# Agent Sandbox on EKS with Pulumi HCL

This branch deploys the agent-sandbox blueprint (`infra/base/terraform` plus
`terraform/blueprint.tfvars`) with [Pulumi HCL](https://github.com/pulumi/pulumi-hcl):
Pulumi runs the Terraform HCL directly (`runtime: hcl` in `Pulumi.yaml`). Nothing
is converted. Pulumi Cloud holds the state, and AWS credentials come from a Pulumi
ESC environment. The Terraform path (`install.sh` / `cleanup.sh`) still works; the
base-module changes below are valid Terraform too.

## Quick start

Prerequisites: `pulumi` (v3.268+, logged in to Pulumi Cloud), AWS CLI v2, `kubectl`
(1.33-1.35), and read access to the ESC environment.

```bash
cd infra/agent-sandbox

# Preview (no changes)
PREVIEW_ONLY=1 ./install-pulumi.sh

# Deploy (20-30 min)
./install-pulumi.sh

# kubectl access (the kubeconfig calls `aws eks get-token`, so kubectl also needs ESC credentials)
pulumi env run ediri/pulumi-idp/auth -- aws eks update-kubeconfig --name agent-sandbox --region us-east-1
pulumi env run ediri/pulumi-idp/auth -- kubectl get pods -n agent-sandbox-system

# Tear down
./cleanup-pulumi.sh
```

| Variable | Default | Used by |
|---|---|---|
| `PULUMI_STACK` | `ediri/agent-sandbox-eks/dev` | both scripts |
| `ESC_ENV` | `ediri/pulumi-idp/auth` | both scripts |
| `PREVIEW_ONLY` | `0` (`1` runs `pulumi preview` only) | install |
| `MAX_ATTEMPTS` | `3` | install (`pulumi up`), cleanup (`pulumi destroy`) |
| `RETRY_DELAY` | `60` seconds | install |
| `PULUMI_ARGS` | empty (extra args for preview/up, e.g. `--diff`) | install |
| `KEEP_IN_CLUSTER_STATE` | `0` (`1` keeps in-cluster resources in state so destroy deletes them through the API) | cleanup |
| `REMOVE_STACK` | `0` (`1` runs `pulumi stack rm` after a verified destroy) | cleanup |

### What `install-pulumi.sh` does

It follows the same steps as `install.sh`:

1. Copies `../base/terraform/*` into `terraform/_LOCAL`.
2. Copies `pulumi/Pulumi.yaml` (project `agent-sandbox-eks`, `runtime: hcl`) into `_LOCAL`.
3. Copies `terraform/blueprint.tfvars` to `_LOCAL/blueprint.auto.tfvars`. Pulumi HCL has no
   `-var-file`; it loads `terraform.tfvars` and `*.auto.tfvars` from the project root (literal values only).
4. Runs `pulumi install`, then checks that `sdks/<provider>/hcl.sdk.json` exists. `pulumi install`
   exits 0 and installs nothing when the HCL fails to parse
   ([pulumi-hcl#688](https://github.com/pulumi/pulumi-hcl/issues/688)).
5. Runs `pulumi stack select --create $PULUMI_STACK`.
6. Runs `pulumi preview` or `pulumi up --yes`, wrapped in `pulumi env run $ESC_ENV --`.

There is no staged `-target` apply. Terraform needs one because it cannot plan
providers or `for_each` whose inputs stay unknown until the cluster exists.
Pulumi registers those resources during the same update, once their inputs resolve.
For the same reason, the preview shows fewer resources than the update creates.
For example, the Karpenter NodePool manifests come from a `kubectl` data source,
which can only be read once the cluster exists.

**Cluster credentials and retries.** The kubernetes, helm and kubectl providers authenticate
with an exec plugin (`aws eks get-token`, see `base/terraform/main.tf`), so no token can
expire. A `data "aws_eks_cluster_auth"` token lasts about 15 minutes. A first `up` can take
longer than that between creating the cluster and finishing Karpenter, ArgoCD and the
addons, which would end in 401s. Pulumi also stores provider inputs in state, so a later
`pulumi destroy` would reuse the expired token. On top of that, `pulumi up` is retried up
to `MAX_ATTEMPTS` times. Pulumi records each resource that succeeds, so a retry only does
the remaining work, and data sources are re-read on each run. The retries cover
eventual-consistency failures on a new cluster: CRDs or webhooks that aren't ready yet,
ArgoCD sync lag, and API throttling.

**`sdks/` and `_LOCAL`.** `terraform/_LOCAL/*` is git-ignored (`**/_LOCAL/*` in the root
`.gitignore`), and that includes `Pulumi.yaml`, `blueprint.auto.tfvars`, `sdks/` and
`Pulumi.<stack>.yaml` inside it. The Pulumi HCL docs recommend committing
`sdks/<provider>/hcl.sdk.json`. This branch doesn't, because `_LOCAL` is generated and
upstream doesn't commit `.terraform.lock.hcl` either. `pulumi install` regenerates them
(providers come from `registry.opentofu.org`). `install-pulumi.sh` never deletes an existing
`_LOCAL/sdks/`, so the provider versions a preview resolved are reused by the following `up`.
Run `rm -rf terraform/_LOCAL/sdks` to re-resolve them.

### What `cleanup-pulumi.sh` does

This is `cleanup.sh` with the Terraform destroy phase replaced. The script re-runs itself
under `pulumi env run $ESC_ENV`, so `aws`, `kubectl` and `pulumi` all get credentials. It
writes its own temporary kubeconfig and leaves your current context alone.

0. Uninstalls the egress example: CNPs/ANPs and the `<cluster>-bedrock-irsa` role. If the
   cluster is already gone, it deletes only the IAM role.
1. Deletes the SandboxClaims, WarmPools, Sandboxes and PVCs in `agent-sandboxes`, so the
   EBS CSI driver deletes the demo's EBS volumes.
2. Scales Karpenter to 0, 3. drops the NodePool/EC2NodeClass finalizers, and
   4. terminates the Karpenter instances. These steps are the same as in `cleanup.sh`.
5. Runs `pulumi destroy`. It first removes the in-cluster resources (`helm:`, `kubectl:`,
   `kubernetes:` types, plus the `terraform_data.karpenter` stash) from the state with
   `pulumi state delete`, dependents first. Deleting the cluster removes them, and the
   destroy then never needs the cluster API, which is what `cleanup.sh` gets from
   `terraform state rm`. It then runs `pulumi destroy --continue-on-error` up to
   `MAX_ATTEMPTS` times, and after each attempt checks AWS directly: is the VPC gone, is
   the EKS cluster gone, and is the stack empty?
6. Sweeps leftovers: cluster security groups in a remaining VPC (then destroys again),
   `available` EBS volumes tagged `kubernetes.io/cluster/<name>=owned`, placement groups,
   the `alias/eks/<name>` KMS alias, and `/aws/eks/<name>` log groups.

The stack itself is kept, empty, so it can be reused.

### Terraform commands and their Pulumi equivalents

| Terraform (README) | Pulumi |
|---|---|
| `terraform -chdir=../terraform/_LOCAL output -raw deployment_name` | `pulumi -C ../terraform/_LOCAL stack output deployment_name --stack ediri/agent-sandbox-eks/dev` |
| `terraform output -raw configure_kubectl` | `pulumi -C terraform/_LOCAL stack output configure_kubectl` |
| `kubectl get ec2nodeclass m6i-cpu -o jsonpath='{.spec.role}'` (the README's Karpenter role lookup) | `pulumi -C ../terraform/_LOCAL stack output karpenter_node_iam_role` (the base creates the `general-purpose`, `gpu` and `neuron` EC2NodeClasses; there is no `m6i-cpu`) |
| `terraform state list` | `pulumi stack --show-urns` / `pulumi stack export` |

The blueprint scripts (`conformance.sh`, `basic/install.sh`, the egress example) read only
`terraform/blueprint.tfvars` and the kubectl context, so they work unchanged. Run them
under `pulumi env run ediri/pulumi-idp/auth --`.

## Base-module changes for Pulumi HCL

Pulumi HCL 0.18.x (language plugin `hcl` 0.18.4, `terraform-provider` 1.4.0) has four
gaps that `infra/base/terraform` runs into. All four workarounds below are also valid
Terraform. Checked with Terraform 1.16.6 `terraform validate` against aws 6.69.1,
helm 3.3.0, kubernetes 3.3.0, and kubectl (alekc) 2.4.1.

| # | File | Pulumi HCL error / gap | Workaround | Terraform-compatible | Upstream issue |
|---|---|---|---|---|---|
| 1 | `main.tf` (`ephemeral "aws_eks_cluster_auth"`, `ephemeral "aws_ecrpublic_authorization_token"`, 5 `ephemeral.*` refs) | `ephemeral` blocks not supported | ECR Public token: `data` source. EKS token: dropped. The kubernetes/helm/kubectl providers use `exec` → `aws eks get-token`, so no token can expire mid-apply or at destroy time | yes (needs AWS CLI v2 on PATH, already a prerequisite) | [pulumi-hcl#169](https://github.com/pulumi/pulumi-hcl/issues/169) |
| 2 | `eks.tf:419`, `torchx-etcd.tf:19` | `depends_on = [module.eks.eks_cluster_id]` → `unknown node "module.eks.output.eks_cluster_id"` (EKS module v21 has no such output; Terraform tolerates the dangling reference) | `depends_on = [module.eks]` | yes | [pulumi-hcl#685](https://github.com/pulumi/pulumi-hcl/issues/685) |
| 3 | `kube-prometheus-stack.tf:27` | sensitive `var.grafana_admin_password` used in `count` is rejected (Terraform allows it) | `nonsensitive(var.grafana_admin_password == "")` (only the emptiness check is exposed) | yes | [pulumi-hcl#686](https://github.com/pulumi/pulumi-hcl/issues/686) |
| 4 | `main.tf` helm provider `registries = [{ url, username, password }]` | list-nested attributes are only accepted in block form, and Terraform/OpenTofu reject the block form | Provider-level `registries` removed. The only OCI charts from `public.ecr.aws` are the two Karpenter releases (`karpenter.tf`), which now set `repository_username`/`repository_password` from `data.aws_ecrpublic_authorization_token` | yes | [pulumi-hcl#687](https://github.com/pulumi/pulumi-hcl/issues/687) |

Notes:

- #687 also covers `helm_release` `set = [{...}]` and `data "helm_template"` `set`.
  Neither appears anywhere in `infra/base/terraform`, enabled or not.
- Side effect of #4: the ECR Public token changes on every run. Every `pulumi up` and
  `terraform plan` therefore shows an in-place update of `helm_release.karpenter_crd` and
  `helm_release.karpenter` (a no-op `helm upgrade`). This is expected.
- `pulumi install` exits 0 on parse errors
  ([pulumi-hcl#688](https://github.com/pulumi/pulumi-hcl/issues/688)). `install-pulumi.sh`
  checks for the generated SDKs.
- The exec wiring was tested locally. A Pulumi HCL program with all three providers
  pointed at a fake API server ran the exec command for each provider, and each sent its
  bearer token.
- Not hit by this blueprint, but seen while testing: `data "kubernetes_namespace_v1"` with
  a `metadata { name = ... }` block fails with `Missing required argument "annotations"`
  under Pulumi HCL.

## Demo configuration (us-east-1)

| File | Change | Why |
|---|---|---|
| `terraform/blueprint.tfvars` | `region = "us-east-1"` | Same region as the agent's Bedrock client (`AWS_REGION` in the agent templates / `agent.py`) |
| `terraform/blueprint.tfvars` | `availability_zones_count = 3` | us-east-1 has 6 AZs. `use1-az3` can't host the EKS control plane (the base already filters it for control-plane subnets) and doesn't offer the core node group's `m6i.xlarge`/`m7i.xlarge`, but the core node group spans every secondary subnet. In the demo account, us-east-1a/b/c = use1-az1/az2/az4, which offer m6i, m7i and g6. **The AZ name-to-ID mapping differs per account**; check it with `aws ec2 describe-availability-zones --region us-east-1`. |
| `terraform/blueprint.tfvars` | `agent_sandbox_version = "v1.0.7"` | Latest release (2026-10-15). The `v1.0.7` tag has `helm/` (the ArgoCD Application path), CRDs in `helm/crds/` (v1beta1 SandboxTemplate with `volumeClaimTemplates`, Sandbox with `operatingMode: Running\|Suspended`), and `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.7` exists (the chart's `image.tag` is set to the same ref) |
| `blueprints/agent-sandbox/manifests/sandbox-agent.yaml` | SandboxWarmPool `replicas: 0` → `1` | The claim adopts a pre-warmed sandbox. Its pod is then named `sandbox-agent-pool-xxxxx`, not `sandbox-agent`; resolve it with `kubectl -n agent-sandboxes get sandboxclaim sandbox-agent -o jsonpath='{.status.sandbox.name}'`. `conformance.sh` and the blueprint README now do this |
| `blueprints/agent-sandbox/manifests/sandbox-agent-{gvisor,runc}.yaml` | `volumeClaimTemplates: [state]` (1Gi, `gp3`, RWO) mounted at `/workspace/state`, plus pod `securityContext.fsGroup: 1000` | Persistent state for the suspend/resume demo. The controller creates PVC `state-<sandbox>` (owned by the Sandbox) and injects pod volume `state`. `fsGroup` lets the non-root agent (uid 1000) write to the volume. The IRSA SA, the gVisor `runtimeClassName`/toleration and the ConfigMap mount are unchanged |

Suspend/resume walkthrough (see also `blueprints/agent-sandbox/README.md`):

```bash
SANDBOX=$(kubectl -n agent-sandboxes get sandboxclaim sandbox-agent -o jsonpath='{.status.sandbox.name}')
kubectl -n agent-sandboxes exec "$SANDBOX" -c agent-runtime -- sh -c 'date > /workspace/state/note'
kubectl -n agent-sandboxes patch sandbox "$SANDBOX" --type merge -p '{"spec":{"operatingMode":"Suspended"}}'
kubectl -n agent-sandboxes patch sandbox "$SANDBOX" --type merge -p '{"spec":{"operatingMode":"Running"}}'
kubectl -n agent-sandboxes wait --for=condition=Ready "pod/$SANDBOX" --timeout=180s
kubectl -n agent-sandboxes exec "$SANDBOX" -c agent-runtime -- cat /workspace/state/note
```

The gp3 EBS volume is zonal, so the resumed pod lands in the same AZ. If the gVisor node was
consolidated while the sandbox was suspended (`consolidateAfter: 10m`), resuming waits 60-90s
for Karpenter to bring up a new node.

Bedrock: the agent templates set `BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-5-20250929-v1:0`.
In us-east-1 that model is entitled and authorized for the demo account, and a test
invocation succeeded. Its lifecycle status is `LEGACY` (legacy since 2026-10-08,
end of life 2027-04-08). The `agent.py` fallback default,
`us.anthropic.claude-sonnet-4-20250514-v1:0`, is past end of life, but it only applies if
`BEDROCK_MODEL_ID` is unset. `anthropic.claude-sonnet-4-6` is `ACTIVE`, and both the IRSA
policy template (`anthropic.claude-sonnet-4-*`, `us.anthropic.claude-sonnet-4*`) and the
egress allowlist already cover it.

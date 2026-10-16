#!/bin/bash
# Agent Sandbox solution — hierarchical teardown for the Pulumi HCL
# deployment (install-pulumi.sh). Port of cleanup.sh with the
# `terraform destroy` phase replaced by `pulumi destroy`.
#
# The whole script runs inside `pulumi env run <ESC env>` (it re-execs
# itself) so aws, kubectl and pulumi all get AWS credentials from
# Pulumi ESC. Phases run in order; each is idempotent and tolerates
# being skipped if its prerequisites are missing.
#
#   0. Egress example uninstall — removes CNPs/ANPs + the Bedrock IRSA
#      role provisioned by blueprints/agent-sandbox/egress.
#   1. Sandbox workloads — deletes SandboxClaims / SandboxWarmPools /
#      Sandboxes and their PVCs in agent-sandboxes so the EBS CSI driver
#      deletes the backing EBS volumes while it is still running.
#   2. Karpenter scale-down — controller replicas to 0 so it stops
#      launching replacement nodes during teardown.
#   3. Karpenter finalizer drop — EC2NodeClass + NodePool finalizers to
#      empty (the termination finalizer waits for the controller).
#   4. Karpenter instance termination — terminates Karpenter-launched
#      EC2 instances directly so subnet/ENI deletion is not blocked.
#   5. Pulumi destroy — removes in-cluster resources (helm/kubectl/
#      kubernetes) from the Pulumi state first (the cluster delete sweeps
#      them; no dependency on a healthy cluster API), then
#      `pulumi destroy` with retry-and-verify (VPC + EKS cluster gone,
#      checked against AWS, not exit codes). Up to MAX_ATTEMPTS.
#   6. Auxiliary AWS resource sweep — leftover cluster SGs, EBS volumes
#      tagged for the cluster, placement groups, KMS alias, CloudWatch
#      log groups.
#
# The Pulumi stack itself is kept (empty) so it can be reused; pass
# REMOVE_STACK=1 to delete it after a successful destroy.
#
# Environment:
#   PULUMI_STACK   (default ediri/agent-sandbox-eks/dev)
#   ESC_ENV        (default ediri/pulumi-idp/auth)
#   MAX_ATTEMPTS   pulumi destroy attempts (default 3)
#   KEEP_IN_CLUSTER_STATE=1  skip the state removal in phase 5 and let
#                  pulumi destroy delete in-cluster resources via the API
#   REMOVE_STACK=1 `pulumi stack rm` after a verified destroy
#
# Usage:
#   cd infra/agent-sandbox
#   ./cleanup-pulumi.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR/terraform/_LOCAL"
PULUMI_STACK="${PULUMI_STACK:-ediri/agent-sandbox-eks/dev}"
ESC_ENV="${ESC_ENV:-ediri/pulumi-idp/auth}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

# Re-exec under Pulumi ESC so every aws/kubectl/pulumi call below has
# AWS credentials.
if [ -z "${AGENT_SANDBOX_CLEANUP_IN_ESC:-}" ]; then
    export AGENT_SANDBOX_CLEANUP_IN_ESC=1
    exec pulumi env run "$ESC_ENV" -- bash "$SCRIPT_DIR/$(basename "$0")" "$@"
fi

for bin in pulumi aws kubectl python3; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found on PATH." >&2; exit 1; }
done

TFVARS="$SCRIPT_DIR/terraform/blueprint.tfvars"
if [ -f "$TFVARS" ]; then
    CLUSTER_NAME=$(grep -E '^name\s*=' "$TFVARS" | head -1 | awk -F'"' '{print $2}')
    TFVARS_REGION=$(grep -E '^region\s*=' "$TFVARS" | head -1 | awk -F'"' '{print $2}' || echo "")
fi
CLUSTER_NAME="${CLUSTER_NAME:-agent-sandbox}"
# Region precedence: tfvars > base module default (us-west-2). The ESC
# environment exports AWS_REGION for its own default region, which is
# not necessarily the deployment region, so it is deliberately ignored.
REGION="${TFVARS_REGION:-us-west-2}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
echo "Resolved cluster=$CLUSTER_NAME region=$REGION stack=$PULUMI_STACK"

vpc_id() {
    aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
        --query "Vpcs[].VpcId" --output text 2>/dev/null || echo ""
}
cluster_status() {
    aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
        --query 'cluster.status' --output text 2>/dev/null || echo ""
}

# Dedicated kubeconfig so we never act on whatever context the caller
# has selected.
KUBECONFIG_TMP=$(mktemp -t agent-sandbox-kubeconfig.XXXXXX)
trap 'rm -f "$KUBECONFIG_TMP"' EXIT
export KUBECONFIG="$KUBECONFIG_TMP"
CLUSTER_REACHABLE=false
if [ -n "$(cluster_status)" ] \
    && aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBECONFIG_TMP" >/dev/null 2>&1 \
    && kubectl version --request-timeout=15s >/dev/null 2>&1; then
    CLUSTER_REACHABLE=true
fi
echo "Cluster API reachable: $CLUSTER_REACHABLE"

echo ""
echo "=== Phase 0: Egress example uninstall (CNPs/ANPs + Bedrock IRSA role) ==="
example_dir="$SCRIPT_DIR/../../blueprints/agent-sandbox/egress"
if [ -x "$example_dir/install.sh" ]; then
    if [ "$CLUSTER_REACHABLE" = "true" ]; then
        ( cd "$example_dir" && CLUSTER_NAME="$CLUSTER_NAME" REGION="$REGION" ./install.sh uninstall ) || true
    else
        # Cluster gone: only the IAM role can still be removed.
        role="${CLUSTER_NAME}-bedrock-irsa"
        if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
            for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
                aws iam delete-role-policy --role-name "$role" --policy-name "$p" || true
            done
            aws iam delete-role --role-name "$role" || true
            echo "  Deleted IAM role $role"
        else
            echo "  Cluster unreachable and no $role role — skipping."
        fi
    fi
fi

echo ""
echo "=== Phase 1: Delete sandbox workloads + PVCs (releases EBS volumes) ==="
if [ "$CLUSTER_REACHABLE" = "true" ] && kubectl get ns agent-sandboxes >/dev/null 2>&1; then
    for kind in sandboxclaims.extensions.agents.x-k8s.io sandboxwarmpools.extensions.agents.x-k8s.io \
                sandboxes.agents.x-k8s.io agentsandboxes.custom.agents.x-k8s.io; do
        kubectl -n agent-sandboxes delete "$kind" --all --wait=true --timeout=120s >/dev/null 2>&1 || true
    done
    kubectl -n agent-sandboxes delete pvc --all --wait=true --timeout=180s >/dev/null 2>&1 || true
    echo "  Done (remaining PVCs: $(kubectl -n agent-sandboxes get pvc --no-headers 2>/dev/null | wc -l))"
else
    echo "  Cluster or namespace not present — skipping."
fi

echo ""
echo "=== Phase 2: Scale Karpenter controller to 0 (stop new node launches) ==="
if [ "$CLUSTER_REACHABLE" = "true" ] && kubectl -n kube-system get deployment karpenter >/dev/null 2>&1; then
    kubectl -n kube-system scale deployment karpenter --replicas=0 >/dev/null 2>&1 || true
    sleep 10
    echo "  Scaled to 0."
else
    echo "  Karpenter deployment not present — skipping."
fi

echo ""
echo "=== Phase 3: Drop Karpenter finalizers on EC2NodeClass + NodePool ==="
if [ "$CLUSTER_REACHABLE" = "true" ]; then
    for res in $(kubectl get ec2nodeclasses -o name 2>/dev/null) $(kubectl get nodepools -o name 2>/dev/null); do
        echo "  Patching finalizer on $res"
        kubectl patch "$res" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
else
    echo "  Cluster not reachable — skipping."
fi

echo ""
echo "=== Phase 4: Terminate Karpenter-provisioned EC2 instances ==="
KARPENTER_INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
              "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
              "Name=instance-state-name,Values=running,pending,stopping" \
    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || echo "")
if [ -z "$KARPENTER_INSTANCES" ]; then
    KARPENTER_INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:karpenter.sh/nodepool,Values=${CLUSTER_NAME}-*" \
                  "Name=instance-state-name,Values=running,pending,stopping" \
        --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || echo "")
fi
if [ -n "$KARPENTER_INSTANCES" ]; then
    echo "  Terminating: $KARPENTER_INSTANCES"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "$REGION" --instance-ids $KARPENTER_INSTANCES >/dev/null
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $KARPENTER_INSTANCES || true
else
    echo "  No Karpenter-provisioned instances found."
fi

echo ""
echo "=== Phase 5: Pulumi destroy ==="
PHASE_5_SUCCESS=false
if [ ! -f "$LOCAL_DIR/Pulumi.yaml" ]; then
    # Fresh checkout (or _LOCAL wiped): stage the project the same way
    # install-pulumi.sh does so pulumi has the project + plugins.
    echo "  Staging Pulumi HCL project in $LOCAL_DIR"
    mkdir -p "$LOCAL_DIR"
    cp -r "$SCRIPT_DIR/../base/terraform/"* "$LOCAL_DIR/"
    cp "$SCRIPT_DIR/pulumi/Pulumi.yaml" "$LOCAL_DIR/Pulumi.yaml"
    cp "$TFVARS" "$LOCAL_DIR/blueprint.auto.tfvars"
    rm -f "$LOCAL_DIR/backend.tf"
    # pulumi install exits 0 even if the HCL fails to parse
    # (https://github.com/pulumi/pulumi-hcl/issues/688); destroy below
    # surfaces such errors.
    ( cd "$LOCAL_DIR" && pulumi install ) || true
fi
if [ -f "$LOCAL_DIR/Pulumi.yaml" ]; then
    cd "$LOCAL_DIR"
    if [ "${KEEP_IN_CLUSTER_STATE:-0}" != "1" ]; then
        # In-cluster resources die with the cluster. Dropping them from
        # state first means the destroy never needs the cluster API (the
        # upstream cleanup.sh does the same with `terraform state rm`).
        # Reverse checkpoint order = dependents first; a URN that still
        # has a non-k8s dependent fails to delete and is simply left for
        # pulumi destroy.
        STATE_JSON=$(mktemp -t agent-sandbox-state.XXXXXX)
        if pulumi stack export --stack "$PULUMI_STACK" > "$STATE_JSON" 2>/dev/null; then
            mapfile -t K8S_URNS < <(python3 -I - "$STATE_JSON" <<'PY'
import json, sys
res = json.load(open(sys.argv[1])).get("deployment", {}).get("resources") or []
k8s = ("helm:", "kubectl:", "kubernetes:")
for r in reversed(res):
    t = r.get("type", "")
    # terraform_data.karpenter (Stash) only exists to order the NodePool
    # manifests after the Karpenter release; it has no cloud resource.
    if t.startswith(k8s) or (t == "pulumi:index:Stash" and r["urn"].endswith("::karpenter[0]")):
        print(r["urn"])
PY
)
            echo "  Removing ${#K8S_URNS[@]} in-cluster resources from state (cluster delete sweeps them)"
            for urn in "${K8S_URNS[@]}"; do
                pulumi state delete "$urn" --stack "$PULUMI_STACK" --yes >/dev/null 2>&1 \
                    && echo "    - ${urn##*::}" || echo "    ! kept ${urn##*::} (has dependents)"
            done
        fi
        rm -f "$STATE_JSON"
    fi

    for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
        echo ""
        echo "  pulumi destroy attempt $attempt/$MAX_ATTEMPTS..."
        pulumi destroy --stack "$PULUMI_STACK" --yes --skip-preview --non-interactive --continue-on-error || true
        remaining_vpc=$(vpc_id)
        remaining_cluster=$(cluster_status)
        remaining_resources=$(pulumi stack export --stack "$PULUMI_STACK" 2>/dev/null \
            | python3 -I -c 'import json,sys; r=json.load(sys.stdin).get("deployment",{}).get("resources") or []; print(sum(1 for x in r if not x["type"].startswith("pulumi:")))' 2>/dev/null || echo "?")
        echo "  After attempt $attempt: vpc='$remaining_vpc' cluster='$remaining_cluster' stack resources=$remaining_resources"
        if [ -z "$remaining_vpc" ] && [ -z "$remaining_cluster" ] && [ "$remaining_resources" = "0" ]; then
            PHASE_5_SUCCESS=true
            break
        fi
        sleep 30
    done
    cd "$SCRIPT_DIR"
fi

echo ""
echo "=== Phase 6: Sweep auxiliary AWS resources ==="
LINGERING_VPC=$(vpc_id)
if [ -n "$LINGERING_VPC" ]; then
    echo "  VPC $LINGERING_VPC still present — sweeping non-default security groups..."
    for sg in $(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$LINGERING_VPC" \
                  --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
        echo "    Deleting security group $sg"
        aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 || true
    done
    if [ -f "$LOCAL_DIR/Pulumi.yaml" ]; then
        echo "  Retrying pulumi destroy..."
        ( cd "$LOCAL_DIR" && pulumi destroy --stack "$PULUMI_STACK" --yes --skip-preview --non-interactive --continue-on-error ) || true
        if [ -z "$(vpc_id)" ] && [ -z "$(cluster_status)" ]; then PHASE_5_SUCCESS=true; fi
    fi
fi

echo "  EBS volumes (kubernetes.io/cluster/${CLUSTER_NAME}=owned, available):"
VOLUME_IDS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" "Name=status,Values=available" \
    --query "Volumes[].VolumeId" --output text 2>/dev/null || echo "")
if [ -n "$VOLUME_IDS" ]; then
    for v in $VOLUME_IDS; do
        echo "    Deleting $v"
        aws ec2 delete-volume --region "$REGION" --volume-id "$v" >/dev/null 2>&1 || true
    done
else
    echo "    None found."
fi

echo "  Placement groups:"
PG_NAMES=$(aws ec2 describe-placement-groups --region "$REGION" --filters "Name=group-name,Values=${CLUSTER_NAME}-*" \
    --query "PlacementGroups[].GroupName" --output text 2>/dev/null || echo "")
if [ -n "$PG_NAMES" ]; then
    for pg in $PG_NAMES; do
        echo "    Deleting $pg"
        aws ec2 delete-placement-group --region "$REGION" --group-name "$pg" >/dev/null 2>&1 || true
    done
else
    echo "    None found."
fi

echo "  KMS aliases:"
KMS_ALIASES=$(aws kms list-aliases --region "$REGION" \
    --query "Aliases[?AliasName=='alias/eks/${CLUSTER_NAME}'].AliasName" --output text 2>/dev/null || echo "")
if [ -n "$KMS_ALIASES" ]; then
    for alias in $KMS_ALIASES; do
        echo "    Deleting $alias"
        aws kms delete-alias --region "$REGION" --alias-name "$alias" >/dev/null 2>&1 || true
    done
else
    echo "    None found."
fi

echo "  CloudWatch log groups:"
LOG_GROUPS=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" \
    --query "logGroups[].logGroupName" --output text 2>/dev/null || echo "")
if [ -n "$LOG_GROUPS" ]; then
    for lg in $LOG_GROUPS; do
        echo "    Deleting $lg"
        aws logs delete-log-group --region "$REGION" --log-group-name "$lg" >/dev/null 2>&1 || true
    done
else
    echo "    None found."
fi

echo ""
if [ "$PHASE_5_SUCCESS" = "true" ]; then
    if [ "${REMOVE_STACK:-0}" = "1" ] && [ -f "$LOCAL_DIR/Pulumi.yaml" ]; then
        ( cd "$LOCAL_DIR" && pulumi stack rm "$PULUMI_STACK" --yes --non-interactive ) || true
    fi
    echo "=== Cleanup complete ==="
    echo "  - Pulumi-managed resources (EKS, VPC, IAM, KMS, log groups) destroyed; stack $PULUMI_STACK is empty"
    echo "  - Bedrock IRSA role, sandbox PVCs/EBS volumes, Karpenter instances removed"
    echo "  - Auxiliary AWS resources swept"
else
    echo "=== Cleanup partially complete ==="
    echo "pulumi destroy did not fully succeed after $MAX_ATTEMPTS attempts. Check:"
    echo "  - VPC tagged Name=$CLUSTER_NAME, EKS cluster $CLUSTER_NAME ($REGION)"
    echo "  - Orphaned ENIs / EC2 instances tagged with the cluster name"
    echo "To retry the destroy manually:"
    echo "  cd $LOCAL_DIR"
    echo "  pulumi env run $ESC_ENV -- pulumi destroy --stack $PULUMI_STACK --yes"
    exit 1
fi

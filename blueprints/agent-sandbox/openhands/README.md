# OpenHands on Agent Sandbox (EKS): the raw take

This is the demo of the KCD UK 2026 talk "Your AI Agent Needs More Than a Pod"
by Engin Diri.

A real [OpenHands](https://docs.openhands.dev/) coding agent runs in a
sandbox it claims from a warm pool on the agent-sandbox blueprint, through
the Agent Sandbox project's
[OpenHands adapter](https://github.com/kubernetes-sigs/agent-sandbox/tree/e0b002e221a7e8d5534f686fe1d3ef4fdfd6d6bb/clients/integrations/openhands). Before
that, a sandbox from the same pool is claimed by hand and inspected with plain
commands: gVisor kernel, no Kubernetes token, one allowed and one off-list
request, and Cilium's own record of the drop. Everything here runs on the
cluster from [`infra/agent-sandbox`](../../../infra/agent-sandbox/) with no
infra changes.

- [What it shows](#what-it-shows)
- [Prerequisites](#prerequisites)
- [Run](#run)
- [Results: the 18 October 2026 raw take](#results-the-18-october-2026-raw-take)
- [Teardown](#teardown)
- [Cost](#cost)
- [Files](#files)

## What it shows

The recording is raw and unstaged. **Every line on screen is a command typed
by the VHS tape ([`openhands-demo.tape`](openhands-demo.tape)) or the
unmodified stdout/stderr of that command.** No comments, no narration, no
custom formatting, no output filters, with one exception: `| head -n 3` on
`dmesg` and `| head -n 1` on the PyPI `curl -I`. Nothing inside the take is
cut, sped up or replayed: VHS records in real time, and each `Wait` in the
tape waits for the shell prompt to come back after a real command.

**The agent is never told about the allowlist.** Its task (in `run.py`) names
no host except the PyPI JSON API it needs and says nothing about the network.
Whatever the agent did is what the video shows.

On screen, in order:

1. The warm pool `openhands-pool` holds 2 Ready sandboxes.
2. `manifests/40-claim.yaml` claims one of them by hand (`guardrails`).
   Inside it: `uname -r` shows the gVisor kernel, `dmesg` gVisor's boot
   lines, the Kubernetes service-account token directory does not exist,
   `pypi.org` answers, `example.com` times out, and Hubble shows Cilium
   dropping that SYN.
3. `python run.py` in the in-cluster client. The agent claims the other
   sandbox from the pool and does its task. Everything the OpenHands SDK
   prints is its default output: banner, INFO logs (including the adapter's
   claim logs), the system prompt, one panel per agent action and
   observation, token and cost lines, and the agent's own final message.

Not on screen: the hidden shell setup before the first visible command
(`export LANG=C.UTF-8 LC_ALL=C.UTF-8`, start `script` for the session log,
`source ./tape-env.sh` for the `$` prompt and the directory, `clear`), and
the off-screen steps in `record.sh` around the take (wait for the pool to
hold 2 Ready sandboxes before VHS starts, delete the `guardrails` claim after
VHS exits).

Configuration that affects how it looks, not what it says: the VHS terminal
(JetBrains Mono 28 px, line height 1.0, 106x26 cells, padding 40, a dark
theme with background `#231f33`). The client pod's only environment variable
is `SANDBOX_SESSION_KEY`. Nothing sets `LOG_LEVEL` or
`OPENHANDS_SUPPRESS_BANNER`, and `TERM` is not set in the pod (Rich uses its
standard colours).

The whole client, [`run.py`](run.py), exactly as the take ran it:

```python
import os

from openhands.sdk import LLM, Conversation
from openhands.tools.preset.default import get_default_agent
from openhands_k8s_agent_sandbox import AgentSandboxWorkspace

TASK = (
    "Compare the PyPI packages requests, boto3, kubernetes, litellm and "
    "openhands-sdk using the PyPI JSON API: latest version and number of "
    "releases. Install rich, write report.py that prints the result as a "
    "table sorted by releases, and run it."
)

with AgentSandboxWorkspace(
    warmpool="openhands-pool",
    namespace="agent-sandboxes",
    api_key=os.environ["SANDBOX_SESSION_KEY"],
) as ws:
    llm = LLM(model="bedrock/us.anthropic.claude-sonnet-4-6", aws_region_name="us-east-1")
    agent = get_default_agent(llm=llm, cli_mode=True)
    conversation = Conversation(agent=agent, workspace=ws)
    conversation.send_message(TASK)
    conversation.run()
```

`api_key=` is the warm pool's session key for the agent-server, not a model
key. The model call happens inside the sandbox: with a remote workspace, the
SDK sends the agent spec to the agent-server, which runs the agent loop and
calls Bedrock with the pod's IRSA role (`agent-sandbox-bedrock-irsa`). The
adapter's own `example.py` could not run unmodified (hard-coded task,
requires `LLM_API_KEY`, runs workspace operations before the agent), so
`run.py` is its agent half with this task and Bedrock instead of an API key.

## Prerequisites

- An AWS account with Bedrock access to Claude Sonnet 4.6
  (`us.anthropic.claude-sonnet-4-6`) in us-east-1. The demo assumes
  us-east-1, the region in `infra/agent-sandbox/terraform/blueprint.tfvars`,
  `run.py` and the SandboxTemplate.
- `pulumi` (v3.268+, logged in to Pulumi Cloud), AWS CLI v2, `kubectl`,
  `openssl`.

**AWS credentials.** All scripts, here and in `infra/agent-sandbox`, use
your ambient AWS credentials (`AWS_PROFILE`, environment, SSO). To take them
from a Pulumi ESC environment instead, set `ESC_ENV=<org>/<project>/<env>`:
each script then runs its AWS calls under `pulumi env run "$ESC_ENV"`.

1. **Cluster.** Deploy the agent-sandbox blueprint with Pulumi HCL, as
   described in [`infra/agent-sandbox/PULUMI.md`](../../../infra/agent-sandbox/PULUMI.md).
   From the repo root:

   ```bash
   cd infra/agent-sandbox
   ./install-pulumi.sh
   ```

   On a first run it creates and selects the stack `dev` in your default
   Pulumi organization (set `PULUMI_STACK=<org>/agent-sandbox-eks/<stack>`
   to pick another). On 18 October: 21m44s, `+ 180 created`.

2. **Platform.** From the repo root:

   ```bash
   cd blueprints/agent-sandbox/openhands
   ./prereqs.sh            # or one phase: ./prereqs.sh kubeconfig|platform|egress
   ```

   `kubeconfig` runs `aws eks update-kubeconfig` and waits for the ArgoCD
   apps `agent-sandbox`, `kro` and `cilium`. `platform` applies the
   namespace, the gVisor RuntimeClass, the basic SandboxTemplates and the
   gVisor Karpenter NodePool. `egress` runs
   [`../egress/install.sh`](../egress/) (Cilium egress policies and the
   Bedrock IRSA role). The Pulumi stack whose outputs it reads is
   `PULUMI_STACK` if set, otherwise the stack selected in
   `infra/agent-sandbox/terraform/_LOCAL` (the one `install-pulumi.sh`
   deployed). On 18 October: about 6 minutes, 5.5 of them waiting for the
   ArgoCD apps.

3. **OpenHands.** In the same folder:

   ```bash
   ./setup-openhands.sh    # apply + wait; also: apply | wait | check | delete
   ```

   Annotates the IRSA ServiceAccount, creates one random session key (a
   Secret in `agent-sandboxes` and `openhands-client`, never printed), and
   applies the SandboxTemplate, the warm pool and the client. It ends with
   `READY TO RECORD` (`./setup-openhands.sh check` re-runs the check). On
   18 October the pool was 2/2 Ready after 118 s on the fresh cluster,
   including the first gVisor node and the agent-server image pull.

No allowlist entries are needed. The blueprint's `sandbox-llm-allowlist`
(PyPI, `*.pythonhosted.org`, `bedrock-runtime.*.amazonaws.com`,
`sts.*.amazonaws.com`) covers everything. `LITELLM_LOCAL_MODEL_COST_MAP=True`
in the template keeps LiteLLM from downloading its price list from
`raw.githubusercontent.com` at start-up.

## Run

**Live, with the in-cluster client:**

```bash
kubectl exec -it -n openhands-client deploy/oh-client -- python run.py
```

The hand-claimed sandbox from the recording, typed the same way:

```bash
kubectl get sandboxwarmpool -n agent-sandboxes
kubectl apply -f manifests/40-claim.yaml && kubectl wait -n agent-sandboxes sandboxclaim/guardrails --for=condition=Ready
POD=$(kubectl get sandboxclaim guardrails -n agent-sandboxes -o jsonpath='{.status.sandbox.name}')
kubectl exec -n agent-sandboxes $POD -- uname -r
kubectl exec -n agent-sandboxes $POD -- dmesg | head -n 3
kubectl exec -n agent-sandboxes $POD -- ls /var/run/secrets/kubernetes.io/serviceaccount
kubectl exec -n agent-sandboxes $POD -- curl -sSI -m 5 https://pypi.org/simple/ | head -n 1
kubectl exec -n agent-sandboxes $POD -- curl -sSI -m 5 https://example.com
RELAY=$(kubectl get svc hubble-relay -n kube-system -o jsonpath='{.spec.clusterIP}')
kubectl exec -n kube-system ds/cilium -c cilium-agent -- hubble observe --server $RELAY:80 --pod agent-sandboxes/$POD --verdict DROPPED --last 2
kubectl delete -f manifests/40-claim.yaml
```

**Recorded, with VHS:**

```bash
./record.sh                       # wait for the pool, check, record, encode, save the log
POSTER_TS=83.5 ./record.sh encode # redo only the encode
```

About 3 minutes. Everything lands in `./out/` (git-ignored):
`openhands-demo.mp4` (H.264 High, 30 fps, no audio, faststart),
`openhands-demo.webm` (VP9), `openhands-demo-poster.png` and
`openhands-raw-<UTC date>.txt`, the raw terminal log (`script` inside the
recorded shell, ANSI stripped). The log is scanned for AWS key ids and the
pool session key, and deleted if either shows up. Needs VHS 0.12+, `ttyd`,
`ffmpeg` (libx264, libvpx-vp9), a Chromium VHS can find and the JetBrains
Mono font. After a take the pool needs about 80 s to hold 2 Ready sandboxes
again; `record.sh` waits for that before VHS starts.

**Why the client runs in the cluster:** the adapter's default endpoint is the
pod IP on port 8000, and EKS pod IPs are VPC addresses. `kubectl
port-forward` does not work against gVisor pods (adapter README,
Troubleshooting), and the SDK's event websocket carries no custom headers, so
the sandbox-router would lose its `X-Sandbox-*` routing headers on it. The
client has its own namespace because every pod in `agent-sandboxes` is in
Cilium default-deny egress.

**Why Hubble goes through the relay:** the `hubble` CLI in the Cilium agent
container talks to that node's local socket only, and `ds/cilium` picks an
arbitrary node. The agent container uses the node's DNS, so the relay's
ClusterIP goes into a typed variable instead of the service name.

## Results: the 18 October 2026 raw take

Recorded on 18 October 2026 at 23:41 UTC in us-east-1, on this branch with
no infra changes, then torn down. 92.6 s, 1920x1080, 30 fps. The raw terminal
log of the take is
[`recorded/openhands-raw-2026-10-18.txt`](recorded/openhands-raw-2026-10-18.txt)
(ANSI stripped; one redaction, the user, host and path in the prompt of the
hidden setup line).

| Video | Typed command | Output on screen |
| --- | --- | --- |
| 0:00 | `kubectl get sandboxwarmpool -n agent-sandboxes` | 0:02 `openhands-pool   2   2   25m` |
| 0:05 | `kubectl apply -f manifests/40-claim.yaml && kubectl wait -n agent-sandboxes sandboxclaim/guardrails --for=condition=Ready` | 0:08 `created`, 0:09 `condition met` |
| 0:10 | `POD=$(kubectl get sandboxclaim guardrails -n agent-sandboxes -o jsonpath='{.status.sandbox.name}')` | (none) |
| 0:13 | `kubectl exec -n agent-sandboxes $POD -- uname -r` | 0:15 `4.19.0-gvisor` |
| 0:16 | `kubectl exec -n agent-sandboxes $POD -- dmesg \| head -n 3` | 0:18 `[    0.000000] Starting gVisor...` and two more gVisor boot lines |
| 0:20 | `kubectl exec -n agent-sandboxes $POD -- ls /var/run/secrets/kubernetes.io/serviceaccount` | 0:23 `No such file or directory`, `command terminated with exit code 2` |
| 0:24 | `kubectl exec -n agent-sandboxes $POD -- curl -sSI -m 5 https://pypi.org/simple/ \| head -n 1` | 0:28 `HTTP/2 200` |
| 0:29 | `kubectl exec -n agent-sandboxes $POD -- curl -sSI -m 5 https://example.com` | 0:36 `curl: (28) Connection timed out after 5001 milliseconds`, `exit code 28` |
| 0:37 | `RELAY=$(kubectl get svc hubble-relay -n kube-system -o jsonpath='{.spec.clusterIP}')` | (none) |
| 0:41 | `kubectl exec -n kube-system ds/cilium -c cilium-agent -- hubble observe --server $RELAY:80 --pod agent-sandboxes/$POD --verdict DROPPED --last 2` | 0:45 `... <> example.com:443 (world) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)` and `... Policy denied DROPPED (TCP Flags: SYN)`, plus two `EVENTS LOST: HUBBLE_RING_BUFFER` notices |
| 0:48 | `kubectl exec -it -n openhands-client deploy/oh-client -- python run.py` | 0:55 SDK banner. 0:56 adapter INFO logs, all stamped 23:42:44: `Creating SandboxClaim`, `Resolved sandbox name 'openhands-pool-9t85t' ... (claim Ready)`, `Claimed sandbox ... from warm pool`, `Agent-sandbox workspace is ready at http://100.65.87.212:8000`. 0:58 system prompt and task. 1:02 the agent's plan and a `curl` loop over `https://pypi.org/pypi/$pkg/json`. 1:07 `pip install rich -q`. 1:14 creates `report.py`. 1:16 `python3 /workspace/report.py`. 1:23 the table. 1:26 the agent's summary, `Run completed ... (status: finished, elapsed: 28.4s)`, `Released sandbox claim`. |
| 1:32.6 | | end |

- **Claim from the warm pool:** the adapter's claim, resolve and ready logs
  all carry the same second (23:42:44): a bind to a running pod, not a boot.
- **The agent did not touch any blocked host.** Hubble, queried after the
  take for the agent's sandbox (`openhands-pool-9t85t`): DNS lookups only for
  `bedrock-runtime.us-east-1.amazonaws.com`, `sts.us-east-1.amazonaws.com`,
  `pypi.org` and `files.pythonhosted.org`; forwarded TCP only to Bedrock, STS
  and PyPI; 0 drops. The only refused request in the video is the one typed
  by hand (`example.com`).
- **Why `curl` times out instead of failing DNS:** an off-list host still
  resolves (the admin policy allows all DNS through the Cilium DNS proxy),
  but the TCP SYN matches no `toFQDNs` rule and is dropped (exit 28).
- **Agent run:** the SDK reports `status: finished, elapsed: 28.4s`. Model
  cost, as printed by the SDK: $0.0343.

Takes: one rehearsal of all commands plus one agent run before recording.
The first raw take (23:37 UTC, 86.6 s) was discarded: the shell's locale was
POSIX, so readline counted the `❯` prompt glyph as 3 columns and garbled the
two typed commands that wrap. The tape now uses an ASCII `$` prompt and
`LANG=C.UTF-8`; nothing else changed. The second take (23:41 UTC) is the one
above. In the log, long typed commands show a stray space where the terminal
wrapped them (`--fo r=condition=Ready`): an artifact of stripping escape
sequences, not of the recording. VHS `Wait+Screen` only reads the first
screenful of the buffer, so the tape waits on the prompt line
(`Wait+Line /^\$\s*$/`).

## Teardown

From this folder:

```bash
./setup-openhands.sh delete   # optional: only this demo's objects
cd ../../../infra/agent-sandbox
./cleanup-pulumi.sh
```

`cleanup-pulumi.sh` (see [PULUMI.md](../../../infra/agent-sandbox/PULUMI.md#what-cleanup-pulumish-does))
removes the egress policies, the IRSA role and every sandbox before it
destroys the stack, so the first line is optional. On 18/19 October: 23:47
to 00:06 UTC, exit 0. Phases 0 to 4 removed the Cilium policies, the IRSA
role, the sandboxes (0 PVCs left), Karpenter and its instances. Phase 5
`pulumi destroy`: `- 138 deleted`, 14m52s, one attempt (in-cluster resources
are dropped from state first, so it's fewer than the 180 created). Phase 6
deleted 15 leftover Karpenter instance profiles. An independent sweep of the
region afterwards found nothing left from the stack: EKS clusters, EC2
instances, VPCs, EIPs, EBS volumes, load balancers, ENIs, security groups,
instance profiles, IAM roles, EKS OIDC providers, the KMS alias, log groups
and placement groups were all clean. The stack is kept, empty.

## Cost

Approximate cost of the raw take: the cluster was up about 80 minutes (EKS
control plane, 2 x m6i.xlarge, NAT gateway and image pulls, 2 x c6a.large
gVisor nodes, EBS), about $1.10. Bedrock, about $0.27 (local dry run $0.12,
rehearsal $0.08, discarded take $0.03, published take $0.03). About $1.40 in
total. The cluster costs money for as long as it runs, so tear it down when
you are done.

## Files

| File | What it is |
| --- | --- |
| `run.py` | The client: claims a sandbox from the warm pool and runs the agent in it |
| `requirements.txt` | `openhands-sdk[boto3]==1.44.1`, `openhands-tools==1.44.1`, `k8s-agent-sandbox==1.0.7`, the adapter from git @ `e0b002e` |
| `prereqs.sh` | `kubeconfig`, `platform`, `egress`: the cluster-side prerequisites |
| `setup-openhands.sh` | `apply`, `wait`, `check`, `delete`. IRSA SA annotation, one random session key (Secret in both namespaces, never printed), template, pool, client |
| `manifests/10-agent-server-template.yaml` | SandboxTemplate: the adapter's template plus `runtimeClassName: gvisor`, `egress-tier: sandbox`, `networkPolicyManagement: Unmanaged`, the IRSA SA, `automountServiceAccountToken: false`, `LITELLM_LOCAL_MODEL_COST_MAP` |
| `manifests/20-agent-server-warmpool.yaml` | SandboxWarmPool `openhands-pool`, 2 replicas (the take claims both) |
| `manifests/30-client.yaml` | Namespace `openhands-client`, SA + Role (claims and sandboxes in `agent-sandboxes` only), Deployment `oh-client` (`python:3.12-bookworm`, pip install at start-up) |
| `manifests/40-claim.yaml` | SandboxClaim `guardrails`, applied on screen |
| `openhands-demo.tape` | The VHS tape |
| `tape-env.sh` | Sourced in the hidden setup: `$` prompt, directory |
| `record.sh` | Waits for the pool, runs VHS, deletes the `guardrails` claim, encodes MP4/WebM/poster into `out/`, writes the log (ANSI stripped, secret scan) |
| `recorded/openhands-raw-2026-10-18.txt` | Raw terminal log of the 18 October 2026 take |

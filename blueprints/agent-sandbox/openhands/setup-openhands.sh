#!/usr/bin/env bash
# OpenHands on Agent Sandbox: stage the warm pool and the in-VPC client.
# Run after ./prereqs.sh (kubeconfig, platform, egress: namespace, gVisor
# RuntimeClass + NodePool, Cilium egress policies, Bedrock IRSA role).
#
#   ./setup-openhands.sh          # apply + wait
#   ./setup-openhands.sh apply    # SA, session key, template, pool, client
#   ./setup-openhands.sh wait     # pool readyReplicas=2, client Ready
#   ./setup-openhands.sh check    # READY TO RECORD?
#   ./setup-openhands.sh delete   # remove everything this script created
#
# AWS credentials: the ambient ones (AWS_PROFILE, env, SSO, ...), or, with
# ESC_ENV set, re-runs itself under `pulumi env run "$ESC_ENV"` (aws and
# kubectl's exec plugin then get the ESC-provided credentials).
# Never prints the session key.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${ESC_ENV:-}" ] && [ -z "${OPENHANDS_DEMO_IN_ESC:-}" ]; then
  export OPENHANDS_DEMO_IN_ESC=1
  exec pulumi env run "$ESC_ENV" -- bash "$HERE/$(basename "$0")" "$@"
fi
# blueprints/agent-sandbox/openhands -> repo root
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
TFVARS="$REPO_ROOT/infra/agent-sandbox/terraform/blueprint.tfvars"

NS=agent-sandboxes
CNS=openhands-client
SA=sandbox-agent-sa
POOL=openhands-pool
if [ -z "${CLUSTER_NAME:-}" ] && [ -f "$TFVARS" ]; then
  CLUSTER_NAME="$(grep -E '^name\s*=' "$TFVARS" | head -1 | awk -F'"' '{print $2}' || true)"
fi
CLUSTER_NAME="${CLUSTER_NAME:-agent-sandbox}"
ROLE_NAME="${CLUSTER_NAME}-bedrock-irsa"
log() { printf '\n\033[1;36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

apply() {
  log "IRSA ServiceAccount $NS/$SA (same as the blueprint's conformance.sh)"
  local role_arn
  role_arn="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
  kubectl -n "$NS" get sa "$SA" >/dev/null 2>&1 || kubectl -n "$NS" create sa "$SA"
  kubectl -n "$NS" annotate sa "$SA" "eks.amazonaws.com/role-arn=$role_arn" --overwrite >/dev/null
  echo "annotated with role $ROLE_NAME"

  log "pool session key (one random value, Secret in $NS and $CNS)"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $CNS
  labels:
    app.kubernetes.io/part-of: openhands-demo
EOF
  local key
  key="$(kubectl -n "$NS" get secret openhands-session-key -o jsonpath='{.data.key}' 2>/dev/null | base64 -d || true)"
  [ -n "$key" ] || key="$(openssl rand -hex 24)"
  for n in "$NS" "$CNS"; do
    kubectl -n "$n" create secret generic openhands-session-key --from-literal=key="$key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "secret $n/openhands-session-key applied"
  done
  unset key

  log "SandboxTemplate + SandboxWarmPool"
  kubectl apply -f "$HERE/manifests/10-agent-server-template.yaml"
  kubectl apply -f "$HERE/manifests/20-agent-server-warmpool.yaml"

  log "client: run.py + requirements as ConfigMaps, RBAC, Deployment"
  kubectl -n "$CNS" delete configmap oh-client-app --ignore-not-found >/dev/null
  kubectl -n "$CNS" create configmap oh-client-app --from-file=run.py="$HERE/run.py" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$CNS" create configmap oh-client-requirements \
    --from-file=requirements.txt="$HERE/requirements.txt" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$HERE/manifests/30-client.yaml"
}

pool_ready() {
  kubectl -n "$NS" get sandboxwarmpool "$POOL" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
}

wait_ready() {
  log "waiting for $POOL readyReplicas=2 (first gVisor node + image pull on a fresh cluster)"
  local start=$SECONDS r
  for _ in $(seq 1 120); do
    r="$(pool_ready)"
    [ "${r:-0}" -ge 2 ] && break
    sleep 5
  done
  echo "pool ready=${r:-0} after $((SECONDS - start)) s"
  log "waiting for the client Deployment (pip install at start-up)"
  kubectl -n "$CNS" rollout status deploy/oh-client --timeout=10m
  check
}

check() {
  local ok=1 r
  r="$(pool_ready)"
  [ "${r:-0}" -ge 2 ] && echo "pool    : $POOL readyReplicas=$r" || { echo "pool    : $POOL readyReplicas=${r:-0} (want 2)"; ok=0; }
  kubectl -n "$CNS" get deploy oh-client -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q 1 \
    && echo "client  : $CNS/oh-client Ready" || { echo "client  : not Ready"; ok=0; }
  local claims
  claims="$(kubectl -n "$NS" get sandboxclaims --no-headers 2>/dev/null | wc -l)"
  [ "$claims" = 0 ] && echo "claims  : none left over" || { echo "claims  : $claims left over (delete them)"; ok=0; }
  kubectl get nodes -l agent-sandbox/runtime=gvisor --no-headers 2>/dev/null | grep -q ' Ready' \
    && echo "gvisor  : node Ready" || { echo "gvisor  : no Ready gVisor node"; ok=0; }
  [ "$ok" = 1 ] && echo "READY TO RECORD" || { echo "NOT READY"; return 1; }
}

delete() {
  kubectl -n "$NS" delete sandboxclaims --all --ignore-not-found
  kubectl delete -f "$HERE/manifests/30-client.yaml" --ignore-not-found
  kubectl delete -f "$HERE/manifests/20-agent-server-warmpool.yaml" --ignore-not-found
  kubectl delete -f "$HERE/manifests/10-agent-server-template.yaml" --ignore-not-found
  kubectl -n "$NS" delete secret openhands-session-key --ignore-not-found
}

case "${1:-all}" in
  all) apply; wait_ready ;;
  apply) apply ;;
  wait) wait_ready ;;
  check) check ;;
  delete) delete ;;
  *) echo "usage: $0 [all|apply|wait|check|delete]" >&2; exit 1 ;;
esac

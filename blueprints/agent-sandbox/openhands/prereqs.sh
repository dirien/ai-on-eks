#!/usr/bin/env bash
# Platform prerequisites for the OpenHands demo, run after
# infra/agent-sandbox/install-pulumi.sh finished (see infra/agent-sandbox/PULUMI.md).
#
#   ./prereqs.sh              # all phases
#   ./prereqs.sh platform     # one phase
#
# Phases (each idempotent, in this order):
#   kubeconfig  aws eks update-kubeconfig, wait for the ArgoCD apps
#               agent-sandbox, kro and cilium to be Synced/Healthy
#   platform    namespace, gVisor RuntimeClass, basic SandboxTemplates,
#               gVisor Karpenter NodePool (infra/agent-sandbox/manifests)
#   egress      Cilium egress policies + Bedrock IRSA role
#               (blueprints/agent-sandbox/egress/install.sh)
#
# Then ./setup-openhands.sh.
#
# Pulumi stack (for the deployment_name and karpenter_node_iam_role outputs):
# PULUMI_STACK if set, else the stack selected in infra/agent-sandbox/terraform/_LOCAL
# (install-pulumi.sh runs `pulumi stack select --create` there).
#
# AWS credentials: the ambient ones (AWS_PROFILE, env, SSO, ...), or, with
# ESC_ENV set, re-runs itself under `pulumi env run "$ESC_ENV"`: aws, kubectl
# and pulumi then get the ESC-provided credentials.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${ESC_ENV:-}" ] && [ -z "${OPENHANDS_DEMO_IN_ESC:-}" ]; then
  export OPENHANDS_DEMO_IN_ESC=1
  exec pulumi env run "$ESC_ENV" -- bash "$HERE/$(basename "$0")" "$@"
fi

# blueprints/agent-sandbox/openhands -> repo root
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
INFRA="$REPO_ROOT/infra/agent-sandbox"
BP="$REPO_ROOT/blueprints/agent-sandbox"
LOCAL_DIR="$INFRA/terraform/_LOCAL"

log() { printf '\n\033[1;36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$LOCAL_DIR/Pulumi.yaml" ] \
  || die "no Pulumi project in $LOCAL_DIR; deploy first with infra/agent-sandbox/install-pulumi.sh"
if [ -n "${PULUMI_STACK:-}" ]; then
  STACK_ARGS=(--stack "$PULUMI_STACK")
else
  STACK_ARGS=()
  PULUMI_STACK="$(pulumi -C "$LOCAL_DIR" stack --show-name 2>/dev/null)" \
    || die "no Pulumi stack selected in $LOCAL_DIR; set PULUMI_STACK (org/project/stack)"
fi

out() { pulumi -C "$LOCAL_DIR" stack output "$1" ${STACK_ARGS[@]+"${STACK_ARGS[@]}"}; }

CLUSTER_NAME="$(out deployment_name)"
REGION="$(grep -E '^region\s*=' "$INFRA/terraform/blueprint.tfvars" | head -1 | awk -F'"' '{print $2}')"
export CLUSTER_NAME REGION AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
echo "stack=$PULUMI_STACK cluster=$CLUSTER_NAME region=$REGION"

phase_kubeconfig() {
  log "kubeconfig for $CLUSTER_NAME ($REGION)"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  log "waiting for ArgoCD apps agent-sandbox, kro, cilium (Synced/Healthy)"
  local app s
  for app in agent-sandbox kro cilium; do
    for _ in $(seq 1 60); do
      s=$(kubectl -n argocd get application "$app" \
            -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
      [ "$s" = "Synced/Healthy" ] && break
      sleep 10
    done
    echo "  $app: ${s:-missing} ($(kubectl -n argocd get application "$app" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null))"
    [ "$s" = "Synced/Healthy" ] || { echo "ERROR: $app not Synced/Healthy after 10 min" >&2; exit 1; }
  done
  kubectl -n kube-system rollout status ds/cilium --timeout=5m
  kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=3m
}

phase_platform() {
  log "platform manifests (infra/agent-sandbox/manifests)"
  local role; role="$(out karpenter_node_iam_role)"
  kubectl apply -f "$INFRA/manifests/namespace.yaml"
  kubectl apply -f "$INFRA/manifests/runtimeclass-gvisor.yaml"
  kubectl apply -f "$INFRA/manifests/sandbox-runc.yaml"
  kubectl apply -f "$INFRA/manifests/sandbox-gvisor.yaml"
  sed -e "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" -e "s|__KARPENTER_NODE_ROLE__|$role|g" \
    "$INFRA/manifests/karpenter-nodepool-gvisor.yaml" | kubectl apply -f -
}

phase_egress() {
  log "egress example: Cilium policies + Bedrock IRSA role"
  (cd "$BP/egress" && ./install.sh)
}

case "${1:-all}" in
  all) phase_kubeconfig; phase_platform; phase_egress ;;
  kubeconfig|platform|egress) "phase_$1" ;;
  *) echo "usage: $0 [all|kubeconfig|platform|egress]" >&2; exit 1 ;;
esac

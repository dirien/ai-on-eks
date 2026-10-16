#!/bin/bash
# Agent Sandbox solution — deploy with Pulumi HCL instead of Terraform.
#
# Same layout as install.sh: the base module is copied into
# terraform/_LOCAL, which is then run as a Pulumi HCL project
# (`runtime: hcl`, Pulumi executes the Terraform HCL directly).
#
#   1. Copy ../base/terraform/* into terraform/_LOCAL (like install.sh).
#   2. Copy pulumi/Pulumi.yaml into _LOCAL (project agent-sandbox-eks).
#   3. Copy terraform/blueprint.tfvars to _LOCAL/blueprint.auto.tfvars.
#      Pulumi HCL has no -var-file flag; it loads terraform.tfvars and
#      *.auto.tfvars from the project root.
#   4. `pulumi install` (resolves providers/modules, writes _LOCAL/sdks/).
#   5. Select (or create) the stack.
#   6. `pulumi preview` (PREVIEW_ONLY=1) or `pulumi up`, wrapped in
#      `pulumi env run <ESC env> --` so AWS credentials come from
#      Pulumi ESC.
#
# Unlike install.sh there is no staged `-target` apply. Terraform needs
# it because it cannot plan providers/for_each whose inputs are unknown
# until the cluster exists; Pulumi registers those resources once their
# inputs resolve during the same update.
#
# Retries: `pulumi up` is retried (MAX_ATTEMPTS, default 3). Pulumi
# records every resource that succeeded, so a retry only continues the
# remaining work, and data sources are re-read on every run. The base
# module's kubernetes/helm/kubectl providers authenticate with an exec
# plugin (`aws eks get-token`), so there is no 15-minute token to
# expire mid-update; the retry is for eventual-consistency failures on
# a fresh cluster (CRDs/webhooks not ready yet, ArgoCD sync lag, AWS
# API throttling).
#
# Environment:
#   PULUMI_STACK   stack to deploy        (default ediri/agent-sandbox-eks/dev)
#   ESC_ENV        Pulumi ESC environment  (default ediri/pulumi-idp/auth)
#   PREVIEW_ONLY   1 = run `pulumi preview` only, no changes
#   MAX_ATTEMPTS   `pulumi up` attempts    (default 3)
#   RETRY_DELAY    seconds between attempts (default 60)
#   PULUMI_ARGS    extra args appended to preview/up (e.g. "--diff")
#
# Usage:
#   cd infra/agent-sandbox
#   PREVIEW_ONLY=1 ./install-pulumi.sh   # preview
#   ./install-pulumi.sh                  # deploy (20-30 min)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR/terraform/_LOCAL"

PULUMI_STACK="${PULUMI_STACK:-ediri/agent-sandbox-eks/dev}"
ESC_ENV="${ESC_ENV:-ediri/pulumi-idp/auth}"
PREVIEW_ONLY="${PREVIEW_ONLY:-0}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-60}"
read -r -a EXTRA_ARGS <<< "${PULUMI_ARGS:-}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Run a command with AWS credentials from Pulumi ESC.
esc() { pulumi env run "$ESC_ENV" -- "$@"; }

for bin in pulumi aws; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "ERROR: '$bin' not found on PATH." >&2
        if [ "$bin" = "aws" ]; then
            echo "       AWS CLI v2 is required: the base module's kubernetes/helm/kubectl" >&2
            echo "       providers authenticate with 'aws eks get-token'." >&2
        fi
        exit 1
    fi
done

log "Staging Pulumi HCL project in $LOCAL_DIR"
mkdir -p "$LOCAL_DIR"
cp -r "$SCRIPT_DIR/../base/terraform/"* "$LOCAL_DIR/"
cp "$SCRIPT_DIR/pulumi/Pulumi.yaml" "$LOCAL_DIR/Pulumi.yaml"
cp "$SCRIPT_DIR/terraform/blueprint.tfvars" "$LOCAL_DIR/blueprint.auto.tfvars"
# A backend.tf left behind by base/terraform/deploy.sh is ignored by
# Pulumi HCL (with a warning); remove it to keep the output clean.
rm -f "$LOCAL_DIR/backend.tf"

cd "$LOCAL_DIR"

# Existing _LOCAL/sdks/ entries are kept, so provider versions resolved by
# an earlier run (e.g. the preview) are reused by the real `up`.
log "pulumi install"
pulumi install
# `pulumi install` exits 0 and silently installs nothing when the HCL
# fails to parse (https://github.com/pulumi/pulumi-hcl/issues/688), so
# check that the provider SDKs exist. (With SDKs left over from an earlier
# run this cannot catch a new parse error; preview/up below will.)
for sdk in aws helm kubernetes kubectl random; do
    if [ ! -f "sdks/$sdk/hcl.sdk.json" ]; then
        echo "ERROR: 'pulumi install' did not produce sdks/$sdk/hcl.sdk.json." >&2
        echo "       The HCL most likely failed to parse; run 'pulumi preview' in $LOCAL_DIR to see the error." >&2
        exit 1
    fi
done

log "Selecting stack $PULUMI_STACK"
pulumi stack select --create "$PULUMI_STACK" --non-interactive

if [ "$PREVIEW_ONLY" = "1" ]; then
    log "pulumi preview (ESC env: $ESC_ENV)"
    esc pulumi preview --stack "$PULUMI_STACK" --non-interactive "${EXTRA_ARGS[@]}"
    exit 0
fi

attempt=1
until esc pulumi up --stack "$PULUMI_STACK" --yes --non-interactive "${EXTRA_ARGS[@]}"; do
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        log "FAILED: pulumi up did not succeed after $MAX_ATTEMPTS attempts."
        log "Re-run ./install-pulumi.sh to continue; Pulumi resumes from the recorded state."
        log "If the update was interrupted (not just failed), first run:"
        log "  cd $LOCAL_DIR && pulumi cancel --stack $PULUMI_STACK --yes   # only if an update is still locked"
        log "  pulumi env run $ESC_ENV -- pulumi refresh --stack $PULUMI_STACK --yes --clear-pending-creates"
        exit 1
    fi
    attempt=$((attempt + 1))
    log "pulumi up failed — retrying in ${RETRY_DELAY}s (attempt $attempt/$MAX_ATTEMPTS)..."
    sleep "$RETRY_DELAY"
done

log "SUCCESS: pulumi up completed (attempt $attempt)."
echo ""
pulumi stack output --stack "$PULUMI_STACK" || true
echo ""
echo "Next steps (AWS credentials via ESC):"
echo "  pulumi env run $ESC_ENV -- $(pulumi stack output configure_kubectl --stack "$PULUMI_STACK" 2>/dev/null || echo 'aws eks update-kubeconfig --name <name> --region <region>')"
echo "  pulumi env run $ESC_ENV -- kubectl get pods -n agent-sandbox-system"

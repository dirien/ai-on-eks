name                = "agent-sandbox"
eks_cluster_version = "1.34"

# Demo deployment: us-east-1, the same region the reference agent's Bedrock
# client defaults to (AWS_REGION in the agent SandboxTemplates / agent.py).
region = "us-east-1"

# us-east-1 has 6 AZs. use1-az3 does not host the EKS control plane (the base
# module already filters it for control-plane subnets) and does not offer the
# core node group's m6i/m7i instance types, but the core node group spans all
# secondary subnets. Limiting to the first 3 AZ names keeps every subnet in
# AZs that support both. NOTE: AZ name -> ID mapping is per account; in the
# demo account us-east-1a/b/c = use1-az1/az2/az4. Check yours with
#   aws ec2 describe-availability-zones --region us-east-1 \
#     --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output text
availability_zones_count = 3

# Agent Sandbox primitives — ArgoCD-deployed via the base module
# (see infra/base/terraform/argocd_addons.tf). The controller enables
# Sandbox / SandboxTemplate / SandboxClaim CRDs + reconciler; kro
# enables ResourceGraphDefinition-based composition so customers can
# expose a simpler AgentSandbox CR to their teams. Both are optional
# at the base level and opted-in by this solution.
enable_agent_sandbox  = true
agent_sandbox_version = "v1.0.7" # git tag of kubernetes-sigs/agent-sandbox (helm/ chart + controller image tag)
enable_kro            = true

# Cilium in aws-cni chaining mode — required for chained-egress FQDN
# enforcement on Standard EKS. Auto Mode users should set this to
# false and rely on native ApplicationNetworkPolicy instead (the
# example install.sh auto-detects compute mode and applies the right
# enforcement layer accordingly).
enable_cilium = true

# Standard EKS (not Auto Mode) is the default compute mode. gVisor
# shim installation is handled by a Karpenter NodePool (under
# manifests/) that installs containerd-shim-runsc-v1 via AL2023
# user-data — Auto Mode does not expose equivalent node-level hooks.
# To use Auto Mode instead: flip this flag, set enable_cilium=false,
# and skip the karpenter-nodepool-gvisor manifest. Note that gVisor
# tier is not available on Auto Mode.
enable_eks_auto_mode = false

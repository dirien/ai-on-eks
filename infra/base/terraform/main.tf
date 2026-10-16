provider "aws" {
  region = local.region
}

# Cluster credentials for the in-cluster providers come from an exec
# credential plugin (`aws eks get-token`) instead of a token attribute.
#
# Why exec and not an ephemeral/data `aws_eks_cluster_auth` token:
#   - Pulumi HCL does not support `ephemeral` blocks yet
#     (https://github.com/pulumi/pulumi-hcl/issues/169).
#   - A `data "aws_eks_cluster_auth"` token is only valid for ~15 minutes.
#     A first apply that creates the cluster and then installs Karpenter,
#     ArgoCD and the addons can outlive it (401 Unauthorized), and Pulumi
#     stores provider inputs in state, so a later `pulumi destroy` would
#     re-use the expired token.
#   - exec mints a fresh token on demand, works the same in Terraform and
#     Pulumi HCL, and needs only the AWS CLI v2 on PATH (already a
#     prerequisite of every blueprint).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region, "--output", "json"]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region, "--output", "json"]
    }
  }

  # No provider-level `registries`: the list-nested attribute form
  # (`registries = [{ ... }]`) is rejected by Pulumi HCL
  # (https://github.com/pulumi/pulumi-hcl/issues/687), and the block
  # form it accepts is rejected by Terraform/OpenTofu. The only OCI charts pulled
  # from public.ecr.aws are the two Karpenter releases (karpenter.tf), which
  # now pass repository_username/repository_password themselves.
}

provider "kubectl" {
  apply_retry_count      = 30
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  lazy_load              = true

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region, "--output", "json"]
  }
}

# ECR Public auth tokens are only issued in us-east-1. A data source rather
# than an ephemeral resource so Pulumi HCL can evaluate it (pulumi-hcl#169).
data "aws_ecrpublic_authorization_token" "token" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name                   = var.name
  partition              = data.aws_partition.current.partition
  account_id             = data.aws_caller_identity.current.account_id
  mlflow_name            = "mlflow"
  mlflow_namespace       = "mlflow"
  mlflow_service_account = "mlflow"

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/awslabs/ai-on-eks"
  }
}

resource "random_bytes" "this" {
  length = 2
}

resource "aws_cloudformation_stack" "guidance_deployment_metrics" {
  count         = var.solution_id != null && var.solution_description != null ? 1 : 0
  name          = "tracking-stack-${random_bytes.this.hex}"
  on_failure    = "DO_NOTHING"
  template_body = <<STACK
    {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Description": "(${var.solution_id}) ${var.solution_description}",
        "Resources": {
            "EmptyResource": {
                "Type": "AWS::CloudFormation::WaitConditionHandle"
            }
        }
    }
    STACK
}

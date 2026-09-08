# GitHub Actions CI: ECR repos + OIDC federation so `dev`-branch pushes in
# the 4 app repos can build a Docker image, push it to ECR, and trigger a
# deploy via SSM — without any long-lived AWS keys stored in GitHub.
#
# Deliberately scoped to the `dev` branch only (see docker/README.md's
# floating-:dev-tag convention). qa/prd promotion stays a manual
# `deploy.sh <app> qa <tag>` command, not something this role can trigger.

locals {
  # All 4 app repos assume this one CI role via OIDC — kept as a single list
  # even though react-external-app/react-support-app no longer build a
  # Docker image or deploy via SSM (see public_apps.tf): they still need
  # this role's S3 sync / CloudFront invalidation permissions.
  ci_repos = {
    "node-app"           = "VarunERPSolutions/AIARAP-node-backend"
    "java-app"           = "VarunERPSolutions/AIARAP-spring-backend"
    "react-external-app" = "VarunERPSolutions/AIARAP-external-app"
    "react-support-app"  = "VarunERPSolutions/AIARAP-support-app"
  }

  # GitHub now issues OIDC `sub` claims with immutable org/repo IDs appended
  # (e.g. `VarunERPSolutions@291509345/AIARAP-spring-backend@1353664849`) to
  # prevent claim reuse after a rename. The trust policy below matches both
  # this form and the plain org/repo form, since which one GitHub actually
  # sends isn't guaranteed to stay consistent across all repos/time.
  ci_repos_immutable_id = {
    "node-app"           = "VarunERPSolutions@291509345/AIARAP-node-backend@1353664272"
    "java-app"           = "VarunERPSolutions@291509345/AIARAP-spring-backend@1353664849"
    "react-external-app" = "VarunERPSolutions@291509345/AIARAP-external-app@1353662238"
    "react-support-app"  = "VarunERPSolutions@291509345/AIARAP-support-app@1353662817"
  }

  # Repos that still build a Docker image and deploy it onto an EC2 instance
  # via ECR + SSM. react-external-app/react-support-app moved to S3+CloudFront
  # (public_apps.tf) — the react-app EC2 instance they used to share is being
  # decommissioned, so they're deliberately absent from both maps below.
  ecr_ssm_repos = {
    "node-app" = "VarunERPSolutions/AIARAP-node-backend"
    "java-app" = "VarunERPSolutions/AIARAP-spring-backend"
  }

  # instance_id per app that the CI role is allowed to ssm:SendCommand against.
  ci_deploy_instance_ids = {
    "node-app" = var.node_app_instance_id
    "java-app" = var.java_app_instance_id
  }
}

resource "aws_ecr_repository" "app" {
  for_each             = local.ecr_ssm_repos
  name                 = "varunerp/${each.key}"
  image_tag_mutability = "MUTABLE" # :dev is a floating tag by design

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        [for repo in local.ci_repos : "repo:${repo}:ref:refs/heads/dev"],
        [for repo in local.ci_repos_immutable_id : "repo:${repo}:ref:refs/heads/dev"],
      )
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "github-actions-ci"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

data "aws_iam_policy_document" "github_actions_ci" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      # buildx's attestation/provenance manifest-list push reads back
      # existing manifests/layers even on a fresh push — plain upload
      # actions aren't enough (denied: ecr:BatchGetImage).
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  statement {
    sid     = "SsmDeploy"
    actions = ["ssm:SendCommand"]
    resources = concat(
      [for id in distinct(values(local.ci_deploy_instance_ids)) : "arn:aws:ec2:us-east-1:*:instance/${id}"],
      ["arn:aws:ssm:us-east-1:*:document/AWS-RunShellScript"],
    )
  }

  statement {
    sid       = "SsmStatus"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_ci" {
  name   = "github-actions-ci"
  role   = aws_iam_role.github_actions_ci.id
  policy = data.aws_iam_policy_document.github_actions_ci.json
}

output "github_actions_ci_role_arn" {
  description = "Copy into each of the 4 app repos' AWS_ROLE_ARN GitHub Actions secret."
  value       = aws_iam_role.github_actions_ci.arn
}

output "github_actions_ci_ecr_repos" {
  description = "ECR repo URL per app — used to build the docker build/push tag."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_actions_ci_deploy_instance_ids" {
  description = "Copy the matching value into each repo's EC2_INSTANCE_ID GitHub Actions secret."
  value       = local.ci_deploy_instance_ids
}

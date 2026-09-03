# Lets the 3 dev/test app-server instances pull their own :dev images from
# ECR. They share the pre-existing `TailscaleSSMRole` instance profile (see
# docs/infra/INFRASTRUCTURE_REFERENCE.md §4) which ci.tf's CI role deploys
# through via SSM — but the instance role itself had no ECR permissions,
# so `docker compose pull` on the box failed with "no basic auth
# credentials" even after the image landed in ECR successfully.

data "aws_iam_policy_document" "app_server_ecr_pull" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
}

resource "aws_iam_role_policy" "app_server_ecr_pull" {
  name   = "app-server-ecr-pull"
  role   = "TailscaleSSMRole"
  policy = data.aws_iam_policy_document.app_server_ecr_pull.json
}

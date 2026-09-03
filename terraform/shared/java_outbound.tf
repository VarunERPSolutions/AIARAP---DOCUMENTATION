# Java's actual role per ADR-0017: a nightly OUTBOUND batch worker, not an
# inbound API. It calls out to each Tenant's SAP system to extract
# Invoices/Bills/RFQs/POs into staging tables, then hands off to NestJS via
# SQS — it never receives a call from outside AIARAP, so unlike node/sap
# there's no REST API, Cognito scope, or NLB listener for it in this stack.
#
# What Java actually needs, provisioned here:
#   1. Read access to each Tenant's SAP credentials (tenant_settings.
#      sap_credential_secret_ref / sap_oauth_token_secret_ref) to
#      authenticate outbound to their SAP system.
#   2. Permission to publish the "batch complete" event NestJS consumes.
#
# NOT provisioned here (genuinely outside this stack's reach):
#   - Outbound network egress itself (NAT Gateway / route table) — this
#     Terraform doesn't manage java-app's VPC/subnet, only references it.
#     Most default AWS security groups already allow all outbound; confirm
#     java-app's subnet actually has an internet route before relying on
#     this.
#   - Per-Tenant network path for Tenants requiring private connectivity
#     (VPN/PrivateLink) instead of a public HTTPS endpoint — extend this
#     file with a Transit Gateway VPN attachment per such Tenant if/when
#     one is onboarded; most Tenants should just need the public-internet +
#     OAuth/mTLS path this policy already supports.
#   - Attaching the IAM policy below to java-app's actual instance role,
#     unless you set java_app_iam_role_name.

resource "aws_sqs_queue" "batch_complete" {
  name                       = "aiarap-batch-complete"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400 # 1 day — NestJS is expected to consume promptly; not a durable archive
}

resource "aws_iam_policy" "java_outbound" {
  name        = "aiarap-java-outbound-extraction"
  description = "Lets the Java/Spring Batch nightly extraction service (ADR-0017) read Tenant SAP credentials and publish batch-complete events."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTenantSapCredentials"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.tenant_sap_secret_arn_pattern
      },
      {
        Sid      = "PublishBatchComplete"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.batch_complete.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "java_outbound" {
  count      = var.java_app_iam_role_name != null ? 1 : 0
  role       = var.java_app_iam_role_name
  policy_arn = aws_iam_policy.java_outbound.arn
}

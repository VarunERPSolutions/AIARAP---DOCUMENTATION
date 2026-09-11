# Shared-secret bearer token for the Node -> Java internal call (ADR-0042),
# same "internal" namespace convention flow2.tf already uses
# (varunerp/internal/sf-sap/<env>): one secret per environment, distinct
# from the per-Tenant secrets under aiarap/tenant/*.
#
# Both node-app and java-app read the SAME value for a given environment at
# deploy time via docker/deploy.sh's existing per-app Secrets Manager pull
# (extended to also fetch this secret) — Node sends it as
# `Authorization: Bearer <token>`, Java validates the incoming header
# against its own copy. Rotate by tainting/replacing the random_password
# resource for that environment and redeploying both apps.

resource "random_password" "node_java_internal_token" {
  for_each = var.java_environments
  length   = 48
  special  = false
}

resource "aws_secretsmanager_secret" "node_java_internal" {
  for_each = var.java_environments
  name     = "varunerp/internal/node-java/${each.key}"
}

resource "aws_secretsmanager_secret_version" "node_java_internal" {
  for_each  = var.java_environments
  secret_id = aws_secretsmanager_secret.node_java_internal[each.key].id

  secret_string = jsonencode({
    NODE_JAVA_INTERNAL_TOKEN = random_password.node_java_internal_token[each.key].result
  })
}

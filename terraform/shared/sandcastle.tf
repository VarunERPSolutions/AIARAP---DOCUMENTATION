# Sandcastle pre-merge E2E lane pool — ADR-0041 (docs/adr/0041-sandcastle-pre-merge-e2e-testing-architecture.md).
#
# A "lane" is a complete, isolated request path, pre-provisioned once: one
# API Gateway stage (its own gwPort), one NLB listener + target group, one
# dedicated Cognito pool (sandcastle_cognito.tf), one ephemeral Fargate task
# per run registered into it. N=4 lanes, sized against the realistic 2-3
# concurrent-linked-set case (ADR-0041 §"N (lane pool size)"). Growing N
# later is just adding more identical entries below.
#
# Deliberately attaches to `aws_lb.internal` (networking.tf,
# "varunerp-integration-nlb") and `aws_api_gateway_vpc_link.this` —
# confirmed via `aws apigateway get-integration` against the live
# `varunerp-node-api` that this is the NLB actually wired to the real REST
# API today. `aws_lb.backend`/`backend-vpc-link` (gateway_network.tf) are
# live but NOT connected to any REST API integration currently — do not
# attach lane resources there, they would be unreachable.
#
# Cognito/authorizer piece lives in sandcastle_cognito.tf, reusing
# cognito.tf's existing `local.cognito_groups.syscomms` scope
# ("node.invoke") — no Lambda authorizer code change needed, only an
# additive merge into authorizer.tf's pool_map (one-line change there).

locals {
  # Ports deliberately outside every range already in use: node dev/qa
  # (3001/3002), java dev/qa (4001/4002), react dev (8081/8083), sap dev
  # (8083) — see docker/README.md's host port table and variables.tf's
  # sap_environments.
  sandcastle_lane_ids    = range(1, var.sandcastle_lane_count + 1)
  sandcastle_lane_ports  = { for i in local.sandcastle_lane_ids : i => 3100 + i }
  sandcastle_stage_names = { for i in local.sandcastle_lane_ids : i => "sandcastle-${i}" }
}

# --- API Gateway: one stage per lane, on the EXISTING node deployment ------
# Reuses the same deployment/methods/integrations every other stage shares
# (apis.tf's "one deployment per backend" design) — only gwPort differs.

resource "aws_api_gateway_stage" "sandcastle" {
  for_each = local.sandcastle_stage_names

  rest_api_id   = aws_api_gateway_rest_api.this["node"].id
  deployment_id = aws_api_gateway_deployment.this["node"].id
  stage_name    = each.value

  variables = {
    gwPort = tostring(local.sandcastle_lane_ports[each.key])
  }

  tags = {
    Purpose = "sandcastle-lane"
    Lane    = tostring(each.key)
  }
}

# --- NLB: one listener + target group per lane, on the LIVE-wired NLB ------
# target_type = "ip" (not "instance") — the whole point is a different
# ephemeral Fargate task's IP gets registered/deregistered per run, unlike
# tg-java-app/tg-node-app's hardcoded EC2 instance targets.

resource "aws_lb_target_group" "sandcastle" {
  for_each = local.sandcastle_lane_ports

  name        = "varunerp-node-sc-${each.key}-tg"
  port        = each.value
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol = "HTTP"
    path     = "/health" # matches tg-node-app's existing convention
    port     = "traffic-port"
  }

  tags = {
    Purpose = "sandcastle-lane"
    Lane    = tostring(each.key)
  }
}

resource "aws_lb_listener" "sandcastle" {
  for_each = local.sandcastle_lane_ports

  load_balancer_arn = aws_lb.internal.arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sandcastle[each.key].arn
  }
}

# --- Security group for ephemeral Fargate tasks -----------------------------
# aws_api_gateway_vpc_link (v1, REST API style — unlike apigatewayv2's
# VPC link) has no dedicated per-ENI security group to reference as an
# ingress source the way gateway_backend_access references sg-vpc_link.
# Scoping ingress to the VPC CIDR is the correct equivalent here: nothing
# outside the VPC can reach these tasks regardless (they have a public IP
# only for outbound egress — ECR pull, Cognito calls, GitHub), and every
# lane port is already covered by one rule.
resource "aws_security_group" "sandcastle_task" {
  name        = "sandcastle-task"
  description = "Ephemeral Sandcastle E2E Fargate tasks - inbound from the VPC only (NLB path), no direct internet ingress."
  vpc_id      = var.vpc_id

  tags = {
    Name = "sandcastle-task"
  }
}

resource "aws_vpc_security_group_ingress_rule" "sandcastle_task" {
  for_each = local.sandcastle_lane_ports

  security_group_id = aws_security_group.sandcastle_task.id
  cidr_ipv4         = "172.31.0.0/16" # var.vpc_id's CIDR — see docs/infra/INFRASTRUCTURE_REFERENCE.md §1
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Lane ${each.key} - traffic forwarded from the internal NLB"
}
# Explicit egress required — verified live (2026-09-10) that a Terraform
# aws_security_group with no inline egress block does NOT inherit any AWS
# API default; it results in zero egress rules. Confirmed this is true even
# for gateway_backend_access (gateway_network.tf), which only avoids being
# broken by it because the real EC2 instances it's attached to also carry a
# second security group that separately allows outbound. This SG is the
# only one on the ephemeral Fargate task, so it needs its own explicit
# egress rule: outbound HTTPS for ECR image pulls, Cognito token calls, and
# the app's own outbound calls. Nothing wider than 443 — no other outbound
# port is needed by this task.
resource "aws_vpc_security_group_egress_rule" "sandcastle_task_https" {
  security_group_id = aws_security_group.sandcastle_task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Outbound HTTPS - ECR pull, Cognito, image registry"
}

# --- Lane coordination: DynamoDB, atomic claim/release ----------------------

resource "aws_dynamodb_table" "sandcastle_lanes" {
  name         = "sandcastle-lanes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "lane_id"

  attribute {
    name = "lane_id"
    type = "N"
  }
}

# Seeds the N lane rows as free. Sandcastle's orchestrator only ever does
# conditional UpdateItem calls against these (status = "free" -> "claimed"
# and back) — Terraform owns existence/identity of each row, not its
# runtime status, so this is intentionally NOT recreated/overwritten by a
# later apply once claimed (ignore_changes on the mutable fields).
resource "aws_dynamodb_table_item" "sandcastle_lane" {
  for_each = local.sandcastle_lane_ports # map keyed by lane id (1..N) -> port; only the keys matter here

  table_name = aws_dynamodb_table.sandcastle_lanes.name
  hash_key   = aws_dynamodb_table.sandcastle_lanes.hash_key

  item = jsonencode({
    lane_id    = { N = each.key }
    status     = { S = "free" }
    claimed_by = { S = "" }
    claimed_at = { N = "0" }
  })

  lifecycle {
    ignore_changes = [item]
  }
}

# --- ECS cluster + Fargate task definition template -------------------------
# No ECS cluster existed anywhere in the account (confirmed via
# `aws ecs list-clusters`) — this is genuinely new, not a duplicate.
#
# The task definition below is a TEMPLATE only: `app`'s image is a
# placeholder (the existing `:dev` tag). Every real Sandcastle run
# registers its OWN new revision of this family via RegisterTaskDefinition
# with the actual `sandcastle-<sha>` image built that run, then RunTask
# against that revision — Terraform doesn't (and can't, the image changes
# every run) own the per-run image reference. See ADR-0041 §5 "Per-run flow".

resource "aws_ecs_cluster" "sandcastle" {
  name = "sandcastle"
}

resource "aws_cloudwatch_log_group" "sandcastle_task" {
  name              = "/ecs/sandcastle-node"
  retention_in_days = 7 # short-lived ephemeral task logs, not an audit trail
}

resource "aws_iam_role" "sandcastle_task_execution" {
  name = "sandcastle-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sandcastle_task_execution" {
  role       = aws_iam_role.sandcastle_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task-level role for whatever the app container itself needs at runtime via
# IAM (currently nothing — Cognito auth is client_credentials over HTTP, not
# IAM-based). Kept as an empty, assumable placeholder rather than omitted,
# so a future need doesn't require restructuring the task definition.
resource "aws_iam_role" "sandcastle_task" {
  name = "sandcastle-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_ecs_task_definition" "sandcastle_node" {
  family                   = "sandcastle-node"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"  # 0.5 vCPU
  memory                   = "1024" # 1GB, shared across both containers
  execution_role_arn       = aws_iam_role.sandcastle_task_execution.arn
  task_role_arn            = aws_iam_role.sandcastle_task.arn

  container_definitions = jsonencode([
    {
      # Placeholder image — every real run registers a fresh revision with
      # the actual sandcastle-<sha> tag before RunTask. See file header.
      name      = "app"
      image     = "${aws_ecr_repository.app["node-app"].repository_url}:dev"
      essential = true
      # PORT is set per-run by the orchestrator to match the claimed lane's
      # port (one of 3101-3104) — awsvpc network mode means "postgres" is
      # reachable at localhost from this container. DB_USER/DB_PASSWORD/
      # DB_NAME match the postgres container's own environment below —
      # without these the app has a host/port but no way to actually
      # authenticate. The password is a fixed placeholder here (this
      # template is never run directly — see file header); the per-run
      # RegisterTaskDefinition the orchestrator does before RunTask should
      # override it with a fresh random value per ADR-0041's isolation
      # goal, not reuse this literal across runs — cheap defense-in-depth
      # even though the postgres port has no ingress rule at all (only the
      # lane's app port does, see aws_security_group.sandcastle_task below)
      # and is reachable only from "app" in the same task via localhost.
      environment = [
        { name = "DB_HOST", value = "localhost" },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = "sandcastle" },
        { name = "DB_USER", value = "postgres" },
        { name = "DB_PASSWORD", value = "sandcastle" },
      ]
      dependsOn = [
        { containerName = "postgres", condition = "HEALTHY" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sandcastle_task.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "app"
        }
      }
    },
    {
      # Disposable Postgres, matching the real aiarap RDS instance's engine
      # version (confirmed via `aws rds describe-db-instances`: Postgres
      # 18.3) — never the real RDS instance itself. ADR-0041 §4/§5.
      name      = "postgres"
      image     = "postgres:18"
      essential = true
      environment = [
        { name = "POSTGRES_PASSWORD", value = "sandcastle" },
        { name = "POSTGRES_DB", value = "sandcastle" },
      ]
      # Without this, "app" (which starts as soon as ECS launches both
      # containers, not once postgres is actually ready to accept
      # connections) can race postgres's first-start initialization —
      # postgres:18 takes a few real seconds before it's ready. The
      # dependsOn above on "app" only works if this container actually
      # reports a health status to depend on.
      healthCheck = {
        command     = ["CMD-SHELL", "pg_isready -U postgres"]
        interval    = 5
        timeout     = 5
        retries     = 5
        startPeriod = 10
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sandcastle_task.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "postgres"
        }
      }
    },
  ])
}

output "sandcastle_lane_stage_urls" {
  description = "Public Gateway URL per lane — the orchestrator's smoke test target once a lane's Fargate task is registered and healthy."
  value = {
    for i, stage in aws_api_gateway_stage.sandcastle :
    i => "https://${aws_api_gateway_rest_api.this["node"].id}.execute-api.us-east-1.amazonaws.com/${stage.stage_name}"
  }
}

output "sandcastle_lanes_table_name" {
  value = aws_dynamodb_table.sandcastle_lanes.name
}

output "sandcastle_cluster_name" {
  value = aws_ecs_cluster.sandcastle.name
}

output "sandcastle_task_definition_family" {
  value = aws_ecs_task_definition.sandcastle_node.family
}

output "sandcastle_task_security_group_id" {
  value = aws_security_group.sandcastle_task.id
}

# Internal Node -> Java service path (ADR-0042). One internal NLB in front
# of N Java instances per environment — production runs >=2 for horizontal
# capacity/availability, dev/qa may run 1 today using the identical shape
# (var.java_environments). Node talks only to this LB's own DNS name
# (java_internal_lb_dns_name output, in outputs.tf) — it has no
# instance-level knowledge of which or how many Java instances exist.
#
# Deliberately NOT reachable from API Gateway/VPC Link — Java stays a
# private, non-Tenant-facing service (ADR-0039/ADR-0042). This replaces the
# old gateway_network.tf, which wired java_app behind the external-facing
# VPC Link used by node/sap. That wiring was confirmed orphaned (it
# contradicted main.tf's and variables.tf's already-tracked Java-outbound-
# only decision, both of which postdate it) and has been removed outright,
# not left in place unreferenced — see ADR-0042 §0 for the full
# reconciliation. node_app's target group/listener from that file were also
# dropped as redundant: node already has its own real external-facing
# target group in networking.tf, and Node is the *caller* here, never a
# target behind this LB.

resource "aws_lb" "java_internal" {
  name               = "java-internal-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.app_server_subnet_ids

  tags = {
    Name = "java-internal-nlb"
  }
}

# One target group + listener per environment, all on the same LB — same
# "one LB, one listener per (backend, env)" idiom networking.tf already
# uses for node/sap, just for Java's own set of environments/ports.
resource "aws_lb_target_group" "java" {
  for_each = var.java_environments

  name        = "tg-java-${each.key}"
  port        = each.value.port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  preserve_client_ip = true # required for the SG-reference rule below to see the real caller's SG membership

  health_check {
    protocol = "HTTP"
    path     = "/actuator/health"
    port     = "traffic-port"
  }
}

resource "aws_lb_listener" "java" {
  for_each = var.java_environments

  load_balancer_arn = aws_lb.java_internal.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.java[each.key].arn
  }
}

locals {
  # Flatten {env: {instance_ids: [...], port}} -> one entry per (env,
  # instance) — a target group attachment is one resource per instance, not
  # per environment, since production's list can hold >=2.
  java_targets = merge([
    for env, cfg in var.java_environments : {
      for idx, id in cfg.instance_ids : "${env}-${idx}" => { env = env, instance_id = id }
    }
  ]...)

  # Excludes any env still carrying a PLACEHOLDER instance_id (java_environments.prd
  # today) — mirrors main.tf's check-block tolerance for node-prd/sap-dev:
  # the environment/LB/listener/target-group shape exists and can be
  # planned, but no data source or attachment ever queries a fake ID.
  java_targets_real = { for k, v in local.java_targets : k => v if !strcontains(v.instance_id, "PLACEHOLDER") }

  java_placeholder_envs = distinct([
    for k, v in local.java_targets : v.env if strcontains(v.instance_id, "PLACEHOLDER")
  ])
}

check "no_placeholder_java_instances" {
  assert {
    condition     = length(local.java_placeholder_envs) == 0
    error_message = "java_environments still has a PLACEHOLDER instance_id for: ${join(", ", local.java_placeholder_envs)} — replace before applying against real infrastructure."
  }
}

resource "aws_lb_target_group_attachment" "java" {
  for_each = local.java_targets_real

  target_group_arn = aws_lb_target_group.java[each.value.env].arn
  target_id        = each.value.instance_id
  port             = var.java_environments[each.value.env].port
}

# --- Security: only node-app's own security group may reach the Java -----
# --- port(s); the LB's own health-check probes get a narrow subnet-CIDR --
# --- allowance instead, since NLB nodes carry no SG identity to reference -
#
# Deliberately var.node_app_security_group_id (a fixed, known-permanent SG),
# NOT a live `data.aws_instance` lookup of whatever's attached to node-app
# right now. Confirmed via a real scoped plan (2026-09): node-app's live
# instance still carries the OLD gateway_backend_access SG as a leftover
# from the exact setup this file replaces — that SG is destroyed in this
# same apply, so a rule referencing it as a source would create a real
# apply-ordering risk (AWS refuses to delete a security group still
# referenced by another rule). The genuine, permanent SG is the
# hand-created "dev-test-app-servers" group already documented in
# INFRASTRUCTURE_REFERENCE.md §2 — reference that directly instead.

resource "aws_security_group" "java_internal_access" {
  name        = "java-internal-lb-access"
  description = "Grants the node-app security group access to the Java internal LB and instances. No CIDR-based rule for real traffic - only the health-check exception below, scoped to the LB subnets."
  vpc_id      = var.vpc_id

  tags = {
    Name = "java-internal-lb-access"
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_to_java" {
  for_each = var.java_environments

  security_group_id            = aws_security_group.java_internal_access.id
  referenced_security_group_id = var.node_app_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "Allow node-app (${each.key}) to reach the Java internal LB/instances on its matching port"
}

data "aws_subnet" "java_lb_subnet" {
  for_each = toset(var.app_server_subnet_ids)
  id       = each.value
}

resource "aws_vpc_security_group_ingress_rule" "java_healthcheck" {
  for_each = {
    for pair in setproduct(keys(var.java_environments), keys(data.aws_subnet.java_lb_subnet)) :
    "${pair[0]}-${pair[1]}" => {
      port = var.java_environments[pair[0]].port
      cidr = data.aws_subnet.java_lb_subnet[pair[1]].cidr_block
    }
  }

  security_group_id = aws_security_group.java_internal_access.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Allow java-internal-nlb health-check probes for this env/port (NLB nodes carry no SG membership) - scoped to its own subnet CIDR, not VPC-wide"
}

resource "aws_network_interface_sg_attachment" "java" {
  for_each = data.aws_instance.java_app_env

  security_group_id    = aws_security_group.java_internal_access.id
  network_interface_id = each.value.network_interface_id
}

data "aws_instance" "java_app_env" {
  for_each    = local.java_targets_real
  instance_id = each.value.instance_id
}

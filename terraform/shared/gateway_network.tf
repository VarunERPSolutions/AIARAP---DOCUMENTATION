# Internal NLB + VPC Link so the future API Gateway (ADR-0003) can reach
# java-app/node-app/react-app without those instances becoming directly
# reachable — satisfies ADR-0005's "backends unreachable except through the
# gateway" requirement.
#
# Deliberately does NOT touch `sg-0dfb6d3af8165709a` (the existing
# hand-created app-servers SG, not Terraform-managed) — a new SG is created
# here instead and attached to each instance's existing primary network
# interface alongside it, via aws_network_interface_sg_attachment. Tailscale
# access (which bypasses security groups entirely) is unaffected either way.
#
# Traffic path this enforces: API Gateway -> VPC Link ENIs (sg: vpc_link) ->
# internal NLB (no SG of its own — enforcement happens at the target) ->
# EC2 instance (sg: gateway_backend_access, referencing sg: vpc_link as the
# allowed source). This only works because NLB target groups preserve the
# original client (VPC Link ENI) source IP by default for same-VPC instance
# targets — set explicitly below via preserve_client_ip, not left implicit,
# since the security-group-reference rule depends on it.

# --- Security groups -------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "api-gateway-vpc-link"
  description = "Attached to the API Gateway VPC Link ENIs. Referenced (not owned) by gateway_backend_access ingress rules as the allowed source."
  vpc_id      = var.vpc_id

  # No ingress needed — this SG identifies a source, not a destination.
  # Egress left to the default (allow-all) rule AWS creates on a new SG.

  tags = {
    Name = "api-gateway-vpc-link"
  }
}

resource "aws_security_group" "gateway_backend_access" {
  name        = "gateway-backend-access"
  description = "New, Terraform-managed SG granting the API Gateway VPC Link access to the app ports. Attached alongside (not replacing) sg-0dfb6d3af8165709a."
  vpc_id      = var.vpc_id

  # No egress rules here — sg-0dfb6d3af8165709a (already attached to every
  # instance) already permits all outbound; SG rules union across every SG
  # attached to an ENI, so this group only needs to add the inbound it owns.

  tags = {
    Name = "gateway-backend-access"
  }
}

locals {
  # port -> which target group's traffic it represents, used to generate
  # both the ingress rules and the NLB listeners/target groups below.
  backend_ports = {
    java_app       = 4001
    node_app       = 3001
    react_external = 8081
    react_support  = 8083
  }
}

resource "aws_vpc_security_group_ingress_rule" "gateway_backend_access" {
  for_each = local.backend_ports

  security_group_id            = aws_security_group.gateway_backend_access.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "Allow ${each.key} traffic from the API Gateway VPC Link only"
}

# --- Attach the new SG to each instance's existing ENI (additive only) -----

data "aws_instance" "java_app" {
  instance_id = var.java_app_instance_id
}

data "aws_instance" "node_app" {
  instance_id = var.node_app_instance_id
}

data "aws_instance" "react_app" {
  instance_id = var.react_app_instance_id
}

resource "aws_network_interface_sg_attachment" "java_app" {
  security_group_id    = aws_security_group.gateway_backend_access.id
  network_interface_id = data.aws_instance.java_app.network_interface_id
}

resource "aws_network_interface_sg_attachment" "node_app" {
  security_group_id    = aws_security_group.gateway_backend_access.id
  network_interface_id = data.aws_instance.node_app.network_interface_id
}

resource "aws_network_interface_sg_attachment" "react_app" {
  security_group_id    = aws_security_group.gateway_backend_access.id
  network_interface_id = data.aws_instance.react_app.network_interface_id
}

# --- Internal NLB -----------------------------------------------------------

resource "aws_lb" "backend" {
  name               = "backend-internal-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.app_server_subnet_ids

  tags = {
    Name = "backend-internal-nlb"
  }
}

# --- Target groups (one per backend port; react-app gets two — one ---------
# instance serving both frontends on different host ports) ------------------

resource "aws_lb_target_group" "java_app" {
  name        = "tg-java-app"
  port        = local.backend_ports.java_app
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  preserve_client_ip = true # required — see file header note on why

  health_check {
    protocol = "HTTP"
    path     = "/actuator/health"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group" "node_app" {
  name        = "tg-node-app"
  port        = local.backend_ports.node_app
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  preserve_client_ip = true

  health_check {
    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group" "react_external" {
  name        = "tg-react-external"
  port        = local.backend_ports.react_external
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  preserve_client_ip = true

  health_check {
    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group" "react_support" {
  name        = "tg-react-support"
  port        = local.backend_ports.react_support
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  preserve_client_ip = true

  health_check {
    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group_attachment" "java_app" {
  target_group_arn = aws_lb_target_group.java_app.arn
  target_id        = var.java_app_instance_id
  port             = local.backend_ports.java_app
}

resource "aws_lb_target_group_attachment" "node_app" {
  target_group_arn = aws_lb_target_group.node_app.arn
  target_id        = var.node_app_instance_id
  port             = local.backend_ports.node_app
}

resource "aws_lb_target_group_attachment" "react_external" {
  target_group_arn = aws_lb_target_group.react_external.arn
  target_id        = var.react_app_instance_id
  port             = local.backend_ports.react_external
}

resource "aws_lb_target_group_attachment" "react_support" {
  target_group_arn = aws_lb_target_group.react_support.arn
  target_id        = var.react_app_instance_id
  port             = local.backend_ports.react_support
}

# --- NLB listeners (one per port, TCP passthrough to matching target group)-

resource "aws_lb_listener" "java_app" {
  load_balancer_arn = aws_lb.backend.arn
  port              = local.backend_ports.java_app
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.java_app.arn
  }
}

resource "aws_lb_listener" "node_app" {
  load_balancer_arn = aws_lb.backend.arn
  port              = local.backend_ports.node_app
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.node_app.arn
  }
}

resource "aws_lb_listener" "react_external" {
  load_balancer_arn = aws_lb.backend.arn
  port              = local.backend_ports.react_external
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.react_external.arn
  }
}

resource "aws_lb_listener" "react_support" {
  load_balancer_arn = aws_lb.backend.arn
  port              = local.backend_ports.react_support
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.react_support.arn
  }
}

# --- VPC Link ----------------------------------------------------------------
# HTTP API-style VPC Link (aws_apigatewayv2_vpc_link), chosen over the older
# REST API VPC Link because it takes explicit security_group_ids/subnet_ids
# for its own ENIs — the REST API version only takes an NLB ARN with no SG
# control, which is what the security-group-reference design above depends on.
#
# The actual HTTP API resource, its routes, and Cognito authorizer are
# deliberately NOT part of this file — that's the next step once this
# scaffold is applied, done separately per ADR-0003/0004.

resource "aws_apigatewayv2_vpc_link" "backend" {
  name               = "backend-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.app_server_subnet_ids

  tags = {
    Name = "backend-vpc-link"
  }
}

# --- Outputs, for wiring the future HTTP API's integrations ------------------

output "gateway_vpc_link_id" {
  description = "Pass to the HTTP API's integration resources (integration_type = HTTP_PROXY, connection_type = VPC_LINK)."
  value       = aws_apigatewayv2_vpc_link.backend.id
}

output "gateway_nlb_listener_arns" {
  description = "One per backend port — the integration_uri target for each route."
  value = {
    java_app       = aws_lb_listener.java_app.arn
    node_app       = aws_lb_listener.node_app.arn
    react_external = aws_lb_listener.react_external.arn
    react_support  = aws_lb_listener.react_support.arn
  }
}

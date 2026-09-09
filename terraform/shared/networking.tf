# One internal NLB shared by every backend x environment (one listener/
# target group per entry in local.backend_envs), fronted by one VPC Link
# shared by every REST API — API Gateway's VPC_LINK connection type requires
# an NLB; it can't point at an instance IP directly.
resource "aws_lb" "internal" {
  name               = "varunerp-integration-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "varunerp-integration-vpc-link"
  target_arns = [aws_lb.internal.arn]
}

resource "aws_lb_target_group" "backend" {
  for_each    = local.backend_envs
  name        = "varunerp-${each.key}-tg"
  port        = each.value.port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"
}

resource "aws_lb_target_group_attachment" "backend" {
  for_each         = local.backend_envs
  target_group_arn = aws_lb_target_group.backend[each.key].arn
  target_id        = each.value.instance_id
  port             = each.value.port

  # Hard block (unlike main.tf's check "no_placeholder_instances", which is
  # only a warning — check blocks never fail plan/apply) — this only ever
  # evaluates for a backend_envs entry that's actually part of the current
  # plan/apply, so a scoped apply that never touches "sap-*" or "node-prd"
  # entries is completely unaffected by a placeholder still sitting in
  # var.sap_proxy_instance_id/var.node_environments.prd.
  lifecycle {
    precondition {
      condition     = !strcontains(each.value.instance_id, "PLACEHOLDER")
      error_message = "backend_envs[\"${each.key}\"].instance_id is still a placeholder (\"${each.value.instance_id}\") — supply a real instance ID before applying this resource."
    }
  }
}

resource "aws_lb_listener" "backend" {
  for_each          = local.backend_envs
  load_balancer_arn = aws_lb.internal.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend[each.key].arn
  }
}

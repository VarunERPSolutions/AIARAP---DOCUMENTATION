# Grants varunerp-integration-nlb (networking.tf) SG-level access to reach
# node-app on the port(s) its target group(s) actually use. This was a real
# gap, not a deliberate design: networking.tf's aws_lb_target_group /
# aws_lb_target_group_attachment / aws_lb_listener resources for node-dev
# have existed and been applied, but nothing anywhere granted the NLB's own
# ENIs inbound access to reach the instance — INFRASTRUCTURE_REFERENCE.md
# §2 documents node-app's security group ("dev-test-app-servers",
# sg-0dfb6d3af8165709a, hand-created — not a Terraform resource, referenced
# here by ID only) as intentionally carrying no inbound rules at all,
# correct for its original Tailscale-only admin-access design but stale
# the moment the NLB/API-Gateway integration path was added on top of it.
#
# Confirmed live 2026-09-11: with no inbound rule, the NLB target showed
# Target.FailedHealthChecks (unhealthy) even though the instance and
# container were completely healthy locally (localhost:3001/health = 200)
# — the NLB's own ENIs, not Tailscale, are what need to reach this port,
# and they were flatly blocked. Every real /me call through API Gateway
# failed with a 500 after an ~11s hang as a result.
#
# Scoped to the NLB's own subnet CIDRs (var.private_subnet_ids), not the
# whole VPC and not 0.0.0.0/0 — same restriction shape java_internal_lb.tf
# already established for the newer Java-internal NLB
# (aws_vpc_security_group_ingress_rule.java_healthcheck). This is real
# health-check + proxied-traffic access, not an admin/SSH path — Tailscale
# is unrelated and unaffected by this change.
#
# node-dev (port 3001) only — that's the only backend_envs entry with a
# target group actually applied against this instance today (verified via
# `aws elbv2 describe-target-groups`). node_environments also declares
# node-qa (port 3002, variables.tf: "shares the instance with dev"), but no
# node-qa target group exists live yet, so no rule for it here — add an
# identical entry, `for_each` over the same subnets, once that target group
# is actually applied. Don't open a port with no live listener behind it.

data "aws_subnet" "node_nlb" {
  for_each = toset(var.private_subnet_ids)
  id       = each.value
}

resource "aws_vpc_security_group_ingress_rule" "node_dev_nlb_healthcheck" {
  for_each = data.aws_subnet.node_nlb

  security_group_id = "sg-0dfb6d3af8165709a" # dev-test-app-servers, hand-created — see INFRASTRUCTURE_REFERENCE.md §2
  cidr_ipv4         = each.value.cidr_block
  ip_protocol       = "tcp"
  from_port         = 3001
  to_port           = 3001
  description       = "Allow varunerp-integration-nlb health-check/proxy traffic to node-dev (/me) from its own subnet ${each.key}"
}

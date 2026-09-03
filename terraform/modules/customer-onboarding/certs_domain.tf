# Two SANs: bare apex (prod) + wildcard (any other single-label prefix,
# e.g. dev/qa). A wildcard does NOT cover the apex, so both must be
# requested explicitly on the same certificate.
resource "aws_acm_certificate" "customer" {
  domain_name               = "${var.customer_id}.${var.base_domain}"
  subject_alternative_names = ["*.${var.customer_id}.${var.base_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.customer.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "customer" {
  certificate_arn         = aws_acm_certificate.customer.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# "prd" = bare apex subdomain; every other environment gets a prefix. One
# domain object PER ENVIRONMENT now, not apex+wildcard — dev and qa route to
# DIFFERENT stages of the shared REST API (node-app/java-app dev and qa run
# as separate containers even when they share an instance — see
# docker/README.md), and base_path_mapping is a static (domain, path) ->
# (api, stage) binding that can't pick a stage based on which subdomain was
# hit. A single wildcard domain object can no longer serve both.
locals {
  env_domain_name = {
    for env in var.environments :
    env => env == "prd" ? "${var.customer_id}.${var.base_domain}" : "${env}.${var.customer_id}.${var.base_domain}"
  }
}

resource "aws_api_gateway_domain_name" "env" {
  for_each                 = local.env_domain_name
  domain_name              = each.value
  regional_certificate_arn = aws_acm_certificate_validation.customer.certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_route53_record" "env_alias" {
  for_each = local.env_domain_name
  zone_id  = var.route53_zone_id
  name     = aws_api_gateway_domain_name.env[each.key].domain_name
  type     = "A"

  alias {
    name                   = aws_api_gateway_domain_name.env[each.key].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.env[each.key].regional_zone_id
    evaluate_target_health = false
  }
}

# One mapping per (environment, backend) — e.g. dev.custXX.aiarap.com/node
# routes to node-api's "dev" stage. base_path is still the backend name
# (stripped before the request reaches the API, same reason as before);
# stage_name is now the environment directly, since stage IS environment by
# convention in the shared stack.
resource "aws_api_gateway_base_path_mapping" "env_backend" {
  for_each = {
    for pair in setproduct(var.environments, local.backends) :
    "${pair[0]}-${pair[1]}" => { env = pair[0], backend = pair[1] }
  }

  domain_name = aws_api_gateway_domain_name.env[each.value.env].domain_name
  api_id      = var.api_ids[each.value.backend]
  stage_name  = each.value.env
  base_path   = each.value.backend
}

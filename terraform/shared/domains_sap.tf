# Public domains for the SAP APIs — deliberately NOT reusing
# sapdev.varunerpsolutions.com / sap.varunerpsolutions.com. Those already
# mean something else (the SAP boxes' own Tailscale/MagicDNS names,
# published in real DNS but resolving to unroutable 100.64.0.0/10
# addresses — see INFRASTRUCTURE_REFERENCE.md). Salesforce has no tailnet
# access, so it needs a genuinely public endpoint, which these are.
#
# Naming mirrors the aiarap.com convention: bare = prod, prefixed = non-prod.
locals {
  sap_domain_name = {
    for env in keys(var.sap_environments) :
    env => env == "prd" ? "sap-api.varunerpsolutions.com" : "${env}.sap-api.varunerpsolutions.com"
  }
  sap_domain_names_list = [for env in keys(var.sap_environments) : local.sap_domain_name[env]]
}

# One cert covering every provisioned SAP environment's domain. Adding a new
# environment (e.g. "prd") changes the SAN list, which forces a new
# certificate + revalidation — expect a brief window where the SAP APIs are
# unreachable while DNS validation completes, when that day comes.
resource "aws_acm_certificate" "sap_api" {
  domain_name               = local.sap_domain_names_list[0]
  subject_alternative_names = slice(local.sap_domain_names_list, 1, length(local.sap_domain_names_list))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "sap_api_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.sap_api.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.varunerpsolutions_com_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true

  # Hard block, unlike a check block (which only warns) — only evaluates
  # when this specific resource is actually part of the current plan/apply,
  # so a scoped apply that never touches SAP domain resources is unaffected.
  lifecycle {
    precondition {
      condition     = var.varunerpsolutions_com_zone_id != "PLACEHOLDER-ZONE-ID"
      error_message = "varunerpsolutions_com_zone_id is still a placeholder — supply the real Route53 zone ID before applying SAP's domain resources."
    }
  }
}

resource "aws_acm_certificate_validation" "sap_api" {
  certificate_arn         = aws_acm_certificate.sap_api.arn
  validation_record_fqdns = [for r in aws_route53_record.sap_api_cert_validation : r.fqdn]
}

resource "aws_api_gateway_domain_name" "sap" {
  for_each                 = var.sap_environments
  domain_name              = local.sap_domain_name[each.key]
  regional_certificate_arn = aws_acm_certificate_validation.sap_api.certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Root mapping (no base_path) — each domain maps 1:1 to the sap API's
# environment-matching stage, so there's no base-path-stripping ambiguity.
resource "aws_api_gateway_base_path_mapping" "sap" {
  for_each    = var.sap_environments
  domain_name = aws_api_gateway_domain_name.sap[each.key].domain_name
  api_id      = aws_api_gateway_rest_api.this["sap"].id
  stage_name  = each.key
}

resource "aws_route53_record" "sap_alias" {
  for_each = var.sap_environments
  zone_id  = var.varunerpsolutions_com_zone_id
  name     = aws_api_gateway_domain_name.sap[each.key].domain_name
  type     = "A"

  alias {
    name                   = aws_api_gateway_domain_name.sap[each.key].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.sap[each.key].regional_zone_id
    evaluate_target_health = false
  }

  lifecycle {
    precondition {
      condition     = var.varunerpsolutions_com_zone_id != "PLACEHOLDER-ZONE-ID"
      error_message = "varunerpsolutions_com_zone_id is still a placeholder — supply the real Route53 zone ID before applying SAP's domain resources."
    }
  }
}

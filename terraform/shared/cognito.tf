resource "aws_cognito_user_pool" "shared" {
  name = "varunerp-integration-pool"
}

# Cognito custom domains require the cert in us-east-1 regardless of the
# pool's own region — matches this account's region already, so no cross-
# region provider alias needed.
resource "aws_acm_certificate" "auth_domain" {
  domain_name       = "auth.varunerpsolutions.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "auth_domain_validation" {
  for_each = {
    for dvo in aws_acm_certificate.auth_domain.domain_validation_options : dvo.domain_name => {
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
}

resource "aws_acm_certificate_validation" "auth_domain" {
  certificate_arn         = aws_acm_certificate.auth_domain.arn
  validation_record_fqdns = [for r in aws_route53_record.auth_domain_validation : r.fqdn]
}

resource "aws_cognito_user_pool_domain" "auth" {
  domain          = "auth.varunerpsolutions.com"
  certificate_arn = aws_acm_certificate_validation.auth_domain.certificate_arn
  user_pool_id    = aws_cognito_user_pool.shared.id
}

resource "aws_route53_record" "auth_domain_alias" {
  zone_id = var.varunerpsolutions_com_zone_id
  name    = aws_cognito_user_pool_domain.auth.domain
  type    = "A"

  alias {
    name                   = aws_cognito_user_pool_domain.auth.cloudfront_distribution
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront's fixed hosted zone ID — same in every account/region
    evaluate_target_health = false
  }
}

resource "aws_cognito_resource_server" "node" {
  identifier   = "https://api.aiarap.com/node"
  name         = "node-api"
  user_pool_id = aws_cognito_user_pool.shared.id

  scope {
    scope_name        = "node.invoke.dev"
    scope_description = "Invoke Node API — dev"
  }
  scope {
    scope_name        = "node.invoke.qa"
    scope_description = "Invoke Node API — qa"
  }
  scope {
    scope_name        = "node.invoke.prd"
    scope_description = "Invoke Node API — prd"
  }
}

resource "aws_cognito_resource_server" "java" {
  identifier   = "https://api.aiarap.com/java"
  name         = "java-api"
  user_pool_id = aws_cognito_user_pool.shared.id

  scope {
    scope_name        = "java.invoke.dev"
    scope_description = "Invoke Java API — dev"
  }
  scope {
    scope_name        = "java.invoke.qa"
    scope_description = "Invoke Java API — qa"
  }
  scope {
    scope_name        = "java.invoke.prd"
    scope_description = "Invoke Java API — prd"
  }
}

# Declared upfront for both dev and prd even though SAP prod isn't
# provisioned yet — the scope is just a permission string, harmless to have
# before the backend exists, and one less thing to remember when SAP prod
# does go live.
resource "aws_cognito_resource_server" "sap" {
  identifier   = "https://api.varunerpsolutions.com/sap"
  name         = "sap-api"
  user_pool_id = aws_cognito_user_pool.shared.id

  scope {
    scope_name        = "sap.invoke.dev"
    scope_description = "Invoke SAP API — dev"
  }
  scope {
    scope_name        = "sap.invoke.prd"
    scope_description = "Invoke SAP API — prd (not yet provisioned)"
  }
}

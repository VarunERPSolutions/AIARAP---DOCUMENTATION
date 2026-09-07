# S3 + CloudFront + ACM hosting for both portal apps, across every
# environment — react-external-app (Payer/Vendor/Tenant User portal) and
# react-support-app (AIARAP support staff), per ADR-0033. Both go public,
# all three environments, no Tailscale involved at all (see
# architecture-diagram.html Figure 5).
#
# Deliberately NOT covered here (see that ADR's open items and
# 0021-parking-lot.md #55/#56/#58): the two new Cognito scopes
# (node.portal.<env>, node.support.<env>) and app clients these apps
# authenticate with, path-scoping the shared Lambda authorizer across three
# scopes now sharing one stage, and the CI/CD rework to actually build and
# upload to the buckets below. This file only stands up the hosting target
# those depend on.
module "portal_app" {
  source = "../modules/spa-hosting"

  app_name        = "react-external-app"
  subdomain       = "portal"
  route53_zone_id = var.aiarap_com_zone_id
}

module "support_app" {
  source = "../modules/spa-hosting"

  app_name        = "react-support-app"
  subdomain       = "support"
  route53_zone_id = var.aiarap_com_zone_id
}

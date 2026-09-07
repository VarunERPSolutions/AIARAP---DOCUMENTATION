variable "app_name" {
  description = "Human-readable app name, used only in the CloudFront distribution's comment field (e.g. \"react-external-app\")."
  type        = string
}

variable "subdomain" {
  description = "This app's subdomain label (e.g. \"portal\", \"support\") — combined with base_domain to form its domain per environment."
  type        = string
}

variable "base_domain" {
  description = "Base domain this app is served under."
  type        = string
  default     = "aiarap.com"
}

variable "route53_zone_id" {
  description = "Hosted zone ID for base_domain."
  type        = string
}

variable "environments" {
  description = "Environments to provision. \"prd\" is treated as the bare subdomain ({subdomain}.{base_domain}); every other entry gets a prefix ({env}.{subdomain}.{base_domain}) — same convention as modules/tenant-onboarding."
  type        = list(string)
  default     = ["dev", "qa", "prd"]
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (US/Canada/Europe edge locations only) is the cost-conscious default — widen if a Tenant's user base needs broader edge coverage."
  type        = string
  default     = "PriceClass_100"
}

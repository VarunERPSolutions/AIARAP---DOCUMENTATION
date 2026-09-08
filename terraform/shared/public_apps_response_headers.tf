# CloudFront Response Headers Policy per app — security headers + a CSP
# derived from actually inspecting each app's built output and source
# (confirmed: no inline <script>/<style>, no dangerouslySetInnerHTML in
# either app; both use Google Fonts via a <link> in index.html).
#
# Cognito/auth is deferred (this phase's scope) — neither CSP references any
# Cognito endpoint, since nothing in either app's code calls one yet.

locals {
  # connect-src per app: react_external makes no live API calls today (its
  # env.ts/API-gateway config is dead code — see the architecture audit), so
  # 'self' is sufficient. react_support's one live call
  # (src/api/customers.ts) targets a Tailscale-only hostname over plain
  # HTTP; it's listed here so the browser's CSP doesn't block it, but this
  # call already fails independently due to browser mixed-content blocking
  # (an HTTPS page cannot fetch an http:// resource) — a pre-existing issue,
  # tied to the deferred Support API redesign, not something CSP can fix or
  # is trying to fix.
  spa_csp = {
    react_external = "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
    react_support  = "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' http://java-app.tail14147c.ts.net:4001; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
  }
}

resource "aws_cloudfront_response_headers_policy" "spa" {
  for_each = local.spa_apps

  name    = "${each.value.bucket_name}-security-headers"
  comment = "Baseline production security headers + app-specific CSP."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false # opt-in HSTS preload-list submission is a separate, deliberate step — not done here
      override                   = true
    }

    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    content_security_policy {
      content_security_policy = local.spa_csp[each.key]
      override                = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), payment=()"
      override = true
    }
  }
}

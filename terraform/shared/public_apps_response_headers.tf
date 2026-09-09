# CloudFront Response Headers Policy per app — security headers + a CSP
# derived from actually inspecting each app's built output and source
# (confirmed: no inline <script>/<style>, no dangerouslySetInnerHTML in
# either app; both use Google Fonts via a <link> in index.html).
#
# Cognito/auth: each app's connect-src includes ONLY its own pool's Hosted
# UI domain (ADR-0040) — react_external -> portal-dev, react_support ->
# support-dev, never each other's or any of the other 7 (inactive) pools'.
# Added 2026-09-09 after a live PKCE test caught the actual browser error:
# the token-exchange fetch() to /oauth2/token was being silently blocked by
# this CSP, which predated any Cognito call existing in either app's code.
#
# node API Gateway: react_support now also calls the real node/dev REST API
# (GET /me — the ScopeGuard smoke-test endpoint) directly from the browser,
# so its execute-api hostname needs connect-src too. Same discovery
# mechanism as the Cognito fix above — added proactively this time rather
# than waiting to hit the same CSP block again. react_external's
# env.apiGatewayUrl is still dead code, not added here.

locals {
  # connect-src per app: react_external's only live call is now the Cognito
  # token exchange (its env.ts/API-gateway config is still dead code — see
  # the architecture audit — that's unrelated and unchanged here).
  # react_support has three: the Cognito token exchange, the real node API
  # Gateway call, and its pre-existing Tailscale-only java-app call
  # (src/api/customers.ts) — the latter already fails independently via
  # browser mixed-content blocking (HTTPS page, http:// resource), a
  # pre-existing issue tied to the deferred Support API redesign, not
  # something this CSP change touches.
  spa_csp = {
    react_external = "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://varunerp-portal-dev.auth.us-east-1.amazoncognito.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
    react_support  = "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://varunerp-support-dev.auth.us-east-1.amazoncognito.com https://hn0omem2c0.execute-api.us-east-1.amazonaws.com http://java-app.tail14147c.ts.net:4001; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
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

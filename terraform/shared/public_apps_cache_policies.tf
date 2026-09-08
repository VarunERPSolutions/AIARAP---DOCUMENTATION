# Deliberate two-tier caching for the SPA distributions (public_apps.tf).
# Vite's build output (confirmed by actually building both apps) is:
#   dist/index.html              — not content-hashed, must revalidate every deploy
#   dist/assets/*.[hash].{js,css} — content-hashed, safe to cache forever
#   dist/favicon.svg, icons.svg   — unhashed, low-churn, moderate cache is enough
#
# Two cache policies, applied per-path in public_apps.tf's distribution:
#   - spa_immutable_assets: /assets/* only
#   - spa_default: everything else (index.html + the two unhashed root files)
# The actual Cache-Control header is set at upload time in each app's
# deploy-dev.yml (belt-and-suspenders — see that file's comments); these
# policies also cap what CloudFront will hold even if that header is ever
# missing or wrong.

resource "aws_cloudfront_cache_policy" "spa_immutable_assets" {
  name        = "spa-immutable-assets"
  comment     = "Long-lived caching for Vite's content-hashed /assets/* files — a new deploy never reuses a filename, so a 1-year TTL is safe."
  min_ttl     = 31536000
  default_ttl = 31536000
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    # These only affect whether Accept-Encoding is part of the *cache key* —
    # actual response compression is controlled independently by each cache
    # behavior's compress=true (see public_apps.tf) and works regardless.
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

resource "aws_cloudfront_cache_policy" "spa_default" {
  name        = "spa-default-no-cache"
  comment     = "index.html and any other unhashed file — always revalidate so a new deploy is visible immediately."
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    # AWS rejects enable_accept_encoding_* = true on a policy with all-zero
    # TTLs ("InvalidArgument: ... invalid for policy with caching disabled").
    # Irrelevant here anyway — response compression itself still happens via
    # each cache behavior's compress=true, independent of this cache-key setting.
    enable_accept_encoding_gzip   = false
    enable_accept_encoding_brotli = false
  }
}

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

# NOTE: the policy NAME still says "no-cache" for a reason — renaming a
# cache policy in place would churn the two distributions that reference it
# for no functional gain. The behaviour is described accurately in `comment`.
resource "aws_cloudfront_cache_policy" "spa_default" {
  name    = "spa-default-no-cache"
  comment = "Unhashed files: browser revalidates every load; edge may cache. Deploy invalidates /index.html."

  # max_ttl = 0 previously meant CloudFront could NEVER cache index.html no
  # matter what header the origin sent — every single page load went all the
  # way back to S3 (measured: ~430 ms TTFB, "Miss from cloudfront" on 100% of
  # loads, warm or cold). Raising max_ttl does NOT weaken freshness, because:
  #   - default_ttl stays 0, so an object with NO Cache-Control is still
  #     treated as uncacheable — the safe default is unchanged;
  #   - index.html is uploaded with max-age=0, must-revalidate, so every
  #     browser still revalidates on every load and can never show stale HTML;
  #   - s-maxage=1y lets only the SHARED (edge) cache hold it, and deploy-dev.yml
  #     already invalidates /index.html on every deploy, which is what evicts it.
  # Net effect: the browser's revalidation is answered by the edge instead of
  # by S3. Same freshness guarantee, one less origin round trip.
  min_ttl     = 0
  default_ttl = 0
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
    # Now that max_ttl is non-zero this policy is no longer "caching disabled",
    # so AWS accepts these — and they matter: without them the edge would hold
    # a single encoding of index.html and hand it to every client.
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

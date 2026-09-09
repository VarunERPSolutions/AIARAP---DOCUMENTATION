"use strict";

const { CognitoJwtVerifier } = require("aws-jwt-verify");

// The authorizer's full trust allowlist (ADR-0040), keyed by Cognito pool
// ID: { "<poolId>": { "group": "support"|"portal"|"syscomms", "env": "dev"|"qa"|"prd" } }.
// Populated by Terraform (cognito.tf's cognito_pool_map) from the pools it
// actually created — this file never invents or extends this list at
// runtime. A token's unverified `iss` claim is used ONLY to pick which of
// these pre-configured entries to attempt verification against; an iss
// that doesn't match any key here is denied before any JWKS fetch or
// signature check happens at all. See the module README for the full
// design writeup.
const POOL_MAP = JSON.parse(process.env.POOL_MAP || "{}");

// apiId -> backend name ("node" | "sap"). One REST API per backend — dev/
// qa/prd are STAGES of that one API, not separate APIs, so the stage name
// IS the environment. No Host-header parsing needed.
const API_BACKEND_MAP = JSON.parse(process.env.API_BACKEND_MAP || "{}");

// One verifier per trusted pool, built once at cold start — not per
// request, and not on first use per pool either. CognitoJwtVerifier.create()
// itself doesn't fetch JWKS eagerly (that happens, and is cached in-memory
// for the life of this warm container, on that pool's first .verify()
// call), so pre-building all of them here costs nothing extra over the old
// single-pool version beyond one object per trusted pool — at most 9 today.
// clientId: null is REQUIRED (not merely optional) by the installed
// aws-jwt-verify version — omitting it entirely throws "clientId must be
// provided or set to null explicitly" at verify() time, unconditionally,
// for every token. Confirmed live via CloudWatch logs (2026-09-09): every
// prior verification attempt failed on this before ever reaching the
// token's actual signature/claims. null explicitly means "accept a token
// from any app client in this pool" — the scope claim, not client
// identity, is what actually gates access to a given backend/group.
const verifiers = Object.fromEntries(
  Object.keys(POOL_MAP).map((poolId) => [
    poolId,
    CognitoJwtVerifier.create({ userPoolId: poolId, tokenUse: "access", clientId: null }),
  ])
);

// group -> which backend(s) it's permitted to call, and the scope name it
// needs on each. This is authorization LOGIC (what a group even means),
// deliberately kept in code rather than threaded through as another env
// var the way POOL_MAP/API_BACKEND_MAP are (those are deployment-specific
// data; this is a fixed rule). Must stay in sync with cognito.tf's
// local.cognito_groups — same shape, same three groups.
const GROUP_SCOPES = {
  support: { node: "node.support" },
  portal: { node: "node.portal" },
  syscomms: { node: "node.invoke", sap: "sap.invoke" },
};

exports.handler = async (event) => {
  const requestId = event.requestContext && event.requestContext.requestId;

  try {
    const token = extractBearerToken(event.headers);
    if (!token) {
      return deny(event, "no bearer token in Authorization header");
    }

    const unverifiedIss = decodeUnverifiedIssuer(token);
    if (!unverifiedIss) {
      return deny(event, "token has no decodable issuer");
    }

    // Step 1 of 2: SELECT a pre-configured, trusted verifier by matching
    // the token's own (not-yet-verified) issuer against POOL_MAP's known
    // pool IDs. This is a lookup into a fixed allowlist Terraform built —
    // it never extends trust to whatever a token happens to claim. No
    // cryptographic check has happened yet at this point.
    const matchedPoolId = Object.keys(POOL_MAP).find((poolId) =>
      unverifiedIss.endsWith(`/${poolId}`)
    );
    if (!matchedPoolId) {
      console.error(`[${requestId}] issuer "${unverifiedIss}" does not match any provisioned pool`);
      return deny(event, "unrecognized token issuer");
    }

    // Step 2 of 2: VERIFY — the only step that actually trusts the token.
    // Full cryptographic check (signature against that specific pool's own
    // JWKS, expiry, token_use: access) via aws-jwt-verify, which
    // independently re-derives the expected issuer from userPoolId+region
    // and checks the token's iss against THAT — so a spoofed/mismatched iss
    // fails here even if step 1's lookup were somehow tricked. Step 1 only
    // ever picked which verifier to run; it is not itself a trust decision.
    let claims;
    try {
      claims = await verifiers[matchedPoolId].verify(token);
    } catch (err) {
      console.error(`[${requestId}] token verification failed: ${err.message}`);
      return deny(event, "token verification failed");
    }

    const pool = POOL_MAP[matchedPoolId]; // { group, env }

    const apiId = event.requestContext && event.requestContext.apiId;
    const backend = API_BACKEND_MAP[apiId];
    if (!backend) {
      console.error(`[${requestId}] apiId "${apiId}" not in API_BACKEND_MAP`);
      return deny(event, "unrecognized API");
    }

    const stage = event.requestContext && event.requestContext.stage;
    if (!stage) {
      console.error(`[${requestId}] request has no stage in requestContext`);
      return deny(event, "unrecognized stage");
    }

    // The pool that issued this (now cryptographically verified) token has
    // to match the environment being called — a syscomms-dev-issued token
    // can't authenticate to prd, even before checking scope, because there
    // is no per-environment suffix left on the scope string to catch that
    // (ADR-0040 dropped it; the pool itself is what encodes environment
    // now).
    if (pool.env !== stage) {
      console.error(`[${requestId}] pool env "${pool.env}" does not match stage "${stage}"`);
      return deny(event, "token's pool does not match this environment");
    }

    // And the pool's group has to be one actually permitted to call this
    // backend at all — support/portal pools are node-only; syscomms pools
    // may call node or sap.
    const requiredScope = GROUP_SCOPES[pool.group] && GROUP_SCOPES[pool.group][backend];
    if (!requiredScope) {
      console.error(`[${requestId}] group "${pool.group}" is not permitted to call backend "${backend}"`);
      return deny(event, "token's pool group cannot call this backend");
    }

    const grantedScopes = (claims.scope || "").split(" ").filter(Boolean);
    const hasScope = grantedScopes.some(
      (s) => s === requiredScope || s.endsWith(`/${requiredScope}`)
    );

    if (!hasScope) {
      console.error(
        `[${requestId}] client "${claims.client_id}" missing "${requiredScope}" ` +
          `(has: ${grantedScopes.join(", ") || "none"})`
      );
      return deny(event, "insufficient scope", claims.client_id);
    }

    return allow(event, claims.client_id, {
      clientId: claims.client_id,
      backend,
      environment: stage,
      group: pool.group,
      scope: requiredScope,
    });
  } catch (err) {
    console.error(`[${requestId}] authorizer error: ${err.stack || err.message}`);
    return deny(event, "internal error");
  }
};

// Decodes the JWT payload WITHOUT verifying the signature — used only to
// read `iss` well enough to pick a verifier in step 1 above. Never treated
// as trustworthy on its own; see the handler's step 2 for the actual
// verification this feeds into.
function decodeUnverifiedIssuer(token) {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    return typeof payload.iss === "string" ? payload.iss : null;
  } catch {
    return null;
  }
}

function extractBearerToken(headers) {
  const raw = getHeader(headers, "authorization");
  if (!raw || !/^Bearer\s+/i.test(raw)) return null;
  return raw.replace(/^Bearer\s+/i, "").trim();
}

function getHeader(headers, name) {
  if (!headers) return undefined;
  const key = Object.keys(headers).find((k) => k.toLowerCase() === name.toLowerCase());
  return key ? headers[key] : undefined;
}

function allow(event, principalId, context) {
  return {
    principalId,
    policyDocument: policy("Allow", event.methodArn),
    context,
  };
}

function deny(event, reason, principalId = "unauthorized") {
  return {
    principalId,
    policyDocument: policy("Deny", event.methodArn),
    context: { denyReason: reason },
  };
}

// Wildcards to every method/resource in the invoking API+stage, not just the
// one method that triggered this call — the decision only ever depends on
// (matched pool, apiId, stage), never on which specific operation was hit,
// so this stays safe if authorizer caching is ever turned on later.
function policy(effect, methodArn) {
  const [arnPrefix, stage] = methodArn.split("/");
  return {
    Version: "2012-10-17",
    Statement: [
      {
        Action: "execute-api:Invoke",
        Effect: effect,
        Resource: `${arnPrefix}/${stage}/*/*`,
      },
    ],
  };
}

// Exposed for unit testing only — the Lambda runtime only ever calls .handler.
exports._internal = { extractBearerToken, getHeader, policy, decodeUnverifiedIssuer };

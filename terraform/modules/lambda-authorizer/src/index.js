"use strict";

const { CognitoJwtVerifier } = require("aws-jwt-verify");

const USER_POOL_ID = process.env.COGNITO_USER_POOL_ID;

// apiId -> backend name ("node" | "java" | "sap"). One REST API per backend
// now — dev/qa/prd are STAGES of that one API (via stage-variable-driven
// integrations), not separate APIs, so the stage name IS the environment.
// No Host-header parsing needed: requestContext.stage tells us directly.
const API_BACKEND_MAP = JSON.parse(process.env.API_BACKEND_MAP || "{}");

// token_use "access" = client_credentials access tokens. clientId is left
// unset so any app client in the pool can present a token — the scope
// claim, not the client identity, is what gates access to a given
// backend/environment.
const verifier = CognitoJwtVerifier.create({
  userPoolId: USER_POOL_ID,
  tokenUse: "access",
});

exports.handler = async (event) => {
  const requestId = event.requestContext && event.requestContext.requestId;

  try {
    const token = extractBearerToken(event.headers);
    if (!token) {
      return deny(event, "no bearer token in Authorization header");
    }

    let claims;
    try {
      claims = await verifier.verify(token);
    } catch (err) {
      console.error(`[${requestId}] token verification failed: ${err.message}`);
      return deny(event, "token verification failed");
    }

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

    const requiredScope = `${backend}.invoke.${stage}`;
    const grantedScopes = (claims.scope || "").split(" ").filter(Boolean);
    const hasScope = grantedScopes.some(
      (s) => s === requiredScope || s.endsWith(`/${requiredScope}`)
    );

    if (!hasScope) {
      console.error(
        `[${requestId}] client "${claims.client_id}" missing scope "${requiredScope}" ` +
          `(has: ${grantedScopes.join(", ") || "none"})`
      );
      return deny(event, "insufficient scope", claims.client_id);
    }

    return allow(event, claims.client_id, {
      clientId: claims.client_id,
      backend,
      environment: stage,
      scope: requiredScope,
    });
  } catch (err) {
    console.error(`[${requestId}] authorizer error: ${err.stack || err.message}`);
    return deny(event, "internal error");
  }
};

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
// (token scope, apiId, stage), never on which specific operation was hit,
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
exports._internal = { extractBearerToken, getHeader, policy };

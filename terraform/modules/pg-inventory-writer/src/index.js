"use strict";

const { Client } = require("pg");
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");

const DB_HOST = process.env.DB_HOST;
const DB_PORT = Number(process.env.DB_PORT || "5432");
const DB_NAME = process.env.DB_NAME;
// Deliberately the app's own `global` schema (ADR-0004), not a competing
// one — this is AIARAP-internal cross-Tenant governance metadata (Cognito
// client IDs, API key IDs, secret ARNs), the same category of data as
// global.tenant_registry/global.aiarap_staff, not Tenant business data
// that needs schema-per-tenant isolation.
const DB_SCHEMA = process.env.DB_SCHEMA || "global";
const DB_SECRET_ARN = process.env.DB_SECRET_ARN;

const smClient = new SecretsManagerClient({});
let cachedCreds; // reused across warm invocations of the same execution environment

// One table, not a table-per-Tenant-tracking-table — tenant_subdomain is a
// plain column, deliberately NOT a foreign key into global.tenant_registry.
// That table is owned and migrated by the main app (NestJS), not this
// Lambda; FK'ing into it would create a migration-ordering dependency
// between two separately-deployed projects (this Lambda erroring if it
// runs before the app's own migration has created tenant_registry, or vice
// versa). tenant_subdomain is the same natural key as
// global.tenant_registry.subdomain, so a manual join/audit across both is
// still trivial — just not enforced at the DB level.
const MIGRATION_SQL = `
CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};

CREATE TABLE IF NOT EXISTS ${DB_SCHEMA}.integration_connection (
  connection_id     text PRIMARY KEY,
  tenant_subdomain  text NOT NULL,
  connection_key    text NOT NULL,
  backend           text NOT NULL,
  environment       text NOT NULL,
  cognito_client_id text NOT NULL,
  api_key_id        text NOT NULL,
  usage_plan_id     text NOT NULL,
  secret_arn        text NOT NULL,
  status            text NOT NULL DEFAULT 'active',
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS integration_connection_tenant_subdomain_idx
  ON ${DB_SCHEMA}.integration_connection (tenant_subdomain);
`;

// Invoked two ways by Terraform:
//   1. { action: "migrate" }                      -- once, at shared-stack apply time (CREATE_ONLY + triggers)
//   2. { <connection fields>, tf: { action } }     -- once per connection (lifecycle_scope = "CRUD")
exports.handler = async (event) => {
  const client = await connect();
  try {
    if (event.action === "migrate") {
      await client.query(MIGRATION_SQL);
      return { ok: true, ran: "migration" };
    }

    const tfAction = event.tf && event.tf.action; // "create" | "update" | "delete" | undefined
    const data = tfAction === "delete" ? event.tf.prev_input || event : event;

    if (tfAction === "delete") {
      await client.query(
        `DELETE FROM ${DB_SCHEMA}.integration_connection WHERE connection_id = $1`,
        [data.connection_id]
      );
      return { ok: true, ran: "delete", connection_id: data.connection_id };
    }

    await upsertConnection(client, data);
    return { ok: true, ran: tfAction || "create", connection_id: data.connection_id };
  } finally {
    await client.end();
  }
};

async function upsertConnection(client, data) {
  await client.query(
    `INSERT INTO ${DB_SCHEMA}.integration_connection
       (connection_id, tenant_subdomain, connection_key, backend, environment,
        cognito_client_id, api_key_id, usage_plan_id, secret_arn, status, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now())
     ON CONFLICT (connection_id) DO UPDATE SET
       tenant_subdomain  = EXCLUDED.tenant_subdomain,
       connection_key    = EXCLUDED.connection_key,
       backend           = EXCLUDED.backend,
       environment       = EXCLUDED.environment,
       cognito_client_id = EXCLUDED.cognito_client_id,
       api_key_id        = EXCLUDED.api_key_id,
       usage_plan_id     = EXCLUDED.usage_plan_id,
       secret_arn        = EXCLUDED.secret_arn,
       status            = EXCLUDED.status,
       updated_at        = now()`,
    [
      data.connection_id,
      data.tenant_subdomain,
      data.connection_key,
      data.backend,
      data.environment,
      data.cognito_client_id,
      data.api_key_id,
      data.usage_plan_id,
      data.secret_arn,
      data.status || "active",
    ]
  );
}

async function connect() {
  const creds = await getDbCredentials();
  const client = new Client({
    host: DB_HOST,
    port: DB_PORT,
    database: DB_NAME,
    user: creds.username,
    password: creds.password,
    // Encrypts in transit. Not verified against the RDS CA bundle here for
    // simplicity — tighten to `rejectUnauthorized: true, ca: <RDS CA bundle>`
    // if your compliance posture requires full chain verification.
    ssl: { rejectUnauthorized: false },
  });
  await client.connect();
  return client;
}

async function getDbCredentials() {
  if (cachedCreds) return cachedCreds;
  const resp = await smClient.send(new GetSecretValueCommand({ SecretId: DB_SECRET_ARN }));
  cachedCreds = JSON.parse(resp.SecretString);
  return cachedCreds;
}

// Exposed for unit testing only — the Lambda runtime only ever calls .handler.
exports._internal = { MIGRATION_SQL };

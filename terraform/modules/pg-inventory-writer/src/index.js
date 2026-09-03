"use strict";

const { Client } = require("pg");
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");

const DB_HOST = process.env.DB_HOST;
const DB_PORT = Number(process.env.DB_PORT || "5432");
const DB_NAME = process.env.DB_NAME;
const DB_SCHEMA = process.env.DB_SCHEMA || "integration_inventory";
const DB_SECRET_ARN = process.env.DB_SECRET_ARN;

const smClient = new SecretsManagerClient({});
let cachedCreds; // reused across warm invocations of the same execution environment

const MIGRATION_SQL = `
CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};

CREATE TABLE IF NOT EXISTS ${DB_SCHEMA}.customers (
  customer_id text PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ${DB_SCHEMA}.connections (
  connection_id     text PRIMARY KEY,
  customer_id       text NOT NULL REFERENCES ${DB_SCHEMA}.customers(customer_id),
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

CREATE INDEX IF NOT EXISTS connections_customer_id_idx
  ON ${DB_SCHEMA}.connections (customer_id);
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
        `DELETE FROM ${DB_SCHEMA}.connections WHERE connection_id = $1`,
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
    `INSERT INTO ${DB_SCHEMA}.customers (customer_id)
     VALUES ($1)
     ON CONFLICT (customer_id) DO NOTHING`,
    [data.customer]
  );

  await client.query(
    `INSERT INTO ${DB_SCHEMA}.connections
       (connection_id, customer_id, connection_key, backend, environment,
        cognito_client_id, api_key_id, usage_plan_id, secret_arn, status, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now())
     ON CONFLICT (connection_id) DO UPDATE SET
       customer_id       = EXCLUDED.customer_id,
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
      data.customer,
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

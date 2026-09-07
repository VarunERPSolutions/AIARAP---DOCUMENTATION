# Dev/qa isolation on a shared instance

`node-app` and `java-app` each run as two independent containers on the
same EC2 box — one per environment — so a dev deploy is structurally
incapable of touching qa.

**Open item ([ADR-0033](../docs/adr/0033-public-portal-support-app-exposure.md))**:
the two React apps' section below (Docker/nginx on the shared `react-app`
EC2 instance, dev-only) is the old model — both apps are moving to
S3+CloudFront across all three environments, public internet. This
doc/pipeline hasn't been reworked for that yet (still describes the
image-build + SSM-deploy path); treat the React portions below as
dev/legacy until that migration lands.

## Layout

```
docker/
├── deploy.sh
├── node-app/
│   ├── dev/  { docker-compose.yml, .env.example }
│   └── qa/   { docker-compose.yml, .env.example }
├── java-app/
│   ├── dev/  { docker-compose.yml, .env.example }
│   └── qa/   { docker-compose.yml, .env.example }
├── react-external-app/
│   └── dev/  { docker-compose.yml }
└── react-support-app/
    └── dev/  { docker-compose.yml }
```

The two React apps are static nginx builds — no `.env`/`.env.secrets`
(anything they need is baked in at `npm run build` time, see each repo's
`Dockerfile`), and no `qa/` yet — CI only drives the `dev` branch today (see
the repos' `.github/workflows/deploy-dev.yml`); qa promotion for them is a
deliberate follow-up, same as it already is for node-app/java-app.

Each `docker-compose.yml` is a **separate compose project** — its own
directory, its own container name, its own Docker network. There is
deliberately no single top-level compose file listing all four services:
that would make a bare `docker compose up -d` (run from the wrong
directory, or by habit) capable of restarting everything on the box at
once. Every deploy command must `cd` into one specific `<app>/<env>/`
directory first — `deploy.sh` does exactly that and nothing else.

## Host ports

| App | Env | Container port | Host port |
|---|---|---|---|
| node-app | dev | 3000 | 3001 |
| node-app | qa | 3000 | 3002 |
| java-app | dev | 8080 | 4001 |
| java-app | qa | 8080 | 4002 |
| react-external-app | dev | 80 | 8081 |
| react-support-app | dev | 80 | 8083 |

Both React apps' dev containers share the `react-app` EC2 instance (see
`docs/infra/INFRASTRUCTURE_REFERENCE.md` §2) — host ports 8082/8084 are
reserved for their future `qa` environments, not yet created.

**node-app's** host ports are NLB `target_port`s — `terraform/shared`
registers them directly, since node-app receives inbound Tenant/Salesforce
calls.

**java-app's** host ports are *not* NLB targets. Per ADR-0017, Java/Spring
Batch is a nightly outbound-only worker (it calls out to each Tenant's SAP
system; it never receives inbound calls) — there's no Tenant-facing API,
Cognito scope, or NLB listener for it at all (see
`terraform/shared/java_outbound.tf`). These ports exist only for
local health checks/monitoring (e.g. Spring Boot Actuator) if the service
exposes one — not part of any routing path.

## What's actually isolated, and how

- **Process & filesystem**: separate containers, separate directories — a
  dev image pull/restart never touches the qa container's filesystem or
  process.
- **Resources**: `mem_limit`/`cpus` per service, so a dev load test can't
  starve qa of CPU/memory on the shared box.
- **Data**: separate `DB_SCHEMA` per environment (`.env.example` files) —
  point these at genuinely separate schemas on the `aiarap` instance, not
  the same one with a naming convention nobody enforces.
- **Deploy blast radius**: `deploy.sh <app> <env>` only ever operates on one
  compose project. There's no "restart everything" command in this layout.
- **What qa actually tests**: dev floats on a `:dev` tag, rebuilt on every
  merge. qa does **not** — its compose file requires an explicit
  `NODE_QA_TAG`/`JAVA_QA_TAG` (a specific commit SHA) and fails loudly if
  it's unset, so qa's environment can't silently shift out from under
  testers just because dev rebuilt. Promoting to qa is a deliberate command:
  `./deploy.sh node-app qa a1b2c3d`.

## Secrets

`.env` (committed as `.env.example`, real values gitignored) holds
non-secret config. Actual secrets are never written to a file that touches
git — `deploy.sh` pulls them from Secrets Manager
(`varunerp/<app>/<env>`) into `.env.secrets` on every deploy, which
`docker-compose.yml` also loads via `env_file`.

**Prerequisite**: `deploy.sh` needs `jq` on the deploy box — confirmed
missing in this environment when testing the script here (`jq: command not
found`); install it before relying on this on the real host. The script's
`|| touch .env.secrets` fallback means a missing/inaccessible secret
doesn't crash the deploy, just leaves that environment without secrets
until it's fixed — don't mistake a silently-empty `.env.secrets` for "no
secrets needed."

## Note on testing this

Running `deploy.sh` here (to check its error handling) made one real,
read-only call to Secrets Manager under the `tailscale_VarunERP` IAM user —
it correctly failed with `AccessDeniedException` (that user isn't
provisioned for `secretsmanager:GetSecretValue` on this path) and the
script's fallback handled it cleanly. No AWS state was read or changed;
flagging it since it did leave this session's context, unlike everything
else validated so far.

# shared stack

The once-created infrastructure that `tenant-onboarding` (per Tenant) and
everything in `modules/` assume already exists: Cognito, the 2 per-backend
inbound REST APIs, the shared authorizer wiring, the internal NLB, Java's
separate outbound extraction infrastructure, and the inventory writer.

## The core design: 2 inbound REST APIs, N stages

There's one REST API per **inbound backend** (`node`, `sap`), not per
(backend, environment). Every environment is a **stage** of that one API,
and each stage carries its own `gwPort` stage variable — the integration
URI is `http://<nlb-dns>:${stageVariables.gwPort}/...`, resolved by API
Gateway per-request from whichever stage handled the call. One deployment
per backend (resources/methods/integrations are identical across its
environments); the stages are what differ.

**Java is not one of these two.** Per [ADR-0017](../../docs/adr/0017-sap-batch-extraction-java-spring-batch.md),
Java/Spring Batch is a nightly **outbound-only** worker — it calls out to
each Tenant's SAP system to extract data, it never receives an inbound
call. It has no REST API, no Cognito scope, no NLB listener. Its
infrastructure (an SQS handoff queue + IAM policy for reading Tenant SAP
credentials) lives in `java_outbound.tf` instead — see that file's header
comment for what is and isn't provisioned there.

This design is what keeps the inbound API/authorizer count at 2 even
though there are several physically distinct destinations
(`local.backend_envs`: node-dev, node-qa, sap-dev — growing to
node-prd/sap-prd as those get provisioned) — each gets its own NLB
listener/target group and its own stage, but not its own REST API.

**The authorizer is simple as a result**: since stage *is* environment by
convention, `event.requestContext.stage` tells the Lambda authorizer the
environment directly — no Host-header parsing, no fixed-per-apiId config.
`api_backend_map` is just `{ "<apiId>": "<backend name>" }`.

## What this creates

- **Cognito**: one user pool, custom domain (`auth.varunerpsolutions.com`),
  two resource servers (`node-api`, `sap-api`) with their scopes — no
  `java-api`.
- **One internal NLB + VPC Link**, with one listener/target group per entry
  in `local.backend_envs`.
- **2 REST APIs** (`node`, `sap`), each with a proxying `{proxy+}`
  resource, the shared Lambda authorizer attached, one deployment, and one
  stage per environment that backend has provisioned.
- **Public domains for the SAP stages** (`sap-api.varunerpsolutions.com` =
  prod, `dev.sap-api.varunerpsolutions.com` = dev — deliberately distinct
  from `sap.varunerpsolutions.com`/`sapdev.varunerpsolutions.com`, which are
  the SAP boxes' own Tailscale-only hostnames, unreachable from the public
  internet). Node doesn't get a public domain here — that's created per
  Tenant by `tenant-onboarding`, pointed at `output.api_ids` (one ID per
  backend, same for every environment — only the *stage* differs).
- **`modules/lambda-authorizer`**, wired to both REST APIs via
  `api_backend_map`, reserved concurrency set from
  `var.authorizer_reserved_concurrency` so a dev/test traffic spike can't
  starve prod of Lambda capacity.
- **`modules/pg-inventory-writer`**, VPC-attached to reach `aiarap` RDS,
  writing into the app's own `global` schema (ADR-0004) — not a competing
  schema — with the RDS security group auto-wired for it if you provide
  `aiarap_db_security_group_id`.
- **`java_outbound.tf`**: the SQS batch-complete queue and the IAM policy
  Java's nightly extraction actually needs (Secrets Manager read on Tenant
  SAP credentials, SQS publish) — not an inbound API.
- **Flow 2** (VarunERP's own Salesforce → SAP): one Cognito app client +
  secret per provisioned SAP environment — doesn't fit
  `tenant-onboarding` (that's shaped for external Tenants on
  `aiarap.com`), so it's wired directly here instead.

## Required inputs you'll need to supply — nothing here has a silently-guessed default for account-specific values

| Variable | Why it's not defaulted |
|---|---|
| `private_subnet_ids` | Not documented anywhere available to this session |
| `sap_proxy_instance_id` | Genuinely your call — reuse `aws-subnet-router` or stand up a new box |
| `varunerpsolutions_com_zone_id` | Route53 zone ID, account-specific |
| `aiarap_db_instance_identifier`, `aiarap_db_name`, `aiarap_db_secret_arn` | RDS specifics not in INFRASTRUCTURE_REFERENCE.md |

`node_environments` defaults to `dev`+`qa` pointed at the existing
documented instance (`i-0e8bb91b84754d419`) on the ports the `docker/`
compose layout binds to (3001/3002), **plus a `prd` entry with a
placeholder `instance_id`** (`i-PLACEHOLDER-node-prd`) — prod is confirmed
to be its own dedicated instance, but isn't provisioned yet, so the shape
is here without a real target. Two `check` blocks in `main.tf` guard this:
`no_placeholder_instances` warns while any `PLACEHOLDER` value remains, and
`prd_not_sharing_devqa_instance` warns if `prd` is ever pointed at the same
box as dev/qa. Replace the placeholder with the real instance ID once it
exists — nothing else needs to change to pick it up.

`var.tenant_sap_secret_arn_pattern` (in `java_outbound.tf`) is a **guessed**
resource pattern for Tenant SAP credential secrets — not confirmed against
whatever the app's own secret-creation code actually uses. Verify before
relying on it; a wrong pattern means Java's IAM policy either grants too
little (extraction fails with AccessDenied) or, if too broad, more than it
should.

## Explicitly out of scope here

- **The tailnet-proxy's own nginx/socat config** — `var.sap_environments`'
  `port` values are just NLB target ports; something on
  `sap_proxy_instance_id` actually has to forward each of those ports into
  the Tailscale overlay to the right SAP HANA instance. That's server
  config, not Terraform, and isn't built here.
- **node-app's own dev/qa isolation** — see `docker/README.md`. This stack
  only assumes each environment listens on its own host port; how that's
  enforced on the box (separate containers, resource limits, separate
  deploy pipelines) is a deployment concern, not an AWS one.
- **Java's actual outbound network path per Tenant** — `java_outbound.tf`
  grants the *credentials* access; it doesn't provision NAT Gateway egress
  or a Transit Gateway VPN attachment for Tenants requiring private
  connectivity. Most Tenants should work over the public-internet +
  OAuth/mTLS path this policy already supports; extend that file for any
  Tenant that genuinely needs private connectivity instead.
- **Attaching `java_outbound_policy_arn` to java-app's instance role** —
  automatic only if you set `java_app_iam_role_name`; otherwise it's just
  an output for you to attach yourself.

## Growing to a new environment

Add the entry to the relevant `*_environments` map (`prd = { instance_id =
"...", port = ... }` for node, `prd = { port = ... }` for sap — plus, for
SAP, pointing the tailnet-proxy's new stream block at
`sap.varunerpsolutions.com`) and `terraform apply`. This fans out
automatically: NLB listener/target, stage (with its `gwPort` variable), and
— for SAP — the public domain (forces an SAP-API cert replacement, so
expect brief downtime during revalidation) and flow 2's second Cognito
client. The Cognito scope for that environment already exists from day one
for both backends.

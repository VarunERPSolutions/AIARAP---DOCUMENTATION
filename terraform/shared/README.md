# shared stack

The once-created infrastructure that `customer-onboarding` (per customer)
and everything in `modules/` assume already exists: Cognito, the 3
per-backend REST APIs, the shared authorizer wiring, the internal NLB, and
the inventory writer.

## The core design: 3 REST APIs, 8 stages

There's one REST API per **backend** (`node`, `java`, `sap`), not per
(backend, environment). Every environment is a **stage** of that one API,
and each stage carries its own `gwPort` stage variable — the integration
URI is `http://<nlb-dns>:${stageVariables.gwPort}/...`, resolved by API
Gateway per-request from whichever stage handled the call. One deployment
per backend (resources/methods/integrations are identical across its
environments); the stages are what differ.

This is what keeps the API/authorizer count at 3 even though there are 8
physically distinct destinations today (`local.backend_envs`: node-dev,
node-qa, java-dev, java-qa, sap-dev — growing to node-prd/java-prd/sap-prd
as those get provisioned) — each of those 8 gets its own NLB
listener/target group and its own stage, but not its own REST API.

**The authorizer got simpler as a result**: since stage *is* environment by
convention, `event.requestContext.stage` tells the Lambda authorizer the
environment directly — no more Host-header parsing, no more the
`requires_env`-vs-fixed-`env` config split the SAP-only version needed.
`api_backend_map` is now just `{ "<apiId>": "<backend name>" }`.

## What this creates

- **Cognito**: one user pool, custom domain (`auth.varunerpsolutions.com`),
  three resource servers (`node-api`, `java-api`, `sap-api`) with their
  scopes.
- **One internal NLB + VPC Link**, with one listener/target group per entry
  in `local.backend_envs` (8 today).
- **3 REST APIs** (`node`, `java`, `sap`), each with a proxying `{proxy+}`
  resource, the shared Lambda authorizer attached, one deployment, and one
  stage per environment that backend has provisioned.
- **Public domains for the SAP stages** (`sap-api.varunerpsolutions.com` =
  prod, `dev.sap-api.varunerpsolutions.com` = dev — deliberately distinct
  from `sap.varunerpsolutions.com`/`sapdev.varunerpsolutions.com`, which are
  the SAP boxes' own Tailscale-only hostnames, unreachable from the public
  internet). Node/java don't get public domains here — those are created
  per customer by `customer-onboarding`, pointed at `output.api_ids` (one
  ID per backend, same for every environment — only the *stage* differs).
- **`modules/lambda-authorizer`**, wired to all 3 REST APIs via
  `api_backend_map`, reserved concurrency set from
  `var.authorizer_reserved_concurrency` so a dev/test traffic spike can't
  starve prod of Lambda capacity.
- **`modules/pg-inventory-writer`**, VPC-attached to reach `aiarap` RDS,
  with the RDS security group auto-wired for it if you provide
  `aiarap_db_security_group_id`.
- **Flow 2** (VarunERP's own Salesforce → SAP): one Cognito app client +
  secret per provisioned SAP environment — doesn't fit
  `customer-onboarding` (that's shaped for external customers on
  `aiarap.com`), so it's wired directly here instead.

## Required inputs you'll need to supply — nothing here has a silently-guessed default for account-specific values

| Variable | Why it's not defaulted |
|---|---|
| `private_subnet_ids` | Not documented anywhere available to this session |
| `sap_proxy_instance_id` | Genuinely your call — reuse `aws-subnet-router` or stand up a new box |
| `varunerpsolutions_com_zone_id` | Route53 zone ID, account-specific |
| `aiarap_db_instance_identifier`, `aiarap_db_name`, `aiarap_db_secret_arn` | RDS specifics not in INFRASTRUCTURE_REFERENCE.md |

`node_environments`/`java_environments` default to `dev`+`qa` pointed at the
existing documented instances (`i-0e8bb91b84754d419`/`i-01afdc2668e71f05b`)
on the ports the `docker/` compose layout binds to (3001/3002, 4001/4002),
**plus a `prd` entry with a placeholder `instance_id`**
(`i-PLACEHOLDER-node-prd` / `i-PLACEHOLDER-java-prd`) — prod is confirmed to
be its own dedicated instance, but isn't provisioned yet, so the shape is
here without a real target. Two `check` blocks in `main.tf` guard this:
`no_placeholder_instances` warns while any `PLACEHOLDER` value remains, and
`prd_not_sharing_devqa_instance` warns if `prd` is ever pointed at the same
box as dev/qa. Replace the placeholder with the real instance ID once it
exists — nothing else needs to change to pick it up.

## Explicitly out of scope here

- **The tailnet-proxy's own nginx/socat config** — `var.sap_environments`'
  `port` values are just NLB target ports; something on
  `sap_proxy_instance_id` actually has to forward each of those ports into
  the Tailscale overlay to the right SAP HANA instance. That's server
  config, not Terraform, and isn't built here.
- **node-app/java-app's own dev/qa isolation** — see `docker/README.md`.
  This stack only assumes each environment listens on its own host port;
  how that's enforced on the box (separate containers, resource limits,
  separate deploy pipelines) is a deployment concern, not an AWS one.

## Growing to a new environment

Add the entry to the relevant `*_environments` map (`prd = { instance_id =
"...", port = ... }` for node/java, `prd = { port = ... }` for sap — plus,
for SAP, pointing the tailnet-proxy's new stream block at
`sap.varunerpsolutions.com`) and `terraform apply`. This fans out
automatically: NLB listener/target, stage (with its `gwPort` variable), and
— for SAP — the public domain (forces an SAP-API cert replacement, so
expect brief downtime during revalidation) and flow 2's second Cognito
client. The Cognito scope for that environment already exists from day one
for all three backends.

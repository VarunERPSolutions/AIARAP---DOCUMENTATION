# VarunERP — AWS + Tailscale Infrastructure Reference

Last updated: 2026-09-03
Companion visual: `architecture-diagram.html` (same folder) — Figure 1 covers
sections 1–9 below (developer/infra-admin access, narrowed by
[ADR-0038](../adr/0038-portal-support-app-public-exposure-domain-cognito-and-signup.md) — see that note
before assuming Tailscale still gates app traffic); Figure 2 covers section 11
(the Tenant integration hub, machine-to-machine only); Figure 5 covers the
public portal/support app access ADR-0038 introduced, not yet reflected in
the sections below.

## 1. Overview

Developers and infra admins reach all AWS-hosted servers through **Tailscale**
(a WireGuard-based mesh VPN) instead of public IPs — for SSH/deploy access and
SAP HANA/ADS/RDS admin, not for reaching the portal apps themselves (per
[ADR-0038](../adr/0038-portal-support-app-public-exposure-domain-cognito-and-signup.md), `react-external-app`
and `react-support-app` are both public-internet, all environments — see
`architecture-diagram.html` Figure 5). Access is scoped per employee via
Tailscale ACL groups/tags. Two AWS-native services (SAP HANA/ADS via SSH, and RDS)
that can't run a Tailscale client directly are reached via a small subnet-router
instance.

- **AWS Account**: `043207749006`, region `us-east-1`
- **VPC**: `vpc-072f816875fedf904` (default VPC, CIDR `172.31.0.0/16`, 6 subnets across AZs)
- **Tailscale tailnet**: anchored on `varunerpsolutions.com` (Microsoft 365 identity)

## 2. Server Inventory

| Node | AWS Instance ID | Type | Tailscale IP | ACL tag | Public DNS |
|---|---|---|---|---|---|
| sap-hana | `i-09b7a758b807f082d` | r6i.8xlarge, SLES 15 SP7 | 100.95.22.28 | tag:db-servers | sapdev.varunerpsolutions.com |
| sap-ads | `i-0456b335d69f5fd2f` | r6i.xlarge, SLES 15 SP7 | 100.71.57.88 | tag:sap-servers | — |
| aws-subnet-router | `i-05fe2fea51b661923` | t3.micro, Amazon Linux 2023 | 100.112.124.74 | tag:infra | — |
| java-app | `i-01afdc2668e71f05b` | t4g.medium (arm64), 30GB gp3 | 100.88.251.5 | tag:app-servers | javadev.aiarap.com |
| node-app | `i-0e8bb91b84754d419` | t4g.small (arm64), 20GB gp3 | 100.82.12.99 | tag:app-servers | nodedev.aiarap.com |
| react-app | `i-0404b22a0807d70b3` | t4g.small (arm64), 20GB gp3 | 100.70.39.7 | tag:frontend | reactdev.aiarap.com |
| Postgres RDS "aiarap" | (RDS, not EC2) | db instance | — (172.31.84.146:5432) | n/a — reached via router | — |
| Windows RD instance | `i-00b9b28f85d23f6a4` | m6i.xlarge | — | n/a | **stopped**, not part of Tailscale setup |

**App server VPC/subnet placement** (confirmed live via `aws ec2 describe-instances`,
2026-09-07): all three sit in the single default VPC (`vpc-072f816875fedf904`) —
no cross-VPC networking involved, so an API Gateway VPC Link only needs to
attach to this one VPC's subnets to reach all three.

| Node | AZ | Subnet |
|---|---|---|
| java-app | us-east-1b | `subnet-04995cb5d11ee98b1` |
| node-app | us-east-1a | `subnet-06f5722306035b874` |
| react-app | us-east-1a | `subnet-06f5722306035b874` |

node-app and react-app share the same subnet.

**SAP system details**: sap-hana runs the combined S/4HANA ABAP+DB stack (SID `S4H`,
dispatcher port 3200, hostname `sid-hdb-s4h`). sap-ads runs NetWeaver AS Java +
Adobe Document Services (hostname `sid-j2e`).

**Postgres RDS**: endpoint `aiarap.csrqiowos0w4.us-east-1.rds.amazonaws.com:5432`,
private IP `172.31.84.146`, not publicly accessible. Reached only through
`aws-subnet-router`, which advertises the `172.31.0.0/16` route (manually approved
in the Tailscale admin console) and has SG-level permission to reach RDS's SG
(`sg-00b94c03849863691`) on port 5432.

Shared security group for the 3 new dev/test app servers: `sg-0dfb6d3af8165709a`
("dev-test-app-servers") — no inbound rules at all; Tailscale traffic doesn't need one.

## 3. Security Changes Made

Both SAP instances originally had public IPs with security groups open to
`0.0.0.0/0`. All of the following were **revoked**:

| Security Group | Instance | Ports removed from 0.0.0.0/0 |
|---|---|---|
| `sg-02ec491c503af80d0` | sap-ads | 22, 30215, 44300-44301, 50000, 8443, 3200, 30213, 3300 |
| `sg-0bba57b4391d83c27` | sap-hana | 22, 50001 |

Only internal SAP-to-SAP traffic (between the two instances' private IPs) remains
allowed in those groups. All employee/admin access now goes through Tailscale, which
bypasses AWS security groups entirely (traffic arrives via the `tailscale0` tunnel
interface, not the VPC's public path).

## 4. IAM Setup (AWS side)

- **IAM user** `tailscale_VarunERP` — scoped for this project's automation:
  - EC2: RunInstances, Describe*, security group create/modify, tag, start/stop/terminate
  - SSM: SendCommand, GetCommandInvocation, DescribeInstanceInformation, StartSession
  - `iam:PassRole` limited to `ec2.amazonaws.com`
  - RDS: DescribeDBInstances, DescribeDBSubnetGroups
  - Diagnostics addon: `ec2:GetConsoleOutput`, `ec2:GetConsoleScreenshot`, `ec2:GetPasswordData`
- **IAM role** `TailscaleSSMRole` (trusts `ec2.amazonaws.com`, has
  `AmazonSSMManagedInstanceCore`) — attached to sap-hana and sap-ads, but **the SSM
  agent was never actually present on those SLES SAP CAL images**, so this role is
  currently unused. Tailscale was installed via direct SSH instead. Safe to leave
  attached (harmless) or remove if you want to tidy up.

## 5. SSH Access to SAP Servers

- Key file: `VARUNERP_S4HANA2025_FPS01.pem`
  (`...\VARUN_CONSULTING\VARUN ERP SOLUTIONS\SAP_CAL_AWS\`)
- Passphrase-protected — passphrase is known only to the account owner, not stored
  in any file from this session
- Username: **root** (confirmed working on both sap-hana and sap-ads)
- Now reachable **only via Tailscale IP** (100.95.22.28 / 100.71.57.88) — public SSH
  is closed
- Tailscale itself was installed manually via the static binary tarball
  (`pkgs.tailscale.com/stable/tailscale_1.102.3_amd64.tgz`) since the official
  install script doesn't recognize this SLES 15 SP7 SAP CAL variant — binaries were
  placed in `/usr/sbin/`, systemd unit copied from the tarball's `systemd/` folder

## 6. Tailscale ACL Policy (current)

```json
{
  "tagOwners": {
    "tag:infra":       ["autogroup:admin"],
    "tag:db-servers":  ["autogroup:admin"],
    "tag:sap-servers": ["autogroup:admin"],
    "tag:app-servers": ["autogroup:admin"],
    "tag:frontend":    ["autogroup:admin"]
  },
  "groups": {
    "group:dba":             ["ravibabu.koduri@varunerpsolutions.com"],
    "group:developers":      ["ravibabu.koduri@varunerpsolutions.com"],
    "group:qa":              [],
    "group:sap-consultants": ["nshaik@varunconsulting.com", "sshaik@varunconsulting.com"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"],       "dst": ["*:*"] },
    { "action": "accept", "src": ["group:dba"],             "dst": ["tag:db-servers:*", "172.31.84.146/32:5432"] },
    { "action": "accept", "src": ["group:developers"],      "dst": ["tag:sap-servers:*", "tag:app-servers:*", "tag:frontend:*"] },
    { "action": "accept", "src": ["group:qa"],              "dst": ["tag:frontend:80,443"] },
    { "action": "accept", "src": ["group:sap-consultants"], "dst": ["tag:db-servers:*", "tag:sap-servers:*"] }
  ]
}
```

**Manual per-device tag assignment** (Machines → ⋯ → Edit ACL tags) — required
because Tailscale doesn't apply tags automatically:

| Device | Tag |
|---|---|
| sap-hana | tag:db-servers |
| sap-ads | tag:sap-servers |
| java-app | tag:app-servers |
| node-app | tag:app-servers |
| react-app | tag:frontend |
| aws-subnet-router | tag:infra |

## 7. Tailnet Users

| Email | Domain | Role | Access |
|---|---|---|---|
| ravibabu.koduri@varunerpsolutions.com | varunerpsolutions.com | Owner | everything |
| jreddy@varunerpsolutions.com | varunerpsolutions.com | Admin | everything |
| nchanda@varunerpsolutions.com | varunerpsolutions.com | Admin | everything (device: `naga-123`) |
| nshaik@varunconsulting.com | varunconsulting.com (external invite) | Member | sap-hana + sap-ads only |
| sshaik@varunconsulting.com | varunconsulting.com (external invite) | Member | sap-hana + sap-ads only |

`varunconsulting.com` is a **separate domain/tenant** from the tailnet's anchor
domain — those two users had to be added via Tailscale's external-invite flow, not
the standard team invite.

`group:dba`, `group:developers` (beyond the owner), and `group:qa` are defined but
have no other members yet — ready to populate as more employees join.

## 8. DNS Records (Hostinger)

| Record | Type | Value |
|---|---|---|
| sapdev.varunerpsolutions.com | A | 100.95.22.28 |
| javadev.aiarap.com | A | 100.88.251.5 |
| nodedev.aiarap.com | A | 100.82.12.99 |
| reactdev.aiarap.com | A | 100.70.39.7 |

All resolve to Tailscale CGNAT addresses (`100.64.0.0/10`) — safe to publish
publicly since they're unreachable to anyone not on the tailnet.

## 9. SAP GUI Configuration

Local landscape file: `%APPDATA%\SAP\Common\SAPUILandscape.xml`
Connection "S4 HANA- VARUNERP" (System ID `S4H`) → `server="sapdev.varunerpsolutions.com:3200"`

Other employees using SAP GUI need the same hostname in their own landscape file —
no per-machine hosts file editing required since it's now real DNS.

## 10. Cost Notes (dev/test sizing, 20 users)

Estimated for java-app/node-app/react-app running ~12–14 hrs/day (not 24/7):

| Server | Instance | Monthly (compute+storage) |
|---|---|---|
| java-app | t4g.medium, 30GB | ~$14.50–$16.51 |
| node-app | t4g.small, 20GB | ~$7.65–$8.66 |
| react-app | t4g.small, 20GB | ~$7.65–$8.66 |
| **Total** | | **~$29.80–$33.83/month** |

Note: EBS storage bills 24/7 regardless of instance uptime; only compute scales
with the on/off schedule. Running all three 24/7 instead would cost ~$60–65/month.

## 11. Tenant Integration Hub (Cognito + API Gateway)

A separate system from everything above — sections 1–9 are about *employees*
reaching internal servers over Tailscale; this is about *external* systems
(10 Tenant Salesforce orgs, 10 Tenant SAP systems, plus VarunERP's own
Salesforce) reaching Node over the public internet, since none of those
callers can run a Tailscale client. Authenticated via Cognito
client-credentials + per-connection API keys instead. Java is a separate
concern — see below, not part of this inbound hub at all.

**Where the actual infrastructure-as-code lives** (Terraform, not yet
applied against real AWS — see Outstanding below):
- `terraform/shared/` — the once-created stack: Cognito pool + resource
  servers, 2 inbound REST APIs (node/sap), the shared Lambda authorizer, the
  internal NLB, Java's outbound infrastructure (`java_outbound.tf`), the
  Postgres-backed inventory writer.
- `terraform/modules/` — `tenant-onboarding` (stamps out one Tenant's
  certs/domains/Cognito clients/API keys), `lambda-authorizer`,
  `pg-inventory-writer`.
- `terraform/tenants/` — the root config that calls `tenant-onboarding` once
  per Tenant from a list.
- `docker/` — how node-app runs separate dev and qa containers on one
  shared EC2 instance without a dev deploy being able to disrupt qa
  (java-app also runs this way, but its ports aren't customer-facing — see
  `docker/README.md`).

**Core design**: one REST API per inbound backend (not per environment) —
dev/qa/prd are *stages* of that one API, each with its own NLB
listener/target and a `gwPort` stage variable driving where the integration
forwards.

**Java is outbound-only** (ADR-0039): a nightly batch worker that calls out
to each Tenant's SAP system to extract data, publishing a "batch complete"
SQS event NestJS consumes — it never receives an inbound call, so it has no
REST API, Cognito scope, or NLB listener. `terraform/shared/java_outbound.tf`
provisions the SQS queue and the IAM policy for reading Tenant SAP
credentials.

**Outstanding before this can actually be applied**:
- `node` prod instance isn't provisioned — `terraform/shared` currently
  carries a placeholder instance ID for it (guarded by a Terraform `check`
  block that warns until replaced)
- SAP prod (a second HANA instance) isn't provisioned either
- `var.tenant_sap_secret_arn_pattern` (Java's Secrets Manager access) is a
  guessed naming convention, not confirmed against the app's actual
  secret-creation code
- Several account-specific Terraform variables still need real values:
  private subnet IDs, the SAP tailnet-proxy instance ID, the Route53 zone ID
  for `varunerpsolutions.com`, and the `aiarap` RDS instance identifier/
  secret ARN for the inventory writer

## 12. Outstanding / TODO

- [ ] Confirm the ACL policy update (tag:sap-servers split) has been saved and
      device tags applied (section 6)
- [ ] Set up an automated start/stop schedule (AWS Instance Scheduler or an
      EventBridge+Lambda cron) for java-app/node-app/react-app to actually realize
      the 12–14 hr/day cost savings — not yet configured
- [ ] Deploy actual application code to java-app/node-app/react-app (currently
      base OS + Tailscale only, no runtime installed)
- [ ] Confirm Tailscale billing plan status — a business-domain tailnet
      auto-starts a 14-day trial rather than the free plan; verify it's been
      converted to a paid plan (Standard, $8/user/month) before it lapses
- [ ] **Rotate the Tailscale auth key** used to join servers during this session —
      it's reusable and was used repeatedly; regenerate it in Settings → Keys once
      all current servers are confirmed stable, so the old one can be revoked
- [ ] Invite remaining employees (~20 planned total; only 4 + owner added so far)
      and assign them to `group:dba` / `group:developers` / `group:qa` as appropriate
- [ ] Decide whether to keep or terminate the stopped Windows RDP instance
      (`i-00b9b28f85d23f6a4`) — likely superseded by Tailscale, but not touched
      this session
- [ ] Optional cleanup: remove `TailscaleSSMRole` from sap-hana/sap-ads if you
      don't plan to use SSM (currently harmless but unused)
- [ ] Tenant integration hub (section 11): provision the node prod instance
      and SAP prod, confirm `var.tenant_sap_secret_arn_pattern` against the
      app's real secret-creation code, fill in the account-specific
      Terraform variables listed there, then `terraform apply`
      `terraform/shared` before onboarding any real Tenant via
      `terraform/tenants`

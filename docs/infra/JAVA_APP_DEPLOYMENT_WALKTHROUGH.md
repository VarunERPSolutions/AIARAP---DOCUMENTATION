# java-app Deployment Walkthrough — From Zero

**Scope:** how a `git push` to the `dev` branch of `AIARAP-spring-backend` ends up
as a running Spring Boot container on the `java-app` EC2 instance, and every
piece of AWS/GitHub configuration that makes that possible.

**Verification note:** everything in this document was confirmed by directly
reading the actual files, running `aws`/`gh`/`git` commands against the real
account, or executing commands on the live EC2 instance via SSM — not
assumed. The AWS CLI session expired partway through writing this and was
re-authenticated (`aws login`) before finishing, so **every** fact below —
including RDS settings, security group rules, and VPC/subnet details — was
independently confirmed live against the real AWS account this session. Two
things worth flagging up front because they contradict the existing
`docs/infra/INFRASTRUCTURE_REFERENCE.md`: (1) `java-app` (and `node-app`,
`react-app`) **do have public IPs** assigned, despite that document saying
they don't — see §11/§18 (item 17)/§19; (2) the RDS security group **does** permit inbound
from `java-app`'s own security group, resolving what looked like a gap
before live verification — see §11.

---

## 1. Architecture — the complete path

```
Developer (you)
   │  git push origin dev
   ▼
GitHub repository — VarunERPSolutions/AIARAP-spring-backend, branch "dev"
   │  push event on branch "dev" triggers the workflow
   ▼
GitHub Actions — .github/workflows/deploy-dev.yml, job "deploy" on ubuntu-latest
   │  requests a short-lived OIDC token from GitHub's own OIDC provider,
   │  presents it to AWS STS, asking to assume role "github-actions-ci"
   ▼
AWS STS (AssumeRoleWithWebIdentity) — trust policy checks the token's
   "aud" and "sub" claims against what's allowed (see §5)
   │  issues temporary AWS credentials (valid ~1 hour) for that role
   ▼
AWS (as the assumed role "github-actions-ci")
   │  1. ecr:GetAuthorizationToken + push  → uploads a Docker image to ECR
   │  2. ssm:SendCommand                    → tells the EC2 instance to redeploy
   ▼
EC2 instance "java-app" (i-01afdc2668e71f05b)
   │  runs docs/../docker/deploy.sh as root (via SSM, using the instance's
   │  OWN IAM role "TailscaleSSMRole", not the GitHub Actions role)
   │  deploy.sh: pulls secrets from Secrets Manager, logs in to ECR itself,
   │  pulls the new image, restarts the container via docker compose
   ▼
Running application — container "java-dev", Spring Boot on port 8080
   (published as host port 4001, reachable only via Tailscale)
   │  spring.datasource.url=${SPRING_DATASOURCE_URL} etc., populated from
   │  the .env.secrets file deploy.sh wrote
   ▼
AWS RDS "aiarap" (PostgreSQL) — schema "test", table "test.customer"
```

**Two separate AWS identities are involved, at two separate stages** — this
trips up almost everyone new to this pattern, so it's worth stating plainly:

1. **GitHub Actions** authenticates as IAM role `github-actions-ci` (via
   OIDC — no stored AWS keys). It's only allowed to: push images to 4 named
   ECR repos, and send exactly one SSM command (`AWS-RunShellScript`) to 3
   named EC2 instances. It has **no** permission to read Secrets Manager, no
   permission to touch RDS, nothing else.
2. **The EC2 instance itself** authenticates as IAM role `TailscaleSSMRole`
   (via its instance profile — also no stored AWS keys). This is the
   identity that actually runs `deploy.sh`, reads the Secrets Manager
   secret, and pulls the image from ECR. GitHub Actions never touches
   secrets or the image pull directly — it only ever tells SSM "run this
   command," and the box does the rest under its own permissions.

### ASCII diagram (compressed)

```
 You            GitHub              GitHub Actions runner
  │  push dev     │                        │
  └──────────────►│  triggers workflow     │
                   └───────────────────────►│
                                             │ OIDC token ──► AWS STS
                                             │                  │ assumes
                                             │                  ▼
                                             │         role: github-actions-ci
                                             │            (temp credentials)
                                             │
                                    ┌────────┴────────┐
                                    ▼                 ▼
                              docker push        ssm:SendCommand
                                    │                 │
                                    ▼                 ▼
                             ECR: varunerp/     EC2 "java-app"
                             java-app:dev        (i-01afdc2668e71f05b)
                                    │                 │ runs deploy.sh
                                    │                 │ as role: TailscaleSSMRole
                                    │                 │
                                    │        ┌────────┴─────────┐
                                    │        ▼                  ▼
                                    │  Secrets Manager    ECR pull (own
                                    │  varunerp/java-      login, own
                                    │  app/dev secret      permissions)
                                    │        │                  │
                                    └───────►└────────┬─────────┘
                                                       ▼
                                            docker compose up -d
                                                       │
                                                       ▼
                                          container "java-dev" :4001→8080
                                                       │
                                                       ▼
                                          RDS "aiarap" PostgreSQL
                                          (schema "test")
```

---

## 2. Complete inventory

### AWS resources

---
**Name:** `i-01afdc2668e71f05b` ("java-app")
**Type:** EC2 instance, `t4g.medium` (arm64/Graviton), Amazon Linux 2023, 30GB gp3
**Purpose:** runs the `java-dev` (and eventually `java-qa`) Docker container
**Created/modified by:** provisioned manually in an earlier session (per
`INFRASTRUCTURE_REFERENCE.md`) — not Terraform-managed
**Used by:** the GitHub Actions workflow (`ssm:SendCommand` target), Tailscale
(reachable at `100.88.251.5`), `deploy.sh`
**How it connects to deployment:** it's the actual destination of every
deploy — GitHub Actions never touches it except via one SSM command
**Where configured:** instance ID hardcoded in `terraform/shared/variables.tf`
(`var.java_app_instance_id`) and in the GitHub secret `EC2_INSTANCE_ID`
**How to find it in AWS Console:** EC2 → Instances → search `i-01afdc2668e71f05b`
**Dependencies:** IAM instance profile `TailscaleSSMRole`; security group
`sg-0dfb6d3af8165709a`; SSM Agent (confirmed running/online this session);
Tailscale client (confirmed running, peer `100.88.251.5`)

---
**Name:** `TailscaleSSMRole`
**Type:** IAM role (EC2 instance profile)
**Purpose:** the identity the EC2 instance itself runs as
**Created/modified by:** created in an earlier session for Tailscale/SSM
setup; **this session** added one new inline policy to it
(`app-server-ecr-pull`, via `terraform/shared/ec2_ecr_pull.tf`)
**Used by:** `java-app`, `node-app`, `react-app` instances (shared profile)
**Policies attached (verified via `aws iam list-attached-role-policies` /
`list-role-policies` this session):**
  - `AmazonSSMManagedInstanceCore` (AWS-managed) — lets SSM Agent register
    and receive commands
  - `deploy-secrets-read` (inline) — `secretsmanager:GetSecretValue` on
    `arn:aws:secretsmanager:us-east-1:043207749006:secret:varunerp/*`
  - `app-server-ecr-pull` (inline, added this session) — `ecr:GetAuthorizationToken`
    (resource `*`) plus `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`,
    `ecr:BatchCheckLayerAvailability` scoped to the 4 app ECR repo ARNs
**Where configured:** `terraform/shared/ec2_ecr_pull.tf` (the pull policy);
the SSM/secrets-read parts predate this Terraform stack and aren't
Terraform-managed (confirmed: `terraform state list` shows nothing named
`TailscaleSSMRole`)
**How to find it in Console:** IAM → Roles → `TailscaleSSMRole`
**Dependencies:** none upstream; downstream, everything `deploy.sh` does
depends on this role having exactly these three grants

---
**Name:** `github-actions-ci`
**Type:** IAM role (assumed via OIDC, not an instance profile)
**Purpose:** the identity GitHub Actions runs as during the `Deploy to dev`
workflow
**Created/modified by:** `terraform/shared/ci.tf`, applied this session
(and its trust-policy `sub` claims were fixed this session after the first
few deploy attempts failed with `AssumeRoleWithWebIdentity` denied)
**Used by:** the workflow step "Configure AWS credentials (OIDC)"
**Trust policy (who can assume it):** Federated principal = the GitHub OIDC
provider (below), condition requires `aud=sts.amazonaws.com` and `sub`
matching one of 8 exact strings — one plain-format and one immutable-ID
variant per each of the 4 app repos, restricted to `ref:refs/heads/dev`
**Permissions policy (inline, name `github-actions-ci`) — verified this
session via `aws iam get-role` / the applied Terraform state:**
  - `EcrAuth`: `ecr:GetAuthorizationToken` on `*`
  - `EcrPush`: `ecr:BatchCheckLayerAvailability`, `PutImage`,
    `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`,
    `BatchGetImage`, `GetDownloadUrlForLayer` — scoped to the 4 ECR repo ARNs
    (the last two were added this session — the original set was missing
    them, which caused a real deploy failure, see §18 item 5)
  - `SsmDeploy`: `ssm:SendCommand` scoped to exactly 3 EC2 instance ARNs
    (java-app, node-app, react-app) + the `AWS-RunShellScript` document ARN
  - `SsmStatus`: `ssm:GetCommandInvocation` on `*`
**Where configured:** `terraform/shared/ci.tf`
**How to find it in Console:** IAM → Roles → `github-actions-ci`
**Dependencies:** the OIDC provider below must exist first

---
**Name:** `token.actions.githubusercontent.com` OIDC provider
**Type:** IAM OIDC Identity Provider
**ARN:** `arn:aws:iam::043207749006:oidc-provider/token.actions.githubusercontent.com`
**Purpose:** tells AWS "trust identity tokens signed by GitHub Actions"
**Created by:** `terraform/shared/ci.tf` (`aws_iam_openid_connect_provider.github_actions`)
**Used by:** the trust policy on `github-actions-ci`
**Where configured:** `terraform/shared/ci.tf`
**How to find it in Console:** IAM → Identity providers

---
**Name:** ECR repositories — `varunerp/java-app`, `varunerp/node-app`,
`varunerp/react-external-app`, `varunerp/react-support-app`
**Type:** Amazon ECR private repositories
**Purpose:** store the Docker images each app's CI builds
**Created by:** `terraform/shared/ci.tf` (`aws_ecr_repository.app`, `for_each`
over all 4 apps)
**Config:** `image_tag_mutability = MUTABLE` (the `:dev` tag is meant to be
overwritten on every push — it's a floating tag, not immutable); a lifecycle
policy expires **untagged** images after 14 days; scan-on-push enabled
**Full registry URL for java-app:**
`043207749006.dkr.ecr.us-east-1.amazonaws.com/varunerp/java-app`
**Where configured:** `terraform/shared/ci.tf`
**How to find it in Console:** ECR → Repositories

---
**Name:** `varunerp/java-app/dev`
**Type:** AWS Secrets Manager secret
**Purpose:** holds the real (non-committed) config for the `java-dev`
container — datasource credentials, etc.
**Confirmed to exist** via `aws secretsmanager list-secrets` this session.
**Read by:** `deploy.sh`, using the EC2 instance's `TailscaleSSMRole`
**Not verified:** the exact keys inside it (I deliberately never printed the
secret value — see §9 for why, and what keys it *should* contain based on
what the app reads)
**Where configured:** created directly in Secrets Manager (not
Terraform-managed for this app — `terraform/shared` does not contain a
`java-app` secret resource)
**How to find it in Console:** Secrets Manager → Secrets → `varunerp/java-app/dev`

---
**Name:** RDS instance "aiarap"
**Type:** PostgreSQL **18.3**, `db.t4g.micro`, 20GB storage, single-AZ
(`MultiAZ: false`) — all confirmed live via `aws rds describe-db-instances`
**Endpoint:** `aiarap.csrqiowos0w4.us-east-1.rds.amazonaws.com:5432`
**Publicly accessible:** confirmed `false`
**VPC / subnet group:** `vpc-072f816875fedf904` / `default-vpc-072f816875fedf904`
**Security group:** `sg-00b94c03849863691` (confirmed the only one attached)
**Purpose:** stores the `test.customer` table the app's Customer CRUD API uses
**Created/modified by:** Not verified — not created by anything in
`terraform/shared` today (the RDS-provisioning Terraform was removed from
this stack in commit `a2e82e4`, see §14)
**Used by:** the `java-dev` container, via `spring.datasource.url`
**How it connects to deployment:** confirmed live — `java-app`'s own
security group is explicitly permitted inbound on 5432 (see next entry)
**Where configured:** nowhere in this repo currently — it must have been
created directly in the AWS Console or by Terraform that's no longer in this
stack
**How to find it in Console:** RDS → Databases → `aiarap`

---
**Name:** `sg-0dfb6d3af8165709a` ("dev-test-app-servers")
**Type:** Security Group
**Purpose:** attached to `java-app`, `node-app`, `react-app` instances
**Confirmed live via `aws ec2 describe-security-groups`:**
- **Inbound:** empty — no rules at all (matches documentation)
- **Outbound:** `-1` (all protocols/ports) to `0.0.0.0/0` — fully open egress,
  which is what actually lets `java-app` reach both ECR/Secrets Manager (over
  the internet, via the IGW — see VPC entry below) and RDS (within the VPC)
**Where configured:** not in this Terraform stack; managed outside it

---
**Name:** `sg-00b94c03849863691`
**Type:** Security Group, attached to the RDS instance
**Confirmed live via `aws ec2 describe-security-groups`:**
- **Inbound:** TCP 5432 from **two** security groups by ID —
  `sg-0dfb6d3af8165709a` (the app-servers group `java-app` itself uses) and
  `sg-086a3c9a126dca96a` (confirmed by name/description: `tailscale-subnet-router`
  — "Tailscale subnet router - no inbound needed"). A second rule allows all
  protocols from `sg-00b94c03849863691` itself (self-referencing, harmless).
- **Outbound:** all traffic to `0.0.0.0/0`
**Resolved gap:** the documentation only mentioned the router's access; live
verification shows `java-app`'s own security group **is** explicitly
permitted — so network-level connectivity from `java-app` to RDS on 5432 is
confirmed to exist. (This doesn't guarantee the *credentials* work — just
that the network path is open.)

---
**Name:** `vpc-072f816875fedf904`
**Type:** VPC — confirmed **default VPC** (`IsDefault: true`), CIDR `172.31.0.0/16`
**Subnets (all 6 confirmed live via `aws ec2 describe-subnets`):**

| Subnet ID | AZ | CIDR | Auto-assigns public IP |
|---|---|---|---|
| `subnet-06f5722306035b874` | us-east-1a | 172.31.0.0/20 | yes |
| `subnet-070f3eaeef5474e56` | us-east-1c | 172.31.16.0/20 | yes |
| `subnet-0ed64d3f9c0d7f9f5` | us-east-1d | 172.31.32.0/20 | yes |
| `subnet-0cdc6cb130179364c` | us-east-1e | 172.31.48.0/20 | yes |
| `subnet-04995cb5d11ee98b1` | us-east-1b | 172.31.80.0/20 | yes (`java-app` lives here) |
| `subnet-02b7b11bc5dda22ce` | us-east-1f | 172.31.64.0/20 | yes |

**Every subnet in this VPC is effectively public** — all 6 auto-assign
public IPs on launch, and the VPC's route table sends `0.0.0.0/0` straight to
an Internet Gateway (`igw-09d694db11b7f3a3e`, confirmed live) — there is
**no NAT Gateway and no private subnet** in this VPC at all. This is a
default VPC used as-is, not a custom-designed network.

---
**Not present in this deployment (confirmed):** no Application/Network Load
Balancer in front of `java-app` for the dev environment (the `docker-compose.yml`
comment says host port 4001 "is the target_port this environment's NLB
target group points at," implying an NLB target group *may* exist for
`node-app`'s customer-facing traffic — but `java-app` per ADR-0017 is
outbound-only and explicitly has no NLB listener); no CloudFront; no API
Gateway wired to this app.

### GitHub

- **Repository:** `VarunERPSolutions/AIARAP-spring-backend`
- **Branches (confirmed via `gh api .../branches`):** `dev`, `main`, `prod`, `test`
- **Workflow file:** `.github/workflows/deploy-dev.yml`, name `Deploy to dev`
- **Trigger:** `on: push: branches: [dev]` — runs only on pushes to `dev`,
  nothing else (not on PRs, not on `main`/`prod`/`test`)
- **GitHub Actions secrets (confirmed via `gh secret list`, values never
  retrieved):**
  - `AWS_ROLE_ARN` — the ARN of `github-actions-ci` (`arn:aws:iam::043207749006:role/github-actions-ci`)
  - `EC2_INSTANCE_ID` — `i-01afdc2668e71f05b`
- **GitHub Actions variables:** none configured (`gh variable list` returned empty)
- **GitHub Environments:** none configured (`gh api .../environments` returned `"total_count":0`) — the secrets above are plain repository secrets, not scoped to an Environment
- **Permissions block in the workflow:** `id-token: write` (required to
  request an OIDC token) + `contents: read` (required for checkout)
- **OIDC:** yes, used exclusively — confirmed no AWS access keys anywhere in
  the workflow or in repo secrets

### EC2 (`java-app`, confirmed via SSM this session)

- **OS:** Amazon Linux 2023 (`PlatformName: Amazon Linux`, `PlatformVersion: 2023`)
- **Instance type:** `t4g.medium` (arm64/Graviton)
- **Private IP:** `172.31.87.99`; Tailscale IP `100.88.251.5`
- **Docker:** installed and running (`docker ps`, `docker compose` both confirmed working)
- **No Nginx, no systemd unit for the app, no cron jobs found or referenced** —
  the app runs purely as a Docker container managed by `docker compose`, kept
  alive by `restart: unless-stopped` in `docker-compose.yml`, not by a
  systemd service
- **Application directory on the box:** `/opt/aiarap/docker/java-app/dev/`
  (holds `docker-compose.yml`, `.env`, `.env.secrets`) — confirmed via SSM `cat`/`ls`
- **Deploy script location:** `/opt/aiarap/docker/deploy.sh`
- **Note — how these files got onto the box:** there is **no automated sync**
  from this git repo to `/opt/aiarap/docker/` on the instance. Per
  `docker/README.md`, this layout is manually copied onto the box. This
  session had to manually push updated copies of `deploy.sh` and
  `docker-compose.yml` onto the instance via `aws ssm send-command`
  (base64-encoding the file and writing it with `base64 -d >`) after editing
  them in git — editing the git file alone does **not** change what's
  running on the box.
- **SSH:** not used for this app's deployment at all — everything goes
  through SSM (`AWS-RunShellScript` documents)
- **User the container runs as (inside the container, confirmed from
  `Dockerfile`):** a non-root user `spring:spring`, created via
  `addgroup -S spring && adduser -S spring -G spring`
- **Open ports relevant to this app (confirmed via `ss -tlnp` this
  session):** `4001` (both IPv4 and IPv6, owned by `docker-proxy`, forwarding
  to the container's `8080`), plus `22` (sshd) and Tailscale's own listener
  port. No port 4001 rule exists in the security group, by design — it's
  reachable only via the Tailscale interface, which security groups don't govern.

---

## 3. File-by-file explanation

---
**File:** `deploy-dev.yml`
**Exact path:** `AIARAP-spring-backend/.github/workflows/deploy-dev.yml`
**Purpose:** defines the entire CI/CD pipeline for this app's `dev` environment
**Who executes it:** GitHub Actions, on a GitHub-hosted `ubuntu-latest` runner
**When it executes:** automatically, on every push to the `dev` branch
**What it reads:** the repo's own source (`Dockerfile`, source code) via
checkout; two GitHub secrets (`AWS_ROLE_ARN`, `EC2_INSTANCE_ID`)
**What it writes:** a new Docker image in ECR; triggers a file/state change
on the EC2 instance indirectly (via SSM → `deploy.sh`)
**What AWS resources it interacts with:** STS (assume role), ECR (push),
SSM (`SendCommand`, `GetCommandInvocation`)
**What happens if it's missing:** pushing to `dev` does nothing — no build,
no deploy. This is the only trigger mechanism; there is no other automation
**Dependencies:** the `github-actions-ci` IAM role and its trust policy must
already exist and be correctly configured, or the very first step
(`Configure AWS credentials`) fails

---
**File:** `Dockerfile`
**Exact path:** `AIARAP-spring-backend/Dockerfile`
**Purpose:** defines how to build the deployable image from source
**Who executes it:** `docker/build-push-action` inside the GitHub Actions
runner (via Buildx + QEMU, cross-compiling for `linux/arm64`)
**When it executes:** every workflow run, in the "Build and push :dev image" step
**What it reads:** `.mvn/`, `mvnw`, `pom.xml`, `src/` from the checked-out repo
**What it writes:** a two-stage image — build stage produces a jar, final
stage is a slim `eclipse-temurin:21-jre-alpine` image containing only that jar
**What AWS resources it interacts with:** none directly (the *push* of the
built image is a separate action, `docker/build-push-action`, using the ECR
login already established)
**Important lines:**
```dockerfile
FROM eclipse-temurin:21-jdk-alpine AS build
RUN chmod +x mvnw && ./mvnw -B dependency:go-offline   # chmod needed — mvnw is committed non-executable
RUN ./mvnw -B -DskipTests package

FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S spring && adduser -S spring -G spring   # non-root runtime user
USER spring:spring
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```
**What happens if it's missing:** the "Build and push" workflow step fails immediately
**Dependencies:** `mvnw`/`.mvn/` (Maven wrapper) must be present and made
executable (it is committed as non-executable — `chmod +x` in the Dockerfile
works around this rather than fixing the git file mode)

---
**File:** `docker-compose.yml` (dev)
**Exact path:** `AIARAP---DOCUMENTATION/docker/java-app/dev/docker-compose.yml`
**Purpose:** defines how the container actually runs on the EC2 instance —
ports, resource limits, env files, healthcheck, logging
**Who executes it:** `deploy.sh`, via `docker compose -p java-app-dev ...`
**When it executes:** every time `deploy.sh java-app dev` runs
**What it reads:** `.env` and `.env.secrets` (both in the same directory on
the instance, neither committed to git)
**What it writes:** nothing itself; it's a declarative spec Docker Compose
reads
**Important lines:**
```yaml
ports:
  - "4001:8080"          # host:container
env_file:
  - .env
  - .env.secrets          # written fresh by deploy.sh on every deploy
healthcheck:
  test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/actuator/health"]
```
**What happens if it's missing:** `deploy.sh` fails — `docker compose pull`/`up`
has nothing to operate on
**Dependencies:** the image referenced (`.../varunerp/java-app:dev`) must
already exist in ECR (pushed by the workflow before this step runs)

---
**File:** `deploy.sh`
**Exact path:** `AIARAP---DOCUMENTATION/docker/deploy.sh` (git); a manually
copied duplicate lives at `/opt/aiarap/docker/deploy.sh` on the EC2 instance
— see §8 for the full breakdown
**Purpose:** the actual redeploy logic — refresh secrets, refresh ECR login,
pull the new image, restart the container
**Who executes it:** the EC2 instance's own shell, invoked by SSM's
`AWS-RunShellScript` document, as a command sent by the GitHub Actions
workflow. **Not** executed by GitHub Actions itself — GitHub Actions only
asks SSM to run it.
**When it executes:** on every successful image push, immediately after
**What it reads:** command-line args (`$1`=app, `$2`=env, `$3`=tag); the
Secrets Manager secret `varunerp/<app>/<env>`
**What it writes:** `.env.secrets` in the app/env directory (overwritten
every run)
**What AWS resources it interacts with:** Secrets Manager
(`GetSecretValue`), ECR (`GetAuthorizationToken` via `docker login`)
**What happens if it's missing:** the "Deploy on EC2 via SSM" workflow step
fails (`cd /opt/aiarap/docker && ./deploy.sh ...` — no such file)
**Dependencies:** `jq` and the `aws` CLI must be installed on the instance
(both confirmed present)

---
**File:** `application.properties`
**Exact path:** `AIARAP-spring-backend/src/main/resources/application.properties`
**Purpose:** Spring Boot's own configuration file — datasource, Flyway, JPA settings
**Who executes it:** read by the Spring Boot application itself at startup,
inside the container
**When it executes:** on every application boot
**What it reads:** nothing external — but its `${SPRING_DATASOURCE_URL}`
etc. placeholders are resolved from the container's environment variables
(which come from `.env`/`.env.secrets` via `env_file` in `docker-compose.yml`)
**Current content (verified):**
```properties
spring.application.name=AiarapSpringBackend

spring.datasource.url=${SPRING_DATASOURCE_URL}
spring.datasource.username=${SPRING_DATASOURCE_USERNAME}
spring.datasource.password=${SPRING_DATASOURCE_PASSWORD}

spring.flyway.schemas=test
spring.flyway.default-schema=test
spring.flyway.baseline-on-migrate=true
spring.jpa.properties.hibernate.default_schema=test
spring.jpa.hibernate.ddl-auto=validate
```
**What happens if it's missing:** Spring Boot falls back to defaults for
everything (`spring.application.name` becomes blank, no datasource
configured at all)
**Dependencies:** the three `SPRING_DATASOURCE_*` env vars **must** exist in
the container's environment (deliberately not defaulted — "fail loudly if
unset rather than silently pointing at the wrong database," per the file's
own comment) — see §9/§10

---
**File:** `SecurityConfig.java`
**Exact path:** `AIARAP-spring-backend/src/main/java/com/aiarap/config/SecurityConfig.java`
**Purpose:** overrides Spring Security's default all-endpoints-authenticated
behavior to explicitly permit specific test/demo paths
**Who executes it:** Spring's dependency injection container, at startup —
registers a `SecurityFilterChain` bean
**Current logic (verified):** permits `/api/add`, `/api/customers/**`,
`/actuator/health/**`, and `/error` without authentication; everything else
requires OAuth2 resource-server authentication (which currently has no
issuer configured — see §19, this effectively means every *other* endpoint
is unreachable with a valid token today, not just unauthenticated requests)
**Important nuance documented in the file's own comments:** `/error` must
stay permitted because any thrown exception (404/409/400 from the
controllers) triggers a servlet-container-level forward to `/error` — if
Security blocks that forward, the client sees a `403` instead of the real
status code. This only reproduces on a real deployed server, not under
`MockMvc` in tests — which is presumably how it slipped through initially
**Also defines:** a permissive CORS policy (`allowedOriginPatterns: "*"`)
scoped only to `/api/customers/**`, to let `react-support-app` (a different
origin) call it directly for a demo screen — explicitly flagged in a comment
as a shortcut that violates ADR-0003 (which says cross-app calls should go
through an API Gateway) and should be revisited

---
**File:** `pom.xml`
**Exact path:** `AIARAP-spring-backend/pom.xml`
**Purpose:** Maven build definition — dependencies, plugins, Java version
**Key facts:** Spring Boot **4.1.1** (parent), Java **21**; includes
`spring-boot-starter-data-jpa`, `postgresql` (runtime scope),
`spring-boot-starter-flyway` + `flyway-database-postgresql`,
`spring-boot-starter-security-oauth2-resource-server`,
`spring-boot-starter-actuator` (this is what exposes `/actuator/health`),
AWS SDK v2 modules (`sqs`, `sns`, `cloudwatch`), Stripe SDK, Lombok, MapStruct
**What happens if `spring-boot-starter-data-jpa`/`postgresql`/`flyway-*` were
removed:** the app would boot without needing any database at all (this was
literally done temporarily earlier in this deployment's history — see §14)

---
**File:** `V1__create_customer_table.sql`
**Exact path:** `AIARAP-spring-backend/src/main/resources/db/migration/V1__create_customer_table.sql`
**Purpose:** Flyway migration — defines the schema and table the Customer API uses
**Who executes it:** Flyway, at application startup, against the RDS database
**Content (verified, no secrets):**
```sql
CREATE SCHEMA IF NOT EXISTS test;
CREATE TABLE test.customer (
    id            BIGSERIAL PRIMARY KEY,
    customer_code VARCHAR(50)  NOT NULL UNIQUE,
    name          VARCHAR(200) NOT NULL,
    email         VARCHAR(255),
    phone         VARCHAR(50),
    status        VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```
**Important nuance:** `test.customer` already existed in the real database
*before* Flyway ever ran against it (per the git commit message "Baseline
Flyway against the pre-existing test.customer table"). `spring.flyway.baseline-on-migrate=true`
tells Flyway to record V1 as already-applied on first run rather than
re-running the `CREATE TABLE` and failing with "already exists"

---
**Terraform files** (`AIARAP---DOCUMENTATION/terraform/shared/`):
`ci.tf` (OIDC + `github-actions-ci` role + ECR repos), `ec2_ecr_pull.tf`
(the app-server ECR-pull policy added this session), `variables.tf` (the 3
instance-ID inputs), `versions.tf` (provider versions — not read in detail
here, unremarkable). **Not present:** any Terraform managing the RDS
instance, VPC, or security groups for this app — those exist outside this
stack (confirmed: `terraform state list` shows only the CI/ECR resources).
This stack was deliberately narrowed this session (commit `a2e82e4`) — it
used to also contain Cognito, API Gateway, and tenant-onboarding
infrastructure unrelated to this app, which was removed to scope it down to
just what dev CI/CD actually needs.

---

## 4. GitHub Actions workflow — explained block by block

```yaml
name: Deploy to dev
```
A human-readable label, shown in the GitHub Actions UI. Doesn't affect behavior.

```yaml
on:
  push:
    branches: [dev]
```
**"On"** defines the trigger. This says: run this workflow automatically
every time a commit is pushed to the `dev` branch specifically — pushes to
`main`, `prod`, `test`, or any feature branch do nothing.

```yaml
permissions:
  id-token: write
  contents: read
```
Every workflow run gets a GitHub-issued token controlling what it can do
*against GitHub itself* (not AWS). `id-token: write` is what allows the
"Configure AWS credentials" step to request an OIDC identity token at all —
without it, that step fails outright. `contents: read` lets `actions/checkout`
read the repo.

```yaml
env:
  AWS_REGION: us-east-1
  APP_NAME: java-app
  ECR_REPOSITORY: varunerp/java-app
```
Plain workflow-level variables (not secrets — these are just non-sensitive
constants), reused throughout the steps below via `${{ env.X }}`.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
```
A **job** is a group of steps that run together on one machine (a
**runner**). `ubuntu-latest` means GitHub provisions a fresh, temporary
Ubuntu Linux VM for this run, destroyed afterward. This runner is **amd64**
architecture — important later.

**Step 1 — Checkout**
```yaml
- name: Checkout
  uses: actions/checkout@v4
```
Downloads the repository's code (at the exact commit that was pushed) onto
the runner's disk. `uses:` means this step runs a pre-built, reusable
**action** (someone else's packaged automation) rather than a raw shell
command. Without this, there's no `Dockerfile`/`pom.xml`/`src/` for the next
steps to build.

**Step 2 — Configure AWS credentials (OIDC)**
```yaml
- name: Configure AWS credentials (OIDC)
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: ${{ env.AWS_REGION }}
```
This is the authentication step. It: (1) asks GitHub's own OIDC provider for
a signed identity token describing this specific run (which repo, which
branch, etc.); (2) presents that token to AWS STS, asking to assume the role
named in the `AWS_ROLE_ARN` secret; (3) AWS checks the role's trust policy —
does the token's `aud`/`sub` match what's allowed?; (4) if yes, STS returns
temporary AWS credentials, which this action injects as environment
variables for every subsequent step in the job. No AWS access key or secret
key exists anywhere in this repo or its secrets — this is the entire point
of OIDC (see §5).
**Credentials used:** none yet (this step *produces* them) — it authenticates
via the GitHub-issued OIDC token itself.
**What breaks if removed:** every later `aws`/`docker push`/`ssm` call fails
with "no credentials."

**Step 3 — Login to Amazon ECR**
```yaml
- name: Login to Amazon ECR
  id: ecr-login
  uses: aws-actions/amazon-ecr-login@v2
```
Uses the temporary credentials from Step 2 to call `ecr:GetAuthorizationToken`
and logs the local Docker daemon in to the account's ECR registry. `id:
ecr-login` names this step so later steps can reference its output —
specifically `steps.ecr-login.outputs.registry`, the full registry hostname
(`043207749006.dkr.ecr.us-east-1.amazonaws.com`).

**Steps 4 & 5 — Set up QEMU / Set up Docker Buildx**
```yaml
- uses: docker/setup-qemu-action@v3
- uses: docker/setup-buildx-action@v3
```
`java-app` runs on `t4g.medium` — **arm64** (Graviton) hardware. The
`ubuntu-latest` runner is **amd64**. A plain `docker build` produces an image
for the runner's own architecture (amd64), which crashes on the arm64 box
with `exec format error` (this actually happened during this deployment's
history — see §18 item 4). QEMU is a CPU emulator that lets the amd64 runner
emulate arm64 instructions; Buildx is Docker's extended builder that knows
how to target a different platform using that emulation.

**Step 6 — Build and push :dev image**
```yaml
- name: Build and push :dev image
  uses: docker/build-push-action@v6
  with:
    context: .
    platforms: linux/arm64
    push: true
    tags: ${{ steps.ecr-login.outputs.registry }}/${{ env.ECR_REPOSITORY }}:dev
```
Builds the `Dockerfile` in the repo root, explicitly targeting `linux/arm64`
(via the QEMU/Buildx setup above), then pushes the result to
`043207749006.dkr.ecr.us-east-1.amazonaws.com/varunerp/java-app:dev` —
overwriting whatever `:dev` pointed to before (it's a floating tag).
**Credentials used:** the role from Step 2, via the ECR login from Step 3.
**AWS resource touched:** the `varunerp/java-app` ECR repository.
**Output:** a new image, addressable by tag `:dev` or its content digest.

**Step 7 — Deploy on EC2 via SSM**
```yaml
- name: Deploy on EC2 via SSM
  run: |
    set -euo pipefail
    COMMAND_ID=$(aws ssm send-command \
      --instance-ids "${{ secrets.EC2_INSTANCE_ID }}" \
      --document-name "AWS-RunShellScript" \
      --comment "Deploy $APP_NAME dev (${{ github.sha }})" \
      --parameters "commands=[\"cd /opt/aiarap/docker && ./deploy.sh $APP_NAME dev\"]" \
      --query "Command.CommandId" --output text)
    ...
    aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "..." || true
    STATUS=$(aws ssm get-command-invocation ... --query Status --output text)
    ...
    if [ "$STATUS" != "Success" ]; then ... exit 1; fi
```
`run:` (as opposed to `uses:`) means this step is a raw shell script, not a
packaged action. It: (1) calls `ssm:SendCommand`, telling AWS Systems
Manager to run `cd /opt/aiarap/docker && ./deploy.sh java-app dev` on the
instance named by the `EC2_INSTANCE_ID` secret, as a fire-and-forget async
request that returns a `CommandId`; (2) polls (`ssm wait command-executed`)
until that command finishes; (3) fetches its `Status`
(`Success`/`Failed`/etc.) and prints its stdout; (4) if it didn't succeed,
prints stderr too and exits with failure, which marks the whole workflow run
red. **Note the `|| true` after `ssm wait`** — this means the wait command's
own possible failure (e.g. a `TimedOut` waiter state) doesn't immediately
kill the job; the actual pass/fail decision is made explicitly afterward by
checking `$STATUS`.
**Credentials used:** still the `github-actions-ci` role.
**AWS resource touched:** the EC2 instance, indirectly through SSM (GitHub
Actions never opens a direct network connection to the box at all).

---

## 5. AWS authentication — the exact mechanism

**Mechanism used: OIDC + AssumeRoleWithWebIdentity.** Confirmed — no IAM
user, no long-lived access keys, anywhere in this pipeline.

The full chain:

```
GitHub's OIDC provider (token.actions.githubusercontent.com)
   issues a signed JWT for this specific workflow run, containing claims like:
     aud: sts.amazonaws.com
     sub: repo:VarunERPSolutions/AIARAP-spring-backend:ref:refs/heads/dev
        ↓
aws-actions/configure-aws-credentials@v4
   presents that JWT to AWS STS's AssumeRoleWithWebIdentity API,
   naming the role: arn:aws:iam::043207749006:role/github-actions-ci
        ↓
AWS STS checks the role's trust policy:
   - is the token signed by a trusted OIDC provider? (yes — the provider
     resource in ci.tf was created using that exact issuer URL)
   - does "aud" equal "sts.amazonaws.com"? (yes, required condition)
   - does "sub" exactly match one of the 8 allowed strings? (yes, if this
     is a push to VarunERPSolutions/AIARAP-spring-backend's "dev" branch)
        ↓
STS issues temporary credentials for "github-actions-ci"
   (valid ~1 hour, auto-expiring — never stored anywhere)
        ↓
Those credentials carry exactly the permissions in github-actions-ci's
   inline policy: push to 4 ECR repos, SendCommand to 3 EC2 instances,
   GetCommandInvocation on anything. Nothing else — no S3, no RDS, no
   Secrets Manager, no IAM changes.
```

**What's trusted:** AWS trusts tokens signed by GitHub's OIDC provider,
scoped down further by the exact `sub` string. **Who trusts whom:** AWS
trusts GitHub's identity assertions; GitHub Actions in turn trusts whatever
secrets the repo owner configured (`AWS_ROLE_ARN`).
**Why deployment would fail if the OIDC provider or trust policy were
removed:** `Configure AWS credentials (OIDC)` would fail immediately with
`AssumeRoleWithWebIdentity` denied — this literally happened during this
deployment's actual history (see §18 item 2) when the trust policy's `sub`
condition didn't yet include the immutable-ID format GitHub was actually sending.

**GitHub repository restriction:** enforced entirely by the `sub` string
match — only pushes to `dev` in one of these 4 specific repos can ever
successfully assume this role. A push to `main`, or from a fork, or from any
other repo, produces a `sub` claim that doesn't match any allowed string,
and `AssumeRoleWithWebIdentity` is denied.

---

## 6. IAM — from zero, mapped to this deployment

- **IAM user**: a permanent human/service identity with its own long-lived
  credentials (access key + secret, or console password). **Not used
  anywhere in this pipeline** — everything here uses temporary,
  auto-expiring credentials instead. (One does exist in this account,
  `Jreddy@varunerpsolutions.com`, but that's the human operator's own
  console/CLI identity used to run Terraform and inspect AWS — unrelated to
  the deploy pipeline itself.)
- **IAM role**: an identity *without* built-in credentials — something else
  (a person, a service, another AWS resource) must "assume" it to get
  temporary credentials. Both identities in this pipeline
  (`github-actions-ci`, `TailscaleSSMRole`) are roles.
- **IAM policy**: a JSON document listing allowed (or denied) actions on
  specific resources. Two kinds matter here:
  - **Trust policy** ("who can assume this role") — e.g. `github-actions-ci`'s
    trust policy names the GitHub OIDC provider as the only allowed principal.
  - **Permissions policy** ("what this role can do once assumed") — e.g.
    `github-actions-ci`'s inline policy granting ECR push + SSM send-command.
- **IAM group**: a way to attach the same permissions to multiple IAM
  *users* at once. **Not used anywhere in this deployment** (no IAM groups
  were found or referenced).
- **Instance profile**: the mechanism that lets an *EC2 instance* assume an
  IAM role automatically, without any credentials ever being placed on the
  box. `TailscaleSSMRole` is attached to `java-app` this way — confirmed via
  `aws ec2 describe-instances` showing `IamInstanceProfile.Arn`.
- **AssumeRole**: the general act of exchanging one identity's trust for
  another role's temporary credentials. GitHub Actions does this via
  `AssumeRoleWithWebIdentity` (OIDC-flavored); EC2 does an equivalent
  automatic exchange under the hood via its instance profile.

**Mapped directly:**

| Question | Answer |
|---|---|
| GitHub Actions → which IAM role? | `github-actions-ci` |
| EC2 → which IAM role? | `TailscaleSSMRole` |
| `deploy.sh` → which IAM permissions? | Whatever `TailscaleSSMRole` grants (it runs *as* that role, inherited from the instance) |
| Secrets Manager → which IAM permissions? | `TailscaleSSMRole`'s inline `deploy-secrets-read` policy: `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:us-east-1:043207749006:secret:varunerp/*` |

**What specific permissions mean, in this context:**
- `secretsmanager:GetSecretValue` — read the actual value of a secret. Does
  **not** allow creating, deleting, or listing secrets — just reading one
  whose ARN/name is already known and matches the `varunerp/*` prefix.
- `ec2:DescribeInstances` — **not granted to either role in this
  pipeline.** Neither `github-actions-ci` nor `TailscaleSSMRole` needs to
  look up instance metadata; they already know the exact instance ID
  (hardcoded in Terraform/secrets).
- `ssm:SendCommand` — trigger a shell command to run on a named EC2
  instance via the SSM Agent. This is how GitHub Actions reaches into the
  box without SSH.

---

## 7. EC2 — the server, from zero

- **How created:** manually, in an earlier session — not by Terraform in
  this repo (confirmed: no `aws_instance` resource for `java-app` exists in
  `terraform/shared`)
- **AMI/OS:** Amazon Linux 2023 (confirmed via SSM)
- **Instance type:** `t4g.medium` — a Graviton (arm64) burstable instance,
  2 vCPU / 4GB RAM class
- **Region:** `us-east-1`
- **VPC/Subnet:** `vpc-072f816875fedf904`, subnet `subnet-04995cb5d11ee98b1`
  (us-east-1b) — confirmed live via `aws ec2 describe-instances`
- **Security group:** `sg-0dfb6d3af8165709a`
- **IAM instance role:** `TailscaleSSMRole`
- **Storage:** 30GB gp3 (per documentation)
- **Public/private networking:** the instance has a private IP
  (`172.31.87.99`) **and also a public IP, `52.91.46.61`** — confirmed live
  via `aws ec2 describe-instances`. This contradicts
  `INFRASTRUCTURE_REFERENCE.md`, which states these app servers have no
  public IP. In practice this public IP is currently harmless because
  `sg-0dfb6d3af8165709a` has zero inbound rules — nothing can reach it
  through that public IP today — but it does mean the instance is one
  security-group misconfiguration away from being internet-exposed, not
  actually network-isolated by the VPC design itself. The real protection is
  entirely the security group having no inbound rules, not the absence of a
  public IP. The intended, documented access path (Tailscale, `100.88.251.5`)
  remains correct and is what's actually used — the public IP is just
  unused, not a functioning access path today. See §18 item 17, and §19.
- **Application user:** the container process runs as `spring` (non-root)
  *inside* the container; the SSM commands themselves run as `root` on the host
- **Application/deployment directory:** `/opt/aiarap/docker/`
- **Running processes (confirmed):** `sshd`, `containerd`, `tailscaled`,
  `docker-proxy` (forwarding host port 4001), and the Java process inside
  the `java-dev` container
- **Open ports (confirmed):** `22` (SSH), `4001` (the app, via docker-proxy)
  — plus whatever Tailscale itself listens on

**Deployment lifecycle, as it actually happens (confirmed steps, in order):**

1. GitHub Actions starts (triggered by push to `dev`)
2. AWS authentication happens (OIDC → `github-actions-ci` role)
3. A new image is built (cross-compiled for arm64) and pushed to ECR
4. GitHub Actions calls `ssm:SendCommand` — this is "deployment reaching EC2"
5. The SSM Agent on the instance receives the command and executes it as `root`
6. **No files are copied from GitHub to the box** at this point — `deploy.sh`
   and `docker-compose.yml` are already sitting on the box from an earlier,
   manual copy. The only "file" that moves through this pipeline per-deploy
   is the Docker image itself, via ECR pull.
7. The application is **not built on the box** — it was already built as a
   finished Docker image by the GitHub Actions runner. The box only pulls
   and runs it.
8. The existing container is stopped and replaced as part of
   `docker compose up -d --remove-orphans`
9. The new container starts, with `env_file` loading `.env` and
   `.env.secrets` — this is how environment variables and secrets both
   reach the JVM, as plain OS-level environment variables the container
   inherits at start
10. Secrets are loaded specifically via `deploy.sh` re-fetching
    `varunerp/java-app/dev` from Secrets Manager into `.env.secrets`
    *before* `docker compose up` runs, every single deploy
11. A health check happens via Docker's own `healthcheck:` block (not part
    of the GitHub Actions workflow at all — Docker polls
    `wget .../actuator/health` every 15s on its own, independent of CI)
12. Logs are generated as JSON-file-driver container logs, viewable via
    `docker logs java-dev`, capped at 10MB × 3 files

---

## 8. `deploy.sh` — line by line

```bash
#!/usr/bin/env bash
set -euo pipefail
```
`set -euo pipefail` is a safety net: `-e` exits immediately if any command
fails, `-u` treats using an undefined variable as an error, `-o pipefail`
makes a pipeline (`a | b`) fail if *either* side fails, not just the last
one. This is why an unset `$1`/`$2` or a failed `aws` call stops the script
rather than continuing with garbage state.

```bash
APP="${1:?usage: deploy.sh <node-app|java-app> <dev|qa> [tag]}"
ENV="${2:?usage: deploy.sh <node-app|java-app> <dev|qa> [tag]}"
TAG="${3:-}"
```
Reads the 3 command-line arguments. The `:?` syntax means "if this variable
is unset or empty, exit now and print this message" — so calling the script
with too few arguments fails immediately with a clear usage error rather
than proceeding with `APP=""`.

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${APP}/${ENV}"
[ -d "$DIR" ] || { echo "no such app/env: $APP/$ENV" >&2; exit 1; }
cd "$DIR"
```
Computes the absolute path to `docker/<app>/<env>/` relative to the script's
own location (not the shell's current directory — this makes it safe to
call from anywhere), checks that directory actually exists, and `cd`s into
it. For a call of `./deploy.sh java-app dev`, this resolves to
`/opt/aiarap/docker/java-app/dev`.

```bash
SECRET_ID="varunerp/${APP}/${ENV}"
aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text \
  | jq -r 'to_entries | map("\(.key)=\(.value)") | .[]' > .env.secrets \
  || touch .env.secrets
```
This is the Secrets Manager integration. `aws secretsmanager get-secret-value`
contacts AWS (as `TailscaleSSMRole`, since that's the identity the whole
script runs under), asking for the secret named `varunerp/java-app/dev`.
`--query SecretString --output text` extracts just the raw secret text (a
JSON object, by convention for "key/value" style secrets). The `jq` command
transforms that JSON object — e.g. `{"SPRING_DATASOURCE_URL": "jdbc:..."}`
— into `.env`-file format lines, `KEY=value`, one per line, and writes them
to `.env.secrets`. If *any* part of that pipeline fails (wrong permissions,
secret doesn't exist, `jq` chokes on malformed JSON), the `|| touch
.env.secrets` fallback creates an **empty** file instead of crashing the
whole deploy — meaning a missing/broken secret degrades the app (it'll
start without those env vars and fail at whatever depends on them) rather
than blocking the deploy pipeline entirely. This is a deliberate design
choice, called out in `docker/README.md`.
**Where the secret goes:** into `.env.secrets`, which `docker-compose.yml`'s
`env_file:` list loads as container environment variables.
**How the application receives it:** Spring Boot reads OS environment
variables automatically as property overrides — `SPRING_DATASOURCE_URL` (an
env var) maps to `spring.datasource.url` (a property) via Spring's standard
relaxed-binding rules (env vars are conventionally SCREAMING_SNAKE_CASE,
properties are dot.separated — Spring translates between them automatically).

```bash
if [ "$ENV" = "qa" ]; then
  [ -n "$TAG" ] || { echo "qa deploys require an explicit tag..." >&2; exit 1; }
  VAR_NAME="$(echo "${APP}" | tr '-' '_' | tr '[:lower:]' '[:upper:]' | sed 's/_APP$//')_QA_TAG"
  export "${VAR_NAME}=${TAG}"
fi
```
Only relevant for `qa` deploys (not `dev`, which is what actually runs
today). Forces a tag to be given explicitly for `qa` (no floating tag there,
unlike `dev`), and exports it as e.g. `JAVA_QA_TAG` so
`docker-compose.yml`'s `${JAVA_QA_TAG:?...}` can pick it up.

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 043207749006.dkr.ecr.us-east-1.amazonaws.com
```
Logs the box's own Docker daemon in to ECR, using `TailscaleSSMRole`'s
`ecr:GetAuthorizationToken` permission. **This line did not exist
originally** — its absence caused a real deploy failure this session (`no
basic auth credentials` on `docker compose pull`), fixed by adding both this
line and the underlying IAM permission (`ec2_ecr_pull.tf`).

```bash
COMPOSE_PROJECT="${APP}-${ENV}"
docker compose -p "$COMPOSE_PROJECT" pull
docker compose -p "$COMPOSE_PROJECT" up -d --remove-orphans
docker image prune -f
```
`-p` gives Compose an explicit project name (`java-app-dev`) instead of
letting it infer one from the current directory's basename (which would
just be `dev` — colliding with `node-app`'s or `react-app`'s own `dev`
directory if they ever shared the same box, since Compose scopes container
names/networks by project name). `pull` fetches the `:dev` image just pushed
to ECR; `up -d --remove-orphans` recreates the container with the new image
and tears down any container Compose no longer recognizes as part of this
project; `docker image prune -f` deletes now-unused old image layers to
avoid the disk filling up over repeated deploys.
**No rollback logic exists** — if the new image is broken, there's no
automatic revert to the previous one. **No explicit health-check gating**
either — the workflow reports success as soon as `deploy.sh` exits 0,
regardless of whether the container ends up healthy a few seconds later.

---

## 9. Secrets Manager — inventory

---
**Secret name:** `varunerp/java-app/dev`
**Purpose:** holds the real runtime configuration for the dev container —
primarily database connection details
**Used by / read by:** `deploy.sh`, running as `TailscaleSSMRole` on the
`java-app` EC2 instance
**AWS region:** `us-east-1`
**Created by:** Not verified (not Terraform-managed in this stack)
**IAM permission required:** `secretsmanager:GetSecretValue` on
`arn:aws:secretsmanager:us-east-1:043207749006:secret:varunerp/*` — granted
to `TailscaleSSMRole` via its `deploy-secrets-read` inline policy
**Expected keys — Not verified directly (never printed the value), but
inferred from what `application.properties` actually requires:**
```
SPRING_DATASOURCE_URL=<REDACTED>
SPRING_DATASOURCE_USERNAME=<REDACTED>
SPRING_DATASOURCE_PASSWORD=<REDACTED>
```
(These three env var names are not a guess about the secret's contents —
they're a hard requirement read directly from `application.properties`,
which references exactly `${SPRING_DATASOURCE_URL}`,
`${SPRING_DATASOURCE_USERNAME}`, `${SPRING_DATASOURCE_PASSWORD}` with no
defaults. If the secret doesn't contain these exact key names, the app
fails to start with a Hikari/datasource error — which is exactly what
happened earlier in this deployment's history, see §18 item 6.)

**Why Secrets Manager instead of `application.properties`:** committing
real database credentials to git means anyone with repo read access (and
anyone who ever clones it, forever, even after rotation) has them.
Secrets Manager centralizes the actual values outside version control,
lets them be rotated without a code change, and access is governed by IAM
rather than by "who has git clone access."
**How EC2 gets permission:** via its instance profile role
(`TailscaleSSMRole`) — no credentials are ever placed on the box; the AWS
SDK/CLI on the instance automatically uses the instance's own IAM role.
**How `deploy.sh` retrieves it:** one `aws secretsmanager get-secret-value`
call, piped through `jq` into `.env.secrets` (see §8).
**How env vars reach Spring Boot:** `docker-compose.yml`'s `env_file:
[.env, .env.secrets]` loads both files as the container's environment;
Spring Boot's relaxed property binding maps `SPRING_DATASOURCE_URL` (env
var) to `spring.datasource.url` (property) automatically.

---

## 10. Spring Boot configuration — precedence

Spring Boot merges configuration from multiple sources, in a defined
priority order (highest wins) — the ones actually relevant here, high to low:

1. **OS environment variables** (e.g. `SPRING_DATASOURCE_URL`, set by Docker
   from `.env`/`.env.secrets`)
2. **`application.properties`** on the classpath (bundled inside the jar)

Because `application.properties` uses `${SPRING_DATASOURCE_URL}` (a
placeholder, not a literal value) with **no default supplied** (Spring's
placeholder syntax supports `${VAR:default}` — this file deliberately omits
the `:default` part), if the environment variable is genuinely absent,
Spring Boot **fails to start** rather than silently falling back to
`null`/empty. This is a deliberate fail-loud choice, per the file's own comment.

**Mapping, explicitly:**

| Environment variable (Docker/OS level) | Spring property (application-level) |
|---|---|
| `SPRING_DATASOURCE_URL` | `spring.datasource.url` |
| `SPRING_DATASOURCE_USERNAME` | `spring.datasource.username` |
| `SPRING_DATASOURCE_PASSWORD` | `spring.datasource.password` |

This mapping isn't specific to these three names — it's Spring Boot's
general **relaxed binding** rule: any environment variable
`SCREAMING_SNAKE_CASE_LIKE_THIS` is automatically considered as a candidate
value for the property `screaming.snake.case.like.this` (dots replace
underscores, lowercased), without any extra configuration required.

**Locally vs. on EC2:** on EC2, these three env vars come from
`.env.secrets` (fetched from Secrets Manager). Locally (a developer's own
machine, outside this pipeline), a developer would need to `export
SPRING_DATASOURCE_URL=...` etc. themselves before running the app, or the
app fails to start with the same "fail loudly" behavior — there is
**no local default/dev database configured anywhere in this repo**.

---

## 11. RDS database

All confirmed live this session via `aws rds describe-db-instances` /
`aws ec2 describe-security-groups`:

- **Engine:** PostgreSQL **18.3** (per ADR-0007 — RDS chosen over Aurora for cost/simplicity at expected scale)
- **Instance identifier:** `aiarap`
- **Instance class:** `db.t4g.micro`, 20GB storage, single-AZ (no standby replica)
- **Endpoint:** `aiarap.csrqiowos0w4.us-east-1.rds.amazonaws.com:5432`
- **VPC / subnet group:** `vpc-072f816875fedf904` / `default-vpc-072f816875fedf904`
- **Public accessibility:** confirmed `false`
- **Status:** confirmed `available`
- **Schema used by this app:** `test` (per `application.properties`,
  `spring.flyway.schemas=test`)
- **Table:** `test.customer` (created manually before Flyway adopted it as a baseline)
- **Security group:** `sg-00b94c03849863691` — confirmed inbound rules:
  TCP 5432 from `sg-0dfb6d3af8165709a` (java-app's own group) **and** from
  `sg-086a3c9a126dca96a` (named `tailscale-subnet-router`), plus a
  self-referencing all-protocol rule

**The path:**
```
java-app EC2 instance (subnet-04995cb5d11ee98b1, in vpc-072f816875fedf904)
   → RDS "aiarap" (default-vpc-072f816875fedf904 subnet group, same VPC)
```
Both are in the same default VPC, and this session confirmed the network
path is actually open: `sg-00b94c03849863691` explicitly allows inbound 5432
from `sg-0dfb6d3af8165709a`, which is the exact security group `java-app`
uses. **The earlier documentation only mentioned the router's access — live
verification shows `java-app` itself is separately and directly permitted.**
So a `SPRING_DATASOURCE_URL` pointing at the RDS endpoint should be able to
open a TCP connection from inside the container — whether the
username/password in the secret are actually correct is a separate question
this document can't verify without reading the secret's contents.

**Why a connection can work from DBeaver but fail from EC2 (or vice versa),
in general:** DBeaver on a laptop typically reaches RDS through a completely
different path (e.g. via `aws-subnet-router`'s advertised Tailscale route,
or a bastion/SSH tunnel) than an EC2 instance reaching it directly over the
VPC's internal network — they can be governed by two entirely different
security-group rules. A working DBeaver connection is **not** evidence that
EC2-to-RDS connectivity also works.

---

## 12. Networking — from zero

- **VPC (Virtual Private Cloud):** an isolated slice of AWS network space
  you control — here, `vpc-072f816875fedf904`, CIDR `172.31.0.0/16` (the
  default VPC AWS creates automatically per account/region, being reused
  rather than a custom one)
- **Subnet:** a smaller slice of a VPC's IP range, usually tied to one
  Availability Zone. This VPC has 6, confirmed live, one per AZ
  (`us-east-1a/b/c/d/e/f`) — `java-app` sits in `subnet-04995cb5d11ee98b1` (us-east-1b)
- **Public subnet:** has a route to an Internet Gateway, and auto-assigns
  public IPs — confirmed **all 6 subnets in this VPC are public** by this
  definition, including `java-app`'s
- **Private subnet:** no direct route to the internet — confirmed **none
  exist in this VPC**
- **Route table:** the rules deciding where traffic goes based on
  destination IP, attached per subnet — confirmed this VPC's route table
  sends `0.0.0.0/0` to an Internet Gateway
- **Internet Gateway:** lets a VPC's public subnets reach the public internet
  — confirmed present, `igw-09d694db11b7f3a3e`
- **NAT Gateway:** lets private-subnet instances make *outbound* internet
  requests without being reachable *inbound* — confirmed **none exists**;
  it isn't needed here since there are no private subnets. `java-app`
  reaches ECR/Secrets Manager/the internet directly through the Internet
  Gateway, using its (currently unused for inbound) public IP for outbound
  NAT-free routing.
- **Security group:** a *stateful* firewall attached to individual
  resources (not subnets) — "stateful" means a response to an allowed
  outbound request is automatically allowed back in, without needing an
  explicit inbound rule for it
- **Inbound rule:** what's allowed to *reach* a resource
- **Outbound rule:** what a resource is allowed to *reach*
- **Port:** a number identifying a specific service on a host (5432 =
  PostgreSQL by convention, 8080 = this app's internal HTTP port, 4001 = the
  host-side port Docker maps to it)
- **DNS:** translates names to IPs — `javadev.aiarap.com` resolves (per
  Hostinger DNS records) to `100.88.251.5`, a Tailscale address, not a
  normal public IP
- **RDS endpoint:** the DNS name AWS generates for an RDS instance
  (`aiarap.csrqiowos0w4.us-east-1.rds.amazonaws.com`) — resolves internally
  within the VPC to the private IP

**EC2 → RDS, specifically — confirmed live:** `java-app`'s security group
(`sg-0dfb6d3af8165709a`) has an outbound rule allowing all traffic to
`0.0.0.0/0` (no port 5432 restriction), **and** RDS's security group
(`sg-00b94c03849863691`) has an inbound rule explicitly permitting TCP 5432
from `sg-0dfb6d3af8165709a`. Both halves needed for connectivity are
confirmed present.

---

## 13. Deployment sequence — exact, as implemented

| # | Component | File/command | AWS resource | Auth used | Input | Output |
|---|---|---|---|---|---|---|
| 1 | Developer | `git push origin dev` | — | your own GitHub credentials | source code | commit on `dev` |
| 2 | GitHub | (push event) | — | — | commit | triggers workflow run |
| 3 | GitHub Actions | `deploy-dev.yml` starts | — | — | — | job "deploy" begins on `ubuntu-latest` |
| 4 | Runner | `actions/checkout@v4` | — | GitHub's own repo token | — | repo files on disk |
| 5 | Runner | `configure-aws-credentials@v4` | AWS STS | GitHub OIDC token → `github-actions-ci` | `AWS_ROLE_ARN` secret | temp AWS credentials |
| 6 | Runner | `amazon-ecr-login@v2` | ECR | `github-actions-ci` creds | — | Docker logged in to ECR |
| 7 | Runner | `setup-qemu-action`, `setup-buildx-action` | — | — | — | arm64 cross-build capability |
| 8 | Runner | `build-push-action@v6` | ECR | `github-actions-ci` creds | `Dockerfile`, source | image `varunerp/java-app:dev` pushed |
| 9 | Runner | `aws ssm send-command` | SSM | `github-actions-ci` creds | shell command string | `CommandId` |
| 10 | SSM Agent (on EC2) | executes the command | — | `TailscaleSSMRole` (the box's own identity) | `cd /opt/aiarap/docker && ./deploy.sh java-app dev` | runs deploy.sh |
| 11 | `deploy.sh` | `aws secretsmanager get-secret-value` | Secrets Manager | `TailscaleSSMRole` | secret name `varunerp/java-app/dev` | `.env.secrets` written |
| 12 | `deploy.sh` | `aws ecr get-login-password` + `docker login` | ECR | `TailscaleSSMRole` | — | Docker on the box logged in |
| 13 | `deploy.sh` | `docker compose -p java-app-dev pull` | ECR | (Docker's own login from step 12) | image tag `:dev` | new image downloaded to the box |
| 14 | `deploy.sh` | `docker compose -p java-app-dev up -d --remove-orphans` | — | — | `docker-compose.yml`, `.env`, `.env.secrets` | old container replaced, new one started |
| 15 | Container | Spring Boot boots | RDS (aiarap) | DB credentials from `.env.secrets` | `SPRING_DATASOURCE_*` env vars | Flyway validates/baselines schema, JPA starts |
| 16 | Docker | `healthcheck:` polling | — | — | `wget .../actuator/health` | container marked healthy/unhealthy |
| 17 | Runner | `aws ssm get-command-invocation` | SSM | `github-actions-ci` creds | `CommandId` | deploy status reported back to workflow |

---

## 14. Why each configuration exists — "what breaks if I delete this?"

| Configuration | If deleted... |
|---|---|
| The `github_actions_trust` `sub` condition entries | Every push to `dev` fails at "Configure AWS credentials" — `AssumeRoleWithWebIdentity` denied. This is not hypothetical: it actually happened this session before the immutable-ID variants were added. |
| `ecr:BatchGetImage`/`GetDownloadUrlForLayer` on `github-actions-ci` | The image build succeeds but the *push* fails (`denied: ... not authorized to perform: ecr:BatchGetImage`) — also actually happened this session, caused by Buildx's attestation-manifest push needing read-back access even on a fresh push. |
| `app-server-ecr-pull` policy on `TailscaleSSMRole` | `docker compose pull` on the box fails with `no basic auth credentials` — the image exists in ECR but the box has no permission to read it. Also actually happened this session. |
| The `docker login` line in `deploy.sh` | Same failure as above, even with the IAM permission present — the box's Docker daemon still needs an explicit login (tokens expire after 12h, so this must run on every deploy, not just once). |
| `deploy-secrets-read` policy on `TailscaleSSMRole` | `deploy.sh`'s secret fetch fails; the `|| touch .env.secrets` fallback kicks in, producing an *empty* `.env.secrets` — the app then fails to start (`SPRING_DATASOURCE_URL` unset). |
| `spring.flyway.baseline-on-migrate=true` | Flyway would try to run `V1__create_customer_table.sql`'s `CREATE TABLE` against a database where that table already exists, and fail outright — this exact scenario is why the flag was added. |
| `SecurityConfig`'s permit on `/error` | Any thrown exception surfaces as a `403` instead of its real status code, on a real server (not reproducible under `MockMvc` — confirmed as the actual reason this was added, per the commit history). |
| `docker-compose.yml`'s `-p`/`COMPOSE_PROJECT` naming | Two apps sharing one EC2 instance (react-external-app/react-support-app do) would silently tear each other's containers down as "orphans" on deploy — this is an explicitly-documented real risk that was fixed. |
| `chmod +x mvnw` in the `Dockerfile` | The build fails at `RUN ./mvnw ...` with `Permission denied` (exit 126) — `mvnw` is committed to git as non-executable; this actually happened this session. |
| QEMU/Buildx + `platforms: linux/arm64` | The image builds successfully but crashes on the box with `exec format error` — the image would be amd64, the box is arm64. Actually happened this session. |
| The GitHub Actions workflow file itself | Pushing to `dev` does nothing at all — there is no other automation trigger |

---

## 15. Beginner glossary

| Term | Simple definition | Why we use it | Where it appears here |
|---|---|---|---|
| **AWS** | Amazon's cloud platform — rents you servers, databases, storage, etc. | Hosts every server and service in this deployment | Everywhere |
| **EC2** | A virtual server you rent by the hour/second | Runs the actual Docker container | `java-app` instance |
| **RDS** | A managed database service (you don't patch/back it up yourself) | Stores the `customer` table | `aiarap` PostgreSQL instance |
| **VPC** | Your own private network inside AWS | Isolates your resources from other AWS customers | `vpc-072f816875fedf904` |
| **Subnet** | A subdivision of a VPC, usually per-Availability-Zone | Spreads resources for redundancy | 6 subnets in the VPC (unspecified which one `java-app` uses) |
| **Security Group** | A per-resource firewall | Controls exactly what can reach `java-app`/RDS | `sg-0dfb6d3af8165709a`, `sg-00b94c03849863691` |
| **IAM** | AWS's permission system — "who can do what" | Governs every AWS API call in this pipeline | Throughout §5-6 |
| **IAM User** | A permanent identity with its own credentials | Used for human operators, not this pipeline | `Jreddy@varunerpsolutions.com` (unrelated to the pipeline itself) |
| **IAM Role** | A borrow-able identity, assumed temporarily | Both AWS identities in this pipeline are roles | `github-actions-ci`, `TailscaleSSMRole` |
| **IAM Policy** | A document listing allowed/denied actions | Defines exactly what each role can do | The inline policies on both roles |
| **Trust Policy** | The specific policy saying *who* may assume a role | Restricts role-assumption to only the intended caller | `github-actions-ci`'s `sub`-claim conditions |
| **Instance Profile** | The bridge letting an EC2 instance assume a role automatically | Lets `java-app` act as `TailscaleSSMRole` with no stored keys | Attached to `java-app` |
| **OIDC** | An open standard for proving identity via signed tokens | Lets GitHub Actions authenticate to AWS with zero stored secrets | The entire auth chain in §5 |
| **GitHub Actions** | GitHub's built-in CI/CD automation | Runs the build-and-deploy pipeline | `deploy-dev.yml` |
| **Runner** | The (temporary) machine that executes a workflow's steps | Where the Docker image actually gets built | `ubuntu-latest` |
| **Workflow** | A YAML file defining an automated pipeline | The complete CI/CD definition | `deploy-dev.yml` |
| **Artifact** | A file produced by a workflow, savable/downloadable | **Not used** in this pipeline (the Docker image itself is pushed to ECR instead, never uploaded as a GitHub Actions artifact) | n/a |
| **Secret** (GitHub) | An encrypted value stored in repo settings | Holds the role ARN and instance ID | `AWS_ROLE_ARN`, `EC2_INSTANCE_ID` |
| **Secrets Manager** (AWS) | A managed vault for storing sensitive config | Holds real database credentials, outside git | `varunerp/java-app/dev` |
| **AWS CLI** | The command-line tool for calling AWS APIs | Used throughout `deploy.sh` and the workflow's SSM step | `aws ssm ...`, `aws secretsmanager ...`, `aws ecr ...` |
| **SSH** | A protocol for remote shell access to a server | **Not used** to deploy this app — SSM replaces it | n/a for this pipeline |
| **SSM** | AWS Systems Manager — lets you run commands on EC2 instances without SSH | How GitHub Actions actually reaches the box | `ssm:SendCommand`, `AWS-RunShellScript` |
| **Docker** | A tool for packaging an app + its runtime into a portable image | Packages the Spring Boot app | `Dockerfile`, `docker-compose.yml` |
| **Container** | A running instance of a Docker image | The actual running process | `java-dev` |
| **Maven** | A build tool for Java projects | Compiles the app and produces the jar | `pom.xml`, `mvnw` |
| **JAR** | A packaged, executable Java application file | What `ENTRYPOINT ["java","-jar","app.jar"]` runs | `app.jar` |
| **Spring Boot** | A Java framework for building applications quickly | The application framework itself | The whole app |
| **Environment Variable** | A named value available to a running process from its OS | How secrets/config reach the container | `SPRING_DATASOURCE_URL` etc. |
| **systemd** | Linux's service manager, for auto-starting/restarting processes | **Not used** — Docker's own `restart: unless-stopped` does this instead | n/a |
| **Nginx** | A web server / reverse proxy | **Not used** anywhere in this deployment | n/a |
| **DNS** | Translates domain names to IP addresses | `javadev.aiarap.com` → Tailscale IP | Hostinger DNS records |
| **Port** | A numbered endpoint for network services on a host | 8080 (app), 4001 (host-mapped), 5432 (Postgres) | Throughout |
| **TCP** | The underlying reliable-connection protocol most of this runs over | Implicit in "port 5432", "port 4001", etc. | Everywhere networking is discussed |
| **PostgreSQL** | An open-source relational database | What RDS runs | `aiarap` instance |
| **JDBC** | Java's standard API for talking to a database | What `spring.datasource.url`'s `jdbc:postgresql://...` format is | Datasource config |
| **Endpoint** | The address (usually a DNS name) used to reach a service | RDS's connection address | `aiarap.csrqiowos0w4.us-east-1.rds.amazonaws.com` |

---

## 16. "Where do I find this?" guide

**GitHub Actions workflow**
AWS Console path: n/a (GitHub, not AWS)
CLI: `gh run list --repo VarunERPSolutions/AIARAP-spring-backend --branch dev`
Project file: `AIARAP-spring-backend/.github/workflows/deploy-dev.yml`
GitHub location: repo → Actions tab

**GitHub secrets**
CLI: `gh secret list --repo VarunERPSolutions/AIARAP-spring-backend`
GitHub location: repo → Settings → Secrets and variables → Actions

**IAM roles**
AWS Console: IAM → Roles → `github-actions-ci` / `TailscaleSSMRole`
CLI: `aws iam get-role --role-name github-actions-ci`

**ECR repository**
AWS Console: ECR → Repositories → `varunerp/java-app`
CLI: `aws ecr describe-repositories --repository-names varunerp/java-app`

**EC2 instance**
AWS Console: EC2 → Instances → search `i-01afdc2668e71f05b`
CLI: `aws ec2 describe-instances --instance-ids i-01afdc2668e71f05b`

**Secrets Manager secret**
AWS Console: Secrets Manager → Secrets → `varunerp/java-app/dev`
CLI: `aws secretsmanager describe-secret --secret-id varunerp/java-app/dev`
(do **not** run `get-secret-value` casually — it prints the real value)
Project reference: `docker/deploy.sh`

**RDS instance**
AWS Console: RDS → Databases → `aiarap`
CLI: `aws rds describe-db-instances --db-instance-identifier aiarap`

**Running container / logs (on the box, via SSM — no SSH needed)**
```
aws ssm send-command --instance-ids i-01afdc2668e71f05b \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["docker ps","docker logs --tail 50 java-dev"]'
```

**Terraform source for CI/ECR infra**
Project file: `AIARAP---DOCUMENTATION/terraform/shared/ci.tf`,
`ec2_ecr_pull.tf`, `variables.tf`

---

## 17. Troubleshooting map

**If GitHub Actions fails, check:**
- `gh run view <run-id> --repo VarunERPSolutions/AIARAP-spring-backend --log-failed`
- Which step failed — "Configure AWS credentials" failing means an OIDC
  trust-policy problem (check `sub` claim format matches what GitHub
  actually sends — this bit us once already); "Build and push" failing on
  a permission error means the `github-actions-ci` role's ECR policy is
  missing an action; "Deploy on EC2 via SSM" failing means the problem has
  moved to the box itself (see below)
- `gh secret list` — confirm `AWS_ROLE_ARN`/`EC2_INSTANCE_ID` still exist
- `aws iam get-role --role-name github-actions-ci` — confirm trust policy
  and permissions are what's expected

**If EC2 deployment fails (SSM step reports non-Success), check:**
```
aws ssm get-command-invocation --command-id <id> --instance-id i-01afdc2668e71f05b --query StandardErrorContent --output text
```
- Is the SSM Agent online? `aws ssm describe-instance-information --filters "Key=InstanceIds,Values=i-01afdc2668e71f05b"`
- Does `/opt/aiarap/docker/deploy.sh` actually exist and match what's in git? (No auto-sync — must be manually re-copied after any git change)
- Does `TailscaleSSMRole` still have `deploy-secrets-read` and `app-server-ecr-pull`?

**If Spring Boot starts but the database connection fails, check:**
- `docker exec java-dev env | grep SPRING_DATASOURCE` on the box (via SSM) — are all 3 vars actually present?
- `aws secretsmanager get-secret-value --secret-id varunerp/java-app/dev` (careful — prints the real secret) — does it have the exact key names `SPRING_DATASOURCE_URL`/`_USERNAME`/`_PASSWORD`?
- RDS security group — does it permit inbound 5432 from `java-app`'s security group? (See the unresolved gap in §11.)
- `docker logs java-dev` — the actual JDBC/Hikari error message tells you whether it's a credentials problem (auth failure) or a network problem (connection timeout — points to security groups)

**If the application starts but cannot be accessed, check:**
- It has no public IP and no load balancer — it's *only* reachable via
  Tailscale. Confirm your own machine's Tailscale client is actually
  connected (not just the web console) and that the target device
  (`java-app`) appears in your "Network devices" list
- `docker ps` on the box — is the container actually `Up`, and is its
  healthcheck `healthy`?
- `curl localhost:4001/actuator/health` **from the box itself** (via SSM) —
  isolates "is the app broken" from "is the network path broken"

---

## 18. Issues we actually faced, in order — and how each was fixed

This deployment did not work on the first try. It failed for a different
reason at nearly every stage of the pipeline, one at a time, over the course
of getting `java-app` from "nothing running" to "working Customer CRUD API
against a real database." This section is a chronological log of every
real failure encountered, in the order it happened, with the exact error
and the exact fix — not a hypothetical troubleshooting guide (that's §17),
but what genuinely broke.

**1. `terraform apply` had already been run, but nothing was actually
deployed**
The very first check of this whole investigation: `terraform apply "tfplan"`
had succeeded, but `terraform/shared/ci.tf` only provisions CI/CD
*scaffolding* (ECR repos, the OIDC role) — it creates no EC2 instances and
runs no deploy. Confirmed via SSM: `docker ps -a` on `java-app` showed zero
containers, no Java process, nothing listening on 8080. **Not a bug** — just
a misunderstanding of what that Terraform stack actually does versus what
still required a `git push` to trigger.

**2. `AssumeRoleWithWebIdentity` denied — every CI run failed at the very
first AWS step**
```
##[error]Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```
**Cause:** GitHub Actions sends its OIDC `sub` claim using an immutable
org/repo-ID format (`repo:VarunERPSolutions@291509345/AIARAP-spring-backend@1353664849:ref:refs/heads/dev`),
but `github-actions-ci`'s trust policy at the time only matched the plain
format (`repo:VarunERPSolutions/AIARAP-spring-backend:ref:refs/heads/dev`).
**Fix:** added both formats to the trust policy's allowed `sub` list in
`ci.tf`, then `terraform apply`.

**3. Docker build failed: `mvnw: Permission denied` (exit 126)**
**Cause:** `mvnw` (the Maven wrapper script) was committed to git as
non-executable (mode `100644`), most likely from being committed on
Windows.
**Fix:** added `RUN chmod +x mvnw` to the `Dockerfile` immediately before
invoking it, rather than trying to fix the git file mode (more robust
regardless of what OS someone commits from next).

**4. Image built and pushed fine, but the container crashed on the EC2
instance with `exec format error`**
**Cause:** the GitHub Actions runner (`ubuntu-latest`) is **amd64**;
`java-app` is a `t4g.medium` — **arm64** (Graviton). A plain `docker build`
produces an image for the runner's own architecture, which is simply the
wrong CPU architecture for the target host.
**Fix:** added `docker/setup-qemu-action@v3` + `docker/setup-buildx-action@v3`
to the workflow, and switched the build step to `docker/build-push-action@v6`
with `platforms: linux/arm64`, cross-compiling under CPU emulation.

**5. Image push denied: `ecr:BatchGetImage`**
```
denied: User: .../github-actions-ci is not authorized to perform: ecr:BatchGetImage
```
**Cause:** `docker/build-push-action`'s Buildx-based push generates an
attestation/provenance manifest list, which reads back existing
manifests/layers even on a brand-new push — the CI role's original ECR
policy only granted write-side actions (`PutImage`,
`InitiateLayerUpload`/`UploadLayerPart`/`CompleteLayerUpload`,
`BatchCheckLayerAvailability`), not the read-back actions Buildx also needs.
**Fix:** added `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` to the
`EcrPush` statement in `ci.tf`, then `terraform apply`.

**6. Image pushed successfully, but `docker compose pull` on the EC2
instance failed: `no basic auth credentials`**
**Cause:** the box's own IAM role, `TailscaleSSMRole`, had never been
granted any ECR permissions at all — it could receive the SSM command to
redeploy, but had no way to actually authenticate to ECR to pull the image.
**Fix:** two changes together — (a) a new Terraform resource,
`ec2_ecr_pull.tf`, granting `TailscaleSSMRole` `ecr:GetAuthorizationToken` +
`BatchGetImage`/`GetDownloadUrlForLayer`/`BatchCheckLayerAvailability`
scoped to the 4 app ECR repos; (b) an explicit `aws ecr get-login-password |
docker login ...` line added to `deploy.sh`, since the IAM permission alone
doesn't log the box's Docker daemon in — that has to happen freshly on every
deploy anyway, because the login token expires after 12 hours.

**7. Container started but immediately crash-looped: `Failed to determine a
suitable driver class`**
```
Failed to configure a DataSource: 'url' attribute is not specified and no embedded datasource could be configured.
```
**Cause:** `spring-boot-starter-data-jpa`, `flyway-*`, and `postgresql` were
all on the classpath, but no `SPRING_DATASOURCE_URL` (or the other two
datasource env vars) existed anywhere — `.env.secrets` on the box was empty,
since no real database had been wired up for `dev` yet.
**Fix (temporary, later superseded):** added
`spring.autoconfigure.exclude=...DataSourceAutoConfiguration,...HibernateJpaAutoConfiguration,...FlywayAutoConfiguration`
to `application.properties`, letting the app boot with zero database
dependency, purely to verify the rest of the pipeline worked. This was later
reverted once the real `test.customer` table and Secrets Manager values were
actually wired up (see items 12–13 below).

**8. `docker ps` reported the container as `unhealthy`, even though the app
itself responded fine when curled from the host**
**Cause:** `docker-compose.yml`'s healthcheck ran `curl -f
http://localhost:8080/actuator/health` *inside* the container — but the
final image is `eclipse-temurin:21-jre-alpine`, a minimal JRE image with no
`curl` installed at all. Confirmed via `docker exec java-dev which curl`
(not found) vs. `which wget` (found — Alpine's busybox includes it).
**Fix:** changed the healthcheck in both `docker/java-app/dev/` and
`docker/java-app/qa/docker-compose.yml` to `wget -q -O /dev/null http://localhost:8080/actuator/health`.

**9. `/api/add` returned `401 Unauthorized`**
**Cause:** `spring-boot-starter-security-oauth2-resource-server` was on the
classpath with no custom `SecurityFilterChain` — Spring Security's default
behavior requires authentication on every endpoint unless explicitly told
otherwise.
**Fix:** added `SecurityConfig.java`, a `SecurityFilterChain` bean
explicitly permitting `/api/add`.

**10. That fix immediately regressed `/actuator/health` to `403`**
**Cause:** `/actuator/health` had been open by *Spring Boot's own default*
security configuration; the moment a custom `SecurityFilterChain` bean was
added, it fully replaced that default rather than extending it — so
`/actuator/health` silently became "everything else, requires auth" along
with every other endpoint.
**Fix:** added `/actuator/health/**` to the same `permitAll()` list in
`SecurityConfig`. (General lesson, confirmed the hard way: adding your first
custom `SecurityFilterChain` in a Spring Boot app requires explicitly
re-permitting anything the framework's own defaults used to leave open.)

**11. Editing `deploy.sh`/`docker-compose.yml` in git had no effect on the
running instance**
**Cause:** there is no automated sync from either git repo to
`/opt/aiarap/docker/` on the EC2 box — that layout was manually copied there
once, and stays that way until someone manually re-copies it. This isn't a
bug so much as a design gap worth knowing about *before* you spend time
wondering why a committed fix "isn't working."
**Fix:** for each file that needed to change on the live box mid-session
(`deploy.sh`, `docker-compose.yml`), base64-encoded the updated file content
and wrote it directly onto the instance via `aws ssm send-command` (`echo
<base64> | base64 -d > <path>`), then `docker compose up -d` to pick it up
— since there's no SSH access to just `scp` it over.

**12. Real database wiring — `test.customer` already existed manually,
so a plain Flyway migration would have failed**
Once a real Customer CRUD feature was built (`Customer.java`,
`CustomerController.java`, `V1__create_customer_table.sql`), a fresh
`CREATE TABLE test.customer` would fail with "already exists" the moment
Flyway ran against a database where that table was already manually
created. **Fix:** `spring.flyway.baseline-on-migrate=true`, which tells
Flyway to treat `V1` as already-applied on first run instead of re-running
its `CREATE TABLE`.

**13. Two more security bugs found only by testing against the real
deployed server, not caught by `MockMvc` tests** (commit `4714222`, "Fix
CSRF and error-dispatch security bugs found via real-server testing")
- CSRF protection blocked POST/PUT/DELETE to `/api/add`/`/api/customers/**`
  in a real browser/HTTP-client context, since Spring Security's CSRF
  protection is on by default for state-changing requests — **fixed** by
  explicitly ignoring CSRF for those two specific test/demo paths (safe
  here because they use no session/cookie a CSRF token could ever protect).
- Any thrown exception (404 "customer not found", 409 "already exists")
  resulted in a `403` instead of the real status code on the real server —
  **cause:** a thrown exception triggers a servlet-container-level forward
  to `/error`, and `SecurityConfig`'s filter chain was blocking *that*
  forward too, since `/error` wasn't in the permitted list. This
  specifically does not reproduce under `MockMvc`, which doesn't simulate
  the container's real error-dispatch forward — **fixed** by adding `/error`
  to the `permitAll()` list too.

**14. Two apps sharing one EC2 instance could tear each other's containers
down**
**Cause:** `docker compose` infers a project name from the current
directory's basename by default — for both `react-external-app/dev/` and
`react-support-app/dev/`, and for `java-app`/`node-app`'s `dev` vs `qa`
directories, that basename collides (`dev`, `dev`, `qa`, `qa`...). Running
`docker compose up -d --remove-orphans` in one app's directory could then
treat the *other* app's container (under the same inferred project name) as
an "orphan" and remove it.
**Fix:** `deploy.sh` now passes an explicit `-p "${APP}-${ENV}"` project
name to every `docker compose` call, so each app+env combination gets its
own distinct project namespace.

**15. AWS CLI session expired mid-investigation, with a non-standard login flow**
Not a deployment bug, but a real operational snag: `aws sts
get-caller-identity` started failing with "Your session has expired. Please
reauthenticate using 'aws login'" partway through verifying live AWS state.
This environment uses a custom interactive `aws login` (browser-based OIDC
flow), which had to be run by the human operator, not something that could
be scripted/automated from this side.
**Fix:** the operator ran `aws login` interactively; verification resumed
once `aws sts get-caller-identity` succeeded again.

**16. The app couldn't be reached from a browser, even after everything
above was fixed**
Symptom: `http://javadev.aiarap.com:4001/...` and even the raw Tailscale IP
directly (`http://100.88.251.5:4001/...`) both timed out
(`ERR_CONNECTION_TIMED_OUT`) from a specific user's browser, despite the
Tailscale client showing "Connected" and the target device correctly listed
under "Tagged devices."
**Cause — not the app or AWS at all:** a Windows Tailscale client-side
issue. The client's own "Repair Failed: `0x80070642 - User cancelled
installation`" dialog revealed that its WinTun network driver had failed to
install (a UAC/admin-elevation prompt had been dismissed), so the
control-plane connection ("Connected" in the tray) was fine, but no actual
data could flow through the tunnel.
**Fix:** re-ran Tailscale's driver repair and approved the Windows
UAC/driver-install prompt this time, rather than dismissing it.

**17. Documentation drift discovered during live re-verification**
Not a deployment failure, but worth recording: `INFRASTRUCTURE_REFERENCE.md`
stated `java-app`/`node-app`/`react-app` have no public IP — live
`aws ec2 describe-instances` calls this session showed all three actually
do have one assigned (harmless today only because their security groups
have zero inbound rules). The reverse was also true: that document implied
RDS access was only confirmed for the Tailscale subnet router, but live
`aws ec2 describe-security-groups` showed `java-app`'s own security group is
also explicitly and separately permitted into RDS on port 5432 — so that
particular worry turned out to be unfounded. **Lesson:** written
infrastructure docs drift from reality; treat them as a starting point for
investigation, not as a substitute for checking the live resource when it
actually matters.

## 19. Security review

**Problem:** `java-app` (and `node-app`, `react-app`) have public IPs
assigned, contradicting `INFRASTRUCTURE_REFERENCE.md`'s claim that they
don't, and every subnet in this VPC auto-assigns public IPs with no private
subnet available as an alternative
**Risk:** currently low in practice — `sg-0dfb6d3af8165709a` has zero
inbound rules, so the public IP has no open door today. But the *design*
relies entirely on the security group staying empty, not on network
isolation — a single accidental inbound rule addition (e.g. someone opening
port 4001 "just for testing") would immediately expose the app to the
public internet, since there's no private-subnet/NAT boundary to also cross
**Current configuration:** confirmed live — public IP `52.91.46.61` present,
security group has no inbound rules (today)
**Recommended fix:** either explicitly disable public IP assignment for
these instances (`associate-public-ip-address: false` at the ENI level, or
move to a private subnet with a NAT Gateway for outbound), or treat the
empty security group as the sole, carefully-guarded control and add
change-review specifically for any inbound rule added to
`sg-0dfb6d3af8165709a`
**Priority:** Medium (not currently exploited, but the safety margin is
thinner than the documentation implied)

**Problem:** `CorsConfigurationSource` in `SecurityConfig.java` uses
`allowedOriginPatterns(List.of("*"))` for `/api/customers/**`
**Risk:** any website, anywhere, can make authenticated-looking browser
requests to this endpoint (mitigated somewhat by the endpoint itself being
`permitAll` with no real auth today, but this pattern would be dangerous if
left in place once real auth is added)
**Current configuration:** wildcard origin, confirmed in the file, and
explicitly flagged as a temporary shortcut in the code's own comments
(references ADR-0003, which says this should go through an API Gateway instead)
**Recommended fix:** scope to the actual known frontend origin(s) before this leaves test/demo status
**Priority:** Low for now (test-only endpoint, no real data/auth), but should not ship to a customer-facing environment as-is

**Problem:** `/api/add` and `/api/customers/**` are fully unauthenticated
**Risk:** anyone who can reach the app (currently limited to the tailnet)
can create/update/delete customer records with no auth check at all
**Current configuration:** confirmed `permitAll()` in `SecurityConfig.java`,
explicitly labeled as test/demo endpoints in comments
**Recommended fix:** acceptable for now given Tailscale-only network
exposure and explicit test/demo labeling; must not reach a customer-facing
environment without real OAuth2 enforcement
**Priority:** Low today (network already restricted to Tailscale + it's
explicitly a demo), High before any real/production use

**Problem:** OAuth2 resource-server dependency is present but has no
issuer/JWK configuration anywhere found in this repo
**Risk:** every endpoint *other than* the explicitly-permitted ones is
currently unauthenticatable by anyone — not a security hole (fails closed),
but means the "everything else requires auth" half of `SecurityConfig` is
currently untestable/unusable, which could mask a real problem later
**Current configuration:** confirmed — no `spring.security.oauth2.resourceserver.jwt.issuer-uri` or similar found in `application.properties`
**Recommended fix:** none needed until a real authenticated endpoint is built; just don't assume this half of the security config has been validated
**Priority:** Low (fails safe)

**Problem:** stray Terraform plan files (`tfplan`, `tfplan2`, `tfplan3`)
sitting untracked in `terraform/shared/`
**Risk:** low, but plan files can contain resource details (not raw secret
values, but IDs/ARNs) and shouldn't accumulate uncommitted in a shared repo directory
**Current configuration:** confirmed present via `git status` this session
**Recommended fix:** delete them and add `tfplan*` to `.gitignore` if not
already covered
**Priority:** Low (cleanup, not a live risk)

**Problem:** the large Terraform-scoping commit (`a2e82e4`) exists locally
but has not been pushed to `origin/main`
**Risk:** none security-wise, but the fixes made this session
(`ec2_ecr_pull.tf`, the `deploy.sh` ECR-login fix) only exist as an applied
`terraform apply` + a manually-patched file on the EC2 box — if that commit
is lost before being pushed, the *documentation of why* those changes exist
would be lost even though the changes themselves are live
**Current configuration:** confirmed via `git log origin/main..HEAD`
**Recommended fix:** `git push origin main` when ready
**Priority:** Medium (not a security bug, but a "don't lose this work" risk)

**No hardcoded credentials found** in any file inspected this session — the
OIDC design specifically avoids this, and `application.properties` uses
placeholders with no defaults, not literal values. **No long-lived AWS
access keys found anywhere in the pipeline** — both identities use
temporary, auto-expiring credentials.

---

## 20. Final mental model

**GitHub Actions is the delivery truck** — it builds the image and drives it
to ECR, then knocks on the EC2 instance's door via SSM and says "go get the
new one."

**OIDC is the truck's ID badge** — a temporary, single-use credential proving
to AWS "yes, this really is a run of `AIARAP-spring-backend`'s `dev`
workflow," without ever carrying a permanent key that could be stolen or leaked.

**IAM roles are the two separate keyrings** — `github-actions-ci`'s keyring
only opens the ECR loading dock and the EC2 instance's mail slot (SSM).
`TailscaleSSMRole`'s keyring, which only the EC2 instance itself holds, opens
the Secrets Manager safe and its own ECR pull door. Neither keyring opens
the other's doors.

**EC2 is the actual warehouse floor** — it doesn't build anything; it just
receives the finished image and runs it.

**`deploy.sh` is the floor manager** — every time a new shipment (image)
arrives, it re-checks the safe combination (fetches fresh secrets, since the
ECR login token expires every 12h), swaps the old machine (container) for
the new one, and cleans up the old parts (`docker image prune`).

**Secrets Manager is the safe** — the real database password never leaves
it and is never written to git; it's copied out fresh onto the warehouse
floor only at deploy time, into a file that also never touches git.

**Spring Boot is the machine itself** — it reads its operating instructions
(`application.properties`) but refuses to even power on if the safe's
combination (`SPRING_DATASOURCE_*`) wasn't actually delivered.

**RDS is the warehouse's own record-keeping office**, reached over the
internal factory network (VPC) rather than the public road — though exactly
which internal doors are unlocked between the floor and the office
(security groups) wasn't fully confirmed this session.

**Tailscale is the only public entrance** — there is no public loading dock;
the only way anyone gets to see the finished product running is by badging
into the private company network first.

---

## 21. Final checklist

### GitHub
- [x] FOUND — Repository (`VarunERPSolutions/AIARAP-spring-backend`, branches `dev`/`main`/`prod`/`test`)
- [x] FOUND — Workflow (`.github/workflows/deploy-dev.yml`)
- [x] FOUND — Secrets (`AWS_ROLE_ARN`, `EC2_INSTANCE_ID`)
- [x] FOUND — Permissions (`id-token: write`, `contents: read`)
- [x] FOUND (confirmed empty) — GitHub Environments: none configured

### AWS
- [x] FOUND — IAM (`github-actions-ci`, `TailscaleSSMRole`, both roles' policies read directly)
- [x] FOUND — OIDC (provider + trust policy, both confirmed)
- [x] FOUND — EC2 (`i-01afdc2668e71f05b`, confirmed running, SSM online)
- [x] FOUND — Security Group rule details for `sg-0dfb6d3af8165709a` (no inbound, all outbound) and `sg-00b94c03849863691` (inbound 5432 from java-app's own SG + the Tailscale router) — confirmed live
- [x] FOUND — Secrets Manager (`varunerp/java-app/dev` confirmed to exist; contents not read)
- [x] FOUND — RDS instance settings (postgres 18.3, db.t4g.micro, 20GB, single-AZ, not publicly accessible) — confirmed live
- [x] FOUND — VPC/subnet details (default VPC, 6 all-public subnets, no NAT Gateway, IGW `igw-09d694db11b7f3a3e`) — confirmed live
- [x] FOUND — ECR (`varunerp/java-app` and 3 sibling repos, confirmed via Terraform state and `ci.tf`)

### EC2
- [x] FOUND — Application directory (`/opt/aiarap/docker/java-app/dev/`)
- [x] FOUND — Deployment script (`/opt/aiarap/docker/deploy.sh`)
- [x] FOUND — Runtime (Docker + Docker Compose, confirmed working)
- [x] FOUND — Environment (`.env`, `.env.secrets`, confirmed present on the box, contents not printed)
- [x] FOUND — Logs (`docker logs java-dev`, JSON-file driver, confirmed configured)
- [ ] NOT FOUND — systemd service for the app (deliberately not used — Docker's own restart policy replaces it)

### Application
- [x] FOUND — Spring Boot (v4.1.1, confirmed in `pom.xml`)
- [x] FOUND — Database configuration (`application.properties`, env-var-driven, no defaults)
- [x] FOUND — Environment variables (`SPRING_DATASOURCE_URL`/`_USERNAME`/`_PASSWORD`, confirmed required)
- [x] FOUND — Health check (`/actuator/health`, confirmed responding 200 with real traffic this session)

---

## The 5–10 things to learn first

1. **The two-role split (§5-6)** — GitHub Actions and the EC2 instance are
   two completely separate AWS identities with non-overlapping permissions.
   Almost every confusing failure in this pipeline's actual history came
   from mixing these up (assuming a permission on one role would help a
   problem that was actually on the other).
2. **OIDC's trust policy is a literal string match** — the `sub` claim has
   to match *exactly*. This is the single most fragile part of the whole
   setup and the thing most likely to break again if GitHub ever changes
   its token format further.
3. **There is no file sync from git to the EC2 box** — this is the biggest
   trap for a beginner assuming "I pushed to git, so the server has my
   latest `deploy.sh`." It doesn't, until someone manually re-copies it.
4. **Docker Compose's `env_file` mechanism** is the entire bridge between
   "secrets in AWS" and "config Spring Boot can see" — understanding this
   one mechanism explains almost the whole §9-10 chain.
5. **Security groups are stateful and per-resource, not per-subnet** — and
   the unresolved RDS connectivity question in §11 is a great concrete
   example to actually go verify yourself once AWS access is back, as a
   learning exercise.
6. **`docker-compose.yml`'s healthcheck is completely independent of the
   GitHub Actions workflow** — a "successful" deploy in GitHub's UI only
   means `deploy.sh` exited 0, not that the app is actually healthy a few
   seconds later. These are two different signals.
7. **SSM replaces SSH here entirely** — get comfortable with `aws ssm
   send-command`/`get-command-invocation` as your primary way to inspect
   this box; there's no SSH key workflow to learn for this particular app.
8. **Spring Boot's environment-variable-to-property mapping** (§10) is
   generic Spring knowledge, not project-specific — worth learning once,
   applies everywhere you see `SCREAMING_CASE` turning into `dot.case`.

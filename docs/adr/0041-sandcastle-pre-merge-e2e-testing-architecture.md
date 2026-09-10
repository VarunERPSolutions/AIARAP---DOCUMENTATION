# Sandcastle Cross-Repo Orchestration and Pre-Merge E2E Testing Architecture

Redesigns how Sandcastle (the implement→review AFK coding agent loop) picks up
work and verifies it, so a feature spanning frontend + backend can be
implemented and genuinely tested end-to-end before merge — without ever
touching the shared `dev` environment humans rely on.

## 1. Repo strategy: keep 4 code repos + 1 issue-only tracker

Considered consolidating `AIARAP-node-backend`/`AIARAP-external-app`/
`AIARAP-support-app`/`AIARAP-spring-backend` into one monorepo to make
cross-cutting features and issue discovery easier. **Rejected.** The pain
points (agent confusion about ticket ordering, difficulty testing a feature
that spans repos) are solved by fixing *ticket discovery* and *sandbox
orchestration*, not by merging git histories — see
[`docs/agents/issue-tracker.md`](../agents/issue-tracker.md), which already
centralizes issues in `VarunERPSolutions/AIARAP-issues` with per-ticket
`repo:*` labels. A monorepo would also fight the deliberate per-app deploy
isolation already built in `docker/README.md` (dev/qa on separate containers
per app, no "restart everything" command). Four repos stay four repos.

## 2. Ticket model: vertical slices, implemented together, one PR per repo

A feature spanning frontend + backend stays **multiple linked tickets** (one
per repo boundary, `Blocked by #N`), per the existing vertical-slice
convention. What changes is execution: Sandcastle implements the whole
**linked set** in one sandbox pass — so it can wire the branches together and
run a real end-to-end check before opening either PR — but still opens one PR
per repo. PRs and review stay fundamentally per-repo (that's just how git
works); only Sandcastle's *implementation and verification* pass changed to
span the set.

**Not every `Blocked by` edge means "bundle it"** — see §10, added after
connecting this section to how `/to-tickets` actually produces blocking
edges in practice.

## 3. Sandbox composition: only the repos actually in the linked set

Considered always loading all 4 repos into every sandbox for maximum
fidelity. **Rejected** — full-stack toolchains (Java+Maven, Node×3) on every
trivial single-repo ticket is unnecessary weight. A sandbox checks out only
the repo(s) named by the linked ticket set's `repo:*` labels. Other repos'
*running services*, not their source, are reached over the network when a
ticket needs real end-to-end verification — see §5.

## 4. Two-layer testing model

**Layer 1 — iteration (implement → review loop, runs many times per ticket).**
Local Docker sandbox, only the repo(s) in scope, fast, fully isolated:

- **Auth**: real Cognito + real `varunerp-api-authorizer` Lambda, called
  directly (not through the physical Gateway hop). Both are fully-managed,
  auto-scaling AWS services — calling them frequently carries no
  shared-resource contention risk, unlike a fixed-capacity RDS instance, so
  there's no reason to emulate them and risk drift.
- **Database**: `postgres:18` in Docker (matches the real `aiarap` RDS
  instance's engine version — confirmed via `aws rds describe-db-instances`:
  Postgres 18.3, `db.t4g.micro`, single-AZ), spun up fresh via the sandbox's
  own `onSandboxReady` hook, migrations run from a clean slate every time.
  **RDS itself is never touched by Layer 1** — a small burstable instance
  shared with real dev traffic is exactly the kind of shared-resource risk
  this whole redesign exists to avoid, and it would be hit far more
  frequently here than at the Lane phase (§5).
- **Networking**: no Tailscale, no VPC access needed at all — Cognito and
  Lambda are public managed endpoints, Postgres is local. This layer touches
  AWS only via two public API calls.

**Layer 2 — the Lane phase (one real end-to-end check per linked ticket set,
after Layer 1 passes).** See §5.

## 5. The Lane phase: real Gateway, real authorizer, isolated everything else

### Why this needs real infrastructure at all

Per `terraform/shared/gateway_network.tf`, the API Gateway → VPC Link →
internal NLB path forwards only to `target_type=instance` target groups
hardcoded to the real `nodedev`/`javadev` EC2 instance IDs — there is no
mechanism for an ephemeral sandbox to be reached by the real Gateway. A
"does this actually work through the real Gateway + Lambda authorizer" check
is only possible against *something* registered as a live NLB target.
Emulating the Gateway/authorizer/Cognito stack (e.g. LocalStack) was
considered and rejected — passing against an emulation doesn't guarantee
passing against the real AWS services, which defeats the point.

### Verified live today (not what the checked-in Terraform describes — see §7)

| Resource | Live identifier |
|---|---|
| REST API (node) | `varunerp-node-api` (`hn0omem2c0`), stage `dev` |
| REST API (sap) | `varunerp-sap-api` (`95t80f1c91`) |
| Lambda authorizer | `varunerp-api-authorizer`, Node 20, scope-based (`${backend}.${purpose}.${stage}` against the token's Cognito scope claim — not stage-allowlisted, so new stage names work without an authorizer code change) |
| Cognito pools | `AIARAP_DEV`, `varunerp-portal-dev-pool`, `varunerp-support-dev-pool` — the pre-[0040](0040-nine-cognito-pool-architecture.md) model; the target 9-pool architecture is drafted but not applied |
| NLBs | `backend-internal-nlb` (targets = real `java-app`/`node-app` instances), `varunerp-integration-nlb` (1 target group so far: `varunerp-node-dev-tg`) |
| VPC Link | `backend-vpc-link`, fronting `backend-internal-nlb` |
| Subnets | `app_server_subnet_ids`, **public** (`MapPublicIpOnLaunch=true`, default route table → IGW directly, **zero NAT Gateways in the VPC**) |
| RDS | `aiarap`, Postgres 18.3, `db.t4g.micro`, single-AZ |

### The Lane abstraction

A **lane** is a complete, isolated request path pre-provisioned once:

```
Lane K = { API Gateway stage "sandcastle-K", NLB listener + target group K,
           Cognito scope "node.invoke.sandcastle-K", Postgres sidecar (ephemeral, per run) }
```

A fixed pool of **N=4 lanes** (locked — comfortable headroom over the
realistic 2–3 concurrent-linked-set case given the "one issue per iteration"
rule already in `implement-prompt.md`; only `node-app`-touching linked sets
ever need a lane; cheap to widen later, just more identical rows/stages/
target-groups/scopes) is provisioned once. `gwPort` is a per-*stage* variable, so
one stage can only ever point at one NLB target at a time — two concurrent
runs sharing one stage/target-group would have their traffic load-balanced
against each other. Isolation therefore has to happen at the lane level, not
by adding one shared "sandcastle" path.

**Database in the Lane phase**: same reasoning as Layer 1 — a `postgres:18`
sidecar container in the same Fargate task, not the real RDS instance, not
even an isolated schema on it. This removes RDS entirely from every part of
Sandcastle's pipeline; only real Cognito, the real Lambda authorizer, and the
real API Gateway/NLB are ever exercised for real.

### Per-run flow

1. Builds the changed backend repo's image, pushes to the existing ECR repo
   as `sandcastle-<sha>` (not `:dev`) — **before** claiming a lane, so the
   claimed window doesn't have to absorb build/push time variance.
2. Sandcastle claims a free lane (§6) — right before launching compute, not
   before the build step.
3. Launches one Fargate task (0.5 vCPU/1GB) in the existing public subnets
   with `assign_public_ip=ENABLED` — no NAT Gateway needed (§ verified
   above). Task includes a `postgres:18` sidecar; app migrations run fresh.
4. Registers the task's private IP into the lane's target group.
5. Mints a client-credentials token scoped to the lane's Cognito scope from
   a dedicated test-only M2M app client.
6. Any changed frontend repo in the same linked set (running in its own
   Layer-1 sandbox, not itself needing a lane) points its API base URL at
   the lane's stage (`https://<gateway>/sandcastle-K/...`) for this check.
7. Runs the real end-to-end check against the real Gateway → authorizer →
   backend path.
8. Cleanup (§8): deregister target, stop Fargate task, discard the Postgres
   sidecar, release the lane.

**Linked vertical-slice sets share one lane** — claimed once for the whole
set, released once, not per repo. A linked set with no live backend
dependency (e.g. a pure frontend styling ticket) skips lane checkout
entirely.

## 6. Concurrency: lane coordination

One new DynamoDB table, `sandcastle-lanes` (pay-per-request, ~N rows: `free`
or `claimed`). Claiming a lane is a conditional `UpdateItem`
(`status = "free"` → `status = "claimed", claimed_by, claimed_at`) — DynamoDB's
conditional write is atomic, so two concurrent runs can never claim the same
lane. Because every AWS-level isolation boundary that already separates
`dev` from `qa` (distinct target group, now also a distinct DB) separates
lane K from lane K+1, concurrent runs' traffic physically cannot cross.

## 7. Resource inventory

| Resource | Reused as-is | Created once (N lanes provisioned upfront) | Created per run |
|---|---|---|---|
| REST API `varunerp-node-api` | ✅ same API, deployment, methods | — | — |
| Lambda authorizer | ✅ unchanged, no redeploy | — | — |
| API Gateway stage | — | ➕ N stages (`sandcastle-1..N`), each own `gwPort` | — |
| NLB | ✅ same load balancer | ➕ N listeners + N target groups, `target_type=ip` | register/deregister only |
| Cognito | ✅ same pool/resource server | ➕ N scopes + 1 shared test M2M app client | token minted, stateless |
| RDS | **not used at all** — removed from the design (§4, §5) | — | — |
| ECR | ✅ same repos | ➕ extend lifecycle policy to expire `sandcastle-*` tags | image pushed as `sandcastle-<sha>` |
| Security groups | ✅ same `vpc_link` pattern | ➕ 1 SG for ephemeral tasks (ingress from `vpc_link` SG only) | — |
| Subnets/IGW | ✅ existing public subnets — **no NAT Gateway needed** | — | — |
| Lane coordination | — | ➕ 1 DynamoDB table | claim/release writes |
| Compute | — | Fargate task definition (template) | 1 task launched + stopped |

## 8. Cleanup and rollback

Structural (the common path) — the whole lane usage wrapped in try/finally:
claim → launch task → register target → run check → **finally**: deregister,
stop task, discard DB sidecar, release lane. Runs regardless of which step
failed.

Backstop (orchestrator process itself dies) — no standing scheduler.
`ClaimLane()` is lazy-reaping: if every lane shows `claimed`, it checks each
`claimed_at` against a **10-minute TTL (locked)** — sized against the
realistic claimed-window duration once claim happens right before Fargate
launch rather than around the build/push step: task launch (~30–60s cold
start) + health-check wait (30s interval × 3 healthy threshold ≈ up to 90s)
+ smoke test (seconds to ~2 min) + cleanup (seconds) ≈ 3–6 minutes realistic,
so 10 minutes gives roughly 2x margin. A stale claim is force-reclaimed
(recorded task ARN stopped, target deregistered) before being handed to the
new run. Self-heals on the next run that needs a lane, at the cost of a lane
staying stuck for up to 10 minutes if nothing else needs one meanwhile.

## 9. Cost

| Item | Estimate |
|---|---|
| Fargate task-seconds (~5 min/run) | ~$1–5/month at a few hundred runs |
| New NLB listeners/target groups | $0 — same NLB |
| New Cognito scopes/app client | $0 — M2M clients don't count toward MAU |
| RDS | $0 — not used |
| Extra ECR tags | ~cents, bounded by lifecycle policy |
| DynamoDB (lane table) | ~cents, pay-per-request at this row count |
| **Total added** | **~$2–10/month**, against the existing ~$30/month dev EC2 baseline |

## 10. Ticket bundling: same-slice cross-repo tickets vs. sequential slices (refines §2)

`/to-tickets` (`.agents/skills/to-tickets/SKILL.md`) produces `Blocked by`
edges for two structurally different reasons that §2's "implement the whole
linked set together" glossed over:

1. **Same-slice, cross-repo halves** — one tracer-bullet slice split into a
   backend ticket + frontend ticket purely because of this project's
   one-repo-per-ticket convention (`docs/agents/issue-tracker.md`). These
   *should* be bundled — this is exactly what §2's "implement the linked set
   together" was designed for, so a real cross-repo E2E check (§5) can run
   before either merges.
2. **Genuinely sequential slices** — a later tracer-bullet slice blocked by
   an earlier one's completion (`/to-tickets`'s own frontier model: "work the
   frontier... for a linear chain that means top to bottom"). These must
   **not** be bundled — the later slice should only start once the earlier
   one is actually closed/merged, not implemented speculatively alongside
   still-open work it depends on.

Nothing before this addition let Sandcastle tell these apart — both show up
identically as a `Blocked by #N` edge. Bundling every blocked-by chain
naively would try to implement an entire multi-slice feature in one pass
(defeating the incremental tracer-bullet approach, and likely overflowing a
single sandbox's context window). Bundling nothing loses the cross-repo E2E
testing §2/§5 exist for in the first place.

**Resolution: an explicit marker, not a heuristic on blocking-edge shape.**
When `/to-tickets` publishes cross-repo tickets that are cross-repo halves of
the *same* tracer-bullet slice, tag them with a shared marker at publish
time (e.g. a `slice:<feature-slug>-<NN>` label alongside the existing
`repo:*` label). Sandcastle bundles a linked set (§2, §5) only when its
member tickets share a `slice:` marker; any other `Blocked by` edge is
treated as a real frontier dependency — Sandcastle waits for that ticket to
actually close before starting the one it blocks, matching `/to-tickets`'s
own frontier model exactly, never speculatively bundling across it.

This is a project-specific labeling convention layered on top of the
generic skill — same pattern as `repo:*` labels themselves. `/to-tickets`'s
own process (`SKILL.md`) is unchanged; the marker gets attached during its
existing step 5 publish step, or by a thin project-specific wrapper around
it — not by editing the skill.

**Open item**: exactly where/how this marker gets attached (inside
`/to-tickets`'s own publish step vs. a separate project convention) isn't
decided yet. `docs/agents/issue-tracker.md` would need a matching update
once this is settled, the same way it already documents the `repo:*`
convention — not yet made as part of this addition.

## Out of scope / open items

- **The `slice:` marker convention (§10) isn't attached anywhere yet** —
  `/to-tickets` and `docs/agents/issue-tracker.md` both still only produce/
  document plain `Blocked by` edges + `repo:*` labels. Until the marker
  exists, Sandcastle has no real signal to bundle on and must default to
  never bundling (treat every `Blocked by` edge as a frontier dependency) —
  safer than guessing, but forfeits the cross-repo E2E testing §2/§5 exist
  for until this is resolved.
- **`java-app` has no inbound Gateway path at all** (ADR-0039: outbound-only
  nightly batch worker, no REST API/Cognito scope/NLB listener exists for it
  by design). The Lane model above doesn't apply to it. Its own E2E check —
  if any — is a different, simpler thing (e.g. verify it can publish to the
  real `batch_complete` SQS queue / reach the SAP tailnet-proxy), not yet
  designed.
- **Cognito pool structure is mid-migration** ([0040](0040-nine-cognito-pool-architecture.md),
  drafted, not applied) — the Lane phase's new scope/app-client work should
  be done against whichever pool structure is actually live at
  implementation time, and may need revisiting once 0040 lands.
- **`terraform/shared`'s local state is stale/orphaned** relative to live
  AWS (confirmed via direct `aws` CLI queries — both REST APIs, all 3
  Cognito pools, the second NLB, and the authorizer Lambda exist live but
  weren't in the local `.tfstate`; the checked-in `.tf` code has also
  already drifted from reality in places, e.g. `cognito.tf` describes one
  shared pool but live AWS has three separately-named ones). This must be
  reconciled — find the authoritative state, diff the code against live
  reality, re-import — **before** any of this ADR's Terraform is written,
  not as part of it. Stale local state archived to
  `terraform/.stale-state-backup-2026-09-10/` in the AIARAP root repo.

# Testing Strategy and Architecture

Baseline testing architecture for AIARAP, agreed before feature development begins. Reached over a design-only discussion session (2026-09-12) grounded against the actual architecture — [0040](0040-nine-cognito-pool-architecture.md) (9 Cognito pools), [0042](0042-node-java-internal-service-integration.md) (Node↔Java private NLB + shared-secret auth), [0004](0004-schema-per-tenant-isolation.md) (schema-per-tenant + `global` schema), [0007](0007-rds-postgresql-over-aurora.md) (RDS Postgres) — not written from a generic template. Nothing in this ADR has been implemented; it is the agreed target shape.

## 1. Component/boundary map

```
Business UI (react-external-app)   Support UI (react-support-app)
        |  portal-<env> pool                |  support-<env> pool
        +--------------+--------------------+
                        | JWT (Cognito)
                        v
                  API Gateway
                        |
                        v
              Lambda Authorizer   <- iss -> 9-pool POOL_MAP -> JWKS verify -> stage/scope check
                        |
                        v
              Node backend (NestJS)  ---- direct read/write ----> PostgreSQL (Node-owned tables)
                        |
                        | shared-secret bearer token, private NLB (never API Gateway)
                        v
              Java sync REST (batch-job control: trigger/status/cancel)
              Spring Batch (heavy processing)         ---- direct read/write ----> PostgreSQL (Java-owned tables)
```

Four distinct auth/processing layers are kept strictly separate in test design and must never be cross-tested against each other's failure modes: **Cognito/JWT** (Gateway+Authorizer), **shared-secret** (Node↔Java), **Java REST processing**, **Spring Batch processing**.

## 2. Test categories

Full detail (what/why/catches/should-not-test/tool/location/owner/trigger/speed/test-doubles) for all eleven categories — Unit; UI Integration; API Contract; Cognito/JWT + Gateway/Authorizer (split: authorizer unit tests, and real Gateway↔Authorizer↔Cognito integration); Node → Java; Shared-secret authentication; Node → PostgreSQL; Java/Spring REST + Batch; Java → PostgreSQL; E2E; Regression — is preserved verbatim in the session's Notetaker log entry for this date (`2026-09-12-testing-strategy-and-architecture`). Summary of the load-bearing decisions from that detail:

- **Unit tests** are owned by whoever owns the code (UI/Node/Java/authorizer), run on save and every PR, always automated, never touch real infrastructure.
- **API contract tests** protect the two-UI/one-API relationship: Node generates an OpenAPI spec from its real DTOs (`@nestjs/swagger`), both UI repos consume generated TypeScript types from it, so a backend shape change becomes a compile error in the UI rather than a runtime surprise. **Pact/consumer-driven contracts rejected for now** — generated-types is the simpler mechanism for current team size; revisit only if drift slips through despite it.
- **Authorizer unit tests** cover the ~30+ pool/scope/stage/expiry failure combinations across the 9 pools using locally-signed test JWTs — no real AWS needed. **Real Gateway↔Authorizer↔Cognito integration** runs only against a genuinely deployed environment (dev today; QA once provisioned) since it exists to catch Terraform/config drift, not code logic.
- **Node → Java** and **shared-secret authentication** tests are deliberately distinct from the Cognito/JWT layer above — the NLB hop has its own transport/config failure modes (LB routing, multi-instance failover) and the shared-secret filter has its own auth failure modes (missing/wrong/stale/wrong-environment secret), neither of which has anything to do with scopes or JWKS.
- **Node → PostgreSQL** and **Java → PostgreSQL** are both real, Testcontainers-backed (`postgres:18`), never mocked or substituted with H2/SQLite, since schema-per-tenant + JSONB behavior is Postgres-specific. Node has direct Postgres access for transactional CRUD; Java is primarily heavy-batch, plus a synchronous REST surface used mainly for batch-job control (trigger/status/cancel), not general business logic.
- **E2E** (Playwright) covers only critical business journeys per UI, real Cognito/Gateway/backend chain throughout — no mocking, by design. **Deferred**: no E2E infrastructure exists yet (see §5).
- **Regression** is a practice (re-running the above), not a separate framework.

## 3. Pyramid emphasis

Roughly: **~55% unit, ~5% contract, ~12% UI integration, ~22% service/boundary integration, ~5% E2E** (by test count, not effort). The integration layer is deliberately fatter than a textbook pyramid because AWS infrastructure (Gateway, Lambda, NLB, Cognito) is a first-class part of this architecture and a category of bug (misconfiguration) that no unit test can see.

## 4. CI/CD stages

- **Local**: unit + UI integration always; Node→Java→Postgres integration made easy to run but **not** enforced pre-push.
- **Every PR**: unit, contract, UI integration, boundary integration (authorizer unit, shared-secret, Node→Java, Node→DB, Java→DB, Spring Batch correctness) — all automated CI gates.
- **After deploy to dev**: real Gateway/Authorizer/Cognito check.
- **After deploy to QA/staging**: full integration re-run + full Playwright E2E — **conditional on that environment actually being provisioned (see §5)**.
- **Pre-release**: full regression + business acceptance testing (manual) + exploratory testing (manual).
- **Post-production**: automated non-destructive smoke check on every deploy; manual spot-check only for releases flagged high-risk.

## 5. Deliberately deferred (not gaps — decisions)

- **QA/staging environment**: not provisioned now; provisioned only once the first feature is dev-complete and QA-ready. Several rows in §4 depend on this.
- **E2E test infrastructure/orchestration**: not built now. A prior design for this existed and was withdrawn — its number is retired and is not to be cited as a live reference (see the Notetaker log entry `2026-09-11-sandcastle-aws-inventory-and-design-record` for the withdrawn design's content and lessons). Any future rebuild must: (a) never build isolated-environment infrastructure on top of a shared deployment (the withdrawal's core lesson — teardown coupling to the shared `node-dev` deployment was the one real cost of that design), (b) prove the orchestrator against one real lane before provisioning a pool, (c) design the teardown path alongside the create path, (d) start minimal.
- **Pact/consumer-driven contracts**: rejected for now in favor of generated-OpenAPI-types; revisit only if that proves insufficient.
- **CODEOWNERS / automated table-ownership enforcement**: not introduced now (see §6).

## 6. Database migration model and table ownership

**Migrations**: one shared Flyway migration history — not two separate tools (Java keeps Flyway; Node does **not** adopt a second migration tool). Location: a folder under `AIARAP---DOCUMENTATION` (not a new repo), treated as shared/cross-cutting infrastructure the same way `terraform/shared` already is. Not yet moved: the one existing migration (`AIARAP-spring-backend/src/main/resources/db/migration/V1__create_customer_table.sql`) stays where it is until this is acted on.

**Table ownership**: single-writer-per-table is the default — each table is written by exactly one of Node or Java, the other only reads directly if needed. Genuinely dual-written tables are treated as a rare, explicit exception requiring real concurrency handling (e.g. optimistic locking), not a default pattern. Ownership is recorded structurally, via owner-named subfolders in the shared migration location (`node-owned/`, `java-owned/`, `shared/` for exceptions) rather than a separate document that can drift out of sync.

**Enforcement**: a **documented team convention only** at this stage — no CODEOWNERS, no custom CI ownership-validation tooling. There is no DB-level enforcement of table ownership (consistent with the existing statement in `AIARAP-spring-backend/README.md` that this is "an application-level convention, not DB-enforced"). Revisit enforcement only if ownership conflicts become a real, observed problem.

**Still open, factual not architectural**: whether any already-created table genuinely needs writes from both Node and Java — unresolved, answerable only by reviewing the actual schema; until answered, single-writer-per-table is the operating assumption.

## 7. Cross-repo integration test ownership

Node↔Java boundary tests (NLB routing, shared-secret negative cases) live in **`AIARAP-spring-backend`**, exercised by constructing requests shaped exactly like Node's real client calls (real shared-secret header, real body) against a running Java instance — chosen over a dedicated `AIARAP-integration-tests` repo (rejected: would repeat the same before-it's-needed infrastructure pattern as the withdrawn E2E design) and over `AIARAP-node-backend` (would require booting the full Node app in Java's CI unnecessarily). Node's own CI separately covers its client's retry/timeout/error-handling behavior against a locally-run Java container — that stays in Node's own repo as an ordinary integration test of Node's own code, not a cross-repo test.

## 8. Automated vs. manual execution model

**Always automated, no manual equivalent needed**: unit, UI integration, API contract, Node→Java (routine), shared-secret auth, Node→DB, Java→DB, regression — all deterministic pass/fail, run locally and/or in CI.

**Genuinely require human judgment, must not be fully automated**:
- **Exploratory testing** (QA, ad hoc/each QA cycle) — the value is a human finding what no fixed assertion anticipated; automating it stops it being exploratory.
- **Business acceptance testing** (business stakeholders, facilitated by QA, before release sign-off) — asks whether a feature satisfies real business intent, a subjective judgment no test suite can make.

**Deliberately both** (automated routine layer + manual judgment for the first-time/high-risk case):
- Gateway/Authorizer/Cognito real integration — automated known-case check + human review of any real IAM/pool/scope Terraform change.
- Spring Batch — automated mechanics (idempotency/restart) + human review of actual output data the first time a new job type runs at real volume.
- E2E — human walkthrough of a brand-new journey once, before it becomes a repeatable Playwright script.
- Production smoke testing — automated baseline on every deploy + manual spot-check reserved for releases the release team flags as high-risk.

## 9. Token-consumption analysis

No component of the application itself calls an LLM anywhere (confirmed by ADR search — AIARAP has no chatbot/embedding/LLM feature), so **every one of the eleven test categories above consumes zero AI tokens when executed**, locally or in CI, regardless of frequency. The only place AI tokens enter this system at all is human- or agent-driven development activity around the tests (writing a test, triaging a CI failure, a design session like this one) — occasional and developer-initiated, not a property of the test architecture or the CI pipeline. The one design element that would make token cost structural rather than occasional is a future AI-orchestrated implement→test→iterate agent loop, which is explicitly not built (§5).

## Open items carried forward

- Migration/ownership-folder restructuring: designed, not yet executed.
- Whether any existing table needs dual writes: unanswered.
- QA environment and E2E infrastructure: intentionally not provisioned yet.

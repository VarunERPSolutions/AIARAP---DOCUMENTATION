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

Full detail for all eleven categories — what/why/catches/should-not-test/tool/location/owner/trigger/speed/test-doubles/where-it-runs.

### 2.1 Unit tests

| | |
|---|---|
| What | Isolated logic: NestJS services/pipes, React component logic/hooks, Spring `@Service`/util classes, authorizer pool-match/scope logic |
| Why | Cheapest, fastest place to catch a logic bug |
| Catches | Wrong branches, off-by-ones, bad validation, incorrect authorizer matching logic |
| Should NOT test | Real Cognito, real Postgres, real HTTP between services, browser rendering |
| Tool | Jest (Node, React, authorizer Lambda), JUnit5/Mockito (Java) |
| Lives in | Each repo, next to source (`*.spec.ts` / `*Test.java`) |
| Owner | Whoever owns the code (UI/Node/Java devs) |
| Trigger | Local save (watch mode) + every commit + every PR |
| Speed | Very fast |
| Doubles | Mocks/stubs for everything external |
| Runs | Locally + CI (every PR) |

### 2.2 UI Integration tests

| | |
|---|---|
| What | Multiple pieces within one UI app: form→validation→state→API client, routing, auth-guard behavior |
| Why | Proves internal wiring within one app, not just isolated units |
| Catches | Broken prop/state wiring, wrong API-client call shape, auth-guard letting an unauthenticated route through |
| Should NOT test | Real backend response shape (contract tests' job), full login journeys (E2E's job) |
| Tool | React Testing Library + Jest/Vitest, MSW for the API layer |
| Lives in | `AIARAP-external-app`, `AIARAP-support-app`, each independently |
| Owner | UI developers, per app |
| Trigger | Local dev + every PR |
| Speed | Fast |
| Doubles | Mocked API (MSW), jsdom |
| Runs | Locally + CI (every PR) |

### 2.3 API Contract tests

| | |
|---|---|
| What | Node's real OpenAPI spec (generated from DTOs) vs. each UI's actual consumption, via generated TS types |
| Why | Two independent UIs consume one API — a silent shape change can break one or both UIs without either UI's own mocked tests noticing |
| Catches | Backend response/request shape drift before it reaches either UI at runtime |
| Should NOT test | Business logic correctness, UI rendering, auth |
| Tool | `@nestjs/swagger`-generated OpenAPI spec + generated TypeScript types consumed by both UI repos |
| Lives in | Spec generated in `AIARAP-node-backend`; generated types consumed/checked in each UI repo's build |
| Owner | Shared — Node owns the spec, each UI owns keeping its generated types current |
| Trigger | Every PR changing Node DTOs; every PR in either UI repo that changes API consumption |
| Speed | Very fast (schema/type diff, no network) |
| Doubles | N/A |
| Runs | CI only, every relevant PR |

**Pact/consumer-driven contracts rejected for now** — generated-types is the simpler mechanism for current team size; revisit only if drift slips through despite it.

### 2.4 Cognito/JWT + Gateway/Authorizer integration tests

**(a) Authorizer unit tests** — logic only:

| | |
|---|---|
| What | Given a JWT payload + `POOL_MAP`, correct Allow/Deny: valid, expired, wrong `iss`, stage/pool-env mismatch, missing/wrong scope, malformed token |
| Why | 9 pools × failure modes is dozens of cases — proving branch logic in ms beats provisioning real Cognito users for each |
| Catches | Logic bugs in pool-matching/scope/stage checks |
| Should NOT test | Whether API Gateway actually invokes the Lambda, real JWKS network behavior |
| Tool | Jest, locally-signed test JWTs (own test keypair) |
| Lives in | `terraform/modules/lambda-authorizer` |
| Owner | Backend/platform developer owning the authorizer |
| Trigger | Every PR touching authorizer code / `POOL_MAP` |
| Speed | Very fast |
| Doubles | Locally-signed JWTs, mocked JWKS |
| Runs | Locally + CI |

**(b) Real Gateway↔Authorizer↔Cognito integration**:

| | |
|---|---|
| What | Real request → real deployed Gateway → real Lambda → real Cognito-issued token against a real pool |
| Why | Terraform/config can be wrong even when code is perfect |
| Catches | Misconfigured Gateway↔authorizer wiring, wrong pool/env mapping, real JWKS-fetch failures |
| Should NOT test | Node's own business logic behind the gateway |
| Tool | Small Jest/script hitting deployed Gateway with a real token from a dedicated test user |
| Lives in | Alongside the Terraform it verifies, in `AIARAP---DOCUMENTATION/terraform/shared` |
| Owner | Shared — backend/platform devs write, QA runs broadly |
| Trigger | After every deploy to dev; on PRs touching Gateway/Cognito/authorizer Terraform |
| Speed | Medium |
| Doubles | None — real Cognito, Gateway, Lambda |
| Runs | Post-deploy (dev now; QA once provisioned), CI for relevant Terraform PRs |

### 2.5 Node → Java integration tests

| | |
|---|---|
| What | Node's client calling real/containerized Java over the internal NLB path; the cross-repo boundary suite (hosted in `AIARAP-spring-backend`, see §7) sends Node-shaped requests |
| Why | Node and Java can each pass their own unit tests while LB routing, health checks, or client config is wrong |
| Catches | Wrong service URL, LB target-group/health-check misconfig, failed multi-instance failover, timeout/retry bugs |
| Should NOT test | JWT/Cognito concerns — irrelevant on this hop, a different auth model entirely |
| Tool | Java-side: Spring test constructing Node-shaped HTTP requests. Node-side (own client behavior only): Jest/supertest against a locally containerized Java |
| Lives in | Boundary suite: `AIARAP-spring-backend`. Node's own client tests: `AIARAP-node-backend` |
| Owner | Java developers (boundary suite); Node developers (own client tests) |
| Trigger | PR touching either side's relevant code; nightly against dev |
| Speed | Medium |
| Doubles | Real Java container — never mocked |
| Runs | Locally (optional) + CI (enforced gate) |

### 2.6 Shared-secret authentication tests

| | |
|---|---|
| What | `InternalServiceAuthFilter`: correct secret→200, missing header→401, wrong/stale secret→401, wrong-environment secret→401 |
| Why | Bespoke auth mechanism, unrelated to Cognito/JWKS/scopes — needs its own explicit negative-case coverage |
| Catches | Filter bypass bugs, rotation breaking one side but not the other, cross-environment secret leakage |
| Should NOT test | Business payload correctness — pure auth-gate testing |
| Tool | JUnit5/MockMvc (filter unit tests); negative cases folded into the Java-hosted boundary suite |
| Lives in | `AIARAP-spring-backend` |
| Owner | Java developers (filter logic); Node developers (client-side 401 handling) |
| Trigger | Every PR touching the filter/secret-loading code; manual check before any secret rotation |
| Speed | Very fast (unit) to fast (integration) |
| Doubles | Real filter code, deliberately wrong/rotated secret values |
| Runs | Locally + CI |

### 2.7 Node → PostgreSQL integration tests

| | |
|---|---|
| What | Node's direct CRUD against real Postgres: schema-per-tenant queries, cross-schema reads into `global`, transaction behavior |
| Why | Node has direct DB access — mocking proves nothing about real SQL/query correctness |
| Catches | Bad queries, incorrect schema-per-tenant handling, transaction/rollback bugs on the Node side |
| Should NOT test | Java's batch-specific DB concerns |
| Tool | Testcontainers (`postgres:18`) |
| Lives in | `AIARAP-node-backend` |
| Owner | Node developers |
| Trigger | Every PR touching Node's queries/entities |
| Speed | Medium (container startup + real queries) |
| Doubles | Real Postgres via Testcontainers — never mocked |
| Runs | Locally (optional) + CI (enforced gate) |

### 2.8 Java/Spring REST + Batch tests

| | |
|---|---|
| What | Sync `/internal/v1/*` endpoint correctness (largely batch-job control: trigger/status/cancel) and Spring Batch job/step/chunk logic, restart, idempotency |
| Why | Two execution models sharing one deployable — different failure classes |
| Catches | Wrong response shape/status codes (REST); non-idempotent reruns, bad restart semantics, silently-swallowed partial failures (Batch) |
| Should NOT test | Network/LB routing, shared-secret filter internals |
| Tool | `@SpringBootTest` + MockMvc/WebTestClient (REST); Spring Batch's `JobLauncherTestUtils`/`JobRepositoryTestUtils` (batch) |
| Lives in | `AIARAP-spring-backend` |
| Owner | Java developers |
| Trigger | Every PR touching sync endpoints or batch job/step config; nightly full-volume batch run |
| Speed | Fast–medium (REST); medium–slow (nightly full-volume batch) |
| Doubles | Testcontainers Postgres where DB-touching |
| Runs | Locally + CI (every PR); nightly (full-volume batch) |

### 2.9 Java → PostgreSQL integration tests

| | |
|---|---|
| What | Java-owned tables: real SQL/JPA mappings, schema-per-tenant + `global` cross-schema FKs, JSONB custom-field queries, batch staging-table behavior |
| Why | Mocking proves nothing about real migrations/queries; schema-per-tenant and JSONB are Postgres-specific |
| Catches | Bad migrations, incorrect cross-schema handling, JSONB query bugs, batch staging/promotion logic errors |
| Should NOT test | Node-owned table behavior |
| Tool | Testcontainers (`postgres:18`) |
| Lives in | `AIARAP-spring-backend` |
| Owner | Java developers |
| Trigger | Every PR touching entities/migrations/queries for Java-owned tables |
| Speed | Medium |
| Doubles | Real Postgres via Testcontainers — never mocked/H2 |
| Runs | Locally (optional) + CI (enforced gate) |

### 2.10 E2E tests

| | |
|---|---|
| What | Full user journeys, real browser: login (real Cognito) → UI action → Gateway → authorizer → Node → Java → DB → verify, for both UIs |
| Why | Only level proving the whole wired-together system as a real user experiences it |
| Catches | Cross-boundary combinations no single-layer test can — e.g. UI hitting the wrong endpoint despite every layer individually working |
| Should NOT test | Exhaustive UI interactions/edge cases — critical business journeys only |
| Tool | Playwright |
| Lives in | Its own location, reaching across all app repos — not built yet, deferred (see §5) |
| Owner | QA automation primarily; developers must be able to run/debug |
| Trigger | Small critical-path subset on PR (only once isolated E2E env exists); full suite post-QA-deploy; full run pre-release |
| Speed | Slowest category |
| Doubles | None by design — real Cognito, Gateway, backend chain, isolated test DB |
| Runs | Not currently runnable — infrastructure deferred |

### 2.11 Regression testing

Not a separate framework — the purpose of re-running everything above. Owned by CI (automatic re-run) + developers (fix) + QA (triage business impact). Triggered on every PR, every deploy, and as a full-suite run pre-release.

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

| Test | Automated/Manual | Who triggers | When | Where | Tool | Why |
|---|---|---|---|---|---|---|
| Unit | Automated | Developer (local), CI | On save, every commit, every PR | Dev machine, CI | Jest / JUnit | Deterministic, cheap, repeatable |
| UI Integration | Automated | Developer (local), CI | On save, every PR | Dev machine, CI | RTL + Jest/Vitest + MSW | Deterministic DOM/state assertions |
| API Contract | Automated | CI | Every PR touching Node DTOs or UI API consumption | CI | Generated OpenAPI spec + generated TS types | Deterministic schema/type diff |
| Cognito/JWT + Gateway/Authorizer | Both | CI (unit); CI/CD post-deploy (real integration); QA (manual spot-check) | Unit: every PR. Real: after deploy. Manual: on meaningful Terraform/Cognito changes | CI; Dev/QA env; human review | Jest w/ signed JWTs; Jest/script vs real Gateway | Automated pieces are deterministic; a human should still eyeball IAM/pool/scope Terraform changes |
| Node → Java | Automated | Developer (local, optional), CI | PR; nightly against dev | Dev machine (optional), CI | Jest/supertest; Spring test (boundary suite) | Deterministic network/config behavior |
| Shared-secret auth | Automated | CI | Every PR touching filter/secret logic | CI | JUnit5/MockMvc | Deterministic accept/reject logic |
| Node → PostgreSQL | Automated | Developer (local, optional), CI | Every PR touching Node queries/entities | Dev machine (optional), CI | Testcontainers | Deterministic SQL behavior |
| Java → PostgreSQL | Automated | Developer (local, optional), CI | Every PR touching Java-owned entities/migrations | Dev machine (optional), CI | Testcontainers | Deterministic SQL behavior |
| Spring Batch | Both | CI (correctness/idempotency); QA/business (first-run data review) | CI: every PR + nightly. Manual: first time a new job type runs at real volume | CI; QA/staging | Spring Batch test utils + Testcontainers | Mechanics automatable; whether output data is actually correct the first time needs a human look |
| E2E | Both | QA/developer (manual first pass); CI/CD or QA (automated critical-path) | Manual: first time a new journey is built. Automated: every run after, post-QA-deploy, pre-release | QA/staging (once provisioned) | Playwright (automated); human walkthrough (manual) | A new journey needs a human to confirm it's the right one before it's locked into a repeatable script |
| Regression | Automated | CI | Every PR, every deploy, pre-release | CI | Re-run of all suites | Just re-execution, no new judgment needed |
| Exploratory testing | Manual | QA | Ad hoc, each QA cycle, before release | QA/staging | None (session notes) | By definition finds what fixed assertions can't anticipate |
| Business acceptance testing | Manual | Business stakeholders / product owner, via QA | End of a feature's QA cycle, before release sign-off | QA/staging | None (demo/checklist) | Subjective business-fit judgment, not a pass/fail assertion |
| Production smoke testing | Both | CI/CD (automated baseline); release team (manual, high-risk releases) | Automated: immediately after every prod deploy. Manual: additionally for major releases | Production | Small non-destructive script/synthetic check | Automated for routine confidence; manual spot-check reserved for high-risk releases |

**Always automated, no manual equivalent needed**: unit, UI integration, API contract, Node→Java (routine), shared-secret auth, Node→DB, Java→DB, regression.

**Genuinely require human judgment, must not be fully automated**: exploratory testing (the value is a human finding what no fixed assertion anticipated) and business acceptance testing (asks whether a feature satisfies real business intent — a subjective judgment no test suite can make).

**Deliberately both**: Gateway/Authorizer/Cognito real integration, Spring Batch, E2E, and production smoke testing all pair an automated routine layer with manual judgment reserved for the first-time or high-risk case.

## 9. Token-consumption analysis

No component of the application itself calls an LLM anywhere (confirmed by ADR search — AIARAP has no chatbot/embedding/LLM feature), so **every one of the eleven test categories consumes zero AI tokens when executed**, locally or in CI, regardless of frequency.

| Test | AI tokens? | Which component | Why | Approx. usage | When |
|---|---|---|---|---|---|
| Unit | No | — | Deterministic code execution | 0 | Local, every PR |
| UI Integration | No | — | Deterministic component/DOM testing | 0 | Local, every PR |
| API Contract | No | — | Deterministic schema/type diff | 0 | Every PR |
| Cognito/JWT + Gateway/Authorizer (unit) | No | — | Deterministic JWT decode/verify against test keys | 0 | Local, every PR |
| Cognito/JWT + Gateway/Authorizer (real integration) | No | — | Deterministic HTTP calls to real AWS services | 0 | Post-deploy |
| Node → Java | No | — | Deterministic HTTP over the internal NLB | 0 | Local, PR, nightly |
| Shared-secret auth | No | — | Deterministic header/secret comparison | 0 | Every PR |
| Node → PostgreSQL | No | — | Deterministic SQL via Testcontainers | 0 | Local, every PR |
| Java → PostgreSQL | No | — | Deterministic SQL via Testcontainers | 0 | Local, every PR |
| Java/Spring REST + Batch | No | — | Deterministic Spring test execution, chunked batch logic | 0 | Every PR, nightly |
| E2E (Playwright) | No, for test execution itself | — | Deterministic browser automation | 0 | Post-QA-deploy, pre-release (once infra exists) |
| Regression | No | — | Re-running the above, still deterministic | 0 | Every PR, every deploy, pre-release |

The only place AI tokens enter this system at all is human- or agent-driven development activity around the tests (writing a test, triaging a CI failure, a design session like this one) — occasional and developer-initiated, not a property of the test architecture or the CI pipeline:

| Activity | Rating | Why |
|---|---|---|
| Writing a single unit test with AI assistance | Low | Small diff, small context, one-shot |
| Writing a new integration/E2E suite from scratch with AI assistance | Medium | More surrounding context needed per session, but a one-off |
| Triaging one CI failure | Low | Small, bounded input, occasional |
| Triaging a whole failed suite (many red tests, long logs) | Medium | Larger log volume, more back-and-forth |
| A design/architecture session (like this one) | Medium | Long conversation, large accumulated context, but infrequent |
| A future Sandcastle-style implement→test→iterate agent loop, if rebuilt | High, and recurring | Runs repeatedly per feature/ticket, feeding diffs + logs + iteration history back each pass — the only element that would make token cost structural rather than occasional |

**Overall, for the architecture as decided (no such loop built): Low.**

## Open items carried forward

- Migration/ownership-folder restructuring: designed, not yet executed.
- Whether any existing table needs dual writes: unanswered.
- QA environment and E2E infrastructure: intentionally not provisioned yet.

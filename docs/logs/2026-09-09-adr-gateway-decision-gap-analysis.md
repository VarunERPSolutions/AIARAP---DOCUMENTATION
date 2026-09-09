# API Gateway Decision — ADR Gap Analysis

**Date:** 2026-09-09
**Excel row:** `AIARAP_Daily_Implementation_Log.xlsx`, sheet "Daily Log" — "API Gateway decision: ADR gap analysis (research only, no changes)"

## Source documents used
- All 40 ADRs in `AIARAP---DOCUMENTATION\docs\adr\`
- `docs\infra\architecture-diagram.html`
- The untracked, non-git top-level `AIARAP\docs\adr\0003-shared-api-gateway.md` (for contrast only)

## Process followed
User asked a sequence of questions probing whether the tracked ADR set documents the decision to use API Gateway, whether it's AWS's own service vs. a custom one, and whether the Node/SAP split into two REST APIs is documented. Answered each by direct search (`grep`) of the tracked repo only, per the user's earlier explicit instruction to always work in `AIARAP---DOCUMENTATION`, not the loose top-level `docs/` folder.

**Findings, all confirmed by direct grep/read, no assumptions:**
1. No ADR in the tracked repo is dedicated to "use AWS API Gateway" — it's only mentioned in passing inside ADR-0038 and ADR-0040, both of which assume it's already decided.
2. The phrase "AWS API Gateway" (explicitly naming the vendor) appears **zero times** anywhere in the tracked repo. It only appears, with an explicit alternatives-considered rationale (vs. Kong/nginx), in the untracked `docs/adr/0003-shared-api-gateway.md` — a different, non-git-tracked file.
3. `architecture-diagram.html` mentions "API Gateway" extensively (Figures 2, 4, 5), including Figure 3's caption using its *absence* to contrast Java's internal-only SAP path — but always assumes it, never argues for choosing it.
4. The Node/SAP two-REST-API split **is** documented (`apis.tf`'s own comment, `architecture-diagram.html` Figure 2, `terraform/shared/README.md`) but only descriptively — no ADR argues *why* they're split rather than one REST API with two path prefixes.

## Outcome
No files changed — this was pure research/documentation-gap-finding at the user's request. Two concrete, reusable findings surfaced for a future ADR-writing task:
- The AWS API Gateway vendor-choice decision (with its Kong/nginx alternative already reasoned through in the untracked file) needs to be brought into the tracked `AIARAP---DOCUMENTATION` repo as a real ADR.
- The Node/SAP REST API split needs its own documented rationale, currently missing entirely.

## Open items / notes for future sessions
User has not yet asked to actually draft these ADRs — offered twice, not yet actioned. If asked next session, the untracked `docs/adr/0003-shared-api-gateway.md` (and its siblings 0004/0005) are the best starting source material to port in and formalize within the tracked ADR numbering (next free number: 0041).

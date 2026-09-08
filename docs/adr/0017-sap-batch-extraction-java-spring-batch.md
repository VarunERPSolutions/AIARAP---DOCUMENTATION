# SAP Batch Extraction: Polyglot Java/Spring Batch Service for Nightly Bulk Loads

**Superseded by [ADR-0039](0039-sap-integration-technology-and-backend-stack.md).** Originally decided: nightly bulk extraction from Tenants' SAP systems is handled by a dedicated Java + Spring Batch service (staging tables, SQS handoff, NestJS-owned promotion), narrowly carved out of ADR-0009's single-stack backend. Its scope later broadened to all SAP integration, not just nightly batch (see ADR-0039) — kept here as a historical record.

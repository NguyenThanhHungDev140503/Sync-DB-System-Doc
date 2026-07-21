# Snapshot Isolation Decision

**Date:** 2026-07-19
**Context:** Central DB Sync Phase 1 Pilot — MSSQL → PostgreSQL sync for CRM.Partners

## Problem

`SqlServerPartnersReader.cs` (bootstrap + CT incremental readers) used `IsolationLevel.Snapshot`
to ensure a consistent read of the source table and change tracking version within one transaction.

This requires `ALLOW_SNAPSHOT_ISOLATION ON` on the source database (`UA-DEV-2026-T04S3`),
which is a shared dev database used by the entire team.

## Impact of enabling Snapshot Isolation

- Affects **all tables** in the database, not just CT-enabled ones
- SQL Server maintains a row version store in tempdb for every UPDATE/DELETE on any table
- No change to default READ COMMITTED behavior — only sessions that explicitly opt-in are affected
- For a dev DB with small data volume, the performance impact is negligible
- However, the team preferred not to alter the shared dev DB configuration

## Decision

**Do NOT enable ALLOW_SNAPSHOT_ISOLATION** on the dev database.

Instead, the code was changed to:
- Use `IsolationLevel.ReadCommitted` instead of `Snapshot`
- Add `WITH (READPAST)` hint to skip dirty rows (instead of blocking)
- For bootstrap: capture CT version → read data → re-check CT version; retry up to 3 times if the version changed during the read
- For CT incremental: `WITH (READPAST)` on the LEFT JOIN to source table in the CT query

This approach avoids any database-level configuration change while maintaining read consistency
(verify-before-commit pattern with bounded retry).

## Files changed

- `Infrastructure/CentralDbSync/SqlServerPartnersReader.cs` — both `IBootstrapSnapshotReader.ReadAsync`
  and `IChangeTrackingReader.ReadBatchAsync` methods

## Future consideration

If the sync expands to many tables with large data volumes in production,
`ALLOW_SNAPSHOT_ISOLATION` should be reconsidered as the standard approach for ETL consistency.

# Design: Central DB Sync Background Bootstrap at Scale

**Date:** 2026-07-21  
**Status:** Approved & implemented — Phase 1 complete  
**Scope:** `CRM.Partners` pilot initial target

## Goal

Make manual Central DB bootstrap safe for a source table with millions of rows.

The work is split into two delivery phases:

1. The HTTP API accepts a bootstrap request and enqueues durable background work instead of waiting for the full operation.
2. The bootstrap pipeline stages source rows in bounded batches so the application process does not materialize the full snapshot in memory before publishing it.

`report.partners` is the currently published Central DB data used by future Central DB API, BI, and reporting consumers. No existing consumer may see a partially imported snapshot.

## Existing Constraints

- The solution is .NET 10 Clean Architecture. `Application` owns provider-neutral contracts and orchestration; `Infrastructure` owns SQL Server, PostgreSQL, and Hangfire details.
- The existing pilot is `CRM.Partners` from the ERP primary SQL Server to PostgreSQL `report.partners`.
- The existing per-table PostgreSQL advisory lock and checkpoint compare-and-swap remain the correctness boundary. Hangfire coordination is supplementary only.
- The current bootstrap API waits for `BootstrapSyncService.ExecuteAsync`, even though it responds with HTTP 202 after the work completes. That behavior must change.
- Existing `sync_meta.sync_run_log` remains the execution audit log. New request metadata supplements it; it does not replace it.
- For pilot development and early phases, the existing Admin guard remains disabled as documented. It must be enabled for Production deployment.

## Non-goals

- Do not change the recurring Change Tracking schedule or its one-minute cadence.
- Do not add an end-user cancellation endpoint in this delivery.
- Do not introduce a separate worker service, a second queueing product, or all-table point-in-time consistency.
- Do not implement the Phase B vocabulary tables.
- Do not expose source payloads, credentials, or connection strings in API responses or logs.

## Phase 1: Durable Background Bootstrap Request

### User-visible behavior

`POST /api/central-db-sync/bootstrap/{sourceTable}` validates the registered table and the current environment authorization policy, then returns immediately:

```json
{
  "requestId": "UUID",
  "hangfireJobId": "string",
  "sourceTable": "CRM.Partners",
  "status": "Queued",
  "statusUrl": "/api/central-db-sync/bootstrap/{requestId}"
}
```

If an active bootstrap request already exists for the same source table, the endpoint returns HTTP 202 with that existing request and job identifier. Repeated button clicks therefore do not create concurrent bootstrap requests.

The status endpoint returns the request state, staged-row progress, timestamps, retry count, and safe error summary. It does not return source row data.

### Request metadata

Add PostgreSQL table `sync_meta.bootstrap_request`. It stores the durable "work ticket" for one manual bootstrap request:

| Field | Purpose |
|---|---|
| `request_id` | UUID exposed by the API and passed to the job |
| `source_table` | Canonical table name, initially `CRM.Partners` |
| `status` | `PendingEnqueue`, `Queued`, `Running`, `WaitingForLock`, `Completed`, or `Failed` |
| `hangfire_job_id` | Identifier returned by Hangfire after enqueueing |
| `rows_staged` / `total_rows_expected` | Import progress; total is captured from the source snapshot |
| `attempt_count` | Controlled retry count |
| timestamps | Requested, started, completed, and last-updated times |
| safe error fields | Bounded error code and message only |

A partial unique index permits at most one active request per `source_table`, where active means `PendingEnqueue`, `Queued`, `Running`, or `WaitingForLock`.

`sync_meta.sync_run_log` continues to receive the detailed execution outcome (`succeeded`, `failed`, `skipped_locked`, and row/checkpoint counters). Every bootstrap execution receives the same `request_id` as its `run_id` so operators can correlate the HTTP request, Hangfire job, structured logs, and PostgreSQL run log.

### Cross-storage enqueue protocol

Hangfire storage and Central DB are separate stores, so no distributed transaction is assumed.

1. Atomically create a `PendingEnqueue` request row, or return the existing active request.
2. Schedule a one-shot watchdog (45s delay). If process crashes between here and step 4, the watchdog fires and re-enqueues.
3. Enqueue `CentralDbSyncJobs.RunBootstrapAsync(sourceTable, requestId)` through `IBackgroundJobClient`.
4. Save the returned Hangfire job identifier and transition the request to `Queued`.
5. If enqueueing fails, mark the request `Failed` with a safe enqueue error.

The job type must be resolvable through the existing ASP.NET Core DI container. Only small serializable values (`sourceTable` and `requestId`) are job arguments; no connections, services, or source data are serialized into Hangfire.

### Job lifecycle and concurrency

The Hangfire job atomically claims its request, transitions it to `Running`, then calls the existing bootstrap service path with the supplied run ID.

```text
HTTP request -> bootstrap_request -> Hangfire data-sync queue
                                      |
                                      v
                         advisory lock for CRM.Partners
                                      |
                                      v
                  bootstrap service -> run log + request status
```

The PostgreSQL advisory lock remains held for the full bootstrap operation. If a recurring CT run or recovery currently owns it, the manual request becomes `WaitingForLock`, is rescheduled with bounded delay, and remains the active request. It is not falsely recorded as a successful bootstrap. CT jobs that encounter a bootstrap-owned lock retain their existing explicit `skipped_locked` behavior.

`DisableConcurrentExecution` may remain as a Hangfire-level optimization, but no correctness rule relies on it. The advisory lock, idempotent staging writes, and checkpoint compare-and-swap protect against duplicate processing after retries or process failures.

### Orphan recovery, retry and restart behavior

- Per-request one-shot watchdog (delay=45s) recovers requests stuck in `PendingEnqueue` after a crash between steps 1 and 3 of the enqueue protocol. Not a recurring poll.
- The old 5-minute batch reconciliation (`ReconcilePendingBootstrapRequestsAsync`) is retained for manual ops recovery; not registered as a recurring job.
- Retriable PostgreSQL network, timeout, deadlock, and connection-interruption errors use bounded delayed retry with the same request ID.
- Mapping, validation, source-read, and constraint errors fail without blind retry and require operator remediation before a new request is submitted.
- A process restart does not create a new request: Hangfire retains queued work, and the request row identifies its current lifecycle state.
- No cancellation API is added. Operators use request status and a remedied new request after a terminal failure.

## Phase 2: Bounded Staging and Atomic Publish

### Why staging is required

The current `BootstrapSnapshot` materializes all source rows in memory. That is acceptable only when the measured source size fits the application memory budget. For millions of rows, the bootstrap must transfer bounded batches to a staging area instead.

Staging is a private loading area. `report.partners` remains unchanged until every source batch is complete and the final publish transaction succeeds.

### Staging schema and batch contract

Add `sync_meta.partner_bootstrap_staging` with `request_id` plus the mapped partner columns needed to publish `report.partners`. Its primary key is `(request_id, partner_id)`, making repeated writes for the same request idempotent. It is not readable by reporting consumers.

For a bootstrap request:

1. Acquire the existing table advisory lock.
2. On one ERP SQL Server connection and one `SNAPSHOT` transaction, capture `CHANGE_TRACKING_CURRENT_VERSION()` as the baseline and calculate `total_rows_expected`.
3. Read the source deterministically in batches of 10,000 rows. Each batch is mapped, validated, deduplicated through the staging primary key, and committed to PostgreSQL staging before the next batch is read.
4. After the final batch and EOF, mark staging complete for the request.
5. Publish from staging in one PostgreSQL transaction: upsert active rows, soft-deactivate rows in the pilot ownership scope that are absent or filtered out, advance checkpoint to the captured baseline with the existing optimistic guard, write `sync_run_log`, and mark the request `Completed`.
6. Release the advisory lock.

The SQL Server snapshot transaction is intentionally held while the source is read, so the staging input represents the same source boundary as the baseline checkpoint. Before production enablement, operations and the ERP DBA must confirm that the expected duration and SQL Server version-store capacity support this source transaction.

The final publish is the only point where `report.partners` changes. It either commits target lifecycle changes, checkpoint, and run log together, or leaves the previously published Central DB data untouched.

### Failure, cleanup, and progress

- If reading, mapping, or staging fails, do not publish. `report.partners` and its checkpoint remain at the prior successful state.
- Retrying a staging batch for the same request ID is safe because the staging primary key makes it idempotent.
- The request row updates `rows_staged` after each committed batch. While the source count is available, the status endpoint can show progress such as `1,200,000 / 4,800,000` rows.
- On terminal failure, attempt to remove that request's staging data immediately. A daily cleanup job removes any leftover staging rows for terminal requests older than 24 hours and records cleanup failures safely.
- A failure is written to the existing `sync_meta.sync_run_log` as `failed`; the request table also records the user-facing request state and safe error summary.

## Component Boundaries

| Layer | New or changed responsibility |
|---|---|
| `Application` | Provider-neutral request/staging contracts, request coordinator, status model, and run-ID propagation |
| `Infrastructure` | PostgreSQL request/staging stores, SQL Server batched snapshot reader, PostgreSQL staging publisher/cleanup, and Hangfire enqueue/watchdog scheduling/ops reconciliation implementation |
| `WebApi` | Quick `202` request endpoint and status endpoint; no long-running bootstrap work in the request pipeline |
| `CentralDbSyncJobs` | Background bootstrap entry point that resolves scoped services, claims the request, and invokes the shared bootstrap workflow |
| SQL scripts | Idempotent creation of request/staging metadata, indexes, and runtime DML permissions |

The existing source-to-target mapping, soft-deactivation semantics, advisory lock, checkpoint store, checkpoint lag status endpoint (`GET {sourceTable}/status`), and CT pipeline remain shared rather than being duplicated for manual bootstrap.

## Additional features implemented in Phase 1

### Runtime per-table toggle

`ISyncConfigStore` / `PostgresSyncConfigStore` provides a `sync_meta.table_sync_config`-backed runtime toggle so individual tables can be enabled or disabled without code changes or redeploys.

- `IsEnabledAsync` checks whether a table is currently enabled.
- `SetEnabledAsync` toggles the enabled flag (returns `InvalidOperationException` if the table does not exist).
- `GetAllAsync` returns all registered tables with their config and enabled state.
- `SeedAsync` upserts a complete `TableSyncConfig` row.
- `CentralDbSyncJobs.RunAsync` filters out disabled tables before recurring execution.
- `CentralDbSyncJobs.RunBootstrapAsync` calls `SeedAsync` after a successful bootstrap to persist the table's sync config.

Endpoints added:
- `GET /api/central-db-sync/tables` — list all tables with enabled state
- `PATCH /api/central-db-sync/{sourceTable}/enabled` — enable/disable a table at runtime

### Change Tracking health check

`ISqlServerCtHealthCheck` / `SqlServerCtHealthCheck` queries `sys.change_tracking_tables` on the ERP SQL Server to confirm Change Tracking is active for a given source table.

Endpoint added:
- `GET /api/central-db-sync/{sourceTable}/ct-status` — check CT enabled status on the source

### Bootstrap auto-seed

After bootstrap succeeds (status `Completed`), `RunBootstrapAsync` calls `ISyncConfigStore.SeedAsync` to upsert the table's sync config. If seeding fails, the request is marked `Failed` (not `Completed`).

### Open-generic DI registration

`PostgresGenericReader<>` and `PostgresGenericWriter<>` are registered via open-generic DI (no per-table manual registrations).

## Security and Operations

- Pilot development and early phases preserve the currently documented disabled Admin guard. Production deployment must enable the Admin-only guard before exposing manual bootstrap.
- Existing ERP and Central DB least-privilege requirements remain unchanged. The runtime user receives only required staging and target DML permissions; DDL runs under the migration principal.
- Logs and status responses contain request/job IDs, counters, timestamps, outcome, and bounded errors only. They must not include partner payloads, PII, credentials, or SQL text.
- `data-sync` remains isolated from `report-render`. Capacity and worker count must be sized so a long bootstrap does not starve unrelated reporting work.

## Verification and Acceptance

1. A manual bootstrap API request returns HTTP 202 without reading source rows in the HTTP pipeline.
2. Repeated requests for the same active table return the existing request and Hangfire job IDs.
3. A restart between request creation and enqueue is reconciled without creating an independent active request.
4. A concurrent CT/bootstrap/manual attempt never applies concurrently for `CRM.Partners`; lock outcomes are visible in PostgreSQL logs.
5. A synthetic multi-batch bootstrap keeps application memory bounded to one batch plus fixed overhead.
6. Source failure, cancellation, mapping failure, and mid-staging PostgreSQL failure leave published `report.partners` and checkpoint unchanged.
7. Successful publish atomically applies lifecycle changes, checkpoint baseline, request completion, and run log correlation.
8. Retrying a batch or restarting a job with the same request ID does not duplicate staging rows or corrupt target data.
9. Stale terminal staging data is removed by the cleanup path.
10. Focused unit tests, PostgreSQL integration tests, and an API test cover the request lifecycle, status, lock, staging, atomic publish, cleanup, and Production authorization configuration.

## Explicit Decisions

- Use two delivery phases: asynchronous request/job first, scalable staging second.
- Use a new `sync_meta.bootstrap_request` table; do not overload `sync_run_log` with queued-request state.
- Return the existing active request for repeated manual submissions instead of HTTP 409.
- Keep no manual cancellation endpoint in the first delivery.
- Keep the Admin guard disabled during pilot/early phases and require it in Production.
- Refer to `report.partners` as "published Central DB data", not a specific report screen.
- Runtime toggle via `ISyncConfigStore` rather than appsettings or feature flags.
- Bootstrap auto-seeds sync config on completion via `SeedAsync`.
- Open-generic DI registration for readers/writers instead of per-table registrations.
- `ISqlServerCtHealthCheck` for proactive CT-status visibility.

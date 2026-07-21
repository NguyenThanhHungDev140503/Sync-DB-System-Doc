# Central DB Sync Background Bootstrap Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Make manual CRM.Partners bootstrap return a durable HTTP 202 immediately and execute the existing in-memory bootstrap through Hangfire.

**Architecture:** PostgreSQL stores one active bootstrap work ticket per source table. The API creates or reuses that ticket, the Hangfire job runs the existing BootstrapSyncService with its request ID as the run ID, and the existing advisory lock/checkpoint CAS remain responsible for data correctness.

**Tech Stack:** .NET 10, ASP.NET Core, Hangfire 1.8.23, Npgsql 10, Dapper, PostgreSQL, MSTest.

---

## Preconditions

- Phase 1 is deployable only when a measured complete BootstrapSnapshot fits application memory and the ERP SQL Server SNAPSHOT transaction duration budget.
- It does not make multi-million-row bootstrap scalable. Phase 2 replaces the in-memory snapshot with staging.
- Preserve the currently disabled Admin guard in pilot and early environments. Enable it as part of Production deployment.

## File Map

Create:
- Application/Features/CentralDbSync/Models/BootstrapRequest.cs - durable request model and status constants.
- Application/Features/CentralDbSync/Models/BootstrapRequestResult.cs - created or reused request result.
- Application/Features/CentralDbSync/Abstractions/IBootstrapRequestStore.cs - request lifecycle boundary.
- Application/Features/CentralDbSync/Abstractions/IBootstrapJobScheduler.cs - Hangfire-independent enqueue boundary.
- Application/Features/CentralDbSync/Services/BootstrapRequestService.cs - submit, status, reschedule, and stale-pending reconciliation.
- Infrastructure/CentralDbSync/PostgresBootstrapRequestStore.cs - PostgreSQL state machine.
- Infrastructure/CentralDbSync/HangfireBootstrapJobScheduler.cs - IBackgroundJobClient adapter.
- Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs.
- Tests/Ua.Application.UnitTests/CentralDbSync/CentralDbSyncControllerTests.cs.
- Tests/Ua.Application.UnitTests/CentralDbSync/PostgresBootstrapRequestStoreIntegrationTests.cs.

Modify:
- Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql.
- Application/Features/CentralDbSync/Services/BootstrapSyncService.cs.
- Infrastructure/CentralDbSync/CentralDbSyncJobs.cs.
- Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs.
- WebApi/Controllers/CentralDbSyncController.cs.
- WebApi/Program.cs.
- Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapSyncServiceTests.cs.
- README.md.

## Task 1: Define the durable request contract

**Files:**
- Create: Application/Features/CentralDbSync/Models/BootstrapRequest.cs
- Create: Application/Features/CentralDbSync/Models/BootstrapRequestResult.cs
- Create: Application/Features/CentralDbSync/Abstractions/IBootstrapRequestStore.cs
- Create: Application/Features/CentralDbSync/Abstractions/IBootstrapJobScheduler.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs

- [ ] **Step 1: Write failing tests for a new request and a duplicate active request.**

~~~csharp
[TestMethod]
public async Task SubmitAsync_NewRequest_QueuesIt()
{
    var scheduler = new FakeBootstrapJobScheduler("42");
    var service = new BootstrapRequestService(
        new FakeBootstrapRequestStore(), scheduler,
        NullLogger<BootstrapRequestService>.Instance);

    var result = await service.SubmitAsync("CRM.Partners", CancellationToken.None);

    Assert.IsTrue(result.IsNewRequest);
    Assert.AreEqual(BootstrapRequestStatus.Queued, result.Request.Status);
    Assert.AreEqual("42", result.Request.HangfireJobId);
}

[TestMethod]
public async Task SubmitAsync_ActiveRequest_ReturnsItWithoutSecondJob()
{
    var active = BootstrapRequest.New("CRM.Partners") with
    {
        Status = BootstrapRequestStatus.Running,
        HangfireJobId = "21"
    };
    var scheduler = new FakeBootstrapJobScheduler("42");
    var service = new BootstrapRequestService(
        new FakeBootstrapRequestStore(active), scheduler,
        NullLogger<BootstrapRequestService>.Instance);

    var result = await service.SubmitAsync("CRM.Partners", CancellationToken.None);

    Assert.IsFalse(result.IsNewRequest);
    Assert.AreEqual(active.RequestId, result.Request.RequestId);
    Assert.AreEqual(0, scheduler.EnqueueCallCount);
}
~~~

- [ ] **Step 2: Run the focused test to verify it fails.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~BootstrapRequestServiceTests

Expected: FAIL because BootstrapRequestService and request contracts do not exist.

- [ ] **Step 3: Add the request model, result model, and complete store/scheduler interfaces.**

~~~csharp
public static class BootstrapRequestStatus
{
    public const string PendingEnqueue = "pending_enqueue";
    public const string Queued = "queued";
    public const string Running = "running";
    public const string WaitingForLock = "waiting_for_lock";
    public const string Completed = "completed";
    public const string Failed = "failed";
}

public sealed record BootstrapRequest
{
    public Guid RequestId { get; init; }
    public required string SourceTable { get; init; }
    public required string Status { get; init; }
    public string? HangfireJobId { get; init; }
    public long RowsStaged { get; init; }
    public long? TotalRowsExpected { get; init; }
    public int AttemptCount { get; init; }
    public DateTime RequestedAt { get; init; }
    public DateTime? StartedAt { get; init; }
    public DateTime? FinishedAt { get; init; }
    public string? ErrorCode { get; init; }
    public string? ErrorMessage { get; init; }

    public static BootstrapRequest New(string sourceTable) => new()
    {
        RequestId = Guid.NewGuid(),
        SourceTable = sourceTable,
        Status = BootstrapRequestStatus.PendingEnqueue,
        RequestedAt = DateTime.UtcNow
    };
}

public sealed record BootstrapRequestResult(
    BootstrapRequest Request,
    bool IsNewRequest);
~~~

~~~csharp
public interface IBootstrapRequestStore
{
    Task<BootstrapRequestResult> CreateOrGetActiveAsync(string sourceTable, CancellationToken ct);
    Task<BootstrapRequest?> GetAsync(Guid requestId, CancellationToken ct);
    Task<bool> MarkQueuedAsync(Guid requestId, string hangfireJobId, CancellationToken ct);
    Task<bool> TryMarkRunningAsync(Guid requestId, CancellationToken ct);
    Task MarkWaitingForLockAsync(Guid requestId, string message, CancellationToken ct);
    Task MarkCompletedAsync(Guid requestId, CancellationToken ct);
    Task MarkFailedAsync(Guid requestId, string code, string message, CancellationToken ct);
    Task<IReadOnlyList<BootstrapRequest>> GetPendingEnqueueBeforeAsync(DateTime cutoffUtc, CancellationToken ct);
}

public interface IBootstrapJobScheduler
{
    Task<string> EnqueueAsync(string sourceTable, Guid requestId, CancellationToken ct);
    Task<string> ScheduleAsync(string sourceTable, Guid requestId, TimeSpan delay, CancellationToken ct);
}
~~~

- [ ] **Step 4: Re-run the focused test.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~BootstrapRequestServiceTests

Expected: FAIL only because BootstrapRequestService is absent.

- [ ] **Step 5: Commit contracts and failing-test scaffold.**

~~~bash
git add Application/Features/CentralDbSync/Models/BootstrapRequest.cs Application/Features/CentralDbSync/Models/BootstrapRequestResult.cs Application/Features/CentralDbSync/Abstractions/IBootstrapRequestStore.cs Application/Features/CentralDbSync/Abstractions/IBootstrapJobScheduler.cs Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs
git commit -m "feat: add bootstrap request contracts"
~~~

## Task 2: Persist and transition bootstrap work tickets

**Files:**
- Modify: Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql
- Create: Infrastructure/CentralDbSync/PostgresBootstrapRequestStore.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/PostgresBootstrapRequestStoreIntegrationTests.cs

- [ ] **Step 1: Write an opt-in PostgreSQL test that calls CreateOrGetActiveAsync twice and asserts one request ID, then assert a terminal request permits a new request.**

- [ ] **Step 2: Add idempotent request DDL.**

~~~sql
CREATE TABLE IF NOT EXISTS sync_meta.bootstrap_request
(
    request_id UUID PRIMARY KEY,
    source_table TEXT NOT NULL REFERENCES sync_meta.table_sync_config(source_table),
    status TEXT NOT NULL CHECK (status IN
        ('pending_enqueue','queued','running','waiting_for_lock','completed','failed')),
    hangfire_job_id TEXT,
    rows_staged BIGINT NOT NULL DEFAULT 0,
    total_rows_expected BIGINT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_code TEXT,
    error_message TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_bootstrap_request_active_table
    ON sync_meta.bootstrap_request (source_table)
    WHERE status IN ('pending_enqueue','queued','running','waiting_for_lock');
~~~

- [ ] **Step 3: Implement guarded PostgreSQL transitions.**

CreateOrGetActiveAsync inserts a pending request then, on partial-index conflict, reads and returns the active row. All state changes use a status guard, so a delayed job cannot revive a completed or failed request.

~~~csharp
var changed = await connection.ExecuteAsync(new CommandDefinition("""
    UPDATE sync_meta.bootstrap_request
    SET status = 'running',
        started_at = COALESCE(started_at, NOW()),
        attempt_count = attempt_count + 1,
        updated_at = NOW()
    WHERE request_id = @RequestId
      AND status IN ('queued', 'waiting_for_lock')
    """, new { RequestId = requestId }, cancellationToken: ct));
return changed == 1;
~~~

- [ ] **Step 4: Run request-store integration tests.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~PostgresBootstrapRequestStoreIntegrationTests

Expected: PASS with CENTRAL_DB_TEST_CONNECTION configured; otherwise the test class uses the existing explicit integration-test skip convention.

- [ ] **Step 5: Commit schema and store.**

~~~bash
git add Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql Infrastructure/CentralDbSync/PostgresBootstrapRequestStore.cs Tests/Ua.Application.UnitTests/CentralDbSync/PostgresBootstrapRequestStoreIntegrationTests.cs
git commit -m "feat: persist bootstrap request lifecycle"
~~~

## Task 3: Claim, enqueue, and recover pending requests

**Files:**
- Create: Application/Features/CentralDbSync/Services/BootstrapRequestService.cs
- Create: Infrastructure/CentralDbSync/HangfireBootstrapJobScheduler.cs
- Modify: Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs

- [ ] **Step 1: Add failing tests for scheduler failure and five-minute stale pending reconciliation.**

Assert that a scheduler exception marks the claimed request Failed with code BootstrapEnqueueFailed, and reconciliation schedules the same request ID rather than creating a new one.

- [ ] **Step 2: Implement BootstrapRequestService.**

SubmitAsync calls CreateOrGetActiveAsync. It returns an existing request without calling the scheduler. For a new request, it enqueues, calls MarkQueuedAsync, then returns the reloaded request. On an enqueue exception, it calls MarkFailedAsync(requestId, "BootstrapEnqueueFailed", "Unable to enqueue bootstrap request", CancellationToken.None) before rethrowing.

ReconcilePendingAsync receives a cutoff, processes each older pending request independently, and continues after one request cannot be scheduled.

- [ ] **Step 3: Implement the Hangfire adapter using only serializable job arguments.**

~~~csharp
public sealed class HangfireBootstrapJobScheduler(IBackgroundJobClient client)
    : IBootstrapJobScheduler
{
    public Task<string> EnqueueAsync(string table, Guid requestId, CancellationToken ct) =>
        Task.FromResult(client.Enqueue<CentralDbSyncJobs>(
            job => job.RunBootstrapAsync(table, requestId)));

    public Task<string> ScheduleAsync(string table, Guid requestId, TimeSpan delay, CancellationToken ct) =>
        Task.FromResult(client.Schedule<CentralDbSyncJobs>(
            job => job.RunBootstrapAsync(table, requestId), delay));
}
~~~

- [ ] **Step 4: Run service tests.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~BootstrapRequestServiceTests

Expected: PASS.

- [ ] **Step 5: Commit request service and scheduler.**

~~~bash
git add Application/Features/CentralDbSync/Services/BootstrapRequestService.cs Infrastructure/CentralDbSync/HangfireBootstrapJobScheduler.cs Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs
git commit -m "feat: enqueue durable bootstrap requests"
~~~

## Task 4: Execute existing bootstrap from a request-aware job

**Files:**
- Modify: Application/Features/CentralDbSync/Services/BootstrapSyncService.cs
- Modify: Infrastructure/CentralDbSync/CentralDbSyncJobs.cs
- Modify: Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapSyncServiceTests.cs
- Modify: Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs

- [ ] **Step 1: Add a failing test that passes requestId to BootstrapSyncService.ExecuteAsync and asserts all SyncRunLogEntry.RunId values equal it.**

- [ ] **Step 2: Add a run-ID overload and preserve current callers.**

~~~csharp
public Task<SyncRunResult> ExecuteAsync(
    TableSyncConfig config,
    CancellationToken ct = default) =>
    ExecuteAsync(config, Guid.NewGuid(), ct);

public async Task<SyncRunResult> ExecuteAsync(
    TableSyncConfig config,
    Guid runId,
    CancellationToken ct = default)
{
    // Preserve the current lock/read/apply flow.
    // Set RunId = runId on skipped-lock, success, cancellation, and failure entries.
}
~~~

Pass runId through ExecuteWithProvidedLockAsync so CT-invalid recovery remains correlated.

- [ ] **Step 3: Add CentralDbSyncJobs.RunBootstrapAsync(string sourceTable, Guid requestId).**

The job creates a scope, calls TryMarkRunningAsync, and returns when it is false. It invokes BootstrapSyncService with requestId. For skipped_locked it marks WaitingForLock and asks BootstrapRequestService to schedule the same request after one minute, persisting the replacement Hangfire job ID. For succeeded it marks Completed; every other result marks Failed with the result's safe error data.

- [ ] **Step 4: Add ReconcilePendingBootstrapRequestsAsync.**

It creates a scope and calls ReconcilePendingAsync(DateTime.UtcNow.AddMinutes(-5), CancellationToken.None).

- [ ] **Step 5: Run focused tests and commit.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter "FullyQualifiedName~BootstrapSyncServiceTests|FullyQualifiedName~BootstrapRequestServiceTests"

Expected: PASS; a lock conflict leaves an active waiting_for_lock request rather than terminal success.

~~~bash
git add Application/Features/CentralDbSync/Services/BootstrapSyncService.cs Infrastructure/CentralDbSync/CentralDbSyncJobs.cs Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapSyncServiceTests.cs Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapRequestServiceTests.cs
git commit -m "feat: run manual bootstrap through Hangfire"
~~~

## Task 5: Expose API/status and recurring reconciliation

**Files:**
- Modify: Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs
- Modify: WebApi/Controllers/CentralDbSyncController.cs
- Modify: WebApi/Program.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/CentralDbSyncControllerTests.cs

- [ ] **Step 1: Write controller tests for 202 new request, 202 reused request, 400 unknown table, and 404 unknown request.**

- [ ] **Step 2: Register these scoped services in AddCentralDbSync.**

~~~csharp
services.AddScoped<IBootstrapRequestStore>(sp =>
    new PostgresBootstrapRequestStore(centralDbConnection));
services.AddScoped<IBootstrapJobScheduler, HangfireBootstrapJobScheduler>();
services.AddScoped<BootstrapRequestService>();
~~~

- [ ] **Step 3: Replace the synchronous controller action.**

Validate RegisteredTables, call BootstrapRequestService.SubmitAsync, and return AcceptedAtAction(nameof(GetBootstrapStatus), new { requestId }, new { requestId, hangfireJobId, sourceTable, status, statusUrl }). Remove TableSyncConfig construction, the direct BootstrapSyncService call, and the old lock-to-409 branch. Add GET bootstrap/{requestId:guid}, returning safe request fields or 404.

- [ ] **Step 4: Schedule reconciliation on data-sync.**

~~~csharp
RecurringJob.AddOrUpdate<CentralDbSyncJobs>(
    "central-db-sync:reconcile-bootstrap-requests",
    job => job.ReconcilePendingBootstrapRequestsAsync(),
    Cron.MinuteInterval(5),
    new RecurringJobOptions { QueueName = "data-sync" });
~~~

- [ ] **Step 5: Run API tests and build.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter "FullyQualifiedName~CentralDbSyncControllerTests|FullyQualifiedName~BootstrapRequestServiceTests"

Expected: PASS; accepted API execution does not invoke a source reader.

Run: dotnet build UaApp.sln --no-restore

Expected: PASS.

- [ ] **Step 6: Commit API/wiring work.**

~~~bash
git add Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs WebApi/Controllers/CentralDbSyncController.cs WebApi/Program.cs Tests/Ua.Application.UnitTests/CentralDbSync/CentralDbSyncControllerTests.cs
git commit -m "feat: expose asynchronous bootstrap API"
~~~

## Task 6: Runtime toggle (ISyncConfigStore)

**Files:**
- Create: Application/Features/CentralDbSync/Abstractions/ISyncConfigStore.cs
- Create: Infrastructure/CentralDbSync/PostgresSyncConfigStore.cs
- Modify: Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs
- Modify: Infrastructure/CentralDbSync/CentralDbSyncJobs.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/PostgresSyncConfigStoreTests.cs

- [x] **Steps: Implemented as part of build phase.**

`PostgresSyncConfigStore` provides:
- `GetAllAsync` — returns all registered `TableSyncConfig` rows
- `IsEnabledAsync` — checks if a table is enabled
- `SetEnabledAsync` — toggles enabled flag (simple UPDATE)
- `SeedAsync` — full upsert with all config fields

`RunAsync` now filters out disabled tables before recurring execution.
`RunBootstrapAsync` calls `SeedAsync` on successful completion.

## Task 7: Change Tracking health check

**Files:**
- Create: Application/Features/CentralDbSync/Abstractions/ISqlServerCtHealthCheck.cs
- Create: Infrastructure/CentralDbSync/SqlServerCtHealthCheck.cs
- Modify: Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs

- [x] **Steps: Implemented as part of build phase.**

`SqlServerCtHealthCheck` queries `sys.change_tracking_tables` for the given source table and returns whether Change Tracking is enabled.

## Task 8: Table management endpoints

**Files:**
- Modify: WebApi/Controllers/CentralDbSyncController.cs
- Modify: Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs

- [x] **Steps: Implemented as part of build phase.**

| Method | Route | Purpose |
|---|---|---|
| GET | `/api/central-db-sync/tables` | List all registered tables with enabled state |
| PATCH | `/api/central-db-sync/{sourceTable}/enabled` | Enable/disable a table at runtime |
| GET | `/api/central-db-sync/{sourceTable}/ct-status` | Check Change Tracking status on the source |

`SetEnabledAsync` throws `InvalidOperationException` if the UPDATE affects 0 rows.

## Task 9: Open-generic DI registration

**Files:**
- Modify: Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs

- [x] **Steps: Implemented as part of build phase.**

`PostgresGenericReader<>` and `PostgresGenericWriter<>` registered as open-generic scoped services, eliminating per-table manual registrations.

## Task 10: Document and verify the Phase 1 safety gate

**Files:**
- Modify: README.md

- [ ] **Step 1: Document that Phase 1 is allowed only when a measured complete snapshot fits process memory and ERP snapshot-duration budgets; otherwise execute Phase 2 before enabling manual bootstrap.**

- [ ] **Step 2: Run all CentralDbSync tests.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~CentralDbSync

Expected: PASS, with PostgreSQL integration tests explicitly skipped only without their configured test connection.

- [ ] **Step 3: In a pilot environment, POST twice, verify one requestId, poll GET status, verify sync_meta.sync_run_log.run_id equals requestId, and verify a CT-held lock causes waiting_for_lock then rescheduling.**

- [ ] **Step 4: Commit documentation after checks pass.**

~~~bash
cd /workspace/ua-app && git add README.md && git commit -m "docs: document background bootstrap operation"
~~~
~~~

## Definition of Done

- API latency is independent of bootstrap duration.
- At most one active request per table survives API restart.
- A failed bootstrap leaves published Central DB data and its checkpoint unchanged.
- Operators can correlate request state with sync_meta.sync_run_log.
- The Phase 1 memory/snapshot safety gate prevents using this path for oversized tables.

# Central DB Sync Scalable Bootstrap Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Replace the in-memory full bootstrap with bounded SQL Server batches staged in PostgreSQL, then atomically publish report.partners, checkpoint, request completion, and execution audit data.

**Architecture:** BootstrapSyncService keeps ownership of the existing per-table advisory lock. A staged workflow opens one ERP SNAPSHOT transaction, captures the Change Tracking baseline and row count, streams 10,000-row batches to a request-owned PostgreSQL staging table, then publishes staging through one PostgreSQL transaction. The Phase 1 bootstrap_request row provides request ID and progress.

**Tech Stack:** .NET 10, Microsoft.Data.SqlClient, Npgsql 10 binary COPY, Dapper, PostgreSQL, Hangfire 1.8.23, MSTest.

---

## Preconditions

- Phase 1 is complete and deployed: bootstrap_request, request status API, request-aware Hangfire job, and request ID to run-log correlation exist.
- The ERP DBA has approved the expected SQL Server SNAPSHOT transaction duration and version-store capacity for the largest supported source table.
- The source primary key for CRM.Partners is PartnerId and is suitable for deterministic ascending keyset batching.
- Use the Npgsql current binary import API: BeginBinaryImportAsync, StartRowAsync, WriteAsync, WriteNullAsync, and CompleteAsync. Dispose an incomplete importer to cancel its COPY operation.

## File Map

Create:
- Application/Features/CentralDbSync/Models/BootstrapStagingSessionInfo.cs.
- Application/Features/CentralDbSync/Abstractions/IStagedBootstrapSourceReader.cs.
- Application/Features/CentralDbSync/Abstractions/IStagedBootstrapSourceSession.cs.
- Application/Features/CentralDbSync/Abstractions/IBootstrapStagingStore.cs.
- Application/Features/CentralDbSync/Abstractions/IBootstrapStagingPublisher.cs.
- Application/Features/CentralDbSync/Abstractions/IBootstrapWorkflow.cs.
- Infrastructure/CentralDbSync/PostgresBootstrapStagingStore.cs.
- Infrastructure/CentralDbSync/PostgresBootstrapStagingPublisher.cs.
- Infrastructure/CentralDbSync/StagedBootstrapWorkflow.cs.
- Tests/Ua.Application.UnitTests/CentralDbSync/StagedBootstrapWorkflowTests.cs.
- Tests/Ua.Application.UnitTests/CentralDbSync/PostgresBootstrapStagingIntegrationTests.cs.

Modify:
- Application/Features/CentralDbSync/Services/BootstrapSyncService.cs.
- Infrastructure/CentralDbSync/SqlServerPartnersReader.cs.
- Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs.
- Infrastructure/CentralDbSync/CentralDbSyncJobs.cs.
- Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql.
- Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapSyncServiceTests.cs.
- Tests/Ua.Application.UnitTests/CentralDbSync/PostgresIntegrationTests.cs.
- README.md.

## Task 1: Define staged-source and publish contracts

**Files:**
- Create: Application/Features/CentralDbSync/Models/BootstrapStagingSessionInfo.cs
- Create: Application/Features/CentralDbSync/Abstractions/IStagedBootstrapSourceReader.cs
- Create: Application/Features/CentralDbSync/Abstractions/IStagedBootstrapSourceSession.cs
- Create: Application/Features/CentralDbSync/Abstractions/IBootstrapStagingStore.cs
- Create: Application/Features/CentralDbSync/Abstractions/IBootstrapStagingPublisher.cs
- Create: Application/Features/CentralDbSync/Abstractions/IBootstrapWorkflow.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/StagedBootstrapWorkflowTests.cs

- [ ] **Step 1: Write failing workflow tests.**

Cover these cases with fakes: batches are staged one at a time, progress is persisted after each committed batch, a source exception never calls PublishAsync, and a successful workflow passes one request ID/baseline to publish.

~~~csharp
[TestMethod]
public async Task ExecuteAsync_SourceFailure_DoesNotPublish()
{
    var workflow = CreateWorkflow(
        source: new FakeStagedSourceReader(throwAfterBatch: 1),
        staging: new FakeStagingStore(),
        publisher: new FakePublisher());

    await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
        workflow.ExecuteAsync(DefaultConfig, Guid.NewGuid(), CancellationToken.None));

    Assert.AreEqual(0, _publisher.PublishCallCount);
}
~~~

- [ ] **Step 2: Run the tests to verify contract failure.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~StagedBootstrapWorkflowTests

Expected: FAIL because staged workflow contracts do not exist.

- [ ] **Step 3: Add session and workflow interfaces.**

~~~csharp
public sealed record BootstrapStagingSessionInfo(
    long BaselineVersion,
    long TotalRowsExpected);

public interface IStagedBootstrapSourceReader
{
    Task<IStagedBootstrapSourceSession> OpenAsync(
        TableSyncConfig config,
        int batchSize,
        CancellationToken ct);
}

public interface IStagedBootstrapSourceSession : IAsyncDisposable
{
    BootstrapStagingSessionInfo Info { get; }
    IAsyncEnumerable<IReadOnlyList<PartnerSourceRow>> ReadBatchesAsync(
        CancellationToken ct);
    Task CompleteAsync(CancellationToken ct);
}

public interface IBootstrapStagingStore
{
    Task StageBatchAsync(Guid requestId, IReadOnlyList<PartnerSourceRow> rows, CancellationToken ct);
    Task UpdateProgressAsync(Guid requestId, long rowsStaged, long totalRowsExpected, CancellationToken ct);
    Task DeleteAsync(Guid requestId, CancellationToken ct);
    Task<int> DeleteTerminalOlderThanAsync(DateTime cutoffUtc, CancellationToken ct);
}

public interface IBootstrapStagingPublisher
{
    Task<SyncRunResult> PublishAsync(
        TableSyncConfig config,
        Guid requestId,
        long baselineVersion,
        DateTime startedAt,
        CancellationToken ct);
}

public interface IBootstrapWorkflow
{
    Task<SyncRunResult> ExecuteAsync(
        TableSyncConfig config,
        Guid requestId,
        DateTime startedAt,
        CancellationToken ct);
}
~~~

- [ ] **Step 4: Re-run the test and commit contracts.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~StagedBootstrapWorkflowTests

Expected: FAIL only because StagedBootstrapWorkflow is not implemented.

~~~bash
git add Application/Features/CentralDbSync/Models/BootstrapStagingSessionInfo.cs Application/Features/CentralDbSync/Abstractions/IStagedBootstrapSourceReader.cs Application/Features/CentralDbSync/Abstractions/IStagedBootstrapSourceSession.cs Application/Features/CentralDbSync/Abstractions/IBootstrapStagingStore.cs Application/Features/CentralDbSync/Abstractions/IBootstrapStagingPublisher.cs Application/Features/CentralDbSync/Abstractions/IBootstrapWorkflow.cs Tests/Ua.Application.UnitTests/CentralDbSync/StagedBootstrapWorkflowTests.cs
git commit -m "feat: add staged bootstrap contracts"
~~~

## Task 2: Add request-owned PostgreSQL staging

**Files:**
- Modify: Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql
- Create: Infrastructure/CentralDbSync/PostgresBootstrapStagingStore.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/PostgresBootstrapStagingIntegrationTests.cs

- [ ] **Step 1: Write integration tests for idempotent batch replay, request-scoped deletion, and terminal cleanup.**

Use two request IDs with the same PartnerId. Verify the composite key accepts one row per request, replay updates or replaces only that request row, and cleanup never deletes an active request's rows.

- [ ] **Step 2: Add the staging table and indexes.**

Include every mapped PartnerSourceRow field needed by report.partners and an immutable request ID.

~~~sql
CREATE TABLE IF NOT EXISTS sync_meta.partner_bootstrap_staging
(
    request_id UUID NOT NULL REFERENCES sync_meta.bootstrap_request(request_id) ON DELETE CASCADE,
    partner_id INTEGER NOT NULL,
    company_id INTEGER NOT NULL,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    is_customer BOOLEAN,
    is_supplier BOOLEAN,
    email TEXT,
    phone TEXT,
    activated BOOLEAN,
    PRIMARY KEY (request_id, partner_id)
);

CREATE INDEX IF NOT EXISTS ix_partner_bootstrap_staging_request
    ON sync_meta.partner_bootstrap_staging (request_id);
~~~

- [ ] **Step 3: Implement StageBatchAsync with Npgsql binary COPY.**

Use one Central DB connection and transaction for one batch. Begin the importer with explicit columns, write every row, call CompleteAsync, then commit. If mapping/COPY fails, dispose the importer without CompleteAsync and roll back that batch transaction.

~~~csharp
await using var transaction = await connection.BeginTransactionAsync(ct);
await using var importer = await connection.BeginBinaryImportAsync("""
    COPY sync_meta.partner_bootstrap_staging
    (request_id, partner_id, company_id, code, name, is_customer, is_supplier, email, phone, activated)
    FROM STDIN (FORMAT BINARY)
    """, ct);

foreach (var row in rows)
{
    await importer.StartRowAsync(ct);
    await importer.WriteAsync(requestId, NpgsqlDbType.Uuid, ct);
    await importer.WriteAsync(row.PartnerId, NpgsqlDbType.Integer, ct);
    await importer.WriteAsync(row.CompanyId, NpgsqlDbType.Integer, ct);
    await importer.WriteAsync(row.Code, NpgsqlDbType.Text, ct);
    await importer.WriteAsync(row.Name, NpgsqlDbType.Text, ct);
    await WriteNullableBooleanAsync(importer, row.IsCustomer, ct);
    await WriteNullableBooleanAsync(importer, row.IsSupplier, ct);
    await WriteNullableTextAsync(importer, row.Email, ct);
    await WriteNullableTextAsync(importer, row.Phone, ct);
    await WriteNullableBooleanAsync(importer, row.Activated, ct);
}
await importer.CompleteAsync(ct);
await transaction.CommitAsync(ct);
~~~

Because a replay can encounter an existing composite key, delete that request's matching PartnerId values before COPY inside the same batch transaction, or COPY to a per-batch temporary table then upsert into staging before commit. Do not use an unguarded second COPY that fails on replay.

- [ ] **Step 4: Implement UpdateProgressAsync and DeleteTerminalOlderThanAsync.**

Update rows_staged and total_rows_expected only for active request states. Cleanup uses a joined DELETE where request status is completed or failed and finished_at is older than 24 hours. It must not delete waiting_for_lock, queued, or running staging rows.

- [ ] **Step 5: Run integration tests and commit.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~PostgresBootstrapStagingIntegrationTests

Expected: PASS with Central DB test connection; otherwise explicit skip.

~~~bash
git add Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql Infrastructure/CentralDbSync/PostgresBootstrapStagingStore.cs Tests/Ua.Application.UnitTests/CentralDbSync/PostgresBootstrapStagingIntegrationTests.cs
git commit -m "feat: add request-scoped bootstrap staging"
~~~

## Task 3: Stream the ERP snapshot in deterministic batches

**Files:**
- Modify: Infrastructure/CentralDbSync/SqlServerPartnersReader.cs
- Test: Tests/Ua.Application.UnitTests/CentralDbSync/StagedBootstrapWorkflowTests.cs

- [ ] **Step 1: Add fake session tests that prove CompleteAsync is called only after every batch reaches EOF, while a cancellation or read exception disposes/rolls back without completion.**

- [ ] **Step 2: Implement IStagedBootstrapSourceReader in SqlServerPartnersReader.**

Open one SqlConnection using DefaultConnection. Set SNAPSHOT isolation, begin a transaction, capture CHANGE_TRACKING_CURRENT_VERSION first, then run COUNT_BIG(*) from CRM.Partners in that same transaction. Return a session owning the connection and transaction.

- [ ] **Step 3: Implement keyset batch reads in the session.**

Use the full existing explicit Partner column list and no IsCustomer WHERE clause. Read the first 10,000 rows ordered by PartnerId, then use the last PartnerId as the next parameter.

~~~sql
SELECT TOP (@BatchSize)
       PartnerId, CompanyId, Code, Name, IsCustomer, IsSupplier, Email, Phone, Activated
FROM [CRM].[Partners]
WHERE PartnerId > @AfterPartnerId
ORDER BY PartnerId;
~~~

Validate every row and reject null/duplicate/non-increasing PartnerId before yielding a batch. Preserve all current PartnerSourceRow mapping semantics. CompleteAsync commits the SQL Server transaction only after EOF; DisposeAsync rolls back an incomplete session.

- [ ] **Step 4: Run focused reader/workflow tests and commit.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter "FullyQualifiedName~StagedBootstrapWorkflowTests|FullyQualifiedName~PartnerMappingTests"

Expected: PASS.

~~~bash
git add Infrastructure/CentralDbSync/SqlServerPartnersReader.cs Tests/Ua.Application.UnitTests/CentralDbSync/StagedBootstrapWorkflowTests.cs
git commit -m "feat: stream ERP bootstrap source in batches"
~~~

## Task 4: Stage, publish atomically, and replace the in-memory workflow

**Files:**
- Create: Infrastructure/CentralDbSync/StagedBootstrapWorkflow.cs
- Create: Infrastructure/CentralDbSync/PostgresBootstrapStagingPublisher.cs
- Modify: Application/Features/CentralDbSync/Services/BootstrapSyncService.cs
- Modify: Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs only if constructor type changes
- Modify: Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapSyncServiceTests.cs
- Modify: Tests/Ua.Application.UnitTests/CentralDbSync/PostgresIntegrationTests.cs

- [ ] **Step 1: Complete failing workflow tests.**

Assert one batch is staged before the next is requested, progress changes from 0 to batch totals, publish receives the source baseline, and source failure leaves publisher call count at zero.

- [ ] **Step 2: Implement StagedBootstrapWorkflow.**

It opens a source session with batchSize 10000, updates bootstrap_request total_rows_expected, stages each yielded batch, increments rowsStaged only after StageBatchAsync succeeds, calls source.CompleteAsync after EOF, then calls PublishAsync. On exception, call DeleteAsync(requestId, CancellationToken.None), rethrow, and let BootstrapSyncService write the existing failed run log and request job mark failure.

- [ ] **Step 3: Implement PostgresBootstrapStagingPublisher as one transaction.**

Within one PostgreSQL transaction:
1. Upsert active staged rows into report.partners.
2. Set is_active = false for owned report.partners rows absent from this request's staging set or represented by a staged row with IsCustomer false or null.
3. Advance sync_meta.checkpoint only where last_sync_version equals the expected prior checkpoint or is the pending bootstrap state.
4. Insert the succeeded sync_meta.sync_run_log row with run_id = requestId.
5. Set bootstrap_request status completed and finished_at.
6. Commit.

Use a single NOW() captured in SQL or C# for all target synced_at timestamps. If any statement fails, roll back; published Central DB data, checkpoint, run log, and request completion remain unchanged.

- [ ] **Step 4: Change BootstrapSyncService to delegate source/apply work to IBootstrapWorkflow.**

Keep the existing table lock and all failure/cancellation paths. Replace direct IBootstrapSnapshotReader plus ISyncBatchApplier bootstrap use with workflow.ExecuteAsync(config, runId, startedAt, ct). Keep ExecuteWithProvidedLockAsync on the same service so ChangeTrackingSyncService CT-invalid recovery automatically uses staging too.

- [ ] **Step 5: Run unit and PostgreSQL atomicity tests.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter "FullyQualifiedName~BootstrapSyncServiceTests|FullyQualifiedName~StagedBootstrapWorkflowTests|FullyQualifiedName~PostgresIntegrationTests"

Expected: PASS; an injected publish failure leaves target lifecycle and checkpoint unchanged, and a successful publish deactivates only rows outside the completed staging set.

- [ ] **Step 6: Commit workflow/publisher work.**

~~~bash
git add Infrastructure/CentralDbSync/StagedBootstrapWorkflow.cs Infrastructure/CentralDbSync/PostgresBootstrapStagingPublisher.cs Application/Features/CentralDbSync/Services/BootstrapSyncService.cs Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs Tests/Ua.Application.UnitTests/CentralDbSync/BootstrapSyncServiceTests.cs Tests/Ua.Application.UnitTests/CentralDbSync/PostgresIntegrationTests.cs Tests/Ua.Application.UnitTests/CentralDbSync/StagedBootstrapWorkflowTests.cs
git commit -m "feat: publish staged central db bootstrap atomically"
~~~

## Task 5: Wire Phase 2, clean abandoned data, and prove operational behavior

**Files:**
- Modify: Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs
- Modify: Infrastructure/CentralDbSync/CentralDbSyncJobs.cs
- Modify: WebApi/Program.cs
- Modify: README.md
- Modify: Tests/Ua.Application.UnitTests/CentralDbSync/PostgresIntegrationTests.cs

- [ ] **Step 1: Register IStagedBootstrapSourceReader, IBootstrapStagingStore, IBootstrapStagingPublisher, IBootstrapWorkflow, and the refactored BootstrapSyncService as scoped services. Remove the Phase 1-only in-memory bootstrap registration rather than keeping two active bootstrap paths.**

- [ ] **Step 2: Add CentralDbSyncJobs.CleanupTerminalBootstrapStagingAsync.**

It creates a scope, calls DeleteTerminalOlderThanAsync(DateTime.UtcNow.AddHours(-24), CancellationToken.None), and logs only deleted-row count. Schedule it once daily on data-sync.

~~~csharp
RecurringJob.AddOrUpdate<CentralDbSyncJobs>(
    "central-db-sync:cleanup-bootstrap-staging",
    job => job.CleanupTerminalBootstrapStagingAsync(),
    Cron.Daily(),
    new RecurringJobOptions { QueueName = "data-sync" });
~~~

- [ ] **Step 3: Add a synthetic multi-batch integration test.**

Stage at least three batches with more than one batch-size boundary. Assert request progress reaches total, only the final publish changes report.partners, replaying the same request ID remains idempotent, and cleanup removes failed request staging after the retention cutoff.

- [ ] **Step 4: Document operational prerequisites.**

README must state batch size 10,000, the SQL Server SNAPSHOT/version-store approval requirement, status progress semantics, 24-hour terminal staging cleanup, and that reports read only published report.partners data.

- [ ] **Step 5: Run full verification.**

Run: dotnet test Tests/Ua.Application.UnitTests/Ua.Application.UnitTests.csproj --filter FullyQualifiedName~CentralDbSync

Expected: PASS, with unavailable PostgreSQL integration tests explicitly skipped.

Run: dotnet build UaApp.sln --no-restore

Expected: PASS.

- [ ] **Step 6: Execute a pilot acceptance matrix.**

1. Bootstrap more than three batches and verify API progress after each committed staging batch.
2. Fail a source batch and verify report.partners/checkpoint remain at the prior successful state.
3. Fail publish and verify report.partners, checkpoint, request completion, and succeeded run log all roll back.
4. Hold a CT lock, submit bootstrap, verify waiting_for_lock, then verify later publish once the lock releases.
5. Restart a worker during staging, verify the request never creates a second active ticket, and retry with the same request ID safely.
6. Verify daily cleanup does not remove active staging rows.

- [ ] **Step 7: Commit wiring, tests, and docs.**

~~~bash
git add Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs Infrastructure/CentralDbSync/CentralDbSyncJobs.cs WebApi/Program.cs README.md Tests/Ua.Application.UnitTests/CentralDbSync/PostgresIntegrationTests.cs
git commit -m "feat: operate staged bootstrap workflow"
~~~

## Definition of Done

- Bootstrap memory is bounded to one 10,000-row batch plus fixed overhead.
- No published Central DB consumer observes incomplete data.
- Failure before publish leaves report.partners and checkpoint unchanged.
- Final publish atomically changes target lifecycle, checkpoint, request completion, and succeeded execution audit row.
- CT-invalid recovery uses the same staged bootstrap workflow.
- Staging is request-owned, idempotent under retry, observable by progress, and cleaned after terminal retention.

# Bootstrap Sync — Full End-to-End Flow

**Ngày:** 2026-07-23
**Phân tích bởi:** Hung NT (Oz agent)
**Liên quan:** Central DB Sync — TriggerBootstrap → ApplyBootstrapAsync → Orphan Cleanup

---

## 1. Vấn đề (Problem Statement)

Khi operator muốn sync **toàn bộ dữ liệu** lần đầu từ SQL Server (ERP) sang PostgreSQL (mobile app), làm sao để:

- Gửi một API call đơn giản, không block client (async)?
- Chạy bootstrap dưới nền (Hangfire job), không ảnh hưởng HTTP request?
- Đảm bảo dữ liệu nhất quán (không đọc lẫn dòng cũ/mới giữa chừng)?
- Không duplicate, không mất dữ liệu, không deactivate nhầm row của hệ thống khác?
- Ghi checkpoint để incremental sync (CT sync) biết bắt đầu từ đâu?

Flow giải quyết tuần tự: API → Durable Request → Hangfire Job → Lock → Read SQL Server → Write PostgreSQL → Orphan Cleanup → Checkpoint → Audit Log.

---

## 2. Flow tổng quan (End-to-end)

```text
NGƯỜI DÙNG / OPERATOR
│
├── POST /api/central-db-sync/bootstrap/{ruleName}   ← CentralDbSyncController.cs:61
│       │
│       ├── [1] ruleProvider.TryGet(ruleName) → validate rule tồn tại
│       │
│       ├── [2] requestService.SubmitAsync(ruleName)
│       │       │
│       │       ├── [2a] requestStore.CreateOrGetActiveAsync
│       │       │       └── INSERT sync_meta.bootstrap_request (status=pending_enqueue)
│       │       │       └── Hoặc trả về request đã tồn tại nếu chưa xong
│       │       │
│       │       ├── [2b] scheduler.EnqueueAsync → Hangfire job
│       │       │       └── client.Enqueue<CentralDbSyncJobs>(job => job.RunBootstrapAsync(...))
│       │       │
│       │       ├── [2c] scheduler.ScheduleWatchdogAsync (45s delay)
│       │       │       └── Phòng crash giữa create và enqueue
│       │       │
│       │       └── [2d] requestStore.MarkQueuedAsync
│       │               └── UPDATE status = 'queued', hangfire_job_id = ...
│       │
│       └── Return HTTP 202 Accepted
│               { requestId, hangfireJobId, status = "queued", ... }
│
│   ─── HANGFIRE picKS UP JOB ───
│
├── CentralDbSyncJobs.RunBootstrapAsync(sourceTable, requestId)  ← CentralDbSyncJobs.cs:72
│       │
│       ├── [3] requestStore.TryMarkRunningAsync(requestId)
│       │       └── Atomically claim: queued → running
│       │       └── Nếu fail → worker khác đã claim → return
│       │
│       ├── [4] bootstrapService.ExecuteAsync(config, requestId, ct)  ← BootstrapSyncService.cs:23
│       │       │
│       │       ├── [4a] syncLock.TryAcquireAsync (lease 12 min)
│       │       │       └── PostgreSQL pg_try_advisory_lock()
│       │       │       └── Nếu không lấy được → return SkippedLocked
│       │       │
│       │       └── [4b] ExecuteCoreAsync(config, runId, startedAt, ct)  ← BootstrapSyncService.cs:106
│       │               │
│       │               ├── [4b-1] reader.ReadAsync(MSSQL)        ← SqlServerGenericReader.cs:22
│       │               │       └── Version Sandwich + retry 3 lần
│       │               │       └── Return: BootstrapSnapshot(baselineVersion, rows)
│       │               │
│       │               ├── [4b-2] applier.ApplyBootstrapAsync(PG)  ← PostgresGenericApplier.cs:124
│       │               │       └── 1 transaction: UPSERT + orphan + checkpoint
│       │               │
│       │               └── [4b-3] runLog.WriteAsync(PG)            ← PostgresSyncRunLog
│       │                       └── Ghi audit log (transaction riêng)
│       │
│       └── [5] Xử lý kết quả:
│               ├── Succeeded → configStore.SeedAsync + MarkCompletedAsync
│               ├── SkippedLocked → reschedule sau 1 phút
│               └── Failed → MarkFailedAsync (không sửa checkpoint!)
```

---

## 3. Chi tiết từng bước

### Bước 1: API — TriggerBootstrap

**Vai trò:** Validate rule, tạo durable work ticket, enqueue Hangfire, trả về 202 ngay lập tức.

```csharp
// WebApi/Controllers/CentralDbSyncController.cs:61-93
[HttpPost("bootstrap/{ruleName}")]
public async Task<IActionResult> TriggerBootstrap(string ruleName, CancellationToken ct)
{
    // Validate rule tồn tại
    if (!ruleProvider.TryGet(ruleName, out var rule))
        return BadRequest(...);

    // Submit request → tạo work ticket + enqueue Hangfire
    var result = await requestService.SubmitAsync(ruleName, ct);

    return AcceptedAtAction(
        nameof(GetBootstrapStatus),
        new { requestId = result.Request.RequestId },
        new
        {
            requestId = result.Request.RequestId,
            hangfireJobId = result.Request.HangfireJobId,
            ruleName = ruleName,
            sourceTable = rule.Source.PrimaryTable,  // ← lấy từ rule, không phải ruleName
            status = result.Request.Status,
            statusUrl = ...
        });
}
```

**Key points:**
- Không có admin role check trong Phase 1 (TODO: bật trước UAT)
- `sourceTable` trả về là `rule.Source.PrimaryTable` (VD: `"CRM.Partners"`), không phải `ruleName`
- Response 202 — client không phải chờ job chạy xong

### Bước 2: BootstrapRequestService.SubmitAsync

**Vai trò:** Tạo durable work ticket trong `sync_meta.bootstrap_request`, enqueue Hangfire job, và đặt watchdog chống crash.

```csharp
// Application/Features/CentralDbSync/Services/BootstrapRequestService.cs:25-78
public async Task<BootstrapRequestResult> SubmitAsync(string ruleName, CancellationToken ct)
{
    // Kiểm tra rule đã registered
    SyncGuard.AssertRegisteredRule(ruleName, ruleProvider, nameof(ruleName));

    // Tạo hoặc trả về request đã tồn tại (idempotent)
    var result = await requestStore.CreateOrGetActiveAsync(ruleName, ct);
    if (!result.IsNewRequest)
        return result;  // Request đã active → không tạo job mới

    var requestId = result.Request.RequestId;

    // [2b] Watchdog: phòng crash giữa create và enqueue
    await scheduler.ScheduleWatchdogAsync(ruleName, requestId, WatchdogDelay, ct);

    // [2c] Enqueue Hangfire job
    var hangfireJobId = await scheduler.EnqueueAsync(ruleName, requestId, ct);

    // [2d] Đánh dấu request đã enqueued
    await requestStore.MarkQueuedAsync(requestId, hangfireJobId, ct);

    return ...;
}
```

**Request lifecycle states:**

```text
pending_enqueue → queued → running → completed / failed
                    ↑
                    └── watchdog (45s): nếu crash trước khi enqueue
```

**Idempotency:** Mỗi `source_table` chỉ có 1 active request tại một thời điểm (unique partial index `ux_bootstrap_request_active_table` trên `status IN (pending_enqueue, queued, running, waiting_for_lock)`). Gọi API lần 2 trả về request đã tồn tại thay vì tạo mới.

### Bước 3: Hangfire Job Executes

**Vai trò:** Claim request, gọi bootstrap service, xử lý kết quả (seed config / retry / mark failed).

```csharp
// Infrastructure/CentralDbSync/CentralDbSyncJobs.cs:72-140
public async Task RunBootstrapAsync(string sourceTable, Guid requestId)
{
    // [3] Atomically claim request: queued → running
    var claimed = await requestStore.TryMarkRunningAsync(requestId, ct);
    if (!claimed) return;  // Worker khác đã claim

    var rule = _ruleProvider.Get(sourceTable);
    var config = rule.ToTableSyncConfig();

    // [4] Chạy bootstrap với 10-minute timeout
    using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
    var result = await bootstrapService.ExecuteAsync(config, requestId, cts.Token);

    // [5] Xử lý kết quả
    switch (result.Outcome)
    {
        case Succeeded:
            await configStore.SeedAsync(config, ct);     // Seed table_sync_config
            await requestStore.MarkCompletedAsync(requestId, ct);
            break;
        case SkippedLocked:
            // Reschedule sau 1 phút
            await scheduler.ScheduleAsync(sourceTable, requestId, TimeSpan.FromMinutes(1), ct);
            await requestStore.MarkQueuedAsync(requestId, newJobId, ct);
            break;
        default:
            // Failed — không sửa checkpoint!
            await requestStore.MarkFailedAsync(requestId, errorCode, errorMessage, ct);
            break;
    }
}
```

### Bước 4: BootstrapSyncService — Lock + Execute

**Vai trò:** Acquire distributed lock (PostgreSQL advisory lock), gọi core pipeline.

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:23-56
public async Task<SyncRunResult> ExecuteAsync(
    TableSyncConfig config, Guid runId, CancellationToken ct)
{
    // [4a] Acquire PostgreSQL advisory lock (lease 12 phút)
    await using var lockHandle = await syncLock.TryAcquireAsync(
        config.SourceTable, ct, TimeSpan.FromMinutes(12));

    if (lockHandle is null)
        return new SyncRunResult { Outcome = SkippedLocked };

    // [4b] Delegate to core pipeline
    return await ExecuteCoreAsync(config, runId, startedAt, ct);
}
```

**Distributed Lock:**
- Dùng `pg_try_advisory_lock()` — không block, trả về false nếu lock đã bị chiếm
- Watchdog tự động force-release sau 12 phút (tránh lock treo vĩnh viễn nếu worker crash)
- Chi tiết: `docs/.../notes/technical/2026-07-21-advisory-lock-explained.md`

### Bước 5: ExecuteCoreAsync — 3-Phase Pipeline

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:106-169
private async Task<SyncRunResult> ExecuteCoreAsync(
    TableSyncConfig config, Guid runId, DateTime startedAt, CancellationToken ct)
{
    try
    {
        // PHASE 1: Đọc snapshot nhất quán từ SQL Server
        var snapshot = await reader.ReadAsync(config, ct);             // → BootstrapSnapshot

        // PHASE 2: Ghi vào PostgreSQL trong 1 transaction
        var result = await applier.ApplyBootstrapAsync(config, snapshot, ct);  // → SyncRunResult

        // PHASE 3: Ghi audit log
        await runLog.WriteAsync(new SyncRunLogEntry { ... }, ct);
        return result;
    }
    catch (Exception ex)
    {
        // ❌ KHÔNG sửa checkpoint khi fail
        await runLog.WriteAsync(CreateFailedEntry(...));
        return new SyncRunResult { Outcome = Failed, ErrorCode = "BootstrapFailed", ... };
    }
}
```

**Phase 1 — Reader (SQL Server):**
- Version Sandwich: `CHANGE_TRACKING_CURRENT_VERSION()` trước → SELECT data → `CHANGE_TRACKING_CURRENT_VERSION()` sau
- Nếu 2 version bằng nhau → data nhất quán. Nếu khác → ROLLBACK + retry (tối đa 3 lần)
- Dùng `READPAST` hint để bỏ qua row đang bị lock
- Chi tiết: `docs/.../notes/technical/2026-07-21-reader-consistent-snapshot-explained.md`

**Phase 3 — Audit:** Ghi `sync_meta.sync_run_log` với outcome, rows_read, rows_upserted, rows_deleted, checkpoint. Transaction riêng — không gộp với applier transaction.

### Bước 6: ApplyBootstrapAsync — 4 bước trong 1 transaction

Đây là phần quan trọng nhất. Toàn bộ nằm trong **1 PostgreSQL transaction** — tất cả hoặc không gì cả.

```csharp
// Infrastructure/CentralDbSync/PostgresGenericApplier.cs:124-203
async Task<SyncRunResult> ISyncBatchApplier.ApplyBootstrapAsync(
    TableSyncConfig config, BootstrapSnapshot snapshot, CancellationToken ct)
{
    await using var tx = await conn.BeginTransactionAsync(ct);

    try
    {
        // [6a] UPSERT từng row từ snapshot vào target table
        var upsertSql = sqlBuilder.BuildUpsert(rule);
        var snapshotPrimaryKeys = new List<object?>();
        foreach (var row in snapshot.Rows)
        {
            var values = BuildTargetValues(rule, row);
            await conn.ExecuteAsync(upsertSql, values, tx);
            snapshotPrimaryKeys.Add(values[pkColumn]);
        }

        // [6b] ORPHAN CLEANUP — deactivate/delete row không còn trong source
        var hasActiveFlag = sqlBuilder.HasActiveFlag(rule);
        var orphanCount = await conn.ExecuteAsync(
            sqlBuilder.BuildLifecycleOrphans(rule, "sourceSystem"),
            new { sourceSystem = rule.OwnershipScope, snapshotPks = snapshotPrimaryKeys },
            tx);

        // [6c] CHECKPOINT — ghi nhận version đã sync
        await conn.ExecuteAsync(checkpointSql, new { baselineVersion = snapshot.BaselineVersion, ... }, tx);

        // [6d] COMMIT — tất cả cùng lúc
        await tx.CommitAsync(ct);
        return new SyncRunResult { Outcome = Succeeded, RowsUpserted = ..., ... };
    }
    catch
    {
        await tx.RollbackAsync(ct);
        throw;
    }
}
```

---

## 4. Orphan Cleanup — Chi tiết

### Orphan là gì?

Row trong PostgreSQL target table **không còn tồn tại** trong snapshot bootstrap từ source.

### Ví dụ

```text
ERP Source: 1000 partners
Snapshot đọc được: 1000 rows (PartnerId 1-1000)
PostgreSQL Target trước bootstrap: 1050 rows (PartnerId 1-1000 cũ + 50 rows đã bị xóa từ ERP)

Sau khi UPSERT 1000 rows mới:
    → 50 rows với PartnerId > 1000 vẫn còn trong PG → ORPHANS

Orphan cleanup:
    UPDATE/DELETE 50 orphan rows
```

### Cơ chế quyết định: Soft-delete vs Hard-delete

```csharp
// Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:42-61
public string BuildLifecycleOrphans(TableMappingRule rule, string sourceSystemParameterName)
{
    var pk = rule.Target.PrimaryKey[0];
    var whereClause = $"\"source_system\" = @{sourceSystemParameterName}
                        AND \"{pk}\" <> ALL(@snapshotPks)";

    if (TryGetActiveFlagColumn(rule, out var activeFlagColumn))
        // → SOFT-DELETE: UPDATE active = false
        return $"UPDATE ... SET \"{activeFlagColumn}\" = false, \"synced_at\" = NOW()
                WHERE {whereClause}";

    // → HARD-DELETE: DELETE hoàn toàn row
    return $"DELETE FROM ... WHERE {whereClause}";
}
```

| Bảng | Có IsActiveFlag? | Orphan behavior |
|---|---|---|
| `ref.customer` | ❌ (chỉ `Map("active", ...)`) | **DELETE** |
| `ref.supplier` | ❌ | **DELETE** |
| `report.partners` | ✅ (`is_active` với `IsActiveFlag = true`) | **UPDATE active = false** |

### `source_system` trong WHERE clause

```sql
-- Ref.customer: hard-delete orphan
DELETE FROM "ref"."customer"
WHERE "source_system" = @sourceSystem         -- ← chỉ row của ERP
  AND "customer_id" <> ALL(@snapshotPks)      -- ← không có trong snapshot

-- Report.partners: soft-delete orphan
UPDATE "report"."partners"
SET "is_active" = false,
    "synced_at" = NOW()
WHERE "source_system" = @sourceSystem         -- ← chỉ row của ERP
  AND "partner_id" <> ALL(@snapshotPks)
```

**Tại sao cần `source_system` trong WHERE?**
- Nếu có nhiều hệ thống cùng ghi vào 1 bảng (multi-source), orphan cleanup của ERP chỉ được đụng vào row có tem `"erp"`
- Row từ Salesforce (`source_system = "salesforce"`) sẽ không bị ảnh hưởng
- Đây là cơ chế cô lập multi-source ở tầng orphan

---

## 5. UPSERT SQL — Cấu trúc câu lệnh

```sql
-- Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:7-22
INSERT INTO "ref"."customer"
    ("customer_id", "ua_customer_code", "name", "payment_terms",
     "target_margin_pct", "ga_factor", "active",
     "source_system", "synced_at")                 -- ← 2 metadata columns ở cuối
VALUES
    (@customer_id, @ua_customer_code, @name, @payment_terms,
     @target_margin_pct, @ga_factor, @active,
     @source_system, NOW())                         -- ← source_system từ code, synced_at = NOW()
ON CONFLICT ("customer_id")
DO UPDATE SET
    "ua_customer_code" = EXCLUDED."ua_customer_code",  -- ← data: lấy từ source
    "name" = EXCLUDED."name",
    "payment_terms" = EXCLUDED."payment_terms",
    "target_margin_pct" = EXCLUDED."target_margin_pct",
    "ga_factor" = EXCLUDED."ga_factor",
    "active" = EXCLUDED."active",
    "synced_at" = NOW()                                -- ← metadata: always NOW()
```

**Phân biệt INSERT vs UPDATE:**
- **INSERT VALUES:** Cả data columns + `source_system` (từ `rule.OwnershipScope`) + `synced_at` (NOW())
- **UPDATE SET:** Data columns dùng `EXCLUDED.<col>` (giá trị mới từ source), `synced_at` dùng `NOW()` trực tiếp

**Tại sao `synced_at` không dùng `EXCLUDED.synced_at`?**
- Về kỹ thuật, `EXCLUDED.synced_at` cũng = `NOW()` (vì INSERT VALUES đã set `NOW()`)
- Nhưng viết `NOW()` thể hiện rõ intent: đây là system-managed timestamp, không đến từ source data
- Tách biệt data column (EXCLUDED) và metadata column (NOW())

---

## 6. BuildTargetValues — Ánh xạ field

Mỗi row từ MSSQL được map sang PostgreSQL target values:

```csharp
// Infrastructure/CentralDbSync/PostgresGenericApplier.cs:205-216
private Dictionary<string, object?> BuildTargetValues(TableMappingRule rule, GenericSourceRow sourceRow)
{
    var values = new Dictionary<string, object?>();
    foreach (var column in rule.Columns)
        values[column.TargetColumn] = ResolveColumnValue(rule, column, sourceRow);

    values["source_system"] = rule.OwnershipScope;  // ← always set from rule config
    return values;
}
```

### Flow resolve giá trị cho 1 column

```csharp
// PostgresGenericApplier.cs:218-228
private object? ResolveColumnValue(TableMappingRule rule, ColumnMapping column, GenericSourceRow sourceRow)
{
    if (column.IsActiveFlag)                              // VD: is_active
        return IsActive(rule, sourceRow);                 // → tính từ ActivePredicate
    if (!string.IsNullOrWhiteSpace(column.Transform))     // VD: FORMAT(...)
        return transformerRegistry.Resolve(...);          // → chạy transformer
    if (!string.IsNullOrWhiteSpace(column.SourceColumn))  // VD: t0.PartnerId
        return sourceRow.GetValueOrDefault(column.SourceColumn);  // → copy giá trị
    return sourceRow.GetValueOrDefault(column.TargetColumn);      // → fallback
}
```

### Ví dụ mapping cho `ref.customer`

| MSSQL Source Row | ColumnMapping | Resolve logic | Target Value |
|---|---|---|---|
| `t0.PartnerId = 1` | `MapPk("customer_id", "integer", "t0.PartnerId")` | SourceColumn | `1` |
| `t0.Code = "C0001"` | `Map("ua_customer_code", "text", "t0.Code")` | SourceColumn | `"C0001"` |
| `t0.Name = "VU MINH THANG"` | `Map("name", "text", "t0.Name")` | SourceColumn | `"VU MINH THANG"` |
| `t0.Activated = true` | `Map("active", "boolean", "t0.Activated")` | SourceColumn | `true` |
| *(none)* | *(implicit)* | `values["source_system"] = rule.OwnershipScope` | `"erp"` |

---

## 7. Error handling

### Happy path

```text
POST /bootstrap/CRM.Partners to customer
    → 202 Accepted { requestId: "xxx", status: "queued" }

Hangfire picks up job
    → claim request (queued → running)
    → acquire lock ✓
    → read snapshot (CT version = 500, 66 rows)
    → upsert 66 rows + delete 0 orphans
    → checkpoint = 500
    → seed table_sync_config
    → mark request completed
```

### Lock conflict

```text
Worker A đang bootstrap "CRM.Partners to customer"
Worker B cố bootstrap cùng table:

Worker B:
    → claim request ✓ (queued → running)
    → acquire lock ✗ (pg_try_advisory_lock trả về false)
    → return SkippedLocked
    → reschedule sau 1 phút
```

### Read version drift

```text
Retry 1: baseline=100 → SELECT → versionAfter=101 → ROLLBACK
Retry 2: baseline=101 → SELECT → versionAfter=101 → OK ✓
```

### Failure (bất kỳ)

```text
Exception trong bất kỳ bước nào:
    → PostgreSQL transaction ROLLBACK (nếu đã bắt đầu)
    → Checkpoint KHÔNG thay đổi ← quan trọng!
    → Ghi runLog với error code
    → Mark request failed
    → Operator có thể retry từ đầu
```

---

## 8. Ví dụ hình dung (Analogy)

Bạn là quản lý kho, cần đồng bộ toàn bộ hàng từ kho cũ (ERP) sang kho mới (PostgreSQL):

| Bước | Code | Tương tự trong đời thực |
|---|---|---|
| **API call** | `POST /bootstrap/{ruleName}` | Nhấn nút "Đồng bộ kho" trên app |
| **SubmitAsync** | `CreateOrGetActiveAsync + EnqueueAsync` | Tạo phiếu yêu cầu, đưa vào hàng đợi xử lý |
| **Hangfire picks up** | `RunBootstrapAsync` | Nhân viên kho nhận phiếu, bắt đầu làm |
| **Claim request** | `TryMarkRunningAsync` | Đóng dấu "ĐANG XỬ LÝ" lên phiếu |
| **Acquire lock** | `pg_try_advisory_lock` | Khóa cửa kho mới — không ai được vào |
| **Read snapshot** | `Version Sandwich` | Chụp ảnh toàn bộ kho cũ, kiểm tra không có ai thêm/bớt hàng lúc chụp |
| **BuildTargetValues** | Map field từ source → target | Dán nhãn mới cho từng món hàng theo quy chuẩn kho mới |
| **UPSERT** | `INSERT ON CONFLICT DO UPDATE` | Xếp hàng lên kệ. Nếu đã có hàng ở vị trí đó → thay bằng hàng mới |
| **Orphan cleanup** | `DELETE WHERE pk <> ALL(@snapshotPks) AND source_system = 'erp'` | Quét kho: món nào không có trong ảnh chụp → vứt đi. Nhưng chỉ vứt đồ của ERP, không đụng đồ của Salesforce |
| **Checkpoint** | `INSERT checkpoint ... ON CONFLICT DO UPDATE` | Ghi sổ: "Đã đồng bộ xong đến version 500" |
| **Audit log** | `runLog.WriteAsync` | Ký tên vào sổ nhật ký kho |
| **COMMIT** | `tx.CommitAsync` | Mở khóa cửa kho, hoàn thành |

---

## 9. Tài liệu tham khảo

| Tài liệu | Nội dung |
|---|---|
| `notes/technical/2026-07-21-reader-consistent-snapshot-explained.md` | Version Sandwich mechanism chi tiết |
| `notes/technical/2026-07-21-applier-bootstrap-write-explained.md` | ApplyBootstrapAsync 4 bước trong 1 transaction |
| `notes/technical/2026-07-22-bootstrap-executecoreasync-explained.md` | ExecuteCoreAsync pipeline + error handling |
| `notes/technical/2026-07-21-advisory-lock-explained.md` | PostgreSQL advisory lock + watchdog mechanism |
| `notes/technical/2026-07-21-enqueue-watchdog-explained.md` | Watchdog chống crash giữa create & enqueue |
| `notes/2026-07-19-snapshot-isolation-decision.md` | Tại sao không dùng SNAPSHOT isolation |

---

## 10. File mapping

| File | Vai trò |
|---|---|
| `WebApi/Controllers/CentralDbSyncController.cs:61-93` | API endpoint — validate rule, submit request, return 202 |
| `Application/.../Services/BootstrapRequestService.cs:25-78` | SubmitAsync — tạo work ticket + enqueue Hangfire + watchdog |
| `Infrastructure/CentralDbSync/HangfireBootstrapJobScheduler.cs:6-15` | EnqueueAsync / ScheduleAsync — wrapper Hangfire |
| `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs:72-140` | RunBootstrapAsync — claim + execute + handle result |
| `Application/.../Services/BootstrapSyncService.cs:23-56` | ExecuteAsync — acquire lock + gọi core pipeline |
| `Application/.../Services/BootstrapSyncService.cs:73-136` | ExecuteCoreAsync — 3-phase pipeline (read → apply → audit) |
| `Application/.../Services/BootstrapSyncService.cs:106-169` | Error handling — không sửa checkpoint khi fail |
| `Infrastructure/.../PostgresGenericApplier.cs:124-203` | ApplyBootstrapAsync — 4 bước trong 1 transaction |
| `Infrastructure/.../PostgresGenericApplier.cs:205-216` | BuildTargetValues — map field + set source_system |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:7-22` | BuildUpsert — INSERT ON CONFLICT DO UPDATE |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:42-61` | BuildLifecycleOrphans — soft-delete vs hard-delete |
| `Infrastructure/CentralDbSync/SqlServerGenericReader.cs:22-69` | Bootstrap reader — version sandwich + retry |
| `Infrastructure/CentralDbSync/PostgresSyncConfigStore.cs` | SeedAsync — seed table_sync_config sau bootstrap |
| `Application/.../Config/Rules/CRM/CrmPartnerMappingRuleCatalog.cs` | Mapping rules cho customer & supplier |

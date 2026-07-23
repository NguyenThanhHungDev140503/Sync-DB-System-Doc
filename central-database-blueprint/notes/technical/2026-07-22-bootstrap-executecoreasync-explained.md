# `ExecuteCoreAsync` — Bootstrap sync pipeline

**Ngày:** 2026-07-22
**Phân tích bởi:** Hung NT
**Commit tham chiếu:** `a7757b72`
**Liên quan:** Central DB Sync Phase 1-2

---

## 1. Vấn đề (Problem Statement)

Làm sao để đồng bộ toàn bộ dữ liệu của một bảng từ **SQL Server (ERP)** sang **PostgreSQL (mobile app)** một cách an toàn, nhất quán, và có thể scale? Trong đó:

- Dữ liệu nguồn có thể vài triệu dòng, đang được ứng dụng ERP ghi liên tục
- Cần đảm bảo không mất dữ liệu, không duplicate, không đọc lẫn giữa dòng cũ và dòng mới
- Distributed lock để tránh nhiều worker sync cùng một table

---

## 2. Flow tổng quan (End-to-end)

```text
Hangfire Job
  CentralDbSyncJobs.RunBootstrapAsync
  │
  ├── [1] BootstrapRequestService.TryMarkRunningAsync
  │       └── Claim request → chuyển từ PendingEnqueue → Running
  │
  ├── [2] BootstrapSyncService.ExecuteAsync(config, runId, ct)
  │       │
  │       ├── [2a] syncLock.TryAcquireAsync(leaseTimeout: 12 min)
  │       │       └── PostgreSQL pg_try_advisory_lock()
  │       │       └── Tạo AdvisoryLockHandle + watchdog (force-release sau 12 phút)
  │       │
  │       ├── [2b] ExecuteCoreAsync(config, runId, startedAt, ct)
  │       │       │
  │       │       ├── [2b-1] reader.ReadAsync(MSSQL)
  │       │       │       └── Version sandwich → ensure consistency
  │       │       │
  │       │       ├── [2b-2] applier.ApplyBootstrapAsync(PostgreSQL)
  │       │       │       └── Upsert + deactivate orphans + set checkpoint
  │       │       │
  │       │       └── [2b-3] runLog.WriteAsync(PostgreSQL)
  │       │               └── Ghi kết quả sync
  │       │
  │       └── (await using lockHandle → tự động DisposeAsync → pg_advisory_unlock)
  │
  └── [3] Xử lý kết quả (Succeeded / SkippedLocked / Failed)
          └── Seed table_sync_config nếu thành công
```

---

## 3. ExecuteCoreAsync — Core bootstrap logic

### 3.1 Mã nguồn

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:73-136
private async Task<SyncRunResult> ExecuteCoreAsync(
    TableSyncConfig config,
    Guid runId,
    DateTime startedAt,
    CancellationToken cancellationToken)
{
    try
    {
        // [2b-1] Đọc snapshot từ SQL Server
        var snapshot = await reader.ReadAsync(config, cancellationToken);

        // [2b-2] Ghi vào PostgreSQL trong một transaction
        var result = await applier.ApplyBootstrapAsync(config, snapshot, cancellationToken);

        // [2b-3] Ghi audit log
        var finishedAt = DateTime.UtcNow;
        SyncGuard.AssertValidOutcome(result.Outcome, nameof(result.Outcome));
        await runLog.WriteAsync(new SyncRunLogEntry
        {
            RunId = runId,
            SourceTable = config.SourceTable,
            Mode = "Bootstrap",
            Outcome = result.Outcome,
            RowsRead = snapshot.Rows.Count,
            RowsUpserted = result.RowsUpserted,
            RowsDeactivated = result.RowsDeactivated,
            RowsDeleted = result.RowsDeleted,
            CheckpointBefore = null,
            CheckpointAfter = snapshot.BaselineVersion,
            StartedAt = startedAt,
            FinishedAt = finishedAt,
            DurationMs = (int)(finishedAt - startedAt).TotalMilliseconds
        }, cancellationToken);

        return result;
    }
    catch (OperationCanceledException)
    {
        logger.LogInformation("Bootstrap sync cancelled for {SourceTable}", config.SourceTable);
        await runLog.WriteAsync(
            CreateFailedEntry(config.SourceTable, runId, startedAt,
                "Cancelled", "Operation was cancelled"),
            CancellationToken.None);
        throw;
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Bootstrap sync failed for {SourceTable}", config.SourceTable);
        await runLog.WriteAsync(
            CreateFailedEntry(config.SourceTable, runId, startedAt,
                "BootstrapFailed", ex.Message),
            CancellationToken.None);

        return new SyncRunResult { Outcome = SyncStatus.Outcome.Failed,
            ErrorCode = "BootstrapFailed", ErrorMessage = ex.Message };
    }
}
```

### 3.2 Vai trò

`ExecuteCoreAsync` là **core execution** của bootstrap sync. Nó delegate toàn bộ việc đọc-ghi cho 3 component:

| Component | Interface | File |
|---|---|---|
| **Reader** | `IBootstrapSnapshotReader` | `Infrastructure/.../SqlServerGenericReader.cs:22-69` |
| **Applier** | `ISyncBatchApplier` | `Infrastructure/.../PostgresSyncBatchApplier.cs` |
| **RunLog** | `ISyncRunLog` | `Infrastructure/.../PostgresSyncRunLog.cs` |

---

## 4. Reader — Cơ chế Version Sandwich

### 4.1 Vấn đề

Khi đọc bảng nguồn vài triệu dòng, có thể mất 30-60 giây. Trong thời gian đó, ứng dụng ERP có thể INSERT/UPDATE/DELETE dữ liệu. Nếu ta đọc được row A ở version 5, row B ở version 6 (sau khi có write), thì snapshot của ta sẽ **không nhất quán** — như kiểu chụp ảnh mà nửa đầu ảnh cũ nửa sau ảnh mới.

### 4.2 Tại sao không dùng SNAPSHOT isolation?

Xem `docs/central-database-blueprint/notes/2026-07-19-snapshot-isolation-decision.md`:

- Cần bật `ALLOW_SNAPSHOT_ISOLATION ON` ở DB level — shared dev DB, team không muốn thay đổi config
- Snapshot isolation tốn tempdb row version store
- Giải pháp thay thế: **ReadCommitted + version sandwich + retry loop**

### 4.3 Implementation

```csharp
// Infrastructure/CentralDbSync/SqlServerGenericReader.cs:22-69
async Task<BootstrapSnapshot> IBootstrapSnapshotReader.ReadAsync(
    TableSyncConfig config, CancellationToken ct)
{
    using var conn = new SqlConnection(connectionString);
    await conn.OpenAsync(ct);

    for (var attempt = 1; attempt <= MaxBootstrapRetries; attempt++)
    {
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(
            IsolationLevel.ReadCommitted, ct);

        try
        {
            // [A] Đọc CT version TRƯỚC khi đọc data
            var baseline = await conn.ExecuteScalarAsync<long>(
                "SELECT CHANGE_TRACKING_CURRENT_VERSION()", transaction: tx);

            // [B] Đọc TOÀN BỘ rows
            var rows = await ReadRowsAsync(conn, tx, select, ct);

            // [C] Đọc CT version SAU khi đọc data
            var versionAfter = await conn.ExecuteScalarAsync<long>(
                "SELECT CHANGE_TRACKING_CURRENT_VERSION()", transaction: tx);

            // [D] Nếu version không đổi → data nhất quán
            if (baseline == versionAfter)
            {
                await tx.CommitAsync(ct);
                return new BootstrapSnapshot(baseline, rows);
            }

            // [E] Version thay đổi → ai đó ghi vào bảng → RETRY
            await tx.RollbackAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(ct);
            throw;
        }
    }

    throw new InvalidOperationException(
        "Failed to capture a consistent bootstrap snapshot after 3 attempts.");
}
```

### 4.4 Cơ chế hoạt động

```text
Timeline:
  T1: BEGIN TRANSACTION ReadCommitted
  T2: GET CHANGE_TRACKING_CURRENT_VERSION()   → baseline = 42
  T3: SELECT * FROM source_table              → bắt đầu đọc rows
  T3+30s: kết thúc đọc, được 3,000,000 rows
  T4: GET CHANGE_TRACKING_CURRENT_VERSION()   → versionAfter = 42

  Nếu baseline == versionAfter:
       → Trong suốt 30 giây, KHÔNG có ai COMMIT thay đổi lên bảng này
       → Data nhất quán ✓
       → COMMIT, trả về snapshot

  Nếu baseline ≠ versionAfter:
       → Có transaction khác đã ghi vào bảng
       → Data KHÔNG nhất quán ✗
       → ROLLBACK, retry lần 2 (tối đa 3 lần)
```

### 4.5 Giới hạn

**Với bảng traffic cao** (liên tục có INSERT/UPDATE):

```text
Retry 1: baseline=100 → đọc xong → versionAfter=101 → ROLLBACK
Retry 2: baseline=101 → đọc xong → versionAfter=102 → ROLLBACK
Retry 3: baseline=102 → đọc xong → versionAfter=103 → ROLLBACK
→ THROW InvalidOperationException → bootstrap request thất bại
```

Đây là **race condition** cố hữu của optimistic approach. Trong thực tế:
- Nếu bảng chỉ có vài nghìn rows (đọc trong <1s), xác suất conflict rất thấp
- Nếu bảng vài triệu rows, nên schedule bootstrap vào giờ thấp điểm
- Với traffic cực cao, nên cân nhắc bật `ALLOW_SNAPSHOT_ISOLATION`

---

## 5. Applier — Ghi vào PostgreSQL

### 5.1 Công việc của applier

Sau khi đọc được snapshot nhất quán từ SQL Server, `ApplyBootstrapAsync` thực hiện trong **một PostgreSQL transaction**:

```text
BEGIN TRANSACTION
  ├── UPSERT tất cả rows từ snapshot vào target table
  │      (INSERT nếu chưa có, UPDATE nếu đã có theo primary key)
  │
  ├── DEACTIVATE orphans
  │      (rows trong target mà không có trong snapshot → deactivated = true)
  │
  └── SET checkpoint = snapshot.BaselineVersion
         (đánh dấu đã sync đến version nào, cho lần sau chỉ sync delta)
COMMIT
```

### 5.2 Ý nghĩa

| Thao tác | Mục đích |
|---|---|
| **Upsert** | Target có đúng dữ liệu mới nhất từ source |
| **Deactivate orphans** | Nếu ERP xoá một row (không nằm trong snapshot) mà row đó đã sync trước đó, không xoá khỏi mobile app (tránh mất dữ liệu historical) mà chỉ đánh `deactivated = true` |
| **Set checkpoint** | `BaselineVersion` là số version từ SQL Server Change Tracking, lần sau ChangeTrackingSyncService sẽ bắt đầu từ version này |

---

## 6. Error handling

### Happy path

```csharp
// BootstrapSyncService.cs:83-107
var snapshot = await reader.ReadAsync(config, cancellationToken);
var result = await applier.ApplyBootstrapAsync(config, snapshot, cancellationToken);
// → ghi runlog, return result.Succeeded
```

### Cancelled

```csharp
// BootstrapSyncService.cs:110-117
catch (OperationCanceledException)
{
    // Job bị cancel từ Hangfire hoặc timeout
    // KHÔNG return result — re-throw để caller biết
    throw;
}
```

### Exception

```csharp
// BootstrapSyncService.cs:118-135
catch (Exception ex)
{
    // Lỗi bất kỳ (connection fail, timeout, data error...)
    // KHÔNG thay đổi checkpoint — operator có thể retry từ cùng checkpoint
    // Chỉ ghi runlog, return Failed
}
```

**Nguyên tắc quan trọng:** Bootstrap failure **không được sửa checkpoint**. Operator có thể retry lần sau, và hệ thống sẽ đọc lại từ đầu.

---

## 7. Ai gọi ExecuteCoreAsync?

Có **2 caller** của `ExecuteCoreAsync`:

### 7.1 Caller 1: `ExecuteAsync` (normal bootstrap)

```csharp
// BootstrapSyncService.cs:23-56
public async Task<SyncRunResult> ExecuteAsync(
    TableSyncConfig config, Guid runId, CancellationToken ct)
{
    // Acquire lock trước (lease 12 phút)
    await using var lockHandle = await syncLock.TryAcquireAsync(
        config.SourceTable, ct, TimeSpan.FromMinutes(12));

    if (lockHandle is null) return SkippedLocked;

    // Gọi ExecuteCoreAsync
    return await ExecuteCoreAsync(config, runId, startedAt, ct);
}
```

### 7.2 Caller 2: `ExecuteWithProvidedLockAsync` (CT-invalid recovery)

```csharp
// BootstrapSyncService.cs:63-71
public async Task<SyncRunResult> ExecuteWithProvidedLockAsync(
    TableSyncConfig config, Guid runId, DateTime startedAt, CancellationToken ct)
{
    ValidateConfig(config);
    return await ExecuteCoreAsync(config, runId, startedAt, ct);
}
```

Được `ChangeTrackingSyncService` gọi khi gặp `CheckpointInvalidException` — nhưng **không release lock** giữa 2 operations, vì worker khác có thể cướp lock:

```csharp
// ChangeTrackingSyncService.cs:89-107
catch (CheckpointInvalidException)
{
    // Bootstrap recovery chạy DƯỚI CÙNG LOCK
    return await bootstrapService.ExecuteWithProvidedLockAsync(
        config, Guid.NewGuid(), startedAt, cancellationToken);
}
```

---

## 8. Ví dụ hình dung (Analogy)

Giả sử bạn cần **chụp ảnh toàn bộ giá sách** trong thư viện, nhưng thủ thư vẫn đang bỏ sách mới vào và lấy sách cũ ra:

| Bước | Code | Analogy |
|---|---|---|
| Acquire lock | `syncLock.TryAcquireAsync` | Đặt tờ giấy "ĐANG CHỤP" trên bàn thủ thư |
| Đọc version | `CHANGE_TRACKING_CURRENT_VERSION()` | Ghi lại số lần chuông reo hiện tại của thư viện |
| Đọc data | `reader.ReadAsync` | Chụp từng kệ sách từ trái sang phải |
| Kiểm tra version | So sánh baseline vs versionAfter | Sau khi chụp xong, kiểm tra chuông reo — nếu số bằng nhau thì không có sách mới nào được thêm vào giữa chừng |
| Ghi vào target | `applier.ApplyBootstrapAsync` | Dán ảnh vào album mới, bỏ ảnh cũ, đánh dấu cuốn sách nào đã mất |
| Set checkpoint | = BaselineVersion | Ghi dấu trang: "lần tới đọc từ trang 42" |

---

## 9. File mapping

| File | Vai trò |
|---|---|
| `Application/.../Services/BootstrapSyncService.cs:73-136` | `ExecuteCoreAsync` — orchestrator 3 bước |
| `Application/.../Services/BootstrapSyncService.cs:23-56` | `ExecuteAsync` — acquire lock + gọi ExecuteCoreAsync |
| `Application/.../Services/BootstrapSyncService.cs:63-71` | `ExecuteWithProvidedLockAsync` — CT recovery path |
| `Infrastructure/.../SqlServerGenericReader.cs:22-69` | Bootstrap reader: ReadCommitted + version sandwich + retry |
| `Infrastructure/.../PostgresTableSyncLock.cs:11-43` | `TryAcquireAsync` — PostgreSQL advisory lock |
| `Infrastructure/.../PostgresTableSyncLock.cs:60-150` | `AdvisoryLockHandle` — watchdog lease timeout |
| `Infrastructure/.../CentralDbSyncJobs.cs:72-140` | `RunBootstrapAsync` — Hangfire job entry point |
| `Infrastructure/.../CentralDbSyncJobs.cs:59-63` | 5-minute timeout bọc orchestrator |
| `Infrastructure/.../CentralDbSyncJobs.cs:93` | 10-minute timeout bọc bootstrap service |
| `Application/.../Abstractions/IBootstrapSnapshotReader.cs` | Interface định nghĩa contract đọc snapshot |
| `docs/.../notes/2026-07-19-snapshot-isolation-decision.md` | Giải thích lý do không dùng SNAPSHOT isolation |

---

## 10. Câu hỏi tự kiểm tra

1. Tại sao `ExecuteCoreAsync` không acquire lock? Ai acquire lock trước khi gọi nó?
2. Làm sao đảm bảo data nhất quán khi đọc từ SQL Server mà không dùng SNAPSHOT isolation?
3. Điều gì xảy ra nếu CHANGE_TRACKING_CURRENT_VERSION() thay đổi trong lúc đang đọc data?
4. Tại sao `ExecuteWithProvidedLockAsync` tồn tại — tại sao không simply acquire lock lại?
5. Bootstrap failure có làm mất checkpoint không? Tại sao?
6. Điều gì xảy ra nếu reader retry cả 3 lần đều thất bại?

---

## Xem thêm

- [`2026-07-19-snapshot-isolation-decision.md`](../2026-07-19-snapshot-isolation-decision.md) — Tại sao không dùng SNAPSHOT isolation
- [`2026-07-21-advisory-lock-explained.md`] — Cơ chế watchdog lease timeout
- [`2026-07-21-applier-bootstrap-write-explained.md`] — Applier upsert chi tiết

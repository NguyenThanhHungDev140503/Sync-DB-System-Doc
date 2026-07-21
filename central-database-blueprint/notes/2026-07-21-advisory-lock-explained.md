# Advisory Lock trong Central DB Sync

**Ngày:** 2026-07-21

## Vấn đề

Central DB Sync có nhiều worker chạy đồng thời: bootstrap (chạy thủ công), CT sync (chạy mỗi 1 phút), recovery (tự động khi checkpoint invalid). Nếu 2 worker cùng đọc data từ SQL Server và ghi vào PostgreSQL `report.partners` cùng lúc, dữ liệu sẽ bị corrupt.

Cần một cơ chế để đảm bảo **chỉ một worker được xử lý một table tại một thời điểm**.

## Advisory lock là gì?

Advisory lock là một **khóa tùy ý (application-level)** do PostgreSQL cung cấp. Không giống row lock hay table lock, nó không gắn với dữ liệu cụ thể — nó chỉ là một **con số nguyên 64-bit** mà các worker thỏa thuận dùng chung.

```sql
-- Cú pháp PostgreSQL
SELECT pg_try_advisory_lock(123);  -- thử lấy, trả về true/false
SELECT pg_advisory_lock(123);     -- chờ đến khi lấy được (blocking)
SELECT pg_advisory_unlock(123);   -- release
```

### Đặc điểm chính

| Tính chất | Giá trị |
|---|---|
| Loại | Session-level (giữ đến khi connection đóng) |
| Phạm vi | Toàn bộ PostgreSQL instance (cả database) |
| Blocking? | `pg_try_advisory_lock` = non-blocking (trả về false ngay) |
| Key space | 64-bit integer (~9.2 tỷ tỷ giá trị) |
| Transaction-scoped? | **Không** — lock là session-level, không auto release khi COMMIT/ROLLBACK |

## Tại sao không dùng lock mặc định của database?

### Row lock (`SELECT ... FOR UPDATE`)
- Chỉ khóa **các dòng cụ thể** đang được SELECT
- 2 worker vẫn chạy cùng lúc, mỗi thằng xử lý các dòng khác nhau
- Không ngăn được việc 2 worker cùng upsert vào cùng 1 table
- Hậu quả: checkpoint bị ghi đè, dữ liệu mất consistency

### Table lock (`LOCK TABLE`)
- Khóa cả bảng PostgreSQL — các query SELECT thông thường cũng bị block
- Ảnh hưởng đến reporting consumers đang đọc `report.partners`
- Quá nặng so với nhu cầu thực tế

### Advisory lock
- Chỉ ảnh hưởng đến các worker cùng biết key
- Các query đọc bình thường KHÔNG bị ảnh hưởng
- Nhẹ, nhanh, không ảnh hưởng hệ thống

## Chi tiết implementation

### Bước 0: Interface

```csharp
// Application/Features/CentralDbSync/Abstractions/ITableSyncLock.cs
public interface ITableSyncLock
{
    // Trả về handle nếu lấy được lock, null nếu không
    Task<IAsyncDisposable?> TryAcquireAsync(
        string sourceTable,
        CancellationToken cancellationToken);
}
```

### Bước 1: Tính key — FNV-1a 64-bit hash

Mỗi table có một key riêng. Key được hash từ chuỗi `"central-db-sync:" + sourceTable` bằng thuật toán FNV-1a:

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:41-54
private static long GetStableLockHash(string key)
{
    unchecked
    {
        ulong hash = 14695981039346656037;  // FNV-1a offset basis
        foreach (var c in key)
        {
            hash ^= c;                       // XOR với từng byte
            hash *= 1099511628211;           // nhân với FNV prime
        }
        return (long)hash;
    }
}
```

Kết quả:
- `hash("central-db-sync:CRM.Partners")` → key cho CRM.Partners
- `hash("central-db-sync:ERP.Configs.Units")` → key cho ERP.Configs.Units
- `hash("central-db-sync:ERP.Configs.Sizes")` → key cho ERP.Configs.Sizes

FNV-1a là deterministic (cùng input → cùng output), collision-resistant, không cần khởi tạo.

### Bước 2: Lấy khóa — TryAcquireAsync

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:11-39
public async Task<IAsyncDisposable?> TryAcquireAsync(
    string sourceTable, CancellationToken ct)
{
    var lockKey = GetStableLockHash($"central-db-sync:{sourceTable}");

    // Mở connection riêng — lock là session-level,
    // cần connection riêng để không bị ảnh hưởng bởi các transaction khác
    var conn = new NpgsqlConnection(connectionString);
    await conn.OpenAsync(ct);

    try
    {
        var acquired = await conn.ExecuteScalarAsync<bool>(
            "SELECT pg_try_advisory_lock(@lockKey)",
            new { lockKey });

        if (!acquired)
        {
            // Không lấy được → dispose connection, trả về null
            await conn.DisposeAsync();
            return null;
        }

        // Lấy được → trả về handle chứa connection
        // Caller giữ handle này, khi dispose → unlock + đóng connection
        return new AdvisoryLockHandle(conn, lockKey);
    }
    catch
    {
        await conn.DisposeAsync();
        throw;
    }
}
```

**Important:** Mỗi lock dùng một `NpgsqlConnection` riêng. Advisory lock là **session-level** — nếu dùng chung connection với transaction upsert, commit transaction sẽ không release lock, nhưng nếu connection bị đóng (pool return) giữa chừng thì lock mất.

### Bước 3: Giải phóng — AdvisoryLockHandle

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:56-84
private sealed class AdvisoryLockHandle : IAsyncDisposable
{
    private readonly NpgsqlConnection _connection;
    private readonly long _lockKey;
    private bool _disposed;

    public AdvisoryLockHandle(NpgsqlConnection connection, long lockKey)
    {
        _connection = connection;
        _lockKey = lockKey;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;

        try
        {
            // Gọi pg_advisory_unlock trước khi đóng connection
            await _connection.ExecuteAsync(
                "SELECT pg_advisory_unlock(@lockKey)",
                new { lockKey = _lockKey });
        }
        finally
        {
            // Đóng connection — dự phòng nếu unlock fail
            await _connection.DisposeAsync();
        }
    }
}
```

Dispose gọi `pg_advisory_unlock` **rồi mới** đóng connection (dự phòng). Nếu unlock fail, connection đóng cũng tự động release lock.

## Cách dùng trong BootstrapSyncService

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:30-55
await using var lockHandle = await syncLock.TryAcquireAsync(
    config.SourceTable, cancellationToken);

if (lockHandle is null)
{
    // ── Lock busy ──
    logger.LogDebug(
        "Bootstrap sync skipped for {SourceTable}: lock not acquired",
        config.SourceTable);

    // Ghi audit log với outcome = "skipped_locked"
    await runLog.WriteAsync(new SyncRunLogEntry
    {
        RunId = runId,
        SourceTable = config.SourceTable,
        Mode = "Bootstrap",
        Outcome = "skipped_locked",
        StartedAt = startedAt,
        FinishedAt = DateTime.UtcNow,
        DurationMs = 0
    }, CancellationToken.None);

    // Trả về kết quả — không retry, để CT cycle sau hoặc reschedule
    return new SyncRunResult { Outcome = "skipped_locked" };
}

// ── Lock OK ──
// await using → khi scope kết thúc, lock handle tự dispose
return await ExecuteCoreAsync(config, runId, startedAt, cancellationToken);
```

## Tổng quan lifetime của lock handle

```text
using var handle = TryAcquireAsync()
      │
      ├── true (acquired) ──▶ ExecuteCoreAsync()
      │                          │
      │                          ├─ reader.ReadAsync()
      │                          ├─ applier.ApplyBootstrapAsync()
      │                          └─ runLog.WriteAsync()
      │                              │
      │                      ◀──────┘ return SyncRunResult
      │
      └── dispose handle ──▶ pg_advisory_unlock()
                                   └── connection.Dispose()
```

## Các kịch bản lock chi tiết

### Kịch bản 1: Bootstrap + CT cùng lúc

```text
Thời gian:        t1           t2           t3           t4
Bootstrap:  [acquire lock]  [read+write]  [done]  [release lock]
CT sync:                     [try lock]→false  [SkippedLocked]
```
Kết quả: CT cycle bỏ qua, retry ở cycle sau (1 phút).

### Kịch bản 2: 2 bootstrap requests cùng lúc

```text
Request 1:  [INSERT request]  [acquire lock]  [read SQL]  [write PG]
Request 2:                    [try lock]→false  [MarkWaitingForLock]
                                     └── schedule lại sau 1 phút
```
Kết quả: Request 2 không failed — nó chuyển sang `waiting_for_lock`, reschedule, thử lại sau.

### Kịch bản 3: CT recovery sau checkpoint invalid

Khi CT gặp `CheckpointInvalidException` (CT retention hết hạn), nó cần chạy full bootstrap để recovery. Code cũ dùng `ExecuteWithProvidedLockAsync` — **giữ nguyên lock handle**, không release rồi acquire lại:

```csharp
// BootstrapSyncService.ExecuteWithProvidedLockAsync — reuse lock handle
public async Task<SyncRunResult> ExecuteWithProvidedLockAsync(
    TableSyncConfig config, Guid runId, DateTime startedAt, ...)
{
    // KHÔNG acquire lock — vì CT đã acquire rồi
    // Chạy thẳng ExecuteCoreAsync với lock handle hiện tại
    return await ExecuteCoreAsync(config, runId, startedAt, cancellationToken);
}
```

Nếu release rồi acquire lại, worker khác có thể lấy lock ở giữa → conflict.

## Rủi ro và lưu ý

### Connection leak
Nếu `AdvisoryLockHandle.DisposeAsync` không được gọi (exception unexpected, memory leak), connection không đóng → lock không release. Đến lúc PostgreSQL timeout (`idle_in_transaction_session_timeout` hoặc connection pool timeout) thì lock mới được giải phóng.

```csharp
// Luôn dùng await using để đảm bảo dispose
await using var handle = syncLock.TryAcquireAsync(...);
```

### Không transaction-scoped
Advisory lock là session-level, không phải transaction-level. Nếu bạn COMMIT transaction (upsert xong) nhưng quên dispose handle (connection còn mở), worker khác vẫn không lấy được lock.

### Key collision giữa các table
Key là 64-bit integer → xác suất collision cực thấp (nhưng vẫn có). Nếu xảy ra, 2 table khác nhau sẽ blocking lẫn nhau. Hiện tại chỉ có 3 tables nên không đáng ngại.

### Lock không phải là tường lửa tuyệt đối
Advisory lock chỉ ngăn worker khác nếu worker đó cũng gọi `pg_try_advisory_lock` cùng key. Worker nào không gọi lock (bug, code sai) vẫn có thể chạy song song. Tuy nhiên, lớp bảo vệ thứ hai là **optimistic guard trên checkpoint** (`WHERE last_sync_version = @previous` trong checkpoint UPDATE) — rollback nếu phát hiện conflict.

## Ví dụ hình dung

Advisory lock giống như **chìa khóa phòng họp**:
- Mỗi phòng (table) có một con số riêng: 123 = CRM.Partners, 456 = Units, 789 = Sizes
- Ai lấy được chìa 123 thì vào phòng "CRM.Partners" làm việc
- Ai đến sau thấy cửa khóa thì đi về, hẹn 1 phút sau quay lại
- Khi ra khỏi phòng, trả chìa khóa (pg_advisory_unlock) hoặc đóng cửa (connection close)
- Các phòng khác (456, 789) có chìa riêng → không bị ảnh hưởng

## Mã nguồn

| File | Vai trò |
|---|---|
| `Application/Features/CentralDbSync/Abstractions/ITableSyncLock.cs:1-8` | Interface contract |
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:7-84` | Implementation: FNV-1a hash, pg_try_advisory_lock, handle dispose |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:30-55` | Sử dụng lock trong bootstrap flow |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs` | CT sync cũng dùng ITableSyncLock |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:63-71` | ExecuteWithProvidedLockAsync — same-lock recovery |

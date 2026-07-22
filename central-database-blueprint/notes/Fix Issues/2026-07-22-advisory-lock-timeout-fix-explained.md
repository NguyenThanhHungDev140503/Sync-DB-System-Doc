# Advisory Lock Timeout Fix — Defense in Depth (Layer 1 + 3)

**Ngày:** 2026-07-22  
**Mô tả:** Giải thích lý do tại sao advisory lock hiện tại dễ bị forever-lock, và cách fix bằng CancellationToken timeout (Layer 1) + watchdog sử dụng Interlocked guard (Layer 3).

---

## Vấn đề: Process treo → lock vĩnh viễn

PostgreSQL advisory lock trong Central DB Sync hiện tại chỉ được release qua `DisposeAsync()` của `AdvisoryLockHandle`:

```
Flow bình thường (OK):
  TryAcquireAsync() → lấy lock → ExecuteCoreAsync() → DisposeAsync() → unlock

Flow treo (CRITICAL):
  TryAcquireAsync() → lấy lock → [PROCESS TREO ở reader.ReadAsync]
                                     ↓
                          lock không bao giờ release
                          → table đó không sync được nữa
```

**Tại sao Postgres không tự release?**
- App crash → OS đóng TCP socket → Postgres backend nhận RST → session chết → **lock release tự động** (crash path)
- App treo (hang) → OS vẫn gửi TCP keepalive → Postgres thấy connection alive → **lock vĩnh viễn** (hang path)
- Postgres **không có khả năng phân biệt** app-hang vs app-idle: cả 2 đều là "connection alive"

**Tại sao server-side timeout không đủ?**
- `statement_timeout` → chỉ kill SQL query đang chạy, không kill session idle
- `idle_in_transaction_session_timeout` → advisory lock là session-level, **không nằm trong transaction** nào
- `pg_advisory_lock` ≠ `pg_advisory_xact_lock` → lock sống độc lập với transaction
- Kết quả: session ở trạng thái `idle` (không `idle in transaction`) → cả 2 timeout đều **bỏ qua**

## Giải pháp: Defense in Depth (Layer 1 + Layer 3)

Không phải chọn 1 trong 2 — cả 2 lớp bù trừ cho nhau:

| Layer | Cơ chế | Giải quyết | Giới hạn |
|---|---|---|---|
| **Layer 1** | `CancellationTokenSource` timeout trên execution | Code unwind sạch, thread trả về pool, log "cancelled" | Chỉ tác dụng nếu code async honor `ct` |
| **Layer 3** | Watchdog timer trong `AdvisoryLockHandle` | Force-release lock ngay cả khi code không check `ct` | Chỉ cắt lock, app thread vẫn treo |

### Layer 1 — Cái gì?

Layer 1 là thêm `CancellationTokenSource(TimeSpan)` để cancel execution khi quá thời gian cho phép. Không phải để **tránh** treo — mà để **chấm dứt** treo một cách sạch sẽ.

#### Trước khi có Layer 1

```csharp
// CentralDbSyncJobs.cs:89 — HIỆN TẠI
// CancellationToken.None → không bao giờ timeout
var result = await bootstrapService.ExecuteAsync(config, requestId, CancellationToken.None);
```

```csharp
// BootstrapSyncService.cs:83 — HIỆN TẠI
// reader.ReadAsync nhận ct, nhưng ct không có timeout
var snapshot = await reader.ReadAsync(config, cancellationToken);
// Nếu cancellationToken chưa bị cancel, await này không bao giờ kết thúc
// → lock không bao giờ release
```

#### Sau khi có Layer 1

```csharp
// CentralDbSyncJobs.cs — VỚI LAYER 1
public async Task RunBootstrapAsync(string sourceTable, Guid requestId)
{
    using var scope = _scopeFactory.CreateScope();
    // ...
    // ⭐ Tạo CancellationTokenSource với timeout
    using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
    var result = await bootstrapService.ExecuteAsync(
        config, requestId, cts.Token);
    // Khi quá 10 phút → cts.Token bị cancel
    // → reader.ReadAsync nhận token → bắn OperationCanceledException
    // → stack unwind → DisposeAsync của lock handle chạy → unlock
}
```

**Cơ chế cụ thể:**

1. `CancellationTokenSource(10ph)` tạo ra `CancellationToken` sẽ tự động cancel sau 10 phút
2. Token này truyền xuyên suốt: `ExecuteAsync` → `ExecuteCoreAsync` → `reader.ReadAsync(ct)` → Dapper `ExecuteScalarAsync(ct)` → Npgsql command
3. Khi token cancel, Npgsql `Command` đang chạy bị hủy → `OperationCanceledException` được throw
4. Exception stack unwind qua `catch` block → log "Cancelled" → `await using` scope end → `AdvisoryLockHandle.DisposeAsync()` → `pg_advisory_unlock`
5. Thread được giải phóng ngay lập tức — không phải chờ driver timeout

#### Khi nào Layer 1 bất lực?

Layer 1 **chỉ hoạt động** nếu code async check `CancellationToken`. Nếu:

- Code dùng blocking sync call (`.Result`, `.Wait()`, synchronous reader)
- Deadlock ở driver level (code không vào được await point)
- Infinite loop trong code (không await nào được gọi)

...thì `CancellationToken` không thể abort thread — exception không được throw tại await point.

Đây là lúc Layer 3 phát huy tác dụng.

### Layer 3 — Watchdog trong AdvisoryLockHandle

Layer 3 thêm một timer vào `AdvisoryLockHandle` để chủ động gọi `pg_advisory_unlock` + đóng connection **kể cả khi app code không thể tự unwind**.

#### Code thiết kế

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs — VỚI LAYER 3
private sealed class AdvisoryLockHandle : IAsyncDisposable
{
    private readonly NpgsqlConnection _connection;
    private readonly long _lockKey;
    private int _disposed;  // ⭐ int (không phải bool) cho Interlocked
    private readonly CancellationTokenSource _watchdogCts;
    private readonly Task _watchdogTask;

    public AdvisoryLockHandle(NpgsqlConnection connection, long lockKey, TimeSpan leaseTimeout)
    {
        _connection = connection;
        _lockKey = lockKey;
        _watchdogCts = new CancellationTokenSource();

        // ⭐ Watchdog: chạy ngầm, sau leaseTimeout thì force-release
        _watchdogTask = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(leaseTimeout, _watchdogCts.Token);
                // ⭐ Hết giờ mà chưa bị cancel → force release
                await ForceReleaseAsync();
            }
            catch (OperationCanceledException)
            {
                // Happy path: dispose đã chạy, watchdog bị cancel → OK
            }
        });
    }

    public async ValueTask DisposeAsync()
    {
        // ⭐ Interlocked.CompareExchange: atomic guard — chỉ 1 thread vào unlock
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0)
            return;  // Thread khác đã dispose rồi

        // Cancel watchdog — nó chưa fire thì thôi
        await _watchdogCts.CancelAsync();

        try
        {
            await _connection.ExecuteAsync(
                "SELECT pg_advisory_unlock(@lockKey)",
                new { lockKey = _lockKey });
        }
        finally
        {
            await _connection.DisposeAsync();
        }
    }

    private async Task ForceReleaseAsync()
    {
        // ⭐ Force-release: chạy từ watchdog thread
        // Cờ disposed đảm bảo chỉ 1 thread vào unlock
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0)
            return;

        try
        {
            await _connection.ExecuteAsync(
                "SELECT pg_advisory_unlock(@lockKey)",
                new { lockKey = _lockKey });
        }
        finally
        {
            await _connection.DisposeAsync();
        }
    }
}
```

#### Tại sao dùng `int` + `Interlocked.CompareExchange` thay vì `bool`?

`bool _disposed` trong code hiện tại KHÔNG thread-safe:

```
Thread A (happy-path DisposeAsync):   Thread B (watchdog ForceReleaseAsync):
  if (_disposed) return;                if (_disposed) return;
  _disposed = true;                     _disposed = true;
  await connection.ExecuteAsync(...)    await connection.ExecuteAsync(...)
  // ⚠️ CẢ 2 CHẠY UNLOCK!              // ⚠️ ObjectDisposedException!
```

Với `bool`, read-write không atomic → 2 thread có thể cùng pass check → cùng gọi unlock → `ObjectDisposedException`.

`Interlocked.CompareExchange(ref _disposed, 1, 0)`:
- **Atomic**: đọc giá trị cũ, so sánh với 0, nếu bằng 0 thì ghi 1 — một lệnh CPU không thể bị interrupt
- **Chỉ 1 thread thắng**: thread nào thắng thì làm unlock; thread thua return ngay

#### Race: watchog đang fire, happy-path cũng chạy?

Kịch bản: happy-path dispose **trong lúc** watchdog đang await `ExecuteAsync`:

1. Watchdog thắng `CompareExchange` (`_disposed = 1`) → đang chạy `ExecuteAsync` unlock
2. Happy-path gọi `DisposeAsync()` → `CompareExchange` thấy `_disposed = 1` → return ngay
3. Không race: cờ atomic đã chặn

Kịch bản: cả 2 cùng vào `CompareExchange` **gần như đồng thời**:
- CPU guarantee chỉ 1 thread thắng write, thread còn lại nhận giá trị cũ ≠ 0 → return

## Race conditions — Tổng hợp đầy đủ

| Race | Happy-path dispose trước | Watchdog fire trước | Cả 2 cùng lúc |
|---|---|---|---|
| `_disposed` guard | happy-path thắng CompareExchange → watchdog Cancel bị exception → catch (OperationCanceledException) → im lặng | watchog thắng → happy-path CompareExchange fail → return | CPU decide 1 thằng thắng, thằng kia CompareExchange fail |
| Connection unlock | happy-path unlock sạch, connection disposed | watchdog unlock, connection disposed | Như cột bên trái — chỉ 1 thằng vào critical section |
| Hậu quả | Lock released 1 lần, OK | Lock released 1 lần, OK | Lock released 1 lần, OK |

## Dòng chảy (Flow)

```
CentralDbSyncJobs.RunBootstrapAsync
    │
    ├── using var cts = new CancellationTokenSource(10ph)          ← Layer 1
    │
    ├── bootstrapService.ExecuteAsync(config, requestId, cts.Token)
    │       │
    │       ├── await using var lockHandle = syncLock.TryAcquireAsync(ct)
    │       │       │
    │       │       ├── pg_try_advisory_lock → acquired
    │       │       │
    │       │       └── return AdvisoryLockHandle(connection, key)
    │       │               │
    │       │               ├── ⭐ Task.Run watchdog(10ph)          ← Layer 3
    │       │               │      └── Task.Delay(10ph, watchdogCts.Token)
    │       │               │
    │       │               └── dispose sẽ cancel watchdog + unlock
    │       │
    │       ├── ExecuteCoreAsync(config, runId, ...)
    │       │       │
    │       │       ├── reader.ReadAsync(config, ct)               ← ct có timeout
    │       │       │
    │       │       ├── [NẾU TREO Ở ĐÂY]
    │       │       │       ├── Quá 10ph → cts.Token cancel
    │       │       │       ├── reader.ReadAsync bắn OperationCanceledException
    │       │       │       ├── stack unwind → DisposeAsync → unlock
    │       │       │       └── (Layer 3 watchdog là dự phòng)
    │       │       │
    │       │       ├── applier.ApplyBootstrapAsync(config, snapshot, ct)
    │       │       └── runLog.WriteAsync(...)
    │       │
    │       └── return SyncRunResult
    │
    └── cts.Dispose()
```

## Tại sao Layer 3 app-only là đủ?

Một câu hỏi thường gặp: "Không có DB-side `statement_timeout` thì crash có sao không?"

**Crash path** đã native an toàn nhờ Postgres:

```
App crash → OS đóng TCP socket → Postgres backend process chết → session đóng → advisory lock auto-release
```

Đây là guarantee của PostgreSQL: session-level advisory lock tồn tại đến khi **session kết thúc**. Session kết thúc khi **connection đóng**. Crash đóng connection. Không cần app code, không cần watchdog.

Layer 3 chỉ cần cho **hang path** — nơi connection sống nhưng app không tiến triển.

## So sánh Layer 1 vs Layer 3

| Tiêu chí | Layer 1 (CancellationToken) | Layer 3 (Watchdog) |
|---|---|---|
| **Release lock** | Gián tiếp qua stack unwind → DisposeAsync | Trực tiếp gọi `pg_advisory_unlock` |
| **Release thread** | Ngay lập tức (exception unwind) | ❌ Thread không tự thoát |
| **Hoạt động khi code check ct** | ✅ | ✅ (dự phòng) |
| **Hoạt động khi blocking sync** | ❌ | ✅ |
| **Hoạt động khi infinite loop** | ❌ | ✅ |
| **Race condition** | Không có (single-thread unwind) | Cần Interlocked guard |
| **Log kết quả** | Log "Cancelled" với runId | Không log (watchdog là cứu hộ khẩn cấp) |

## Ví dụ hình dung

### Advisory lock forever-lock (hiện tại)

```
Bạn (app) vào phòng họp (advisory lock), đóng cửa, bắt đầu thuyết trình.
Đột nhiên bạn bị đứng hình (process treo) — mắt mở, tay giữ micro, nhưng không nói được.
Cửa phòng vẫn khóa (lock held). Không ai vào được.
Quản lý tòa nhà (PostgreSQL) chỉ kiểm tra: "cửa còn khóa không?" = có, "người còn sống không?"
Vì bạn còn đứng, tay còn cầm micro → quản lý kết luận "vẫn ổn."
Đồng nghiệp không thể vào phòng họp cho đến khi... bạn ngất xỉu (process crash).
```

### Layer 1 — Đồng hồ báo thức

```
Trước khi họp: bạn cài đồng hồ hẹn giờ 10 phút.
Bạn bị đứng hình → 10 phút sau đồng hồ reo.
Trợ lý (CancellationToken) chạy vào: "hết giờ!" → kéo bạn ra ngoài (exception unwind)
→ cửa tự động khóa lại (DisposeAsync → unlock).
```

### Layer 3 — Búa phá cửa

```
Cũng có đồng hồ. Nhưng nếu bạn đứng hình đến mức trợ lý cũng không kéo được
(blocking sync, infinite loop), thì đồng hồ không reo — nó kích hoạt búa phá cửa.
Búa đập cửa (watchdog force-release), cửa mở toang → người khác vào được.
Nhưng bạn vẫn đang đứng hình trong phòng — chỉ là cửa không còn khóa nữa.
```

## Bảng mapping source code

| File | Layer | Vai trò |
|---|---|---|
| `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs:68-89` | Layer 1 | `RunBootstrapAsync` — thêm `CancellationTokenSource(10ph)` |
| `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs:29-30` | Layer 1 | `RunAsync`/`RunPilotAsync` — thêm `CancellationTokenSource(5ph)` cho CT jobs |
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:56-84` | Layer 3 | `AdvisoryLockHandle` — thêm watchdog timer + Interlocked guard |
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:11-39` | Layer 1 | `TryAcquireAsync` — nhận `CancellationToken`, truyền xuống handle |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:30-31` | — | `await using` lock handle + `cancellationToken` — không đổi, nhận từ caller |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:30-31` | — | CT sync — tương tự, nhận token từ caller |
| `Application/Features/CentralDbSync/Abstractions/ITableSyncLock.cs:5-7` | — | Interface — không đổi |
| `WebApi/appsettings.json:40` | — | Connection string — không đổi (không DB-side timeout cho scope này) |

Layer 1 thay đổi ở **Hangfire job entry points** (`CentralDbSyncJobs.cs`), không cần sửa service layer. Layer 3 thay đổi ở **lock implementation** (`PostgresTableSyncLock.cs`), không cần sửa interface.

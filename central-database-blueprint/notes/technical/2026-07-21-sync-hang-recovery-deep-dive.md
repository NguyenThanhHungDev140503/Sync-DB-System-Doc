# Sync Hang Scenario: Deep Dive & Recovery Analysis

**Ngày:** 2026-07-21
**Module:** Central DB Sync Engine
**Mục tiêu:** Hiểu chính xác điều gì xảy ra khi một sync process bị treo (hang) giữa chừng — từ lock, checkpoint, đến recovery path.

---

## 1. Vấn đề là gì?

Central DB Sync dùng advisory lock để đảm bảo chỉ 1 worker xử lý 1 table tại 1 thời điểm. Nhưng lock là session-level, gắn với PostgreSQL connection — không có timeout ở application layer. Nếu process treo (không crash, không đóng connection), lock tồn tại vĩnh viễn. Vậy hệ thống phản ứng thế nào? Có tự phục hồi được không?

---

## 2. Nội dung chính — trace từng bước

### Bước 1: Cách lock được acquire — `pg_try_advisory_lock` (non-blocking)

Khác với `pg_advisory_lock` (blocking — chờ đến khi lấy được), hệ thống dùng `pg_try_advisory_lock`:

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:22-24
var acquired = await conn.ExecuteScalarAsync<bool>(
    "SELECT pg_try_advisory_lock(@lockKey)",
    new { lockKey });
```

Kết quả:
- Lock **đang rảnh** → `acquired = true` → trả về `AdvisoryLockHandle`
- Lock **đang bị giữ** → `acquired = false` → dispose connection, trả về `null` **ngay lập tức** (không chờ)

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:26-30
if (!acquired)
{
    await conn.DisposeAsync();
    return null;
}
```

Đây là khác biệt then chốt: nếu dùng blocking lock, toàn bộ pipeline sẽ đứng hình khi 1 table bị treo. Non-blocking cho phép scheduled job tiếp tục xử lý các table khác.

---

### Bước 2: Hai outcome "skip" — `skipped_locked` vs `skipped_dependency`

Đây là hai cơ chế hoàn toàn khác nhau, dễ nhầm:

#### `skipped_locked` — lock đang bị giữ bởi worker khác

Xảy ra trong `BootstrapSyncService` và `ChangeTrackingSyncService`:

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:30-53
await using var lockHandle = await syncLock.TryAcquireAsync(
    config.SourceTable, cancellationToken);

if (lockHandle is null)
{
    logger.LogDebug(  // ← Debug level, KHÔNG phải Warning
        "Bootstrap sync skipped for {SourceTable}: per-table lock not acquired",
        config.SourceTable);

    await runLog.WriteAsync(new SyncRunLogEntry
    {
        SourceTable = config.SourceTable,
        Mode = "Bootstrap",
        Outcome = SyncStatus.Outcome.SkippedLocked,  // ← "skipped_locked"
        StartedAt = startedAt,
        FinishedAt = DateTime.UtcNow,
        DurationMs = 0
    }, CancellationToken.None);

    return new SyncRunResult { Outcome = SyncStatus.Outcome.SkippedLocked };
}
```

- **Nguyên nhân:** Lock của chính bảng đó đang bị worker khác giữ
- **Log level:** Debug (đây là tình huống bình thường — retry cycle sau)
- **Outcome:** `skipped_locked`

#### `skipped_dependency` — bảng cha chưa sẵn sàng

Xảy ra trong `SyncOrchestrator`, **trước khi thử acquire lock**:

```csharp
// Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:40-59
if (!await AreDependenciesReadyAsync(config, cancellationToken))
{
    logger.LogWarning(  // ← Warning level, cần chú ý
        "Table {SourceTable} skipped: one or more dependencies are not Ready",
        config.SourceTable);

    await runLog.WriteAsync(new SyncRunLogEntry
    {
        SourceTable = config.SourceTable,
        Mode = "Orchestrator",
        Outcome = SyncStatus.Outcome.SkippedDependency,  // ← "skipped_dependency"
        ...
    }, CancellationToken.None);

    continue;  // ← KHÔNG throw, tiếp tục bảng tiếp theo
}
```

- **Nguyên nhân:** Checkpoint của bảng CHA chưa `ready` (có thể là `pending_initial_sync`, `requires_full_resync`, hoặc null)
- **Log level:** Warning (bảng con không chạy được là vấn đề cần theo dõi)
- **Lock của bảng con:** Chưa hề được thử acquire

---

### Bước 3: Advisory lock lifecycle — gắn với connection

Lock sống theo vòng đời của **NpgsqlConnection**, không phải transaction:

```csharp
// Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:56-84
private sealed class AdvisoryLockHandle : IAsyncDisposable
{
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;

        try
        {
            await _connection.ExecuteAsync(
                "SELECT pg_advisory_unlock(@lockKey)",
                new { lockKey = _lockKey });
        }
        finally
        {
            await _connection.DisposeAsync();  // ← dự phòng
        }
    }
}
```

Lock được release khi **một trong các sự kiện sau** xảy ra:

| Sự kiện | Cơ chế |
|---|---|
| `await using` scope kết thúc bình thường | `DisposeAsync()` → `pg_advisory_unlock` |
| Process crash | OS đóng TCP socket → PostgreSQL phát hiện → release lock |
| Process exit bình thường | Connection pool cleanup → `pg_advisory_unlock` |
| DBA kill session | `SELECT pg_terminate_backend(pid)` |
| PostgreSQL restart | Toàn bộ lock bị xóa |

**Sự kiện KHÔNG release lock:** Transaction COMMIT/ROLLBACK. Advisory lock là **session-level**, không phải transaction-level.

---

### Bước 4: Trace flow khi process treo — từng dòng code

**Giả định:** Bootstrap đang chạy cho `FABRIC_MASTER`, process treo sau khi acquire lock nhưng trước khi COMMIT (VD: network timeout khi đọc SQL Server).

#### Cycle 1: Process treo đang giữ lock

```
FABRIC_MASTER: lock ĐANG bị giữ, checkpoint = 'pending_initial_sync'
               (checkpoint chưa được update vì transaction chưa COMMIT)
```

#### Cycle 2: Scheduled job phút tiếp theo

**Cho `FABRIC_MASTER` (không có dependency):**

```csharp
// SyncOrchestrator.cs:40 — AreDependenciesReadyAsync
// Dependency = [] → return true (không bị chặn)

// SyncOrchestrator.cs:62 — Check checkpoint state
var checkpoint = await checkpointStore.GetAsync("FABRIC_MASTER", ct);
// checkpoint.SyncStatus = "pending_initial_sync"

// SyncOrchestrator.cs:65-67 — Quyết định sync path
if (checkpoint is null
    || checkpoint.SyncStatus == SyncStatus.CheckpointState.PendingInitialSync
    || checkpoint.SyncStatus == SyncStatus.CheckpointState.RequiresFullResync)
{
    result = await bootstrapService.ExecuteAsync(config, cancellationToken);
    //                                                                   ↑
    // ── VÀO ĐÂY (PendingInitialSync) ──▶ BootstrapSyncService ─────────┘
}
```

**Trong `BootstrapSyncService.ExecuteAsync`:**

```csharp
// BootstrapSyncService.cs:30
await using var lockHandle = await syncLock.TryAcquireAsync(
    "FABRIC_MASTER", cancellationToken);
// → lockHandle = null  (lock đang bị process treo giữ)

// BootstrapSyncService.cs:33-53
if (lockHandle is null)
{
    // Log: "Bootstrap sync skipped for FABRIC_MASTER: per-table lock not acquired"
    // Outcome: "skipped_locked"
    return new SyncRunResult { Outcome = SyncStatus.Outcome.SkippedLocked };
}
```

Kết quả: `FABRIC_MASTER` → `skipped_locked`, checkpoint không đổi.

**Cho `FABRIC_PRICE_MASTER` (dependency = `["FABRIC_MASTER"]`):**

```csharp
// SyncOrchestrator.cs:40 — AreDependenciesReadyAsync
foreach (var dep in config.Dependency)
{
    var depCheckpoint = await checkpointStore.GetAsync("FABRIC_MASTER", ct);
    // depCheckpoint.SyncStatus = "pending_initial_sync"

    if (depCheckpoint?.SyncStatus != SyncStatus.CheckpointState.Ready)
    {
        // "pending_initial_sync" != "ready" → TRUE
        return false;
    }
}
// → return false → skipped_dependency
```

Kết quả: `FABRIC_PRICE_MASTER` → `skipped_dependency`. Lock của bảng này **chưa hề được thử acquire**.

---

### Bước 5: Sau khi DBA kill connection — hệ thống có tự phục hồi?

DBA chạy `SELECT pg_terminate_backend(<pid>)` → connection đóng → advisory lock release.

**Cycle kế tiếp:**

1. **`FABRIC_MASTER`:**
   - Checkpoint vẫn `pending_initial_sync` (transaction đã ROLLBACK khi connection đóng)
   - Orchestrator route → BootstrapSyncService
   - Lock đã rảnh → acquire thành công
   - Bootstrap chạy lại từ đầu → thành công → checkpoint → `ready`

2. **`FABRIC_PRICE_MASTER`:**
   - `AreDependenciesReadyAsync` → `FABRIC_MASTER` đã `ready` → OK
   - Chạy bootstrap như bình thường

**Kết luận:** Với code hiện tại, hệ thống **CÓ tự phục hồi** sau khi lock được release thủ công. Lý do: checkpoint chưa được commit → transaction rollback → checkpoint vẫn là `pending_initial_sync` → orchestrator route đúng vào Bootstrap.

---

### Bước 6: Checkpoint state machine & orchestrator routing

```csharp
// Application/Features/CentralDbSync/Models/SyncStatus.cs:15-20
public static class CheckpointState
{
    public const string PendingInitialSync = "pending_initial_sync";
    public const string Ready = "ready";
    public const string RequiresFullResync = "requires_full_resync";
}
```

State machine hiện tại (chỉ 3 trạng thái):

```text
                    ┌─────────────────────────┐
                    │   pending_initial_sync   │ ← seed data ban đầu
                    └───────────┬─────────────┘
                                │
                    Bootstrap thành công
                                │
                                ▼
                    ┌─────────────────────────┐
                    │         ready            │ ← CT incremental chạy bình thường
                    └───────────┬─────────────┘
                                │
               CheckpointInvalidException
               (CT bị cleanup, version quá cũ)
                                │
                                ▼
                    ┌─────────────────────────┐
                    │   requires_full_resync   │ ← chờ bootstrap recovery
                    └─────────────────────────┘
```

Orchestrator routing:

```csharp
// Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:62-74
var checkpoint = await checkpointStore.GetAsync(config.SourceTable, cancellationToken);

SyncRunResult result;
if (checkpoint is null                              // chưa có row
    || checkpoint.SyncStatus == "pending_initial_sync"  // chưa sync lần đầu
    || checkpoint.SyncStatus == "requires_full_resync") // CT invalid, cần resync
{
    result = await bootstrapService.ExecuteAsync(config, cancellationToken);
    //     ── Bootstrap path ──
}
else
{
    result = await ctService.ExecuteAsync(config, cancellationToken);
    //     ── CT incremental path (chỉ khi status = "ready") ──
}
```

Route logic:
- `null` / `pending_initial_sync` / `requires_full_resync` → **Bootstrap**
- Mọi trạng thái khác (thực tế chỉ có `ready`) → **CT incremental**

---

### Bước 7: Auto-recovery duy nhất — `CheckpointInvalidException`

Chỉ có MỘT đường dẫn recovery tự động trong toàn bộ hệ thống, nằm trong `ChangeTrackingSyncService`:

```csharp
// Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:88-107
catch (CheckpointInvalidException)
{
    logger.LogWarning(
        "Checkpoint invalid for {SourceTable}: transitioning and running immediate bootstrap recovery",
        config.SourceTable);

    // Bước 1: Transition checkpoint → requires_full_resync
    await checkpointStore.TransitionToFullResyncAsync(
        config.SourceTable, "CheckpointInvalid",
        "CT checkpoint is below minimum valid version", cancellationToken);

    // Bước 2: Chạy bootstrap recovery NGAY LẬP TỨC
    //         dùng ExecuteWithProvidedLockAsync — GIỮ NGUYÊN lock handle
    return await bootstrapService.ExecuteWithProvidedLockAsync(
        config, Guid.NewGuid(), startedAt, cancellationToken);
}
```

Điểm quan trọng:
- Recovery chạy **trong cùng một lock handle** với CT sync
- Không release lock giữa transition và bootstrap (tránh worker khác steal lock)
- `ExecuteWithProvidedLockAsync` bỏ qua bước acquire lock — dùng lock đã có sẵn:

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:63-71
public async Task<SyncRunResult> ExecuteWithProvidedLockAsync(
    TableSyncConfig config, Guid runId, DateTime startedAt,
    CancellationToken cancellationToken = default)
{
    ValidateConfig(config);
    // KHÔNG acquire lock — caller đã acquire rồi
    return await ExecuteCoreAsync(config, runId, startedAt, cancellationToken);
}
```

---

### Bước 8: Rủi ro còn tồn tại — không có timeout cho lock

**Vấn đề:** Không có `CancellationToken` với timeout được truyền vào lock acquisition hoặc sync operation. Process treo → lock tồn tại vĩnh viễn.

```csharp
// Hiện tại — KHÔNG có timeout
await using var lockHandle = await syncLock.TryAcquireAsync(
    config.SourceTable, cancellationToken);
// cancellationToken không có timeout → nếu process treo SAU KHI acquire,
// lock không bao giờ tự release

// Đề xuất — thêm timeout
using var timeoutCts = new CancellationTokenSource(TimeSpan.FromMinutes(30));
using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
    timeoutCts.Token, cancellationToken);
await using var lockHandle = await syncLock.TryAcquireAsync(
    config.SourceTable, linkedCts.Token);
```

Một giải pháp khác: PostgreSQL server-side `idle_in_transaction_session_timeout` — tự động kill connection nếu idle quá N phút. Nhưng đây là config ở tầng database, không phải application layer.

---

## 3. Tổng quan luồng khi process treo

```text
Cycle N: Bootstrap bắt đầu
  │
  ├── TryAcquireAsync("FABRIC_MASTER") → OK ✓
  │
  ├── reader.ReadAsync() → đọc SQL Server...
  │       │
  │       └── ⚡ TREO (network timeout, deadlock, ...)
  │           Process không crash, không đóng connection
  │           └── Advisory lock VẪN được giữ
  │           └── Checkpoint VẪN là pending_initial_sync (chưa COMMIT)
  │
  ▼
═══════════════════════════════════════════════════════
Cycle N+1 (1 phút sau): Scheduled job chạy
  │
  ├── FABRIC_MASTER (dep = [])
  │     ├── AreDependenciesReadyAsync → true (không có dep)
  │     ├── Checkpoint = pending_initial_sync → Bootstrap path
  │     ├── TryAcquireAsync("FABRIC_MASTER") → null (lock bị giữ)
  │     ├── Log: "Bootstrap skipped: lock not acquired" (Debug)
  │     └── Outcome: skipped_locked → return
  │
  ├── FABRIC_PRICE_MASTER (dep = ["FABRIC_MASTER"])
  │     ├── AreDependenciesReadyAsync
  │     │     └── FABRIC_MASTER checkpoint = pending_initial_sync ≠ ready
  │     ├── Log: "skipped: one or more dependencies are not Ready" (Warning)
  │     └── Outcome: skipped_dependency → continue
  │
  └── Các bảng khác (không phụ thuộc FABRIC_MASTER) → chạy bình thường

═══════════════════════════════════════════════════════
DBA can thiệp: pg_terminate_backend(<pid>)
  └── Connection đóng → lock release → transaction ROLLBACK

Cycle N+2: Tự động phục hồi
  │
  ├── FABRIC_MASTER
  │     ├── Checkpoint = pending_initial_sync → Bootstrap path
  │     ├── TryAcquireAsync → OK (lock đã rảnh)
  │     └── Bootstrap chạy thành công → checkpoint = ready ✓
  │
  └── FABRIC_PRICE_MASTER
        ├── AreDependenciesReadyAsync → FABRIC_MASTER = ready → OK
        └── Chạy bình thường ✓
```

---

## 4. Ví dụ hình dung (Analogy)

### 🅿️ Bãi đỗ xe — mỗi table là một chỗ đỗ

| Thành phần sync | Tương tự bãi đỗ xe |
|---|---|
| **Advisory lock** | Thẻ giữ chỗ — ai cầm thẻ thì được đỗ |
| **pg_try_advisory_lock** | Nhìn chỗ đỗ: trống thì lấy thẻ vào ngay, có xe thì đi luôn (không chờ) |
| **pg_advisory_lock** | Đứng đợi đến khi xe kia đi (blocking) |
| **skipped_locked** | "Chỗ này có xe rồi, vòng sau quay lại" |
| **skipped_dependency** | "Xe tải chưa đến, xe con không dỡ hàng được → đợi" |
| **Checkpoint = ready** | Biển "ĐÃ DỠ HÀNG XONG" trước chỗ đỗ |
| **Process treo** | Xe tải đang dỡ giữa chừng thì tài xế... ngủ quên. Thẻ vẫn trong túi. |
| **DBA kill connection** | Bảo vệ gọi xe cẩu kéo xe tải đi → trả thẻ |
| **Tự phục hồi** | Xe tải mới đến, thấy biển "CHƯA DỠ" → dỡ lại từ đầu |
| **Timeout cho lock** | Đồng hồ bấm giờ: nếu dỡ quá 30 phút → tự động kéo xe đi |

---

## 5. Bảng mapping source code

| File | Vai trò |
|---|---|
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:11-39` | `TryAcquireAsync` — non-blocking lock via `pg_try_advisory_lock` |
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:56-84` | `AdvisoryLockHandle` — giải phóng lock khi dispose |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:20-86` | `ExecuteAsync` — duyệt tuần tự, kiểm tra dependency |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:62-74` | **Route logic**: quyết định Bootstrap hay CT path dựa vào checkpoint |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:88-108` | `AreDependenciesReadyAsync` — kiểm tra tất cả dep đã `ready` |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:30-55` | `skipped_locked` handling — lock không acquire được |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:55-71` | CT skip khi checkpoint không `ready` → `requires_full_resync` |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:88-107` | Auto-recovery — `CheckpointInvalidException` → transition + bootstrap |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:63-71` | `ExecuteWithProvidedLockAsync` — bootstrap dùng lại lock của CT |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:110-136` | Error handling — bootstrap fail KHÔNG đổi checkpoint |
| `Application/Features/CentralDbSync/Models/SyncStatus.cs:1-21` | Hằng số Outcome và CheckpointState |
| `Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:25-36` | `GetAsync` — đọc checkpoint |
| `Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:68-92` | `TransitionToFullResyncAsync` — chuyển trạng thái checkpoint |

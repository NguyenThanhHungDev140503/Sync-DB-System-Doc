# CT Checkpoint Invalid → Auto Recovery

**Ngày:** 2026-07-21  
**Module:** ChangeTrackingSyncService + BootstrapSyncService  
**Mục tiêu:** Hiểu toàn bộ flow khi CT sync phát hiện checkpoint quá cũ, cách hệ thống tự phục hồi mà không cần manual intervention, và cách child tables bị ảnh hưởng.

---

## Vấn đề là gì?

SQL Server Change Tracking có **retention period** giới hạn. Nếu sync engine ngừng chạy một thời gian dài (vd: 3 ngày, retention chỉ có 2 ngày), checkpoint hiện tại sẽ nằm dưới `CHANGE_TRACKING_MIN_VALID_VERSION` — tức là SQL Server đã xóa mất những thay đổi cũ, không thể đọc incremental được nữa.

Lúc này, CT sync KHÔNG thể tiếp tục từ checkpoint cũ. Cần chạy **full Bootstrap** để thiết lập lại baseline. Nhưng phải làm sao để:
- Phát hiện tình huống này tự động?
- Chuyển sang Bootstrap recovery mà không để worker khác xen vào?
- Đảm bảo child tables không chạy khi parent đang recovery?
- Tự retry nếu recovery thất bại?

---

## Bước 1: Phát hiện — SqlServerGenericReader ném CheckpointInvalidException

Khi đọc CT changes, reader kiểm tra checkpoint hiện tại có còn hợp lệ không:

```csharp
// Infrastructure/CentralDbSync/SqlServerGenericReader.cs:83-93
var minValid = await conn.ExecuteScalarAsync<long?>(
    $"SELECT CHANGE_TRACKING_MIN_VALID_VERSION(...)",
    transaction: tx);

if (minValid.HasValue && checkpoint < minValid.Value)
{
    logger.LogWarning(
        "Checkpoint {Checkpoint} is below minimum valid version {MinValid} for {SourceTable}",
        checkpoint, minValid.Value, config.SourceTable);
    throw new CheckpointInvalidException(config.SourceTable, checkpoint, minValid.Value);
}
```

`CHANGE_TRACKING_MIN_VALID_VERSION` trả về version thấp nhất mà SQL Server còn giữ. Nếu checkpoint của ta nhỏ hơn → những thay đổi giữa checkpoint và minValid đã bị xóa → không sync incremental được nữa → throw.

Exception được định nghĩa gọn trong một class riêng:

```csharp
// Application/Features/CentralDbSync/CheckpointInvalidException.cs:3-8
public sealed class CheckpointInvalidException(
    string sourceTable, long? currentCheckpoint, long minValidVersion)
    : InvalidOperationException(
        $"Checkpoint invalid for {sourceTable}: current={currentCheckpoint}, minValid={minValidVersion}")
```

---

## Bước 2: Catch + Transition — ChangeTrackingSyncService

Exception propagate từ reader lên CT service. Tại đây, thay vì fail, hệ thống **chủ động phục hồi**:

```csharp
// Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:88-107
catch (CheckpointInvalidException)
{
    logger.LogWarning(
        "Checkpoint invalid for {SourceTable}: transitioning and running immediate bootstrap recovery",
        config.SourceTable);

    // ① Transition checkpoint sang "requires_full_resync"
    await checkpointStore.TransitionToFullResyncAsync(
        config.SourceTable, "CheckpointInvalid",
        "CT checkpoint is below minimum valid version", cancellationToken);

    logger.LogInformation(
        "Running immediate bootstrap recovery for {SourceTable}", config.SourceTable);

    // ② Chạy Bootstrap recovery NGAY — không release lock
    return await bootstrapService.ExecuteWithProvidedLockAsync(
        config, Guid.NewGuid(), startedAt, cancellationToken);
}
```

### Bước 2a: TransitionToFullResyncAsync

Ghi `sync_status = 'requires_full_resync'` vào `sync_meta.checkpoint`. Đây là tín hiệu cho toàn hệ thống biết: "bảng này đang cần được sửa".

```sql
-- Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:76-91
UPDATE sync_meta.checkpoint
SET sync_status = 'requires_full_resync',
    last_attempt_at = NOW(),
    last_failure_at = NOW(),
    last_error_code = @errorCode,
    last_error_message = @errorMessage,
    consecutive_failure_count = consecutive_failure_count + 1
WHERE source_table = @sourceTable
```

### Bước 2b: ExecuteWithProvidedLockAsync — giữ lock xuyên suốt

Đây là điểm tinh tế nhất của flow. CT sync **đã acquire advisory lock từ trước**:

```csharp
// ChangeTrackingSyncService.cs:30-31
await using var lockHandle = await syncLock.TryAcquireAsync(
    config.SourceTable, cancellationToken);
```

Nếu gọi `bootstrapService.ExecuteAsync()` (hàm bình thường), nó sẽ thử acquire lock lại — nhưng lock đang được giữ → `TryAcquireAsync` trả về `null` → `skipped_locked`. Tệ hơn: nếu release lock rồi acquire lại, worker khác có thể **steal lock** trong khoảng hở đó.

`ExecuteWithProvidedLockAsync` bỏ qua bước acquire lock, chạy thẳng `ExecuteCoreAsync`:

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:63-71
public async Task<SyncRunResult> ExecuteWithProvidedLockAsync(
    TableSyncConfig config, Guid runId, DateTime startedAt, ...)
{
    // KHÔNG acquire lock — caller đã acquire rồi
    return await ExecuteCoreAsync(config, runId, startedAt, cancellationToken);
}
```

Toàn bộ flow CT detection → transition → recovery diễn ra trong **cùng một lock handle**, không có khoảng hở.

---

## Bước 3: Hai kết quả có thể xảy ra của recovery

### Recovery thành công

`BootstrapSyncService.ExecuteCoreAsync` chạy bình thường:
- Đọc snapshot từ SQL Server (SNAPSHOT transaction)
- Upsert vào PostgreSQL + deactivate orphans
- Set checkpoint: `last_sync_version = baseline`, `sync_status = 'ready'`

→ Checkpoint 🟢 `ready` → bảng đã sẵn sàng cho CT sync trở lại → child tables được phép chạy.

### Recovery thất bại

```csharp
// BootstrapSyncService.cs:118-135
catch (Exception ex)
{
    // Bootstrap errors must NOT modify the checkpoint
    await runLog.WriteAsync(CreateFailedEntry(...), CancellationToken.None);
    return new SyncRunResult { Outcome = Failed, ErrorCode = "BootstrapFailed", ... };
}
```

Checkpoint **không đổi** → vẫn là 🟡 `requires_full_resync`. Nếu dừng ở đây, bảng sẽ bị kẹt vĩnh viễn. Nhưng có **đường phục hồi thứ hai** (xem Bước 4).

---

## Bước 4: Đường phục hồi B — SyncOrchestrator

Đây là lớp bảo vệ thứ hai. Mỗi cycle (1 phút), `SyncOrchestrator` kiểm tra trạng thái checkpoint trước khi chọn sync path:

```csharp
// Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:62-69
if (checkpoint is null
    || checkpoint.SyncStatus == SyncStatus.CheckpointState.PendingInitialSync
    || checkpoint.SyncStatus == SyncStatus.CheckpointState.RequiresFullResync)
{
    result = await bootstrapService.ExecuteAsync(config, cancellationToken);
}
else
{
    result = await ctService.ExecuteAsync(config, cancellationToken);
}
```

`requires_full_resync` được xếp chung nhóm với `null` và `pending_initial_sync` — đều dẫn đến chạy **Bootstrap trực tiếp**. Không cần đi qua CT path để gặp `CheckpointInvalidException`.

Điều này có nghĩa: nếu recovery trong Bước 2 thất bại, checkpoint vẫn là 🟡, cycle sau Orchestrator thấy 🟡 và **tự động chạy Bootstrap lại**. Lặp cho đến khi thành công.

---

## Tổng quan luồng

```text
Cycle N: Scheduled job (Cron.Minutely)
│
├── Parent table: CT sync
│   ├── Acquire advisory lock ✅
│   ├── ReadBatchAsync(checkpoint=100)
│   │   └── CHANGE_TRACKING_MIN_VALID_VERSION = 500
│   │       └── checkpoint (100) < minValid (500) → THROW CheckpointInvalidException
│   │
│   ├── Catch CheckpointInvalidException:
│   │   ├── ① TransitionToFullResyncAsync("CheckpointInvalid")
│   │   │       → sync_status = 'requires_full_resync' 🟡
│   │   │
│   │   └── ② ExecuteWithProvidedLockAsync(config, runId, startedAt)
│   │           │  (giữ nguyên advisory lock — không release)
│   │           │
│   │           ├── ExecuteCoreAsync:
│   │           │   ├── Read ERP snapshot (baseline=520, 1500 rows)
│   │           │   ├── Upsert PostgreSQL
│   │           │   ├── Deactivate orphans
│   │           │   └── Set checkpoint: version=520, status='ready' 🟢
│   │           │
│   │           └── THÀNH CÔNG → return Succeeded
│   │
│   └── Release advisory lock
│
├── Child table: AreDependenciesReadyAsync()
│   ├── Check parent checkpoint → 🟡 (nếu recovery chưa xong)
│   │   └── → SKIPPED_DEPENDENCY → retry cycle sau
│   │
│   └── Check parent checkpoint → 🟢 (sau khi recovery thành công)
│       └── → OK → chạy sync bình thường ✅
│
│
│ NẾU RECOVERY THẤT BẠI:
│   └── checkpoint vẫn 🟡 requires_full_resync
│
▼
Cycle N+1: Scheduled job
│
├── Parent: Orchestrator.ExecuteAsync()
│   ├── Checkpoint.SyncStatus == RequiresFullResync 🟡
│   │   └── → chạy Bootstrap.ExecuteAsync() (có acquire lock mới)
│   │       ├── Thành công → 🟢
│   │       └── Thất bại → 🟡 → retry cycle N+2...
│   │
│   └── Lặp cho đến khi thành công
│
└── Child: vẫn SKIPPED_DEPENDENCY cho đến khi parent 🟢
```

---

## Ví dụ hình dung

### 🚑 Xe cứu thương và bệnh nhân

| Bước trong sync | Analogy |
|---|---|
| **CT sync** | Bác sĩ kiểm tra định kỳ bệnh nhân |
| **Checkpoint quá cũ** | Kết quả xét nghiệm cho thấy bệnh đã tiến triển nặng, không thể điều trị ngoại trú được nữa |
| **CheckpointInvalidException** | Bác sĩ kết luận: "Cần nhập viện gấp" |
| **TransitionToFullResyncAsync** | Y tá ghi vào hồ sơ: 🟡 "Đang cấp cứu" |
| **ExecuteWithProvidedLockAsync** | Bác sĩ **không rời bệnh nhân** — gọi xe cứu thương và đi cùng luôn, không giao bệnh nhân cho người khác |
| **Giữ lock** | Không ai khác được đụng vào bệnh nhân này trong lúc cấp cứu |
| **Recovery thành công** | Phẫu thuật thành công → hồ sơ chuyển 🟢 "Khỏe mạnh" |
| **Recovery thất bại** | Ca mổ thất bại → hồ sơ vẫn 🟡 → ngày mai bác sĩ trực khác đọc hồ sơ, thấy 🟡, tự động đưa vào phòng mổ lại |
| **SyncOrchestrator detect** 🟡 | Bác sĩ trực ca sau đọc hồ sơ: "À, bệnh nhân này vẫn đang 🟡, để tôi phẫu thuật tiếp" |
| **Child skipped_dependency** | Người nhà bệnh nhân (child table) không được vào thăm cho đến khi bệnh nhân 🟢 |
| **Không có timeout cho child** | Không có chuyện "đợi 30 phút không thấy thì tự vào" — thà không gặp còn hơn gặp trong tình trạng nguy kịch |

---

## Bảng mapping source code

| File | Vai trò |
|---|---|
| `Application/Features/CentralDbSync/CheckpointInvalidException.cs:1-9` | Exception class — báo hiệu checkpoint quá cũ |
| `Infrastructure/CentralDbSync/SqlServerGenericReader.cs:83-93` | Nơi throw — so sánh checkpoint với `CHANGE_TRACKING_MIN_VALID_VERSION` |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:88-107` | Catch + transition + gọi recovery |
| `Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:68-92` | TransitionToFullResyncAsync — UPDATE `sync_status = 'requires_full_resync'` |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:63-71` | ExecuteWithProvidedLockAsync — recovery không acquire lock mới |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:73-136` | ExecuteCoreAsync — logic bootstrap (read + upsert + checkpoint) |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:118-135` | Error handling — checkpoint KHÔNG đổi khi lỗi |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:62-74` | Orchestrator check 🟡 → chạy Bootstrap (đường phục hồi B) |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:88-108` | AreDependenciesReadyAsync — child bị block khi parent không 🟢 |
| `Application/Features/CentralDbSync/Models/SyncStatus.cs:15-20` | CheckpointState constants: Ready, PendingInitialSync, RequiresFullResync |
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs:7-84` | Advisory lock — session-level, ngăn worker khác xen vào |

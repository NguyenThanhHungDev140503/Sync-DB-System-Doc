# [Big Issue] Orchestrator `else` Catch-All Gây Infinite Loop Khi Checkpoint Unknown State

**Ngày:** 2026-07-21
**Tag:** Big Issue
**Mức độ:** Critical — có thể gây infinite loop, không recovery tự động được

---

## Tóm tắt

`SyncOrchestrator.ExecuteAsync` có nhánh `else` catch-all (dòng 71-74) mặc định gửi mọi checkpoint state lạ vào `ChangeTrackingSyncService`. Nếu checkpoint mang giá trị không nằm trong 3 trạng thái định nghĩa (`pending_initial_sync`, `ready`, `requires_full_resync`), flow tạo infinite loop:

1. Orchestrator thấy unknown state → route sang CT sync
2. CT sync thấy không phải `ready` → return `RequiresFullResync` outcome, **không transition checkpoint**
3. Checkpoint vẫn giữ unknown state → cycle sau lặp lại y hệt

Checkpoint `sync_status` là `TEXT` không có CHECK constraint ở database — bất kỳ giá trị nào cũng có thể tồn tại (do manual insert, partial write, future code, migration lỗi).

---

## Root Cause

### 1. Nhánh `else` catch-all ở Orchestrator

```csharp
// Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:71-74
else
{
    result = await ctService.ExecuteAsync(config, cancellationToken);
}
```

Logic hiện tại chỉ phân biệt 3 trường hợp:
- `null` → Bootstrap
- `pending_initial_sync` → Bootstrap
- `requires_full_resync` → Bootstrap
- **mọi thứ khác** → CT sync (nhánh `else`)

Không có guard cho unknown state, không có fallback cleanup, không có log warning cấp độ cao.

### 2. CT sync không transition checkpoint khi state không hợp lệ

```csharp
// Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:65-71
if (checkpoint.SyncStatus != SyncStatus.CheckpointState.Ready)
{
    logger.LogInformation(
        "CT sync skipped for {SourceTable}: checkpoint status is {Status} → requires_full_resync",
        config.SourceTable, checkpoint.SyncStatus);
    return new SyncRunResult { Outcome = SyncStatus.Outcome.RequiresFullResync };
}
```

CT chỉ return outcome, không gọi `TransitionToFullResyncAsync`. Checkpoint không đổi.

### 3. Database không có CHECK constraint

```sql
-- Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql:98
sync_status TEXT NOT NULL DEFAULT 'pending_initial_sync',
```

Không có CHECK constraint — DB chấp nhận mọi giá trị TEXT.

### 4. SyncGuard chỉ validate ở application layer, không phải database

`SyncGuard.AssertValidCheckpointStatus` (dòng 61-67) chỉ gọi được ở code path có guard — không bảo vệ khỏi dữ liệu xấu đã tồn tại trong DB.

---

## Infinite Loop Trace

```
Cycle N: Scheduled job (Cron.Minutely)
│
├── SyncOrchestrator.ExecuteAsync()
│   ├── Get checkpoint → sync_status = "???" (unknown)
│   ├── checkpoint is null?           → No
│   ├── checkpoint == PendingInitialSync? → No
│   ├── checkpoint == RequiresFullResync? → No
│   └── → else: gọi CT sync
│
├── ChangeTrackingSyncService.ExecuteAsync()
│   ├── checkpoint.SyncStatus != Ready? → Yes (unknown ≠ ready)
│   └── return RequiresFullResync outcome
│       ⚠️ KHÔNG transition checkpoint
│       ⚠️ Checkpoint vẫn là "???"
│
▼
Cycle N+1: LẶP LẠI Y HỆT → infinite loop
```

### Dừng infinite loop bằng cách nào?

| Cách | Mô tả |
|---|---|
| **Manual SQL fix** | `UPDATE sync_meta.checkpoint SET sync_status = 'requires_full_resync' WHERE source_table = 'Xxx'` |
| **Kill job** | Stop Hangfire server schedule |
| **Deploy fix** | Thêm guard ở Orchestrator + TransitionToFullResyncAsync ở CT |

Không có auto-recovery từ code.

---

## Impact Assessment

### Kịch bản kích hoạt

| Nguyên nhân | Khả năng |
|---|---|
| DBA hoặc script ghi nhầm giá trị vào `sync_status` | Thấp nhưng có thể xảy ra |
| Migration thêm state mới nhưng quên update Orchestrator | Trung bình |
| Partial write khi PostgreSQL crash giữa lúc UPDATE checkpoint | Rất thấp (TEXT field, atomic write) |
| Code tương lai ghi state mới không đồng bộ với SyncStatus.CheckpointState constants | Cao |

### Hậu quả

| Mức độ | Ảnh hưởng |
|---|---|
| **Table bị ảnh hưởng** | Table bị stuck vĩnh viễn, không sync được |
| **Child tables** | Bị `skipped_dependency` vì parent không bao giờ `ready` |
| **Phát hiện** | Chỉ có thể phát hiện qua sync log pattern (liên tục `RequiresFullResync` outcome) |
| **Recovery** | Cần DBA can thiệp thủ công UPDATE checkpoint |

---

## Proposed Solutions

### Solution 1: Fix Orchestrator else branch (Recommended — immediate)

Thêm guard ở nhánh `else`: check nếu state không phải `ready`, tự động transition sang `RequiresFullResync` và route sang Bootstrap.

```csharp
// SyncOrchestrator.cs — thay thế else hiện tại
if (checkpoint.SyncStatus == SyncStatus.CheckpointState.Ready)
{
    result = await ctService.ExecuteAsync(config, cancellationToken);
}
else
{
    // Unknown state hoặc state không mong đợi → cleanup + fallback Bootstrap
    logger.LogWarning(
        "Checkpoint for {SourceTable} has unexpected state '{Status}': transitioning to RequiresFullResync",
        config.SourceTable, checkpoint.SyncStatus);
    
    await checkpointStore.TransitionToFullResyncAsync(
        config.SourceTable, "UnexpectedCheckpointState",
        $"Checkpoint has unknown state '{checkpoint.SyncStatus}'", cancellationToken);
    
    result = await bootstrapService.ExecuteAsync(config, cancellationToken);
}
```

**Ưu điểm:** Fix root cause ngay tại điểm quyết định. State lạ được cleanup trước khi chạy sync.
**Nhược điểm:** Thay đổi logic routing — cần review kỹ.

### Solution 2: Fix CT sync trả checkpoint về trạng thái an toàn

Thêm transition trong CT sync khi phát hiện state không phải `Ready`:

```csharp
// ChangeTrackingSyncService.cs:65-71 — sửa thành:
if (checkpoint.SyncStatus != SyncStatus.CheckpointState.Ready)
{
    logger.LogWarning(
        "CT sync skipped for {SourceTable}: unexpected checkpoint status '{Status}' → transitioning to RequiresFullResync",
        config.SourceTable, checkpoint.SyncStatus);
    
    await checkpointStore.TransitionToFullResyncAsync(
        config.SourceTable, "UnexpectedCheckpointState",
        $"CT sync received checkpoint with status '{checkpoint.SyncStatus}'", cancellationToken);
    
    return new SyncRunResult { Outcome = SyncStatus.Outcome.RequiresFullResync };
}
```

**Ưu điểm:** Đơn giản, ít thay đổi. CT tự cleanup khi gặp state lạ.
**Nhược điểm:** Chỉ fix được khi CT được gọi — nếu có code path khác gọi Orchestrator thì vẫn lỗi.

### Solution 3: Database-level CHECK constraint (Defense in depth)

Thêm CHECK constraint để DB từ chối state không hợp lệ:

```sql
ALTER TABLE sync_meta.checkpoint
ADD CONSTRAINT chk_checkpoint_sync_status
CHECK (sync_status IN ('pending_initial_sync', 'ready', 'requires_full_resync'));
```

**Ưu điểm:** Ngăn chặn ở DB level — không thể insert/update state lạ.
**Nhược điểm:** Migration cần downtime hoặc careful handling. Không fix infinite loop cho dữ liệu đã tồn tại.

### Recommended Approach

1. **Ngay lập tức:** Solution 1 — Fix Orchestrator else branch + thêm warning log
2. **Kèm theo:** Solution 2 — CT sync cũng tự cleanup để defense in depth
3. **Sau đó:** Solution 3 — Thêm CHECK constraint ở DB

---

## Mã nguồn liên quan

| File | Dòng | Vai trò |
|---|---|---|
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs` | 62-74 | `ExecuteAsync` — routing logic với else catch-all |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs` | 65-71 | CT check `SyncStatus != Ready` → return outcome, không transition |
| `Application/Features/CentralDbSync/Models/SyncStatus.cs` | 15-20 | `CheckpointState` constants — chỉ có 3 giá trị |
| `Application/Features/CentralDbSync/Validation/SyncGuard.cs` | 18-23 | `ValidCheckpointStatuses` — validation set trùng với constants |
| `Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs` | 68-92 | `TransitionToFullResyncAsync` — hàm cleanup cần gọi |
| `Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql` | 98 | `sync_status TEXT NOT NULL` — không có CHECK constraint |

---

## Kết luận

Nhánh `else` catch-all ở `SyncOrchestrator.cs:71-74` là lỗ hổng thiết kế. Khi checkpoint mang bất kỳ state nào ngoài 3 giá trị định nghĩa, hệ thống rơi vào infinite loop không recovery tự động được. Cần fix theo defense in depth: sửa routing logic ở Orchestrator + thêm cleanup ở CT sync + thêm CHECK constraint ở database.

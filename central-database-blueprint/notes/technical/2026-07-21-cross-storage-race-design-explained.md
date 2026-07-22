# Cross-storage Race Design: Tại sao SubmitAsync và Hangfire worker chạy song song?

**Ngày:** 2026-07-21

---

## Vấn đề

Khi admin bấm `POST /bootstrap/CRM.Partners`, có 2 việc cần làm:

1. **Ghi nhận request** vào PostgreSQL (`sync_meta.bootstrap_request`)
2. **Enqueue job** vào Hangfire (SQL Server) — để chạy bootstrap trong background

Hai storage khác nhau, không thể dùng transaction chung. Làm sao đảm bảo không mất request, không duplicate job, và API trả về nhanh?

---

## Nếu cố gắng làm tuần tự

### Cách 1: INSERT → Enqueue → MarkQueued → Return

```text
[1] INSERT pending_enqueue  (PostgreSQL)
[2] ScheduleWatchdog        (Hangfire, SQL Server)
[3] EnqueueAsync            (Hangfire, SQL Server)
                            ← worker có thể claim job NGAY tại đây
[4] MarkQueuedAsync         (PostgreSQL) — fail nếu worker claim trước!
```

Vấn đề: worker claim job giữa bước 3 và 4 → MarkQueuedAsync UPDATE 0 rows. Race là **không thể tránh** vì Hangfire không có cơ chế "chờ tôi mark xong rồi hãy chạy".

### Cách 2: INSERT → MarkQueued → Enqueue → Return

```text
[1] INSERT pending_enqueue  (PostgreSQL)
[2] MarkQueuedAsync         (PostgreSQL) — status = queued
                            ← CRASH tại đây! Enqueue chưa chạy
[3] EnqueueAsync            (Hangfire) — không bao giờ đến
```

Vấn đề: crash giữa MarkQueued và Enqueue → request là `queued` nhưng **không có job nào trong Hangfire**. Còn tệ hơn race — vì recovery khó hơn.

### Cách 3: Dùng distributed transaction

Không khả thi vì:
- PostgreSQL và SQL Server khác instance
- Distributed transaction (2PC) chậm, không phải lúc nào cũng support
- Deadlock risk cao
- Không cần thiết cho use case này

---

## Giải pháp: Không đồng bộ, dùng Compare-and-Set

Thay vì cố làm 2 luồng chạy tuần tự, thiết kế chấp nhận song song và dùng **status filter trong SQL** làm guard:

```sql
-- MarkQueuedAsync (SubmitAsync)
UPDATE sync_meta.bootstrap_request
SET status = 'queued'
WHERE request_id = @Id
  AND status IN ('pending_enqueue', 'waiting_for_lock')
--       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
--       Chỉ UPDATE được nếu status còn ở trạng thái cho phép
```

```sql
-- TryMarkRunningAsync (Hangfire worker)
UPDATE sync_meta.bootstrap_request
SET status = 'running'
WHERE request_id = @Id
  AND status IN ('pending_enqueue', 'queued', 'waiting_for_lock')
--       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
--       Chấp nhận nhiều hơn — claim được cả từ pending_enqueue lẫn queued
```

Cả 2 đều là **optimistic lock**: UPDATE có WHERE condition. Nếu status đã thay đổi → UPDATE 0 rows → biết rằng mình đã thua cuộc đua.

---

## Flow diagram: 2 kịch bản

### Kịch bản A: SubmitAsync chạy trước (bình thường)

```text
SubmitAsync                              Hangfire Worker
    │                                         │
    ├── INSERT pending_enqueue                │
    ├── ScheduleWatchdog(45s)                 │
    ├── EnqueueAsync ───────────────────────► │
    │                                         ├── TryMarkRunningAsync
    │                                         │   UPDATE ... SET status = 'running'
    │                                         │   WHERE status IN ('pending_enq','queued','waiting')
    │                                         │   → OK! pending_enqueue → running
    │                                         │
    ├── MarkQueuedAsync                       │
    │   UPDATE ... SET status = 'queued'      │
    │   WHERE status IN ('pending_enq','waiting')
    │   → FAIL! status là 'running',          │
    │     không match WHERE condition         │
    │                                         │
    ├── log warning (harmless)                │
    └── return 202                            │
    │                                         ├── chạy bootstrap
    │                                         └── MarkCompletedAsync
    │
    ├── 45s sau: Watchdog fires
    │   → request.Status = running → no-op
    │
    ▼
 Kết quả: request = running, bootstrap đang chạy  ✓
```

### Kịch bản B: Worker chạy sau SubmitAsync (bình thường)

```text
SubmitAsync                              Hangfire Worker
    │                                         │
    ├── INSERT pending_enqueue                │
    ├── ScheduleWatchdog(45s)                 │
    ├── EnqueueAsync ───────────────────────► │
    ├── MarkQueuedAsync                       │
    │   UPDATE ... SET status = 'queued'      │
    │   → OK! pending_enqueue → queued        │
    │                                         ├── TryMarkRunningAsync
    │                                         │   UPDATE ... SET status = 'running'
    │                                         │   → OK! queued → running
    │                                         │
    └── return 202                            ├── chạy bootstrap
    │                                         └── MarkCompletedAsync
    │
    ├── 45s sau: Watchdog fires
    │   → request.Status = completed → no-op
    │
    ▼
 Kết quả: bình thường ✓
```

---

## Code

```csharp
// BootstrapRequestService.cs:45-65
try
{
    await scheduler.ScheduleWatchdogAsync(sourceTable, requestId, WatchdogDelay, ct);

    var hangfireJobId = await scheduler.EnqueueAsync(sourceTable, requestId, ct);

    var marked = await requestStore.MarkQueuedAsync(requestId, hangfireJobId, ct);
    if (!marked)
    {
        // ─── Race! Worker claim trước, MarkQueued fail ───
        // Không sao. Worker đã có request trong tay. Chỉ log warning.
        logger.LogWarning(
            "Failed to mark request {RequestId} as Queued — it may have been claimed by the job",
            requestId);
    }

    var updated = await requestStore.GetAsync(requestId, ct);
    return new BootstrapRequestResult(
        updated ?? result.Request with { Status = BootstrapRequestStatus.Queued, ... },
        true);
}
```

---

## Tổng kết

| Câu hỏi | Trả lời |
|---|---|
| **Tại sao 2 luồng?** | Vì PostgreSQL (request store) và Hangfire storage là 2 database khác nhau, không thể dùng 1 transaction |
| **Tại sao không chờ MarkQueuedAsync rồi mới Enqueue?** | Nếu crash giữa 2 bước → request `queued` nhưng không có job — khó recover hơn race |
| **Race có sao không?** | Không. Optimistic lock (WHERE status IN ...) đảm bảo ai UPDATE trước thì thắng, ai sau thì biết mình thua |
| **Ai chịu trách nhiệm cuối cùng?** | **Watchdog** (45s sau) kiểm tra lần cuối. Nếu request vẫn `pending_enqueue` → recover |
| **Nếu cả 2 đều fail?** | Exception → catch → MarkFailedAsync("BootstrapEnqueueFailed") → API báo lỗi |

## Analogy

Bạn order hàng trên Shopee (PostgreSQL) và chuyển khoản qua ngân hàng (Hangfire — SQL Server). Hai hệ thống riêng biệt:

```text
Bước 1: Tạo đơn hàng (INSERT pending_enqueue)
    ── PostgreSQL: đơn hàng với status = "chờ thanh toán"

Bước 2: Hẹn 45p kiểm tra (ScheduleWatchdog)
    ── Hangfire: sẽ kiểm tra đơn sau 45p

Bước 3: Gửi lệnh chuyển khoản (EnqueueAsync)
    ── Hangfire nhận lệnh, chuẩn bị chuyển

Bước 4: Ghi "đã gửi lệnh" (MarkQueuedAsync)
    ── PostgreSQL: UPDATE status = "đã gửi lệnh chuyển khoản"

--- CÙNG LÚC ---

Ngân hàng (Hangfire worker) xử lý lệnh chuyển khoản
    ── Nếu nhanh hơn bước 4:
        "Tài khoản đã được ghi nợ" (running)
        → bước 4 không UPDATE được nữa (vì status đã khác)
        → không sao, tiền đã chuyển rồi

    ── Nếu chậm hơn bước 4:
        "Đã gửi lệnh chuyển khoản" (queued)
        → ngân hàng đọc lệnh và xử lý
        → "Tài khoản đã được ghi nợ" (running)

--- 45 phút sau ---

Watchdog kiểm tra:
    ├── Nếu đơn vẫn "chờ thanh toán" → crash thật → chuyển khoản lại
    └── Nếu đơn đã "đã ghi nợ" → bỏ qua
```

## Bảng mapping source code

| File | Vai trò |
|---|---|
| `Application/.../BootstrapRequestService.cs:45-65` | `SubmitAsync` — enqueue + MarkQueued + xử lý race |
| `Infrastructure/.../PostgresBootstrapRequestStore.cs:125-140` | `MarkQueuedAsync` — UPDATE với filter `pending_enqueue`/`waiting_for_lock` |
| `Infrastructure/.../PostgresBootstrapRequestStore.cs:142-157` | `TryMarkRunningAsync` — UPDATE với filter `pending_enqueue`/`queued`/`waiting_for_lock` |
| `Infrastructure/.../HangfireBootstrapJobScheduler.cs:9-11` | `EnqueueAsync` — gửi job cho Hangfire worker |
| `Infrastructure/.../CentralDbSyncJobs.cs:68-134` | `RunBootstrapAsync` — worker gọi `TryMarkRunningAsync` rồi chạy bootstrap |

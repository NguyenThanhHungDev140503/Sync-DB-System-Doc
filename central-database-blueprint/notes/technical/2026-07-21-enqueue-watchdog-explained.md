# Enqueue Bootstrap + One-shot Watchdog — Giải thích cho người mới

**Ngày:** 2026-07-21

---

## Vấn đề

Khi admin bấm `POST /bootstrap/CRM.Partners`, app cần:

1. INSERT một work ticket (request) vào PostgreSQL — để API có status để trả về
2. Enqueue Hangfire job — để chạy bootstrap trong background
3. Nếu app crash giữa bước 1 và 2 → request đã có trong DB nhưng không ai chạy bootstrap cho nó

**Làm sao để recover request bị orphan mà không cần poll (chạy 5 phút 1 lần)?**

Giải pháp: **One-shot watchdog** — mỗi request tự động schedule một Hangfire job trễ 45 giây. Nếu submit thành công → watchdog no-op. Nếu crash → watchdog enqueue lại.

---

## Bước 1: INSERT pending_enqueue

Controller gọi `BootstrapRequestService.SubmitAsync`. Đầu tiên, tạo row trong PostgreSQL:

```csharp
// BootstrapRequestService.cs:33
var result = await requestStore.CreateOrGetActiveAsync(sourceTable, ct);
```

SQL bên trong:

```sql
-- PostgresBootstrapRequestStore.cs:48-59
INSERT INTO sync_meta.bootstrap_request
    (request_id, source_table, status, requested_at, updated_at)
VALUES
    (@RequestId, @SourceTable, 'pending_enqueue', NOW(), NOW())
ON CONFLICT (source_table) WHERE status IN ('pending_enqueue','queued','running','waiting_for_lock')
DO UPDATE SET updated_at = EXCLUDED.updated_at
RETURNING request_id
```

Giải thích:
- **INSERT** — tạo request mới với status = `pending_enqueue`
- **ON CONFLICT** — nếu đã có request active cho source_table đó → trả về row cũ
- **RETURNING request_id** — trả về ID thật trong DB, so sánh với ID đã generate để biết có phải row mới không

---

## Bước 2: Schedule watchdog

Ngay sau khi INSERT thành công, schedule một **one-shot watchdog job**:

```csharp
// BootstrapRequestService.cs:49
await scheduler.ScheduleWatchdogAsync(sourceTable, requestId, WatchdogDelay, ct);
```

`WatchdogDelay` = **45 giây** (BootstrapRequestService.cs:19).

```csharp
// HangfireBootstrapJobScheduler.cs:17-23
public Task ScheduleWatchdogAsync(string sourceTable, Guid requestId, TimeSpan delay, CancellationToken ct)
{
    client.Schedule<CentralDbSyncJobs>(
        job => job.ReconcileBootstrapRequestAsync(sourceTable, requestId),  // hàm watchdog
        delay);   // 45 giây
    return Task.CompletedTask;
}
```

Đây là một **scheduled Hangfire job thường** — sẽ chạy đúng 1 lần sau 45 giây.

---

## Bước 3: Enqueue bootstrap job

Sau đó enqueue job **thật** để chạy bootstrap:

```csharp
// BootstrapRequestService.cs:51
var hangfireJobId = await scheduler.EnqueueAsync(sourceTable, requestId, ct);
```

```csharp
// HangfireBootstrapJobScheduler.cs:9-11
public Task<string> EnqueueAsync(string sourceTable, Guid requestId, CancellationToken ct) =>
    Task.FromResult(client.Enqueue<CentralDbSyncJobs>(
        job => job.RunBootstrapAsync(sourceTable, requestId)));
```

Job này sẽ chạy **ngay lập tức** (hoặc sớm nhất có thể).

---

## Bước 4: Mark queued

Cập nhật status thành `queued`:

```csharp
// BootstrapRequestService.cs:53
var marked = await requestStore.MarkQueuedAsync(requestId, hangfireJobId, ct);
```

```sql
-- PostgresBootstrapRequestStore.cs:135
UPDATE sync_meta.bootstrap_request
SET status = 'queued',
    hangfire_job_id = @JobId,
    updated_at = NOW()
WHERE request_id = @RequestId
  AND status IN ('pending_enqueue', 'waiting_for_lock')
```

Sau bước này, request đã sẵn sàng. API trả về HTTP 202.

---

## Bước 5: Watchdog fires (45 giây sau)

Sau 45 giây kể từ lúc `ScheduleWatchdogAsync`, Hangfire gọi:

```csharp
// CentralDbSyncJobs.cs:142-148
public async Task ReconcileBootstrapRequestAsync(string sourceTable, Guid requestId)
{
    using var scope = _scopeFactory.CreateScope();
    var requestService = scope.ServiceProvider.GetRequiredService<BootstrapRequestService>();
    await requestService.ReconcileOneAsync(sourceTable, requestId, CancellationToken.None);
}
```

`ReconcileOneAsync` kiểm tra trạng thái hiện tại:

```csharp
// BootstrapRequestService.cs:94-110
public async Task ReconcileOneAsync(string sourceTable, Guid requestId, CancellationToken ct)
{
    var request = await requestStore.GetAsync(requestId, ct);
    if (request is null) return;  // request đã bị xoá

    if (request.Status != BootstrapRequestStatus.PendingEnqueue)
    {
        // Đã là queued/running/completed → submit thành công, không cần làm gì
        return;  // ← NO-OP
    }

    // Vẫn còn pending_enqueue → orphan detected!
    var hangfireJobId = await scheduler.ScheduleAsync(sourceTable, requestId, TimeSpan.Zero, ct);
    await requestStore.MarkQueuedAsync(requestId, hangfireJobId, ct);
    // log: "Watchdog reconciled orphan pending request"
}
```

---

## Flow diagram

### Luồng bình thường (không crash)

```text
POST /bootstrap/CRM.Partners
    │
    ├── [1] INSERT pending_enqueue
    │
    ├── [2] ScheduleWatchdogAsync(delay=45s)
    │   └── Hangfire: sẽ chạy ReconcileBootstrapRequestAsync sau 45s
    │
    ├── [3] EnqueueAsync → RunBootstrapAsync (chạy ngay)
    │
    ├── [4] MarkQueuedAsync → status = queued
    │
    └── Return HTTP 202

... 45 giây sau ...

Watchdog fires → ReconcileOneAsync
    └── request.Status = queued → no-op (không làm gì)
```

### Luồng crash

```text
POST /bootstrap/CRM.Partners
    │
    ├── [1] INSERT pending_enqueue     → OK
    ├── [2] ScheduleWatchdogAsync(45s) → OK
    │                                   ← CRASH !!!
    │  (EnqueueAsync chưa chạy)
    │
    │  === App restart ===
    │  Hangfire còn nhớ watchdog job cần chạy
    │
    └── Sau 45s: Watchdog fires
        └── request.Status = pending_enqueue (vẫn còn!)
            → orphan detected!
            → ScheduleAsync(delay=0) → enqueue bootstrap job
            → MarkQueuedAsync → status = queued
            → log: "Watchdog reconciled orphan pending request"
```

---

## Analogy

Bạn order hàng trên Shopee:

```text
Bước 1 — INSERT pending_enqueue:
    ── Bạn đặt hàng, hệ thống tạo đơn hàng (status = "chờ thanh toán")

Bước 2 — Schedule watchdog:
    ── Hệ thống hẹn 45 phút sau sẽ kiểm tra: "đơn này đã thanh toán chưa?"
       Nếu chưa → nhắc nhở. Nếu rồi → bỏ qua.

Bước 3 — Enqueue:
    ── Bạn chuyển khoản ngay (hoặc sau 2 phút)
    ── Status → "đã thanh toán, đang đóng gói"

Bước 4 — Mark queued:
    ── Hệ thống ghi nhận: "đã thanh toán xong"

--- 45 phút sau ---

Watchdog kiểm tra:
    ── Đơn đã "đang đóng gói" rồi → không cần nhắc nữa (no-op)

Trường hợp crash:
    ── Bạn đặt hàng, tạo đơn (pending), app ngân hàng crash
    ── 45 phút sau watchdog gọi: "đơn vẫn pending, tôi thanh toán giúp"
    ── Status → "đã thanh toán, đang đóng gói"
```

---

## So sánh: Watchdog vs Recurring Job (cách cũ)

| Tiêu chí | One-shot watchdog | Recurring job (5 phút) |
|---|---|---|
| **Cơ chế** | Schedule job trễ 45s mỗi request | Poll query mỗi 5 phút |
| **Recover time** | Tối đa 45 giây | Tối đa 5 phút |
| **Overhead khi không crash** | 1 no-op job (gần 0 cost) | Query PostgreSQL mỗi 5 phút |
| **Overhead khi nhiều request** | 1 watchdog / request | 1 query cho tất cả |
| **Recover sai request?** | Gắn với đúng request ID | Phải quét batch + so sánh cutoff |
| **Độ phức tạp** | Thấp | Trung bình |

---

## Bảng mapping source code

| File | Vai trò |
|---|---|
| `Application/.../BootstrapRequestService.cs:25-78` | `SubmitAsync` — 4 bước enqueue (watchdog → enqueue → mark) |
| `Application/.../BootstrapRequestService.cs:94-150` | `ReconcileOneAsync` — watchdog handler (no-op hoặc recover) |
| `Infrastructure/.../HangfireBootstrapJobScheduler.cs:17-23` | `ScheduleWatchdogAsync` — schedule Hangfire job trễ 45s |
| `Infrastructure/.../CentralDbSyncJobs.cs:142-148` | `ReconcileBootstrapRequestAsync` — Hangfire entry point cho watchdog |
| `Infrastructure/.../PostgresBootstrapRequestStore.cs:48-59` | `CreateOrGetActiveAsync` — INSERT + ON CONFLICT guard |
| `Infrastructure/.../PostgresBootstrapRequestStore.cs:128-142` | `MarkQueuedAsync` — UPDATE status = queued |
| `WebApi/Program.cs:127-129` | Xoá recurring job cũ, watchdog là one-shot |

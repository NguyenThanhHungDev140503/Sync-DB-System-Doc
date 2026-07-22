# [Big Issue] Advisory Lock không có Application-Level Timeout

**Ngày:** 2026-07-21
**Tag:** Big Issue
**Mức độ:** Critical — có thể gây deadlock toàn bộ hệ thống sync cho một table

---

## Tóm tắt

PostgreSQL advisory lock trong Central DB Sync hiện tại **không có timeout ở application layer**. Code chỉ acquire lock rồi giữ — không có `CancellationToken` với timeout, không có cơ chế tự động release sau N phút. Nếu process treo (không crash, không đóng connection), lock tồn tại vĩnh viễn cho đến khi có người vào kill session thủ công.

---

## Lock hiện tại được release khi nào?

### Các cơ chế release hiện có (tất cả đều là "happy path" hoặc "crash path")

| Sự kiện | Cơ chế | Độ tin cậy |
|---|---|---|
| **1. Normal completion** | `await using` scope end → `DisposeAsync()` → `pg_advisory_unlock()` + `connection.DisposeAsync()` | ✅ Nếu flow chạy bình thường |
| **2. Process crash** | Connection đóng → PostgreSQL tự release | ✅ Luôn hoạt động |
| **3. Process exit (graceful)** | `DisposeAsync` được gọi trong finally blocks | ✅ Nếu shutdown graceful |
| **4. DBA kill session** | `SELECT pg_terminate_backend(pid)` | ⚠️ Cần can thiệp thủ công |

### Không có các cơ chế sau

| Cơ chế | Trạng thái |
|---|---|
| **Application-level lock timeout** | ❌ Không có |
| **CancellationToken với timeout** | ❌ Không có (dùng `CancellationToken.None` ở một số chỗ) |
| **PostgreSQL `statement_timeout`** | ❌ Không được set |
| **PostgreSQL `idle_in_transaction_session_timeout`** | ❌ Không được set |
| **Npgsql `CommandTimeout`** | ❌ Không được set (dùng default = 30s của Npgsql, nhưng lock không phải là command chạy dài) |
| **Hangfire job timeout thực sự** | ⚠️ `DisableConcurrentExecution(timeoutInSeconds: 60)` chỉ ngăn chạy concurrent, không kill job đang treo |

---

## Lỗ hổng: Process treo → lock vĩnh viễn

### Kịch bản

```text
┌─────────────────────────────────────────────────────────────────┐
│ Hangfire job bắt đầu                                            │
│   │                                                             │
│   ├─ TryAcquireAsync("CRM.Partners") → acquired ✅              │
│   │                                                             │
│   ├─ ExecuteCoreAsync()                                         │
│   │   ├─ reader.ReadAsync() → đọc từ SQL Server                 │
│   │   │   └─ SQL Server query bị treo (deadlock, network hang)  │
│   │   │                                                        │
│   │   └─ ⚠️ PROCESS TREO TẠI ĐÂY                               │
│   │      • Connection vẫn mở (PostgresTableSyncLock giữ)        │
│   │      • await using lockHandle chưa kết thúc                 │
│   │      • Không crash, không đóng connection                    │
│   │      • Không timeout, không CancellationToken               │
│   │      • Hangfire cũng không kill job                          │
│   │                                                             │
│   └─ LOCK TỒN TẠI VĨNH VIỄN                                    │
│                                                                 │
│ Tất cả các job sau đó:                                          │
│   TryAcquireAsync("CRM.Partners") → false                       │
│   → SkippedLocked → retry 1 phút sau → SkippedLocked → ...     │
│   → TABLE CRM.PARTNERS NEVER SYNCS AGAIN                        │
└─────────────────────────────────────────────────────────────────┘
```

### Các nguyên nhân process có thể treo

1. **SQL Server query bị deadlock/hang** — `SqlServerGenericReader` chạy query SELECT, SQL Server có thể bị treo do lock escalation hoặc blocking từ transaction khác
2. **Network partition** — kết nối TCP giữa app server và SQL Server bị đứt nhưng kernel chưa phát hiện (TCP keepalive mặc định là 2 giờ trên Linux)
3. **ThreadPool starvation** — tất cả thread bị chiếm bởi các task khác, task sync không có thread để chạy tiếp
4. **GC pause** — gen2 GC pause kéo dài, lock connection không được phục vụ
5. **Infinite loop / deadlock trong code** — bug logic khiến code không bao giờ thoát khỏi `ExecuteCoreAsync`

---

## Root Cause: Thiếu 3 lớp bảo vệ

### Lớp 1: Application-level lock lease timeout (thiếu)

```csharp
// PostgresTableSyncLock.cs:11-39 — Hiện tại
public async Task<IAsyncDisposable?> TryAcquireAsync(
    string sourceTable,
    CancellationToken ct)  // ← ct chỉ dùng cho conn.OpenAsync, không phải lock timeout
{
    var conn = new NpgsqlConnection(connectionString);
    await conn.OpenAsync(ct);  // ← ct dùng ở đây

    var acquired = await conn.ExecuteScalarAsync<bool>(
        "SELECT pg_try_advisory_lock(@lockKey)",  // ← non-blocking, trả về ngay
        new { lockKey });

    if (!acquired) { await conn.DisposeAsync(); return null; }

    return new AdvisoryLockHandle(conn, lockKey);
    // ⚠️ Handle này không có expiry, không có heartbeat, không có watchdog
}
```

**Vấn đề:**
- `CancellationToken ct` chỉ được dùng cho `conn.OpenAsync(ct)` — mở connection
- Sau khi lock được acquire, không có cơ chế timeout nào để release
- `AdvisoryLockHandle` chỉ release khi `DisposeAsync()` được gọi explicitly

### Lớp 2: CancellationToken với timeout trên toàn bộ execution (thiếu)

```csharp
// CentralDbSyncJobs.cs:89 — Bootstrap job
var result = await bootstrapService.ExecuteAsync(config, requestId, CancellationToken.None);
//                                                                     ^^^^^^^^^^^^^^^^
//                                                                     KHÔNG BAO GIỜ timeout

// CentralDbSyncJobs.cs:29-30 — CT sync job
public async Task RunPilotAsync(CancellationToken cancellationToken)
    => await RunAsync(cancellationToken);
//     ^^ Hangfire cung cấp token, nhưng token này chỉ được cancel khi:
//        - App pool recycle (IIS)
//        - Hangfire server shutdown
//        - KHÔNG có timeout tự động từ Hangfire
```

### Lớp 3: PostgreSQL server-side session timeout (thiếu)

```text
Connection string hiện tại: "Host=...;Database=...;Username=...;Password=..."
                              ↑ Không có CommandTimeout
                              ↑ Không có OPTIONS=-c statement_timeout=...
                              ↑ Không set idle_in_transaction_session_timeout ở server level
```

**Tại sao cần server-side timeout:**
- Ngay cả khi application code có timeout, nếu application thread bị treo đến mức không thể chạy `CancellationToken.Cancel()`, server-side timeout là lớp bảo vệ cuối cùng
- PostgreSQL sẽ tự động kill connection → release lock

---

## Impact Assessment

### Mức độ ảnh hưởng

| Table bị lock | Hậu quả |
|---|---|
| **CRM.Partners** | Tất cả sync bị block → reporting data stale |
| **ERP.Configs.Units** | Config data không update → mobile app hiển thị data cũ |
| **ERP.Configs.Sizes** | Tương tự |

### Recovery hiện tại

Cách duy nhất để recovery lock stuck hiện nay:
1. Phát hiện: check `pg_locks` + `pg_stat_activity`
2. Kill session: `SELECT pg_terminate_backend(pid)`
3. **Yêu cầu DBA can thiệp thủ công**

Không có alert tự động, không có monitoring, không có auto-recovery.

### Trên production

Trên production, việc DBA phải vào kill session thủ công là:
- Tốn thời gian phát hiện (có thể vài giờ trước khi user report data cũ)
- Rủi ro kill nhầm session
- Không scalable nếu có nhiều table

---

## Proposed Solutions

### Solution 1: Lock lease với timeout (Application-level)

Thêm cơ chế lock lease: lock chỉ có hiệu lực trong N phút, sau đó tự động expire. Cần một background watchdog/ heartbeat để renew lease nếu job vẫn đang chạy bình thường.

```csharp
// Approach: Thay vì dùng pg_try_advisory_lock, dùng lock với expiry trong PostgreSQL
// Option A: Dùng transaction-level advisory lock (pg_advisory_xact_lock)
//          → auto release khi transaction COMMIT/ROLLBACK
//          → Nhưng cần thay đổi kiến trúc: lock và upsert phải cùng transaction

// Option B: Dùng application-level lease table
//          INSERT INTO sync_lock_lease (table_name, acquired_at, expires_at, lease_id)
//          → lease tự expire sau N phút
//          → Watchdog renew lease mỗi N/2 phút
```

**Trade-off Analysis:**

| Approach | Ưu điểm | Nhược điểm |
|---|---|---|
| **A: `pg_advisory_xact_lock`** | Auto release khi transaction kết thúc, đơn giản | Phải gộp lock + read + upsert vào 1 transaction → transaction dài → risk conflict |
| **B: Lease table** | Linh hoạt, có thể cấu hình TTL, watchdog-based | Phức tạp hơn, cần thêm bảng, cần heartbeat service |
| **C: `statement_timeout` connection-level** | Đơn giản nhất, set 1 lần | Chỉ timeout SQL execution, không bảo vệ khỏi treo ở application code |
| **D: `CancellationTokenSource(TimeSpan)`** | Wrap toàn bộ execution với timeout | Chỉ hoạt động nếu code thường xuyên check token |

### Solution 2: CancellationTokenSource với timeout (Short-term fix)

Đây là giải pháp nhanh nhất, có thể implement ngay:

```csharp
// CentralDbSyncJobs.cs — Bootstrap job
public async Task RunBootstrapAsync(string sourceTable, Guid requestId)
{
    using var scope = _scopeFactory.CreateScope();
    // ...
    
    // ⭐ Thêm timeout cho toàn bộ execution
    using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
    var result = await bootstrapService.ExecuteAsync(config, requestId, cts.Token);
    // ...
}
```

**Ưu điểm:** Dễ implement, ít thay đổi code
**Nhược điểm:** Chỉ hoạt động nếu code async thường xuyên check `CancellationToken` — các blocking call (SQL query synchronous, deadlock ở driver level) sẽ không bị ảnh hưởng

### Solution 3: PostgreSQL server-side timeout (Defense in depth)

Thêm vào connection string:

```text
Host=...;Database=...;Username=...;Password=...;CommandTimeout=300;OPTIONS='-c statement_timeout=600000'
```

Hoặc set ở server level:

```sql
ALTER DATABASE central_db SET statement_timeout = '10min';
ALTER DATABASE central_db SET idle_in_transaction_session_timeout = '15min';
```

**Lưu ý:** `statement_timeout` chỉ kill các query SQL đang chạy — không kill application process đang treo ngoài SQL.

### Solution 4: Monitoring + Alert (Operational)

Ít nhất cần có:

```sql
-- Query phát hiện lock stuck (giữ > N phút)
SELECT 
    l.pid,
    l.locktype,
    l.mode,
    a.state,
    a.query_start,
    now() - a.query_start AS duration,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.locktype = 'advisory'
  AND a.query_start < now() - INTERVAL '10 minutes'
  AND a.state = 'active';
```

- Có thể thêm vào health check endpoint
- Auto-alert qua Slack/email khi phát hiện lock stuck
- Optionally: auto-kill session nếu lock stuck quá 30 phút

### Recommended Approach: Defense in Depth

1. **Ngay lập tức:** Solution 2 — `CancellationTokenSource` với timeout 10 phút cho bootstrap jobs
2. **Ngắn hạn:** Solution 3 — Set `statement_timeout` và `idle_in_transaction_session_timeout` ở PostgreSQL server level
3. **Dài hạn:** Solution 1 (Option B) — Lease-based lock với heartbeat + Solution 4 — Monitoring & alert

---

## Mã nguồn liên quan

| File | Dòng | Vai trò |
|---|---|---|
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs` | 11-39 | `TryAcquireAsync` — không có timeout |
| `Infrastructure/CentralDbSync/PostgresTableSyncLock.cs` | 56-84 | `AdvisoryLockHandle` — chỉ release qua `DisposeAsync` |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs` | 30-31 | `await using lockHandle` — happy-path dispose |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs` | 30-31 | Tương tự cho CT sync |
| `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs` | 89 | `CancellationToken.None` — bootstrap job không có timeout |
| `Infrastructure/CentralDbSync/CentralDbSyncInfrastructureExtensions.cs` | 53-54 | DI registration — `PostgresTableSyncLock` là scoped |
| `Application/Features/CentralDbSync/Abstractions/ITableSyncLock.cs` | 5-7 | Interface — `CancellationToken` có sẵn nhưng không dùng cho timeout |

---

## Kết luận

Advisory lock là công cụ mạnh để ngăn concurrent sync, nhưng thiếu timeout ở application layer là một **lỗ hổng critical**. Khi process treo (không crash), lock không bao giờ được release, table bị lock vĩnh viễn, yêu cầu DBA can thiệp thủ công.

Cần ít nhất:
1. **Timeout ở application layer** — `CancellationTokenSource` với timeout cho mỗi job
2. **Timeout ở database layer** — `statement_timeout` + `idle_in_transaction_session_timeout`
3. **Monitoring + Alert** — phát hiện lock stuck và cảnh báo tự động

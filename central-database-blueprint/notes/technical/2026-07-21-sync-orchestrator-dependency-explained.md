# SyncOrchestrator: Dependency Handling & Error Recovery

**Ngày:** 2026-07-21
**Module:** Central DB Sync Engine
**Mục tiêu:** Hiểu cách SyncOrchestrator xử lý thứ tự sync giữa các bảng có quan hệ phụ thuộc, và cách nó phục hồi khi dependency bị lỗi hoặc treo.

---

## 1. Vấn đề là gì?

Khi đồng bộ dữ liệu từ ERP sang PostgreSQL Central DB, các bảng có quan hệ với nhau (VD: `fabric_price_master` cần `fabric_master` tồn tại trước để join). Nếu sync không theo thứ tự, app query join sẽ bị thiếu dữ liệu.

**Cách giải quyết của hệ thống:** Mỗi bảng khai báo danh sách dependency. SyncOrchestrator kiểm tra checkpoint của từng dependency trước khi cho phép sync bảng đó. Nếu dependency chưa sẵn sàng (chưa `ready`), bảng bị skip và retry ở cycle sau.

---

## 2. Nội dung chính — từng bước một

### Bước 1: Cấu hình dependency

Mỗi bảng sync có một `TableSyncConfig` chứa mảng `Dependency` — danh sách tên các bảng cha (theo `source_table` trong checkpoint) phải hoàn thành sync trước.

```csharp
// Application/Features/CentralDbSync/Models/TableSyncConfig.cs:10
public string[] Dependency { get; init; } = [];
```

**Ví dụ cấu hình thực tế:**

| Bảng | Dependency |
|------|-----------|
| `FABRIC_MASTER` | `[]` (không phụ thuộc ai) |
| `FABRIC_PRICE_MASTER` | `["FABRIC_MASTER"]` |
| `TRIM_PRICE_MASTER` | `[]` |
| `TRIM_RATING` | `["TRIM_PRICE_MASTER"]` |

Cấu hình này được khai báo trong `TableMappingRule` (mapping rule provider) và chuyển thành `TableSyncConfig` qua `ToTableSyncConfig()`:

```csharp
// Application/Features/CentralDbSync/Mapping/TableMappingRule.cs:12
public string[] Dependency { get; init; } = [];
```

---

### Bước 2: Scheduled job gọi SyncOrchestrator

Hangfire `Cron.Minutely()` gọi `CentralDbSyncJobs.RunAsync()` mỗi phút:

```csharp
// Infrastructure/CentralDbSync/CentralDbSyncJobs.cs:32
[DisableConcurrentExecution(timeoutInSeconds: 60)]
[AutomaticRetry(Attempts = 0)]  // We handle retry internally
public async Task RunAsync(CancellationToken cancellationToken)
{
    // ...
    var configs = ruleProvider
        .GetAll()
        .Where(rule => rule.Enabled)
        .Select(rule => rule.ToTableSyncConfig())
        .ToArray();

    await orchestrator.ExecuteAsync(enabled.ToArray(), cancellationToken);
}
```

Hai điểm quan trọng:
- `[AutomaticRetry(Attempts = 0)]` — Hangfire KHÔNG tự retry. Mọi retry đến từ scheduled job mỗi phút.
- `[DisableConcurrentExecution]` — Tránh 2 scheduled job chạy đè lên nhau.

---

### Bước 3: SyncOrchestrator duyệt tuần tự và kiểm tra dependency

```csharp
// Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:20
public async Task ExecuteAsync(
    TableSyncConfig[] configs,
    CancellationToken cancellationToken = default)
{
    foreach (var config in configs)
    {
        // ... validate config, check Enabled ...

        // Check all upstream dependencies are Ready before processing this table
        if (!await AreDependenciesReadyAsync(config, cancellationToken))
        {
            // Log warning + ghi sync_run_log với outcome = skipped_dependency
            // continue (KHÔNG throw exception)
            continue;
        }

        // ... run Bootstrap hoặc CT sync ...
    }
}
```

Logic: **Duyệt tuần tự**. Nếu dependency chưa ready → `skipped_dependency` → `continue` sang bảng tiếp theo.

---

### Bước 4: AreDependenciesReadyAsync — cơ chế kiểm tra

```csharp
// Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:88
private async Task<bool> AreDependenciesReadyAsync(
    TableSyncConfig config,
    CancellationToken cancellationToken)
{
    if (config.Dependency is null || config.Dependency.Length == 0)
        return true;  // Không có dependency → luôn được chạy

    foreach (var dep in config.Dependency)
    {
        var depCheckpoint = await checkpointStore.GetAsync(dep, cancellationToken);
        if (depCheckpoint?.SyncStatus != SyncStatus.CheckpointState.Ready)
        {
            logger.LogWarning(
                "Dependency {Dependency} for table {SourceTable} is not Ready (status: {Status})",
                dep, config.SourceTable, depCheckpoint?.SyncStatus ?? "null");
            return false;  // CHỈ CẦN 1 dependency chưa ready → return false
        }
    }

    return true;  // TẤT CẢ dependency đều ready
}
```

Điều kiện: **TẤT CẢ** dependency trong mảng phải có `SyncStatus == "ready"`. Chỉ cần 1 cái chưa ready (hoặc null — chưa từng sync) → return false.

Ví dụ minh họa:

| `fabric_master` status | `trim_price_master` status | `fabric_price_master` (deps: [FM, TPM]) được chạy? |
|---|---|---|
| `ready` | `ready` | ✅ OK |
| `ready` | `pending_initial_sync` | ❌ Skipped |
| `pending_initial_sync` | `ready` | ❌ Skipped |
| `null` (chưa có row) | `ready` | ❌ Skipped |
| `ready` | `requires_full_resync` | ❌ Skipped |

---

### Bước 5: Các trạng thái checkpoint và ảnh hưởng

```csharp
// Application/Features/CentralDbSync/Models/SyncStatus.cs:15
public static class CheckpointState
{
    public const string PendingInitialSync = "pending_initial_sync";
    public const string Ready = "ready";
    public const string RequiresFullResync = "requires_full_resync";
}
```

| Trạng thái checkpoint | Dependency check | Ý nghĩa |
|---|---|---|
| `null` (chưa có row) | ❌ Block | Bảng chưa từng được sync, chưa có checkpoint |
| `pending_initial_sync` | ❌ Block | Đã seed checkpoint nhưng chưa chạy bootstrap lần đầu |
| `ready` | ✅ Cho phép | Bootstrap đã thành công, dữ liệu đã sẵn sàng |
| `requires_full_resync` | ❌ Block | CT checkpoint bị invalid, đang chờ recovery |

---

### Bước 6: Cách checkpoint chuyển trạng thái

Checkpoint được quản lý bởi `PostgresSyncCheckpointStore`:

**Sau Bootstrap thành công → `ready`:**
```csharp
// Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:46
var affected = await conn.ExecuteAsync(
    @"UPDATE sync_meta.checkpoint
      SET last_sync_version = @nextCheckpoint,
          sync_status = @syncStatus,   -- "ready"
          last_success_at = NOW(),
          consecutive_failure_count = 0,
          ...
      WHERE source_table = @sourceTable
        AND last_sync_version = @previousCheckpoint",  -- optimistic guard
    ...);
```

**Khi CT checkpoint invalid → `requires_full_resync`:**
```csharp
// Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:76
await conn.ExecuteAsync(
    @"UPDATE sync_meta.checkpoint
      SET sync_status = @syncStatus,   -- "requires_full_resync"
          last_failure_at = NOW(),
          consecutive_failure_count = consecutive_failure_count + 1,
          ...
      WHERE source_table = @sourceTable",
    ...);
```

**Khi sync FAIL — checkpoint KHÔNG đổi:**
```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:118
catch (Exception ex)
{
    // Bootstrap errors must NOT modify the checkpoint — only the run log
    // and request status should reflect the failure. Operators can retry
    // from the same checkpoint.
    await runLog.WriteAsync(CreateFailedEntry(...), CancellationToken.None);
    return new SyncRunResult { Outcome = SyncStatus.Outcome.Failed, ... };
}
```

---

### Bước 7: Các kịch bản lỗi và cách phục hồi

#### 7a. Parent chưa từng sync

```
Cycle 1: fabric_master → chạy Bootstrap (mất 2 phút)
         fabric_price_master → check dep → fabric_master chưa ready → SKIPPED_DEPENDENCY
Cycle 2: fabric_master → đã ready → CT sync (no changes)
         fabric_price_master → check dep → fabric_master ready → chạy Bootstrap ✅
```

#### 7b. Parent Bootstrap bị lỗi

```
Cycle 1: fabric_master → Bootstrap FAIL (SQL Server timeout)
           → exception caught → log failed → checkpoint KHÔNG đổi
         fabric_price_master → check dep → fabric_master vẫn pending → SKIPPED_DEPENDENCY
Cycle 2: fabric_master → retry Bootstrap (cùng checkpoint) → thành công → checkpoint = ready
         fabric_price_master → check dep → ready → chạy ✅
```

#### 7c. Parent CT sync bị lỗi transient

```csharp
// Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:206
private async Task<SyncRunResult> ApplyWithRetryAsync(...)
{
    for (var attempt = 1; attempt <= MaxApplyRetries; attempt++)  // MaxApplyRetries = 3
    {
        try { return await applier.ApplyBatchAsync(config, batch, cancellationToken); }
        catch (Exception ex) when (attempt < MaxApplyRetries && IsTransient(ex))
        {
            // Transient (deadlock/timeout/connection) → retry với backoff
            await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt - 1)), cancellationToken);
        }
        catch (Exception ex) when (attempt == MaxApplyRetries && IsTransient(ex))
        {
            // Hết retry → Failed, checkpoint không đổi
            return new SyncRunResult { Outcome = "failed", ... };
        }
    }
}
```

Transient error được retry 3 lần với exponential backoff (1s → 2s → 4s). Nếu vẫn fail → `failed`, checkpoint không đổi → parent vẫn `ready` (CT sync fail không làm mất trạng thái ready) → child không bị ảnh hưởng.

#### 7d. Parent CT checkpoint invalid → tự động recovery

```csharp
// Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:88
catch (CheckpointInvalidException)
{
    // Transition atomically sang requires_full_resync
    await checkpointStore.TransitionToFullResyncAsync(...);

    // Chạy bootstrap recovery NGAY trong cùng lock
    // (không release lock — tránh worker khác steal)
    return await bootstrapService.ExecuteWithProvidedLockAsync(
        config, Guid.NewGuid(), startedAt, cancellationToken);
}
```

Điểm quan trọng: recovery chạy **trong cùng lock** với CT sync. Không release lock giữa transition và recovery → không worker nào khác có thể xen vào.

Trong thời gian recovery (vài giây đến vài phút), dependency check của child thấy `requires_full_resync` → `skipped_dependency`. Sau recovery thành công → `ready` → child chạy ở cycle sau.

#### 7e. Parent bị cancel (OperationCanceledException)

```csharp
// Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:110
catch (OperationCanceledException)
{
    logger.LogInformation("Bootstrap sync cancelled for {SourceTable}", config.SourceTable);
    await runLog.WriteAsync(CreateFailedEntry(...), CancellationToken.None);
    throw;  // RE-THROW
}
```

`throw` propagate lên `SyncOrchestrator.ExecuteAsync()` → thoát khỏi `foreach` loop. Các bảng phía sau (bao gồm child) **không được xử lý trong cycle này**. Cycle sau, tất cả được retry từ đầu.

#### 7f. Treo / hang (process bị kẹt)

Lock là session-level advisory lock trong PostgreSQL, giữ đến khi connection đóng hoặc process chết. KHÔNG có application-level timeout cho sync operation.

Nếu process treo:
- Advisory lock vẫn được giữ → scheduled job cycle sau `TryAcquireAsync` fail → `skipped_locked`
- Checkpoint không đổi → child vẫn thấy parent chưa `ready` → `skipped_dependency`
- Cần **manual intervention** (kill process, restart service)

---

### Bước 8: Retry cycle — cơ chế phục hồi tự động

```
Hangfire Cron.Minutely()
  │
  └─► CentralDbSyncJobs.RunAsync()           ← chạy mỗi phút
        │
        ├─► Lấy danh sách configs (theo thứ tự IMappingRuleProvider)
        │
        └─► SyncOrchestrator.ExecuteAsync(configs)
              │
              └─► foreach config:
                    ├─► AreDependenciesReadyAsync()
                    │     ├─► OK → chạy sync
                    │     └─► FAIL → skipped_dependency → log → continue
                    │
                    └─► (cycle kế tiếp: retry tất cả từ đầu)
```

Mỗi phút, **toàn bộ danh sách bảng** được duyệt lại từ đầu. Bảng bị skip ở cycle trước sẽ được thử lại. Không có cơ chế "nhớ" bảng nào bị skip — dependency check là stateless, chỉ dựa vào checkpoint hiện tại.

---

## 3. Tổng quan luồng (Flow diagram)

```text
┌─────────────────────────────────────────────────────────────────┐
│                   Hangfire Cron.Minutely()                      │
│                         mỗi 60 giây                              │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│              CentralDbSyncJobs.RunAsync()                        │
│  - Lấy configs từ IMappingRuleProvider (đã sắp xếp thứ tự)      │
│  - Lọc bỏ configs bị disabled                                   │
│  - Gọi orchestrator.ExecuteAsync(configs)                        │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│             SyncOrchestrator.ExecuteAsync()                      │
│                                                                  │
│  foreach (config in configs)                                     │
│  ┌──────────────────────────────────────────────────────┐       │
│  │ 1. Validate config                                    │       │
│  │ 2. Check Enabled                                      │       │
│  │ 3. AreDependenciesReadyAsync()                        │       │
│  │    ├── OK ──────────────────────────────────┐        │       │
│  │    │  4. Check checkpoint state             │        │       │
│  │    │     ├── null/pending → Bootstrap       │        │       │
│  │    │     └── ready → CT incremental         │        │       │
│  │    │                                         │        │       │
│  │    │  Bootstrap:                             │        │       │
│  │    │  ├── Acquire advisory lock              │        │       │
│  │    │  ├── Read ERP snapshot (SNAPSHOT tx)    │        │       │
│  │    │  ├── Apply to PG (upsert + deactivate)  │        │       │
│  │    │  ├── Set checkpoint = ready             │        │       │
│  │    │  └── Release lock                       │        │       │
│  │    │                                         │        │       │
│  │    │  CT incremental:                        │        │       │
│  │    │  ├── Acquire advisory lock              │        │       │
│  │    │  ├── Read CT changes since checkpoint   │        │       │
│  │    │  ├── Apply batch (retry 3x nếu transient)│       │       │
│  │    │  ├── Advance checkpoint (optimistic)    │        │       │
│  │    │  └── Release lock                       │        │       │
│  │    │                                         │        │       │
│  │    │  Error handling:                        │        │       │
│  │    │  ├── Transient → retry 3x backoff       │        │       │
│  │    │  ├── Non-transient → fail fast          │        │       │
│  │    │  ├── CT invalid → auto recovery         │        │       │
│  │    │  ├── Any failure → checkpoint unchanged │        │       │
│  │    │  └── Cancelled → re-throw               │        │       │
│  │    │                                         │        │       │
│  │    └── FAIL → skipped_dependency ────────────┘        │       │
│  │         ├── Log warning                                │       │
│  │         ├── Ghi sync_run_log                           │       │
│  │         └── continue (next config)                     │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                  │
│  → Cycle sau (1 phút): retry tất cả từ đầu                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Ví dụ hình dung (Analogy)

### 🏗️ Xây nhà — Đổ móng trước, xây tường sau

Hãy tưởng tượng SyncOrchestrator là một **đội trưởng công trường** xây nhà:

| Bước trong sync | Tương tự trong xây nhà |
|---|---|
| **Scheduled job mỗi phút** | Mỗi sáng, đội trưởng đi kiểm tra toàn bộ công trường |
| **TableSyncConfig** | Bản vẽ thi công — tường nhà ghi chú "phụ thuộc vào: móng" |
| **Checkpoint** | Biển báo trạng thái trước mỗi hạng mục: 🟢 "Đã xong" / 🔴 "Chưa làm" |
| **Dependency check** | Đội trưởng nhìn biển báo trước hạng mục cha. Nếu móng chưa 🟢 → không cho xây tường |
| **Bootstrap sync** | Đổ móng lần đầu — công việc nặng, mất nhiều thời gian |
| **CT incremental sync** | Bảo trì — chỉ sửa những chỗ bị nứt, không làm lại toàn bộ |
| **skipped_dependency** | "Móng chưa xong, tường đợi đi, mai kiểm tra lại" |
| **skipped_locked** | "Tổ khác đang đổ móng rồi, mình không vào tranh được" |
| **Retry sau 1 phút** | Sáng hôm sau, đội trưởng kiểm tra lại từ đầu |
| **Bootstrap fail → checkpoint không đổi** | Móng đổ bị lỗi → biển báo vẫn 🔴 "Chưa làm" → mai làm lại |
| **CT invalid → auto recovery** | Phát hiện móng bị nứt nặng → đập ra làm lại NGAY (không rời công trường) |
| **Treo/hang** | Máy trộn bê tông bị kẹt giữa chừng → công nhân đứng đợi → cần gọi thợ sửa (manual intervention) |

---

## 5. Bảng mapping source code

| File | Vai trò |
|---|---|
| `Application/Features/CentralDbSync/Models/TableSyncConfig.cs:1-15` | Khai báo cấu trúc config, bao gồm mảng `Dependency` |
| `Application/Features/CentralDbSync/Models/SyncStatus.cs:1-21` | Định nghĩa các hằng số Outcome và CheckpointState |
| `Application/Features/CentralDbSync/Mapping/TableMappingRule.cs:1-31` | Mapping rule → TableSyncConfig, kế thừa Dependency |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:1-109` | **Core logic** — duyệt tuần tự, check dependency, quyết định sync path |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:88-108` | `AreDependenciesReadyAsync()` — kiểm tra tất cả dependency đã ready chưa |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:1-162` | Bootstrap logic — acquire lock, read snapshot, apply, error handling |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:110-136` | Error handling trong bootstrap — checkpoint KHÔNG đổi khi lỗi |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:1-288` | CT incremental logic — read changes, retry, auto recovery |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:88-107` | CT checkpoint invalid → transition + immediate bootstrap recovery |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:206-260` | `ApplyWithRetryAsync()` — retry 3 lần với exponential backoff |
| `Infrastructure/CentralDbSync/PostgresSyncCheckpointStore.cs:1-93` | PostgreSQL implementation của checkpoint store — Advance, Transition |
| `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs:1-162` | Hangfire job entry points — scheduled sync + bootstrap request |
| `Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql:71-105` | Schema `sync_meta.table_sync_config` và `sync_meta.checkpoint` |
| `Infrastructure/Database/SqlScript/CentralDbSync/002-central-db-sync-seed.sql:1-27` | Seed data — đăng ký `CRM.Partners` với `dependency = '{}'` |
| `docs/central-database-blueprint/phase-1/specs/2026-07-18-central-db-sync-design.md:17-23` | Spec — "Registry chạy parent trước child để đảm bảo referential integrity" |

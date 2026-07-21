# Design: Central DB Sync Decisions

**Ngày:** 2026-07-18  
**Status:** Approved decisions — implementation plan pending  
**Phạm vi audit:**
- `docs/central-database-blueprint/phase-1/2026-07-18-Implementation-Idea.md`
- `docs/central-database-blueprint/phase-1/2026-07-18-Implementation-Plan.md`

## Mục tiêu

Chốt contract triển khai Phase 1 cho luồng một chiều ERP primary → PostgreSQL Central DB. Tài liệu này bổ sung các quyết định kiến trúc còn thiếu trong Idea và Plan; không thay thế mapping cụ thể từng bảng.

## 1. Scope và consistency model

Phase 1 đảm bảo **per-table eventual consistency**. Mỗi bảng hội tụ độc lập; không cam kết một ERP snapshot duy nhất xuyên toàn bộ 17 bảng vocabulary.

PostgreSQL vẫn giữ FK vật lý. Registry chạy parent trước child để đảm bảo referential integrity, nhưng thứ tự này không biến các bảng thành một atomic snapshot group.

Mỗi bảng phải có trạng thái và thời điểm sync thành công riêng. BI/report join nhiều bảng phải chấp nhận freshness khác nhau theo bảng.

Nếu parent trong dependency chain fail hoặc chưa `ready`, child phụ thuộc bị `skipped_dependency` trong cold cycle hiện tại và được retry ở cycle sau. Các bảng không phụ thuộc vẫn tiếp tục.

Phase 1 không dùng `ON DELETE CASCADE`. Mặc định lifecycle của vocabulary row là soft-deactivate; hard-delete chỉ được dùng khi business rule xác nhận và phải thực hiện child-first trong dependency group có ownership đầy đủ.

## 2. Per-table concurrency ownership

Mọi logical operation trên cùng source table phải dùng một lock phân tán chung:

```text
central-db-sync:{source_table}
```

Cơ chế: PostgreSQL session-level advisory lock, bọc qua `ITableSyncLock`.

Lock bao trùm toàn bộ operation:

```text
acquire lock
  read checkpoint/state
  read ERP snapshot hoặc CT batch
  apply PostgreSQL changes
  commit checkpoint/state
release lock
```

Lock dùng chung cho recurring job, bootstrap endpoint, sync-once/manual trigger và CT-invalid recovery. Không cần global lock cho toàn bộ tier.

Không lấy được lock:

- Scheduled job ghi `skipped_locked`, log Debug, không advance checkpoint.
- Manual bootstrap trả HTTP `409 Conflict`.
- Recovery giữ state hiện tại và thử lại cycle sau.

## 3. Bootstrap và CT-invalid recovery

Bootstrap và recovery dùng cùng một source contract:

```csharp
public sealed record BootstrapSnapshot(
    long BaselineVersion,
    IReadOnlyList<SourceRow> Rows);

public interface IBootstrapSnapshotReader
{
    Task<BootstrapSnapshot> ReadAsync(
        TableSyncConfig config,
        CancellationToken cancellationToken);
}
```

Source boundary bắt buộc:

```text
1. Acquire per-table lock.
2. Mở một SqlConnection tới ERP primary.
3. SET TRANSACTION ISOLATION LEVEL SNAPSHOT.
4. BEGIN TRANSACTION.
5. Capture baseline = CHANGE_TRACKING_CURRENT_VERSION().
6. Đọc complete full snapshot theo config/filter.
7. COMMIT source transaction.
8. Mở PostgreSQL transaction.
9. Upsert snapshot và scoped orphan lifecycle action.
10. Set checkpoint = baseline, sync_status = ready.
11. COMMIT PostgreSQL transaction.
12. Release lock.
```

`BaselineVersion` và full snapshot phải được lấy trên cùng SQL Server connection và cùng `SNAPSHOT` transaction. Không tách hai read operations sang connection/transaction khác.

Khi checkpoint CT invalid, transition atomically sang `requires_full_resync`, sau đó chạy đúng flow trên. Không lấy `CHANGE_TRACKING_CURRENT_VERSION()` ở cuối full-copy để ghi checkpoint.

## 4. FullRefresh completeness (Phase B scope)

<div class="callout"><b>⚠ Thực trạng Phase A Pilot:</b> FullRefresh strategy chưa được implement. Phase A chỉ implement <b>Bootstrap</b> (một lần, có CT baseline) và <b>CT incremental</b>. <code>IFullRefreshReader</code> được đăng ký DI và implement bởi <code>SqlServerPartnersReader</code>, nhưng chưa có service nào consume nó. <code>TableSyncConfig.SyncMode</code> default = <code>"FullRefresh"</code> nhưng không được đọc trong code.</div>

### Phân biệt Bootstrap vs FullRefresh

| | Bootstrap | FullRefresh (tương lai) |
|---|---|---|
| Mục đích | Seed CT baseline lần đầu | Sync định kỳ cho bảng không có CT |
| CT version | Có — capture baseline + set checkpoint | Không — không dùng CT |
| Orphan deactivate | Soft-deactivate rows không trong snapshot | Soft-deactivate rows không trong snapshot |
| Dùng khi nào | checkpoint = null / pending / requires_full_resync | SyncMode = FullRefresh (tables không CT, Phase B) |
| Implemented? | ✅ Phần A | ⏳ Phase B |

FullRefresh (sau này) chỉ áp dụng target sau khi source read hoàn tất toàn bộ:

```csharp
public sealed record FullSnapshot(
    IReadOnlyList<SourceRow> Rows);

public interface IFullRefreshReader
{
    Task<FullSnapshot> ReadCompleteAsync(
        TableSyncConfig config,
        CancellationToken cancellationToken);
}
```

`ReadCompleteAsync` chỉ trả kết quả sau khi:

- đọc đến EOF hoặc tất cả page/chunk thành công;
- mapper đã xử lý toàn bộ rows;
- PK hợp lệ;
- filter, aggregate và dedup đã hoàn tất;
- request chưa bị cancellation.

Nếu source read/map/cancel lỗi, target và checkpoint không đổi.

Khi implement Phase B, materialized complete snapshot trong memory trước PostgreSQL write transaction. Đo số rows/payload để xác nhận fit memory. Nếu không fit memory, chuyển sang staging table theo `run_id`: source stream vào staging, chỉ merge target + lifecycle action sau khi staging complete.

## 5. Filter và row lifecycle

Pilot `CRM.Partners` đọc toàn bộ source rows. Không dùng SQL `WHERE IsCustomer = 1` làm ranh giới duy nhất cho Bootstrap snapshot. Strategy áp dụng filter sau khi đã có current source state.

Unified lifecycle contract:

```text
Source row exists và IsCustomer = 1
  => target upsert, is_active = true.

Source row exists và IsCustomer = 0
  => target is_active = false.

Source row deleted
  => target is_active = false.

Source row absent from complete snapshot (Bootstrap / FullRefresh)
  => target is_active = false.
```

CT reader vẫn phải join current source row:

```text
D                       => deactivate theo PK.
I/U, current filter true => upsert active.
I/U, current filter false => deactivate theo PK.
```

Lifecycle action chỉ chạm rows thuộc đúng source/config ownership scope. BI query active data phải filter `is_active = true`.

## 6. CT batch atomicity và retry

CT reader chụp `UpperWatermark` trước khi enumerate changes trong SQL Server `SNAPSHOT` transaction. Chỉ đọc `SYS_CHANGE_VERSION <= UpperWatermark`.

```csharp
public sealed record ChangeBatch(
    long PreviousCheckpoint,
    long UpperWatermark,
    IReadOnlyList<ChangedRow> Rows);
```

`ISyncBatchApplier` phải thực hiện một PostgreSQL transaction duy nhất:

```text
deactivate/delete CT D rows
upsert CT I/U rows
update checkpoint tới UpperWatermark bằng optimistic guard
commit
```

Upsert theo đủ PK dùng `INSERT ... ON CONFLICT DO UPDATE`. Deactivate/delete theo đủ PK phải idempotent. Checkpoint chỉ advance khi target transaction commit thành công.

Retry:

- Transient PostgreSQL failure: retry cùng `ChangeBatch` và cùng `UpperWatermark`, tối đa 3 attempts.
- Sau attempts thất bại: checkpoint không đổi; scheduled cycle sau đọc lại từ checkpoint cũ.
- Non-transient failure, gồm mapping/constraint failure: fail nhanh, không retry cùng input.
- Exception classification dùng PostgreSQL SQLSTATE; deadlock/timeout/connection interruption thuộc transient category.

## 7. Scheduler và multi-instance behavior

Pilot hot CT job dùng `Cron.Minutely()`. Không dùng cron seconds, Hangfire.Pro, hoặc extra cron parser trong Phase 1.

`data-sync` queue tách khỏi `report-render`. `[DisableConcurrentExecution]` chỉ là guard job-level bổ sung; correctness phụ thuộc `ITableSyncLock` per-table.

Nhiều WebApi/Hangfire instances được giả định có thể tồn tại. Mọi instance phải dùng cùng Central DB advisory lock, nên duplicate schedule attempt trở thành `skipped_locked`, không tạo concurrent table sync.

## 8. Observability và health

`sync_meta.sync_run_log` là bắt buộc. Không dùng `success BOOLEAN`; dùng `outcome`:

```text
succeeded
no_changes
failed
skipped_locked
skipped_dependency
requires_full_resync
```

Mỗi run có `run_id` dùng chung cho Hangfire context, Serilog structured log và `sync_run_log`.

Schema log tối thiểu:

```text
source_table, run_id, mode, outcome,
rows_read, rows_upserted, rows_deactivated, rows_deleted,
checkpoint_before, checkpoint_after,
started_at, finished_at, duration_ms,
error_code, error_message
```

`sync_meta.checkpoint` lưu thêm:

```text
last_attempt_at
last_success_at
last_failure_at
consecutive_failure_count
last_error_code
last_error_message
```

`TableSyncConfig` có `ExpectedSyncInterval` và `MaxAllowedLag`. Health model:

```text
Healthy  = last success trong MaxAllowedLag, zero consecutive failures, ready.
Degraded = stale, repeated failure, hoặc requires_full_resync.
Unknown  = pending_initial_sync.
```

Log level:

```text
succeeded          Information
no_changes         Debug
skipped_locked     Debug
skipped_dependency Warning
requires_full_resync Warning
failed             Error
```

Không ghi source payload, PII, credentials, connection string hoặc full SQL vào information/error logs.

## 9. Security và access control

SQL Server ERP login chỉ có `SELECT` trên source tables/cột cần sync và `VIEW CHANGE TRACKING` trên CT tables. DBA review/bật `ALLOW_SNAPSHOT_ISOLATION` trước production.

PostgreSQL dùng dedicated sync user:

- `USAGE` trên `report` và `sync_meta` schemas;
- chỉ DML cần thiết trên bảng target và sync metadata;
- không superuser, không quyền DDL;
- migration/schema scripts chạy bằng principal tách biệt.

`CentralDbConnection` bind qua `AppDatabaseSettings`; secrets không commit vào Git hoặc log.

Bootstrap endpoint bắt buộc `[Authorize(Roles = "Admin")]`. Hangfire dashboard dev/UAT có thể mở theo môi trường; production bắt buộc auth bằng reverse proxy hoặc authorization middleware.

## 10. Acceptance criteria

Phase 1 implementation phải chứng minh:

1. Concurrent bootstrap, recovery, recurring và manual execution cùng table không chạy đồng thời.
2. Bootstrap/recovery checkpoint không vượt source snapshot boundary.
3. Source read lỗi/cancel trước completion không đổi target/checkpoint.
4. CT batch failure rollback data lifecycle action và checkpoint cùng nhau.
5. Retry cùng batch không duplicate hoặc skip change.
6. Partner `IsCustomer: true → false` làm target inactive, không stale active row.
7. Parent failure làm child dependent skip rõ ràng; PostgreSQL FK vẫn hợp lệ.
8. Multi-instance schedule attempt chỉ tạo một table run; các attempt khác `skipped_locked`.
9. Operator xác định được stale/failure/dependency block từ metadata và run log mà không đọc raw application logs.
10. Sync login và Central DB login không có quyền rộng hơn nhu cầu runtime.

## Ngoài phạm vi

- Single point-in-time ERP snapshot cho toàn bộ 17 vocabulary tables.
- Sub-minute hot sync.
- Streaming trực tiếp vào target cho snapshot lớn.
- `ON DELETE CASCADE` mặc định.
- Tự động chạy DDL/migration bằng runtime sync account.

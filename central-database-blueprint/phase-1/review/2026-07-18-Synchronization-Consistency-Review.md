# Review: Tính nhất quán dữ liệu của Phase 1 ERP → PostgreSQL Sync
**Ngày:** 2026-07-18
**Phạm vi:** Rà soát toàn bộ Markdown trong `docs/central-database-blueprint/phase-1/`.
**Tài liệu đã rà soát:**
- `2026-07-17-Section5.3-Table-List.md`
- `2026-07-18-Implementation-Idea.md`
- `2026-07-18-Implementation-Plan.md`

## Kết luận
`2026-07-18-Implementation-Plan.md` chưa nên được implement nguyên trạng. Có các lỗi mức Critical/High liên quan đến Change Tracking (CT) checkpoint và full-refresh recovery: hệ thống có thể bỏ sót thay đổi concurrent hoặc rơi vào trạng thái dữ liệu đích và checkpoint không khớp.

Cần áp dụng một pattern thống nhất cho tất cả bảng dùng CT:
1. Khóa xử lý theo từng bảng.
2. Đọc và validate checkpoint.
3. Chụp `upperWatermark = CHANGE_TRACKING_CURRENT_VERSION()` trước khi enumerate CT.
4. Đọc CT rows chỉ đến watermark đó trong SQL Server snapshot transaction.
5. Apply delete/upsert và advance checkpoint trong cùng một PostgreSQL transaction.
6. Retry theo semantics at-least-once với thao tác ghi idempotent.

## Quy tắc checkpoint bắt buộc
Checkpoint của một bảng chỉ được đặt thành version `V` khi PostgreSQL đã áp dụng thành công tất cả thay đổi CT có `SYS_CHANGE_VERSION <= V`.

Không dùng `CHANGE_TRACKING_CURRENT_VERSION()` ở cuối lượt sync để update checkpoint. Giá trị đó có thể bao gồm thay đổi xảy ra sau khi CT batch đã được đọc và dẫn tới bỏ sót vĩnh viễn ở lượt sau.

## Finding 1 — Critical: Checkpoint CT có thể bỏ sót thay đổi concurrent
**Vị trí:** `2026-07-18-Implementation-Plan.md:401`

Tài liệu mô tả flow đọc CT, ghi PostgreSQL, sau đó cập nhật checkpoint theo current version tại cuối job.

### Kịch bản lỗi
1. Checkpoint hiện tại là `100`.
2. Job query CT từ version `100`, đọc được các thay đổi đến `110`.
3. Một transaction ERP khác commit thay đổi version `111` khi job đang upsert.
4. Job gọi `CHANGE_TRACKING_CURRENT_VERSION()` ở cuối và nhận `111`.
5. Job lưu checkpoint `111`, dù thay đổi `111` không thuộc batch đã đọc.
6. Lượt kế tiếp `CHANGETABLE(CHANGES ..., 111)` chỉ trả version lớn hơn `111`.

Thay đổi version `111` bị bỏ qua vĩnh viễn.

### Giải pháp
- Chụp `upperWatermark = CHANGE_TRACKING_CURRENT_VERSION()` trước khi đọc CT.
- Query CT từ checkpoint cũ, giới hạn `SYS_CHANGE_VERSION <= upperWatermark`.
- Chỉ commit checkpoint bằng `upperWatermark` đã chụp.
- `ChangedRow` phải chứa `SYS_CHANGE_VERSION`; reader nên trả `ChangeBatch { PreviousCheckpoint, UpperWatermark, Rows }`.

## Finding 2 — Critical: Dữ liệu đích và checkpoint không được ghi nguyên tử
**Vị trí:** `2026-07-18-Implementation-Plan.md:95`, `:189`, `:401`

Plan tách `IPostgresUpsertWriter` và `ISyncCheckpointStore`. Nếu writer và checkpoint store dùng các transaction riêng, có thể có hai trạng thái sai:
- Dữ liệu PostgreSQL commit nhưng checkpoint lỗi: retry lặp batch.
- Checkpoint commit nhưng một phần ghi dữ liệu lỗi: checkpoint tiến lên trong khi data chưa đầy đủ; thay đổi bị mất.

### Giải pháp
Thay CT write path bằng một operation atomic, ví dụ `ISyncBatchApplier.ApplyBatchAndAdvanceCheckpointAsync(...)`:
1. Mở PostgreSQL transaction.
2. Delete row có operation `D` theo PK.
3. Upsert row `I`/`U` bằng `INSERT ... ON CONFLICT DO UPDATE`.
4. Update checkpoint đến `UpperWatermark`.
5. Commit một lần.

Checkpoint update cần optimistic concurrency guard:
```sql
UPDATE sync_meta.checkpoint
SET last_sync_version = @upper_watermark,
    updated_at = now()
WHERE source_table = @source_table
  AND last_sync_version = @previous_checkpoint;
```

Nếu không update đúng một row thì rollback và retry. Delete theo PK và upsert phải idempotent để retry an toàn.

### Sắc thái bổ sung
- Plan `:402` ("Không cập nhật checkpoint nếu ghi Postgres fail") ép thứ tự **data trước, checkpoint sau**. Thứ tự này đã loại ca "checkpoint tiến khi data thiếu" nếu writer atomic. Nhưng nó **không** loại ca crash *sau khi data tx commit, trước khi checkpoint tx commit*: lượt sau đọc lại CT từ checkpoint cũ, có thể duplicate delete/upsert. An toàn chỉ khi mọi ghi idempotent — nên atomic gộp vẫn là fix đúng, không phải tùy chọn.
- `IPostgresUpsertWriter` (Plan `:189`) gộp *batch upsert + batch delete* trong một interface. Hai thao tác này cũng phải nằm trong **cùng một** Postgres transaction với checkpoint update — không chỉ ghép data+checkpoint mà còn phải ghép upsert+delete với nhau. Nếu writer chạy 2 statement/2 tx, replay nửa batch vẫn phải idempotent-safe.

## Finding 3 — High: Bootstrap và full-resync recovery chưa đảm bảo snapshot nhất quán
**Vị trí:** `2026-07-18-Implementation-Plan.md:403-407`, `:377-384`; `2026-07-18-Implementation-Idea.md:71-79`

Tài liệu Idea đúng khi chụp baseline trước full load. Tuy nhiên plan recovery lại ghi checkpoint bằng `CHANGE_TRACKING_CURRENT_VERSION()` sau full refresh. Thay đổi xảy ra trong lúc copy có thể bị checkpoint nhảy qua.

### Giải pháp
Dùng một quy trình thống nhất cho bootstrap và CT-invalid recovery:
1. Chụp `baselineVersion = CHANGE_TRACKING_CURRENT_VERSION()` trước full-copy.
2. Đọc full snapshot từ SQL Server dưới snapshot isolation.
3. Upsert/delete dữ liệu đích theo chính sách full refresh.
4. Trong cùng PostgreSQL transaction xác nhận full load hoàn tất và lưu checkpoint bằng `baselineVersion`.
5. Lượt CT incremental tiếp theo đọc từ `baselineVersion`, nên bắt được tất cả thay đổi phát sinh trong lúc full-copy.

Không được lấy current version ở cuối full refresh làm checkpoint.

## Finding 4 — High: `DEFAULT 0` không biểu thị checkpoint hợp lệ
**Vị trí:** `2026-07-18-Implementation-Plan.md:283-287`

Schema hiện có `last_sync_version BIGINT NOT NULL DEFAULT 0`. Giá trị `0` không phân biệt được:
- Bảng chưa bootstrap.
- Checkpoint hợp lệ ngay sau lúc CT được bật.
- Checkpoint đã hết hạn vì retention cleanup.

Nếu CT đã tồn tại lâu và cleanup chạy, `0` nhỏ hơn min valid version. Job có thể enumerate incremental bằng checkpoint không hợp lệ.

### Giải pháp
Dùng schema checkpoint có trạng thái:
```sql
CREATE TABLE sync_meta.checkpoint (
    source_table      TEXT PRIMARY KEY,
    last_sync_version BIGINT NULL,
    sync_status       TEXT NOT NULL DEFAULT 'pending_initial_sync',
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (sync_status IN (
        'pending_initial_sync',
        'ready',
        'requires_full_resync'
    ))
);
```

- Chỉ CT incremental khi `sync_status = 'ready'`.
- Khi checkpoint không còn hợp lệ, atomically chuyển sang `requires_full_resync`.
- Bảng mới bắt đầu ở `pending_initial_sync`.

## Finding 5 — High: Filter `IsCustomer = 1` làm stale target row
**Vị trí:** `2026-07-18-Implementation-Plan.md:364-369`

Plan đề xuất filter CT query bằng `P.IsCustomer = 1 OR CT.SYS_CHANGE_OPERATION = 'D'`. Điều này không xử lý một Partner từng là customer, đã được sync, sau đó update thành `IsCustomer = 0`.

CT operation là `U`; row nguồn hiện vẫn tồn tại nhưng bị filter loại. Target PostgreSQL sẽ giữ row stale thay vì xóa nó.

### Giải pháp
Quy định semantics theo từng CT row:
- `D`: delete target row theo PK.
- `I`/`U` với current source row thỏa filter: upsert target row.
- `I`/`U` với current source row không còn thỏa filter: delete target row theo PK.

Full refresh orphan-delete cũng phải giới hạn trong phạm vi ownership/config tương ứng; không được xóa row do source hoặc config khác quản lý.

## Finding 6 — Medium: Thiếu `SELECT` permission và snapshot isolation
**Vị trí:** `2026-07-18-Implementation-Plan.md:256-260`

Kế hoạch chỉ cấp `VIEW CHANGE TRACKING`, nhưng CT reader join `CRM.Partners`, nên login còn cần `SELECT` trên source table/cột được sync.

Kế hoạch cũng chưa yêu cầu snapshot isolation để CT metadata và row nguồn được đọc nhất quán.

### Giải pháp
Thêm quyền tối thiểu:
```sql
GRANT SELECT ON [CRM].[Partners] TO [api_login];
GRANT VIEW CHANGE TRACKING ON [CRM].[Partners] TO [api_login];
```

Bật snapshot isolation sau DBA review:
```sql
ALTER DATABASE [ERP_DB] SET ALLOW_SNAPSHOT_ISOLATION ON;
```

Reader dùng:
```sql
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRANSACTION;

DECLARE @upper_watermark bigint = CHANGE_TRACKING_CURRENT_VERSION();

SELECT CT.SYS_CHANGE_VERSION,
       CT.SYS_CHANGE_OPERATION,
       CT.PartnerId,
       P.*
FROM CHANGETABLE(CHANGES [CRM].[Partners], @last_version) AS CT
LEFT JOIN [CRM].[Partners] AS P
    ON P.PartnerId = CT.PartnerId
WHERE CT.SYS_CHANGE_VERSION <= @upper_watermark
ORDER BY CT.SYS_CHANGE_VERSION, CT.PartnerId;

COMMIT TRANSACTION;
```

DBA cần đánh giá tác động version store trên `tempdb` trước production.

## Finding 7 — Medium: Full-refresh orphan delete có thể vi phạm FK hoặc xóa sai
**Vị trí:** `2026-07-18-Implementation-Plan.md:397-399`, `:532-537`; `2026-07-17-Section5.3-Table-List.md:36-58`

Sync parent trước child chỉ phù hợp cho upsert. Khi source xóa parent nhưng target child còn tồn tại, delete parent sẽ bị FK chặn.

Ngoài ra, orphan delete không được scoped đúng có thể xóa dữ liệu do config/source khác quản lý.

### Giải pháp
Chọn và document một chính sách delete nhất quán:
- Soft-delete/inactivate để giữ FK; hoặc
- Hard-delete theo thứ tự child → parent; hoặc
- FK `ON DELETE` phù hợp nghiệp vụ.

Với full refresh, upsert và orphan-delete của một bảng phải nằm trong cùng PostgreSQL transaction. Đồng thời cần định nghĩa ownership marker hay source scope để orphan-delete không chạm row ngoài phạm vi config.

## Finding 8 — Medium: Cron 30 giây chưa được xác nhận tương thích với HangFire version đang dùng
**Vị trí:** `2026-07-18-Implementation-Plan.md:435-440`

Plan dùng cron 6 trường `"*/30 * * * * *"`. Cần xác nhận chính xác version/parser của HangFire có hỗ trợ seconds. API cron tích hợp chuẩn của HangFire thường dùng schedule độ phân giải theo phút.

### Giải pháp
- Pilot an toàn: dùng `Cron.Minutely()`.
- Nếu SLA buộc latency 30 giây: xác nhận extension/version hỗ trợ cron seconds, hoặc dùng `BackgroundService` poller để enqueue/call sync use case mỗi 30 giây.
- Dù chọn scheduler nào, CT vẫn là pull/poll pattern; CT không tự push job sang HangFire.

## Finding 9 — Low: Đường dẫn tài liệu tham chiếu không nhất quán
**Vị trí:** `2026-07-17-Section5.3-Table-List.md:6`, `:728`; `2026-07-18-Implementation-Idea.md:109`

- Table List tham chiếu `2026-07-17-SyncWorker-Implementation-plan.md`, nhưng file này không có trong folder Phase 1 đã rà soát.
- Implementation Idea trỏ Table List không có segment `phase-1/`, trong khi file thực tế nằm trong folder đó.

### Giải pháp
Cập nhật tất cả reference nội bộ về đúng đường dẫn hiện hành và bỏ/đổi reference đến plan cũ không còn tồn tại.

## Finding 10 — Medium: Composite PK chưa có trong contract delete/checkpoint
**Vị trí:** `2026-07-17-Section5.3-Table-List.md` (`exchange_rates`, `unit_conversions`)

`exchange_rates` (PK = currency + effective_date) và `unit_conversions` (PK = from_unit + to_unit) dùng composite PK. Delete-by-PK và upsert `ON CONFLICT` phải liệt kê đủ tất cả cột PK. Contract `ChangedRow.PrimaryKey` dạng `IReadOnlyDictionary` xử lý được, nhưng plan gốc `TableSyncConfig.PrimaryKeyColumns[]` + `IPostgresUpsertWriter.DeleteBatch(pkColumns, keys)` chưa có test riêng cho ca composite. Test 9 (FK delete) không cover composite-key delete.

### Giải pháp
- Bắt buộc writer build `WHERE`/`ON CONFLICT` từ toàn bộ `PrimaryKeyColumns`, không giả định single-column.
- Thêm test: delete + upsert idempotent trên bảng composite PK.

## Finding 11 — High: `exchange_rates` append-by-date xung đột full-refresh orphan-delete
**Vị trí:** `2026-07-17-Section5.3-Table-List.md` (`exchange_rates`); `2026-07-18-Implementation-Plan.md:397-399`

Table List quy định `exchange_rates` giữ lịch sử theo ngày — không overwrite. Nhưng FullRefresh orphan-delete (Plan `:399`) xóa row Postgres không còn trong snapshot filter vừa đọc. Nếu snapshot chỉ lấy tỷ giá hiện hành / một cửa sổ ngày, các row lịch sử ngoài cửa sổ sẽ bị orphan-delete xóa mất — mâu thuẫn yêu cầu giữ lịch sử.

### Giải pháp
- Với bảng history-append: **tắt** orphan-delete, chỉ upsert theo composite PK (currency + effective_date).
- Hoặc scope orphan-delete theo đúng cửa sổ snapshot đọc, không phải toàn bảng.
- Đánh dấu mode riêng (`AppendOnly` / `HistoryUpsert`) trong `TableSyncConfig` để tách khỏi FullRefresh có orphan-delete.

## Finding 12 — Medium: `cmp_sections` DISTINCT/aggregate phá map 1:1 row-PK
**Vị trí:** `2026-07-17-Section5.3-Table-List.md` (`cmp_sections`)

`cmp_sections` nguồn từ `CMP.Operations`, phải `DISTINCT` ra 9 section. Nguồn nhiều row map về ít row đích — không phải 1:1 row→PK. FullRefresh full-snapshot upsert giả định mỗi source row = một target PK; ở đây mapper phải aggregate trước upsert. Nếu không, upsert lặp cùng `ua_section_code` gây conflict/ghi đè vô ích, và orphan-delete tính sai tập PK nguồn.

### Giải pháp
- Mapper `cmp_sections` phải `SELECT DISTINCT` / `GROUP BY` ở tầng đọc SQL Server, trả tập section đã dedup trước khi vào writer.
- Orphan-delete so tập PK **sau** aggregate, không so raw source row.

## Finding 13 — Medium: Cron 30s + `DisableConcurrentExecution` timeout gây backlog phình
**Vị trí:** `2026-07-18-Implementation-Plan.md:427`, `:435-440`

Cron 30 giây kết hợp `[DisableConcurrentExecution(timeout)]`. Nếu một lượt sync chạy lâu hơn 30 giây, Hangfire vẫn enqueue lượt kế; `DisableConcurrentExecution` chặn chạy song song nhưng job bị chặn nằm chờ tới hết timeout, và scheduler tiếp tục enqueue → backlog queue `data-sync` phình. Finding 8 chỉ chạm tương thích parser cron, chưa nêu tương tác backlog.

### Giải pháp
- Đảm bảo chu kỳ enqueue > thời gian chạy tối đa dự kiến (đo p95 latency trước khi chốt 30s).
- Hoặc dùng `BackgroundService` poller *self-scheduling* (chạy xong mới hẹn lượt sau) thay recurring cron cứng, tránh chồng enqueue.
- Set `DisableConcurrentExecution` timeout ngắn để job chặn fail nhanh thay vì giữ worker slot.

## Hướng thay đổi contracts đề xuất
`ChangedRow` cần primary key riêng, CT metadata và payload nullable cho DELETE:
```csharp
public sealed record ChangedRow(
    IReadOnlyDictionary<string, object?> PrimaryKey,
    string Operation,
    long ChangeVersion,
    IReadOnlyDictionary<string, object?>? CurrentValues);

public sealed record ChangeBatch(
    long PreviousCheckpoint,
    long UpperWatermark,
    IReadOnlyList<ChangedRow> Rows);
```

Thay cho các lời gọi writer/checkpoint tách rời:
```csharp
public interface ISyncBatchApplier
{
    Task ApplyBatchAndAdvanceCheckpointAsync(
        TableSyncConfig config,
        ChangeBatch batch,
        CancellationToken cancellationToken);
}
```

## Kiểm thử bắt buộc trước Phase A sign-off
1. Bootstrap lần đầu: target khớp source trong phạm vi filter.
2. CT insert/update/delete: target thay đổi đúng.
3. Filter transition: `IsCustomer = true` chuyển thành `false` phải xóa row target.
4. Concurrent change: tạo update sau khi chụp upper watermark nhưng trước PostgreSQL commit; update đó phải xuất hiện ở lượt kế tiếp.
5. Failure atomicity: inject lỗi trước PostgreSQL commit và sau delete/upsert; dữ liệu target và checkpoint phải rollback cùng nhau.
6. Retry: chạy lại cùng batch không tạo duplicate hoặc sai dữ liệu.
7. CT retention/truncate: checkpoint invalid phải chuyển sang full-resync, không enumerate CT sai.
8. Full-resync concurrent change: thay đổi trong lúc full-copy phải được CT incremental kế tiếp bắt lại.
9. FK delete: xác nhận chính sách soft-delete/hard-delete và thứ tự xóa hoạt động cho parent-child tables.
10. Restart/downtime: restart API/HangFire phải catch-up từ checkpoint hợp lệ.
11. Composite PK (Phase B): delete + upsert idempotent trên `exchange_rates`, `unit_conversions` với PK nhiều cột.
12. History-append (Phase B): `exchange_rates` giữ row lịch sử — orphan-delete không được xóa row ngoài cửa sổ snapshot.
13. Aggregate mapping (Phase B): `cmp_sections` DISTINCT từ `CMP.Operations` ra đúng tập section, orphan-delete tính trên tập đã dedup.

## Thứ tự khắc phục khuyến nghị
1. Sửa schema checkpoint, interface và CT flow atomically trước Phase A implementation.
2. Bổ sung snapshot isolation, permission `SELECT`, CT validity check và bootstrap/full-resync flow.
3. Chốt filter-transition và delete semantics cho `CRM.Partners`.
4. Chốt full-refresh/FK deletion policy trước Phase B.
5. Xác nhận cron 30 giây hoặc chuyển pilot sang schedule mỗi phút; đo p95 latency để chống backlog phình (Finding 13).
6. Sửa link/reference tài liệu.
7. Trước Phase B: tách mode `AppendOnly`/`HistoryUpsert` cho `exchange_rates`, hỗ trợ composite PK trong writer, và aggregate mapping cho `cmp_sections` (Finding 10–12).
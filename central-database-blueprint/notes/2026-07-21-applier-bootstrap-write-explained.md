# Applier: Ghi Bootstrap Data vào PostgreSQL 

**Ngày:** 2026-07-21

## Vấn đề

Reader đã đọc snapshot từ SQL Server thành công — một list các rows. Làm sao để ghi tất cả rows đó vào PostgreSQL một cách an toàn, không duplicate, và không làm hỏng dữ liệu cũ?

Cần 3 việc:
1. **Upsert** — thêm mới hoặc cập nhật nếu đã có (INSERT ON CONFLICT)
2. **Deactivate orphans** — tắt những row cũ trong PG không còn trong snapshot
3. **Checkpoint** — ghi nhận version đã sync để CT sync sau này biết đường chạy

---

## Bước 1: BuildTargetValues — Ánh xạ field

Snapshot từ reader có dạng `GenericSourceRow` — dictionary keyed bằng alias SQL (VD: `partner_id`, `company_id`). Applier cần ánh xạ sang PostgreSQL column names.

Input từ reader:
```csharp
// GenericSourceRow (keyed bằng alias của SELECT)
{ partner_id: 1, company_id: 100, code: "ABC", name: "Cty ABC",
  is_customer: true, is_supplier: false, email: "abc@xyz.com",
  phone: "0909123456", activated: true }
```

`BuildTargetValues` duyệt từng `ColumnMapping` trong rule và quyết định giá trị:

```csharp
// PostgresGenericApplier.cs:217-227
private object? ResolveColumnValue(TableMappingRule rule, ColumnMapping column, GenericSourceRow sourceRow)
{
    // Trường hợp 1: IsActiveFlag → tính từ ActivePredicate (VD: IsCustomer == true)
    if (column.IsActiveFlag)
        return IsActive(rule, sourceRow);

    // Trường hợp 2: Transform → chạy transformer
    if (!string.IsNullOrWhiteSpace(column.Transform))
        return transformerRegistry.Resolve(column.Transform).Transform(sourceRow.Values);

    // Trường hợp 3: SourceColumn cụ thể → copy giá trị
    if (!string.IsNullOrWhiteSpace(column.SourceColumn))
        return sourceRow.GetValueOrDefault(column.SourceColumn);

    // Trường hợp 4: mặc định → copy theo tên
    return sourceRow.GetValueOrDefault(column.TargetColumn);
}
```

### Ví dụ mapping cho CRM.Partners

| ColumnMapping | TargetColumn | SourceColumn | IsActiveFlag | Kết quả |
|---|---|---|---|---|
| MapPk("partner_id", "integer", "t0.PartnerId") | partner_id | t0.PartnerId | false | copy: `1` |
| Map("company_id", "integer", "t0.CompanyId") | company_id | t0.CompanyId | false | copy: `100` |
| Map("name", "text", "t0.Name") | name | t0.Name | false | copy: `"Cty ABC"` |
| new() { TargetColumn = "is_active", IsActiveFlag = true } | is_active | null | **true** | tính: `IsCustomer == true` → `true` |

Output — target values:
```csharp
{ partner_id: 1, company_id: 100, code: "ABC", name: "Cty ABC",
  is_customer: true, is_supplier: false, email: "abc@xyz.com",
  phone: "0909123456", activated: true,
  is_active: true }   // ← được tính từ ActivePredicate
```

Lưu ý: `is_active` KHÔNG có trong SELECT từ SQL Server. Nó là computed field — được tính từ `ActivePredicate` (`IsCustomer == true`).

---

## Bước 2: Upsert tất cả rows

Sau khi có target values dictionary, applier dùng `UpsertSqlBuilder.BuildUpsert(rule)` để sinh câu SQL:

```csharp
// UpsertSqlBuilder.cs:7-20
INSERT INTO "report"."partners"
    ("partner_id", "company_id", "code", "name",
     "is_customer", "is_supplier", "email", "phone", "activated", "is_active")
VALUES
    (@partner_id, @company_id, @code, @name,
     @is_customer, @is_supplier, @email, @phone, @activated, @is_active)
ON CONFLICT ("partner_id")
DO UPDATE SET
    "company_id" = EXCLUDED."company_id",
    "code" = EXCLUDED."code",
    "name" = EXCLUDED."name",
    "is_customer" = EXCLUDED."is_customer",
    "is_supplier" = EXCLUDED."is_supplier",
    "email" = EXCLUDED."email",
    "phone" = EXCLUDED."phone",
    "activated" = EXCLUDED."activated",
    "is_active" = EXCLUDED."is_active",
    "synced_at" = NOW()
```

Giải thích:
- **INSERT** — thêm row mới
- **ON CONFLICT ("partner_id")** — nếu partner_id đã tồn tại...
- **DO UPDATE SET** — cập nhật tất cả column (trừ PK)
- **EXCLUDED** — tham chiếu đến giá trị mới (của INSERT)
- **synced_at = NOW()** — tự động ghi thời gian sync

Applier chạy câu này cho **mỗi row** trong snapshot:

```csharp
// PostgresGenericApplier.cs:140-146
foreach (var row in snapshot.Rows)
{
    var values = BuildTargetValues(rule, row);          // map field
    var parameters = ToDynamicParameters(values);        // thành Dapper params
    await conn.ExecuteAsync(upsertSql, parameters, tx);   // chạy SQL
    snapshotPrimaryKeys.Add(values[primaryKeyColumn]);    // lưu PK để xóa orphan
}
```

Đồng thời, nó lưu tất cả các primary key vào list `snapshotPrimaryKeys` — chuẩn bị cho bước xóa orphan.

---

## Bước 3: Deactivate orphan rows

### Orphan là gì?

**Orphan** = row trong PostgreSQL `report.partners` mà KHÔNG còn trong snapshot bootstrap.

### Ví dụ

ERP có 1000 partners, snapshot đọc được 950 rows (50 rows bị xóa khỏi ERP). Khi bootstrap xong, 50 rows cũ trên PostgreSQL phải bị tắt đi (không xóa hẳn — soft-deactivate).

### Câu SQL

`UpsertSqlBuilder.BuildLifecycleOrphans(rule, "sourceSystem")` sinh:

```sql
UPDATE "report"."partners"
SET "is_active" = false,
    "synced_at" = NOW()
WHERE "source_system" = @sourceSystem           -- chỉ xử lý row của ERP
  AND "partner_id" <> ALL(@snapshotPks)          -- KHÔNG có trong snapshot
```

Giải thích:
- `source_system = 'erp'` — chỉ deactivate row do ERP quản lý (không đụng row do hệ thống khác tạo)
- `partner_id <> ALL(@snapshotPks)` — row nào có PK không nằm trong list PK của snapshot thì đánh `is_active = false`

### Nếu table không có is_active flag

Với table như `ERP.Configs.Sizes` không có `is_active`, orphan sẽ bị **DELETE** thay vì soft-deactivate:

```sql
DELETE FROM "report"."sizes"
WHERE "source_system" = @sourceSystem
  AND "size_id" <> ALL(@snapshotPks)
```

---

## Bước 4: Upsert checkpoint

Ghi nhận checkpoint để CT sync biết bắt đầu từ đâu:

```sql
INSERT INTO sync_meta.checkpoint
    (source_table, last_sync_version, sync_status,
     last_attempt_at, last_success_at,
     consecutive_failure_count, last_error_code, last_error_message)
VALUES
    ('CRM.Partners', 100, 'ready',
     NOW(), NOW(),
     0, NULL, NULL)
ON CONFLICT (source_table)
DO UPDATE SET
    last_sync_version = EXCLUDED.last_sync_version,
    sync_status = 'ready',
    last_attempt_at = NOW(),
    last_success_at = NOW(),
    consecutive_failure_count = 0,
    last_error_code = NULL,
    last_error_message = NULL
```

- `last_sync_version = 100` — chính là `BaselineVersion` từ snapshot
- `sync_status = 'ready'` — báo hiệu table đã sẵn sàng cho CT sync

---

## Atomicity — 1 transaction

Cả 3 bước (upsert + deactivate orphan + checkpoint) nằm trong **1 PostgreSQL transaction**:

```csharp
// PostgresGenericApplier.cs:130-181
await using var tx = await conn.BeginTransactionAsync(ct);

try
{
    // Bước 2: Upsert từng row
    foreach (var row in snapshot.Rows) { ... }

    // Bước 3: Deactivate orphans
    await conn.ExecuteAsync(lifecycleSql, ...);

    // Bước 4: Upsert checkpoint
    await conn.ExecuteAsync(checkpointSql, ...);

    // Commit tất cả cùng lúc
    await tx.CommitAsync(ct);
}
catch
{
    await tx.RollbackAsync(ct);  // hoặc tất cả đều không có gì
    throw;
}
```

Nếu bất kỳ bước nào fail → **toàn bộ ROLLBACK**:
- Upsert rows mới chưa được ghi
- Orphans chưa bị tắt
- Checkpoint không thay đổi

---

## Bước 5 (ngoài transaction): SyncRunLog

Sau khi applier thành công, `BootstrapSyncService` ghi audit log:

```csharp
await runLog.WriteAsync(new SyncRunLogEntry
{
    RunId = runId,                          // UUID = requestId
    SourceTable = config.SourceTable,        // "CRM.Partners"
    Mode = "Bootstrap",
    Outcome = "succeeded",                   // hoặc failed
    RowsRead = snapshot.Rows.Count,          // 1000
    RowsUpserted = result.RowsUpserted,      // 950
    RowsDeactivated = result.RowsDeactivated, // 50
    CheckpointAfter = snapshot.BaselineVersion // 100
    // ...
}, cancellationToken);
```

Log này ghi vào bảng `sync_meta.sync_run_log` (transaction riêng — không gộp với upsert transaction).

---

## Tổng quan luồng

```text
BootstrapSyncService.ExecuteCoreAsync
    │
    ├── reader.ReadAsync() → snapshot (1000 rows, baseline version = 100)
    │
    ├── applier.ApplyBootstrapAsync()
    │       │
    │       ├── [BEGIN TRANSACTION PostgreSQL]
    │       │
    │       ├── Lặp 1000 rows:
    │       │   ├── BuildTargetValues (mỗi row)
    │       │   └── INSERT ON CONFLICT DO UPDATE
    │       │
    │       ├── Deactivate orphans:
    │       │   └── UPDATE report.partners SET is_active = false
    │       │       WHERE partner_id NOT IN (list 1000 PKs)
    │       │
    │       ├── Upsert checkpoint:
    │       │   └── INSERT sync_meta.checkpoint ... ON CONFLICT DO UPDATE
    │       │
    │       └── [COMMIT]
    │
    ├── runLog.WriteAsync() → ghi audit OK
    │
    └── return SyncRunResult { Outcome = "succeeded", ... }

Trường hợp lỗi ở giữa:
    ├── [ROLLBACK]
    └── return SyncRunResult { Outcome = "failed", ... }
```

---

## Ví dụ hình dung

Bạn đang chuyển nhà:

```text
Bước 1 — BuildTargetValues:
    ── Lấy đồ từ thùng carton cũ (source), ghi nhãn mới cho thùng mới (target)
    ── VD: "PartnerId" trên nhãn cũ → "partner_id" trên nhãn mới
    ── "IsCustomer = true" → dán nhãn "is_active = true"

Bước 2 — Upsert:
    ── Mở tủ mới, bỏ đồ vào đúng ngăn
    ── Nếu đã có đồ ở ngăn đó → thay thế bằng đồ mới

Bước 3 — Deactivate orphans:
    ── Kiểm tra tủ cũ: đồ nào không có trong thùng mới → bỏ vào thùng rác
    ── Nhưng không vứt hẳn (soft-delete) — chỉ đánh dấu "rác"

Bước 4 — Checkpoint: 
    ── Ghi lên tủ: "đã dọn xong ngày 2026-07-21"

Atomicity:
    ── Nếu đang dọn thì có người gọi → bỏ qua hết, đóng tủ lại, hôm khác làm lại từ đầu
```

---

## Mã nguồn

| File | Vai trò |
|---|---|
| `Infrastructure/CentralDbSync/PostgresGenericApplier.cs:124-203` | ApplyBootstrapAsync — 4 bước trong 1 transaction |
| `Infrastructure/CentralDbSync/PostgresGenericApplier.cs:205-227` | BuildTargetValues — map field từ source row → target values |
| `Infrastructure/CentralDbSync/PostgresGenericApplier.cs:229-254` | IsActive + Evaluate — tính is_active từ ActivePredicate |
| `Infrastructure/CentralDbSync/PostgresGenericApplier.cs:309-371` | Typed PK array cho orphan query |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:7-20` | BuildUpsert — sinh INSERT ON CONFLICT DO UPDATE |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:40-59` | BuildLifecycleOrphans — sinh UPDATE/DELETE orphans |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:87-106` | runLog.WriteAsync sau khi applier thành công |
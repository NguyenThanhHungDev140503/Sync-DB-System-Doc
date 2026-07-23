# Metadata Fields: source_system & synced_at

**Ngày:** 2026-07-23

## Vấn đề

Sync engine copy dữ liệu từ nhiều nguồn (ERP, Salesforce...) vào PostgreSQL. Mỗi row cần trả lời được 2 câu hỏi:

1. **"Ai đã tạo ra row này?"** — để khi dọn dẹp (orphan cleanup), không xóa nhầm dữ liệu của nguồn khác.
2. **"Row này còn sống không?"** — để biết lần cuối sync engine chạm vào row này là khi nào, phục vụ audit và debug.

Hai field `source_system` và `synced_at` là metadata columns — chúng **không có trong mapping rule**, mà do sync engine tự quản lý. Mọi bảng target đều phải có chúng.

---

## Bước 1: `source_system` — tem xuất xưởng

### Nó là gì?

`source_system` là một TEXT ghi tên nguồn dữ liệu (ví dụ `"erp"`). Nó được gán một lần duy nhất khi row được INSERT, và **không bao giờ thay đổi**.

### Nó đến từ đâu?

Giá trị được lấy từ `rule.OwnershipScope` trong mapping rule:

```csharp
// CrmPartnerMappingRuleCatalog.cs:50
OwnershipScope = "erp",
```

Khi applier build target values, nó tự động thêm `source_system` vào dictionary — **không cần khai báo trong `rule.Columns`**:

```csharp
// PostgresGenericApplier.cs:205-215
private Dictionary<string, object?> BuildTargetValues(TableMappingRule rule, GenericSourceRow sourceRow)
{
    var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
    foreach (var column in rule.Columns)
    {
        PostgresTypeMap.EnsureSupported(column.TargetType);
        values[column.TargetColumn] = ResolveColumnValue(rule, column, sourceRow);
    }

    values["source_system"] = rule.OwnershipScope;  // ← tự động thêm
    return values;
}
```

### Nó xuất hiện ở đâu trong SQL?

**Trong UPSERT INSERT** — row mới luôn được dán tem:

```csharp
// UpsertSqlBuilder.cs:9-14
var insertColumns = rule.Columns.Select(c => QuotePgIdentifier(c.TargetColumn))
    .Append(QuotePgIdentifier("source_system"))    // ← thêm vào column list
    .Append(QuotePgIdentifier("synced_at")).ToList();
var valueColumns = rule.Columns.Select(c => "@" + c.TargetColumn)
    .Append("@source_system")                       // ← tham chiếu giá trị
    .Append("NOW()").ToList();
```

**Trong orphan cleanup** — WHERE clause dùng `source_system` để filter:

```csharp
// UpsertSqlBuilder.cs:100-101
var whereClause = $"\"source_system\" = @{sourceSystemParameterName}
  AND \"{pk}\" <> ALL(@snapshotPks)";
```

Sinh ra câu SQL:
```sql
UPDATE "ref"."customer"
SET "active" = false, "synced_at" = NOW()
WHERE "source_system" = @sourceSystem          -- chỉ đụng row của ERP
  AND "customer_id" <> ALL(@snapshotPks)        -- không có trong snapshot mới
```

Và ở phía gọi:

```csharp
// PostgresGenericApplier.cs:150-157
var orphanLifecycleCount = await conn.ExecuteAsync(
    sqlBuilder.BuildLifecycleOrphans(rule, "sourceSystem"),
    new
    {
        sourceSystem = rule.OwnershipScope,     // "erp"
        snapshotPks
    },
    transaction: tx);
```

### Tại sao orphan cleanup KHÔNG update `source_system`?

Vì row đó đã có tem `"erp"` từ lúc INSERT rồi. WHERE clause chỉ cần **đọc** tem để quyết định: "Row này có tem 'erp' không? Nếu có và không còn trong danh sách mới → xóa nó." Update `source_system = 'erp'` vào SET là thừa — giống như cầm tem cũ ra xem, thấy ghi "erp", rồi dán đè tem y hệt lên.

---

## Bước 2: `synced_at` — dấu thời gian sync cuối

### Nó là gì?

`synced_at` là TIMESTAMPTZ ghi lại thời điểm sync engine **cuối cùng chạm vào row này** — bất kể là INSERT mới, UPDATE, hay soft-delete. Nó luôn được set `NOW()` tại thời điểm thực thi SQL.

### Nó xuất hiện ở đâu?

`synced_at` được hardcode trong `UpsertSqlBuilder` ở **4 vị trí**:

**Vị trí 1 & 2 — UPSERT (INSERT + UPDATE)**

```csharp
// UpsertSqlBuilder.cs:9-19
// INSERT:
var insertColumns = ...
    .Append(QuotePgIdentifier("synced_at")).ToList();     // ← cột
var valueColumns = ...
    .Append("NOW()").ToList();                             // ← giá trị

// UPDATE:
var updateColumns = ...
    .Append($"\"synced_at\" = NOW()");                     // ← SET clause
```

Kết quả SQL:
```sql
INSERT INTO "ref"."customer" (..., "synced_at")
VALUES (..., NOW())                              -- INSERT: gán NOW()
ON CONFLICT ("customer_id")
DO UPDATE SET
    ...,
    "synced_at" = NOW()                          -- UPDATE: gán NOW()
```

**Vị trí 3 — Lifecycle soft-delete (incremental sync)**

```csharp
// UpsertSqlBuilder.cs:81-84
// Deactivate một row cụ thể khi source báo row đó bị xóa
return $@"UPDATE ... SET "{activeFlagColumn}" = false,
    "synced_at" = NOW()
WHERE {whereClause}";
```

**Vị trí 4 — Lifecycle orphan cleanup (bootstrap)**

```csharp
// UpsertSqlBuilder.cs:105-108
// Deactivate tất cả row không còn trong snapshot bootstrap
return $@"UPDATE ... SET "{activeFlagColumn}" = false,
    "synced_at" = NOW()
WHERE ...";
```

### Tại sao `synced_at` dùng `NOW()` thay vì `EXCLUDED.synced_at`?

Trong PostgreSQL `ON CONFLICT DO UPDATE`, `EXCLUDED` là pseudo-table chứa giá trị mà INSERT *định* ghi. Với `synced_at`, INSERT VALUES đã là `NOW()` nên `EXCLUDED.synced_at` cũng trả về `NOW()` — kết quả giống hệt.

Viết `NOW()` thay vì `EXCLUDED.synced_at` là **chủ ý thiết kế**: phân biệt rõ data column (dùng `EXCLUDED` — giá trị đến từ source) với metadata column (dùng `NOW()` — do engine quản lý). Code rõ intent hơn.

---

## So sánh nhanh

| | `source_system` | `synced_at` |
|---|---|---|
| **Mục đích** | Ai tạo ra row này? | Row này được sync lần cuối khi nào? |
| **Đến từ đâu** | `rule.OwnershipScope` | `NOW()` tại thời điểm SQL thực thi |
| **Khi nào được ghi** | INSERT (1 lần duy nhất) | Mọi INSERT, UPDATE, soft-delete |
| **Không update khi** | — | DELETE (hard-delete) |
| **Dùng trong WHERE** | Có (orphan cleanup) | Không |
| **Có trong mapping rule?** | Không — engine tự thêm | Không — builder hardcode |
| **Thay đổi được không?** | Không, tem cố định từ lúc sinh | Có, cập nhật mỗi lần sync |

---

## Tổng quan luồng

```text
Sync Engine (Incremental hoặc Bootstrap)
    │
    ├── BuildTargetValues()
    │   └── values["source_system"] = rule.OwnershipScope    ← dán tem
    │       values[...data columns...] = từ source row
    │       (synced_at KHÔNG có trong values — do SQL tự sinh)
    │
    ├── BuildUpsert()
    │   └── INSERT (..., "source_system", "synced_at")
    │       VALUES (..., @sourceSystem, NOW())               ← tem + timestamp
    │       ON CONFLICT DO UPDATE SET
    │           ...data columns = EXCLUDED...                 ← data từ source
    │           "synced_at" = NOW()                           ← metadata tự sinh
    │
    ├── BuildLifecycleOrphans()  [chỉ khi bootstrap]
    │   └── UPDATE ... SET "active" = false, "synced_at" = NOW()
    │       WHERE "source_system" = @sourceSystem             ← dùng tem để lọc
    │         AND pk <> ALL(@snapshotPks)
    │
    └── BuildLifecycleByPrimaryKey()  [chỉ khi CT sync]
        └── UPDATE ... SET "active" = false, "synced_at" = NOW()
            WHERE pk = @pk
```

---

## Ví dụ hình dung

Hãy tưởng tượng bạn quản lý một **kho hàng** (PostgreSQL):

**`source_system`** = **tem xuất xưởng** dán lên mỗi kiện hàng:
- Kiện hàng từ ERP → dán tem `"erp"`
- Kiện hàng từ Salesforce → dán tem `"salesforce"`
- Khi kiểm kê kho (orphan cleanup): "Chỉ kiểm hàng có tem ERP, hàng tem Salesforce để yên."
- Tem được dán MỘT LẦN khi hàng nhập kho, không bao giờ đổi.

**`synced_at`** = **phiếu kiểm kê** ghi ngày giờ:
- Mỗi lần chạm vào kiện hàng (nhập mới, cập nhật, đánh dấu hỏng) → kẹp phiếu mới ghi ngày hôm nay.
- Ai muốn biết "kiện hàng này còn được quản lý không?" → nhìn phiếu: nếu phiếu cũ quá (2 tuần trước) → có vấn đề.

---

## Mã nguồn

| File | Vai trò |
|---|---|
| `Infrastructure/CentralDbSync/PostgresGenericApplier.cs:205-215` | `BuildTargetValues` — tự động thêm `source_system` vào values |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:7-24` | `BuildUpsert` — thêm cả 2 field vào INSERT + UPDATE SQL |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:68-92` | `BuildLifecycleByPrimaryKey` — soft-delete với `synced_at = NOW()` |
| `Infrastructure/CentralDbSync/Sql/UpsertSqlBuilder.cs:94-113` | `BuildLifecycleOrphans` — orphan cleanup với `source_system` trong WHERE + `synced_at = NOW()` |
| `Application/Features/CentralDbSync/Config/Rules/CRM/CrmPartnerMappingRuleCatalog.cs:50` | `OwnershipScope = "erp"` — nguồn gốc giá trị `source_system` |

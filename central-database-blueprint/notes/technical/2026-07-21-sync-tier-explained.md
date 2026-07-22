# sync_tier — Phân loại bảng đồng bộ (Hot / Cold)

## 1. Mở đầu — Vấn đề

**sync_tier là gì?** Là một label phân loại gắn cho mỗi bảng trong Central DB Sync, có hai giá trị: **Hot** và **Cold**.

**Tại sao cần nó?**
- Không phải bảng nào cũng quan trọng như nhau
- Bảng quan trọng (Hot) cần đồng bộ thường xuyên, độ trễ thấp
- Bảng ít thay đổi (Cold) có thể đồng bộ tần suất thấp hơn để tiết kiệm tài nguyên

sync_tier là **cơ sở hạ tầng** (infrastructure) cho phép phân loại này — nó được cài sẵn ở tất cả các layer (schema, model, mapping rule, validation) để sau này dễ dàng implement scheduling khác nhau giữa Hot và Cold.

---

## 2. sync_tier xuất hiện ở những đâu?

### 2.1. SQL schema

```sql
-- Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql:80
CREATE TABLE IF NOT EXISTS sync_meta.table_sync_config
(
    ...
    sync_tier TEXT NOT NULL DEFAULT 'Hot',
    ...
);
```

Cột `sync_tier` trong bảng `sync_meta.table_sync_config` lưu giá trị tier cho từng bảng. Default là `'Hot'`.

### 2.2. Model C# — TableSyncConfig

```csharp
// Application/Features/CentralDbSync/Models/TableSyncConfig.cs:9
public string SyncTier { get; init; } = "Hot";
```

`TableSyncConfig` là runtime config được truyền vào các service sync. Default là `"Hot"`.

### 2.3. Model C# — TableMappingRule

```csharp
// Application/Features/CentralDbSync/Mapping/TableMappingRule.cs:11
public string SyncTier { get; init; } = "Cold";
```

`TableMappingRule` là nơi định nghĩa mapping rule cho từng bảng. Default là `"Cold"` — một bảng mới khi tạo mapping rule sẽ mặc định là Cold, dev phải **chủ động set thành Hot** nếu cần.

### 2.4. Validation — SyncGuard

```csharp
// Application/Features/CentralDbSync/Validation/SyncGuard.cs:15-16
private static readonly HashSet<string> ValidSyncTiers =
    ["Hot", "Cold"];

public static void AssertValidSyncTier(string value, string paramName)
{
    if (!ValidSyncTiers.Contains(value))
        throw new ArgumentException(
            $"'{value}' is not a valid sync tier. Allowed: {string.Join(", ", ValidSyncTiers)}",
            paramName);
}
```

Chỉ chấp nhận `"Hot"` hoặc `"Cold"`. Bất kỳ giá trị nào khác đều throw exception ở application layer.

### 2.5. Validation được gọi ở đâu?

- `SyncOrchestrator.ExecuteAsync` — dòng 31: trước khi xử lý từng bảng
- `ChangeTrackingSyncService.ExecuteAsync` — dòng 26: trước khi chạy change-tracking sync
- `BootstrapSyncService.ValidateConfig` — dòng 142: trước khi chạy bootstrap sync

### 2.6. Seed data

```sql
-- Infrastructure/Database/SqlScript/CentralDbSync/002-central-db-sync-seed.sql:12-16
INSERT INTO sync_meta.table_sync_config
    (source_table, target_schema, target_table, sync_mode, sync_tier, ...)
VALUES
    ('CRM.Partners', 'report', 'partners', 'ChangeTracking', 'Hot', ...)
ON CONFLICT (source_table) DO NOTHING;
```

CRM.Partners — table đầu tiên và duy nhất được seed — có `sync_tier = 'Hot'`.

### 2.7. PostgresSyncConfigStore

```csharp
// Infrastructure/CentralDbSync/PostgresSyncConfigStore.cs:19,29-40
$@"INSERT INTO {TableName}
    (source_table, target_schema, target_table, sync_mode, sync_tier, ...)
    VALUES
    (@sourceTable, @targetSchema, @targetTable, @syncMode, @syncTier, ...)
    ON CONFLICT (source_table)
    DO UPDATE SET ...
        sync_tier = @syncTier, ..."
```

Khi seed config qua application, `syncTier` được truyền từ `config.SyncTier` vào DB.

---

## 3. Hot vs Cold — Sự khác biệt hiện tại

Tất cả các bảng đã đăng ký trong hệ thống đều set `SyncTier = "Hot"`:

| Bảng | SyncTier | expected_sync_interval | max_allowed_lag |
|---|---|---|---|
| `CRM.Partners` | Hot | 1 phút | 5 phút |
| `ERP.Configs.Units` | Hot | 2 phút | 5 phút |
| `ERP.Configs.Sizes` | Hot | 2 phút | 5 phút |

(Source: `Application/Features/CentralDbSync/Config/TableMappingRegistry.cs:66,94,126`)

**Chưa có runtime branching theo tier.** sync_tier được validate ở tất cả các service, nhưng chưa có logic nào kiểm tra `if (config.SyncTier == "Cold")` để chạy nhánh xử lý khác. Đây là infrastructure đã sẵn sàng — phần scheduling differentiation dựa trên tier sẽ được implement sau.

---

## 4. Luồng dữ liệu

```text
TableMappingRegistry.CreateRules()
    │
    ├── Mỗi rule có SyncTier (Hot / Cold)
    │
    ├── rule.ToTableSyncConfig()
    │       └── SyncTier được copy qua TableSyncConfig
    │
    ├── PostgresSyncConfigStore.SeedAsync()
    │       └── Ghi sync_tier vào sync_meta.table_sync_config
    │
    └── SyncOrchestrator.ExecuteAsync()
            └── SyncGuard.AssertValidSyncTier() — validate
            └── (chưa branch theo tier)
```

---

## 5. Analogy

| Tầng | Nghiệp vụ | Kỹ thuật |
|---|---|---|
| Cửa hàng có 2 loại khách | Khách VIP (Hot) ưu tiên phục vụ trước, nhanh hơn. Khách thường (Cold) chờ lâu hơn. | sync_tier phân loại Hot/Cold |
| Danh sách khách VIP ở quầy lễ tân | Mỗi khách có thẻ VIP (hay không) | Cột `sync_tier` trong `table_sync_config` |
| Lễ tân kiểm tra thẻ trước khi phục vụ | Kiểm tra "khách này có thẻ VIP không?" | `SyncGuard.AssertValidSyncTier()` |
| Nhà hàng đã có quy trình phân loại, có thẻ, có danh sách | Nhưng quy trình phục vụ nhanh/chậm chưa được triển khai cụ thể | Chưa có runtime branching |

---

## 6. Bảng mapping source code

| File | Vai trò |
|---|---|
| `Application/Features/CentralDbSync/Models/TableSyncConfig.cs:9` | Model runtime — default `"Hot"` |
| `Application/Features/CentralDbSync/Mapping/TableMappingRule.cs:11` | Model mapping rule — default `"Cold"` |
| `Application/Features/CentralDbSync/Validation/SyncGuard.cs:15-58` | Validation — chỉ chấp nhận `"Hot"` / `"Cold"` |
| `Application/Features/CentralDbSync/Config/TableMappingRegistry.cs:66,94,126` | Gán tier cho từng bảng cụ thể |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs:31` | Validate tier trước khi sync |
| `Application/Features/CentralDbSync/Services/ChangeTrackingSyncService.cs:26` | Validate tier trước CT sync |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs:142` | Validate tier trước bootstrap |
| `Infrastructure/CentralDbSync/PostgresSyncConfigStore.cs:19,29` | Persist tier vào DB |
| `Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql:80` | Định nghĩa cột `sync_tier` (DEFAULT `'Hot'`) |
| `Infrastructure/Database/SqlScript/CentralDbSync/002-central-db-sync-seed.sql:12` | Seed CRM.Partners với `sync_tier = 'Hot'` |

---

## 7. Feature implement cho Cold tier

sync_tier là **cơ sở hạ tầng** được xây dựng để hỗ trợ Cold tier:

- **Schema và model** đã có cột sync_tier, mặc định là `"Cold"` ở mapping rule — nghĩa là bảng mới sẽ là Cold nếu không set explicit
- **Validation** đã chấp nhận `"Cold"` — không throw error nếu gặp giá trị này
- **Tất cả bảng hiện tại** đều là Hot — phù hợp với phase 1 pilot
- Khi cần mở rộng cho Cold table, việc cần làm:
  1. Thêm mapping rule mới với `SyncTier = "Cold"` (hoặc không set — default đã là `"Cold"`)
  2. Implement scheduling logic phân biệt Hot/Cold (ví dụ: chạy Cold table mỗi 1 giờ thay vì mỗi 1 phút)

Cold tier là target cho các bảng đồng bộ ít quan trọng hơn (ví dụ: bảng tham số, bảng ít biến động), không yêu cầu độ trễ thấp.

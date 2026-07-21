# Plan: Dynamic Sync Mapping Rule — Generic ERP → PostgreSQL Sync Engine

**Ngày:** 2026-07-20 (cập nhật 2026-07-20 — bỏ FullRefresh; làm rõ phạm vi join)
**Status:** Plan — đã chốt quyết định thiết kế (2026-07-20); chưa implement
**Phạm vi:** Refactor engine sync ERP (SQL Server) → Central DB (PostgreSQL) từ *Partner-specific* sang *generic, config-driven mapping rule* — **single-source only** (một bảng nguồn → một bảng đích, Bootstrap + CT).
**Tài liệu nền:**
- `2026-07-18-Implementation-Idea.md` — vì sao sync, ERP primary vs replica
- `2026-07-18-central-db-sync-design.md` — contract đã chốt (lock, checkpoint, atomicity, lifecycle)
- `2026-07-18-Synchronization-Consistency-Review.md` — quy tắc CT checkpoint bắt buộc
- `2026-07-17-Section5.3-Table-List.md` — 17 bảng vocab Phase B sẽ hưởng lợi trực tiếp
- `docs/notes/2026-07-19-snapshot-isolation-decision.md` — bootstrap isolation = READPAST + recheck

> **Nguyên tắc bất biến:** Plan này **không thay đổi** các contract nhất quán đã chốt trong design (per-table advisory lock, `UpperWatermark` chụp trước khi đọc CT, apply + advance checkpoint trong một PostgreSQL transaction, soft-deactivate `is_active`, eventual consistency per-table). Nó chỉ thay **cách một bảng được đọc và ghi** — từ hard-code sang khai báo.

> **Chiến lược sync (đã chốt 2026-07-20):** Mọi bảng dùng **Bootstrap + Change Tracking** — khớp orchestrator hiện tại. **Không** có FullRefresh định kỳ (full read lặp lại sau init). Init/recovery = Bootstrap; steady-state = CT. `SyncMode` trên metadata luôn `ChangeTracking`.

```
Checkpoint null / pending / requires_full_resync  →  Bootstrap (full snapshot + baseline)
Checkpoint ready                                →  Change Tracking (incremental)
```

> **Phạm vi IN (plan này — implement ngay):**
> - Single-source: `Source.Joins = []` — một bảng ERP → một bảng Postgres.
> - Map cột, `SourceExpression` / transform trên **cùng một bảng nguồn**, ReadFilter, ActivePredicate.
> - Bootstrap + CT; migrate Partners; onboard vocab single-source (Stage 6).
>
> **Phạm vi OUT (không implement trong plan này — xem §14):**
> - **Join nhiều bảng nguồn → một bảng đích** (`Source.Joins` không rỗng).
> - Tính toán / map cột lấy từ **nhiều bảng nguồn khác nhau** qua join native trong engine.
> - Aggregate / DISTINCT nhiều row nguồn → một PK đích (vd `cmp_sections`).
>
> **Workaround tạm thời (ngoài engine):** tạo **SQL View** trên ERP gom join + tính toán, sync view như một nguồn single-table.

---

## 1. Mục tiêu

Xây một **generic sync engine** cho phép onboard một bảng mới sang Central DB **chủ yếu bằng khai báo mapping rule**, không phải viết lại reader/writer/model cho từng bảng.

Một mapping rule phải diễn đạt được:

1. **Bảng nguồn → bảng đích** (tên logical giống convention entity `[Table("...")]` / `ToTable("...")`) — **một nguồn, một đích**.
2. **Danh sách cột cần map**, kèm **kiểu dữ liệu đích** (Postgres).
3. **Logic phức tạp trên single-source:** cắt ghép string, phép tính numeric, biến đổi giá trị (`SourceExpression` / transform C#) — **chỉ cột từ `t0` / một bảng nguồn**.
4. **Metadata sync:** primary key, active-flag / active-predicate, read-filter, sync tier (Hot/Cold) — tái dùng cơ chế Bootstrap + CT đã chốt.
5. **Filter động theo cột + giá trị** qua predicate có cấu trúc (không phụ thuộc raw SQL tùy ý).

> **Không thuộc mục tiêu plan này:** join nhiều bảng nguồn (`JoinSpec`, `t1`, `t2`…) — model đã phác thảo trong §4.2 nhưng **validator chặn** và **không implement** ở Stage 1–6; triển khai ở **plan tiếp theo §14**.

**Kết quả cuối cùng mong đợi:** thêm một bảng vocab 5.3 (hoặc bảng bất kỳ) = **thêm một khai báo rule + (nếu cần) một transform C#**, không đụng vào orchestrator, lock, checkpoint, run-log, Hangfire job.

---

## 2. Hiện trạng & vấn đề

### 2.1. Cái đã generic (giữ nguyên)

Các thành phần sau chỉ làm việc theo `TableSyncConfig.SourceTable` (định danh chuỗi), **không** biết về cột Partner:

| Thành phần | File | Kết luận |
|---|---|---|
| `SyncOrchestrator` | `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs` | Generic — giữ nguyên (Bootstrap → CT theo checkpoint; không thêm mode khác) |
| `ChangeTrackingSyncService` | `.../Services/ChangeTrackingSyncService.cs` | Chỉ dùng `batch.Rows.Count`, `UpperWatermark`, `PreviousCheckpoint` — generic-safe |
| `BootstrapSyncService` | `.../Services/BootstrapSyncService.cs` | Chỉ dùng `snapshot.Rows.Count`, `BaselineVersion` — generic-safe |
|| `PostgresSyncCheckpointStore`, `PostgresTableSyncLock`, `PostgresSyncRunLog`, `CentralDbSyncStatusService` | `Infrastructure/CentralDbSync/*` | Generic theo `source_table` — giữ nguyên |

### 2.2. Cái đang hard-code Partner (phải bóc ra generic)

| Thành phần | Vấn đề |
|---|---|
| `PartnerSourceRow`, `PartnerTargetRow`, `ChangedPartnerRow` | Model cứng theo cột Partner |
| `ChangeBatch` | Đang bọc `IReadOnlyList<ChangedPartnerRow>` — coupling vào Partner |
| `SqlServerPartnersReader` | `SelectColumns`, `SourceTable`, SQL CT join cố định cho `[dbo].[CRM.Partners]` |
| `PostgresPartnersWriter` | `UpsertColumns`, `UpsertValues`, `UpsertUpdateSet`, filter `IsCustomer` — cố định cho `report.partners` |
| `TableSyncConfig` | Không mô tả cột/join/transform — chỉ có định danh + scheduling; sẽ **derive** từ rule |
| `CentralDbSyncJobs`, `CentralDbSyncController` | Config Partner viết tay inline |

**Kết luận:** blast radius của refactor **rất hẹp** — chỉ phần *reader + writer + row models + config*. Toàn bộ luồng điều phối và nhất quán được bảo toàn.

---

## 3. Tư tưởng thiết kế

```
                    ┌──────────────────────────────┐
                    │   Mapping Rule (khai báo)    │  ← nguồn sự thật duy nhất (SSOT)
                    │  source, target, columns,    │
                    │  joins, predicates, schedule │
                    └───────────────┬──────────────┘
                                    │ ToTableSyncConfig() / IMappingRuleProvider
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
┌───────────────┐          ┌────────────────┐          ┌────────────────┐
│ SQL Builder   │          │ Generic Reader │          │ Generic Applier│
│ (SELECT/CT)   │──────────▶ (SQL Server)   │──────────▶ (PostgreSQL)   │
└───────────────┘          └───────┬────────┘          └───────┬────────┘
                                    │ GenericRow[]              │ dynamic UPSERT
                                    ▼                           ▼
                       (services điều phối — GIỮ NGUYÊN) ──────▶ report.<table>
```

Các quyết định cốt lõi (đã chốt 2026-07-20):

1. **Row là dữ liệu động, không phải type cứng.** Thay `PartnerSourceRow` bằng dictionary `column → value`.
2. **`TableMappingRule` = nguồn sự thật duy nhất** (mapping + scheduling). `TableSyncConfig` derive từ rule (`ToTableSyncConfig()`). `sync_meta.table_sync_config` sync từ registry lúc startup (hoặc deprecate dần) — không duy trì hai bản config song song.
3. **Rule là declarative.** Phase 1: C# registry (type-safe, versioned trong Git). DB-stored JSON để ngỏ ở Stage 7 nếu khách cần chỉnh runtime không deploy.
4. **Hai tầng transform.**
   - **Push-down SQL** (ưu tiên): concat/phép tính/join biểu diễn bằng SQL expression trên SQL Server.
   - **C# transform registry** (dự phòng): logic khó/không nên viết bằng SQL.
5. **Tách ReadFilter vs ActivePredicate** (xem §4.2, §9.7) — không gộp một `Filter` SQL duy nhất như bản nháp trước.
6. **Tên bảng nguồn** = chuỗi logical giống entity (`"CRM.Partners"`, `"Report.Definition"`). Builder quote thành `[dbo].[CRM.Partners]` — không cần tách schema/object field.
7. **Chỉ Bootstrap + CT.** Không implement FullRefresh định kỳ. Mọi bảng onboard qua cùng luồng orchestrator hiện có; vocab Phase B cũng Bootstrap lần đầu rồi CT (bật CT trên bảng nguồn ERP).

---

## 4. Mô hình Mapping Rule (proposed)

> Đây là code **mới** (đề xuất), đặt ở Application layer để Domain/Infrastructure cùng tham chiếu contract.

### 4.1. Aggregate rule — SSOT

```csharp
namespace Application.Features.CentralDbSync.Mapping;

public sealed record TableMappingRule
{
    // Định danh rule = checkpoint key (sync_meta.checkpoint.source_table / run-log key).
    // Không bắt buộc trùng PrimaryTable nếu sau này một primary phục vụ nhiều target;
    // pilot Partners: Name = "CRM.Partners".
    public required string Name { get; init; }

    public required SourceSpec Source { get; init; }
    public required TargetSpec Target { get; init; }
    public required IReadOnlyList<ColumnMapping> Columns { get; init; }

    // Scheduling / orchestration — nằm trên rule (SSOT), không nhân đôi nơi khác
    // SyncMode luôn ChangeTracking — derive trong ToTableSyncConfig(); không khai báo trên rule.
    public string SyncTier { get; init; } = "Cold";          // Hot | Cold
    public string[] Dependency { get; init; } = [];          // Rule.Name của upstream
    public TimeSpan ExpectedSyncInterval { get; init; } = TimeSpan.FromHours(1);
    public TimeSpan MaxAllowedLag { get; init; } = TimeSpan.FromHours(2);
    public string OwnershipScope { get; init; } = "erp";
    public bool Enabled { get; init; } = true;

    /// <summary>
    /// Derive TableSyncConfig cho SyncOrchestrator / job / health — không khai báo tay song song.
    /// SourceTable trên config = Rule.Name (checkpoint key), không nhất thiết = PrimaryTable.
    /// </summary>
    public TableSyncConfig ToTableSyncConfig() => new()
    {
        SourceTable = Name,
        TargetSchema = Target.Schema,
        TargetTable = Target.Table,
        SyncMode = "ChangeTracking",   // cố định — mọi bảng Bootstrap + CT
        SyncTier = SyncTier,
        Dependency = Dependency,
        ExpectedSyncInterval = ExpectedSyncInterval,
        MaxAllowedLag = MaxAllowedLag,
        OwnershipScope = OwnershipScope,
        Enabled = Enabled
    };
}
```

### 4.2. Nguồn — join, ReadFilter, ActivePredicate

```csharp
public sealed record SourceSpec
{
    // Logical table name — cùng convention entity:
    //   [Table("Report.Definition")] / ToTable("CRM.Partners")
    // SqlSelectBuilder quote: "CRM.Partners" → [dbo].[CRM.Partners]
    // (không viết FROM CRM.Partners trần — SQL Server hiểu nhầm schema/table).
    public required string PrimaryTable { get; init; }
    public string PrimaryAlias { get; init; } = "t0";

    public IReadOnlyList<JoinSpec> Joins { get; init; } = [];

    // WHERE push-down trên source read (optional).
    // Chỉ dùng khi thật sự không cần đọc row ngoài filter.
    // Partners: để trống — đọc toàn bộ, lifecycle quyết định bởi ActivePredicate.
    public IReadOnlyList<ColumnPredicate> ReadFilter { get; init; } = [];

    // Quyết định is_active SAU khi đã có row (applier / bootstrap).
    // Partners: [ Eq("IsCustomer", true) ] → khớp PostgresPartnersWriter hiện tại.
    // Mọi predicate AND với nhau. Có thể mở rộng OR / nhóm sau nếu cần.
    public IReadOnlyList<ColumnPredicate> ActivePredicate { get; init; } = [];

    // PK của bảng nguồn primary — dùng làm CT key và (qua map cột) upsert conflict key.
    public required IReadOnlyList<string> PrimaryKey { get; init; }  // vd ["PartnerId"]
}

/// <summary>
/// Predicate có cấu trúc — filter động theo cột + giá trị mong muốn.
/// Builder sinh SQL parameterized (@p0, @p1…); không string-concat value.
/// </summary>
public enum PredicateOperator
{
    Eq,
    Neq,
    In,
    NotIn,
    IsNull,
    IsNotNull,
    Gt,
    Gte,
    Lt,
    Lte
}

public sealed record ColumnPredicate
{
    // Tên cột nguồn, có hoặc không alias: "IsCustomer" hoặc "t0.IsCustomer"
    public required string Column { get; init; }
    public required PredicateOperator Operator { get; init; }
    // Scalar hoặc IReadOnlyList<object?> cho In/NotIn; null với IsNull/IsNotNull
    public object? Value { get; init; }
}

public enum JoinKind { Inner, Left }

public sealed record JoinSpec
{
    // Logical name giống PrimaryTable, vd "Configs.Country"
    public required string Table { get; init; }
    public required string Alias { get; init; }          // vd "t1"
    public JoinKind Kind { get; init; } = JoinKind.Left;
    // Escape hatch: điều kiện join do dev khai báo (không nhận input runtime).
    public required string OnCondition { get; init; }    // vd "t1.CountryId = t0.NationalityId"
}
```

**Raw SQL filter:** không còn field `Filter` string trên `SourceSpec`. Nếu sau này cần biểu thức không diễn đạt được bằng `ColumnPredicate`, thêm escape hatch có kiểm soát (review + validator) — ngoài phạm vi mặc định Phase 1.

### 4.3. Đích

```csharp
public sealed record TargetSpec
{
    public string Schema { get; init; } = "report";
    public required string Table { get; init; }          // vd "partners"
    public required IReadOnlyList<string> PrimaryKey { get; init; }  // vd ["partner_id"]
}
```

### 4.4. Cột — nơi diễn đạt map / concat / calc / transform

```csharp
public sealed record ColumnMapping
{
    public required string TargetColumn { get; init; }   // snake_case, vd "full_name"
    public required string TargetType { get; init; }     // Postgres type: text|integer|bigint|boolean|numeric|timestamptz|date

    // Cách lấy giá trị — chọn ĐÚNG MỘT producer cuối cùng:
    public string? SourceColumn { get; init; }           // 1) đơn giản: "t0.Name"
    public string? SourceExpression { get; init; }       // 2) push-down SQL: "CONCAT(t0.Code,' - ',t1.CountryName)"
    public string? Transform { get; init; }              // 3) C#-side: tên transformer đã đăng ký

    // Cột raw mà Transform cần đọc (phải có trong SELECT). Chỉ dùng khi Transform != null.
    public IReadOnlyList<string> TransformDependsOn { get; init; } = [];

    public bool IsPrimaryKey { get; init; }              // cột này thuộc PK đích (upsert conflict key)
    public bool IsActiveFlag { get; init; }              // cột đích nhận giá trị is_active (thường "is_active")
}
```

**Quy ước giá trị cột:**

- Mỗi `TargetColumn` có đúng một producer: `SourceExpression` **hoặc** `SourceColumn` **hoặc** `Transform`.
- Khi dùng `Transform`: SELECT gồm `TransformDependsOn` (+ các `SourceColumn` khác); transformer ghi đè giá trị target sau khi đọc row.
- Cột `IsActiveFlag = true` nhận giá trị từ đánh giá `Source.ActivePredicate` trên row (không hard-code `IsCustomer`).

### 4.5. Row động & batch generic (thay Partner-specific)

```csharp
public sealed record GenericSourceRow(IReadOnlyDictionary<string, object?> Values);

public sealed record GenericChangeRow(
    string Operation,                 // I | U | D
    long ChangeVersion,
    IReadOnlyList<object?> PrimaryKey,
    GenericSourceRow? CurrentValues); // null khi Operation = D

public sealed record GenericChangeBatch(
    long PreviousCheckpoint,
    long UpperWatermark,
    IReadOnlyList<GenericChangeRow> Rows);

public sealed record GenericSnapshot(
    long BaselineVersion,             // dùng cho bootstrap CT
    IReadOnlyList<GenericSourceRow> Rows);
```

> `ChangeBatch`/`BootstrapSnapshot` hiện tại sẽ được **thay bằng** các bản generic này. `IFullRefreshReader` / `FullSnapshot` **nghỉ hưu** — không dùng trong plan này. Do services chỉ đọc `Count`/`Version`, đổi model không phá logic điều phối.

### 4.6. Transform C#-side

```csharp
public interface IValueTransformer
{
    string Name { get; }
    // Nhận toàn bộ raw source row (đã join) → trả giá trị cho một target column.
    object? Transform(IReadOnlyDictionary<string, object?> sourceRow);
}

public interface IValueTransformerRegistry
{
    IValueTransformer Resolve(string name);   // ném nếu không tìm thấy → fail-fast lúc validate
}
```

### 4.7. Ví dụ rule Partners (khớp hành vi pilot hiện tại)

```csharp
new TableMappingRule
{
    Name = "CRM.Partners",
    Source = new SourceSpec
    {
        PrimaryTable = "CRM.Partners",
        PrimaryKey = ["PartnerId"],
        ReadFilter = [],  // đọc toàn bộ source
        ActivePredicate =
        [
            new ColumnPredicate
            {
                Column = "IsCustomer",
                Operator = PredicateOperator.Eq,
                Value = true
            }
        ]
    },
    Target = new TargetSpec
    {
        Schema = "report",
        Table = "partners",
        PrimaryKey = ["partner_id"]
    },
    Columns =
    [
        new() { TargetColumn = "partner_id", TargetType = "integer", SourceColumn = "t0.PartnerId", IsPrimaryKey = true },
        new() { TargetColumn = "company_id", TargetType = "integer", SourceColumn = "t0.CompanyId" },
        new() { TargetColumn = "code", TargetType = "text", SourceColumn = "t0.Code" },
        new() { TargetColumn = "name", TargetType = "text", SourceColumn = "t0.Name" },
        new() { TargetColumn = "is_customer", TargetType = "boolean", SourceColumn = "t0.IsCustomer" },
        // ... các cột còn lại ...
        new() { TargetColumn = "is_active", TargetType = "boolean", IsActiveFlag = true }
    ],
    SyncTier = "Hot",
    ExpectedSyncInterval = TimeSpan.FromMinutes(1),
    MaxAllowedLag = TimeSpan.FromMinutes(5),
    OwnershipScope = "erp",
    Enabled = true
};
```

Lifecycle tương đương writer hiện tại:

| Tình huống | Hành vi |
|---|---|
| Row tồn tại + `ActivePredicate` true | upsert, `is_active = true` |
| Row tồn tại + `ActivePredicate` false | `is_active = false` (filter-out) |
| CT operation `D` | `is_active = false` |
| Bootstrap: PK không có trong snapshot (ownership scope) | `is_active = false` |

---

## 5. Kiến trúc & luồng dữ liệu

```
Hangfire (queue data-sync)
   └─ CentralDbSyncJobs.RunAsync
        └─ configs = registry.GetAll().Where(Enabled).Select(ToTableSyncConfig)
        └─ SyncOrchestrator.ExecuteAsync(configs)          [GIỮ NGUYÊN — Bootstrap → CT]
             ├─ per-table lock (ITableSyncLock)            [GIỮ NGUYÊN]
             ├─ checkpoint state (ISyncCheckpointStore)    [GIỮ NGUYÊN] key = Rule.Name
             ├─ Bootstrap / ChangeTracking service         [GIỮ NGUYÊN]
             │     ├─ IBootstrapSnapshotReader ─┐
             │     └─ IChangeTrackingReader ────┴─▶ SqlServerGenericReader  ◀── TableMappingRule
             │                                        (dùng SqlSelectBuilder)
             └─ ISyncBatchApplier ─────────────────▶ PostgresGenericApplier ◀── TableMappingRule
                                                          (ActivePredicate + UpsertSqlBuilder)
```

- **SSOT:** Job / Controller / health lấy danh sách từ `IMappingRuleProvider` → `ToTableSyncConfig()`. Không khai báo `TableSyncConfig` inline song song với rule.
- **Checkpoint key** = `Rule.Name` (ghi vào `sync_meta.checkpoint.source_table`). Pilot: `"CRM.Partners"`.
- **`sync_meta.table_sync_config`:** lúc startup, upsert từ registry (đồng bộ metadata cho quan sát SQL) **hoặc** deprecate dần sau khi health đọc trực tiếp registry — chọn một hướng ở Stage 1; khuyến nghị sync-at-startup trước để ít phá health hiện có.
- **Reader/Applier** resolve `TableMappingRule` theo `config.SourceTable` (= `Rule.Name`).

---

## 6. Folder / file structure đích

`★` = tạo mới · `~` = sửa · `✗` = xóa/nghỉ hưu sau khi migrate

```
Application/Features/CentralDbSync/
  Mapping/                                   ★ (feature con mới)
    TableMappingRule.cs                      ★ aggregate rule + ToTableSyncConfig()
    SourceSpec.cs                            ★ primary table + joins + ReadFilter + ActivePredicate + PK
    ColumnPredicate.cs                       ★ Column + Operator + Value
    PredicateOperator.cs                     ★ enum
    JoinSpec.cs                              ★
    TargetSpec.cs                            ★
    ColumnMapping.cs                         ★ target col + type + source/expr/transform
    IMappingRuleProvider.cs                  ★ Get(ruleName) / GetAll()
    IValueTransformer.cs                     ★
    IValueTransformerRegistry.cs             ★
    MappingRuleValidator.cs                  ★ validate rule lúc startup
  Models/
    GenericSourceRow.cs                      ★
    GenericChangeRow.cs                      ★
    GenericChangeBatch.cs                    ★ (thay ChangeBatch)
    GenericSnapshot.cs                       ★ (thay BootstrapSnapshot)
    PartnerSourceRow.cs / PartnerTargetRow.cs / ChangedPartnerRow.cs   ✗ (sau migrate)
    ChangeBatch.cs / BootstrapSnapshot.cs / FullSnapshot.cs            ~ hoặc ✗
  Abstractions/
    IChangeTrackingReader.cs                 ~ trả GenericChangeBatch
    IBootstrapSnapshotReader.cs              ~ trả GenericSnapshot
    ISyncBatchApplier.cs                     ~ nhận GenericChangeBatch/GenericSnapshot
    IFullRefreshReader.cs                    ✗ nghỉ hưu — không dùng
  Models/ (hoặc giữ)
    TableSyncConfig.cs                       ~ derive-only từ rule; không còn nguồn khai báo song song
  Config/
    TableMappingRegistry.cs                  ★ nơi khai báo tất cả rule (Partners, vocab 5.3)
  Transformers/                              ★
    ConcatTransformer.cs                       ví dụ transform C# (nếu cần)
    ...

Infrastructure/CentralDbSync/
  Sql/                                       ★
    SqlSelectBuilder.cs                      ★ SELECT full + CT-join; QuoteSqlServerTable; ReadFilter → WHERE params
    UpsertSqlBuilder.cs                      ★ INSERT..ON CONFLICT + deactivate theo PK động
    PostgresTypeMap.cs                       ★ map TargetType → Npgsql/DDL type
    PredicateSqlBuilder.cs                   ★ (optional tách) ColumnPredicate[] → SQL + params
  SqlServerGenericReader.cs                  ★ IBootstrap + IChangeTracking (thay SqlServerPartnersReader)
  PostgresGenericApplier.cs                  ★ ISyncBatchApplier + ActivePredicate (thay PostgresPartnersWriter)
  TableSyncConfigSynchronizer.cs             ★ (optional) upsert sync_meta.table_sync_config từ registry lúc startup
  SqlServerPartnersReader.cs                 ✗ (sau migrate)
  PostgresPartnersWriter.cs                  ✗ (sau migrate)
  CentralDbSyncInfrastructureExtensions.cs   ~ đăng ký generic reader/applier + registry + transformers
  CentralDbSyncJobs.cs                       ~ registry.GetAll() → ToTableSyncConfig()
  DdlGenerator.cs                            ★ (optional) sinh CREATE TABLE target từ rule

Infrastructure/Database/SqlScript/CentralDbSync/
  001-central-db-sync-schema.sql             ~ (nếu thêm sync_meta.table_mapping_rule cho Phase DB-stored)
  004-generic-<table>.sql                    ★ DDL target cho từng bảng mới (hoặc sinh tự động)

WebApi/
  Controllers/CentralDbSyncController.cs     ~ dùng registry, bỏ config inline
  Program.cs                                 ~ đăng ký job theo registry (Hot/Cold cron; mọi bảng Bootstrap + CT)

Tests/Ua.Application.UnitTests/CentralDbSync/
  MappingRuleValidatorTests.cs               ★
  ColumnPredicateSqlTests.cs                 ★ ReadFilter / ActivePredicate → SQL param-safe
  SqlSelectBuilderTests.cs                   ★ gồm QuoteSqlServerTable("CRM.Partners")
  UpsertSqlBuilderTests.cs                   ★
  GenericApplierTests.cs                     ★ ActivePredicate lifecycle
  (các test Partner hiện có)                 ~ chuyển sang assert qua rule
```

---

## 7. Vai trò từng thành phần

| Thành phần | Mục đích | Ghi chú thiết kế |
|---|---|---|
| `TableMappingRule` | **SSOT** — mapping + scheduling + lifecycle predicates | Immutable; `Name` = checkpoint key; `ToTableSyncConfig()` |
| `SourceSpec` + `JoinSpec` | 1..n bảng nguồn, PK, ReadFilter, ActivePredicate | `PrimaryTable` = logical name entity-style |
| `ColumnPredicate` | Filter động theo cột + giá trị | Parameterized; dùng cho ReadFilter và ActivePredicate |
| `TargetSpec` | Bảng/schema/PK đích | PK đích ↔ conflict key upsert |
| `ColumnMapping` | Map cột / concat / calc / transform + kiểu đích | Đúng một producer / cột; `IsActiveFlag` nhận kết quả ActivePredicate |
| `IMappingRuleProvider` / `TableMappingRegistry` | Cấp rule theo tên, liệt kê tất cả | Nơi duy nhất dev thêm bảng mới |
| `IValueTransformer(Registry)` | Logic C# không tiện viết SQL | Resolve theo tên, fail-fast |
| `MappingRuleValidator` | Chặn rule sai trước khi chạy | PK, trùng target col, transform resolve, đúng 1 producer, **chặn join** (§9.4) |
| `GenericSourceRow/ChangeRow/ChangeBatch/Snapshot` | Row động thay type cứng | Dictionary-based |
| `SqlSelectBuilder` | Sinh SELECT full & CT join từ rule | `QuoteSqlServerTable`; áp `ReadFilter` vào WHERE; giữ `UpperWatermark` |
| `UpsertSqlBuilder` | Sinh upsert + deactivate theo PK động | Bảo toàn atomic apply + checkpoint |
| `PostgresTypeMap` | TargetType → kiểu Npgsql param & DDL | Trung tâm hóa mapping kiểu |
| `SqlServerGenericReader` | Đọc ERP theo rule, trả generic rows | Giữ READPAST + recheck (đã chốt) |
| `PostgresGenericApplier` | Ghi Postgres theo rule + ActivePredicate | Optimistic guard; lifecycle §4.7 |
| `DdlGenerator` (optional) | Sinh `CREATE TABLE` target từ rule | Biến "thêm bảng" thành thực sự config-only |

---

## 8. Các giai đoạn triển khai

Chia nhỏ, mỗi stage build & test độc lập, không làm gãy pilot Partner đang chạy cho tới stage migrate.

### Stage 0 — Chốt thiết kế & guardrail (0.5 ngày) — **đã xong 2026-07-20**
- **Việc:** review model §4; ghi quyết định vào phụ lục.
- **Kết quả:** xem **Phụ lục — Quyết định** (đã điền).

### Stage 1 — Mapping rule model + validator (1–1.5 ngày)
- **Việc:** tạo toàn bộ record ở `Application/.../Mapping/` (gồm `ColumnPredicate`); `IMappingRuleProvider` + `TableMappingRegistry` (khai báo **rule Partners** §4.7); `MappingRuleValidator`; `ToTableSyncConfig()`; (optional) synchronizer `sync_meta.table_sync_config`.
- **File:** `Mapping/*.cs`, `Config/TableMappingRegistry.cs`.
- **Test:** `MappingRuleValidatorTests` — thiếu PK, trùng target col, nhiều producer, transform thiếu, **join bị chặn**; predicate `In`/`Eq` hợp lệ.
- **Kết quả mong đợi:** compile được; validator bắt lỗi khai báo; **chưa** đụng reader/writer → pilot vẫn chạy.

### Stage 2 — Generic row models + đổi abstractions (0.5–1 ngày)
- **Việc:** thêm `GenericSourceRow/ChangeRow/ChangeBatch/Snapshot`; đổi chữ ký reader/applier sang generic.
- **File:** `Models/Generic*.cs`, `Abstractions/*.cs`.
- **Lưu ý:** khuyến nghị **gộp branch với Stage 3–4** để không commit trạng thái gãy.
- **Kết quả mong đợi:** interface generic sẵn sàng; services chỉ sửa kiểu tham số.

### Stage 3 — SQL builders + PostgresTypeMap (1.5–2 ngày)
- **Việc:**
  - `PostgresTypeMap`: `TargetType` → Npgsql + DDL.
  - `QuoteSqlServerTable("CRM.Partners")` → `[dbo].[CRM.Partners]` (unit test bắt buộc).
  - `SqlSelectBuilder`: SELECT full (cột + join + **ReadFilter → WHERE params**); SELECT CT với `CHANGETABLE` + join PK (+ joins) + `SYS_CHANGE_VERSION <= @upperWatermark`.
  - `UpsertSqlBuilder`: `INSERT..ON CONFLICT` + deactivate theo PK động + orphan bootstrap theo ownership scope.
- **File:** `Infrastructure/CentralDbSync/Sql/*.cs`.
- **Test:** snapshot SQL single/join; ReadFilter param-safe; không string-concat value.
- **Kết quả mong đợi:** sinh SQL đúng, verify không cần DB.

### Stage 4 — Generic reader + applier (2 ngày)
- **Việc:** `SqlServerGenericReader` (`IBootstrapSnapshotReader` + `IChangeTrackingReader`; UpperWatermark; min-valid → `CheckpointInvalidException`; READPAST+recheck). `PostgresGenericApplier` (**đánh giá ActivePredicate**, upsert/deactivate, optimistic guard, `IsTransient`). Nghỉ hưu `IFullRefreshReader`.
- **DI:** đăng ký generic; registry; validator lúc startup; job lấy config từ `ToTableSyncConfig()`.
- **Kết quả mong đợi:** Partner chạy **qua rule**.

### Stage 5 — Migrate pilot Partners sang rule + retire code cũ (1 ngày)
- **Việc:** xác nhận rule §4.7 khớp hành vi cũ (`IsCustomer` → `is_active`, orphan, CT). Xóa reader/writer/model Partner-specific. Controller/Jobs chỉ dùng registry.
- **Test:** regression bootstrap + CT + no-change + concurrent checkpoint + filter-out non-customer.
- **Kết quả mong đợi:** mốc nghiệm thu **"generic base" hoàn tất**.

### Stage 6 — Chứng minh onboard bảng thứ hai (1–1.5 ngày)
- **Việc:** thêm một rule vocab single-source (vd `Configs.Season`) vào registry; bật CT trên bảng nguồn ERP; đăng ký Hangfire job (tier Cold nếu cần). Chứng minh Bootstrap → CT qua cùng generic reader/applier, không sửa orchestrator.
- **Kết quả mong đợi:** onboard bảng mới chỉ bằng rule + DDL + script bật CT — không viết reader/writer riêng.

### Stage 7 (optional) — DDL generator & DB-stored rule (2–3 ngày, Phase sau)
- **Việc:** `DdlGenerator`; (optional) `sync_meta.table_mapping_rule` JSON.
- **Kết quả mong đợi:** config-only / chỉnh rule không deploy.

---

## 9. Xử lý các case phức tạp (đặc tả)

### 9.1. Single source → single target
`Source.Joins = []`; mỗi `ColumnMapping.SourceColumn = "t0.<Col>"`. Đây là mẫu vocab 5.3.

### 9.2. Multi-source join → một target (plan tiếp theo §14)
Khai báo `Source.Joins` với alias `t1, t2...` và `OnCondition` — **ngoài phạm vi implement plan này** (validator chặn ở Stage 1–6). Chi tiết phase kế tiếp: **§14**.

### 9.3. Cắt ghép string / phép tính numeric (single-source)
- **Push-down SQL (khuyến nghị)** — chỉ cột từ bảng primary `t0` trong plan này:
  `ColumnMapping { TargetColumn="display", TargetType="text", SourceExpression="CONCAT(t0.Code,' - ',t0.Name)" }`
  `ColumnMapping { TargetColumn="total", TargetType="numeric", SourceExpression="t0.Qty * t0.UnitPrice" }`
- **C# transform:** `Transform` + `TransformDependsOn`; validator đảm bảo cột phụ thuộc có trong SELECT.
- Biểu thức dùng `t1`, `t2` (join) thuộc **plan tiếp theo §14**, không implement ở Stage 1–6.

### 9.4. Change Tracking khi target join nhiều nguồn — GIỚI HẠN QUAN TRỌNG
CT chỉ bật trên **một** bảng (`Source.PrimaryTable`). Thay đổi ở bảng **join phụ** không sinh CT trên primary → target có thể stale.

**Quy tắc Phase 1 (Bootstrap + CT only):**
- Rule **có join** (`Source.Joins` không rỗng) ⇒ **validator chặn** — ngoài phạm vi implement plan này.
- Chỉ rule **single-source** (`Joins = []`) được onboard.
- Multi-source join target là **plan tiếp theo §14**; workaround tạm = SQL View trên ERP.

Vocab 5.3 đa số single-source → phù hợp Bootstrap + CT. Bảng cần join/aggregate (vd `cmp_sections`) xử lý ở phase sau.

### 9.5. Kiểu dữ liệu
`PostgresTypeMap` quy đổi `TargetType` → `NpgsqlDbType` / DDL. Ép kiểu SQL Server → target khi đọc/applier theo `TargetType`.

### 9.6. Bảo toàn contract nhất quán (không được vi phạm)
- Chụp `UpperWatermark` **trước** khi đọc CT; chỉ đọc `SYS_CHANGE_VERSION <= UpperWatermark`.
- Apply data + advance checkpoint **một** PostgreSQL transaction, optimistic guard.
- Bootstrap: baseline + snapshot cùng transaction SQL Server — **READPAST + recheck** (đã chốt; xem note 2026-07-19).
- Upsert/deactivate idempotent theo PK.

### 9.7. ReadFilter vs ActivePredicate (lifecycle)
| | `ReadFilter` | `ActivePredicate` |
|---|---|---|
| Khi nào | Optional — thật sự không cần row ngoài tập | Luôn dùng khi target có soft-active |
| Áp dụng ở | SQL Server SELECT / CT join (`WHERE` param) | Applier / bootstrap sau khi có row |
| Partners | `[]` (đọc all) | `IsCustomer == true` |
| Dynamic | Nhiều `ColumnPredicate` (AND) theo cột + giá trị | Cùng model predicate |

Không dùng một raw SQL `Filter` duy nhất để vừa cắt read vừa quyết định `is_active` — đó là nguồn lệch so với design Partners.

### 9.8. Tên bảng nguồn (logical → SQL)
- Trong rule: chuỗi giống entity / Fluent `ToTable`, vd `"CRM.Partners"`, `"Report.Definition"`.
- Trong builder: một helper `QuoteSqlServerTable(name)` → `[dbo].[{name}]`.
- Không bắt buộc field Schema/Object riêng. Đủ để nhận biết và sinh SQL an toàn với tên có dấu chấm.

---

## 10. Workflow onboard một bảng mới (payoff)

Sau khi engine hoàn tất, thêm một bảng =:

1. **Khai báo rule** trong `TableMappingRegistry` (source, target, columns, ReadFilter/ActivePredicate, tier).
2. **Tạo bảng đích** Postgres — `DdlGenerator` (Stage 7) hoặc `004-<table>.sql`.
3. **Bật Change Tracking** trên bảng nguồn ERP (`ENABLE CHANGE_TRACKING`).
4. **(Nếu cần) viết transformer C#** cho cột phức tạp.
5. Job tự lấy từ registry (`GetAll` + `ToTableSyncConfig`) — không sửa inline config.
6. Chạy — **Bootstrap lần đầu → CT định kỳ**; quan sát `sync_meta.sync_run_log` + `/hangfire`.

**Không** phải: viết reader, viết writer, viết row model, sửa orchestrator/lock/checkpoint.

---

## 11. Chiến lược test

| Loại | Trọng tâm |
|---|---|
| Unit — validator | rule sai bị chặn lúc startup |
| Unit — predicate / SQL builders | ReadFilter/ActivePredicate param-safe; QuoteSqlServerTable; SELECT/CT/upsert |
| Unit — applier | ActivePredicate lifecycle + atomic apply + optimistic guard |
| Integration (Postgres testcontainer) | bootstrap → CT → no-change → concurrent checkpoint qua đường generic |
| Regression | Partner qua rule = hành vi code cũ (gồm non-customer deactivate) |

---

## 12. Rủi ro & quyết định

| Vấn đề | Hướng xử lý |
|---|---|
| CT + join phụ bị stale (§9.4) | Phase 1 chặn rule có join; single-source only |
| `SourceExpression` / `OnCondition` raw SQL | Chỉ dev khai báo; không interpolate value người dùng; predicate value luôn param |
| Hai nguồn config lệch nhau | **Đã chốt:** rule = SSOT; config derive; DB sync-at-startup hoặc deprecate |
| Filter/lifecycle lệch Partners | **Đã chốt:** tách ReadFilter / ActivePredicate (§9.7) |
| Tên bảng có dấu chấm | **Đã chốt:** logical string + `QuoteSqlServerTable` (§9.8) |
| Bootstrap isolation | **Đã chốt:** READPAST + recheck |
| Snapshot lớn không fit memory | Staging-table theo `run_id` nếu vượt ngưỡng (đo trước) |

## 13. Ngoài phạm vi plan này (backlog ngắn hạn)

- UI quản trị mapping rule.
- Tự động chạy DDL bằng runtime sync account (giữ nguyên nguyên tắc security design).
- Raw SQL `Filter` string trên `SourceSpec` (dùng `ColumnPredicate`; escape hatch sau nếu thật sự cần).
- DB-stored rule JSON / chỉnh rule không deploy (Stage 7 optional).

## 14. Plan tiếp theo — Multi-source join & mapping phức tạp (sau khi hoàn thành Stage 1–6)

**Xác nhận (2026-07-20):** Plan hiện tại **không implement** join nhiều bảng nguồn thành một bảng đích. Phần này là **phase kế tiếp**, bắt đầu sau khi generic engine single-source (Partners + vocab single-table) đã chạy ổn định.

### 14.1. Vấn đề cần giải quyết

- `Source.Joins` + `JoinSpec` + `OnCondition` — join 2+ bảng ERP trong một rule.
- `SourceExpression` / map cột lấy giá trị từ `t0`, `t1`, `t2`…
- Transform / tính toán trên dữ liệu đã join trước khi ghi Postgres.
- Aggregate / DISTINCT (vd `cmp_sections` từ `CMP.Operations`).
- Chính sách **Bootstrap + CT** khi chỉ primary bật CT — thay đổi bảng join phụ không sinh CT trên primary (§9.4).

### 14.2. Tiền đề (phải có trước khi bắt phase này)

- [ ] Stage 1–6 của plan này **hoàn tất** (generic reader/applier, Partners regression, ít nhất 1 bảng vocab single-source).
- [ ] Danh sách bảng **thật sự cần join** (không workaround được bằng SQL View).
- [ ] Chốt chính sách CT với join: (a) chấp nhận stale bảng phụ + bootstrap định kỳ thủ công, (b) bật CT nhiều bảng, hoặc (c) hybrid khác.

### 14.3. Hướng implement dự kiến (chưa chi tiết — plan riêng)

| Hạng mục | Nội dung |
|---|---|
| `SqlSelectBuilder` | Sinh `JOIN` từ `JoinSpec`; SELECT/CT query có alias `t1`, `t2` |
| `MappingRuleValidator` | Cho phép `Joins` không rỗng; validate `OnCondition`, cột tham chiếu |
| CT reader | Join PK source trong `CHANGETABLE` query; document giới hạn stale |
| Applier | Không đổi contract atomic apply + checkpoint |
| Test | Rule join 2 bảng; regression CT khi bảng phụ đổi |

### 14.4. Workaround cho đến khi có phase join

Nếu cần join **trước** khi phase §14 sẵn sàng:

1. Tạo **VIEW** (hoặc indexed view) trên SQL Server ERP gom join + tính toán.
2. Khai báo rule single-source trỏ vào view (`PrimaryTable = "vw_..."`).
3. Bootstrap + CT trên view / bảng gốc theo thiết kế DBA.

Đây là giải pháp **ngoài engine**, không thay thế implement `JoinSpec` trong phase sau.

---

## Phụ lục — Quyết định (chốt 2026-07-20)

- [x] **Rule storage:** code-registry (Phase 1); DB-stored để ngỏ Stage 7
- [x] **Bootstrap isolation:** READPAST + recheck (`docs/notes/2026-07-19-snapshot-isolation-decision.md`)
- [x] **Transform mặc định:** push-down SQL; C# registry dự phòng
- [x] **Config SSOT:** `TableMappingRule` duy nhất; `TableSyncConfig` = `ToTableSyncConfig()`; `sync_meta.table_sync_config` sync từ registry lúc startup hoặc deprecate dần
- [x] **Checkpoint key:** `Rule.Name`
- [x] **Filter / lifecycle:** tách `ReadFilter` (WHERE push-down, optional) và `ActivePredicate` (quyết định `is_active`); cả hai dùng `ColumnPredicate` (cột + operator + giá trị, parameterized)
- [x] **Tên bảng nguồn:** chuỗi logical giống `[Table("...")]` / `ToTable("...")`; builder `QuoteSqlServerTable` → `[dbo].[name]`
- [x] **Chiến lược sync:** Bootstrap + Change Tracking only — **không** FullRefresh định kỳ (2026-07-20)
- [x] **SyncMode metadata:** luôn `ChangeTracking` trong `ToTableSyncConfig()`; không khai báo trên rule
- [x] **Multi-source join:** **ngoài phạm vi** plan này (Stage 1–6); phase kế tiếp §14; workaround = SQL View trên ERP
- [ ] **Bảng chứng minh Stage 6:** __________ (điền khi bắt đầu Stage 6)

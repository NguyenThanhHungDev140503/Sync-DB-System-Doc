# CT Implementation Analysis: CRM.Partners

**Ngày:** 2026-07-18
**DB:** UA-DEV-2026-T04S3
**Bảng nguồn:** `dbo.[CRM.Partners]`

## 1. Schema bảng nguồn

| Đặc điểm | Giá trị |
|---|---|
| PK | `PartnerId` (int, identity) — single-column PK |
| Số cột | ~80+ cột |
| Filter cột | `IsCustomer` (bit), `IsSupplier` (bit) |
| CT state hiện tại | Chưa bật (DB-level và table-level đều chưa) |
| `CHANGE_TRACKING_CURRENT_VERSION()` | `NULL` |

### Danh sách cột đầy đủ

```
PartnerId (int, PK, identity)
CompanyId (int)
Name (nvarchar 600)
Code (nvarchar 200)
IsCustomer (bit)
IsSupplier (bit)
CreatedByUserId (int)
CreatedDate (datetime)
UpdatedByUserId (int)
UpdatedDate (datetime)
Address (nvarchar 1000)
Phone (nvarchar 100)
Email (nvarchar 1000)
TaxCode (nvarchar 200)
CompanyName (nvarchar 600)
ContactName (nvarchar 600)
Description (nvarchar 4000)
ManageUserIds (nvarchar 1000)
DebtUserIds (nvarchar 1000)
FoundByUserIds (nvarchar 1000)
GroupId (int)
SourceId (int)
TypeId (int)
Deputy (nvarchar 600)
Anniversary (datetime)
Version (int)
AccountIdPartner_Customer (int)
Activated (bit)
CreatedSession (tinyint)
UpdatedBySession (tinyint)
CompanyAddress (nvarchar 1000)
CompanyCode (nvarchar 200)
Summary_Total_Order (int)
Summary_Total_Purchase_Money (money)
Summary_Debt (money)
Summary_Point (money)
ContinentId (int)
NationalityId (int)
RegionId (int)
ProvinceId (int)
DistrictId (int)
WardId (int)
ContactPhone (nvarchar 40)
Website (nvarchar 1000)
BankName (nvarchar 1000)
BankAddress (nvarchar 2000)
BankAccount (nvarchar 200)
BankNumber (nvarchar 100)
SwiftCode (nvarchar 100)
NumberEmployee (money)
DeliveryId (int)
DeliveryAdress (nvarchar 1000)
DeliveryWard (nvarchar 1000)
DeliveryDistrict (nvarchar 1000)
DeliveryProvince (nvarchar 1000)
DeliveryPerson (nvarchar 1000)
DeliveryPhone (nvarchar 100)
DeliveryEmail (nvarchar 200)
CargoReady (datetime)
AgentType (tinyint)
Commisssion (nvarchar 600)
PaymentTerm (nvarchar 1000)
Confirmation (nvarchar 4000)
OtherNote (nvarchar 4000)
TypeOfEntity (tinyint)
Principal (nvarchar 1000)
WastagePercent (money)
BrandName (nvarchar 500)
YearFounded (int)
Location (nvarchar 500)
InstagramFollowing (int)
Commission (money)
ScorePoint (money)
QualityAgreementId (int)
EnterpriseSizeId (int)
HasCreditCheck (bit)
ShippingManual (nvarchar 500)
HasInsurance (bit)
HasContractAgreement (bit)
HasAuditRequirement (bit)
HasCalendarCadence (bit)
Deposit (money)
AtShipment (money)
AfterShipment (money)
Shipment (int)
ShippingToleranceMinus (money)
ShippingTolerancePlus (money)
BrandCategory (nvarchar 500)
StoreType (nvarchar 500)
ExpectAnnualUnits (int)
ExpectAnnualRevenue (money)
AverageFob (money)
IntroductionYear (int)
SgaFactor (float)
CmpFactor (float)
ApplyCostingConfig (bit)
CostingRateId (int)
IsOutsourceSupplier (bit)
LogoPath (nvarchar 1000)
PaymentTermId (int)
Domain (nvarchar 20)
```

## 2. Các bước implement CT

### Bước 1: Bật Change Tracking

**Bắt buộc cả 2 level**, nhưng với vai trò khác nhau:

**DB Level** — điều kiện tiên quyết, chỉ chạy 1 lần:
```sql
ALTER DATABASE [UA-DEV-2026-T04S3]
SET CHANGE_TRACKING = ON
(CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
```

Không có bước này, `ENABLE CHANGE_TRACKING` ở table level sẽ báo lỗi.

**Table Level** — bật cho từng bảng cần track:
```sql
ALTER TABLE [CRM.Partners]
ENABLE CHANGE_TRACKING
WITH (TRACK_COLUMNS_UPDATED = OFF);
```

Thứ tự: DB level trước → table level sau. Cả hai đều là DDL nên phải do DBA chạy (sync user chỉ có `SELECT` + `VIEW CHANGE TRACKING`).

### Bước 2: Bootstrap — lấy baseline và full snapshot

Flow quan trọng nhất, quyết định tính đúng đắn của toàn bộ pipeline:

```
1. Acquire per-table lock (PostgreSQL advisory lock: central-db-sync:CRM.Partners)
2. Mở SqlConnection → ERP primary
3. SET TRANSACTION ISOLATION LEVEL SNAPSHOT
4. BEGIN TRANSACTION
5. Capture baseline = CHANGE_TRACKING_CURRENT_VERSION()     ← chụp TRƯỚC
6. SELECT * FROM [CRM].[Partners]                            ← đọc TOÀN BỘ
7. COMMIT source transaction
8. Mở PostgreSQL transaction
9. Upsert toàn bộ snapshot + set is_active theo filter IsCustomer
10. Set checkpoint = baseline, sync_status = 'ready'
11. COMMIT PostgreSQL transaction
12. Release lock
```

### Baseline là gì và được lưu ở đâu

`baseline` là **số version Change Tracking hiện tại của SQL Server tại thời điểm bắt đầu bootstrap**:

```sql
SELECT CHANGE_TRACKING_CURRENT_VERSION();
-- Ví dụ kết quả: 1000
```

SQL Server cấp một `SYS_CHANGE_VERSION` tăng dần cho các thay đổi trên bảng đã bật CT. Baseline là mốc trả lời câu hỏi: **"full snapshot này đã bao phủ source state đến version nào?"**

- Baseline **được sinh ở SQL Server** bởi `CHANGE_TRACKING_CURRENT_VERSION()`.
- Baseline **không được ghi lại vào bảng nguồn SQL Server**.
- Sau khi full snapshot được ghi thành công, ứng dụng lưu số này thành `last_sync_version` / checkpoint trong PostgreSQL: `sync_meta.checkpoint`.
- CT cycle sau đọc checkpoint từ PostgreSQL và truyền lại vào SQL Server: `CHANGETABLE(CHANGES [CRM].[Partners], @last_checkpoint)`; SQL Server trả các change có version **lớn hơn** checkpoint.

```
Bootstrap:
SQL Server: CHANGE_TRACKING_CURRENT_VERSION() = 1000
PostgreSQL: sync_meta.checkpoint.last_sync_version = 1000

CT cycle kế tiếp:
PostgreSQL đọc checkpoint 1000
        │
        └──► SQL Server: CHANGETABLE(CHANGES [CRM].[Partners], 1000)
                    └──► trả change có SYS_CHANGE_VERSION > 1000
```

Ví dụ: baseline `1000` được chụp, full snapshot có 500 Partners và được ghi sang PostgreSQL. Nếu một Partner thay đổi sau đó tại version `1001`, lần CT kế tiếp đọc từ `1000` nên sẽ bắt đúng change `1001`.

### Vì sao baseline phải chụp trước snapshot

Điểm mấu chốt: `baseline` phải được chụp **trước** khi đọc full snapshot, và cả hai phải nằm trong **cùng một SNAPSHOT transaction**. Nếu không, có thể bỏ sót change xảy ra giữa hai thao tác.

**Giải thích chi tiết:**

```
Timeline nếu LÀM ĐÚNG (baseline trước, cùng transaction):
─────────────────────────────────────────────────────────
[Tx bắt đầu]──baseline=V────SELECT all rows────[Tx commit]
                                           │
              Ngoài tx: UPDATE CRM.Partners │ (V+1)
                                           │
              → Lần CT sau: đọc từ V, bắt được change V+1 ✓

Nếu làm SAI #1 (baseline SAU khi đọc, khác transaction):
─────────────────────────────────────────────────────────
[Tx1]──SELECT all rows────[commit]──baseline=V────
   │                                        │
   │   UPDATE CRM.Partners (V+1)            │ ← change này ở giữa
   │                                        │
   → Snapshot không có change V+1, nhưng baseline=V bỏ qua nó
   → Mất change vĩnh viễn ✗

Nếu làm SAI #2 (cùng transaction nhưng baseline SAU):
─────────────────────────────────────────────────────────
[Tx]──SELECT all rows────baseline=V────[commit]
   │                    │
   │   UPDATE (V+1)     │ ← SNAPSHOT isolation: tx không thấy change này
   │                    │
   → Giống sai #1: snapshot thiếu change, baseline bỏ qua ✗
```

Lý do dùng `SNAPSHOT isolation` thay vì `READ COMMITTED` mặc định:
- `READ COMMITTED`: mỗi câu SELECT thấy một snapshot khác nhau → full snapshot có thể lẫn row cũ và mới
- `SNAPSHOT`: toàn bộ transaction thấy đúng một phiên bản của data tại thời điểm bắt đầu → consistency tuyệt đối

SQL bootstrap:
```sql
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRANSACTION;

DECLARE @baseline bigint = CHANGE_TRACKING_CURRENT_VERSION();

SELECT PartnerId, CompanyId, Name, Code, IsCustomer, IsSupplier,
       CreatedByUserId, CreatedDate, UpdatedByUserId, UpdatedDate,
       Address, Phone, Email, TaxCode, CompanyName, ContactName,
       Description, ManageUserIds, DebtUserIds, FoundByUserIds,
       GroupId, SourceId, TypeId, Deputy, Anniversary, Version,
       AccountIdPartner_Customer, Activated, CreatedSession, UpdatedBySession,
       CompanyAddress, CompanyCode,
       Summary_Total_Order, Summary_Total_Purchase_Money, Summary_Debt, Summary_Point,
       ContinentId, NationalityId, RegionId, ProvinceId, DistrictId, WardId,
       ContactPhone, Website, BankName, BankAddress, BankAccount, BankNumber, SwiftCode,
       NumberEmployee, DeliveryId, DeliveryAdress, DeliveryWard, DeliveryDistrict,
       DeliveryProvince, DeliveryPerson, DeliveryPhone, DeliveryEmail, CargoReady,
       AgentType, Commisssion, PaymentTerm, Confirmation, OtherNote, TypeOfEntity,
       Principal, WastagePercent, BrandName, YearFounded, Location,
       InstagramFollowing, Commission, ScorePoint,
       QualityAgreementId, EnterpriseSizeId,
       HasCreditCheck, ShippingManual, HasInsurance, HasContractAgreement,
       HasAuditRequirement, HasCalendarCadence,
       Deposit, AtShipment, AfterShipment, Shipment,
       ShippingToleranceMinus, ShippingTolerancePlus,
       BrandCategory, StoreType, ExpectAnnualUnits, ExpectAnnualRevenue,
       AverageFob, IntroductionYear, SgaFactor, CmpFactor,
       ApplyCostingConfig, CostingRateId, IsOutsourceSupplier,
       LogoPath, PaymentTermId, Domain
FROM [CRM].[Partners];

COMMIT TRANSACTION;
-- @baseline được truyền sang Postgres writer
```

### Bước 3: CT Incremental — hot path

Sau bootstrap, recurring job mỗi phút (`Cron.Minutely()`):

```sql
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRANSACTION;

DECLARE @upper_watermark bigint = CHANGE_TRACKING_CURRENT_VERSION();

SELECT CT.SYS_CHANGE_VERSION,
       CT.SYS_CHANGE_OPERATION,   -- 'I', 'U', 'D'
       CT.PartnerId,
       P.*
FROM CHANGETABLE(CHANGES [CRM].[Partners], @last_checkpoint) AS CT
LEFT JOIN [CRM].[Partners] AS P ON P.PartnerId = CT.PartnerId
WHERE CT.SYS_CHANGE_VERSION <= @upper_watermark
ORDER BY CT.SYS_CHANGE_VERSION, CT.PartnerId;

COMMIT TRANSACTION;
```

**Phân loại operation theo filter:**

| CT Operation | Current Source Row | Hành động trên Postgres |
|---|---|---|
| `D` (delete) | Không tồn tại | `is_active = false` theo PK |
| `I` / `U` | `IsCustomer = 1` | Upsert, `is_active = true` |
| `I` / `U` | `IsCustomer = 0` (hoặc NULL) | `is_active = false` theo PK |

### Bước 4: Apply batch lên Postgres

Toàn bộ batch trong **1 PostgreSQL transaction duy nhất**:

```sql
BEGIN;

-- Deactivate CT 'D' rows
UPDATE report.partners
SET is_active = false, synced_at = NOW()
WHERE partner_id = ANY(@delete_pks);

-- Deactivate rows chuyển từ IsCustomer=1 → 0
UPDATE report.partners
SET is_active = false, synced_at = NOW()
WHERE partner_id = ANY(@filter_out_pks);

-- Upsert rows còn IsCustomer=1
INSERT INTO report.partners (partner_id, company_id, name, code, ...)
VALUES (...)
ON CONFLICT (partner_id) DO UPDATE
SET name = EXCLUDED.name,
    code = EXCLUDED.code,
    ...
    is_active = true,
    synced_at = NOW();

-- Advance checkpoint với optimistic guard
UPDATE sync_meta.checkpoint
SET last_sync_version = @upper_watermark,
    last_success_at = NOW(),
    consecutive_failure_count = 0
WHERE source_table = 'CRM.Partners'
  AND last_sync_version = @previous_checkpoint;  -- guard

COMMIT;
```

Nếu `last_sync_version != @previous_checkpoint` → rollback toàn bộ transaction.

## 3. Edge case cần xử lý

### 3.1 CT version invalid

```csharp
var minValid = await GetMinValidVersionAsync(tableName);
if (minValid > lastCheckpoint)
{
    await checkpointStore.TransitionToFullResyncAsync(config);
    // BootstrapSyncService sẽ chạy full snapshot flow
}
```

### 3.2 Concurrent bootstrap + CT job: PostgreSQL Advisory Lock

#### Advisory lock là gì

PostgreSQL advisory lock là cơ chế **khóa phân tán do ứng dụng tự định nghĩa**, không gắn với bất kỳ row hay bảng nào. Nó hoàn toàn do code quyết định ý nghĩa.

```sql
-- Acquire lock (session-level)
SELECT pg_advisory_lock(123456);

-- Non-blocking version — return false nếu lock đã bị chiếm
SELECT pg_try_advisory_lock(123456);

-- Release
SELECT pg_advisory_unlock(123456);
```

#### Phân biệt với các loại lock khác

| Loại lock | Scope | Auto-release | Phù hợp |
|---|---|---|---|
| Row lock (`SELECT ... FOR UPDATE`) | Row cụ thể | Cuối transaction | Đồng bộ row-level |
| Table lock (`LOCK TABLE`) | Cả bảng | Cuối transaction | Block mọi access, quá nặng |
| **Advisory lock** | Do app định nghĩa | Khi disconnect hoặc gọi unlock | Sync job phân tán |

#### Tại sao dùng advisory lock trong sync design

Lock key được tạo từ hash của string `"central-db-sync:{source_table}"`:

```csharp
long lockKey = HashCode.Combine("central-db-sync:CRM.Partners");
```

**Tác dụng:**
1. **Chống concurrent sync cùng bảng** — instance A đang sync `CRM.Partners`, instance B gọi `pg_try_advisory_lock()` với cùng key sẽ return false ngay → `skipped_locked`
2. **Lock tồn tại xuyên suốt session** — không auto-release sau mỗi transaction, chỉ release khi gọi `pg_advisory_unlock()` hoặc disconnect
3. **Không ảnh hưởng row data** — lock này không chặn `SELECT`/`UPDATE` thông thường. Process khác vẫn đọc/ghi `report.partners` bình thường nếu không tôn trọng cùng lock convention

#### Flow multi-instance

```
Job A (instance 1)                    Job B (instance 2)
────────────────────                  ────────────────────
pg_try_advisory_lock(45678)
→ lock acquired ✓
                                      pg_try_advisory_lock(45678)
                                      → false → skipped_locked ✓
read CT batch from ERP
apply to Postgres
pg_advisory_unlock(45678)
                                      (cycle sau retry bình thường)
```

Đây chính là cơ chế đảm bảo **multi-instance safety**: dù có bao nhiêu WebApi instance, chỉ 1 instance được sync bảng `CRM.Partners` tại một thời điểm.

#### Cách dùng trong code

```csharp
// ITxTableSyncLock.cs
public interface ITableSyncLock
{
    Task<IDisposable?> TryAcquireAsync(string sourceTable, CancellationToken ct);
}

// PostgresTableSyncLock.cs
public class PostgresTableSyncLock : ITableSyncLock
{
    public async Task<IDisposable?> TryAcquireAsync(string sourceTable, CancellationToken ct)
    {
        var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        var lockKey = (long)HashCode.Combine("central-db-sync:" + sourceTable);
        var acquired = await conn.QuerySingleAsync<bool>(
            "SELECT pg_try_advisory_lock(@key)", new { key = lockKey });

        if (!acquired)
        {
            await conn.DisposeAsync();
            return null; // → skipped_locked
        }

        return new AdvisoryLockHandle(conn, lockKey);
    }
}
```

Khi không acquire được lock:
- Scheduled job ghi `skipped_locked`, log Debug, không advance checkpoint
- Manual bootstrap trả HTTP `409 Conflict`
- Recovery giữ state hiện tại và thử lại cycle sau

### 3.3 Retry transient failure

Tối đa 3 retry với cùng `ChangeBatch` + `UpperWatermark`. Phân loại exception dựa trên PostgreSQL SQLSTATE:
- **Transient:** `08xxx` (connection), `40P01` (deadlock), `57Pxx` (admin shutdown)
- **Non-transient:** `23xxx` (constraint), mapping error → fail nhanh

### 3.4 Filter `IsCustomer` áp dụng thế nào

**Không** dùng `WHERE IsCustomer = 1` trong FullRefresh SQL. Thay vào đó:
- FullRefresh đọc **toàn bộ** rows
- `PartnersRowMapper` hoặc `FullRefreshSyncStrategy` áp dụng filter sau khi có current source state
- Row có `IsCustomer = 0` → `is_active = false` trên target
- Đảm bảo không bỏ sót row đã từng là customer nhưng sau đó bị chuyển

## 4. Cấu trúc code

```
Application/Features/CentralDbSync/
├── Abstractions/
│   ├── IChangeTrackingReader.cs     ← CHANGETABLE query + UpperWatermark
│   ├── IFullRefreshReader.cs        ← SELECT * FROM [CRM].[Partners]
│   ├── ISyncBatchApplier.cs         ← Apply batch + advance checkpoint
│   ├── ISyncCheckpointStore.cs      ← Read/write/transition checkpoint
│   ├── ITableRowMapper.cs           ← ERP row → Postgres row
│   ├── ISyncStrategy.cs
│   └── IBootstrapSyncService.cs
├── Models/
│   ├── TableSyncConfig.cs
│   ├── ChangedRow.cs
│   ├── ChangeBatch.cs
│   └── SyncBatchResult.cs
├── Strategies/
│   ├── FullRefreshSyncStrategy.cs
│   └── ChangeTrackingSyncStrategy.cs
├── Services/
│   ├── SyncTablesUseCase.cs
│   └── BootstrapSyncService.cs
└── Mappers/
    └── PartnersRowMapper.cs

Infrastructure/CentralDb/
├── SqlServer/
│   ├── SqlServerFullRefreshReader.cs
│   ├── SqlServerChangeTrackingReader.cs  ← CHANGETABLE implement
│   └── ErpPrimaryConnectionFactory.cs
├── Postgres/
│   ├── SyncBatchApplier.cs
│   ├── SyncCheckpointStore.cs
│   └── CentralDbConnectionFactory.cs
├── Jobs/
│   └── SyncHotTablesJob.cs               ← Hangfire wrapper
└── Scripts/
    ├── 001_init_sync_meta.sql
    └── 002_create_partners.sql
```

## 5. Luồng hoạt động tổng thể

```
┌─────────────────────────────────────────────────┐
│ Hangfire Recurring Job (Cron.Minutely)          │
│ Queue: data-sync                                │
└──────────────────┬──────────────────────────────┘
                   ▼
┌─────────────────────────────────────────────────┐
│ SyncHotTablesJob                                 │
│ [DisableConcurrentExecution(60s)]               │
└──────────────────┬──────────────────────────────┘
                   ▼
┌─────────────────────────────────────────────────┐
│ SyncTablesUseCase.ExecuteAsync(Hot)              │
│ → TableSyncConfigRegistry.GetByTier(Hot)        │
└──────────────────┬──────────────────────────────┘
                   ▼
┌─────────────────────────────────────────────────┐
│ PostgreSQL Advisory Lock                         │
│ central-db-sync:CRM.Partners                    │
└──────────────────┬──────────────────────────────┘
                   ▼
┌─────────────────────────────────────────────────┐
│ ChangeTrackingSyncStrategy                       │
│ 1. Load checkpoint từ sync_meta                 │
│ 2. IChangeTrackingReader.ReadBatchAsync()       │
│    → SET SNAPSHOT → UpperWatermark → CHANGETABLE│
│ 3. ISyncBatchApplier.ApplyBatchAsync()          │
│    → Delete D + Deactivate non-customer + Upsert│
│    → Advance checkpoint với optimistic guard    │
│ 4. Release lock                                 │
└─────────────────────────────────────────────────┘
```

## 6. Không cần DbContext cho Postgres

Hiện tại project có 3 DbContext, tất cả đều SQL Server:

| DbContext | Connection | Provider | Mục đích |
|---|---|---|---|
| `UaWriteDbContext` | `DefaultConnection` | SQL Server | Write ERP primary |
| `UaReadDbContext` | `ErpReplicateConnection` | SQL Server | Read ERP replica |
| `ReportingDbContext` | `ReportingConnection` | SQL Server | Hangfire + report metadata |

Cả 3 dùng `AddDbContext<T>()` với `UseSqlServer()`, cần EF Core vì có entity mapping phức tạp, relationship, ChangeTracker, audit hook.

Postgres trong Phase 1 không cần DbContext vì:

1. Sync logic đơn giản — chỉ `INSERT ... ON CONFLICT DO UPDATE`, `UPDATE`, `DELETE`
2. Không thêm NuGet nặng — `Npgsql.EntityFrameworkCore.PostgreSQL` kéo theo EF Core provider không cần thiết
3. Khác provider hoàn toàn — 3 DbContext hiện tại đều SQL Server
4. Bảng `sync_meta.*` đơn giản — checkpoint store cũng chỉ cần read/write key-value

**Cách làm:** Npgsql + Dapper (raw SQL):

```csharp
// Infrastructure/CentralDb/Postgres/CentralDbConnectionFactory.cs
public class CentralDbConnectionFactory
{
    private readonly string _connectionString;
    
    public CentralDbConnectionFactory(AppDatabaseSettings settings)
    {
        _connectionString = settings.CentralDbConnection;
    }
    
    public NpgsqlConnection CreateConnection()
    {
        var conn = new NpgsqlConnection(_connectionString);
        conn.Open();
        return conn;
    }
}
```

`AppDatabaseSettings` cần thêm:

```csharp
public string CentralDbConnection { get; set; } = string.Empty;
```

# Phase 1 Implementation Plan: Sync ERP → PostgreSQL (Central DB)

**Ngày:** 2026-07-18  
**Status:** Ready for implementation  
**Phạm vi Phase 1:** Toàn bộ feature sync nền tảng trong UaApp — gồm **Phase A (Pilot)** + **Phase B (Section 5.3 vocab)**.  
**Tài liệu gốc:** `2026-07-18-Implementation-Idea.md`  
**Danh sách vocab:** `2026-07-17-Section5.3-Table-List.md`

> **Gọi tên:** Trong blueprint cũ, “Phase 1” từng chỉ nhóm vocab 5.3.  
> Trong plan này, **Phase 1 = cả feature sync lần đầu** (A + B). Vocab 5.3 là **Phase B** bên trong Phase 1.

---

## Mục lục

1. [Mục tiêu Phase 1](#1-mục-tiêu-phase-1)
2. [Nguyên tắc kiến trúc & map vào UaApp](#2-nguyên-tắc-kiến-trúc--map-vào-uaapp)
3. [Folder / file structure đích](#3-folder--file-structure-đích)
4. [Vai trò từng thành phần](#4-vai-trò-từng-thành-phần)
5. [Phase A — Pilot `CRM.Partners`](#phase-a--pilot-crmpartners)
6. [Phase B — Mở rộng vocab Section 5.3](#phase-b--mở-rộng-vocab-section-53)
7. [Checklist hoàn thành Phase 1](#7-checklist-hoàn-thành-phase-1)
8. [Ngoài phạm vi Phase 1](#8-ngoài-phạm-vi-phase-1)

---

## 1. Mục tiêu Phase 1

Xây pipeline sync **một chiều** từ SQL Server ERP (primary) sang PostgreSQL, chạy bằng **Hangfire** sẵn có trong WebApi, để Base44 / Retool đọc Postgres thay vì ERP.

| Tiểu giai đoạn | Mục tiêu | Bảng |
|---|---|---|
| **Phase A — Pilot** | Chứng minh end-to-end: Bootstrap + CT incremental + Hangfire + checkpoint | `CRM.Partners` → Postgres `partners` (tên chốt ở A.2) |
| **Phase B — Vocab 5.3** | Sync đủ ~17 bảng danh mục theo Table List, chủ yếu FullRefresh | Theo `2026-07-17-Section5.3-Table-List.md` |

**Kết quả mong đợi cuối Phase 1:**

- Postgres có dữ liệu Partners (pilot) + toàn bộ vocab 5.3
- Job Hangfire chạy ổn, quan sát được trên `/hangfire`
- Thêm bảng mới chủ yếu bằng **config + mapper**, không viết lại pipeline
- Tool BI chỉ cần connection string Postgres (read-only)

---

## 2. Nguyên tắc kiến trúc & map vào UaApp

### 2.1. Connection / DbContext

| Connection | DbContext hiện có / mới | Vai trò trong Phase 1 |
|---|---|---|
| `DefaultConnection` | `UaWriteDbContext` | **Nguồn sync** — đọc snapshot + `CHANGETABLE` trên ERP primary |
| `ErpReplicateConnection` | `UaReadDbContext` | **Không dùng** cho sync CT |
| `ReportingConnection` | `ReportingDbContext` + Hangfire storage | Giữ nguyên Reporting; Hangfire job storage vẫn ở đây |
| `CentralDbConnection` (**mới**) | Không bắt buộc EF đầy đủ — ưu tiên **Npgsql / Dapper** | Đích sync + bảng `sync_meta.*` |

Thêm vào `AppDatabaseSettings`:

```csharp
public string CentralDbConnection { get; set; } = string.Empty;
```

### 2.2. Hangfire

- Tái dụng `AddHangfire` / `AddHangfireServer` hiện có
- Thêm queue riêng: **`data-sync`** (không tranh worker với `report-render`)
- Cập nhật `Program.cs`:

```csharp
options.Queues = ["report-render", "data-sync", "default"];
```

- Recurring job đăng ký **cố định lúc startup** (khác pattern dynamic `report-schedule-{id}`)

### 2.3. CQRS / layer

| Layer | Chứa gì |
|---|---|
| Domain | Enum sync (`SyncMode`, `SyncTier`); không bắt buộc entity Postgres |
| Application | Interface, DTO config, use case orchestrator, mapper contract |
| Infrastructure | SQL Server readers, Postgres writer, checkpoint store, Hangfire job wrappers, DI extension |
| WebApi | Đăng ký recurring job lúc startup; (optional) endpoint bootstrap / health |

### 2.4. Sơ đồ luồng

```
Hangfire (queue: data-sync)
        │
        ▼
CentralDbSyncJob  →  SyncTablesUseCase
        │
        ├─ [Phase A ✅] BootstrapSyncService  → IBootstrapSnapshotReader (ERP primary)
        │     (checkpoint == null / pending / requires_full_resync)
        ├─ [Phase A ✅] ChangeTrackingSyncService → IChangeTrackingReader (ERP primary)
        │     (checkpoint == ready → CHANGETABLE incremental)
        ├─ [Phase B ⏳] FullRefresh strategy  → IFullRefreshReader (ERP primary)
        │     (tables không có CT, SyncMode = FullRefresh)
        │
        ▼
ISyncBatchApplier (upsert + delete + checkpoint trong 1 transaction)  →  PostgreSQL (CentralDbConnection)
```

---

## 3. Folder / file structure đích

Cấu trúc đề xuất (tạo dần theo giai đoạn; Phase A chỉ cần subset có đánh dấu ★):

```
Domain/
  Enums/
    CentralDb/
      SyncMode.cs                          ★  FullRefresh | ChangeTracking | HistoryUpsert
      SyncTier.cs                          ★  Hot | Cold

Application/
  Features/
    CentralDbSync/                         ★ feature mới
      Abstractions/
        IFullRefreshReader.cs              ★
        IChangeTrackingReader.cs           ★
        ISyncBatchApplier.cs               ★  upsert + delete + checkpoint atomic
        ISyncCheckpointStore.cs            ★  read/state transition checkpoint
        ITableRowMapper.cs                 ★  map Dictionary/row → target shape
        ISyncStrategy.cs                   ★
        IBootstrapSyncService.cs           ★
      Models/
        TableSyncConfig.cs                 ★
        ChangedRow.cs                      ★  PK + operation + CT version + values nullable
        ChangeBatch.cs                     ★  previous checkpoint + upper watermark + rows
        SyncBatchResult.cs                 ★
      Strategies/
        FullRefreshSyncStrategy.cs         ★
        ChangeTrackingSyncStrategy.cs      ★
        HistoryUpsertSyncStrategy.cs         Phase B — chỉ upsert history theo composite PK
      Services/
        SyncTablesUseCase.cs               ★  orchestrator theo list config
        BootstrapSyncService.cs            ★  onboard CT lần đầu
      Mappers/
        PartnersRowMapper.cs               ★  Phase A
        UnitsRowMapper.cs                    Phase B
        SeasonsRowMapper.cs                  Phase B
        ... (1 mapper / bảng vocab khi tới B)
      Config/
        TableSyncConfigRegistry.cs         ★  danh sách bảng + mode/tier

Infrastructure/
  CentralDb/
    SqlServer/
      SqlServerFullRefreshReader.cs        ★
      SqlServerChangeTrackingReader.cs     ★
      ErpPrimaryConnectionFactory.cs       ★  lấy DefaultConnection (không qua UaWrite SaveChanges)
    Postgres/
      SyncBatchApplier.cs                  ★  upsert + delete + checkpoint atomic
      SyncCheckpointStore.cs               ★
      CentralDbConnectionFactory.cs        ★
    Jobs/
      SyncHotTablesJob.cs                  ★  Hangfire wrapper tier Hot
      SyncColdTablesJob.cs                   Phase B (hoặc tái dùng 1 job + filter tier)
    Scripts/                               (hoặc docs/.../scripts/)
      001_init_sync_meta.sql               ★
      002_create_partners.sql              ★
      003_create_vocab_5_3.sql               Phase B
    CentralDbSyncInfrastructureExtensions.cs ★  DI + Hangfire registration helpers

WebApi/
  Program.cs                               ★  queue data-sync + RecurringJob.AddOrUpdate
  Controllers/CentralDb/                   (optional Phase A)
    CentralDbSyncController.cs             bootstrap on-demand / status (checkpoint lag)

docs/central-database-blueprint/
  2026-07-18-Implementation-Idea.md
  2026-07-18-Implementation-Plan.md        ← file này
  scripts/                                 SQL init Postgres (nếu không để trong Infrastructure)
```

**NuGet cần thêm (Infrastructure hoặc WebApi):**

| Package | Mục đích |
|---|---|
| `Npgsql` | Kết nối / bulk ghi PostgreSQL |
| (optional) `Dapper` | Query ERP / Postgres gọn nếu team muốn |

> Không bắt buộc `Npgsql.EntityFrameworkCore.PostgreSQL` cho Phase 1 nếu ghi bằng SQL thuần (`INSERT ... ON CONFLICT`).

---

## 4. Vai trò từng thành phần

| Thành phần | Mục đích | Ghi chú |
|---|---|---|
| `TableSyncConfig` | Mô tả 1 bảng: source SQL, target Postgres, PK columns, mode, tier, filter SQL, mapper key | Config-driven — thêm bảng = thêm config |
| `ChangedRow` | Một CT row: `PrimaryKey`, operation `I` / `U` / `D`, `ChangeVersion`, `CurrentValues?` | `CurrentValues` null cho delete; PK hỗ trợ composite key |
| `ChangeBatch` | Tập CT row: `PreviousCheckpoint`, `UpperWatermark`, `Rows` | Ràng buộc chính xác khoảng version đã đọc với checkpoint được advance |
| `IFullRefreshReader` | `SELECT` snapshot từ ERP primary theo config | ⏳ Phase B: mode chính của vocab không CT. Phase A: đã implement trong `SqlServerPartnersReader` nhưng chưa có service nào consume |
| `IChangeTrackingReader` | Chụp `UpperWatermark`, query `CHANGETABLE(CHANGES ...)` đến watermark, join bảng nguồn | Chỉ bảng mode CT; đọc trong SQL Server snapshot transaction |
| `ISyncBatchApplier` | Apply delete/upsert CT batch và advance checkpoint | Một PostgreSQL transaction, `ON CONFLICT DO UPDATE`, idempotent để retry an toàn |
| `ISyncCheckpointStore` | Đọc checkpoint và transition trạng thái | Advance checkpoint do applier thực hiện với optimistic guard `last_sync_version = PreviousCheckpoint` |
| `ITableRowMapper` | ERP row → Postgres row (rename, type, metadata) | 1 class / bảng (hoặc keyed registry) |
| `FullRefreshSyncStrategy` | Đọc full → map → upsert → xóa orphan theo PK | ⏳ Phase B: chưa implement. Phase A chỉ implement Bootstrap + CT incremental |
| `HistoryUpsertSyncStrategy` | Đọc history snapshot → map → upsert theo composite PK | Không orphan-delete toàn bảng; dành cho `exchange_rates` để giữ lịch sử ngoài snapshot window |
| `ChangeTrackingSyncStrategy` | Đọc CT batch → map → `ISyncBatchApplier` | Advance đúng `UpperWatermark`; checkpoint invalid chuyển full-resync |
| `BootstrapSyncService` | Onboard CT: lấy baseline **trước** → full snapshot → lưu checkpoint baseline | Full-load state + checkpoint cùng PostgreSQL transaction; không gắn recurring.<br>⚠ Không phải FullRefresh — Bootstrap capture CT baseline, chỉ chạy 1 lần hoặc khi recovery |
| `SyncTablesUseCase` | Lọc config theo tier/mode → chạy strategy | Entry cho Hangfire job |
| `SyncHotTablesJob` / `SyncColdTablesJob` | Hangfire entry; `[DisableConcurrentExecution]`; queue `data-sync` | Thin wrapper |
| `SqlServer*Reader` | Implement reader bằng `Microsoft.Data.SqlClient` trên `DefaultConnection` | Tránh dựa vào ChangeTracker của EF khi chỉ đọc CT |
| `SyncBatchApplier` / `SyncCheckpointStore` | Implement trên `CentralDbConnection` | Schema `sync_meta` + schema nghiệp vụ (vd. `report`) |

---

# Phase A — Pilot `CRM.Partners`

**Mục tiêu:** Vertical slice chạy được. Chứng minh Bootstrap + CT incremental + Hangfire trước khi nhân bản sang nhiều bảng.

**Bảng nguồn:** `CRM.Partners` (PK cột ERP: `PartnerId` — theo `PartnerConfiguration`)  
**Entity tham chiếu:** `Domain.Entities.CRM.Partner`  
**Filter pilot (đề xuất):** `IsCustomer = 1` (chốt khi implement nếu cần sync cả supplier)

---

## A.0 — Chuẩn bị môi trường Postgres + connection

### Công việc

1. Chạy PostgreSQL local (Docker khuyến nghị):
   ```bash
   docker run --name pg-central-dev -e POSTGRES_PASSWORD=devpassword \
     -e POSTGRES_DB=central_db -p 5432:5432 -d postgres:16
   ```
2. Thêm `CentralDbConnection` vào `AppSettings` / `appsettings.Development.json`
3. Cài `Npgsql` vào project Infrastructure
4. Chạy DDL script 001-central-db-sync-schema.sql trên PostgreSQL Central DB

### File chạm

- `Domain/Common/AppSettings.cs`
- `WebApi/appsettings.Development.json` (+ Production khi sẵn sàng)
- `Infrastructure/*.csproj`
- `WebApi/Controllers/CentralDbSyncController.cs` — `GET {sourceTable}/status`, `POST bootstrap/{sourceTable}`

### Kết quả mong đợi

- [ ] API start được với connection Postgres hợp lệ
- [ ] Test/health xác nhận ERP primary + Postgres reachable
- [ ] Chưa có logic sync

---

## A.1 — Bật Change Tracking trên ERP (DBA / script)

### Công việc

1. Xác nhận SQL Server edition hỗ trợ CT (thường Standard trở lên đều có)
2. Xác nhận `CRM.Partners` có Primary Key (`PartnerId`)
3. Bật CT mức database (nếu chưa):
   ```sql
   ALTER DATABASE [ERP_DB] SET CHANGE_TRACKING = ON
   (CHANGE_RETENTION = 5 DAYS, AUTO_CLEANUP = ON);
   ```
4. Bật CT trên bảng:
   ```sql
   ALTER TABLE [CRM].[Partners] ENABLE CHANGE_TRACKING
   WITH (TRACK_COLUMNS_UPDATED = ON);
   ```
5. Cấp quyền tối thiểu cho SQL login của API:
   ```sql
   GRANT SELECT ON [CRM].[Partners] TO [api_login];
   GRANT VIEW CHANGE TRACKING ON [CRM].[Partners] TO [api_login];
   ```
6. Bật snapshot isolation sau DBA review tác động version store trên `tempdb`:
   ```sql
   ALTER DATABASE [ERP_DB] SET ALLOW_SNAPSHOT_ISOLATION ON;
   ```
7. Verify thủ công: insert/update/delete 1 partner → query `CHANGETABLE(CHANGES [CRM].[Partners], 0)` thấy thay đổi

### File / artifact

- `docs/central-database-blueprint/scripts/erp-enable-ct-partners.sql` (script review với DBA; **không** chạy tự động từ app)

### Kết quả mong đợi

- [ ] CT hoạt động trên `CRM.Partners`
- [ ] Tài khoản API đọc được CHANGETABLE (không cần sysadmin)

> **Lưu ý ops:** Cần approve DBA — đụng schema/DB production. Làm trên UAT trước.

---

## A.2 — Schema Postgres: `sync_meta` + bảng `partners`

### Công việc

1. Tạo schema quản lý:
   ```sql
   CREATE SCHEMA IF NOT EXISTS sync_meta;

   CREATE TABLE sync_meta.checkpoint (
       source_table      TEXT PRIMARY KEY,   -- vd. 'CRM.Partners'
       last_sync_version BIGINT NULL,
       sync_status       TEXT NOT NULL DEFAULT 'pending_initial_sync',
       updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
       CHECK (sync_status IN (
           'pending_initial_sync',
           'ready',
           'requires_full_resync'
       ))
   );

   -- Chỉ chạy CT incremental khi sync_status = 'ready'.
   -- Checkpoint invalid phải atomically chuyển sang 'requires_full_resync'.

   CREATE TABLE sync_meta.sync_run_log (     -- optional nhưng hữu ích pilot
       id           BIGSERIAL PRIMARY KEY,
       source_table TEXT NOT NULL,
       mode         TEXT NOT NULL,
       rows_upserted INT NOT NULL DEFAULT 0,
       rows_deleted  INT NOT NULL DEFAULT 0,
       started_at   TIMESTAMPTZ NOT NULL,
       finished_at  TIMESTAMPTZ,
       success      BOOLEAN NOT NULL,
       error_message TEXT
   );
   ```
2. Tạo bảng đích pilot (đề xuất — chỉnh khi chốt mapping):

| Cột Postgres | Kiểu | Nguồn ERP (gợi ý) |
|---|---|---|
| `partner_id` | `int` PK | `PartnerId` |
| `company_id` | `int` | `CompanyId` |
| `code` | `text` | `Code` |
| `name` | `text` | `Name` |
| `is_customer` | `boolean` | `IsCustomer` |
| `is_supplier` | `boolean` | `IsSupplier` |
| `email` | `text` | `Email` |
| `phone` | `text` | `Phone` |
| `activated` | `boolean` | `Activated` |
| `synced_at` | `timestamptz` | set khi ghi |
| `source_system` | `text` | `'erp'` |

> Pilot **không** cần sync hết mọi cột `Partner` — chỉ đủ để chứng minh pipeline + phục vụ Retool xem list khách hàng. Có thể mở rộng cột sau.

Schema nghiệp vụ đề xuất: `report.partners` (hoặc `crm.partners` — chốt 1 lần, giữ nhất quán Phase B dùng `report.*`).

### File

- `Infrastructure/CentralDb/Scripts/001_init_sync_meta.sql`
- `Infrastructure/CentralDb/Scripts/002_create_partners.sql`

### Kết quả mong đợi

- [ ] Chạy script trên Postgres local thành công
- [ ] Insert thủ công 1 dòng `partners` + 1 checkpoint được

---

## A.3 — Application contracts + models

### Công việc

1. Tạo enum `SyncMode`, `SyncTier`
2. Tạo DTO/config:
   - `TableSyncConfig` — `SourceTable`, `TargetSchema`, `TargetTable`, `PrimaryKeyColumns[]`, `Mode`, `Tier`, `SourceFilterSql?`, `MapperKey`
   - `ChangedRow` — `IReadOnlyDictionary<string, object?> PrimaryKey`, `string Operation`, `long ChangeVersion`, `IReadOnlyDictionary<string, object?>? CurrentValues`
   - `ChangeBatch` — `long PreviousCheckpoint`, `long UpperWatermark`, `IReadOnlyList<ChangedRow> Rows`
3. Tạo interfaces trong `Abstractions/` như mục 3–4, gồm `ISyncBatchApplier.ApplyBatchAndAdvanceCheckpointAsync(config, batch, cancellationToken)`

### File (★ trong structure)

- Toàn bộ dưới `Application/Features/CentralDbSync/`

### Kết quả mong đợi

- [ ] Build được; chưa cần implement Infrastructure
- [ ] Config Partners hard-code tạm trong `TableSyncConfigRegistry` (1 entry, mode ChangeTracking, tier Hot)

---

## A.4 — Infrastructure readers / writers

### Công việc theo thứ tự

1. **`ErpPrimaryConnectionFactory`** — tạo `SqlConnection` từ `DefaultConnection` (scoped hoặc transient mở khi dùng)
2. **`SqlServerBootstrapReader`** (tên gốc: SqlServerPartnersReader implement IBootstrapSnapshotReader)
   - Input: config (table + filter)
   - Output: BootstrapSnapshot có CT baseline version
   - Chụp CHANGE_TRACKING_CURRENT_VERSION() trước, đọc full rows với READPAST, verify version không đổi
3. **`SqlServerChangeTrackingReader`** — chạy trong SQL Server snapshot transaction:
   ```sql
   SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
   BEGIN TRANSACTION;

   DECLARE @upper_watermark bigint = CHANGE_TRACKING_CURRENT_VERSION();

   SELECT CT.SYS_CHANGE_VERSION,
          CT.SYS_CHANGE_OPERATION,
          CT.PartnerId,
          P.*
   FROM CHANGETABLE(CHANGES [CRM].[Partners], @last_version) AS CT
   LEFT JOIN [CRM].[Partners] AS P ON P.PartnerId = CT.PartnerId
   WHERE CT.SYS_CHANGE_VERSION <= @upper_watermark
   ORDER BY CT.SYS_CHANGE_VERSION, CT.PartnerId;

   COMMIT TRANSACTION;
   ```
   - Reader trả `ChangeBatch` với `PreviousCheckpoint`, `UpperWatermark`, `Rows`.
   - `D`: delete target theo PK.
   - `I`/`U` còn thỏa `IsCustomer = 1`: upsert.
   - `I`/`U` không còn thỏa filter: delete target theo PK, tránh row stale.
4. **`CentralDbConnectionFactory`** + **`SyncBatchApplier`**
   - Mở một PostgreSQL transaction: delete `D`, upsert `I`/`U` bằng `INSERT ... ON CONFLICT DO UPDATE`, rồi advance checkpoint đến `UpperWatermark`.
   - Checkpoint update dùng optimistic guard `WHERE source_table = @source_table AND last_sync_version = @previous_checkpoint`; nếu không đúng một row thì rollback và retry.
   - Delete theo đủ `PrimaryKeyColumns` và upsert phải idempotent để retry at-least-once an toàn.
5. **`SyncCheckpointStore`** — đọc state/checkpoint theo `source_table`; transition checkpoint invalid sang `requires_full_resync` atomically.
6. **`PartnersRowMapper`** — map cột ERP → Postgres + set `synced_at` / `source_system`

### Xử lý CT version invalid

Nếu `CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(...)) > last_sync_version`:

- Atomically chuyển `sync_status` sang `requires_full_resync` và log Warning.
- Chụp `baseline = CHANGE_TRACKING_CURRENT_VERSION()` **trước** full-copy.
- Đọc full snapshot dưới snapshot isolation.
- FullRefresh dữ liệu đích và lưu `checkpoint = baseline`, `sync_status = 'ready'` trong cùng PostgreSQL transaction.
- Lần CT sau đọc từ baseline để bắt thay đổi phát sinh trong lúc full-copy.

### Kết quả mong đợi

- [ ] Unit/integration test nhỏ: mock hoặc DB thật — reader trả rows; writer upsert 2 dòng; checkpoint đọc/ghi được
- [ ] Manual: gọi writer insert Partners mẫu từ query ERP

---

## A.5 — Strategies + Bootstrap + Use case

### Công việc

1. **`BootstrapSyncService`** (đã implement — không phải FullRefresh)
   - Chụp baseline = CHANGE_TRACKING_CURRENT_VERSION() + full snapshot trong SNAPSHOT transaction.
   - Upsert snapshot và deactivate orphan trong cùng PostgreSQL transaction.
   - Set checkpoint = baseline, sync_status = ready.
   - ⚠ Không orphan-delete toàn bảng; orphan-delete chỉ áp dụng cho PK trong phạm vi filter/ownership.
2. **`ChangeTrackingSyncService`** (đã implement)
   - Load checkpoint hợp lệ → CT reader trả `ChangeBatch` → map → `ISyncBatchApplier.ApplyBatchAndAdvanceCheckpointAsync`.
   - Applier ghi delete/upsert và advance checkpoint đúng `UpperWatermark` trong cùng PostgreSQL transaction.
   - Retry at-least-once; mọi ghi phải idempotent. Không lấy current version sau khi đọc CT để ghi checkpoint.
3. **`SyncOrchestrator`** (đã implement) — quyết định đường đi:
   - checkpoint == null / pending / requires_full_resync → BootstrapSyncService
   - checkpoint == ready → ChangeTrackingSyncService
4. **`SyncTablesUseCase.ExecuteAsync(SyncTier? tier = Hot)`**
   - Lấy configs (Phase A: chỉ Partners)
   - Switch strategy theo `Mode`
5. Đăng ký DI trong `CentralDbSyncInfrastructureExtensions` + gọi từ `AddInfrastructure`

### Kết quả mong đợi

- [ ] Gọi `BootstrapSyncService` 1 lần (test/controller) → Postgres đầy dữ liệu Partners (theo filter)
- [ ] Checkpoint có version > 0
- [ ] Gọi `SyncTablesUseCase` sau khi sửa 1 Partner trên ERP → Postgres cập nhật

---

## A.6 — Hangfire jobs + đăng ký startup

### Công việc

1. Tạo `SyncHotTablesJob`:
   ```csharp
   [DisableConcurrentExecution(timeoutInSeconds: 60)]
   [AutomaticRetry(Attempts = 3)]
   public Task RunAsync(CancellationToken ct)
       => _useCase.ExecuteAsync(SyncTier.Hot, ct);
   ```
   Enqueue/recurring với queue name **`data-sync`**. Timeout lock ngắn để job bị chặn fail nhanh, không giữ worker slot.
2. Trong `Program.cs` (sau Build, hoặc hosted bootstrap), pilot an toàn dùng schedule theo phút:
   ```csharp
   RecurringJob.AddOrUpdate<SyncHotTablesJob>(
       "centraldb-sync-hot",
       j => j.RunAsync(CancellationToken.None),
       Cron.Minutely(),
       new RecurringJobOptions { QueueName = "data-sync" });
   ```
   Nếu SLA bắt buộc 30 giây, phải xác nhận Hangfire version/parser hỗ trợ cron seconds hoặc dùng `BackgroundService` poller self-scheduling. Chu kỳ enqueue phải lớn hơn p95 runtime; nếu không queue `data-sync` sẽ backlog dù job không chạy song song.
3. **Thứ tự vận hành:** Bootstrap (A.5) **trước** khi bật recurring (hoặc job no-op nếu chưa có checkpoint và mode CT — nên fail rõ / skip có log)
4. (Optional) Endpoint `POST /api/central-db/sync/bootstrap/partners` — chỉ Dev/Admin, gọi `BootstrapSyncService`

### File

- `Infrastructure/CentralDb/Jobs/SyncHotTablesJob.cs`
- `WebApi/Program.cs`
- `Infrastructure/CentralDb/CentralDbSyncInfrastructureExtensions.cs`

### Kết quả mong đợi

- [ ] Dashboard `/hangfire` thấy recurring `centraldb-sync-hot` trên queue `data-sync`
- [ ] Không chiếm hết worker của `report-render`
- [ ] Sửa Partner trên ERP → trong ~30s–1 phút Postgres đổi theo

---

## A.7 — Kiểm thử Phase A (Definition of Done)

### Kịch bản bắt buộc

| # | Kịch bản | Pass khi |
|---|---|---|
| 1 | Bootstrap lần đầu | Số dòng Postgres ≈ số Partners ERP (theo filter) |
| 2 | Insert Partner mới (customer) | Xuất hiện trên Postgres sau job |
| 3 | Update Name/Email | Postgres phản ánh đúng |
| 4 | Delete / soft-deactivate (tùy quy ước) | Postgres xóa hoặc cập nhật `activated` đúng design |
| 5 | Filter transition `IsCustomer = 1` → `0` | Row target bị delete, không stale |
| 6 | Concurrent update sau khi chụp upper watermark | Không nằm trong batch hiện tại, xuất hiện ở CT cycle sau |
| 7 | Inject lỗi trước PostgreSQL commit | Delete/upsert và checkpoint rollback cùng nhau |
| 8 | Retry cùng `ChangeBatch` | Không duplicate hoặc sai dữ liệu |
| 9 | CT retention/truncate làm checkpoint invalid | Transition `requires_full_resync`, full refresh rồi CT catch-up từ baseline |
| 10 | Restart WebApi giữa chừng | Job resume từ checkpoint, không full lại trừ khi invalid |

### Kết quả mong đợi Phase A

|- [ ] Pipeline Bootstrap + CT incremental + Hangfire + checkpoint **ổn định trên UAT/dev**
- [ ] Có log rõ bảng, số row, lỗi
- [ ] Team approve → mới sang Phase B

---

# Phase B — Mở rộng vocab Section 5.3

**Điều kiện vào:** Phase A DoD đã pass.  
**Mục tiêu:** Sync đủ bảng controlled vocab trong `2026-07-17-Section5.3-Table-List.md` vào Postgres, phục vụ FK cho báo cáo / Base44 sau này.

**Mode mặc định Phase B:** `FullRefresh` + tier `Cold` (job hourly hoặc daily).  
**Không** bật CT hàng loạt trừ khi đo được bảng lớn/hot thật sự cần.

---

## B.0 — Chuẩn bị mapping & verify schema ERP

### Công việc

1. Với từng bảng trong Table List, verify cột thật bằng `INFORMATION_SCHEMA` / SSMS (Table List ghi TBD ở nhiều cột)
2. Chốt mapping ERP → Postgres theo convention:
   - `lower_snake_case`
   - PK dạng `ua_*_code` hoặc composite theo Table List
   - Metadata: `synced_at`, `source_system = 'erp'`
3. Cập nhật bảng tracking trong docs (hoặc spreadsheet) khi cột đã verify

### Kết quả mong đợi

- [ ] Có mapping “đã verify” cho ít nhất batch đầu (units → seasons) trước khi code mapper

---

## B.1 — SQL tạo toàn bộ bảng vocab 5.3 trên Postgres

### Công việc

1. Script `003_create_vocab_5_3.sql` tạo schema `report` (nếu chưa) + 17 bảng theo thứ tự FK trong Table List:

| # | Postgres table | ERP source (đã xác nhận trong Table List) |
|---|---|---|
| 1 | `units` | `ERP.Configs.Units` |
| 2 | `unit_conversions` | `ERP.Configs.UnitRates` |
| 3 | `cmp_sections` | `ERP.Configs.CMP.Operations` |
| 4 | `fabric_kinds` | `ERP.Configs.Fabrics.Kinds` |
| 5 | `fabric_types` | `ERP.Configs.FabricTypes` |
| 6 | `trim_groups` | `ERP.Configs.TrimGroups` |
| 7 | `trim_types` | `ERP.Configs.Trims.Types` |
| 8 | `treatment_types` | `ERP.Configs.TreatmentTypes` |
| 9 | `work_types` | `ERP.Configs.WorkTypes` |
| 10 | `style_categories` | `ERP.Configs.StyleCategories` |
| 11 | `garment_kinds` | `ERP.Configs.POM.GarmentKinds` |
| 12 | `colours` | `ERP.Configs.Colors` |
| 13 | `seasons` | `ERP.Configs.Seasons` |
| 14 | `artwork_positions` | `ERP.Artwork.Position` |
| 15 | `machines` | `ERP.Configs.Machines` |
| 16 | `exchange_rates` | `Acc.ExchangeRates` |
| 17 | `drop_vocab` | `ERP.Configs.Drops` |

2. Thêm FK Postgres giữa các bảng con (vd. `unit_conversions` → `units`, `fabric_types` → `fabric_kinds`, `drop_vocab` → `seasons` nếu có)

### Kết quả mong đợi

- [ ] Script chạy clean trên Postgres trống
- [ ] FK không chặn sync nếu sync đúng thứ tự

---

## B.2 — Generic hóa registry + cold job

### Công việc

1. Mở rộng `TableSyncConfigRegistry`: mỗi vocab dùng `Tier = Cold`; mặc định `Mode = FullRefresh`, riêng `exchange_rates` dùng `Mode = HistoryUpsert` với `HistoryUpsertSyncStrategy` (không whole-table orphan-delete; chỉ upsert theo composite PK, hoặc scope delete đúng snapshot window nếu nghiệp vụ sau này cần)
2. Partners giữ `Mode = ChangeTracking`, `Tier = Hot` (từ Phase A)
3. Tạo `SyncColdTablesJob` + recurring:
   ```csharp
   RecurringJob.AddOrUpdate<SyncColdTablesJob>(
       "centraldb-sync-cold",
       j => j.RunAsync(CancellationToken.None),
       Cron.Hourly(), // hoặc Daily — chốt theo SLA
       new RecurringJobOptions { QueueName = "data-sync" });
   ```
4. Trong `SyncTablesUseCase`: khi sync nhiều bảng cold, **tuân thủ thứ tự** trong registry (cùng thứ tự Table List) để thỏa FK
5. (Optional) `Parallel.ForEachAsync` với `MaxDegreeOfParallelism` thấp **chỉ giữa các bảng không phụ thuộc FK**; mặc định Phase B nên **sequential theo thứ tự** cho an toàn

### Kết quả mong đợi

- [ ] Một job cold chạy lần lượt vocab; job hot vẫn chỉ Partners (CT)
- [ ] Thêm bảng mới ≈ thêm config + mapper + dòng SQL create table

---

## B.3 — Implement mapper + sync theo batch

Không làm 17 bảng một PR khổng lồ. Chia batch:

### Batch B3.1 — Nền tảng đơn vị & CMP

- `units`, `unit_conversions`, `cmp_sections`
- Mapper + config + test FullRefresh + orphan delete

**Kết quả:** 3 bảng có data; Retool đọc được units.

### Batch B3.2 — Fabric / Trim

- `fabric_kinds`, `fabric_types`, `trim_groups`, `trim_types`, `treatment_types`

**Kết quả:** FK `fabric_types.ua_fabric_kind_code` đúng.

### Batch B3.3 — Style / catalogue chung

- `work_types`, `style_categories`, `garment_kinds`, `colours`, `seasons`, `drop_vocab`

**Kết quả:** seasons + drops dùng được cho filter report.

### Batch B3.4 — Còn lại

- `artwork_positions`, `machines`, `exchange_rates`

**Kết quả:** đủ 17/17 bảng Table List.

Mỗi batch:

1. Verify cột ERP  
2. Viết/ cập nhật `*RowMapper`  
3. Thêm `TableSyncConfig`  
4. Chạy cold job (hoặc endpoint sync-once)  
5. So sánh count ERP vs Postgres (+ sample diff)

### Kết quả mong đợi từng batch

- [ ] Count (sau filter active) khớp hoặc giải thích được lệch
- [ ] Không phá FK Postgres
- [ ] `synced_at` cập nhật mỗi lần job

---

## B.4 — Harden vận hành (áp dụng cả A đã có)

### Công việc

1. `[DisableConcurrentExecution]` trên mọi sync job
2. Retry Hangfire có giới hạn; log `source_table`, mode, duration, row counts
3. (Optional) ghi `sync_meta.sync_run_log`
4. Giảm cron hot Partners từ 30s xuống mức hợp lý prod (vd. 1–5 phút)
5. Giới hạn quyền Hangfire dashboard (nếu chưa)
6. Document connection string Central DB + hướng dẫn Retool/Base44 (read-only user Postgres)

### Kết quả mong đợi

- [ ] Fail một bảng không làm “im lặng” — log/Error rõ
- [ ] Job overlap không chạy song song cùng tier

---

## B.5 — Kiểm thử Phase B / Definition of Done Phase 1

| # | Kiểm thử | Pass khi |
|---|---|---|
| 1 | Cold job full vocab | 17 bảng có data đúng mapping đã verify |
| 2 | Đổi 1 Season trên ERP | Sau chu kỳ cold, Postgres cập nhật |
| 3 | Partners CT vẫn chạy song song | Không regress Phase A |
| 4 | Thứ tự FK | Sync từ DB Postgres trống → full cold job không lỗi FK |
| 5 | Composite PK `unit_conversions` / `exchange_rates` | Delete + upsert idempotent dùng đủ cột trong `WHERE` và `ON CONFLICT` |
| 6 | Lịch sử `exchange_rates` | `HistoryUpsert` không xóa row lịch sử ngoài snapshot window |
| 7 | Aggregate `cmp_sections` | `SELECT DISTINCT` / `GROUP BY` trả đúng tập section; orphan-delete so tập PK đã dedup |
| 8 | Downtime API ngắn | Catch-up sau restart OK |
| 9 | Smoke Retool/Base44 | Kết nối read-only, query được `partners` + vài vocab |

### Kết quả mong đợi cuối Phase 1 (A + B)

|- [ ] Pipeline generic (Bootstrap + CT incremental cho tables có CT; FullRefresh cho tables không CT) đã chứng minh
- [ ] `CRM.Partners` sync incremental ổn
- [ ] Section 5.3 đủ bảng trên Postgres
- [ ] Hangfire queues tách (`data-sync` vs `report-render`)
- [ ] Docs Idea + Plan + SQL scripts đủ để onboarding dev mới

---

## 7. Checklist hoàn thành Phase 1

### Phase A

- [ ] A.0 Postgres + `CentralDbConnection`
- [ ] A.1 CT trên `CRM.Partners` (UAT)
- [ ] A.2 Schema `sync_meta` + `partners`
- [ ] A.3–A.5 Contracts, readers/writers, bootstrap, use case
- [ ] A.6 Hangfire hot job queue `data-sync`
- [ ] A.7 Test DoD pass

### Phase B

- [ ] B.0 Mapping verify
- [ ] B.1 SQL 17 bảng
- [ ] B.2 Cold job + registry
- [ ] B.3 Batches B3.1–B3.4
- [ ] B.4 Harden
- [ ] B.5 DoD Phase 1 pass

---

## 8. Ngoài phạm vi Phase 1

- Transform / aggregation (dirty entity, recompute metric) — Phase sau
- Sync toàn bộ ~700 bảng ERP
- Section 5.2 / 5.1 (reference, operational) — sau khi 5.3 xong
- Tách Hangfire worker process riêng / Redis backplane
- Đọc sync từ replica
- Đưa entity Central DB vào `ReportingDbContext`

---

## Lộ trình tóm tắt

| Giai đoạn | Việc chính | Đầu ra |
|---|---|---|
| **A.0–A.2** | Postgres, CT ERP, schema đích | Hạ tầng sẵn sàng |
| **A.3–A.5** | Pipeline code + bootstrap Partners | Sync thủ công được |
| **A.6–A.7** | Hangfire + test | Pilot ổn định |
| **B.0–B.2** | Mapping + SQL vocab + cold job | Khung mở rộng |
| **B.3** | 4 batch mapper vocab | Đủ 17 bảng |
| **B.4–B.5** | Harden + DoD | **Phase 1 hoàn thành** |

Sau Phase 1, mở rộng bảng mới = thêm dòng registry + mapper + migration SQL Postgres; chỉ dùng CT khi bảng thật sự cần incremental (pattern đã có từ Partners).

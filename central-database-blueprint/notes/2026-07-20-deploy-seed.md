# Central DB Sync — Deploy Seed Guide

> Ngày: 2026-07-20
> Mục đích: Xác định những gì cần seed trên PostgreSQL Production (Railway) khi deploy Central DB Sync lần đầu.

## Kiến trúc

- **Central DB**: PostgreSQL trên Railway — `Host=tokaido.proxy.rlwy.net;Database=railway;`
- **Connection string**: Config trong `appsettings.{Environment}.json` → `AppSettings:DatabaseSettings:CentralDbConnection`
- **Migration tool**: Không có — scripts SQL phải chạy thủ công (không EF migration, không DbUp, không Flyway)
- **Scripts location**: `Infrastructure/Database/SqlScript/CentralDbSync/`

## Những gì cần seed

### 1. Schema — `001-central-db-sync-schema.sql`

Chạy trước. Idempotent (`IF NOT EXISTS`/`CREATE OR REPLACE`).

**Tạo:**
| Schema | Table | Mục đích |
|--------|-------|----------|
| `sync_meta` | — | Schema chứa metadata của sync engine |
| `report` | — | Schema chứa dữ liệu đã sync |
| `report` | `partners` | Denormalised copy của CRM.Partners |
| `sync_meta` | `table_sync_config` | Registry cấu hình cho mỗi table cần sync |
| `sync_meta` | `checkpoint` | Tracking sync progress (version, status, lỗi) |
| `sync_meta` | `sync_run_log` | Append-only audit log mỗi lần chạy |

### 2. Seed data — `002-central-db-sync-seed.sql`

Chạy sau script 001. Idempotent (`ON CONFLICT DO NOTHING`).

**Insert:**
- **`sync_meta.table_sync_config`**: 1 row — `CRM.Partners` → `report.partners`
  - `sync_mode = 'ChangeTracking'`
  - `sync_tier = 'Hot'`
  - `expected_sync_interval = '1 minute'`
  - `max_allowed_lag = '5 minutes'`
  - `ownership_scope = 'erp'`
  - `enabled = TRUE`
- **`sync_meta.checkpoint`**: 1 row — `CRM.Partners` với `sync_status = 'pending_initial_sync'`
  - Lần chạy đầu tiên sẽ phát hiện status này → thực hiện Bootstrap → sync từ version 0

## Những thứ **không** cần seed

| Thành phần | Lý do |
|------------|-------|
| `CentralDbConnection` trong appsettings | Đã có sẵn trong file config deploy cùng app |
| DI registration (`CentralDbSyncInfrastructureExtensions`) | Là code, deploy cùng app |
| Hangfire job (`CentralDbSyncJobs`) | Là code, đăng ký trong `Program.cs` |
| Hangfire queue `data-sync` | Hangfire tự tạo khi job đầu tiên được đăng ký |

## Deployment procedure

```bash
# 1. Deploy app code (code chứa DI, job, config đã sẵn sàng)

# 2. Kết nối đến Central DB (Railway)
psql "Host=tokaido.proxy.rlwy.net;Port=12289;Database=railway;Username=postgres;Password=<password>"

# 3. Chạy schema
\i Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql

# 4. Chạy seed
\i Infrastructure/Database/SqlScript/CentralDbSync/002-central-db-sync-seed.sql
```

## Flow sau khi deploy

```
App start
  → Program.cs: RecurringJob.AddOrUpdate<CentralDbSyncJobs>(..., Cron.Minutely(), queue: "data-sync")
  → CentralDbSyncJobs.RunAsync()
    → Orchestrator đọc checkpoint: pending_initial_sync
    → Orchestrator chọn ChangeTrackingStrategy
    → CT strategy thấy pending_initial_sync → chạy Bootstrap (full read từ ERP)
    → Upsert vào report.partners
    → Ghi checkpoint: sync_status = 'ready', last_sync_version = <version mới>
  → Job chạy mỗi phút → CT incremental sync từ checkpoint version
```

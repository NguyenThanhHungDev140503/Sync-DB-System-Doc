# Config Read Gap — `table_sync_config` không được code đọc

**Ngày:** 2026-07-19  
**Liên quan:** Phase 1 Central DB Sync Pilot

## Vấn đề

Bảng `sync_meta.table_sync_config` trên PostgreSQL hiện là **documentation data** — không có C# code nào đọc từ bảng này.

## Config được hardcode ở đâu?

| Caller | File | Dòng |
|---|---|---|
| Scheduled job (Hangfire) | `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs` | 27-39 |
| HTTP endpoint | `WebApi/Controllers/CentralDbSyncController.cs` | 22-23 (RegisteredTables), 79-91 (TableSyncConfig) |

Cả 2 nơi đều tự tạo `TableSyncConfig` bằng hardcode. `SyncOrchestrator.ExecuteAsync` nhận `TableSyncConfig[]` từ caller — không có interface `ISyncConfigReader` nào tồn tại.

## Các abstraction hiện có

```
Application/Features/CentralDbSync/Abstractions/
├── IBootstrapSnapshotReader.cs   ← đọc snapshot từ MSSQL
├── IChangeTrackingReader.cs      ← đọc CT changes từ MSSQL
├── IFullRefreshReader.cs         ← đọc full data từ MSSQL
├── ISyncBatchApplier.cs          ← ghi data vào PostgreSQL
├── ISyncCheckpointStore.cs       ← đọc/ghi checkpoint
├── ISyncRunLog.cs                ← ghi audit log
└── ITableSyncLock.cs             ← distributed lock

(không có ISyncConfigReader)
```

## Tác động

- Thêm table mới vào sync cần code change ở 2 chỗ + seed SQL → dễ quên
- `table_sync_config` trên DB có thể out-of-sync với hardcode
- Không thể enable/disable table qua DB mà không restart

## Hướng giải quyết (khi cần)

1. Tạo `ISyncConfigReader` interface
2. Implement `PostgresSyncConfigReader : ISyncConfigReader` (query `sync_meta.table_sync_config`)
3. Refactor `CentralDbSyncJobs.RunPilotAsync()` và `CentralDbSyncController` dùng `ISyncConfigReader`
4. Xóa `RegisteredTables` hardcode — validation đọc từ DB

## Xem thêm

- `docs/central-database-blueprint/artifacts/central-db-sync-data-schema.html` (section II)
- `docs/central-database-blueprint/artifacts/central-db-sync-flow.html` (section 7)
- `docs/central-database-blueprint/artifacts/central-db-sync-endpoints.html` (section V)

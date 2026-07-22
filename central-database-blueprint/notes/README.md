# Central DB Sync — Notes Navigation

> Thư mục chứa các ghi chép kỹ thuật trong quá trình phát triển Central DB Sync (Phase 1 Pilot).
> Mỗi file là một note độc lập, ghi lại quyết định, giải thích, audit, issue, hoặc hướng dẫn.

---

## Cấu trúc thư mục

```
notes/
├── README.md                          ← File này
├── 2026-07-19-*.md                    (3 files — ngày 19/07)
├── 2026-07-20-*.md                    (2 files — ngày 20/07)
├── 2026-07-21-*.md                    (11 files — ngày 21/07)
├── Future Implement/                  (trống — chưa có nội dung)
└── Issues Error/
    ├── 2026-07-21-advisory-lock-no-timeout-forever-lock.md
    └── 2026-07-21-checkpoint-unknown-state-infinite-loop.md
```

---

## Tổng quan các notes

### Ngày 19/07 — Pilot Setup

| File | Mô tả | Loại |
|------|-------|------|
| `2026-07-19-admin-role-bypass.md` | Admin role check `AppConst.Admin` **tạm thời bị tắt** trên endpoint bootstrap để test Phase 1 Pilot. Cần re-enable trước UAT/Production. | Decision / Reminder |
| `2026-07-19-config-read-gap.md` | Bảng `sync_meta.table_sync_config` là **dead data** — không code C# nào đọc từ bảng này. Config đang hardcode ở 2 chỗ. Đề xuất tạo `ISyncConfigReader`. | Gap / Technical Debt |
| `2026-07-19-snapshot-isolation-decision.md` | **Quyết định**: KHÔNG bật `ALLOW_SNAPSHOT_ISOLATION` trên shared dev DB. Thay bằng `ReadCommitted` + `WITH (READPAST)` + version verify retry. | Decision |

### Ngày 20/07 — Deployment & Schema

| File | Mô tả | Loại |
|------|-------|------|
| `2026-07-20-deploy-seed.md` | **Hướng dẫn seed** PostgreSQL Central DB trên Railway lần đầu: schema (`001-*.sql`) → seed data (`002-*.sql`). Liệt kê những gì cần / không cần seed. | Guide |
| `2026-07-20-fk-validation-removal.md` | FK constraint `REFERENCES sync_meta.table_sync_config` đã bị xóa khỏi `bootstrap_request`. App-layer validation thay thế. | Decision |

### Ngày 21/07 — Kiến trúc & Flow (Phần lớn notes)

#### Giải thích Kiến trúc (Explained series)

| File | Mô tả | Loại |
|------|-------|------|
| `2026-07-21-advisory-lock-explained.md` | **Advisory lock** chi tiết: `pg_try_advisory_lock`, FNV-1a hash, `AdvisoryLockHandle` lifecycle, các kịch bản lock (Bootstrap + CT cùng lúc, 2 bootstrap requests, CT recovery). | Architecture Explained |
| `2026-07-21-applier-bootstrap-write-explained.md` | **Applier**: Cách ghi bootstrap data vào PostgreSQL — `BuildTargetValues` (map field), `INSERT ON CONFLICT DO UPDATE` (upsert), deactivate orphans, checkpoint, atomicity (1 transaction). | Architecture Explained |
| `2026-07-21-cross-storage-race-design-explained.md` | **Cross-storage race**: Tại sao `SubmitAsync` và Hangfire worker chạy song song? Optimistic lock (`WHERE status IN ...`) giải quyết race giữa PostgreSQL và Hangfire (SQL Server). | Architecture Explained |
| `2026-07-21-ct-checkpoint-invalid-recovery-explained.md` | **CT checkpoint invalid → auto recovery**: Flow từ `CheckpointInvalidException` → `TransitionToFullResyncAsync` → `ExecuteWithProvidedLockAsync` (giữ lock). Đường phục hồi B qua `SyncOrchestrator`. | Architecture Explained |
| `2026-07-21-enqueue-watchdog-explained.md` | **One-shot watchdog**: Cơ chế recover request bị orphan — mỗi request tự động schedule Hangfire job trễ 45s. Nếu submit thành công → no-op. Nếu crash → watchdog enqueue lại. | Architecture Explained |
| `2026-07-21-reader-consistent-snapshot-explained.md` | **Reader + Consistent Snapshot**: Version verify retry (đọc CT version → SELECT → đọc lại → so sánh). `WITH (READPAST)` hint. `CHANGE_TRACKING_CURRENT_VERSION()`. | Architecture Explained |
| `2026-07-21-sync-hang-recovery-deep-dive.md` | **Sync hang scenario deep dive**: Trace khi process treo giữa chừng — `skipped_locked` vs `skipped_dependency`, lock lifecycle, checkpoint state machine (`pending_initial_sync` → `ready` → `requires_full_resync`), auto-recovery paths. | Architecture Explained |
| `2026-07-21-sync-orchestrator-dependency-explained.md` | **SyncOrchestrator + Dependency**: Cách duyệt tuần tự, `AreDependenciesReadyAsync`, checkpoint state ảnh hưởng dependency, 7 kịch bản lỗi & recovery (parent chưa sync, bootstrap fail, transient fail, CT invalid, cancel, treo). | Architecture Explained |
| `2026-07-21-sync-tier-explained.md` | **sync_tier (Hot/Cold)**: Infrastructure đã sẵn sàng ở tất cả layers (schema, model, mapping rule, validation) nhưng **chưa có runtime branching**. Default mapping rule = `"Cold"`, buộc dev set explicit. | Architecture Explained |

#### Audit & TODO

| File | Mô tả | Loại |
|------|-------|------|
| `2026-07-21-dependency-config-inconsistency-audit.md` | **Audit**: 4 vấn đề về dependency config inconsistency — `PostgresSyncConfigStore.SeedAsync()` bỏ qua cột `dependency`, DB column dead data, `MappingRuleValidator` không validate dependency, dual source of truth. | Audit |
| `2026-07-21-admin-alert-auto-recovery-retries.md` | **TODO**: Admin alert khi recovery retry vượt ngưỡng (≥3 lần Warning, ≥10 lần Critical). Đề xuất `IAlertService` interface + Slack/email notification. | Planned Feature |

---

### Issues Error — Issues đã phát hiện

| File | Severity | Mô tả |
|------|----------|-------|
| `advisory-lock-no-timeout-forever-lock.md` | **Critical** | Advisory lock **không có application-level timeout**. Process treo → lock tồn tại vĩnh viễn, không auto-recovery. Cần DBA kill session thủ công. |
| `checkpoint-unknown-state-infinite-loop.md` | **Critical** | Nhánh `else` catch-all ở `SyncOrchestrator` gây **infinite loop** khi checkpoint mang state lạ. Không có CHECK constraint ở DB. |

---

## Phân loại theo chủ đề

### Decisions (Quyết định thiết kế)
- `2026-07-19-snapshot-isolation-decision.md` — Không dùng Snapshot Isolation
- `2026-07-20-fk-validation-removal.md` — Xóa FK constraint, app-layer validation
- `2026-07-19-admin-role-bypass.md` — Tạm tắt role guard cho Pilot

### Architecture Explained (Giải thích luồng)
- `2026-07-21-advisory-lock-explained.md` — Distributed lock
- `2026-07-21-applier-bootstrap-write-explained.md` — Ghi data vào PostgreSQL
- `2026-07-21-cross-storage-race-design-explained.md` — Race condition handling
- `2026-07-21-ct-checkpoint-invalid-recovery-explained.md` — CT recovery
- `2026-07-21-enqueue-watchdog-explained.md` — Watchdog cơ chế
- `2026-07-21-reader-consistent-snapshot-explained.md` — Snapshot consistency
- `2026-07-21-sync-hang-recovery-deep-dive.md` — Hang scenario & recovery
- `2026-07-21-sync-orchestrator-dependency-explained.md` — Orchestrator & dependency
- `2026-07-21-sync-tier-explained.md` — Hot/Cold tier

### Guides (Hướng dẫn)
- `2026-07-20-deploy-seed.md` — Seed database

### Audit & Technical Debt
- `2026-07-19-config-read-gap.md` — Config read gap
- `2026-07-21-dependency-config-inconsistency-audit.md` — Dependency inconsistency

### Issues (Critical)
- `Issues Error/2026-07-21-advisory-lock-no-timeout-forever-lock.md`
- `Issues Error/2026-07-21-checkpoint-unknown-state-infinite-loop.md`

### Planned Features
- `2026-07-21-admin-alert-auto-recovery-retries.md`

---

## Cách tìm nhanh

- **Muốn hiểu tổng quan kiến trúc?** Đọc các file *Explained theo thứ tự: advisory-lock → applier-bootstrap-write → reader-consistent-snapshot → sync-tier → sync-orchestrator-dependency → ct-checkpoint-invalid-recovery → enqueue-watchdog → cross-storage-race → sync-hang-recovery.
- **Muốn xem các quyết định?** File *Decision, *Removal, *Bypass.
- **Muốn biết issue đang tồn đọng?** Mở thư mục `Issues Error/` + `admin-alert-auto-recovery-retries.md` + `config-read-gap.md`.
- **Muốn deploy?** Đọc `2026-07-20-deploy-seed.md`.
- **Đang implement tính năng mới?** Kiểm tra `dependency-config-inconsistency-audit.md` để fix các lỗ hổng trước khi onboard bảng ref có dependency.

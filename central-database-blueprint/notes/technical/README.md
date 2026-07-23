# Central DB Sync — Technical Explainers

> Thư mục chứa các bài giải thích chuyên sâu (deep-dive) về từng thành phần kiến trúc của Central DB Sync engine.
> Mỗi file là một chủ đề độc lập, có thể đọc riêng lẻ hoặc theo thứ tự flow dữ liệu.

## Cấu trúc file

```
notes/technical/
├── README.md                                    ← File này
├── 2026-07-21-sync-tier-explained.md            SyncTier (Hot/Cold)
├── 2026-07-21-reader-consistent-snapshot-explained.md    Reader
├── 2026-07-21-bootstrap-executecoreasync-explained.md    Bootstrap pipeline
├── 2026-07-21-applier-bootstrap-write-explained.md       Applier
├── 2026-07-21-advisory-lock-explained.md                 Advisory Lock
├── 2026-07-21-sync-orchestrator-dependency-explained.md  SyncOrchestrator
├── 2026-07-21-ct-checkpoint-invalid-recovery-explained.md   CT Recovery
├── 2026-07-21-enqueue-watchdog-explained.md              Watchdog
├── 2026-07-21-cross-storage-race-design-explained.md     Cross-storage Race
├── 2026-07-21-sync-hang-recovery-deep-dive.md            Hang Recovery
├── 2026-07-23-bootstrap-full-flow-explained.md           Bootstrap Full Flow
└── 2026-07-23-metadata-fields-explained.md               Metadata Fields
```

## Danh sách explainers

| # | File | Mô tả | Depth |
|---|------|-------|-------|
| 1 | [`sync-tier-explained.md`](./2026-07-21-sync-tier-explained.md) | **sync_tier** (Hot/Cold): phân loại bảng đồng bộ, infrastructure tại tất cả layers (schema → model → mapping rule → validation → seed). Giải thích tại sao default mapping rule là `"Cold"` và các bảng hiện tại đều là `"Hot"`. | Beginner |
| 2 | [`reader-consistent-snapshot-explained.md`](./2026-07-21-reader-consistent-snapshot-explained.md) | **Reader + Consistent Snapshot**: cơ chế đọc consistent snapshot từ SQL Server mà không cần SNAPSHOT isolation. Version sandwich (`CHANGE_TRACKING_CURRENT_VERSION()` trước/sau SELECT) + retry loop. `WITH (READPAST)` hint để tránh deadlock. | Intermediate |
| 3 | [`bootstrap-executecoreasync-explained.md`](./2026-07-21-bootstrap-executecoreasync-explained.md) | **Bootstrap Pipeline** (`ExecuteCoreAsync`): flow end-to-end của bootstrap sync — Reader (version sandwich) → Applier (upsert + deactivate orphans + checkpoint) → RunLog. Commit tham chiếu `a7757b72`. | Advanced |
| 4 | [`applier-bootstrap-write-explained.md`](./2026-07-21-applier-bootstrap-write-explained.md) | **Applier**: cách ghi bootstrap data vào PostgreSQL — `BuildTargetValues` map field theo column mapping, `INSERT ON CONFLICT DO UPDATE` (upsert), deactivate orphans (còn trong ERP nhưng không có trong snapshot), checkpoint, atomicity trong 1 transaction. | Intermediate |
| 5 | [`advisory-lock-explained.md`](./2026-07-21-advisory-lock-explained.md) | **Advisory Lock**: distributed lock bằng `pg_try_advisory_lock` + FNV-1a hash. `AdvisoryLockHandle` lifecycle. Các kịch bản lock (Bootstrap + CT cùng lúc, 2 bootstrap requests, CT recovery). Session-level vs transaction-level. | Advanced |
| 6 | [`sync-orchestrator-dependency-explained.md`](./2026-07-21-sync-orchestrator-dependency-explained.md) | **SyncOrchestrator + Dependency**: cách duyệt tuần tự các bảng, `AreDependenciesReadyAsync`, checkpoint state ảnh hưởng dependency. 7 kịch bản lỗi & recovery (parent chưa sync, bootstrap fail, transient fail, CT invalid, cancel, treo). Code trace chi tiết. | Advanced |
| 7 | [`ct-checkpoint-invalid-recovery-explained.md`](./2026-07-21-ct-checkpoint-invalid-recovery-explained.md) | **CT Checkpoint Invalid → Auto Recovery**: flow khi CT sync phát hiện checkpoint quá cũ (dưới `CHANGE_TRACKING_MIN_VALID_VERSION`) — tự động transition `requires_full_resync` → bootstrap recovery giữ nguyên lock. Đường phục hồi B qua SyncOrchestrator. | Advanced |
| 8 | [`enqueue-watchdog-explained.md`](./2026-07-21-enqueue-watchdog-explained.md) | **Watchdog**: cơ chế one-shot watchdog 45s để recover orphan request khi process crash. Mỗi request tự động schedule Hangfire job trễ. Nếu submit thành công → watchdog là no-op. Nếu crash → watchdog enqueue lại. | Intermediate |
| 9 | [`cross-storage-race-design-explained.md`](./2026-07-21-cross-storage-race-design-explained.md) | **Cross-storage Race**: optimistic lock giữa PostgreSQL và Hangfire (SQL Server). `SubmitAsync` và Hangfire worker chạy song song — `WHERE status IN (...)` trong UPDATE là cơ chế duy nhất ngăn race. Race window 50ms. | Advanced |
| 10 | [`sync-hang-recovery-deep-dive.md`](./2026-07-21-sync-hang-recovery-deep-dive.md) | **Sync Hang Deep Dive**: trace khi process treo giữa chừng — phân biệt `skipped_locked` vs `skipped_dependency`, lock lifecycle, checkpoint state machine (`pending_initial_sync` → `ready` → `requires_full_resync`), 3 đường auto-recovery. | Advanced |
| 11 | [`bootstrap-full-flow-explained.md`](./2026-07-23-bootstrap-full-flow-explained.md) | **Bootstrap Full Flow**: end-to-end từ API TriggerBootstrap → SubmitAsync → Hangfire Job → ExecuteCoreAsync → Reader → Applier → Orphan Cleanup → Checkpoint → Audit Log. Trace request lifecycle states (`pending_enqueue` → `running` → `completed`). | Intermediate |
| 12 | [`metadata-fields-explained.md`](./2026-07-23-metadata-fields-explained.md) | **Metadata Fields** (`source_system` + `synced_at`): tem nguồn dữ liệu và dấu thời gian sync cuối. Engine tự động thêm vào mọi UPSERT, dùng trong orphan cleanup filter. `NOW()` vs `EXCLUDED` design. | Intermediate |

## Thứ tự đọc đề xuất

Đọc theo flow dữ liệu từ đầu đến cuối:

```text
[1] sync_tier ──→ [2] Reader ──→ [3] Bootstrap Pipeline ──→ [4] Applier
                         │
                    (advisory lock)
                         │
                         ↓
                   [5] Advisory Lock
                         │
                         ↓
              [6] SyncOrchestrator ──→ [7] CT Recovery
                         │                    │
                         │              [8] Watchdog
                         │                    │
                         ↓              [9] Cross-storage Race
                   [10] Hang Recovery

            [11] Bootstrap Full Flow  ← tổng quan end-to-end
            [12] Metadata Fields      ← source_system & synced_at
```

**Luồng tóm tắt:**
1. **sync_tier** — hiểu cách phân loại bảng Hot/Cold
2. **Reader** — đọc consistent snapshot từ SQL Server
3. **Bootstrap Pipeline** — tổng quan end-to-end bootstrap
4. **Applier** — ghi dữ liệu vào PostgreSQL
5. **Advisory Lock** — distributed lock tránh conflict
6. **SyncOrchestrator** — điều phối sync, dependency handling
7. **CT Recovery** — phục hồi khi checkpoint quá cũ
8. **Watchdog** — recover orphan request
9. **Cross-storage Race** — optimistic lock giữa 2 DB
10. **Hang Recovery** — deep dive khi process treo
11. **Bootstrap Full Flow** — API → PostgreSQL end-to-end (tổng quan)
12. **Metadata Fields** — `source_system` & `synced_at`

## Mối quan hệ với các notes khác

Thư mục `technical/` tập trung vào **kiến trúc giải thích** (Explained series), là một phần của hệ thống notes lớn hơn tại [`notes/README.md`](../README.md). Các notes khác bao gồm:

- **Operations & Decisions**: `notes/2026-07-19-*.md`, `notes/2026-07-20-*.md`
- **Audit Reports**: `notes/2026-07-21-dependency-config-inconsistency-audit.md`
- **Issues**: `notes/Issues Error/`
- **Planned Features**: `notes/admin-alert-auto-recovery-retries.md`

Xem [`notes/README.md`](../README.md) để có navigation tổng quan toàn bộ notes.

## Quy ước đặt tên

```
YYYY-MM-DD-chu-de-ngan-gon.md
```

- File trong `technical/` là các explainer chuyên sâu (depth: Intermediate → Advanced)
- Có thể tham chiếu commit hash để trace source code chính xác
- Code snippets được include để minh họa, kèm đường dẫn file đầy đủ

---

*Last updated: 2026-07-23*

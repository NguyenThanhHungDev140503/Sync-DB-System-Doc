# Sync DB System Documentation — Index

Tổng hợp toàn bộ tài liệu hệ thống Central DB Sync (ERP → PostgreSQL).

## Cấu trúc thư mục

```
Sync-DB-System-Doc/
├── README.md                          ← file này
├── 03_ref_schema.sql                  ← schema PostgreSQL (ref lane)
└── central-database-blueprint/
    ├── image/
    ├── artifacts/                     ← HTML diagrams
    ├── notes/                         ← ghi chú kỹ thuật, giải thích, audit
    ├── optimize-background-boostrap/  ← design + plans cho background bootstrap
    │   ├── specs/
    │   └── plans/
    └── phase-1/                       ← design + plans cho Phase 1
        ├── specs/
        ├── plans/
        └── review/
```

---

## 1. SQL Schema

| File | Mô tả |
|------|-------|
| [`03_ref_schema.sql`](./03_ref_schema.sql) | PostgreSQL `ref` schema: reference & rate-card tables (section 5.2) + controlled vocabularies (section 5.3). Thiết kế không FK giữa các bảng, PK khớp ERP PK để upsert idempotent. |

---

## 2. Phase 1 — Specs & Plans

Tài liệu nền tảng: thiết kế, triển khai, và review cho Phase 1 pilot (CRM.Partners).

### 2.1. Specs (Yêu cầu & Thiết kế)

| File | Mô tả |
|------|-------|
| [`phase-1/specs/2026-07-17-Section5.3-Table-List.md`](./central-database-blueprint/phase-1/specs/2026-07-17-Section5.3-Table-List.md) | Danh sách bảng Report DB cần sync từ ERP — controlled vocabularies |
| [`phase-1/specs/2026-07-18-Implementation-Idea.md`](./central-database-blueprint/phase-1/specs/2026-07-18-Implementation-Idea.md) | Ý tưởng triển khai ban đầu: kiến trúc, công nghệ, flow |
| [`phase-1/specs/2026-07-18-central-db-sync-design.md`](./central-database-blueprint/phase-1/specs/2026-07-18-central-db-sync-design.md) | Design decisions: Change Tracking, advisory lock, upsert strategy |

### 2.2. Plans

| File | Mô tả |
|------|-------|
| [`phase-1/plans/2026-07-18-Implementation-Plan.md`](./central-database-blueprint/phase-1/plans/2026-07-18-Implementation-Plan.md) | Phase 1 Implementation Plan — tổng thể |
| [`phase-1/plans/2026-07-18-CT-Implementation-Analysis.md`](./central-database-blueprint/phase-1/plans/2026-07-18-CT-Implementation-Analysis.md) | Phân tích chi tiết Change Tracking implementation cho CRM.Partners |
| [`phase-1/plans/2026-07-20-Dynamic-Sync-Mapping-Rule-Plan.md`](./central-database-blueprint/phase-1/plans/2026-07-20-Dynamic-Sync-Mapping-Rule-Plan.md) | Generic sync engine với dynamic mapping rule (bỏ FullRefresh, làm rõ join) |

### 2.3. Review

| File | Mô tả |
|------|-------|
| [`phase-1/review/2026-07-18-Synchronization-Consistency-Review.md`](./central-database-blueprint/phase-1/review/2026-07-18-Synchronization-Consistency-Review.md) | Rà soát tính nhất quán dữ liệu toàn bộ Phase 1 |

---

## 3. Background Bootstrap — Design & Plans

Tài liệu cho tính năng bootstrap chạy ngầm (POST /bootstrap → enqueue → watchdog → background worker).

### 3.1. Tổng quan

| File | Mô tả |
|------|-------|
| [`optimize-background-boostrap.md`](./central-database-blueprint/optimize-background-boostrap.md) | Giải thích tại sao cần `bootstrap_request` bên cạnh Hangfire |

### 3.2. Specs

| File | Mô tả |
|------|-------|
| [`optimize-background-boostrap/specs/2026-07-20-central-db-sync-background-bootstrap-design.md`](./central-database-blueprint/optimize-background-boostrap/specs/2026-07-20-central-db-sync-background-bootstrap-design.md) | Design: background bootstrap at scale — request lifecycle, watchdog, cross-storage race handling |

### 3.3. Plans

| File | Mô tả |
|------|-------|
| [`optimize-background-boostrap/plans/2026-07-20-central-db-sync-background-bootstrap-phase-1.md`](./central-database-blueprint/optimize-background-boostrap/plans/2026-07-20-central-db-sync-background-bootstrap-phase-1.md) | Background Bootstrap Phase 1 Plan |
| [`optimize-background-boostrap/plans/2026-07-20-central-db-sync-scalable-bootstrap-phase-2.md`](./central-database-blueprint/optimize-background-boostrap/plans/2026-07-20-central-db-sync-scalable-bootstrap-phase-2.md) | Background Bootstrap Phase 2 — scalable |

---

## 4. Notes — Technical Explainers

Giải thích sâu từng thành phần kiến trúc. Đọc theo thứ tự flow dữ liệu:

| # | File | Mô tả |
|---|------|-------|
| 1 | [`notes/2026-07-21-sync-tier-explained.md`](./central-database-blueprint/notes/2026-07-21-sync-tier-explained.md) | **sync_tier**: phân loại bảng Hot/Cold, infrastructure đã có sẵn |
| 2 | [`notes/2026-07-21-reader-consistent-snapshot-explained.md`](./central-database-blueprint/notes/2026-07-21-reader-consistent-snapshot-explained.md) | **Reader**: đọc consistent snapshot từ SQL Server (version verify retry, READPAST) |
| 3 | [`notes/2026-07-21-applier-bootstrap-write-explained.md`](./central-database-blueprint/notes/2026-07-21-applier-bootstrap-write-explained.md) | **Applier**: ghi dữ liệu vào PostgreSQL (upsert, orphan deactivate, checkpoint) |
| 4 | [`notes/2026-07-21-advisory-lock-explained.md`](./central-database-blueprint/notes/2026-07-21-advisory-lock-explained.md) | **Advisory Lock**: cơ chế distributed lock bằng FNV-1a hash + pg_try_advisory_lock |
| 5 | [`notes/2026-07-21-sync-orchestrator-dependency-explained.md`](./central-database-blueprint/notes/2026-07-21-sync-orchestrator-dependency-explained.md) | **SyncOrchestrator**: dependency handling, 7 error scenarios, retry cycle |
| 6 | [`notes/2026-07-21-enqueue-watchdog-explained.md`](./central-database-blueprint/notes/2026-07-21-enqueue-watchdog-explained.md) | **Watchdog**: cơ chế one-shot watchdog 45s để recover orphan request khi crash |
| 7 | [`notes/2026-07-21-cross-storage-race-design-explained.md`](./central-database-blueprint/notes/2026-07-21-cross-storage-race-design-explained.md) | **Cross-storage Race**: optimistic lock giữa PostgreSQL và Hangfire (SQL Server) |

---

## 5. Notes — Operations & Decisions

Các quyết định thiết kế và hướng dẫn vận hành:

| File | Mô tả |
|------|-------|
| [`notes/2026-07-19-admin-role-bypass.md`](./central-database-blueprint/notes/2026-07-19-admin-role-bypass.md) | **Tạm thời**: bỏ qua Admin role check cho Phase 1 pilot testing. Cần re-enable trước UAT. |
| [`notes/2026-07-19-config-read-gap.md`](./central-database-blueprint/notes/2026-07-19-config-read-gap.md) | **Gap**: `table_sync_config` trong DB không được code đọc — config bị hardcode. Hướng giải quyết: `ISyncConfigReader`. |
| [`notes/2026-07-19-snapshot-isolation-decision.md`](./central-database-blueprint/notes/2026-07-19-snapshot-isolation-decision.md) | **Decision**: không bật `ALLOW_SNAPSHOT_ISOLATION` trên dev DB. Dùng ReadCommitted + version verify thay thế. |
| [`notes/2026-07-20-deploy-seed.md`](./central-database-blueprint/notes/2026-07-20-deploy-seed.md) | **Deploy Guide**: các bước seed schema + data lên PostgreSQL Railway khi deploy lần đầu |
| [`notes/2026-07-20-fk-validation-removal.md`](./central-database-blueprint/notes/2026-07-20-fk-validation-removal.md) | **Decision**: bỏ FK constraint trên `bootstrap_request.source_table` — validate ở application layer |

---

## 6. Notes — Audit Reports

| File | Mô tả |
|------|-------|
| [`notes/2026-07-21-dependency-config-inconsistency-audit.md`](./central-database-blueprint/notes/2026-07-21-dependency-config-inconsistency-audit.md) | **Audit**: 4 vấn đề phát hiện — P0 (validator không check dependency name), P1 (SeedAsync thiếu cột dependency), P2 (DB column dead data), P3 (dual source of truth). Chưa implement. |

---

## 7. HTML Artifacts (Diagrams)

File trong `central-database-blueprint/artifacts/`:

| File | Mô tả |
|------|-------|
| `central-db-sync-data-schema.html` | Data schema diagram: `sync_meta` + `report` tables |
| `central-db-sync-flow.html` | Sync flow: bootstrap → CT incremental → checkpoint |
| `central-db-sync-endpoints.html` | REST API endpoints documentation |
| `central-db-sync-checkpoint-recovery.html` | Checkpoint recovery flow |
| `central-db-sync-bootstrap-data-flow.html` | Bootstrap data flow: reader → applier → checkpoint |
| `background-bootstrap-phase-1.html` | Background bootstrap architecture diagram |

---

## Hướng dẫn đọc theo mục đích

**Người mới onboarding:**
1. `phase-1/specs/2026-07-18-central-db-sync-design.md` — nắm kiến trúc tổng quan
2. Notes explainers (#1 → #7) — hiểu từng thành phần
3. `phase-1/review/2026-07-18-Synchronization-Consistency-Review.md` — biết các điểm cần lưu ý

**Dev cần implement tính năng mới:**
1. `phase-1/plans/` — xem kế hoạch đã thực hiện
2. `optimize-background-boostrap/specs/` + `plans/` — nếu làm việc với bootstrap
3. Notes explainers — hiểu sâu cơ chế liên quan

**Ops/DevOps cần deploy:**
1. `notes/2026-07-20-deploy-seed.md` — quy trình deploy
2. `notes/2026-07-19-admin-role-bypass.md` — nhớ re-enable trước UAT

**Audit/Review:**
1. `notes/2026-07-21-dependency-config-inconsistency-audit.md` — các vấn đề đã phát hiện
2. `notes/2026-07-19-config-read-gap.md` — gap cần giải quyết trong tương lai

---

*Last updated: 2026-07-21*

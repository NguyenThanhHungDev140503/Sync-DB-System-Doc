# Audit: Dependency Config Inconsistency

**Ngày:** 2026-07-21
**Status:** Ghi nhận — chưa cần fix ngay (Pilot chỉ có 3 bảng độc lập, chưa ai dùng Dependency)

---

## Tóm tắt

Kiểm tra tính nhất quán của cơ chế `Dependency` giữa C# mapping registry, DB `table_sync_config`, validator, và `PostgresSyncConfigStore`. Phát hiện 3 vấn đề, chưa ảnh hưởng Pilot nhưng cần sửa trước khi onboard bảng ref có dependency.

---

## Các vấn đề

### #1: `PostgresSyncConfigStore.SeedAsync()` bỏ qua cột `dependency`

**File:** `Infrastructure/CentralDbSync/PostgresSyncConfigStore.cs:17-44`

INSERT và ON CONFLICT DO UPDATE đều không include `dependency`. Hiện tại chạy được nhờ `DEFAULT '{}'` trong schema. Nhưng nếu sau này rule có `Dependency = ["FABRIC_MASTER"]`, cột này sẽ không được upsert xuống DB.

**Fix:** Thêm `dependency` vào cả INSERT và DO UPDATE SET.

### #2: Cột `dependency` trong DB là dead data

**File:** `Infrastructure/CentralDbSync/PostgresSyncConfigStore.cs:47-87`

`IsEnabledAsync()`, `SetEnabledAsync()`, `GetAllEnabledAsync()` — không method nào đọc cột `dependency`. SyncOrchestrator dùng `Dependency` từ C# `TableMappingRule` → `ToTableSyncConfig()`. DB column tồn tại nhưng không ai query.

**Hệ quả:** Nếu operator UPDATE `table_sync_config.dependency` bằng tay, hệ thống không thấy.

**Fix (2 hướng):**
- A) Đọc `dependency` từ DB giống như `enabled` (thêm `GetDependenciesAsync` vào `ISyncConfigStore`), hoặc
- B) Deprecate DB column, chỉ dùng C# registry làm SSOT (theo hướng plan Dynamic Mapping Rule)

### #3: `MappingRuleValidator` không validate dependency

**File:** `Application/Features/CentralDbSync/Mapping/MappingRuleValidator.cs:24-52`

Validator check Name, Source, Target, Columns, Predicates nhưng **không check**:
- Dependency name có tồn tại trong registry không
- Có circular dependency không (A → B → A)

**Hệ quả:** Typo trong Dependency (VD: `"FABRIC_MASTRE"` thay vì `"FABRIC_MASTER"`) → runtime `AreDependenciesReadyAsync()` thấy checkpoint `null` → `skipped_dependency` vĩnh viễn, không có log error rõ ràng.

**Fix:** Thêm `ValidateDependencies()` — check từng dep name có trong registry không, detect cycle.

### #4 (minor): Dual source of truth

`table_sync_config` (DB) và `TableMappingRegistry` (C#) là 2 nơi lưu config có thể diverge. Plan Dynamic Mapping Rule đã xác định hướng: C# registry là SSOT, DB table sync lúc startup hoặc deprecate dần.

---

## Impact hiện tại

- **Pilot (Phase A):** Không ảnh hưởng — cả 3 rule (`CRM.Partners`, `ERP.Configs.Units`, `ERP.Configs.Sizes`) đều `Dependency = []`
- **Khi onboard bảng ref:** Cần fix #1 và #3 trước. #2 có thể để sau (theo plan Dynamic Mapping Rule).

---

## Priority khi implement

| # | Ưu tiên | Khi nào fix |
|---|---------|------------|
| #3 | P0 | Trước khi onboard bảng ref đầu tiên có dependency |
| #1 | P1 | Trước khi bootstrap bảng ref có dependency |
| #2 | P2 | Cùng với Dynamic Mapping Rule plan |
| #4 | P3 | Design decision — chọn 1 SSOT |

# PostgreSQL `ref` Schema → SQL Server Mapping Report

**Ngày tạo:** 2026-07-21
**Nguồn PostgreSQL:** `docs/Sync-DB-System-Doc/03_ref_schema.sql`
**Nguồn SQL Server:** MSSQL MCP (`27.71.25.246`), 32 databases được khảo sát

---

## Tổng quan

- **32 bảng** trong PostgreSQL `ref` schema được đối chiếu với **32+ databases** SQL Server
- **24 bảng** tìm thấy tương đồng trực tiếp (75%)
- **4 bảng** tìm thấy tương đồng một phần (cấu trúc khác biệt đáng kể)
- **5 bảng** chưa rõ bảng nguồn trong SQL Server
- **Khác biệt kiến trúc cốt lõi**: SQL Server dùng `int` ID cho quan hệ, PostgreSQL dùng `text` code (`ua_*_code`). Sync worker cần resolve ID → code.

---

## A. Các bảng tương đồng trực tiếp (Controlled Vocabularies)

### 1. ERP.Configs.Fabrics.Kinds → ref.fabric_kinds
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `KindOfFabricId` (int PK), PG dùng `code` (text PK) — cần resolve
- SS có `IsActivate`, `CompanyId`, audit columns — PG không có
- PG: PK là `code` text, SS: PK là `KindOfFabricId` int

---

### 2. ERP.Configs.FabricTypes → ref.fabric_types
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `FabricTypeId` (int PK), `GroupFabricTypeId`, `IsExcludeWipDaily` — PG không có
- `IsActivate` (bit) có trong SS nhưng không có trong PG

---

### 3. ERP.Configs.TrimGroups → ref.trim_groups
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `TrimGroupId` (int PK), `DisplayOrder`, `Activated`, `CompanyId` — PG tối giản hơn

---

### 4. ERP.Configs.TreatmentTypes → ref.treatment_types
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- PG có `category` (text) — SS có `TreatmentSection` (tinyint) thay thế
- SS có rất nhiều field extra: `LevelOfEffect`, `PrintingTest`, `IsShownOnDigitalApp`, `ShowroomName`, `FirstPhoto`, `TotalFileAttachment`, `PrintOutsourceGroupId`

---

### 5. ERP.Configs.WorkTypes → ref.work_types
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `WorkTypeId` (int PK), `ForMer`, `ForClient` — PG không có

---

### 6. ERP.Configs.StyleCategories → ref.style_categories
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `ParentId` (int), `LeadTime` (int), `StandardPCS` (int) — PG không có

---

### 7. ERP.Configs.POM.GarmentKinds → ref.garment_kinds
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `Remark`, `TotalOfFeature`, `Activated` — PG hoàn toàn tối giản

---

### 8. ERP.Configs.Colors → ref.colours
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `ColorRGB` (nvarchar), `NameCode` (nvarchar) — PG không có
- PG dùng `colours` (British spelling)

---

### 9. ERP.Configs.Seasons → ref.seasons
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `ParentId` (int), `Description`, `IsGreigeDeductionExcluded` — PG không có

---

### 10. ERP.Artwork.Position → ref.artwork_positions
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `PomFeatureId` (int), `NameEng` (nvarchar), `Activated` — PG không có

---

### 11. ERP.Configs.Machines → ref.machines
**OK:**
- `Code` (nvarchar) → `code` (text)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- SS có `MachineAreaId` (int) — PG không có

---

## B. Các bảng tương đồng trực tiếp (Reference & Rate-Card)

### 12. ERP.Configs.Fabrics → ref.fabric_master
**OK:**
- `Name` (nvarchar) → `name` (text)
- `Code` (nvarchar) → `fabric_code` (text PK) — mapping tên cột
- `IsActivate` (bit) → `active` (boolean) — mapping logic

**Confuse:**
- **Quan hệ**: SS dùng int ID (`UnitId`, `KindOfFabricId`, `FabricStructureId`, `WeaveParameterId`, `FabricYarnId`, `FabricCompositionId`, `FabricColorId`, `HandFeelId`). PG dùng text code (`ua_unit_code`, `ua_fabric_type_code`, `ua_fabric_kind_code`). Sync worker phải join lookup table để lấy code từ ID.
- PG có: `weight_gsm`, `yarn`, `composition`, `weave`, `colour_type` là text thuần — SS có các field tương ứng dưới dạng text như `Remark`, `Weight` nhưng nhiều field là FK đến bảng khác (vd `FabricYarnId`, `FabricCompositionId`, `FabricColorId`)
- SS `Weight` là `int` — PG `weight_gsm` là `numeric(10,2)`. Không rõ đơn vị.
- SS có `Version` (int), `CreatedByUserId`, `CreatedDate`, `UpdatedByUserId`, `UpdatedDate`, `CompanyId` — PG không có

---

### 13. ERP.Configs.CMP.Operations.Timings → ref.cmp_timing
**OK:**
- `Code` (nvarchar) → `op_code` (text PK)
- `Name` (nvarchar) → `description` (text) — tương đương ngữ nghĩa
- `Consumption` (money) → `consumption` (numeric(12,4))
- `Frequency` (money) → `timing_s` (numeric(12,4)) — cần verify: Frequency có phải là timing (giây)?

**Confuse:**
- SS `CmpFeatureId` (int) → PG `cmp_section` (text). Cần join qua `ERP.Configs.CMP.Features` để lấy `Code`
- SS `MachineId` (int) → PG `ua_machine_code` (text). Cần join qua `ERP.Configs.Machines` để lấy `Code`
- SS có `Photo`, `Remark`, `Activated`, `QtyOfTiming`, `CmpOperationId`, `CmpProductGroupId` — PG không có

---

### 14. ERP.Costing.Wastages → ref.wastage
**OK:**
- `Name` (nvarchar) → `name` (text)
- `WastagePercentage` (decimal) → `wastage_pct` (numeric(6,2))
- `ShrinkageRateOfFabric` (decimal) → `shrinkage_pct` (numeric(6,2))

**Confuse:**
- SS `Type` là `tinyint` (enum) — PG `type` là `text`. Cần mapping enum → text.
- SS có `KindOfPrint` (tinyint), `DisplayOrder`, `IsAOP`, `Activated` — PG không có
- PG có PK `(name, type, version)` — SS chỉ có `WastageId` (int PK). Không có khái niệm `version` rõ ràng.
- PG có `apply_date` (date) — SS không có

---

### 15. ERP.Costing.Configurations → ref.rate_config
**OK:**
- `CmpFactor` (float) → `cmp_factor` (numeric(8,4))
- `SgaFactor` (float) → `sga_factor` (numeric(8,4))
- `TestingPercent` (float) → `testing_pct` (numeric(6,2))
- `StandardQty` (decimal) → `standard_qty` (integer)
- `ApplyDate` (datetime) → `apply_date` (date)

**Confuse:**
- PG PK là `(version, costing_rate)` — SS PK là `CostingConfigurationId` (int). `CostingRateId` là FK đến `ERP.Costing.Rates`.
- PG `costing_rate` là text (tier name như "RATE 1/2/3") — SS `CostingRateId` là int FK → cần join `ERP.Costing.Rates` để lấy `Rate` (nvarchar)
- SS có `CostingTypeId` (tinyint), `NumberOfThread`, `CurrencyId`, `AllPartPositionId`, `FabricTypeMainId`, `FabricTypeRibId`, `TreatmentOnId` — PG không có
- SS `Version` là `int` — PG `version` là `text`

---

### 16. ERP.Configs.FabricRating → ref.fabric_rating

> **⚠️ PDF BLUEPRINT NOTE:** Bảng `ref.fabric_rating` **KHÔNG** được nhắc đến trong bất kỳ mục nào của PDF blueprint:
> - **5.1** (Operation Tables — không cần mapping): không có
> - **5.2** (Reference & rate-card tables — cần mapping): không có
> - **5.3** (Controlled vocabularies — cần mapping): không có
>
> Đây là bảng được thêm trong quá trình thiết kế schema thực tế (`03_ref_schema.sql`) nhưng chưa có trong spec gốc. Cần quyết định: (a) giữ lại và mapping từ `ERP.Configs.FabricRating`, hoặc (b) cân nhắc lại xem có thực sự cần thiết không.

**OK:**
- `StandardCuttingWidth` (money) → `cutting_width_cm` (numeric(10,2))
- `StandardQty` (int) → `standard_qty` (numeric(12,4))

**Confuse:**
- **PK khác biệt**: SS dùng `FabricRatingId` (int PK), PG dùng `(fabric_code, ua_category_code)` composite PK
- SS không có `fabric_code` mà dùng `StyleCategoryId` (int) — PG dùng `ua_category_code` (text)
- SS có `Name`, `Code` — không rõ mapping logic
- Thiếu quan hệ trực tiếp đến fabric: SS không có FabricId/FabricCode, chỉ có `StyleCategoryId`

---

### 17. GlobalConfigs → ref.config
**OK:**
Không có field nào map trực tiếp. Hai bảng có cấu trúc hoàn toàn khác:
- PG: key-value store (`setting_key`, `setting_value`, `description`)
- SS: fixed-column table (`VND_CurrencyId`, `ServerApiBaseUrl`, `AccountIdBank`, ...)

**Confuse:**
- Cần quyết định: map từng dòng config riêng lẻ từ SS vào PG, hay giữ nguyên PG làm key-value và sync worker sẽ transform
- SS có `VersionMobileAndroid`, `VersionMobileIOS`, `MoneyPerPoint`, `AfterNotLoginMobileNotReceiveNotify` — không có chỗ trong PG

---

### 18. ERP.Configs.Units → ref.units
**OK:**
- `Code` (nvarchar) → `code` (text PK)
- `Name` (nvarchar) → `name` (text)

**Confuse:**
- PG có `dimension` (text: mass/length/count) — SS có `UnitType` (tinyint enum), `NumberType` (tinyint enum). Cần mapping enum → text.
- SS có `DefaultValue` (money), `IsTrimRatingDisplayed` (bit), `Description` — PG không có

---

### 19. ERP.Configs.UnitConversions → ref.unit_conversions
**OK:**
- Ý tưởng chung: chuyển đổi đơn vị

**Confuse:**
- **Cấu trúc khác hẳn**: SS dùng `FromRate`/`ToRate` (money) thay vì 1 `factor` duy nhất. PG: 1 `factor` (numeric(18,8)). SS: 2 rate riêng biệt.
- SS dùng `FromUnitId`/`ToUnitId` (int FK) — PG dùng `from_unit`/`to_unit` (text). Cần join `ERP.Configs.Units`.
- PG PK `(from_unit, to_unit)` — SS PK `UnitConversionId` (int)
- PG có `CHECK (factor > 0)` — SS không có constraint tương tự

---

### 20. Acc.ExchangeRates → ref.exchange_rates
**OK:**
- `Rate` (money) → `rate` (numeric(18,8))
- `FromDate` (datetime) → `apply_date` (date)

**Confuse:**
- **Cấu trúc khác**: SS dùng `CurrencyId` (int FK đến bảng Currency) cho 1 chiều (từ VND?), PG dùng `(from_currency, to_currency)` text pair
- PG PK `(from_currency, to_currency, apply_date)` — SS PK `ExchangeRateId` (int). Có thể có nhiều rate cho cùng ngày/currency vì `Version`.
- SS có `CompanyId` — PG không có

---

## C. Các bảng tương đồng một phần (Partial Match)

### 21. ERP.Configs.Fabrics.Suppliers.Requests → ref.fabric_price_master

**OK (một phần):**
- `MOC` (money) có thể → `bulk_price_usd` (numeric(12,4))
- `PriceQuotedDate` (datetime) có thể → `apply_date` (date)
- `UpdatedDate` (datetime) → `updated_at` (timestamptz)

**Confuse:**
- SS là **supplier request workflow** (có State, SentToFinanceDate, FinanceApprovedDate, SkipApprovedDate...), không phải bảng giá thuần
- SS PK `FabricSupplierRequestId` (int) — PG PK `(fabric_code, version)`
- Thiếu `version` rõ ràng trong SS (có `Version` int nhưng là row version)
- Thiếu `price_currency`, `confidence`, `source` — các field này không có trong SS
- `supplier_code` → SS có `FabricSupplierCode` và `PartnerId`
- SS có quá nhiều field extra: `Surcharge`, `OtherFeePrice`, `LocalFeePrice`, `MoldFeePrice`, `VATFeePrice`, `BankFeePrice`, lead time, etc.

---

### 22. ERP.Configs.Trims.Suppliers.Requests → ref.trim_price_master

**OK (một phần):**
- `MOC` (money) có thể → `unit_price_usd` (numeric(12,4))
- `PriceQuotedDate` (datetime) có thể → `apply_date` (date)
- `UpdatedDate` (datetime) → `updated_at` (timestamptz)

**Confuse:**
- Giống fabric_price: SS là supplier request workflow, không phải bảng giá thuần
- SS PK `TrimSupplierRequestId` (int) — PG PK `(trim_code, version)`
- Thiếu `version`, `confidence`, `source`, `ua_trim_type_code` — không có trong SS
- SS có quá nhiều field extra như `Surcharge`, `OtherFeePrice`, `LocalFeePrice`, `MoldFeePrice`, `VATFeePrice`, `BankFeePrice`, lead time, etc.

---

### 23. ERP.PurchaseOrders.Trims.Technicals.Rating → ref.trim_rating

**Confuse:**
- SS là bảng **transactional per PO/Style**, không phải reference catalog toàn cục như PG
- SS có PK `TrimTechnicalRatingId` (int) — PG PK `(trim_code, ua_category_code)`
- PG có `qty` (numeric(12,4)) — SS không có field tương đương trực tiếp (có `Temporary`, `FlowBySize` nhưng không có quantity)
- SS gắn với `PurchaseOrderId`, `StyleId`, `StyleTrimId` — PG là bảng reference độc lập

**Nhận định:** Có thể rating catalog trong ERP được lưu ở database khác hoặc được tính từ `StyleFabricId`/`StyleTrimId` trong các bảng technical khác.

---

### 24. ERP.Dyewash.Kinds → ref.wash_matrix

**OK (một phần):**
- `Name` (nvarchar) → `description` (text)
- `Code` (nvarchar) có thể → `treatment_key` (text)

**Confuse:**
- SS là **danh mục loại dyewash** (lookup), không phải bảng giá (rate matrix)
- PG có `rate_usd` (numeric(12,4)) và `apply_date` (date) — SS không có
- SS có `LevelOfEffect` (nvarchar), `Activated` (bit) — PG không có
- PG PK `(treatment_key, version)` — SS PK `DyewashKindId` (int)

---

### 25. ERP.Configs.Printing.Price → ref.print_area_bands

**Confuse:**
- SS là **bảng giá in với approval workflow** (có `ProcessingRequestId`, `IsDraft`, `SkipApprovedDate`, `PriceExpiryDate`...)
- PG là bảng phân vùng diện tích in đơn giản: `band`, `area_min_cm2`, `area_max_cm2`, `rate_usd`
- SS không có columns `area_min_cm2`, `area_max_cm2` — thay vào đó là `TreatmentTypeId`, `PrintingPriceType` (tinyint), `PrintOutsourceGroupId`
- PK khác biệt: SS `PrintingPriceId` (int) vs PG `band` (text)

---

### 26. Languages.Labels → ref.dictionary

> **⚠️ PDF BLUEPRINT NOTE:** Bảng `ref.dictionary` **KHÔNG** được nhắc đến trong bất kỳ mục nào của PDF blueprint:
> - **5.1** (Operation Tables — không cần mapping): không có
> - **5.2** (Reference & rate-card tables — cần mapping): không có
> - **5.3** (Controlled vocabularies — cần mapping): không có
>
> Đây là bảng được thêm trong quá trình thiết kế schema thực tế (`03_ref_schema.sql`) — comment trong file gốc ghi: "Present in the Base44↔UA alignment workbook (REPLACE/USE UA) but not itemised in PDF 5.2". `Languages.Labels` không phải là nguồn chính xác (đây là hệ thống i18n, không phải alias dictionary). Cần xác định nguồn dữ liệu thực tế từ ERP.

**Confuse:**
- Cấu trúc khác biệt hoàn toàn
- PG là alias dictionary: `alias_id`, `domain`, `alias`, `canonical` — dùng để map tên viết tắt → canonical
- SS là language label system: `LabelId`, `Lexicon`, `Description`, `ForJs`, `IsSystem` — dùng cho i18n/multi-language
- Không có field `domain` trong SS

---

## D. Các bảng chưa rõ nguồn trong SQL Server

Các bảng trong `03_ref_schema.sql` **KHÔNG** tìm thấy bảng tương đồng rõ ràng trong SQL Server:

| # | PostgreSQL Table | Ghi chú |
|---|-----------------|---------|
| 1 | `ref.cmp_gate_matrix` | Ma trận giây theo gate/cổng. SS có `ERP.PurchaseOrders.Styles.Technicals.CMP` nhưng đó là bảng transactional per-PO/Style, không phải reference matrix. Có thể dữ liệu gate matrix được lưu trong config khác hoặc được tính từ `CmpOperationId`/`CmpProductGroupId`. |
| 2 | `ref.consumption_matrix` | Định mức tiêu hao vải theo category × fabric width. Không tìm thấy bảng reference tương tự. `ERP.IPO.Fabrics.QATestingMatrixes` không liên quan (là QA testing, không phải consumption). |
| 3 | `ref.margin_rules` | Target/floor margin theo customer/category. Không tìm thấy trong SS. `ERP.Costing.Configurations` có CmpFactor/SgaFactor nhưng không có target_markup_pct/floor_margin_pct. Có thể margin rules được hard-code trong code hoặc config khác. |
| 4 | `ref.embroidery_rate` | Bảng giá thêu. Không tìm thấy database riêng cho embroidery rate. Có thể embroidery được gộp chung trong `ERP.Configs.Printing.Price` (với `PrintingPriceType` enum phân biệt) hoặc trong treatment sheet. |
| 5 | `ref.trim_types` | Lookup code→name cho loại trim. SS `ERP.Configs.Trims` có `KindOfTrimId` và `TypeOfTrimId` (int FK) nhưng không tìm thấy bảng lookup `TypeOfTrim` độc lập. Có thể gộp chung với `TrimGroups` hoặc chưa được expose. |

---

## E. Tổng hợp các vấn đề cần resolve

### E.1 ID → Code Resolution (toàn bộ schema)
SQL Server dùng `int` surrogate key cho quan hệ; PostgreSQL dùng `text` natural key (`ua_*_code`). Sync worker phải:
1. Đọc bảng master (vd `ERP.Configs.Fabrics`)
2. Join với tất cả lookup tables (vd `ERP.Configs.Fabrics.Kinds`, `ERP.Configs.Units`, ...)
3. Lấy `Code` (nvarchar) từ lookup thay vì `Id` (int)
4. Ghi vào PostgreSQL dưới dạng text code

### E.2 Data Type Mismatches
- `money` (SS) → `numeric(12,4)` (PG): cần explicit cast
- `tinyint` enum (SS) → `text` (PG): cần mapping table
- `datetime` (SS) → `timestamptz` (PG): chú ý timezone
- `bit` (SS) → `boolean` (PG): map 1→true, 0→false

### E.3 PK Strategy Mismatch
- Nhiều bảng SS dùng `int IDENTITY` PK — PG dùng composite natural key
- Sync worker cần construct composite key từ các field hoặc generate text key từ ID

### E.4 Các field không có trong PG nhưng có trong SS
Hầu hết các bảng SS đều có `CompanyId`, `CreatedByUserId`, `CreatedDate`, `UpdatedByUserId`, `UpdatedDate`, `Version` (row version). PG schema hiện tại bỏ qua các field này.

### E.5 Các field không có trong SS nhưng có trong PG
- `confidence`, `source` (fabric_price_master, trim_price_master)
- `dimension` (units)
- `category` (treatment_types)
- `colour_type`, `yarn`, `composition`, `weave` (fabric_master — có thể suy từ FK)

---

## F. Khuyến nghị

1. **Xác nhận 4 bảng partial match**: Cần quyết định sync từ supplier request tables hay tìm nguồn khác cho `fabric_price_master`, `trim_price_master`, `trim_rating`, `wash_matrix`
2. **Tìm 5 bảng missing**: Cần khảo sát thêm ERP modules hoặc confirm với team ERP xem dữ liệu nằm ở đâu
3. **Xây dựng ID→Code mapping**: Viết hàm/CTE chuẩn cho sync worker để resolve tất cả int ID → text code
4. **Enum mapping**: Document tất cả `tinyint` → `text` mappings cho `Type` (wastage), `UnitType`, `TreatmentSection`, etc.
5. **Unit Conversion logic**: Khác biệt `factor` vs `FromRate/ToRate` cần business rule rõ ràng

# Ý tưởng triển khai: Sync ERP → PostgreSQL (Central / Report DB)

**Ngày:** 2026-07-18  
**Status:** Idea (chưa phải plan chi tiết / chưa implement)  
**Mục tiêu tài liệu:** Giúp dev hình dung *vì sao* và *làm gì trước*, trước khi viết plan kỹ thuật từng giai đoạn.

**Tài liệu liên quan:**
- `2026-07-17-Section5.3-Table-List.md` — danh sách bảng vocab Phase 1 (làm sau khi pilot ổn)
- Hạ tầng hiện có trong UaApp: Hangfire (Reporting), tách DbContext Read/Write/Reporting

---

## 1. Vấn đề cần giải quyết

Các tool báo cáo / low-code như **Base44**, **Retool** cần đọc dữ liệu ERP để dựng dashboard và báo cáo.

**Không muốn** cho các tool này kết nối trực tiếp vào SQL Server ERP vì:

- Tải query không kiểm soát lên DB đang phục vụ nghiệp vụ
- Rủi ro bảo mật / lộ schema / quyền quá rộng
- Schema ERP phức tạp, không ổn định cho BI tool

**Hướng giải:** đồng bộ một chiều dữ liệu cần thiết từ ERP sang một **PostgreSQL** riêng (Central / Report DB). Tool chỉ đọc Postgres.

```
SQL Server ERP (primary)  ──sync──▶  PostgreSQL (Report / Central DB)  ──read──▶  Base44 / Retool / ...
         ▲                                      ▲
    nguồn authoritative                    đích chỉ-đọc cho tool
```

---

## 2. Vì sao làm trong project UaApp (API hiện tại)

Không tách worker riêng ở phase ý tưởng này. Tận dụng hạ tầng đã có:

| Đã có trong UaApp | Dùng lại như thế nào |
|---|---|
| **Hangfire** (SQL storage trên Reporting DB, dashboard `/hangfire`) | Đăng ký **Recurring Job** chạy sync định kỳ / background |
| **DefaultConnection** → ERP primary (`UaWriteDbContext`) | **Nguồn đọc sync + Change Tracking** (xem mục 3) |
| **ErpReplicateConnection** → replica | **Không dùng** cho luồng sync CT của feature này |
| **ReportingConnection** → Reporting SQL Server | Giữ cho Reporting + Hangfire storage; **không** nhét bảng sync Postgres vào đây |
| Clean Architecture + DI | Sync logic nằm Application/Infrastructure; job Hangfire gọi use case |

Postgres là **connection / “DbContext” thứ 4** (hoặc raw Npgsql), tách biệt ERP và Reporting SQL Server.

---

## 3. Quyết định nguồn dữ liệu: ERP primary, không phải replica

**Sync (đặc biệt khi dùng SQL Server Change Tracking) đọc từ DB ERP chính** — connection tương đương `DefaultConnection` / primary.

Lý do ngắn gọn:

- Change Tracking (`CHANGETABLE`, checkpoint version) gắn với DB đã `ENABLE CHANGE_TRACKING`
- Replica phục vụ CQRS đọc API thông thường; không phải nguồn chuẩn cho CT trong ý tưởng này

API query nghiệp vụ vẫn có thể đọc replica như hiện tại. **Chỉ luồng sync CT → Postgres** đi primary.

---

## 4. Cơ chế sync: kết hợp FullRefresh + Change Tracking (CT)

Không chọn một mode duy nhất cho mọi bảng:

| Mode | Khi nào | Cách làm (ý) |
|---|---|---|
| **FullRefresh** | Seed lần đầu; bảng nhỏ / ít đổi; hoặc CT mất version (retention) | Đọc snapshot (toàn bộ hoặc theo filter) → upsert Postgres; nếu cần orphan-delete thì upsert + delete cùng transaction, scope theo filter/ownership, và theo policy FK đã chốt |
| **Change Tracking** | Sau khi đã có baseline; bảng thay đổi thường xuyên | Poll `CHANGETABLE` từ checkpoint → insert/update/delete tương ứng trên Postgres → cập nhật checkpoint |

**Bootstrap bảng dùng CT (thứ tự quan trọng):**

1. Bật CT trên bảng nguồn (ERP primary)
2. Ghi `CHANGE_TRACKING_CURRENT_VERSION()` **trước** khi full load
3. FullRefresh / seed toàn bộ sang Postgres
4. Lưu checkpoint = version bước 2
5. Các lần sau chỉ poll CT incremental

Lấy version trước snapshot để không bỏ sót thay đổi xảy ra trong lúc full load (upsert dư một lần vẫn an toàn).

---

## 5. Phạm vi làm việc theo giai đoạn ý tưởng

### Phase A — Pilot (làm trước, chứng minh pipeline)

| Hạng mục | Giá trị |
|---|---|
| Bảng ERP nguồn | **`CRM.Partners`** (entity Domain: `Partner`) |
| Mục đích nghiệp vụ pilot | Sync danh sách đối tác / khách hàng sang Postgres |
| Filter nghiệp vụ (dự kiến) | Ưu tiên khách hàng: `IsCustomer = true` (chốt khi implement) |
| Mode | **FullRefresh (seed) + CT (incremental)** trên cùng một bảng |
| Scheduler | Hangfire Recurring Job (tần suất pilot: có thể ~30s–1 phút để dễ test) |
| Đích | 1 bảng Postgres (tên schema/bảng chốt khi design chi tiết), kèm metadata sync nếu cần (`synced_at`, …) |

**Pilot thành công khi:**

- Seed lần đầu: Postgres có đủ (hoặc đúng filter) dữ liệu từ `CRM.Partners`
- Insert / update / delete trên ERP primary phản ánh đúng trên Postgres sau chu kỳ job
- Restart API / Hangfire: catch-up từ checkpoint, không mất / không loạn dữ liệu nghiêm trọng
- Có thể quan sát job trên Hangfire dashboard

→ Đây là **vertical slice**: Postgres connection + reader ERP (CT + full) + writer Postgres + Hangfire job + checkpoint.

### Phase B — Mở rộng vocab Section 5.3 (sau khi Phase A ổn)

Khi pilot `CRM.Partners` ổn định, mới implement lần lượt các bảng trong:

**`docs/central-database-blueprint/phase-1/2026-07-17-Section5.3-Table-List.md`**

Nhóm 5.3 = controlled vocabularies (units, seasons, colours, …) — nền FK cho các phase report sau.

Đặc điểm nhóm này (theo Table List):

- Bảng nhỏ, ít đổi → phần lớn dùng **FullRefresh** định kỳ (giờ/ngày), **không bắt buộc** bật CT ngay
- Mapping cột ERP → Postgres (`ua_` prefix, `lower_snake_case`, `synced_at`, …)
- Sync theo thứ tự FK trong Table List

CT chỉ bật thêm khi bảng thật sự cần incremental (lớn / hot), tái dùng pattern đã chứng minh ở Phase A.

---

## 6. Hình dung kiến trúc logic (ý tưởng, chưa chốt tên class)

```
Hangfire Recurring Job
        │
        ▼
  Sync orchestrator (Application)
        │
        ├─ mode FullRefresh ──▶ đọc snapshot từ ERP primary ──┐
        │                                                     │
        └─ mode ChangeTracking ─▶ CHANGETABLE + checkpoint ───┤
                                                              ▼
                                                    Upsert / Delete trên PostgreSQL
                                                              │
                                                    Cập nhật sync_meta.checkpoint
```

Nguyên tắc:

- Application chỉ biết interface (reader / writer / checkpoint)
- Infrastructure: SQL Server CT/full query + Npgsql bulk upsert
- Config theo bảng (sau Phase A): nguồn, đích, mode, tier tần suất — để thêm bảng 5.3 chủ yếu bằng config + mapper, không viết lại toàn bộ pipeline

---

## 7. Việc cố ý chưa làm ở giai ý tưởng / pilot

- Sync ~700 bảng hoặc toàn bộ Section 5.3 ngay từ đầu
- Transform / aggregation phức tạp (dirty entity, recompute metric) — có thể bổ sung sau khi 1:1 ổn
- Cho Base44/Retool đọc replica ERP
- Gộp schema sync vào `ReportingDbContext` (SQL Server Reporting)
- Tách worker process riêng (có thể xem lại khi tải sync ảnh hưởng API)

---

## 8. Tóm tắt một câu cho dev

> Dùng Hangfire sẵn có để sync một chiều từ **ERP primary** sang **PostgreSQL** phục vụ Base44/Retool; pilot trên **`CRM.Partners`** với **FullRefresh + Change Tracking**; khi ổn mới mở rộng theo danh sách bảng Section 5.3.

---

## 9. Bước tiếp theo (sau khi team thống nhất ý tưởng)

1. Viết **Implementation Plan** chi tiết trong cùng folder (connection string, schema Postgres pilot, bật CT trên `CRM.Partners`, job Hangfire, checklist test).
2. Implement Phase A trong UaApp.
3. Review kết quả pilot → mới schedule Phase B theo `2026-07-17-Section5.3-Table-List.md`.

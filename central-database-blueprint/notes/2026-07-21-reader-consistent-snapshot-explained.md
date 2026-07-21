# Reader & Consistent Snapshot

**Ngày:** 2026-07-21

## Vấn đề

Bootstrap cần đọc **toàn bộ dữ liệu** từ SQL Server (VD: `CRM.Partners`) và ghi vào PostgreSQL. Trong lúc đọc, ERP vẫn đang hoạt động — nhân viên thêm mới partner, sửa tên, xóa partner cũ.

Làm sao để đảm bảo: snapshot dữ liệu bootstrap khớp với checkpoint version? Nếu không, sau này CT sync sẽ bị lệch.

## Giải pháp: Version Verify Retry

```text
Mở transaction
    │
    ├── 1. Đọc CT version hiện tại → baseline = 100
    │
    ├── 2. SELECT TOÀN BỘ dữ liệu (có thể mất vài giây)
    │
    ├── 3. Đọc CT version lại → versionAfter = ?
    │
    ├── baseline == versionAfter?
    │   ├── YES → COMMIT, dùng snapshot này
    │   └── NO  → ROLLBACK, thử lại (tối đa 3 lần)
    │
    └── Hết 3 lần → throw exception
```

## Ví dụ cụ thể

### Trường hợp 1: Không có ai thay đổi data trong lúc đọc

```text
Thời gian:  t1              t2              t3
ERP:        [không có DML]                
Reader:     [CT version=100] [SELECT...] [CT version=100]
                                           └── 100 == 100 → OK
```

Kết quả: Lấy snapshot version 100, commit.

### Trường hợp 2: Có người thêm partner trong lúc đọc

```text
Thời gian:  t1              t2              t3              t4
ERP:                        [INSERT partner]                    
Reader:     [CT version=100] [SELECT...]     [CT version=101]
                                              └── 100 ≠ 101 → ROLLBACK
                                              └── thử lại lần 2
```

Kết quả: Rollback, mở transaction mới, SELECT lại từ đầu.

## Tại sao không dùng Snapshot Isolation?

SQL Server có `SET TRANSACTION ISOLATION LEVEL SNAPSHOT` — cho phép đọc consistent snapshot mà không bị ảnh hưởng bởi concurrent DML.

**Nhưng code dùng ReadCommitted + version verify vì:**
- Snapshot Isolation yêu cầu bật ở cấp database (`ALLOW_SNAPSHOT_ISOLATION ON`) — team không muốn ảnh hưởng dev DB dùng chung
- Version verify đơn giản, không cần config database
- Snapshot Isolation tốn tempdb version store — không free

## Vai trò của READPAST

`WITH (READPAST)` là hint báo SQL Server: **bỏ qua các row đang bị lock**, đọc các row khác.

```sql
SELECT ... FROM [dbo].[CRM.Partners] AS [t0] WITH (READPAST)
```

### Ví dụ

Có transaction khác đang UPDATE partner ID = 5:

```text
Transaction A: UPDATE CRM.Partners SET Name = 'ABC' WHERE PartnerId = 5 (đang chạy, chưa commit)
Transaction B (Reader): SELECT ... WITH (READPAST)
    ├── PartnerId 1 → đọc được
    ├── PartnerId 2 → đọc được
    ├── PartnerId 5 → BỎ QUA (đang bị lock)
    ├── PartnerId 6 → đọc được
    └── Tổng: 999 rows (thiếu row 5)
```

### Rủi ro của READPAST

Nếu row duy nhất bị lock, reader sẽ miss row đó → snapshot thiếu dữ liệu:

```text
ERP có 1 partner duy nhất (PartnerId = 1)
Transaction A: đang UPDATE partner 1 (chưa commit)
Reader: SELECT WITH READPAST → 0 rows!
```

**Cách phòng chống:**
1. Reader dùng **ERP Replica connection** (read-only replica) — tránh lock từ transaction chính
2. Nếu có concurrent DML, version sẽ thay đổi → version verify phát hiện → rollback + retry
3. Nếu version không thay đổi (DML được rollback) → snapshot thiếu row → không phát hiện được

Đây là rủi ro đã biết, được chấp nhận vì bootstrap là thao tác thủ công, có thể retry nếu cần.

## Chi tiết implementation

### Luồng code

```csharp
// Infrastructure/CentralDbSync/SqlServerGenericReader.cs:22-69
async Task<BootstrapSnapshot> IBootstrapSnapshotReader.ReadAsync(
    TableSyncConfig config, CancellationToken ct)
{
    var rule = ruleProvider.Get(config.SourceTable);

    // Mở connection đến SQL Server
    await using var conn = new SqlConnection(connectionString);
    await conn.OpenAsync(ct);

    // Retry tối đa 3 lần
    for (var attempt = 1; attempt <= MaxBootstrapRetries; attempt++)
    {
        // Bước 1: Mở transaction ReadCommitted
        await using var tx = await conn.BeginTransactionAsync(
            IsolationLevel.ReadCommitted, ct);

        try
        {
            // Bước 2: Đọc CT version → baseline
            var baseline = await conn.ExecuteScalarAsync<long>(
                "SELECT CHANGE_TRACKING_CURRENT_VERSION()",
                transaction: tx);

            // Bước 3: SELECT data
            var select = sqlBuilder.BuildBootstrapSelect(rule);
            var rows = await ReadRowsAsync(conn, tx, select, ct);

            // Bước 4: Đọc CT version lại
            var versionAfter = await conn.ExecuteScalarAsync<long>(
                "SELECT CHANGE_TRACKING_CURRENT_VERSION()",
                transaction: tx);

            // Bước 5: So sánh
            if (baseline == versionAfter)
            {
                // Khớp → commit, trả về snapshot
                await tx.CommitAsync(ct);
                return new BootstrapSnapshot(baseline, rows);
            }

            // Không khớp → rollback, thử lại
            await tx.RollbackAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(ct);
            throw;
        }
    }

    // Hết 3 lần → throw
    throw new InvalidOperationException(
        "Failed to capture consistent snapshot after 3 attempts.");
}
```

### CHANGE_TRACKING_CURRENT_VERSION là gì?

Là hàm của SQL Server Change Tracking, trả về **số version hiện tại** của database. Mỗi lần có INSERT/UPDATE/DELETE trên bất kỳ table nào có bật Change Tracking, version này tăng lên 1.

```sql
-- VD: chưa có thay đổi → version = 100
SELECT CHANGE_TRACKING_CURRENT_VERSION();  -- 100

-- Có người INSERT partner → version tự động tăng
SELECT CHANGE_TRACKING_CURRENT_VERSION();  -- 101
```

**Lưu ý:** Version là **database-wide**, không phải per-table. INSERT trên table `Units` cũng làm tăng version — dù bạn chỉ đang đọc `Partners`.

## Kết quả: BootstrapSnapshot

Sau khi đọc thành công, dữ liệu được đóng gói:

```csharp
// Application/Features/CentralDbSync/Models/BootstrapSnapshot.cs
public sealed record BootstrapSnapshot(
    long BaselineVersion,               // CT version tại thời điểm snapshot
    IReadOnlyList<GenericSourceRow> Rows  // danh sách rows
);

// Mỗi row là Dictionary<string, object?> keyed bằng alias của SELECT
public sealed record GenericSourceRow(IReadOnlyDictionary<string, object?> Values);
```

VD snapshot cho `CRM.Partners` có 2 rows:

```text
BaselineVersion: 100
Rows:
  [
    { partner_id: 1, company_id: 100, code: "ABC", name: "Cty ABC", is_customer: true, ... },
    { partner_id: 2, company_id: 100, code: "XYZ", name: "Cty XYZ", is_customer: false, ... }
  ]
```

## Tổng quan luồng

```text
BootstrapSyncService.ExecuteCoreAsync
    │
    ├── reader.ReadAsync(config)
    │       │
    │       ├── [SQL Server] BEGIN TRAN ReadCommitted
    │       ├── [SQL Server] SELECT CHANGE_TRACKING_CURRENT_VERSION() → 100
    │       ├── [SQL Server] SELECT ... FROM CRM.Partners WITH (READPAST) → rows
    │       ├── [SQL Server] SELECT CHANGE_TRACKING_CURRENT_VERSION() → 100
    │       ├── 100 == 100? → YES
    │       ├── [SQL Server] COMMIT
    │       └── return BootstrapSnapshot(baseline: 100, rows: 1000 rows)
    │
    └── (tiếp theo: applier.ApplyBootstrapAsync)

Nếu version thay đổi:

    ├── 100 != 101? → NO
    ├── [SQL Server] ROLLBACK
    ├── retry lần 2 → BEGIN TRAN → version=101 → SELECT → version=101 → OK
    └── return BootstrapSnapshot(baseline: 101, rows: 1000 rows)
```

## Ví dụ hình dung

Bạn muốn chụp ảnh một đàn chim đang bay:

```text
Cách 1: Snapshot Isolation
    ── Dùng máy ảnh siêu tốc, chụp một phát → đóng băng toàn bộ khung cảnh
    ── Nhưng cần cài đặt đặc biệt (ALLOW_SNAPSHOT_ISOLATION ON)

Cách 2: Version Verify (cách code đang dùng)
    ── Bước 1: Đếm số chim hiện tại → "có 100 con"
    ── Bước 2: Chụp ảnh (mất 3 giây)
    ── Bước 3: Đếm lại → "có 100 con"
    ── Nếu 2 lần đếm khớp → ảnh chụp đại diện đúng cho thời điểm "100 con"
    ── Nếu không khớp → xóa ảnh, chụp lại
```

## Mã nguồn

| File | Vai trò |
|---|---|
| `Infrastructure/CentralDbSync/SqlServerGenericReader.cs:22-69` | Core logic: version verify retry loop |
| `Infrastructure/CentralDbSync/SqlServerGenericReader.cs:126-141` | ReadRowsAsync — đọc SqlDataReader thành GenericSourceRow list |
| `Infrastructure/CentralDbSync/SqlServerGenericReader.cs:170-179` | ReadSourceRow — chuyển 1 row thành Dictionary |
| `Application/Features/CentralDbSync/Models/BootstrapSnapshot.cs:3-5` | Snapshot DTO |
| `Application/Features/CentralDbSync/Models/GenericSourceRow.cs:3-16` | Dictionary-backed row model |
| `Infrastructure/CentralDbSync/Sql/SqlServerSqlBuilder.cs:8-25` | Build SELECT từ TableMappingRule |

# TODO: Admin Alert khi Recovery Retry vượt ngưỡng

**Ngày:** 2026-07-21  
**Status:** Planned — chưa implement

## Vấn đề

Hiện tại, khi CT checkpoint invalid, hệ thống tự động chạy Bootstrap recovery. Nếu recovery thất bại liên tục (vd: SQL Server down, network partition, data corruption), checkpoint mắc kẹt ở 🟡 `requires_full_resync` và cứ retry mỗi phút qua `SyncOrchestrator` (đường phục hồi B). Không có cơ chế nào thông báo cho Admin biết tình trạng này.

Admin chỉ biết khi:
- Chủ động query `sync_meta.checkpoint` thấy `consecutive_failure_count` tăng cao
- Chủ động query `sync_meta.sync_run_log` thấy repeated `failed`
- Child tables mãi không sync được (vẫn `skipped_dependency`)

## Giải pháp đề xuất

Thêm cơ chế gửi notification (email/Slack/webhook) khi `consecutive_failure_count` của một bảng vượt ngưỡng cấu hình được.

### Trigger point

Hai nơi có thể trigger:

**1. Trong `BootstrapSyncService.ExecuteCoreAsync`** — mỗi lần bootstrap fail:

```csharp
// BootstrapSyncService.cs:118-135 — thêm sau khi ghi run log
if (shouldAlert(consecutiveFailureCount))
{
    await alertService.SendAsync(new RecoveryStuckAlert
    {
        SourceTable = config.SourceTable,
        ConsecutiveFailures = consecutiveFailureCount,
        LastError = ex.Message,
        Severity = consecutiveFailureCount >= criticalThreshold ? "CRITICAL" : "WARNING"
    });
}
```

**2. Trong `SyncOrchestrator.ExecuteAsync`** — khi phát hiện 🟡 ở đầu cycle (đường B).

### Ngưỡng đề xuất

| Mức | Threshold | Hành động |
|---|---|---|
| Warning | ≥ 3 lần | Gửi Slack notification |
| Critical | ≥ 10 lần | Gửi email + Slack + tạo incident ticket |

### Dữ liệu cần trong notification

- `source_table` — bảng nào đang gặp vấn đề
- `consecutive_failure_count` — đã fail bao nhiêu lần liên tiếp
- `last_error_code` + `last_error_message` — lỗi gần nhất là gì
- `sync_status` — trạng thái hiện tại (`requires_full_resync`)
- `last_success_at` — lần cuối sync thành công là khi nào
- Timestamp — thời điểm alert được gửi

### Implementation notes

- Dùng `IAlertService` interface trong Application layer, implement trong Infrastructure (Slack webhook, SMTP, v.v.)
- Đảm bảo alert không spam: gửi tối đa 1 lần mỗi N phút cho cùng một bảng (dedup bằng `source_table`)
- Cấu hình threshold qua `appsettings.json` hoặc `ref.config`
- Alert gửi trong `CancellationToken.None` context (không bị cancel khi sync job timeout)

## File cần sửa

| File | Thay đổi |
|---|---|
| `Application/Features/CentralDbSync/Abstractions/` | Thêm `IAlertService` interface |
| `Application/Features/CentralDbSync/Services/BootstrapSyncService.cs` | Gọi alert sau khi bootstrap fail |
| `Application/Features/CentralDbSync/Services/SyncOrchestrator.cs` | Gọi alert khi thấy 🟡 + high failure count |
| `Infrastructure/CentralDbSync/` | Implement `SlackAlertService` / `SmtpAlertService` |
| `appsettings.json` | Thêm `AlertThresholds` section |

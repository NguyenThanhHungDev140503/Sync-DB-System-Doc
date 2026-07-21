# Toi uu background bootstrap: tai sao can `bootstrap_request` ben canh Hangfire?

**Muc dich:** giai thich cho nguoi moi tai sao luong bootstrap Central DB dung
ca Hangfire va bang `sync_meta.bootstrap_request`, thay vi chi dung Hangfire.

## Tra loi ngan gon

Hangfire biet **cach chay mot viec nen**. `bootstrap_request` biet **y nghia
nghiep vu cua mot lan bootstrap**.

Hai thanh phan bo sung cho nhau, khong trung lap:

| Thanh phan | Tra loi cau hoi gi? |
|---|---|
| Hangfire | "Khi nao va o worker nao can goi method nay?" |
| `bootstrap_request` | "Admin da yeu cau bootstrap bang nao, dang o trang thai nao, va ket qua ra sao?" |

Co the hinh dung:

- Hangfire la **tai xe giao hang**: nhan viec, xep hang, thu lai khi can.
- `bootstrap_request` la **phieu giao hang**: ma theo doi, nguoi gui, trang thai,
  tien do va loi nghiep vu.

Tai xe co the doi, chuyen xe hoac giao lai. Phieu giao hang van la mot phieu
duy nhat de nguoi gui theo doi.

## Luong xu ly

```text
Admin goi POST /bootstrap/CRM.Partners
        |
        v
1. Tao hoac lay lai bootstrap_request (runId = A)
   status = pending_enqueue
        |
        v
2. Enqueue Hangfire job, truyen sourceTable va runId A
        |
        v
3. Worker Hangfire claim phieu A va chay bootstrap
   pending_enqueue -> queued -> running
        |
        +--> thanh cong: completed
        +--> lock dang ban: waiting_for_lock -> queued (hen lai)
        +--> loi: failed
        |
        v
GET /bootstrap/{runId} doc bootstrap_request de tra status cho API
```

`runId` (hay `request_id`) la ma theo doi on dinh ma API tra ve. Hangfire job ID
la chi tiet van hanh; no co the thay doi khi job duoc hen lai hoac tao lai.

## Hangfire da luu job, tai sao chua du?

Hangfire luu cac thong tin can de thuc thi background job, vi du method can goi,
arguments, retry, exception va trang thai queue. Day la du lieu cua **he thong
job scheduler**, khong phai du lieu nghiep vu cua Central DB Sync.

### 1. API can mot ma theo doi on dinh

API can tra ve `202 Accepted` ngay, kem `runId`, de client hoi trang thai sau do.
Neu chi dung Hangfire job ID:

- client bi gan chat vao chi tiet noi bo cua Hangfire;
- job ID co the thay doi khi reschedule;
- API phai dien giai cac state noi bo cua Hangfire thanh state nghiep vu;
- khong co noi de luu cac truong sync nhu `rows_staged`, tong so dong du kien,
  error code da chuan hoa va thoi gian bootstrap bat dau/ket thuc.

`bootstrap_request` la hop dong ro rang cho API. Hangfire Dashboard van la cong
cu cho van hanh va debug, khong phai API nghiep vu cho client.

### 2. Can chong bam lap va chay trung

Admin co the bam nut hai lan, client co the retry HTTP, hoac hai instance API
co the nhan cung mot request gan nhu dong thoi.

Bang `bootstrap_request` co partial unique index: moi `source_table` chi duoc co
mot phieu dang active trong cac state `pending_enqueue`, `queued`, `running` va
`waiting_for_lock`.

Vi vay hai lan bam bootstrap `CRM.Partners` se nhan lai cung mot `runId`, thay vi
tao hai full bootstrap canh tranh nhau.

Hangfire co co che queue va lock, nhung khong tu cung cap quy tac nghiep vu
"moi bang nguon chi co mot bootstrap active". Hangfire cung khuyen nghi job phai
idempotent va ung dung phai tu bao ve duplicate side effect bang transaction/CAS.

### 3. Bao ve khoang trong khi app bi restart

Day la tinh huong quan trong:

1. API da nhan yeu cau bootstrap.
2. App tao phieu `pending_enqueue` trong PostgreSQL.
3. App crash truoc khi goi `EnqueueAsync`.

Luc nay Hangfire chua co job nao de tim. Neu chi dung Hangfire, yeu cau cua Admin
bi mat hoac user phai bam lai ma khong biet lan dau da di den dau.

Voi `bootstrap_request`, phieu van ton tai. Recurring reconciliation job tim cac
phieu `pending_enqueue` qua han va enqueue lai. Day la ly do phieu duoc luu
**truoc** khi tao job Hangfire.

### 4. Trang thai nghiep vu khac trang thai scheduler

Mot job Hangfire co the la Enqueued, Processing, Succeeded, Failed hoac Scheduled.
Bootstrap can cac state co nghia voi nguoi van hanh:

| State request | Nghia |
|---|---|
| `pending_enqueue` | Da tao phieu, chua chac job da duoc enqueue |
| `queued` | Da co Hangfire job dang cho chay |
| `running` | Worker da claim phieu va dang dong bo |
| `waiting_for_lock` | Bang dang duoc mot sync khac giu lock; se hen lai |
| `completed` | Bootstrap da publish thanh cong |
| `failed` | Bootstrap khong thanh cong; co error code/message de xu ly |

Vi du, `waiting_for_lock` khong phai loi Hangfire. Day la quyet dinh nghiep vu:
khong ghi de len sync dang chay, giu phieu va thu lai sau.

### 5. Du lieu nam o hai storage khac nhau

Trong kien truc hien tai:

- Hangfire storage dung `ReportingConnection` (SQL Server).
- Du lieu dich, checkpoint va metadata sync dung `CentralDbConnection`
  (PostgreSQL).

`bootstrap_request` can nam canh `sync_meta.checkpoint` va `report.partners` trong
Central DB, vi no mo ta tien trinh dong bo cua chinh du lieu nay. Dung truc tiep
bang noi bo cua Hangfire lam source of truth se lam API va Central DB Sync phu
thuoc vao schema/storage implementation cua scheduler.

## Quan he giua request va Hangfire job

```text
Mot bootstrap_request (runId on dinh)
        |
        +-- co the lien ket mot hangfire_job_id hien tai
        |
        +-- co the duoc chay lai / reschedule
                |
                +-- hangfire_job_id moi, nhung van cung runId
```

Do do, `hangfire_job_id` la metadata tham chieu de debug; `request_id` moi la
dinh danh cua lan bootstrap trong API, log va Central DB.

## Cac tinh huong mau

### Admin bam nut hai lan

- **Chi Hangfire:** co the enqueue hai job, hai job cung co gang bootstrap.
- **Co request table:** index tra lai phieu dang active; ca hai response cung
  tro mot `runId`.

### App restart ngay sau khi nhan API

- **Chi Hangfire:** neu crash truoc enqueue, khong con dau vet cua request.
- **Co request table:** con phieu `pending_enqueue`; reconciliation job enqueue lai.

### Lock cua `CRM.Partners` dang ban

- **Chi Hangfire:** job co the Failed/Retry ma khong phan biet duoc day la loi hay
  chi la bang dang ban.
- **Co request table:** ghi `waiting_for_lock`, sau do hen lai; API hien dung ly do.

### Worker doi hoac job bi retry

- **Chi Hangfire:** client phai biet job nao la ban retry cua job cu.
- **Co request table:** client van hoi cung `GET /bootstrap/{runId}`; worker/job ID
  nao xu ly la chi tiet noi bo.

## Khi nao chi dung Hangfire la du?

Chi dung Hangfire la hop ly neu tat ca dieu sau deu dung:

- tac vu la fire-and-forget;
- khong can API status hay progress cho nguoi dung;
- khong can deduplicate theo khoa nghiep vu;
- khong can recovery cho khoang crash truoc enqueue;
- retry cua Hangfire du cho nghiep vu;
- job khong can lien ket voi state trong database dich.

Bootstrap Central DB khong thoa cac dieu kien nay: no co the lon, anh huong
`report.partners` va checkpoint, can lock, can quan sat, va phai tranh chay trung.

## Quy tac thiet ke can giu

1. Tao phieu trong PostgreSQL truoc, sau do moi enqueue Hangfire.
2. `request_id` la ma theo doi on dinh; khong dung Hangfire job ID lam run ID API.
3. Moi thao tac claim/transition phai co dieu kien state trong SQL de tranh hai
   worker cung claim mot phieu.
4. Mot `source_table` chi co mot request active.
5. Job phai idempotent: Hangfire lock chi la lop ho tro, khong thay the transaction,
   compare-and-set va PostgreSQL advisory lock.
6. Khi bootstrap loi, request va run log ghi loi; du lieu report va checkpoint chi
   duoc publish/advance theo transaction thanh cong.

## Ket luan

`sync_meta.bootstrap_request` khong phai ban sao cua Hangfire. No la bang metadata
nghiep vu, giup API tra status dung, chong duplicate, va phuc hoi request sau restart.
Hangfire van can thiet de chay worker nen, retry va quan sat van hanh.

Kien truc dung la: **request table quan ly y nghia va trang thai bootstrap;
Hangfire quan ly viec thuc thi bootstrap do.**

## Tai lieu lien quan

- `Infrastructure/Database/SqlScript/CentralDbSync/001-central-db-sync-schema.sql`
- `Application/Features/CentralDbSync/Services/BootstrapRequestService.cs`
- `Infrastructure/CentralDbSync/PostgresBootstrapRequestStore.cs`
- `Infrastructure/CentralDbSync/CentralDbSyncJobs.cs`
- `docs/central-database-blueprint/notes/2026-07-20-deploy-seed.md`

# com.flyme.auto.keyserver — bản vá KeyServer (map phím vô lăng)

KeyServer (`com.flyme.auto.keyserver`, system app uid 1000 của HU) là app nhận
key event thật từ MCU qua VHAL rồi dispatch tới `HomeKeyHandler` /
`ModeKeyHandler`. Tên hiển thị gốc trên HU: **AutoKeyServer** (label trong
AndroidManifest) — field `name` của catalog dùng đúng tên này. Bản vá
**không đổi hành vi gốc** — chỉ chèn một bước forward:
mỗi event GELLY (Home) / MODE được phát đi ordered broadcast
`vn.coon.intent.action.HARD_KEY_EVENT` (extras `key` = home|mode, `state` =
1|2|3) tới `vn.coon.app` (Coon). Nếu Coon không nhận (không cài, bị
force-stop, hoặc không claim qua `resultCode = 1`) thì handler gốc chạy đúng
hành vi factory. Nguồn smali + hướng dẫn build: repo `coolray-lab`
(`projects/coon/keyserver-patch/`).

## Vì sao phải vá

Phím vô lăng không đi qua Linux input; mỗi phím là một VHAL property do
KeyServer độc quyền lắng nghe. Không vá thì Coon không thể nhận event để map
cử chỉ (single/double/long → mở 360, mở Coon, Android Auto…).

## Nhận diện bản vá

Chữ ký của bản vá **giống hệt factory** (cùng platform testkey — điều kiện để
cài như update của system app), nên không phân biệt được qua signature. Coon
nhận diện bằng sha256 của APK đang active:

| Trạng thái | Ý nghĩa |
| --- | --- |
| `FACTORY` | versionCode = 26020313 và sha256 = `5dd6217d…` (bản gốc) → nút "Cập nhật" |
| `PATCHED_OK` | sha256 khớp release mới nhất trong catalog |
| `PATCHED_OUTDATED` | sha256 khớp release cũ → nút "Cập nhật" |
| `UNKNOWN_UPDATE` | có update lạ Coon không biết — cảnh báo, không tự thay |
| `BASE_MISMATCH` | APK factory trên xe khác base catalog build trên → chặn vá |

## Releases

| releasedAt | versionCode | sha256 | Ghi chú |
| --- | --- | --- | --- |
| 2026-11-03 | 27020314 (factory + 1.000.000 + 1) | `5c69bf058b697a64a48e8b690464e0acb5739c725c361362eb6f837435864712` | Release đầu tiên cài qua Coon Market (PackageInstaller, APK nằm /data/app). Nội dung smali giống bản test trên xe thật 2026-11-01 (đủ 6 cử chỉ GELLY/MODE × single/double/long), chỉ bump versionCode. |

Lịch sử: bản test 2026-11-01 (sha256 `bf73010e…`, versionCode bằng factory) chỉ
đã flash trực tiếp vào /system qua OTA/ADB — không nằm trong catalog.

## Sau khi cài (postInstall)

Install qua PackageInstaller khiến PMS kill process KeyServer ngay; service chỉ
được đánh thức bởi broadcast boot `com.geely.action.BOOT_KET_SERVICE_APP`.
Coon phải tự start lại:

```
am start-foreground-service -n com.flyme.auto.keyserver/.service.AutoKeyService
```

(Cho phép vì Coon cùng sharedUser uid 1000. Nếu thất bại → reboot HU.)

## Rollback

- Cài qua Coon (update nằm `/data/app`, versionCode bump): bản gốc còn nguyên
  trong `/system` — rollback = uninstall update (PMS tự lộ lại bản gốc).
  Coon cũng backup bản gốc vào filesDir + `/sdcard` trước khi vá lần đầu.
- TH đặc biệt versionCode bằng factory (cài đè cùng mã): Coon cài lại
  backup; không có thì tải `factory.apk` từ catalog (cùng versionCode nên
  không cần downgrade).

## Rủi ro

- APK vá sai → KeyServer crash lúc boot: phím vô lăng mất (không bootloop cả
  máy — KeyServer chỉ là app). Rollback như trên.
- Single-press chậm thêm ~400ms so với factory (chờ CLICK của VHAL + cửa sổ
  double-press trong Coon).
- MODE nhấn đơn (đổi nguồn âm thanh) chưa port được sang Coon vì SDK
  `ecarx.xsf.mediacenter` sống trong process KeyServer; khi Coon sống thì
  event bị claim nên slot này mặc định không làm gì. Chi tiết:
  `docs/features/keymap.md` trong Coon.

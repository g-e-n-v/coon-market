# coon-market

Market cho **Coon** — app quản lý xe chạy trên head unit IHU689G (Geely New
Coolray 2026 VN, Android 9). Repo này là **nguồn sự thật duy nhất** cho:

1. **Bản vá system app** (`type: patch`): APK đã sửa của app factory (KeyServer,
   ConnAdaptor…) để mở khóa tính năng mở rộng của Coon. Cài như update của
   system app (PackageInstaller, APK nằm `/data/app`), rollback = gỡ update
   để về bản gốc trong `/system`.
2. **App gợi ý** (`type: app`): APK sideload thông thường.

Catalog duy nhất: `catalog/coon-market.json` (schema v2). Binaries luôn nằm ở
**GitHub Releases** (không trong git/LFS) để link ổn định vĩnh viễn theo tag.

> Repo **public** — Coon tải catalog lẫn APK không cần token. Không đưa gì
> nhạy cảm vào đây; nguồn phát hành chỉ là người giữ quyền push.

## Cấu trúc

```
catalog/coon-market.json        catalog duy nhất (edit trên main, rolling)
schema/catalog.schema.json      JSON Schema v2 (hỗ trợ editor; validate.py là chuẩn)
icons/<package>.<png|webp>      icon hiển thị trong Coon (khuyến nghị 192px)
apps/<package>/README.md        doc từng app: vá gì, rủi ro, rollback
tools/validate.py               CI: cấu trúc + nghiệp vụ + asset thật trên GitHub
tools/promote.sh                phát hành: check cert + gh release + cập nhật catalog
.github/workflows/ci.yml        chạy validate.py khi push/PR
```

## Luồng phát hành (maintainer)

Vá/build vẫn làm trong repo `coolray-lab` (`projects/coon/keyserver-patch/`).
Xong thì promote vào đây:

```bash
tools/promote.sh com.flyme.auto.keyserver ~/…/GeelyAutoKeyServer.apk \
  --version-code 27020315 \
  --min-coon 3 \
  --start-service com.flyme.auto.keyserver/.service.AutoKeyService \
  --note "mô tả thay đổi"
git add -A && git commit -m "market: keyserver patch-3" && git push
```

`promote.sh` tự: **verify chữ ký platform testkey** (chặn phát hành APK ký sai
key — mất sharedUser `android.uid.system` khi install) → tính sha256/size →
tạo/upload asset vào tag `market-<hôm nay>` → sửa catalog → chạy validate.

Đăng ký **factory base mới** (firmware khác): `tools/promote.sh --factory
<package> <apk-gốc> --version-code N --system-app-path /system/…/X.apk` —
cập nhật đủ `versionCode`/`sha256`/`systemApkPath`/artifact rollback.

CI chạy `validate.py`: schema v2, versionCode trùng/lùi, asset tồn tại trên
GitHub + digest khớp, icon URL resolve được.

## Luồng Coon (runtime)

Coon fetch `https://raw.githubusercontent.com/g-e-n-v/coon-market/main/catalog/coon-market.json`,
cache bản good cuối để dùng offline. Trạng thái từng app chạy **hoàn toàn
local** (không cần mạng):

```
h = sha256(APK đang active)
1. pkg chưa cài          → patch: FIRMWARE_UNKNOWN; app: NOT_INSTALLED
2. h khớp release R       → PATCHED_OK / PATCHED_OUTDATED
3. versionCode > factory  → UNKNOWN_UPDATE (cảnh báo)
4. versionCode = factory:
     h = factory.sha256   → FACTORY → nút "Cập nhật"
     h khác               → BASE_MISMATCH (chặn vá)
type=app: so versionCode với release mới nhất → INSTALLED / OUTDATED
```

"Cập nhật" = tải APK → verify sha256 → backup bản `/system` (lần đầu) →
PackageInstaller install → chạy `postInstall` (start-service/reboot) →
re-check. "Gỡ cập nhật" = gỡ update, về bản đang nằm trong `/system`.

## Quy ước quan trọng

- **`name` của app patch = tên gốc của app trên HU** (application label trong
  AndroidManifest, vd `AutoKeyServer`): người dùng thấy Market thay đúng app
  đang chạy trên xe. Lấy qua `aapt2 dump badging <apk> | grep application:`.
- **versionCode bản vá**: `factory + 1.000.000 + n`. Không dùng versionName —
  định danh hiển thị của release là `releasedAt`.
- **sha256 là mốc nhận diện tuyệt đối** — chữ ký bản vá trùng platform
  testkey với factory nên không phân biệt được qua signature.
- Icon: extract từ APK gốc (`aapt2 dump badging` → `application-icon-480`,
  unzip) rồi commit vào `icons/<package>.webp`.
- Mọi field catalog phải phục vụ một quyết định/hiển thị runtime của Coon;
  thông tin cho người bảo trì nằm trong `apps/<package>/README.md`.

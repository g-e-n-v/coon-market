# coon-market

Market cho **Coon** — app quản lý xe chạy trên head unit IHU689G (Geely New
Coolray 2026 VN, Android 9). Repo này là **nguồn sự thật duy nhất** cho:

1. **Bản vá system app** (`type: patch`): APK đã sửa của app factory (KeyServer,
   ConnAdaptor…) để mở khóa tính năng mở rộng của Coon. Cài như update của
   system app (`pm install -r`, APK nằm `/data/app`), rollback được về factory.
2. **App gợi ý** (`type: app`): APK sideload thông thường.

Catalog duy nhất: `catalog/coon-market.json`. Binaries luôn nằm ở **GitHub
Releases** (không trong git/LFS) để link ổn định vĩnh viễn theo tag.

> Repo **private** có chủ đích: chứa APK repack của app bản quyền Geely.
> Coon truy cập bằng fine-grained PAT (Contents: read-only, chỉ scope repo
> này), token nhập tay trong app.

## Cấu trúc

```
catalog/coon-market.json        catalog duy nhất (edit trên main, rolling)
schema/catalog.schema.json      JSON Schema (hỗ trợ editor; validate.py là chuẩn)
apps/<package>/README.md        doc từng app: vá gì, rủi ro, rollback
tools/validate.py               CI: cấu trúc + nghiệp vụ + asset thật trên GitHub
tools/promote.sh                phát hành: gh release create + cập nhật catalog
.github/workflows/ci.yml        chạy validate.py khi push/PR
```

## Luồng phát hành (maintainer)

Vá/build vẫn làm trong repo `coolray-lab` (`projects/coon/keyserver-patch/`).
Xong thì promote vào đây:

```bash
tools/promote.sh com.flyme.auto.keyserver patch-2 ~/…/GeelyAutoKeyServer.apk \
  --version-code 27020314 \
  --min-coon 2 \
  --start-service com.flyme.auto.keyserver/.service.AutoKeyService \
  --note "mô tả thay đổi"
git add -A && git commit -m "market: keyserver patch-2" && git push
```

CI chạy `validate.py`: schema, versionCode trùng/lùi, asset tồn tại trên
GitHub, sizeBytes và sha256 khớp digest asset (nếu API trả).

## Luồng Coon (runtime)

Coon fetch `https://raw.githubusercontent.com/g-e-n-v/coon-market/main/catalog/coon-market.json`
(kèm header token), cache bản good cuối để dùng offline. Trạng thái từng app
chạy **hoàn toàn local** (không cần mạng):

```
h = sha256(APK đang active)
1. pkg chưa cài          → patch: FIRMWARE_UNKNOWN; app: NOT_INSTALLED
2. h khớp release R       → PATCHED_OK / PATCHED_OUTDATED
3. versionCode > factory  → UNKNOWN_UPDATE (cảnh báo)
4. versionCode = factory:
     h = factory.sha256   → FACTORY → nút "Vá"
     h khác               → BASE_MISMATCH (chặn vá)
```

"Vá" = tải APK → verify sha256 → backup bản `/system` ra `/sdcard` (lần đầu)
→ `pm install -r` → chạy `postInstall` (start-service/reboot) → re-check.

## Quy ước quan trọng

- **`name` của app patch = tên gốc của app trên HU** (application label trong
  AndroidManifest, vd `AutoKeyServer`, không phải tên file APK hay tên tự đặt):
  người dùng thấy Market thay đúng app đang chạy trên xe. Lấy tên gốc từ xe qua
  ADB: pull APK theo `factory.systemApkPath` rồi
  `aapt2 dump badging <apk> | grep application-label`. App sideload (`type: app`)
  dùng tên hiển thị chính thức của app đó.
- **versionCode bản vá**: `factory + 1.000.000 + n` từ patch-2 (patch-1 giữ
  nguyên 26020313 — ngoại lệ được ghi chú, digest là mốc nhận diện).
- **sha256 là mốc nhận diện tuyệt đối** — chữ ký bản vá trùng platform
  testkey với factory nên không phân biệt được qua signature.
- Mọi field catalog phải phục vụ một quyết định runtime của Coon; thông tin
  cho người bảo trì nằm trong `apps/<package>/README.md`.

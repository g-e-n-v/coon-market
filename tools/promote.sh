#!/usr/bin/env bash
# Phát hành một APK mới vào coon-market (schema v2): tạo/upload GitHub Release
# asset + cập nhật catalog. Repo PUBLIC — không cần PAT để Coon tải.
#
# Cách dùng (release mới):
#   tools/promote.sh <package> <apk-file> \
#       [--version-code N] [--min-coon N] [--note "..." (lặp được)] \
#       [--start-service com.pkg/.Svc] [--reboot]
#
# Đăng ký / thay artifact factory (kèm base mới):
#   tools/promote.sh --factory <package> <apk-file> \
#       --version-code N [--system-app-path /system/app/.../X.apk]
#
# Quy ước versionCode bản vá: factory + 1.000.000 + n.
# Tag release = market-<ngày>. Nếu tag đã có trong hôm nay, upload asset vào tag đó.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$DIR/catalog/coon-market.json"
command -v gh >/dev/null || { echo "Cần cài gh CLI" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Cần python3" >&2; exit 1; }

# SHA-256 digest của cert platform testkey (aosp testkey, serial b3998086d056cffa)
# — mọi APK vá/Factory app ký bằng key này mới giữ được sharedUserId android.uid.system.
PLATFORM_CERT_SHA256="c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"

find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return 0
  fi
  local root="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  ls "$root"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true
}

check_cert() {
  local apk="$1" signer
  signer="$(find_apksigner)"
  if [ -z "${signer:-}" ]; then
    echo "WARN: không tìm thấy apksigner — bỏ qua kiểm tra chữ ký platform (tự verify tay!)" >&2
    return 0
  fi
  local digest
  digest="$("$signer" verify --print-certs "$apk" 2>/dev/null | awk '/SHA-256 digest/ {print $NF; exit}')"
  if [ "$digest" != "$PLATFORM_CERT_SHA256" ]; then
    echo "LỖI: APK không ký bằng platform testkey (SHA-256 cert: ${digest:-không đọc được})." >&2
    echo "      Key sai = mất sharedUser android.uid.system khi install. Ký lại bằng" >&2
    echo "      usb-upgrade/keys/platform.pk8 + aosp_platform.x509.pem." >&2
    return 1
  fi
  echo "==> Chữ ký OK (platform testkey)"
}

MODE="release"
FACTORY_ARGS=()
if [ "${1:-}" = "--factory" ]; then
  MODE="factory"
  shift
fi

if [ "$MODE" = "factory" ]; then
  [ $# -ge 2 ] || { echo "Cách dùng: $0 --factory <package> <apk-file> --version-code N [--system-app-path /path]" >&2; exit 1; }
  PKG="$1"; APK="$2"; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --version-code) FACTORY_ARGS+=(--version-code "$2"); shift 2 ;;
      --system-app-path) FACTORY_ARGS+=(--system-app-path "$2"); shift 2 ;;
      *) echo "Flag lạ: $1" >&2; exit 1 ;;
    esac
  done
else
  [ $# -ge 2 ] || { echo "Cách dùng: $0 <package> <apk-file> [flags]" >&2; exit 1; }
  PKG="$1"; APK="$2"; shift 2
fi

VERSION_CODE=""; MIN_COON=""; NOTES=(); POST_INSTALL="[]"
while [ $# -gt 0 ]; do
  case "$1" in
    --version-code) VERSION_CODE="$2"; shift 2 ;;
    --min-coon) MIN_COON="$2"; shift 2 ;;
    --note) NOTES+=("$2"); shift 2 ;;
    --start-service) POST_INSTALL="[{\"action\":\"start-service\",\"target\":\"$2\"}]"; shift 2 ;;
    --reboot) POST_INSTALL='[{"action":"reboot"}]'; shift ;;
    *) echo "Flag lạ: $1" >&2; exit 1 ;;
  esac
done

[ -s "$APK" ] || { echo "Không thấy $APK" >&2; exit 1; }
python3 - "$CATALOG" "$PKG" <<'PYEOF' || { echo "LỖI: package $PKG chưa có trong catalog — thêm app entry trước khi promote." >&2; exit 1; }
import json, sys
catalog_path, pkg = sys.argv[1:3]
with open(catalog_path, encoding="utf-8") as fh:
    catalog = json.load(fh)
sys.exit(0 if any(a.get("package") == pkg for a in catalog["apps"]) else 1)
PYEOF

check_cert "$APK"

REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
TAG="market-$(date +%Y.%m.%d)"
SHA="$(shasum -a 256 "$APK" | awk '{print $1}')"
SIZE="$(stat -f%z "$APK")"
ASSET_NAME="$(basename "$APK")"
URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$ASSET_NAME"

echo "==> $PKG | tag $TAG | asset $ASSET_NAME"
echo "    sha256=$SHA size=$SIZE"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Tag $TAG đã tồn tại, upload asset vào"
  gh release upload "$TAG" "$APK" --clobber
else
  gh release create "$TAG" "$APK" --title "$TAG" --notes "Market $TAG: $PKG ${VERSION_CODE:-factory}"
fi

echo "==> Cập nhật catalog $CATALOG"
if [ "$MODE" = "factory" ]; then
  python3 - "$CATALOG" "$PKG" "$URL" "$SHA" "$SIZE" "${FACTORY_ARGS[@]-}" <<'PYEOF'
import datetime, json, sys
args = sys.argv[1:]
catalog_path, pkg, url, sha, size = args[:5]
size = int(size)
flags = {}
i = 5
while i + 1 <= len(args) - 1:
    flags[args[i]] = args[i + 1]
    i += 2
if "--version-code" not in flags:
    raise SystemExit("Cần --version-code N khi đăng ký factory (bản base mới)")
with open(catalog_path, encoding="utf-8") as fh:
    catalog = json.load(fh)
app = next(a for a in catalog["apps"] if a["package"] == pkg)
factory = app.setdefault("factory", {})
factory["versionCode"] = int(flags["--version-code"])
factory["sha256"] = sha
if "--system-app-path" in flags:
    factory["systemApkPath"] = flags["--system-app-path"]
factory["apk"] = {"url": url, "sha256": sha, "sizeBytes": size}
catalog["catalogVersion"] = datetime.date.today().strftime("%Y.%m.%d")
with open(catalog_path, "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(f"Đã cập nhật factory (versionCode {factory['versionCode']}) trong {pkg}")
PYEOF
else
  [ -n "$VERSION_CODE" ] || { echo "Cần --version-code N cho release" >&2; exit 1; }
  python3 - "$CATALOG" "$PKG" "$VERSION_CODE" "$URL" "$SHA" "$SIZE" \
      "${MIN_COON:-1}" "$POST_INSTALL" "${NOTES[@]-}" <<'PYEOF'
import datetime, json, sys
(catalog_path, pkg, version_code, url, sha, size,
 min_coon, post_install, *notes) = sys.argv[1:]
release = {
    "versionCode": int(version_code),
    "releasedAt": datetime.date.today().isoformat(),
    "minCoonVersionCode": int(min_coon),
    "apk": {"url": url, "sha256": sha, "sizeBytes": int(size)},
}
if post_install != "[]":
    release["postInstall"] = json.loads(post_install)
if notes:
    release["notes"] = list(notes)
with open(catalog_path, encoding="utf-8") as fh:
    catalog = json.load(fh)
app = next(a for a in catalog["apps"] if a["package"] == pkg)
app["releases"] = [r for r in app["releases"] if r["versionCode"] != release["versionCode"]]
app["releases"].append(release)
app["releases"].sort(key=lambda r: r["versionCode"])
catalog["catalogVersion"] = datetime.date.today().strftime("%Y.%m.%d")
with open(catalog_path, "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(f"Đã thêm release versionCode {version_code} vào {pkg}")
PYEOF
fi

echo "==> Validate"
( cd "$DIR" && COON_MARKET_TOKEN="$(gh auth token)" python3 tools/validate.py )

cat <<EOF

Tiếp theo (tay):
  cd $DIR && git add -A && git commit -m "market: thêm $ASSET_NAME" && git push
EOF

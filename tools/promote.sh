#!/usr/bin/env bash
# Phát hành một APK mới vào coon-market: tạo GitHub Release + cập nhật catalog.
#
# Cách dùng:
#   tools/promote.sh <package> <versionName> <apk-file> \
#       [--version-code N] [--min-coon N] [--note "..." (lặp được)] \
#       [--start-service com.pkg/.Svc] [--reboot]
#   tools/promote.sh --factory <package> <apk-file>   # thay artifact factory
#
# Quy ước versionCode bản vá: factory + 1.000.000 + n (truyền --version-code).
# Tag release = market-<ngày>. Nếu tag đã có trong hôm nay, upload asset vào tag đó.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$DIR/catalog/coon-market.json"
command -v gh >/dev/null || { echo "Cần cài gh CLI" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Cần python3" >&2; exit 1; }

MODE="release"
if [ "${1:-}" = "--factory" ]; then
  MODE="factory"
  shift
fi

if [ "$MODE" = "factory" ]; then
  [ $# -eq 2 ] || { echo "Cách dùng: $0 --factory <package> <apk-file>" >&2; exit 1; }
  PKG="$1"; APK="$2"
else
  [ $# -ge 3 ] || { echo "Cách dùng: $0 <package> <versionName> <apk-file> [flags]" >&2; exit 1; }
  PKG="$1"; VERSION_NAME="$2"; APK="$3"; shift 3
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
  NOTES_TITLE="${PKG} ${VERSION_NAME:-factory}"
  gh release create "$TAG" "$APK" --title "$TAG" --notes "Market $TAG: $NOTES_TITLE"
fi

echo "==> Cập nhật catalog $CATALOG"
if [ "$MODE" = "factory" ]; then
  python3 - "$CATALOG" "$PKG" "$URL" "$SHA" "$SIZE" <<'PYEOF'
import datetime, json, sys
catalog_path, pkg, url, sha, size = sys.argv[1:6]
size = int(size)
with open(catalog_path, encoding="utf-8") as fh:
    catalog = json.load(fh)
app = next(a for a in catalog["apps"] if a["package"] == pkg)
factory = app.setdefault("factory", {})
factory["apk"] = {"url": url, "sha256": sha, "sizeBytes": size}
catalog["catalogVersion"] = datetime.date.today().strftime("%Y.%m.%d")
with open(catalog_path, "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("Đã cập nhật factory.apk trong catalog")
PYEOF
else
  [ -n "$VERSION_CODE" ] || { echo "Cần --version-code N cho release" >&2; exit 1; }
  python3 - "$CATALOG" "$PKG" "$VERSION_NAME" "$VERSION_CODE" "$URL" "$SHA" "$SIZE" \
      "${MIN_COON:-1}" "$POST_INSTALL" "${NOTES[@]-}" <<'PYEOF'
import datetime, json, sys
(catalog_path, pkg, version_name, version_code, url, sha, size,
 min_coon, post_install, *notes) = sys.argv[1:]
release = {
    "versionCode": int(version_code),
    "versionName": version_name,
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
print(f"Đã thêm release {version_name} vào {pkg}")
PYEOF
fi

echo "==> Validate"
( cd "$DIR" && COON_MARKET_TOKEN="$(gh auth token)" python3 tools/validate.py )

cat <<EOF

Tiếp theo (tay):
  cd $DIR && git add -A && git commit -m "market: thêm $ASSET_NAME" && git push
EOF

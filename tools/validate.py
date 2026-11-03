#!/usr/bin/env python3
"""Validate catalog/coon-market.json cho repo coon-market (schema v2).

Chỉ dùng stdlib. Kiểm tra:
  1. Cấu trúc: field bắt buộc, pattern (sha256, package, url, date, component,
     icon), string optional (description, featureHint, rollbackNote).
  2. Nghiệp vụ: package duy nhất, versionCode release duy nhất trong app,
     release không được nhỏ hơn factory.versionCode, postInstall hợp lệ,
     factory bắt buộc với type=patch.
  3. Tích hợp GitHub: mọi url apk phải là asset thật của release (query API,
     so khớp tên + sizeBytes + digest sha256 nếu API trả về); icon URL phải
     resolve 200. Repo public — token không bắt buộc (dùng được để tránh rate
     limit).

Exit code 0 = PASS (cho phép WARN), khác 0 = có ERROR.
"""

import json
import os
import re
import sys
import urllib.request
import urllib.error

CATALOG_PATH = os.path.join(os.path.dirname(__file__), "..", "catalog", "coon-market.json")
SUPPORTED_SCHEMA_VERSION = 2

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CATALOG_VERSION_RE = re.compile(r"^\d{4}\.\d{2}\.\d{2}$")
RELEASE_URL_RE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$")
ICON_URL_RE = re.compile(r"^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/icons/([^/]+)$")
COMPONENT_RE = re.compile(
    r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*"
    r"(/\.?[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*)?$"
)
POST_INSTALL_ACTIONS = {"start-service", "reboot"}

errors = []
warnings = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def require_str(obj, key, path, pattern=None, label=None):
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        err(f"{path}: thiếu {label or key}")
        return None
    if pattern and not pattern.match(value):
        err(f"{path}.{key}: giá trị {value!r} không khớp pattern")
        return None
    return value


def optional_str(obj, key, path):
    if key not in obj:
        return
    if not isinstance(obj.get(key), str) or not obj.get(key):
        err(f"{path}.{key}: nếu có phải là string không rỗng")


def require_int(obj, key, path, minimum=None):
    value = obj.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        err(f"{path}: thiếu/{key} không phải số nguyên")
        return None
    if minimum is not None and value < minimum:
        err(f"{path}.{key}: {value} < mức tối thiểu {minimum}")
        return None
    return value


def check_apk_artifact(obj, path):
    """Trả về (url, sha256, sizeBytes) nếu hợp lệ, ngược lại None."""
    if not isinstance(obj, dict):
        err(f"{path}: phải là object")
        return None
    url = require_str(obj, "url", path, pattern=RELEASE_URL_RE)
    sha = require_str(obj, "sha256", path, pattern=SHA256_RE)
    size = require_int(obj, "sizeBytes", path, minimum=1)
    if url and sha and size:
        return (url, sha, size)
    return None


def check_post_install(actions, path):
    if not isinstance(actions, list):
        err(f"{path}: phải là mảng")
        return
    for i, action in enumerate(actions):
        p = f"{path}[{i}]"
        if not isinstance(action, dict):
            err(f"{p}: phải là object")
            continue
        kind = action.get("action")
        if kind not in POST_INSTALL_ACTIONS:
            err(f"{p}.action: {kind!r} không thuộc {sorted(POST_INSTALL_ACTIONS)}")
            continue
        if kind == "start-service":
            target = require_str(action, "target", p, pattern=COMPONENT_RE)
            if target:
                warn(f"{p}: start-service {target} — cần verify trên xe rằng service sống lại sau install")


def check_release(release, path, seen_version_codes, factory_version_code):
    if not isinstance(release, dict):
        err(f"{path}: phải là object")
        return
    vc = require_int(release, "versionCode", path, minimum=1)
    require_str(release, "releasedAt", path, pattern=DATE_RE)
    min_coon = release.get("minCoonVersionCode", 1)
    if not isinstance(min_coon, int) or isinstance(min_coon, bool) or min_coon < 1:
        err(f"{path}.minCoonVersionCode: phải là số nguyên >= 1")
    if vc is not None:
        if vc in seen_version_codes:
            err(f"{path}.versionCode {vc} trùng với release khác trong cùng app")
        seen_version_codes.add(vc)
        if factory_version_code is not None and vc < factory_version_code:
            err(
                f"{path}.versionCode {vc} < factory.versionCode {factory_version_code} "
                "(install sẽ cần downgrade)"
            )
        if factory_version_code is not None and vc == factory_version_code:
            warn(
                f"{path}.versionCode {vc} bằng factory.versionCode — digest là mốc nhận diện; "
                "nên bump theo quy ước factory + 1.000.000 + n"
            )
    if "versionName" in release:
        err(f"{path}.versionName: đã bỏ ở schema v2 — định danh hiển thị là releasedAt")
    artifact = check_apk_artifact(release.get("apk"), f"{path}.apk")
    if "notes" in release and not isinstance(release.get("notes"), list):
        err(f"{path}.notes: phải là mảng string")
    check_post_install(release.get("postInstall", []), f"{path}.postInstall")
    return artifact


def check_factory(factory, path):
    if not isinstance(factory, dict):
        err(f"{path}: phải là object")
        return None
    require_int(factory, "versionCode", path, minimum=1)
    require_str(factory, "sha256", path, pattern=SHA256_RE)
    if "systemApkPath" in factory:
        value = factory.get("systemApkPath")
        if not isinstance(value, str) or not value.startswith("/"):
            err(f"{path}.systemApkPath: phải là đường dẫn tuyệt đối")
    artifact = None
    if "apk" in factory:
        artifact = check_apk_artifact(factory.get("apk"), f"{path}.apk")
    return artifact


def github_api(path, token):
    url = f"https://api.github.com{path}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "coon-market-validate",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def check_url_ok(url, context):
    """HEAD/GET kiểm tra URL public resolve được (icon raw URL)."""
    request = urllib.request.Request(url, method="HEAD", headers={
        "User-Agent": "coon-market-validate",
    })
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status != 200:
                err(f"{context}: HTTP {response.status} khi tải {url}")
    except urllib.error.HTTPError as exc:
        err(f"{context}: HTTP {exc.code} khi tải {url} — file không tồn tại trên repo?")
    except (urllib.error.URLError, TimeoutError) as exc:
        warn(f"{context}: lỗi mạng {exc} — bỏ qua")


def check_urls_online(artifacts, icon_urls):
    """artifacts: list (url, sha256, sizeBytes, context). Group theo tag để gọi API 1 lần."""
    token = os.environ.get("COON_MARKET_TOKEN") or os.environ.get("GITHUB_TOKEN")
    by_tag = {}
    for url, sha, size, context in artifacts:
        match = RELEASE_URL_RE.match(url)
        owner, repo, tag, asset_name = match.groups()
        by_tag.setdefault((owner, repo, tag), []).append((asset_name, sha, size, context))
    for (owner, repo, tag), items in sorted(by_tag.items()):
        api_path = f"/repos/{owner}/{repo}/releases/tags/{tag}"
        try:
            release = github_api(api_path, token)
        except urllib.error.HTTPError as exc:
            err(f"github {api_path}: HTTP {exc.code} — release/tag không tồn tại?")
            continue
        except (urllib.error.URLError, TimeoutError) as exc:
            warn(f"github {api_path}: lỗi mạng {exc} — bỏ qua")
            continue
        assets = {asset["name"]: asset for asset in release.get("assets", [])}
        for asset_name, sha, size, context in items:
            asset = assets.get(asset_name)
            if asset is None:
                err(f"{context}: asset {asset_name!r} không có trong release {tag}")
                continue
            if asset.get("size") != size:
                err(f"{context}: sizeBytes {size} ≠ size thật trên GitHub {asset.get('size')}")
            digest = asset.get("digest") or ""
            if digest.startswith("sha256:"):
                actual = digest[len("sha256:"):]
                if actual != sha:
                    err(f"{context}: sha256 catalog {sha} ≠ digest asset {actual}")
            else:
                warn(f"{context}: GitHub API không trả digest cho asset {asset_name!r} — chỉ check tên + size")
    for url, context in icon_urls:
        check_url_ok(url, context)


def main():
    try:
        with open(CATALOG_PATH, encoding="utf-8") as handle:
            catalog = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"LỖI: không đọc được catalog: {exc}")
        return 1

    artifacts = []
    icon_urls = []

    if catalog.get("schemaVersion") != SUPPORTED_SCHEMA_VERSION:
        err(f"schemaVersion phải = {SUPPORTED_SCHEMA_VERSION}, đang là {catalog.get('schemaVersion')!r}")
    require_str(catalog, "catalogVersion", "catalog", pattern=CATALOG_VERSION_RE)

    apps = catalog.get("apps")
    if not isinstance(apps, list) or not apps:
        err("catalog.apps: phải là mảng không rỗng")
        apps = []

    seen_packages = set()
    for index, app in enumerate(apps):
        path = f"apps[{index}]"
        if not isinstance(app, dict):
            err(f"{path}: phải là object")
            continue
        pkg = require_str(app, "package", path, pattern=PKG_RE)
        if pkg:
            if pkg in seen_packages:
                err(f"{path}.package {pkg} trùng lặp")
            seen_packages.add(pkg)
            path = f"apps[{pkg}]"
        kind = app.get("type")
        if kind not in {"patch", "app"}:
            err(f"{path}.type: {kind!r} phải là 'patch' hoặc 'app'")
            kind = None
        require_str(app, "name", path)
        require_str(app, "summary", path)
        for key in ("description", "featureHint", "rollbackNote"):
            optional_str(app, key, path)
        if "descriptionUrl" in app:
            err(f"{path}.descriptionUrl: đã bỏ ở schema v2 — dùng description (HU không có browser)")
        icon = require_str(app, "icon", path, pattern=ICON_URL_RE) if "icon" in app else None
        if icon:
            icon_urls.append((icon, f"{path}.icon"))

        factory_version_code = None
        if kind == "patch":
            if "factory" not in app:
                err(f"{path}: type=patch bắt buộc có factory")
            else:
                factory_version_code = app["factory"].get("versionCode")
                artifact = check_factory(app["factory"], f"{path}.factory")
                if artifact:
                    artifacts.append((*artifact, f"{path}.factory.apk"))
        elif kind == "app" and "factory" in app:
            err(f"{path}: type=app không được có factory")

        releases = app.get("releases")
        if not isinstance(releases, list) or not releases:
            err(f"{path}.releases: phải là mảng không rỗng")
            releases = []
        seen_version_codes = set()
        for r_index, release in enumerate(releases):
            artifact = check_release(release, f"{path}.releases[{r_index}]", seen_version_codes, factory_version_code)
            if artifact:
                artifacts.append((*artifact, f"{path}.releases[{r_index}].apk"))

    check_urls_online(artifacts, icon_urls)

    print(f"Catalog: {len(seen_packages)} app, {len(artifacts)} artifact APK, {len(icon_urls)} icon")
    for message in warnings:
        print(f"WARN: {message}")
    for message in errors:
        print(f"LỖI: {message}")
    if errors:
        print(f"KẾT QUẢ: FAIL ({len(errors)} lỗi, {len(warnings)} cảnh báo)")
        return 1
    print(f"KẾT QUẢ: PASS ({len(warnings)} cảnh báo)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

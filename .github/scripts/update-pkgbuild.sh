#!/usr/bin/env bash
# 检测上游 APT 仓库（https://download.gotempest.app/apt）中的新版本，
# 下载对应架构的 .deb 以计算 SHA-512，并据此更新 PKGBUILD。
#
# 仅当上游版本比 PKGBUILD 中的 pkgver 新时才改动文件，因此可以安全地重复运行。
#
# 用法:
#   bash .github/scripts/update-pkgbuild.sh          # 检查并更新 PKGBUILD
#   bash .github/scripts/update-pkgbuild.sh --check  # 只检查是否上游有更新，不下载/不写文件
#
# 在 GitHub Actions 中会向 $GITHUB_OUTPUT 写入:
#   updated=true|false  是否更新了 PKGBUILD
#   pkgver=<版本>       更新后（或当前）的版本
set -euo pipefail

PACKAGES_URL="https://download.gotempest.app/apt/dists/stable/main/binary-amd64/Packages.gz"
DOWNLOAD_BASE="https://download.gotempest.app"
UPSTREAM_PKG="tempest-desktop"

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=true
fi

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

emit() {
    local updated="$1" pkgver="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            printf 'updated=%s\n' "$updated"
            printf 'pkgver=%s\n' "$pkgver"
        } >>"$GITHUB_OUTPUT"
    fi
}

[[ -f PKGBUILD ]] || die "PKGBUILD not found; run this script from the repository root"

current_pkgver="$(sed -n 's/^pkgver=//p' PKGBUILD | head -n1)"
[[ -n "$current_pkgver" ]] || die "cannot read pkgver from PKGBUILD"
log "current pkgver: ${current_pkgver}"

# 与 .nvchecker.toml 使用同一个上游数据源: Debian Packages 索引
upstream_pkgver="$(
    curl -fsSL --retry 5 --retry-delay 3 "$PACKAGES_URL" |
        gzip -dc |
        awk -v pkg="$UPSTREAM_PKG" '
            $0 == "Package: " pkg { found = 1; next }
            found && /^Version: / { sub(/^Version: /, ""); print; exit }
        '
)"
# Debian 版本可能带 "-<修订号>" 后缀，PKGBUILD 中不使用
upstream_pkgver="${upstream_pkgver%-*}"
[[ -n "$upstream_pkgver" ]] || die "failed to determine upstream version"
log "upstream pkgver: ${upstream_pkgver}"

if [[ "$upstream_pkgver" == "$current_pkgver" ]]; then
    log "already up to date"
    emit "false" "$current_pkgver"
    exit 0
fi

# 只接受更新的版本，避免上游误发布旧版本时把包降级
newest="$(printf '%s\n%s\n' "$current_pkgver" "$upstream_pkgver" | sort -V | tail -n1)"
if [[ "$newest" != "$upstream_pkgver" ]]; then
    log "upstream ${upstream_pkgver} is older than current ${current_pkgver}; skipping"
    emit "false" "$current_pkgver"
    exit 0
fi

if [[ "$CHECK_ONLY" == true ]]; then
    log "update available: ${current_pkgver} -> ${upstream_pkgver} (check-only, nothing changed)"
    emit "false" "$current_pkgver"
    exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 下载 .deb 并输出 SHA-512（十六进制）。日志走 stderr，stdout 只输出摘要。
download_and_hash() {
    local arch="$1" debarch="$2" url out sum
    url="${DOWNLOAD_BASE}/${UPSTREAM_PKG}_${upstream_pkgver}_${debarch}.deb"
    out="${tmpdir}/${arch}.deb"
    log "downloading ${url}"
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        -o "$out" "$url" ||
        die "failed to download ${url}"
    sum="$(sha512sum "$out" | awk '{print $1}')"
    rm -f "$out"
    printf '%s' "$sum"
}

sha512_x86_64="$(download_and_hash x86_64 amd64)"
sha512_aarch64="$(download_and_hash aarch64 arm64)"

# 改写 PKGBUILD: 版本号、pkgrel、两个架构的 SHA-512，
# 以及记录上游公布的 Base64 SHA-512 的注释（保持人工核对方便）。
python3 - "$upstream_pkgver" "$sha512_x86_64" "$sha512_aarch64" <<'PY'
import base64
import pathlib
import re
import sys

pkgver, sha512_x86_64, sha512_aarch64 = sys.argv[1:4]
path = pathlib.Path("PKGBUILD")
text = path.read_text(encoding="utf-8")


def b64(hexdigest: str) -> str:
    return base64.b64encode(bytes.fromhex(hexdigest)).decode()


def replace_once(pattern: str, replacement: str, label: str) -> str:
    new_text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        sys.exit(f"ERROR: expected exactly one {label} in PKGBUILD, found {count}")
    return new_text


text = replace_once(r"^pkgver=.*$", f"pkgver={pkgver}", "pkgver")
text = replace_once(r"^pkgrel=.*$", "pkgrel=1", "pkgrel")

for arch, digest in (("x86_64", sha512_x86_64), ("aarch64", sha512_aarch64)):
    # 优先连同上一行的“上游公布值”注释一起更新
    new_text, count = re.subn(
        rf"^#   [A-Za-z0-9+/]{{86}}==\n(sha512sums_{arch}=\(')[0-9a-f]{{128}}('\))$",
        rf"#   {b64(digest)}\n\g<1>{digest}\g<2>",
        text,
        flags=re.MULTILINE,
    )
    if count == 1:
        text = new_text
    else:
        # 注释被删掉时只更新校验和
        text = replace_once(
            rf"^(sha512sums_{arch}=\(')[0-9a-f]{{128}}('\))$",
            rf"\g<1>{digest}\g<2>",
            f"sha512sums_{arch}",
        )

path.write_text(text, encoding="utf-8")
PY

log "updated PKGBUILD to ${upstream_pkgver}"
log "remember to regenerate .SRCINFO before committing: makepkg --printsrcinfo > .SRCINFO"
emit "true" "$upstream_pkgver"

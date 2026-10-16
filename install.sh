#!/system/bin/sh
set -eu

# OpenCode v2 Android/Termux installer.
# Installs the official ARM64 musl binary without npm, proot, root, or a container.

VERSION="${OPENCODE_VERSION:-2.0.31}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${OPENCODE_INSTALL_DIR:-$PREFIX/lib/opencode}"
BIN="$PREFIX/bin/opencode"
TMP="${TMPDIR:-$PREFIX/tmp}/opencode-install.$$"
ALPINE_VERSION="${OPENCODE_ALPINE_VERSION:-3.24.2}"
ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION"
NPM_TARBALL="https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/-/cli-linux-arm64-musl-$VERSION.tgz"
ALPINE_ROOTFS="$ALPINE_BASE/releases/aarch64/alpine-minirootfs-$ALPINE_VERSION-aarch64.tar.gz"
ALPINE_MAIN="$ALPINE_BASE/main/aarch64"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

die() {
  printf '%s\\n' "opencode-termux: $*" >&2
  exit 1
}

log() {
  printf '%s\\n' "opencode-termux: $*"
}

[ "$(uname -m 2>/dev/null || true)" = "aarch64" ] ||
  die "this installer requires an Android ARM64 (aarch64) device"
[ -n "${TERMUX_VERSION:-}" ] ||
  die "this installer is for Termux"
command -v pkg >/dev/null 2>&1 ||
  die "Termux package manager not found"

mkdir -p "$TMP"
pkg install -y curl tar gzip >/dev/null

rm -rf "$ROOT"
mkdir -p "$ROOT/bin" "$ROOT/lib"

log "Downloading OpenCode v$VERSION ARM64 musl binary..."
curl -fL --retry 3 --retry-delay 1 "$NPM_TARBALL" -o "$TMP/opencode.tgz"
tar -xzf "$TMP/opencode.tgz" -C "$TMP"

BINARY="$(find "$TMP/package" -type f \( -name opencode -o -name opencode2 \) -perm -u+x -print -quit 2>/dev/null || true)"
[ -n "$BINARY" ] || die "OpenCode binary was not found in the platform package"

cp "$BINARY" "$ROOT/bin/opencode"
chmod 755 "$ROOT/bin/opencode"

log "Installing the musl runtime..."
curl -fL --retry 3 --retry-delay 1 "$ALPINE_ROOTFS" -o "$TMP/alpine.tar.gz"
mkdir -p "$TMP/alpine"
tar -xzf "$TMP/alpine.tar.gz" -C "$TMP/alpine"

LOADER="$TMP/alpine/lib/ld-musl-aarch64.so.1"
[ -x "$LOADER" ] || die "Alpine musl loader was not found"

cp "$LOADER" "$ROOT/lib/ld-musl-aarch64.so.1"
chmod 755 "$ROOT/lib/ld-musl-aarch64.so.1"

# libstdc++ and libgcc_s are taken from the same Alpine release as the musl loader.
LIBSTDCXX_APK="$(curl -fsSL "$ALPINE_MAIN/" | sed -n 's/.*href="\\(libstdc++-[^"]*\\.apk\\)".*/\\1/p' | sort -V | tail -n 1)"
LIBGCC_APK="$(curl -fsSL "$ALPINE_MAIN/" | sed -n 's/.*href="\\(libgcc-[^"]*\\.apk\\)".*/\\1/p' | sort -V | tail -n 1)"
[ -n "$LIBSTDCXX_APK" ] || die "could not resolve Alpine libstdc++ package"
[ -n "$LIBGCC_APK" ] || die "could not resolve Alpine libgcc package"

for apk_name in "$LIBSTDCXX_APK" "$LIBGCC_APK"; do
  curl -fL --retry 3 --retry-delay 1 "$ALPINE_MAIN/$apk_name" -o "$TMP/$apk_name"
  mkdir -p "$TMP/apk"
  tar -xzf "$TMP/$apk_name" -C "$TMP/apk"
done

find "$TMP/apk/usr/lib" -maxdepth 1 -type f -name 'libstdc++.so*' -exec cp -a {} "$ROOT/lib/" \;
find "$TMP/apk/usr/lib" -maxdepth 1 -type f -name 'libgcc_s.so*' -exec cp -a {} "$ROOT/lib/" \;

[ -f "$ROOT/lib/libstdc++.so.6" ] || die "libstdc++.so.6 was not installed"
[ -f "$ROOT/lib/libgcc_s.so.1" ] || die "libgcc_s.so.1 was not installed"

cat > "$BIN" <<EOF
#!/system/bin/sh
set -eu

ROOT="$ROOT"
LOADER="\$ROOT/lib/ld-musl-aarch64.so.1"
PROGRAM="\$ROOT/bin/opencode"

export LD_LIBRARY_PATH="\$ROOT/lib${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
export TERM="${TERM:-xterm-256color}"

# Android/Termux does not need OpenCode's desktop-specific audio integration.
export OPENCODE_DISABLE_TUI_AUDIO="${OPENCODE_DISABLE_TUI_AUDIO:-1}"

# v2 can use a private foreground server, avoiding Android-hostile background
# re-exec behavior when the binary is launched through the musl loader.
case "${1:-}" in
  service|serve|--server|--standalone) set -- "$@" ;;
  *) set -- --standalone "$@" ;;
esac

exec "$LOADER" --library-path "$ROOT/lib" "$PROGRAM" "$@"
EOF
chmod 755 "$BIN"

"$BIN" --version >/dev/null || die "installed OpenCode failed its ARM64 smoke test"
"$BIN" run --help >/dev/null || die "installed OpenCode failed its run-command smoke test"

log "Installed OpenCode v$VERSION"
log "Run: opencode"

#!/system/bin/sh
set -eu

# OpenCode v2 native Termux / Android ARM64 installer.
# No npm, proot, chroot, Docker, or root required.

VERSION="${OPENCODE_VERSION:-2.0.31}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${OPENCODE_INSTALL_DIR:-$PREFIX/lib/opencode}"
BIN="$PREFIX/bin/opencode"
TMP="${TMPDIR:-$PREFIX/tmp}/opencode-install.$$"

# Alpine 3.24.2 is hosted in the v3.24 repository.
ALPINE_VERSION="${OPENCODE_ALPINE_VERSION:-3.24.2}"
ALPINE_BRANCH="${OPENCODE_ALPINE_BRANCH:-3.24}"
ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_BRANCH"
ALPINE_MAIN="$ALPINE_BASE/main/aarch64"
OPENCODE_TARBALL="https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/-/cli-linux-arm64-musl-$VERSION.tgz"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

die() { printf '%s\n' "opencode-termux: $*" >&2; exit 1; }
log() { printf '%s\n' "opencode-termux: $*"; }

[ "$(uname -m 2>/dev/null || true)" = "aarch64" ] ||
  die "this installer requires Android ARM64 (aarch64)"
[ -n "${TERMUX_VERSION:-}" ] || die "this installer is for Termux"
command -v pkg >/dev/null 2>&1 || die "Termux package manager not found"

mkdir -p "$TMP" "$ROOT/bin" "$ROOT/lib"
pkg install -y curl tar gzip coreutils >/dev/null

rm -f "$ROOT/bin/opencode"
log "Downloading OpenCode v$VERSION ARM64 musl binary..."
curl -fL --retry 3 --retry-delay 1 "$OPENCODE_TARBALL" -o "$TMP/opencode.tgz"
tar -xzf "$TMP/opencode.tgz" -C "$TMP"

BINARY="$(find "$TMP/package" -type f \( -name opencode -o -name opencode2 \) -print -quit 2>/dev/null || true)"
[ -n "$BINARY" ] || die "OpenCode binary was not found in the platform package"
cp "$BINARY" "$ROOT/bin/opencode"
chmod 755 "$ROOT/bin/opencode"

log "Installing musl runtime from Alpine $ALPINE_VERSION..."
INDEX="$(curl -fsSL "$ALPINE_MAIN/")" || die "could not read Alpine package index"

MUSL_APK="$(printf '%s\n' "$INDEX" | sed -n 's/.*href="\(musl-[^"]*\.apk\)".*/\1/p' | grep -v -- '-dbg-' | grep -v -- '-dev-' | sort -V | tail -n 1)"
LIBSTDCXX_APK="$(printf '%s\n' "$INDEX" | sed -n 's/.*href="\(libstdc++-[^"]*\.apk\)".*/\1/p' | sort -V | tail -n 1)"
LIBGCC_APK="$(printf '%s\n' "$INDEX" | sed -n 's/.*href="\(libgcc-[^"]*\.apk\)".*/\1/p' | sort -V | tail -n 1)"

[ -n "$MUSL_APK" ] || die "could not resolve Alpine musl package"
[ -n "$LIBSTDCXX_APK" ] || die "could not resolve Alpine libstdc++ package"
[ -n "$LIBGCC_APK" ] || die "could not resolve Alpine libgcc package"

mkdir -p "$TMP/apk"

for apk_name in "$MUSL_APK" "$LIBSTDCXX_APK" "$LIBGCC_APK"; do
  log "Downloading $apk_name..."
  curl -fL --retry 3 --retry-delay 1 "$ALPINE_MAIN/$apk_name" -o "$TMP/$apk_name"
  tar -xzf "$TMP/$apk_name" -C "$TMP/apk"
done

LOADER="$TMP/apk/lib/ld-musl-aarch64.so.1"
[ -f "$LOADER" ] || die "Alpine musl loader was not found"
cp "$LOADER" "$ROOT/lib/ld-musl-aarch64.so.1"
chmod 755 "$ROOT/lib/ld-musl-aarch64.so.1"

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

export LD_LIBRARY_PATH="\$ROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export SSL_CERT_FILE="\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
export TERM="\${TERM:-xterm-256color}"
export OPENCODE_DISABLE_TUI_AUDIO="\${OPENCODE_DISABLE_TUI_AUDIO:-1}"

case "\${1:-}" in
  service|serve|--server|--standalone)
    exec "\$LOADER" --library-path "\$ROOT/lib" "\$PROGRAM" "\$@"
    ;;
  *)
    exec "\$LOADER" --library-path "\$ROOT/lib" "\$PROGRAM" --standalone "\$@"
    ;;
esac
EOF
chmod 755 "$BIN"

"$BIN" --version >/dev/null || die "installed OpenCode failed its ARM64 smoke test"
"$BIN" run --help >/dev/null || die "installed OpenCode failed its run-command smoke test"

log "Installed OpenCode v$VERSION successfully"
log "Run: opencode"

#!/system/bin/sh
set -eu

VERSION="${OPENCODE_VERSION:-2.0.31}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${OPENCODE_INSTALL_DIR:-$PREFIX/lib/opencode}"
BIN="$PREFIX/bin/opencode"
TMP="${TMPDIR:-$PREFIX/tmp}/opencode-install.$$"

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.24"
ALPINE_LIB="$ALPINE_BASE/main/aarch64"
MUSL_ROOTFS="$ALPINE_BASE/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz"
LIBGCC="$ALPINE_LIB/libgcc-15.2.0-r5.apk"
LIBSTDCXX="$ALPINE_LIB/libstdc++-15.2.0-r5.apk"
OPENCODE="https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/-/cli-linux-arm64-musl-$VERSION.tgz"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

die() { printf '%s\n' "opencode-termux: ERROR: $*" >&2; exit 1; }
log() { printf '%s\n' "opencode-termux: $*"; }

[ "$(uname -m 2>/dev/null || true)" = "aarch64" ] || die "Android ARM64 (aarch64) is required"
[ -n "${TERMUX_VERSION:-}" ] || die "Termux is required"
command -v pkg >/dev/null 2>&1 || die "Termux package manager not found"

pkg install -y curl tar gzip coreutils >/dev/null
rm -rf "$TMP" "$ROOT"
mkdir -p "$TMP" "$ROOT/bin" "$ROOT/lib"

log "Downloading OpenCode v$VERSION ARM64 musl binary..."
curl -fL --retry 3 --retry-delay 1 "$OPENCODE" -o "$TMP/opencode.tgz"
tar -xzf "$TMP/opencode.tgz" -C "$TMP"
BINARY="$(find "$TMP/package" -type f \( -name opencode -o -name opencode2 \) -print -quit 2>/dev/null || true)"
[ -n "$BINARY" ] || die "OpenCode binary not found in package"
cp "$BINARY" "$ROOT/bin/opencode"
chmod 755 "$ROOT/bin/opencode"

log "Installing verified Alpine 3.24.2 musl runtime..."
curl -fL --retry 3 --retry-delay 1 "$MUSL_ROOTFS" -o "$TMP/alpine.tar.gz"
mkdir -p "$TMP/alpine"
tar -xzf "$TMP/alpine.tar.gz" -C "$TMP/alpine" ./lib/ld-musl-aarch64.so.1 ./lib/libc.musl-aarch64.so.1
cp "$TMP/alpine/lib/ld-musl-aarch64.so.1" "$ROOT/lib/"
cp "$TMP/alpine/lib/libc.musl-aarch64.so.1" "$ROOT/lib/"
chmod 755 "$ROOT/lib/ld-musl-aarch64.so.1" "$ROOT/lib/libc.musl-aarch64.so.1"

for spec in "libgcc:$LIBGCC" "libstdc++:$LIBSTDCXX"; do
  name="${spec%%:*}"
  url="${spec#*:}"
  file="$TMP/$name.apk"
  log "Downloading Alpine $name runtime..."
  curl -fL --retry 3 --retry-delay 1 "$url" -o "$file"
  mkdir -p "$TMP/$name"
  tar -xzf "$file" -C "$TMP/$name"
done

[ -f "$TMP/libgcc/usr/lib/libgcc_s.so.1" ] || die "libgcc_s.so.1 missing from verified Alpine package"
cp "$TMP/libgcc/usr/lib/libgcc_s.so.1" "$ROOT/lib/"

STD_REAL="$(find "$TMP/libstdc++" -type f -name 'libstdc++.so.6.*' -print -quit)"
[ -n "$STD_REAL" ] || die "versioned libstdc++.so.6 library missing from Alpine package"
cp "$STD_REAL" "$ROOT/lib/libstdc++.so.6.0.34"
ln -sf libstdc++.so.6.0.34 "$ROOT/lib/libstdc++.so.6"
[ -f "$ROOT/lib/libstdc++.so.6.0.34" ] || die "libstdc++.so.6 library was not installed correctly"
[ -L "$ROOT/lib/libstdc++.so.6" ] || die "libstdc++.so.6 symlink was not installed correctly"

cat > "$BIN" <<'EOF'
#!/system/bin/sh
set -eu
ROOT="__OPENCODE_ROOT__"
LOADER="\$ROOT/lib/ld-musl-aarch64.so.1"
PROGRAM="\$ROOT/bin/opencode"
unset LD_PRELOAD
unset LD_LIBRARY_PATH
export LD_LIBRARY_PATH="\$ROOT/lib"
export SSL_CERT_FILE="${SSL_CERT_FILE:-__OPENCODE_PREFIX__/etc/tls/cert.pem}"
export TERM="\${TERM:-xterm-256color}"
# OpenCode v2 starts its managed service by re-executing process.execPath.
# Under an explicit musl-loader launch, process.execPath is the loader itself,
# so upstream would try to execute "serve" as a program. Start the managed
# service with the real binary first, then let the client discover it.
start_service() {
  service_log="\$ROOT/service.log"
  "\$LOADER" --library-path "\$ROOT/lib" "\$PROGRAM" serve --service >"\$service_log" 2>&1 &
}

case "\${1:-}" in
  ""|run|attach|session|agent|mcp|plugin|project|stats|export|import|api|models)
    start_service
    exec "\$LOADER" --library-path "\$ROOT/lib" "\$PROGRAM" "\$@"
    ;;
  service|serve|--server|--standalone|--version|-v|--help|-h|help|completion|upgrade|auth)
    exec "\$LOADER" --library-path "\$ROOT/lib" "\$PROGRAM" "\$@"
    ;;
  *)
    start_service
    exec "\$LOADER" --library-path "\$ROOT/lib" "\$PROGRAM" "\$@"
    ;;
esac
EOF
sed -i "s|__OPENCODE_ROOT__|$ROOT|g; s|__OPENCODE_PREFIX__|$PREFIX|g" "$BIN"
chmod 755 "$BIN"

log "Running ARM64 smoke test..."
"$BIN" --version
"$BIN" run --help >/dev/null

log "OpenCode v$VERSION installed successfully."
log "Run: opencode"

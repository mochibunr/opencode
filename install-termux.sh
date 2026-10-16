#!/system/bin/sh
set -eu

VERSION="${OPENCODE_VERSION:-2.0.31}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${OPENCODE_INSTALL_DIR:-$PREFIX/lib/opencode}"
BIN="$PREFIX/bin/opencode"
TMP="${TMPDIR:-$PREFIX/tmp}/opencode-install.$"
SERVICE_PID=""

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.24"
ALPINE_LIB="$ALPINE_BASE/main/aarch64"
MUSL_ROOTFS="$ALPINE_BASE/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz"
LIBGCC="$ALPINE_LIB/libgcc-15.2.0-r5.apk"
LIBSTDCXX="$ALPINE_LIB/libstdc++-15.2.0-r5.apk"
OPENCODE="https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/-/cli-linux-arm64-musl-$VERSION.tgz"

cleanup() { [ -z "$SERVICE_PID" ] || kill "$SERVICE_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

die() { printf '%s\n' "opencode-termux: ERROR: $*" >&2; exit 1; }
log() { printf '%s\n' "opencode-termux: $*"; }

[ "$(uname -m 2>/dev/null || true)" = "aarch64" ] || die "Android ARM64 (aarch64) is required"
[ -n "${TERMUX_VERSION:-}" ] || die "Termux is required"
command -v pkg >/dev/null 2>&1 || die "Termux package manager not found"

pkg install -y curl tar gzip coreutils patchelf >/dev/null
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

# Patch the ELF interpreter instead of explicitly invoking musl-loader.
# This is required because OpenCode/Bun re-executes process.execPath for its
# managed service. If we launch through the loader, process.execPath becomes
# ld-musl-aarch64.so.1 and the re-exec tries to load "serve" as an executable.
log "Configuring ARM64 ELF interpreter..."
"$PREFIX/bin/patchelf" --set-interpreter "$ROOT/lib/ld-musl-aarch64.so.1" --set-rpath "$ROOT/lib" "$ROOT/bin/opencode" || die "failed to configure musl ELF interpreter"
[ "$("$PREFIX/bin/patchelf" --print-interpreter "$ROOT/bin/opencode")" = "$ROOT/lib/ld-musl-aarch64.so.1" ] || die "ELF interpreter was not configured correctly"
[ "$("$PREFIX/bin/patchelf" --print-rpath "$ROOT/bin/opencode")" = "$ROOT/lib" ] || die "ELF runtime path was not configured correctly"

cat > "$BIN" <<'EOF'
#!/system/bin/sh
set -eu
ROOT="__OPENCODE_ROOT__"
PROGRAM="$ROOT/bin/opencode"
unset LD_PRELOAD
export LD_LIBRARY_PATH="$ROOT/lib"
export SSL_CERT_FILE="${SSL_CERT_FILE:-__OPENCODE_PREFIX__/etc/tls/cert.pem}"
export TERM="${TERM:-xterm-256color}"
exec "$PROGRAM" "$@"
EOF
sed -i "s|__OPENCODE_ROOT__|$ROOT|g; s|__OPENCODE_PREFIX__|$PREFIX|g" "$BIN"
chmod 755 "$BIN"

log "Running ARM64 smoke test..."
"$BIN" --version
"$BIN" run --help >/dev/null
[ -x "$ROOT/bin/opencode" ] || die "installed OpenCode binary is not executable"

# Exercise the actual managed-service entrypoint in an isolated state directory.
# This catches the exact class of failure where the wrapper/loader can run the
# CLI but cannot start `serve --service`.
SERVICE_HOME="$TMP/service-home"
mkdir -p "$SERVICE_HOME" "$TMP/service-state" "$TMP/service-data" "$TMP/service-config" "$TMP/service-cache"
HOME="$SERVICE_HOME" \
XDG_STATE_HOME="$TMP/service-state" \
XDG_DATA_HOME="$TMP/service-data" \
XDG_CONFIG_HOME="$TMP/service-config" \
XDG_CACHE_HOME="$TMP/service-cache" \
"$BIN" serve --service --port 0 >"$TMP/service.log" 2>&1 &
SERVICE_PID=$!
SERVICE_ALIVE=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if kill -0 "$SERVICE_PID" 2>/dev/null; then
    state="$(awk '{print $3}' "/proc/$SERVICE_PID/stat" 2>/dev/null || true)"
    if [ "$state" != "Z" ]; then
      SERVICE_ALIVE=true
      break
    fi
    break
  fi
  sleep 0.2
done
if [ "$SERVICE_ALIVE" != "true" ]; then
  wait "$SERVICE_PID" 2>/dev/null || true
  cat "$TMP/service.log" >&2 || true
  die "OpenCode managed service failed to start"
fi
kill "$SERVICE_PID" 2>/dev/null || true
wait "$SERVICE_PID" 2>/dev/null || true
SERVICE_PID=""

log "Testing managed-service client path..."
HOME="$SERVICE_HOME" \
XDG_STATE_HOME="$TMP/service-state" \
XDG_DATA_HOME="$TMP/service-data" \
XDG_CONFIG_HOME="$TMP/service-config" \
XDG_CACHE_HOME="$TMP/service-cache" \
timeout 20 "$BIN" session list --format json >/dev/null ||
  die "OpenCode client could not start or connect to its managed service"

log "OpenCode v$VERSION installed successfully."
log "Run: opencode"

#!/system/bin/sh
set -eu

# OpenCode v2 native Termux / Android ARM64 installer.
# No npm, proot, chroot, Docker, or root required.

VERSION="${OPENCODE_VERSION:-2.0.31}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${OPENCODE_INSTALL_DIR:-$PREFIX/lib/opencode}"
BIN="$PREFIX/bin/opencode"
TMP="${TMPDIR:-$PREFIX/tmp}/opencode-install.$"
SERVICE_PID=""

# Alpine 3.24.2 is hosted in the v3.24 repository.
ALPINE_VERSION="${OPENCODE_ALPINE_VERSION:-3.24.2}"
ALPINE_BRANCH="${OPENCODE_ALPINE_BRANCH:-3.24}"
ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_BRANCH"
ALPINE_MAIN="$ALPINE_BASE/main/aarch64"
OPENCODE_TARBALL="https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/-/cli-linux-arm64-musl-$VERSION.tgz"

cleanup() { [ -z "$SERVICE_PID" ] || kill "$SERVICE_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

die() { printf '%s\n' "opencode-termux: $*" >&2; exit 1; }
log() { printf '%s\n' "opencode-termux: $*"; }

[ "$(uname -m 2>/dev/null || true)" = "aarch64" ] ||
  die "this installer requires Android ARM64 (aarch64)"
[ -n "${TERMUX_VERSION:-}" ] || die "this installer is for Termux"
command -v pkg >/dev/null 2>&1 || die "Termux package manager not found"

mkdir -p "$TMP" "$ROOT/bin" "$ROOT/lib"
pkg install -y curl tar gzip coreutils patchelf >/dev/null

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

find "$TMP/apk/usr/lib" -maxdepth 1 \( -type f -o -type l \) -name 'libstdc++.so*' -exec cp -a {} "$ROOT/lib/" \;
find "$TMP/apk/usr/lib" -maxdepth 1 \( -type f -o -type l \) -name 'libgcc_s.so*' -exec cp -a {} "$ROOT/lib/" \;

[ -f "$ROOT/lib/libstdc++.so.6" ] || die "libstdc++.so.6 was not installed"
[ -f "$ROOT/lib/libgcc_s.so.1" ] || die "libgcc_s.so.1 was not installed"

log "Configuring ARM64 ELF interpreter..."
"$PREFIX/bin/patchelf" --set-interpreter "$ROOT/lib/ld-musl-aarch64.so.1" --set-rpath "$ROOT/lib" "$ROOT/bin/opencode" ||
  die "failed to configure musl ELF interpreter"
[ "$("$PREFIX/bin/patchelf" --print-interpreter "$ROOT/bin/opencode")" = "$ROOT/lib/ld-musl-aarch64.so.1" ] ||
  die "ELF interpreter was not configured correctly"
[ "$("$PREFIX/bin/patchelf" --print-rpath "$ROOT/bin/opencode")" = "$ROOT/lib" ] ||
  die "ELF runtime path was not configured correctly"

cat > "$BIN" <<EOF
#!/system/bin/sh
set -eu

ROOT="$ROOT"
PROGRAM="$ROOT/bin/opencode"

# Never let Termux's Bionic LD_PRELOAD helper enter the musl process.
unset LD_PRELOAD
export LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
export TERM="${TERM:-xterm-256color}"
export OPENCODE_DISABLE_TUI_AUDIO="${OPENCODE_DISABLE_TUI_AUDIO:-1}"

# The ELF interpreter is patched into the OpenCode binary, so Bun's
# process.execPath remains the real OpenCode executable. This is important
# because OpenCode v2 re-executes process.execPath when starting its service.
exec "$PROGRAM" "$@"
EOF
chmod 755 "$BIN"

log "Running ARM64 smoke test..."
"$BIN" --version >/dev/null || die "installed OpenCode failed its ARM64 smoke test"
"$BIN" run --help >/dev/null || die "installed OpenCode failed its run-command smoke test"

# Exercise the actual managed-service entrypoint in an isolated state directory.
# This catches loader/wrapper failures that only appear when `serve --service`
# is launched as a child process.
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

log "Installed OpenCode v$VERSION successfully"
log "Run: opencode"

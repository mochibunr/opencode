# Android / Termux ARM64

This fork includes a Termux installer for OpenCode v2.

## Install

On an ARM64 Termux device:

```sh
curl -fsSL https://raw.githubusercontent.com/mochibunr/opencode/dev/install-termux.sh | sh
```

The installer does not use npm, proot, chroot, Docker, or root.

It installs the ARM64 musl OpenCode binary and the matching musl runtime under:

- `$PREFIX/lib/opencode/bin/opencode`
- `$PREFIX/lib/opencode/lib/`

and exposes:

```text
$PREFIX/bin/opencode
```

The installer patches the OpenCode ELF interpreter to the bundled musl loader. This lets OpenCode/Bun re-execute its real `process.execPath` when starting the managed background service, instead of accidentally re-executing the musl loader with `serve` as its program.

## Version

The installer is pinned to OpenCode v2.0.31 by default:

```sh
OPENCODE_VERSION=2.0.31 curl -fsSL https://raw.githubusercontent.com/mochibunr/opencode/android-termux-arm64/install.sh | sh
```

To test another published platform-package version:

```sh
OPENCODE_VERSION=<version> curl -fsSL https://raw.githubusercontent.com/mochibunr/opencode/android-termux-arm64/install.sh | sh
```

## Requirements

- Termux
- Android ARM64 / `aarch64`
- Android networking access
- Enough storage for the OpenCode binary and musl runtime

The installer downloads the OpenCode ARM64 musl package from the npm registry directly with `curl`; npm itself is never installed or invoked. The musl loader and C++ runtime are obtained from Alpine Linux.

## Important implementation detail

Android uses Bionic libc, while the OpenCode ARM64 musl binary uses musl. Termux can execute the binary without a Linux userspace/container by patching the ELF interpreter to the bundled musl loader and supplying the required musl libraries. The launcher also removes Termux’s Bionic `LD_PRELOAD`, which is incompatible with the musl process.

This is a native Termux process, but it is **not** a pure Bionic build. A future pure-Bionic build would require Android-specific native builds of OpenTUI and PTY dependencies.

## Smoke tests

The installer refuses to finish unless both commands succeed:

```sh
opencode --version
opencode run --help
```

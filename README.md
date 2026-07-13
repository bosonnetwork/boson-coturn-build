# Static coturn Builds

Build automation that produces portable [coturn](https://github.com/coturn/coturn)
`turnserver` binaries from pinned upstream sources:

- **Linux** (`amd64`, `arm64`) — **fully static** musl-libc binaries: no glibc, no dynamic
  linker, zero `NEEDED` entries. Copy them to any Linux distro (Alpine, Debian, a `scratch`
  container) and run.
- **macOS** — a **universal** (`arm64` + `x86_64`) binary. macOS can't be fully static (Apple
  ships no static `libSystem`), so OpenSSL and libevent are linked as static archives with only
  `libSystem`/`libresolv` remaining dynamic — the standard "static-ish" macOS binary.

This repository contains only the build scripts; the coturn, OpenSSL, libevent, and musl sources
are downloaded during the build.

## Requirements

| Building for | Needs |
|--------------|-------|
| Linux, from a **Linux** host | `build-essential make curl perl pkg-config linux-libc-dev` |
| Linux, from a **macOS** host | Docker with buildx (e.g. Docker Desktop or OrbStack) |
| macOS | Xcode command-line tools (`clang`, `lipo`). No Rosetta required. |

## Quick start

On a **macOS** host (the root `Makefile` orchestrates everything):

```bash
make            # build everything: both Linux static binaries + macOS universal
make verify     # sanity-check all outputs
```

On a **Linux** host (no Docker, no macOS logic — build natively for the host arch):

```bash
make -f linux.mk           # fully static binary for this host's architecture
make -f linux.mk verify    # file / ldd / readelf checks
```

Binaries are written to `output/`.

## Build targets

Run from a macOS host via the root `Makefile`:

| Target | Result |
|--------|--------|
| `make` / `make all` | Both Linux static binaries (via Docker) + the macOS universal binary |
| `make linux-amd64` | `output/turnserver-linux-amd64` (fully static, via buildx) |
| `make linux-arm64` | `output/turnserver-linux-arm64` (fully static, via buildx) |
| `make darwin` / `make darwin-universal` | `output/turnserver-darwin-universal` (fat arm64 + x86_64) |
| `make darwin-arm64` / `make darwin-x86_64` | A single-arch macOS slice |
| `make verify` | `verify-linux-amd64` + `verify-linux-arm64` + `verify-darwin-universal` |
| `make verify-linux-amd64` | Static-ness check inside a clean `debian:bookworm-slim` container |
| `make clean` | Remove build artifacts, keep downloaded tarballs |
| `make distclean` | Remove everything, including downloads |

The Linux targets run each build inside Docker via buildx, natively per platform
(QEMU-emulated when cross-building, e.g. `linux/amd64` on Apple Silicon).

## Repository layout

The build is split into per-platform Makefiles over two shared includes, so a Linux developer
can build natively without Docker or any macOS logic.

| File | Purpose |
|------|---------|
| [`version.mk`](version.mk) | Pinned versions, download URLs, and coturn feature flags. Shared by everything. |
| [`common.mk`](common.mk) | Shared directories, `NPROC`, and the download helper. Includes `version.mk`. |
| [`linux.mk`](linux.mk) | Native musl static build for the host arch (both arches via `uname -m`). Run directly on Linux, and inside the container by the Dockerfile. |
| [`macos.mk`](macos.mk) | Native clang build; produces the universal binary by default. |
| [`Makefile`](Makefile) | Root orchestrator (for macOS hosts): Linux via buildx, macOS delegated to `macos.mk`. |
| [`docker/Dockerfile.musl`](docker/Dockerfile.musl) | Toolchain image: installs deps, copies the `.mk` files in, runs `make -f linux.mk`. |

## Component versions

Pinned in [`version.mk`](version.mk):

| Component | Version |
|-----------|---------|
| musl | 1.2.6 |
| OpenSSL | 3.6.3 |
| libevent | 2.1.13-stable |
| coturn | 4.14.0 |

Each platform builds the same four phases: **musl** (Linux only) → **OpenSSL** → **libevent** →
**coturn**, using coturn's own `./configure` (not CMake).

## What's included

The build disables every optional database and metrics backend so nothing links dynamically
against a library that happens to be installed on the build host (which would break the static
goal). Disabled: MySQL, PostgreSQL, MongoDB, Redis, SQLite, Prometheus, systemd, SCTP.

**Enabled:** STUN/TURN, TLS/DTLS, and the TURN REST API + OAuth (these use only libcrypto, so
they add no dynamic-link risk). See `COTURN_FEATURE_FLAGS` in [`version.mk`](version.mk).

## Verification

`make verify-linux-*` runs inside a stock `debian:bookworm-slim` container and confirms full
static linkage:

```
== file ==   ELF 64-bit LSB executable, ..., statically linked
== ldd ==    not a dynamic executable
== readelf -d (NEEDED entries) ==  (none)
== run ==    4.14.0
```

`make verify-darwin-universal` uses `file`, `lipo -info`, and `otool -L`, expecting a fat binary
whose slices depend only on `libSystem`/`libresolv`.


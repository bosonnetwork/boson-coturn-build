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
| `make licenses` | `output/licenses/` - each component's license notice, from the pinned sources |
| `make dist` | `output/dist/boson-coturn-<version>.tar.gz` + `SHA256SUMS`, unsigned |
| `make release` | `dist` + `SHA256SUMS.asc` signed by the Boson release key (see [Releasing](#releasing)) |
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
| [`release.mk`](release.mk) | Release packaging (included by `Makefile`): license notices, tarball, `SHA256SUMS`, signature. |
| [`scripts/sign-release.sh`](scripts/sign-release.sh) | Signs `SHA256SUMS` with the release key and verifies it against the committed key. |
| [`keys/boson-release.asc`](keys/boson-release.asc) | The Boson release public key (`103C B1D4 C51D E544 61C2 4198 28E1 4DED 565C 5BDE`). |

## Component versions

Pinned in [`version.mk`](version.mk):

| Component | Version |
|-----------|---------|
| musl | 1.2.6 |
| OpenSSL | 3.5.9 |
| libevent | 2.1.13-stable |
| coturn | 4.18.0 |

Each platform builds the same four phases: **musl** (Linux only) → **OpenSSL** → **libevent** →
**coturn**, using coturn's own `./configure` (not CMake).

## What's included

The build disables every optional database and metrics backend so nothing links dynamically
against a library that happens to be installed on the build host (which would break the static
goal). **Disabled:** MySQL, PostgreSQL, MongoDB, Redis, SQLite, Prometheus (and with it the
libmicrohttpd dependency), systemd, SCTP, OAuth.

**Enabled:** STUN/TURN over UDP/TCP and TLS/DTLS, plus the TURN REST API (`--use-auth-secret`
/ `--static-auth-secret`). These use only libcrypto, so they add no dynamic-link risk. The
telnet CLI and the HTTPS web-admin are compiled in but **off by default** (`--cli` /
`--web-admin`) and pull in no extra dependency. Feature toggles live in `COTURN_FEATURE_FLAGS`;
OAuth is turned off via `COTURN_EXTRA_CFLAGS` — coturn's `TURN_NO_OAUTH` environment knob is
broken upstream (see [`version.mk`](version.mk)).

DTLS is compiled in but stays a per-deployment runtime decision: DTLS listeners only start when
`--dtls` is given, so it can be disabled without rebuilding.

The binary is configured with `--prefix=/usr/local --turndbdir=/var/lib/coturn --disable-rpath`
so no throwaway build-staging path is baked into it; run it with `-n` (skip the config file) and
explicit options.

## Hardening and size

Every component is compiled with `-fstack-protector-strong -D_FORTIFY_SOURCE=2`. coturn and
libevent additionally get `-O2` — coturn's own `configure`/`Makefile.in` add **no** `-O` at all,
so without it the relay would be built at `-O0` (and `_FORTIFY_SOURCE` would be inert). OpenSSL
already builds at `-O3`, so it only receives the two security flags. See `HARDENING_CFLAGS` /
`OPENSSL_HARDENING` in [`version.mk`](version.mk).

The binaries are stripped as part of the build (`strip --strip-all` on Linux, `strip -x` on
macOS) to keep the artifacts small for embedding; stripping does not affect static linkage.

## Verification

`make verify-linux-*` runs inside a stock `debian:bookworm-slim` container and confirms full
static linkage:

```
== file ==   ELF 64-bit LSB executable, ..., statically linked
== ldd ==    not a dynamic executable
== readelf -d (NEEDED entries) ==  (none)
== run ==    4.18.0
```

`make verify-darwin-universal` uses `file`, `lipo -info`, and `otool -L`, expecting a fat binary
whose slices depend only on `libSystem`/`libresolv`.


## Releasing

A release is `<coturn version>-<build number>` (`RELEASE_VERSION` in [`version.mk`](version.mk),
e.g. `4.18.0-1`). Bump `RELEASE_BUILD` when the same coturn version is rebuilt (an OpenSSL or
libevent update, a flag change); reset it to `1` on a new coturn version.

On a macOS host, from a clean, committed tree:

```bash
make            # build all binaries
make verify     # check them
make release    # package + sign exactly what was verified
```

`make release` never builds: it packages the binaries already in `output/`, refuses a dirty
tree (the tarball's `BUILDINFO` names the commit), and leaves three assets in `output/dist/`:

| Asset | Contents |
|-------|----------|
| `boson-coturn-<version>.tar.gz` | `bin/turnserver-{linux-amd64,linux-arm64,darwin-arm64,darwin-x86_64}`, `licenses/` (coturn, OpenSSL, libevent, musl), `BUILDINFO` (versions, flags, commit, per-binary sha256) |
| `SHA256SUMS` | sha256 of the tarball |
| `SHA256SUMS.asc` | detached signature by the Boson release key |

Signing follows `super-node-deployment/scripts/dev/make-release.sh --sign`: gpg signs with
exactly the primary key, then `gpgv` verifies against the key **committed** at
`keys/boson-release.asc`. A signature by the wrong key removes the `.asc` and fails the
release. The private key never leaves your keyring; gpg may ask for its passphrase.

The tarball is deterministic for the same binaries (sorted entries, commit-time mtimes,
`root:root`, no macOS metadata, `gzip -n`), so repackaging gives the same sha256. The
universal macOS binary is not shipped; it is just the two darwin slices combined.

`make release` prints the matching `gh release create` command. Consumers (the Boson
distribution build) pin the tarball's sha256, so a re-released tag with different bytes is
rejected rather than silently picked up.

# restic-deb

Unofficial Debian (`.deb`) packaging for [Restic](https://github.com/restic/restic).

This repository runs a scheduled GitHub Actions workflow that downloads
official upstream `restic_<version>_linux_<arch>.bz2` release assets,
repackages their contents into standard Debian packages (`/usr/bin/restic`,
man pages in `/usr/share/man/man1/`, and shell completions for Bash, Zsh, and
Fish), runs smoke and upgrade tests across Debian and Ubuntu distros, and publishes
the resulting `.deb` packages as GitHub Releases.

This project is **not affiliated with or endorsed by the Restic project**.

Building the packages locally requires `docker`, `curl`, `bunzip2`, and `bash`.
Debian-specific packaging steps (`restic generate`, `dpkg-deb --build`) run inside a
`debian:13` container, so the build scripts work seamlessly from macOS or any Linux host
without local Debian packaging tools installed.

## Install

```sh
curl -LO https://github.com/codexscribo/restic-deb/releases/latest/download/restic_<version>_amd64.deb
sudo apt install ./restic_<version>_amd64.deb
```

Replace `amd64` with `arm64` on ARM systems (e.g. Raspberry Pi, AWS Graviton), and `<version>`
with the full version string from the release you downloaded (e.g. `0.19.1-1`).

The package is named `restic`, matching Debian and Ubuntu's stock package name.
Installing it cleanly upgrades and supersedes whatever distro-provided `restic` package
(if any) is already installed.

## Included features

- **Executable binary**: `/usr/bin/restic`
- **Man pages**: Comprehensive section 1 man pages (`/usr/share/man/man1/restic*.1.gz`)
  generated directly from the upstream restic binary
- **Shell completions**:
  - Bash: `/usr/share/bash-completion/completions/restic`
  - Zsh: `/usr/share/zsh/vendor-completions/_restic`
  - Fish: `/usr/share/fish/vendor_completions.d/restic.fish`
- **Documentation**: Debian changelog and copyright documentation in `/usr/share/doc/restic/`

## Supported architectures

- `amd64` (x86_64)
- `arm64` (aarch64)

## Versioning

Package versions follow Debian's `<upstream_version>-<package_revision>`
convention, e.g. `0.19.1-1`. `<upstream_version>` is the upstream Restic
version; `<package_revision>` identifies how many times *this repackaging*
has been published for that same upstream version. A packaging-only fix
can be re-released as `0.19.1-2` without waiting for a new upstream Restic release.
Each `<version>-<revision>` combination is published as its own GitHub Release,
tagged e.g. `v0.19.1-1`, so every past revision stays downloadable — grabbing the
`latest` release always gets you the newest revision of the newest version.

## How it works

1. **`scripts/build-deb.sh <version> <arch> [package_revision]`** downloads
   the matching upstream release asset (`restic_<version>_linux_<arch>.bz2`),
   decompresses the executable to `pkgroot/usr/bin/restic`, sets up Debian documentation
   ([`debian/copyright`](./debian/copyright) and rendered
   [`debian/changelog.template`](./debian/changelog.template)), and renders
   [`debian/control.template`](./debian/control.template). It then runs a `debian:13`
   container to:
   - Generate man pages (`restic generate --man`) and compress them with `gzip -9n`
   - Generate Bash, Zsh, and Fish shell completions (`restic generate --*-completion`)
   - Check runtime shared-library dependencies with `ldd` + `dpkg -S`
   - Compute `Installed-Size`
   - Build the `.deb` with `dpkg-deb --root-owner-group --build`
2. **`scripts/test-deb.sh <restic-deb> <version>`**
   installs the distro's own stock `restic` package first (exercising the upgrade path),
   installs the built `.deb` over it, checks that `restic` reports the expected version,
   exercises functional tests (initializing a repo, creating a snapshot, verifying snapshots and repository integrity),
   confirms man pages and shell completions are properly installed and owned by the `restic` package,
   and verifies clean uninstallation.
3. **`.github/workflows/release.yml`** runs on a daily schedule and can be
   triggered manually (`workflow_dispatch`). It resolves the latest upstream Restic release
   and auto-picks the next package revision. It builds `.deb` packages for both `amd64` and `arm64`,
   smoke-tests each package across Ubuntu 22.04, 24.04, 26.04 and Debian 12, 13 (including upgrading
   from stock distro packages), and publishes a GitHub Release if every test passes.

## Caveats

- This is a repackaging of upstream prebuilt binaries, not an independently compiled package.
- No APT repository is provided; packages are distributed as GitHub Release assets.
- Upstream prebuilt Restic binaries are statically linked and include their own dependencies.

## License

[MIT](./LICENSE) — applies to the packaging scripts and CI in this repo only,
not to Restic itself (see [restic/restic](https://github.com/restic/restic)
for its license).

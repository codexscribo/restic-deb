#!/usr/bin/env bash
# Repackage an official upstream Restic prebuilt release into a .deb.
#
# Usage: build-deb.sh <version> <arch> [package_revision]
#   <version>           upstream tag, e.g. v0.19.1
#   <arch>              amd64 | arm64
#   [package_revision]  our packaging revision for this upstream version
#                        (Debian "debian_revision" convention). Defaults to 1.
#                        Bump this to publish a new .deb for the same
#                        upstream Restic version, e.g. after a packaging-only
#                        fix, without waiting for a new upstream release.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <version> <arch> [package_revision]" >&2
  exit 1
fi

version="$1"
arch="$2"
package_revision="${3:-1}"

# Debian packages to install inside the build container before running the
# ldd-based dependency-detection loop below, keyed by nothing in particular
# -- just a flat curated allowlist. Upstream restic binaries are statically
# linked Go binaries; if a future release links dynamically against a shared
# library not present in the base debian image, add the owning package here.
# The hard-fail check further down guarantees this list cannot silently fall
# out of date.
extra_packages=()

# Image used to run ldd/dpkg-deb so dependency detection, man page/completion
# generation, and package building are reproducible regardless of host OS
# (this script is expected to work from macOS too). debian:13 matches the
# GitHub Actions runners' native platforms (amd64: ubuntu-latest; arm64:
# ubuntu-24.04-arm), so no QEMU emulation is needed on native runners.
build_image="${BUILD_IMAGE:-debian:13}"

case "$arch" in
  amd64|arm64) ;;
  *)
    echo "Unsupported arch: $arch (expected amd64 or arm64)" >&2
    exit 1
    ;;
esac

version_number="${version#v}"
deb_version="${version_number}-${package_revision}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

asset="restic_${version_number}_linux_${arch}.bz2"
url="https://github.com/restic/restic/releases/download/${version}/${asset}"

echo "Downloading ${url}"
curl -fL --retry 3 -o "$work_dir/$asset" "$url"

echo "Extracting ${asset}"
bunzip2 -c "$work_dir/$asset" > "$work_dir/restic"
chmod 755 "$work_dir/restic"

echo "Building package root"
pkgroot="$work_dir/pkgroot"
mkdir -p "$pkgroot/usr/bin" "$pkgroot/DEBIAN"
cp "$work_dir/restic" "$pkgroot/usr/bin/restic"

doc_dir="$pkgroot/usr/share/doc/restic"
mkdir -p "$doc_dir"
cp "$repo_root/debian/copyright" "$doc_dir/copyright"

changelog="$work_dir/changelog.Debian"
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__UPSTREAM_TAG__/${version}/g" \
    -e "s/__ARCH__/${arch}/g" \
    -e "s/__DATE__/$(date -R)/g" \
    "$repo_root/debian/changelog.template" > "$changelog"
gzip -9n -c "$changelog" > "$doc_dir/changelog.Debian.gz"

sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__ARCH__/${arch}/g" \
    "$repo_root/debian/control.template" > "$pkgroot/DEBIAN/control"

deb_name="restic_${deb_version}_${arch}.deb"
pkgroot_container="/work/pkgroot"

cat > "$work_dir/container-build.sh" <<'EOS'
set -euo pipefail

if [[ -n "$EXTRA_PACKAGES" ]]; then
  echo "Installing curated dependency packages: $EXTRA_PACKAGES"
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $EXTRA_PACKAGES
fi

echo "Generating man pages and shell completions"
mkdir -p "$PKGROOT/usr/share/man/man1"
mkdir -p "$PKGROOT/usr/share/bash-completion/completions"
mkdir -p "$PKGROOT/usr/share/zsh/vendor-completions"
mkdir -p "$PKGROOT/usr/share/fish/vendor_completions.d"

"$PKGROOT/usr/bin/restic" generate --man "$PKGROOT/usr/share/man/man1"
gzip -9n "$PKGROOT"/usr/share/man/man1/*.1

"$PKGROOT/usr/bin/restic" generate --bash-completion "$PKGROOT/usr/share/bash-completion/completions/restic"
"$PKGROOT/usr/bin/restic" generate --zsh-completion "$PKGROOT/usr/share/zsh/vendor-completions/_restic"
"$PKGROOT/usr/bin/restic" generate --fish-completion "$PKGROOT/usr/share/fish/vendor_completions.d/restic.fish"

echo "Detecting runtime dependencies"
mapfile -t elf_files < <(find "$PKGROOT/usr/bin" -type f -perm -u+x 2>/dev/null)

declare -A dep_packages=()
missing_libs=()
for elf in "${elf_files[@]}"; do
  # Skip non-dynamic ELFs (e.g. statically linked Go binaries) or non-ELF files silently.
  if ! ldd "$elf" >/dev/null 2>&1; then
    continue
  fi
  ldd_output="$(ldd "$elf" 2>/dev/null)"

  if grep -q 'not found$' <<<"$ldd_output"; then
    while IFS= read -r missing_line; do
      missing_libs+=("$elf: ${missing_line# }")
    done < <(grep 'not found$' <<<"$ldd_output")
  fi

  while IFS= read -r libpath; do
    [[ -z "$libpath" ]] && continue
    [[ "$libpath" == *"linux-vdso"* || "$libpath" == *"ld-linux"* ]] && continue
    [[ -e "$libpath" ]] || continue
    # dpkg's file list records canonical paths (e.g. /usr/lib/...), but ldd
    # reports paths through symlinks like /lib -> usr/lib, so resolve first.
    real_libpath="$(readlink -f "$libpath")"
    pkg="$(dpkg -S "$real_libpath" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    [[ -n "$pkg" ]] && dep_packages["$pkg"]=1
  done < <(awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }' <<<"$ldd_output")
done

if [[ ${#missing_libs[@]} -gt 0 ]]; then
  echo "ERROR: ldd reported unresolved shared library dependencies:" >&2
  printf '  %s\n' "${missing_libs[@]}" >&2
  echo "Add the Debian package that owns the missing SONAME(s) to the" >&2
  echo "extra_packages allowlist in scripts/build-deb.sh." >&2
  exit 1
fi

ldd_depends="$(IFS=,; echo "${!dep_packages[*]}" | sed 's/,/, /g')"
if [[ -n "$ldd_depends" ]]; then
  sed -i "s|__DEPENDS__|Depends: ${ldd_depends}|" "$PKGROOT/DEBIAN/control"
else
  sed -i '/__DEPENDS__/d' "$PKGROOT/DEBIAN/control"
fi

installed_size="$(du -sk "$PKGROOT/usr" | cut -f1)"
sed -i "s/__INSTALLED_SIZE__/${installed_size}/g" "$PKGROOT/DEBIAN/control"

echo "Building ${OUT_DEB}"
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT_DEB"
EOS

echo "Detecting dependencies and building package inside ${build_image}"
docker run --rm --platform "linux/${arch}" \
  -e "PKGROOT=${pkgroot_container}" \
  -e "EXTRA_PACKAGES=${extra_packages[*]:-}" \
  -e "OUT_DEB=/work/${deb_name}" \
  -v "$work_dir:/work" \
  "$build_image" bash /work/container-build.sh

mkdir -p "$dist_dir"
deb_path="$dist_dir/$deb_name"
cp "$work_dir/$deb_name" "$deb_path"

echo "Done: ${deb_path}"

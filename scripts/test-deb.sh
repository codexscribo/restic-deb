#!/usr/bin/env bash
# Install, smoke-test, and uninstall built restic .deb inside a distro container.
#
# Usage: test-deb.sh <restic-deb> <expected-version>
# Intended to run as root inside an Ubuntu/Debian Docker container.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <restic-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
expected_version="$2"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"

export DEBIAN_FRONTEND=noninteractive

# Official Ubuntu Docker images configure dpkg to skip installing man pages
# (and other docs) to keep images small. Disable it for this test.
rm -f /etc/dpkg/dpkg.cfg.d/excludes

apt-get update -qq || fail "apt-get update"

# If the distro provides a stock restic package, install it first to test
# that our package cleanly upgrades over the distro's package.
echo "==> Testing upgrade over distro stock restic package (if available)"
if apt-get install -y --no-install-recommends restic; then
  command -v restic >/dev/null 2>&1 || fail "restic not found after installing stock package"
  echo "Stock version: $(restic version)"
fi

echo "==> Installing $deb_path over stock package (or cleanly)"
apt-get install -y "./${deb_path}" || fail "apt-get install failed"

echo "==> Verifying upgrade replaced the stock package"
hash -r
restic_version_output="$(restic version)"
echo "$restic_version_output"
echo "$restic_version_output" | grep -qF "$expected_version" || fail "restic version does not reflect expected version '$expected_version'"

echo "==> Verifying functional smoke tests"
test_repo="/tmp/test-restic-repo"
rm -rf "$test_repo"
export RESTIC_PASSWORD="test-smoke-password"
restic init -r "$test_repo" || fail "restic init failed"
restic backup -r "$test_repo" /etc/hosts || fail "restic backup failed"
restic snapshots -r "$test_repo" || fail "restic snapshots failed"
restic check -r "$test_repo" || fail "restic check failed"
rm -rf "$test_repo"

echo "==> Verifying man pages and shell completions"
test -f /usr/share/man/man1/restic.1.gz || fail "man page /usr/share/man/man1/restic.1.gz not installed"
test -f /usr/share/man/man1/restic-backup.1.gz || fail "man page /usr/share/man/man1/restic-backup.1.gz not installed"
test -f /usr/share/bash-completion/completions/restic || fail "bash completion not installed"
test -f /usr/share/zsh/vendor-completions/_restic || fail "zsh completion not installed"
test -f /usr/share/fish/vendor_completions.d/restic.fish || fail "fish completion not installed"

echo "==> Verifying dpkg package status and ownership"
dpkg -s restic | grep -q "^Status: install ok installed" || fail "dpkg status for restic is not 'install ok installed'"
dpkg -S /usr/bin/restic | grep -q "^restic:" || fail "restic binary is not owned by restic package"
dpkg -S /usr/share/man/man1/restic.1.gz | grep -q "^restic:" || fail "man page is not owned by restic package"

echo "==> Uninstalling restic"
apt-get remove -y restic || fail "apt-get remove restic failed"
hash -r

if command -v restic >/dev/null 2>&1; then
  fail "restic still present on PATH after removing restic"
fi

if dpkg -s restic 2>/dev/null | grep -q "^Status: install ok installed"; then
  fail "restic still reports as installed after removal"
fi

echo "PASS: all checks succeeded"

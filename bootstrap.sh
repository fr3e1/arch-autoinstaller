#!/usr/bin/env bash
# arch-autoinstaller bootstrap: run from the Arch Linux live ISO with
#
#   curl -L fr3e.ca/arch | bash                 # web dashboard (default)
#   curl -L fr3e.ca/arch | bash -s -- --menu    # terminal dashboard
#   curl -L fr3e.ca/arch | bash -s -- --help    # all options
#
# Downloads the latest installer (no git needed) to /root/arch-autoinstaller
# and starts it. Any arguments are passed on to install.sh.
#
# Everything is inside main() so a partially downloaded script never runs.

main() {
  set -euo pipefail
  local repo=fr3e1/arch-autoinstaller
  local branch=${ARCH_AUTOINSTALLER_BRANCH:-main}
  local dir=/root/arch-autoinstaller
  local url="https://codeload.github.com/$repo/tar.gz/refs/heads/$branch"

  if [[ $EUID -ne 0 ]]; then
    echo "Run this as root on the Arch Linux live ISO." >&2
    exit 1
  fi
  if [[ ! -d /run/archiso ]]; then
    echo "Warning: this does not look like the Arch Linux live ISO." >&2
  fi

  echo ":: Downloading arch-autoinstaller ($branch)..."
  local tmp
  tmp=$(mktemp -d)
  if ! curl -fsSL --retry 3 "$url" | tar -xz -C "$tmp" --strip-components=1; then
    echo "Download failed. Check the internet connection (use 'iwctl' for Wi-Fi)." >&2
    rm -rf "$tmp"
    exit 1
  fi

  # Keep the config from a previous run so a retry does not lose your choices.
  if [[ -f "$dir/config" ]]; then cp "$dir/config" "$tmp/config"; fi
  rm -rf "$dir"
  mv "$tmp" "$dir"
  chmod +x "$dir/install.sh"

  (($#)) || set -- --web
  cd "$dir"
  # stdin is this script when piped from curl, so read answers from the terminal.
  exec ./install.sh "$@" </dev/tty
}

main "$@"

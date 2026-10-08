#!/usr/bin/env bash
# Builds holo from this checkout and installs it for the current user
# (no root needed): ~/.local/bin/holo and a systemd user unit.
#
#   scripts/linux/install.sh            build and install
#   scripts/linux/install.sh --uninstall
#
# Prefer the .deb package on Debian/Ubuntu; this is for other setups.
set -euo pipefail
cd "$(dirname "$0")/../.."

PREFIX=${PREFIX:-$HOME/.local}
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
APP_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/applications

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now holo.service 2>/dev/null || true
  rm -f "$PREFIX/bin/holo" "$PREFIX/bin/holo-screenshot-portal" "$UNIT_DIR/holo.service" "$APP_DIR/holo.desktop"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "Removed holo. Profiles remain in ${XDG_DATA_HOME:-$HOME/.local/share}/Holo."
  exit 0
fi

# shellcheck disable=SC2086
swift build -c release --static-swift-stdlib --product holo ${SWIFT_BUILD_FLAGS:-}
install -Dm755 "$(swift build -c release --show-bin-path)/holo" "$PREFIX/bin/holo"
install -Dm755 packaging/linux/holo-screenshot-portal "$PREFIX/bin/holo-screenshot-portal"
install -d "$UNIT_DIR"
sed "s|@BINDIR@|$PREFIX/bin|" packaging/linux/holo.service.in > "$UNIT_DIR/holo.service"
install -Dm644 packaging/linux/holo.desktop "$APP_DIR/holo.desktop"
systemctl --user daemon-reload 2>/dev/null || true

echo "Installed $PREFIX/bin/holo"
echo "Next: holo check, holo calibrate, then: systemctl --user enable --now holo"

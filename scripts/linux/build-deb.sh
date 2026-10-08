#!/usr/bin/env bash
# Builds dist/holo_<version>_<arch>.deb from this checkout.
#
#   scripts/linux/build-deb.sh
#
# Needs a Swift toolchain (5.9 or newer), libasound2-dev, and dpkg-deb.
# Extra flags for `swift build` can be passed in SWIFT_BUILD_FLAGS.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=${VERSION:-$(sed -n 's/.*static let string = "\([0-9][0-9.]*\).*/\1/p' Sources/HoloLinuxCLI/Support.swift)}
REVISION=${REVISION:-1}
ARCH=$(dpkg --print-architecture)
OUT=${OUT:-dist}

# shellcheck disable=SC2086
swift build -c release --static-swift-stdlib --product holo ${SWIFT_BUILD_FLAGS:-}
BIN="$(swift build -c release --show-bin-path)/holo"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"
install -Dm755 "$BIN" "$STAGE/usr/bin/holo"
strip --strip-unneeded "$STAGE/usr/bin/holo"
install -Dm755 packaging/linux/holo-screenshot-portal "$STAGE/usr/bin/holo-screenshot-portal"
install -d "$STAGE/usr/lib/systemd/user"
sed 's|@BINDIR@|/usr/bin|' packaging/linux/holo.service.in > "$STAGE/usr/lib/systemd/user/holo.service"
chmod 644 "$STAGE/usr/lib/systemd/user/holo.service"
install -Dm644 packaging/linux/holo.desktop "$STAGE/usr/share/applications/holo.desktop"
install -Dm644 docs/LINUX.md "$STAGE/usr/share/doc/holo/README.md"
install -d "$STAGE/usr/share/man/man1"
for page in holo.1 holo-screenshot-portal.1; do
  gzip -9n < "packaging/linux/$page" > "$STAGE/usr/share/man/man1/$page.gz"
done
gzip -9n < packaging/linux/changelog > "$STAGE/usr/share/doc/holo/changelog.Debian.gz"
chmod 644 "$STAGE"/usr/share/man/man1/*.gz "$STAGE/usr/share/doc/holo/changelog.Debian.gz"
{
  echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
  echo "Upstream-Name: Holo"
  echo "Source: https://github.com/JustinGamer191/Holo"
  echo
  echo "Files: *"
  echo "License: MIT"
  sed 's/^/ /; s/^ $/ ./' LICENSE
} > "$STAGE/usr/share/doc/holo/copyright"

# Runtime dependencies follow from what the binary links against.
GLIBC=$(objdump -T "$STAGE/usr/bin/holo" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)
DEPENDS="libc6 (>= $GLIBC), libstdc++6, libgcc-s1, libasound2t64 | libasound2, python3"
ICU=$(objdump -p "$STAGE/usr/bin/holo" | sed -n 's/.*NEEDED *libicuuc\.so\.\([0-9]*\).*/\1/p')
if [ -n "$ICU" ]; then DEPENDS="$DEPENDS, libicu$ICU"; fi

install -d "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: holo
Version: $VERSION-$REVISION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: Holo Linux port <cruciat@users.noreply.github.com>
Installed-Size: $(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
Depends: $DEPENDS
Recommends: pipewire-bin, wireplumber, pipewire-alsa, libglib2.0-bin, xdg-utils, wl-clipboard, sound-theme-freedesktop
Suggests: espeak-ng | speech-dispatcher, gnome-screenshot, python3-gi
Homepage: https://github.com/JustinGamer191/Holo
Description: tap your desk, your laptop responds
 Holo listens through the laptop's built-in microphone and turns the desk
 around the laptop into four tap zones. Each accepted tap runs the action
 assigned to its zone: a shell command, an app, a website, a file, copied
 or spoken text, a sound, or a screenshot.
 .
 This is the Linux port: guided terminal calibration and evaluation, and
 a systemd user service (holo.service) that listens in the background.
CONTROL

mkdir -p "$OUT"
DEB="$OUT/holo_${VERSION}-${REVISION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null
echo "$DEB"

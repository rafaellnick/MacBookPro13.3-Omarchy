#!/bin/bash
# Build the measured low-wakeup T1Bridge renderer and hardware service.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMIT=81cbdf81026a16e02f0bea74735c6b029a8ffae2
REPOSITORY=https://github.com/standardagents/t1bridge.git
BUILD_DIR=${T1BRIDGE_BUILD_DIR:-/tmp/t1bridge-low-wakeup}
TARGET_USER=${SUDO_USER:-$USER}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_GROUP=$(id -gn "$TARGET_USER")

if [[ $EUID -ne 0 ]]; then
	printf 'Run this helper with sudo; package installation and service files need root.\n' >&2
	exit 1
fi

for command in git cargo install systemctl; do
	command -v "$command" >/dev/null || {
		printf 'Missing required command: %s\n' "$command" >&2
		exit 1
	}
done

case $BUILD_DIR in
	/tmp/*) ;;
	*) printf 'T1BRIDGE_BUILD_DIR must be a child of /tmp.\n' >&2; exit 1 ;;
esac
[[ $BUILD_DIR != /tmp/ ]] || { printf 'Refusing to use /tmp itself.\n' >&2; exit 1; }

rm -rf -- "$BUILD_DIR"
sudo -u "$TARGET_USER" git clone "$REPOSITORY" "$BUILD_DIR"
sudo -u "$TARGET_USER" git -C "$BUILD_DIR" checkout --detach "$COMMIT"
sudo -u "$TARGET_USER" git -C "$BUILD_DIR" apply --unidiff-zero \
	"$HERE/assets/source-patches/t1bridge-low-wakeup.patch"

sudo -u "$TARGET_USER" cargo test --release -p t1-touchbar \
	--manifest-path "$BUILD_DIR/Cargo.toml"
sudo -u "$TARGET_USER" cargo build --release -p t1-touchbar --bin t1-touchbar \
	--manifest-path "$BUILD_DIR/Cargo.toml"
sudo -u "$TARGET_USER" cargo build --release -p t1-touchbar-hw \
	--features service --bin t1-touchbar-hw \
	--manifest-path "$BUILD_DIR/Cargo.toml"

install -D -m 0755 "$BUILD_DIR/target/release/t1-touchbar" \
	/usr/local/lib/t1bridge/t1-touchbar-power
install -D -m 0755 "$BUILD_DIR/target/release/t1-touchbar-hw" \
	/usr/local/lib/t1bridge/t1-touchbar-hw-power
install -D -m 0644 "$HERE/assets/systemd-system/t1-touchbar-hw.service.d/70-power-idle.conf" \
	/etc/systemd/system/t1-touchbar-hw.service.d/70-power-idle.conf
install -D -m 0644 -o "$TARGET_USER" -g "$TARGET_GROUP" \
	"$HERE/assets/systemd-user/t1-touchbar.service.d/70-power-idle.conf" \
	"$TARGET_HOME/.config/systemd/user/t1-touchbar.service.d/70-power-idle.conf"

systemctl daemon-reload
systemctl restart t1-touchbar-hw.service
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
	DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$TARGET_USER")/bus" \
	systemctl --user daemon-reload
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
	DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$TARGET_USER")/bus" \
	systemctl --user restart t1-touchbar.service

printf 'Installed T1Bridge low-wakeup binaries built from %s.\n' "$COMMIT"

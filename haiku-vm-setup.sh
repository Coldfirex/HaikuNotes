#!/bin/sh
# Post-install setup for a default Haiku VM.
# Run once from Terminal after the installer finishes and the network is up:
#   sh haiku-vm-setup.sh
#
# Login from another machine is:  ssh user@<vm-ip>
# The account name is "user", not "root". sshd still treats UID 0 as root,
# so PermitRootLogin has to be yes or password login is refused.

set -u

USER_NAME="user"
SSHD_CONFIG="/boot/system/settings/ssh/sshd_config"
MARKER="/boot/home/config/settings/haiku-vm-setup.done"

say() {
	printf '\n==> %s\n' "$1"
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

set_sshd_opt() {
	key="$1"
	val="$2"
	if grep -q "^${key}[[:space:]]" "$SSHD_CONFIG"; then
		sed -i "s/^${key}[[:space:]].*/${key} ${val}/" "$SSHD_CONFIG"
	elif grep -q "^#[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
		sed -i "s/^#[[:space:]]*${key}[[:space:]].*/${key} ${val}/" "$SSHD_CONFIG"
	else
		printf '%s %s\n' "$key" "$val" >> "$SSHD_CONFIG"
	fi
}

need_cmd pkgman
need_cmd sed
need_cmd grep

if [ "$(id -un)" != "$USER_NAME" ]; then
	printf 'warning: expected to run as %s, running as %s\n' \
		"$USER_NAME" "$(id -un)"
fi

if ! ping -c 1 -W 5 haiku-os.org >/dev/null 2>&1; then
	printf 'warning: haiku-os.org did not answer. pkgman may fail if the VM has no network.\n'
fi

say "Set the password for ${USER_NAME}"
printf 'SSH will use this password. Type it twice at the prompt.\n'
passwd || die "passwd failed"

say "Make sure the sshd account exists"
if ! grep -q '^sshd:' /etc/passwd 2>/dev/null; then
	useradd sshd || printf 'warning: useradd sshd failed; continuing\n'
fi

say "Host keys"
if command -v ssh-keygen >/dev/null 2>&1; then
	ssh-keygen -A || printf 'warning: ssh-keygen -A failed; continuing\n'
fi

say "Enable password login in sshd_config"
if [ ! -f "$SSHD_CONFIG" ]; then
	die "missing ${SSHD_CONFIG} (install openssh first, then re-run)"
fi
cp -f "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
set_sshd_opt PermitRootLogin yes
set_sshd_opt PasswordAuthentication yes
set_sshd_opt KbdInteractiveAuthentication yes
set_sshd_opt PubkeyAuthentication yes
set_sshd_opt UsePAM no

say "Restart sshd"
if kill sshd >/dev/null 2>&1; then
	sleep 1
fi
if [ -x /bin/sshd ]; then
	/bin/sshd || printf 'warning: /bin/sshd did not start; it should come up after reboot\n'
else
	printf 'warning: /bin/sshd not found yet; openssh install below should add it\n'
fi

say "Refresh package lists"
pkgman refresh || die "pkgman refresh failed"

say "Install software updates"
# -y skips the confirm prompt. A system update still needs the reboot at the end.
pkgman full-sync -y || die "pkgman full-sync failed"

say "Install development packages"
# jam, gcc, make, bison, flex, and the system headers ship in a normal
# nightly/release image. These cover building the Haiku tree on Haiku
# (https://www.haiku-os.org/guides/building/pre-reqs/) plus the usual extras.
DEV_PKGS="haiku_devel git openssh cmd:python3 cmd:xorriso devel:libzstd \
	cmd:gcc cmd:g++ cmd:jam cmd:make cmd:bison cmd:flex cmd:nasm \
	cmd:autoconf cmd:automake cmd:m4 cmd:gawk cmd:wget cmd:curl \
	cmd:pkg-config cmd:cmake cmd:gdb cmd:less cmd:vim cmd:ssh"

# Secondary-arch headers, only if this image is a hybrid.
if pkgman search -D devel:libzstd_x86 >/dev/null 2>&1; then
	if pkgman search devel:libzstd_x86 2>/dev/null | grep -q libzstd_x86; then
		DEV_PKGS="${DEV_PKGS} devel:libzstd_x86"
	fi
fi

# shellcheck disable=SC2086
pkgman install -y $DEV_PKGS || die "development package install failed"

say "Set timezone to America/Chicago (US Central)"
# QEMU's hardware clock is UTC. Tell Haiku that, or the offset is applied twice.
printf 'gmt\n' > /boot/home/config/settings/RTC_time_settings
cat > /tmp/set-tz.cpp << 'EOF'
#include <stdio.h>
#include <string.h>

#include <MutableLocaleRoster.h>
#include <TimeZone.h>
#include <syscalls.h>

int
main()
{
	const char* id = "America/Chicago";
	BTimeZone zone(id);

	status_t status = BPrivate::MutableLocaleRoster::Default()
		->SetDefaultTimeZone(zone);
	if (status != B_OK) {
		fprintf(stderr, "SetDefaultTimeZone failed: %s\n", strerror(status));
		return 1;
	}

	status = _kern_set_timezone(zone.OffsetFromGMT(), zone.ID().String(),
		zone.ID().Length());
	if (status != B_OK) {
		fprintf(stderr, "kernel set_timezone failed: %s\n", strerror(status));
		return 1;
	}

	status = _kern_set_real_time_clock_is_gmt(true);
	if (status != B_OK) {
		fprintf(stderr, "RTC-is-GMT failed: %s\n", strerror(status));
		return 1;
	}

	printf("timezone %s, offset %d seconds\n", zone.ID().String(),
		(int)zone.OffsetFromGMT());
	return 0;
}
EOF
if ! g++ -Wall -o /tmp/set-tz /tmp/set-tz.cpp -lbe; then
	die "could not build timezone helper"
fi
/tmp/set-tz || die "could not set timezone"
rm -f /tmp/set-tz /tmp/set-tz.cpp

if command -v Time >/dev/null 2>&1; then
	Time --update || printf 'warning: NTP update failed; continuing\n'
fi

say "Install Firefox"
if ! pkgman install -y firefox; then
	printf 'firefox package failed, trying firefox_esr\n'
	pkgman install -y firefox_esr || die "could not install firefox or firefox_esr"
fi

date > "$MARKER"

say "Done. Rebooting so package updates and sshd pick up the new settings."
printf 'After reboot: ssh %s@<vm-ip>\n' "$USER_NAME"
sleep 3
shutdown -r

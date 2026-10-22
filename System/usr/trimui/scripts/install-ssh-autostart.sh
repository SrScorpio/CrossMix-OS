#!/bin/sh
# Make dropbear start on every boot, through the mechanism this firmware actually
# honours.
#
# Measured on hardware: ex_init.sh is not run, °customization.sh is not run, and
# /etc/init.d/sshd belongs to OpenSSH (it points at /usr/sbin/sshd, which does not
# exist here) - so nothing started dropbear at boot even with NETWORK_SSH="Y" and
# the menu showing the service as enabled. /etc/rc.local is run by the init after
# everything else, and /etc is a writable overlay.
#
# Idempotent: safe to run from a hotfix, from the menu, or by hand.

RC="/etc/rc.local"

[ -f "$RC" ] || exit 0
grep -q "ssh_start.sh" "$RC" && exit 0

cp -f "$RC" "$RC.bak-se" 2>/dev/null

TMP="/tmp/rc.local.new"
LINE=$(grep -n "^exit 0" "$RC" 2>/dev/null | head -1 | cut -d: -f1)

if [ -n "$LINE" ]; then
	head -n $((LINE - 1)) "$RC" > "$TMP"
else
	cat "$RC" > "$TMP"
fi

cat >> "$TMP" <<'EOF'

# CrossMix-OS SE: dropbear on every boot (rc.local runs after init)
[ -x /mnt/SDCARD/System/usr/trimui/scripts/ssh_start.sh ] && /mnt/SDCARD/System/usr/trimui/scripts/ssh_start.sh >/dev/null 2>&1 &
EOF

if [ -n "$LINE" ]; then
	tail -n +"$LINE" "$RC" >> "$TMP"
fi

sh -n "$TMP" 2>/dev/null || {
	echo "install-ssh-autostart: refusing to install, result does not parse" >&2
	exit 1
}

cat "$TMP" > "$RC"
rm -f "$TMP"
exit 0

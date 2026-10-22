#!/bin/sh
# Make dropbear start on every boot, through the mechanism this firmware actually
# honours.
#
# Measured on hardware, in this order of discovery:
#   - ex_init.sh is never invoked.
#   - °customization.sh never runs the helper at boot.
#   - /etc/init.d/sshd exists with an S50sshd symlink, but it is the OpenSSH
#     script: it runs /usr/sbin/sshd, which does not exist in this image. That is
#     why the menu showed the service as enabled and nothing was listening.
#   - /etc/rc.local IS executed, from /etc/init.d/done (S95done), which calls
#     "sh /etc/rc.local" in its boot().
#
# And the subtle one: S95done can run before the card is mounted, so a helper
# living on /mnt/SDCARD is not executable yet and the whole thing exits quietly.
# The helper is therefore copied into /etc (writable overlay) and waits for the
# config itself. A beacon in /tmp records that init got here, even when SSH does
# not come up - without it, a silent failure is indistinguishable from rc.local
# never running.
#
# Idempotent: safe to run from a hotfix, from the menu, or by hand.

RC="/etc/rc.local"
HELPER="/mnt/SDCARD/System/usr/trimui/scripts/ssh_start.sh"

[ -f "$RC" ] || exit 0

# Keep a copy outside the card: at boot the card may not be mounted yet.
if [ -x "$HELPER" ]; then
	cp -f "$HELPER" /etc/ssh_start.sh 2>/dev/null
	chmod +x /etc/ssh_start.sh 2>/dev/null
fi

grep -q "setsid /etc/ssh_start.sh" "$RC" && exit 0

cp -f "$RC" "$RC.bak-se" 2>/dev/null

# Drop any previous block so this is re-runnable after an upgrade.
grep -v "ssh_start.sh" "$RC" | grep -v "CrossMix-OS SE: reached from" \
	| grep -v "Beacon first: proves init" > /tmp/rc.local.clean

TMP="/tmp/rc.local.new"
LINE=$(grep -n "^exit 0" /tmp/rc.local.clean 2>/dev/null | head -1 | cut -d: -f1)

if [ -n "$LINE" ]; then
	head -n $((LINE - 1)) /tmp/rc.local.clean > "$TMP"
else
	cat /tmp/rc.local.clean > "$TMP"
fi

cat >> "$TMP" <<'EOF'

# CrossMix-OS SE: reached from /etc/init.d/done (S95done) -> sh /etc/rc.local
# Beacon first: proves init got here even when SSH does not come up.
echo "rc.local ran $(date); sdcard=$(mount | grep -c SDCARD)" >> /tmp/rc-beacon.log
/usr/bin/setsid /etc/ssh_start.sh >> /tmp/rc-beacon.log 2>&1 &
EOF

if [ -n "$LINE" ]; then
	tail -n +"$LINE" /tmp/rc.local.clean >> "$TMP"
fi

sh -n "$TMP" 2>/dev/null || {
	echo "install-ssh-autostart: refusing to install, result does not parse" >&2
	rm -f "$TMP" /tmp/rc.local.clean
	exit 1
}

cat "$TMP" > "$RC"
rm -f "$TMP" /tmp/rc.local.clean
exit 0

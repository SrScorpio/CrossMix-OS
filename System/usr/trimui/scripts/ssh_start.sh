#!/bin/sh
# Bring dropbear up exactly once per boot, key-only.
#
# Called from ex_init.sh and from °customization.sh: the firmware does not
# reliably run the first, and the second is the script that paints the splash.
# Being idempotent makes double invocation harmless.
#
# Detection uses pidof, not ps. busybox ps on this firmware only lists processes
# belonging to the current session, so a guard built on it never sees the running
# server: it starts another dropbear on every call, and the one that ends up
# owning port 22 is the firmware's, which accepts passwords.

[ -f /mnt/SDCARD/System/etc/ex_config ] && . /mnt/SDCARD/System/etc/ex_config

# /etc/rc.local runs from S95done, which can get there before the card is
# mounted: the helper is then unreadable and exits doing nothing, which is
# exactly why the service looked enabled and never came up. The script lives in
# /etc for that reason, and waits here for the config to appear.
n=0
while [ ! -r /mnt/SDCARD/System/etc/ex_config ] && [ "$n" -lt 60 ]; do
	sleep 0.5
	n=$((n + 1))
done
[ -f /mnt/SDCARD/System/etc/ex_config ] && . /mnt/SDCARD/System/etc/ex_config

[ "$NETWORK_SSH" = "Y" ] || exit 0

LOG="/mnt/SDCARD/System/updates/ssh-diag.log"

# Serialise the callers. Two of them can reach this point within the same second
# (boot script and the menu's toggle), both see no server, and both start one -
# leaving a dropbear alive that never owns the socket.
LOCKDIR="/tmp/ssh_start.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
	# A previous run died before releasing it. Only trust the lock while the
	# port is actually free; otherwise this is a live run and we stay out.
	sleep 4
	if netstat -ln 2>/dev/null | grep -q ':22 '; then
		exit 0
	fi
	rm -rf "$LOCKDIR"
	mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

# If a server is already up, keep it only when it runs key-only (-s).
PIDS=$(pidof dropbear 2>/dev/null)
KEYONLY=0
if [ -n "$PIDS" ]; then
	for p in $PIDS; do
		CL=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
		case " $CL " in
			*" -s "*) KEYONLY=1 ;;
		esac
	done
	[ "$KEYONLY" = "1" ] && exit 0

	# Started by the firmware, accepting passwords - and the image ships a root
	# password anyone can read in a public repository. Replace it.
	pkill dropbear 2>/dev/null
	sleep 1
fi

export PATH="/mnt/SDCARD/System/bin:$PATH"
export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"

KEYDIR="/etc/dropbear"
[ -w /etc ] || KEYDIR="/tmp/dropbear"
mkdir -p "$KEYDIR" /root/.ssh

[ -f "$KEYDIR/dropbear_ed25519_host_key" ] || \
	dropbearkey -t ed25519 -f "$KEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1

OPTS=""
AUTH="/mnt/SDCARD/System/etc/dropbear/authorized_keys"
if [ -f "$AUTH" ]; then
	cp "$AUTH" /root/.ssh/authorized_keys 2>/dev/null
	chmod 700 /root/.ssh 2>/dev/null
	chmod 600 /root/.ssh/authorized_keys 2>/dev/null
	OPTS="-s"
fi

# Resolve the binary explicitly: dropbear ships on the card, not in /usr/sbin, so
# a bare "dropbear" depends on the caller's PATH. From rc.local that failed and
# the error went to the log while nothing listened.
DROPBEAR="/mnt/SDCARD/System/bin/dropbear"
[ -x "$DROPBEAR" ] || DROPBEAR=$(command -v dropbear 2>/dev/null)
if [ ! -x "$DROPBEAR" ]; then
	echo "ssh_start: dropbear binary not found" >> "$LOG"
	exit 1
fi

# setsid is not cosmetic: a background child of a script started by init dies with
# its parent, which is why the server appeared in the log and was gone by the time
# the boot finished.
setsid "$DROPBEAR" -r "$KEYDIR/dropbear_ed25519_host_key" $OPTS -p 22 >>"$LOG" 2>&1 &
sleep 3

{
	echo "--- started $(date) ---"
	echo "pids_before=${PIDS:-none} keyonly_before=$KEYONLY"
	echo "pids_after=$(pidof dropbear 2>/dev/null)"
	netstat -ln 2>/dev/null | grep ':22' || echo "nothing listening on :22"
	echo "keydir=$KEYDIR opts=${OPTS:-password-allowed}"
} >> "$LOG"

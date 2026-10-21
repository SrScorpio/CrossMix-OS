#!/bin/sh
# Bring dropbear up exactly once per boot.
#
# Called from two places on purpose. ex_init.sh is what the upstream tree uses,
# but nothing in the repository invokes it - the stock firmware does, and on a
# real console it did not run after a reboot: the service only appeared after
# the menu's enable script was pressed. °customization.sh, on the other hand, is
# guaranteed to run on every boot because it paints the splash.
#
# Being a no-op when a server is already listening makes double invocation
# harmless.

[ -f /mnt/SDCARD/System/etc/ex_config ] && . /mnt/SDCARD/System/etc/ex_config
[ "$NETWORK_SSH" = "Y" ] || exit 0

# The menu's script and ex_init can both fire; the loser of the race for port 22
# stays alive with no socket.
ps | grep -v grep | grep -q "[d]ropbear" && exit 0

export PATH="/mnt/SDCARD/System/bin:$PATH"
export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"

KEYDIR="/etc/dropbear"
[ -w /etc ] || KEYDIR="/tmp/dropbear"
mkdir -p "$KEYDIR" /root/.ssh

[ -f "$KEYDIR/dropbear_ed25519_host_key" ] || \
    dropbearkey -t ed25519 -f "$KEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1

# The image sets a root password everyone can read in °customization.sh, and
# dropbear accepts passwords by default. With a key installed, close that door:
# -s means keys only.
OPTS=""
AUTH="/mnt/SDCARD/System/etc/dropbear/authorized_keys"
if [ -f "$AUTH" ]; then
    cp "$AUTH" /root/.ssh/authorized_keys 2>/dev/null
    chmod 700 /root/.ssh 2>/dev/null
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    OPTS="-s"
fi

LOG="/mnt/SDCARD/System/updates/ssh-diag.log"
nice -2 dropbear -r "$KEYDIR/dropbear_ed25519_host_key" $OPTS -p 22 >>"$LOG" 2>&1 &
sleep 3

{
    echo "--- started $(date) ---"
    ps | grep -v grep | grep "[d]ropbear" || echo "dropbear: not running"
    netstat -ln 2>/dev/null | grep ':22' || echo "nothing listening on :22"
    echo "keydir=$KEYDIR opts=${OPTS:-password-allowed}"
} >> "$LOG"

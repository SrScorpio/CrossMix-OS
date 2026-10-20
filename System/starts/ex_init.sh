#!/bin/sh

source /mnt/SDCARD/System/etc/ex_config

mkdir -p ~/.config/

if [[ "$NETWORK_FIX" == "Y" ]]; then

    if [ ! -f "$EX_CONFIG_PATH/mac_addr.conf" ]; then
        # Generate random bytes
        bytes=$(dd if=/dev/urandom bs=6 count=1 2>/dev/null | xxd -p)

        # Format bytes into MAC address format
        MAC_ADDR=$(echo "00:00:${bytes:4:2}:${bytes:6:2}:${bytes:8:2}:${bytes:10:2}")

        # Output the random MAC address
        echo "MAC_ADDR=$MAC_ADDR" >> "$EX_CONFIG_PATH/mac_addr.conf"
    else
        source "$EX_CONFIG_PATH/mac_addr.conf"
    fi

    ## MAC ADDRESS STUFF FROM: https://github.com/tGecko/TrimUI-Smart-Pro-resources?tab=readme-ov-file#startup-script

    ## Force a decent macaddr
    ifconfig wlan0 down
    ifconfig wlan0 hw ether "$MAC_ADDR"
    ifconfig wlan0 up
fi

/mnt/SDCARD/System/bin/ex_update.sh

if [[ "$NETWORK_SSH" == "Y" ]]; then
    # dropbear needs the card's libraries. ex_init never exported them (the
    # menu's enable script does), so the server died before binding. Host keys
    # fall back to /tmp when /etc is read-only, and authorized_keys is fetched
    # from the card. The log is the only way to see the failure without a shell.
    export PATH="/mnt/SDCARD/System/bin:$PATH"
    export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"

    SSHLOG="/mnt/SDCARD/System/updates/ssh-diag.log"

    KEYDIR="/etc/dropbear"
    [ -w /etc ] || KEYDIR="/tmp/dropbear"
    mkdir -p "$KEYDIR" /root/.ssh

    if [ ! -f "$KEYDIR/dropbear_ed25519_host_key" ]; then
        dropbearkey -t ed25519 -f "$KEYDIR/dropbear_ed25519_host_key" >/dev/null 2>>"$SSHLOG"
    fi

    if [ -f /mnt/SDCARD/System/etc/dropbear/authorized_keys ]; then
        cp /mnt/SDCARD/System/etc/dropbear/authorized_keys /root/.ssh/authorized_keys 2>>"$SSHLOG"
        chmod 700 /root/.ssh 2>/dev/null
        chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    fi

    nice -2 dropbear -r "$KEYDIR/dropbear_ed25519_host_key" -p 22 2>>"$SSHLOG" &
    sleep 3
    {
        echo "--- started $(date) ---"
        ps | grep -v grep | grep dropbear || echo "dropbear: not running"
        netstat -ln 2>/dev/null | grep ':22' || echo "nothing listening on :22"
        echo "keydir=$KEYDIR"
    } >> "$SSHLOG"
fi

if [[ "$NETWORK_SFTPGO" == "Y" ]]; then
    mkdir -p /opt/sftpgo

    nice -2 /mnt/SDCARD/System/sftpgo/sftpgo serve -c /mnt/SDCARD/System/sftpgo/ > /dev/null &
fi

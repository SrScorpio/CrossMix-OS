#!/bin/sh
# Telnet used to start here as root with no authentication and no encryption:
# anyone on the LAN could open port 23 and own the console. It is retired.
#
# SSH is the supported remote shell and runs with key authentication only
# (see ssh_start.sh). If telnet is ever needed for debugging, it must be a
# deliberate, documented change that requires a login - not a menu toggle.

/mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh \
    -m "Telnet disabled: it ran as root without authentication. Use SSH." -c red -t 4

/mnt/SDCARD/System/usr/trimui/scripts/mainui_state_update.sh "TELNET" "disabled"
exit 1

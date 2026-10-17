#!/bin/sh
# Legacy version-key stub ((empty)): delegates to the canonical CE hotfix.
# Migrated consoles may still hold an upstream key in crossmix-version.txt;
# without this file Check Update would report "No hotfix available".
source /mnt/SDCARD/System/usr/trimui/scripts/update_common.sh
url="https://raw.githubusercontent.com/SrScorpio/CrossMix-OS-SE/main/_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.sh"
echo "Legacy key (empty) detected -> applying canonical CE hotfix"
curl -k -s -L "$url" | sh

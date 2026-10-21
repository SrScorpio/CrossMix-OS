#!/bin/sh
# Tune the I/O scheduler for a device whose storage IS the workload.
#
# The TSP kernel boots with CFQ. Everything expensive on this console is random
# write to an SD card: scanning a library of thousands of ROMs, writing save
# states and battery saves, scraping, unpacking PortMaster ports. CFQ spends its
# time reordering for fairness between processes; on a single-user handheld that
# is pure latency. noop (or deadline) hands the request straight to the card.
#
# Linux 4.9 has no 'none' - only noop/deadline/cfq - so writing 'none' would
# fail silently. Every write here is guarded and the script always exits 0: it
# runs from the boot path, where a non-zero exit is noise, not a signal.

for queue in /sys/block/mmcblk[0-9]*/queue /sys/block/sd[a-z]/queue; do
	[ -d "$queue" ] || continue

	if grep -qw noop "$queue/scheduler" 2>/dev/null; then
		echo noop > "$queue/scheduler" 2>/dev/null
	elif grep -qw deadline "$queue/scheduler" 2>/dev/null; then
		echo deadline > "$queue/scheduler" 2>/dev/null
	fi

	# 128 KB default is tuned for spinning disks. 1 MB favours the sequential
	# reads of ROM loading and the big writes of installs.
	echo 1024 > "$queue/read_ahead_kb" 2>/dev/null
done

exit 0

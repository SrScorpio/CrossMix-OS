#!/bin/sh
# GH#29 - parent/child error propagation for the OTA chain.
#
# Chain:  ota_update.sh -> ota_bootstrap.sh -> update_ota_release.sh
#                        -> CrossMix-OS_v<local>.sh (hotfix)
#
# Exit status: see the OTA exit code contract at the top of update_common.sh.
# A child that fails is logged, reported to the user and propagated; nothing
# here may treat "the child ran" as "the update worked".
. /mnt/SDCARD/System/usr/trimui/scripts/update_common.sh

# Mirror of the contract: this script sources update_common.sh BEFORE the
# bootstrap refreshes it, so the codes must survive an older SD copy.
OTA_EXIT_OK=${OTA_EXIT_OK:-0}
OTA_EXIT_ERROR=${OTA_EXIT_ERROR:-1}
OTA_EXIT_DOWNLOAD=${OTA_EXIT_DOWNLOAD:-2}
OTA_EXIT_VERIFY=${OTA_EXIT_VERIFY:-3}
OTA_EXIT_APPLY=${OTA_EXIT_APPLY:-4}
OTA_EXIT_PRECOND=${OTA_EXIT_PRECOND:-5}
OTA_EXIT_NO_RELEASE=${OTA_EXIT_NO_RELEASE:-10}
OTA_EXIT_CANCEL=${OTA_EXIT_CANCEL:-11}

OTA_SCRIPTS_DIR=/mnt/SDCARD/System/usr/trimui/scripts
OTA_BOOTSTRAP_URL="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/_assets/scripts/ota_bootstrap.sh"

# Same helpers as update_common.sh, defined here only when the SD copy predates
# GH#29 (the bootstrap may not have replaced it yet). Failure reporting must not
# depend on a helper that may be missing: this is the path taken when the
# bootstrap itself fails.
if ! command -v ota_run_logged >/dev/null 2>&1; then
	ota_run_logged() {
		_orl_log="$1"
		shift
		[ $# -gt 0 ] || return 1
		_orl_rc="/tmp/ota_rc.$$"
		rm -f "$_orl_rc"
		{ "$@" 2>&1; echo $? >"$_orl_rc"; } | tee -a "$_orl_log"
		_orl_status=$(cat "$_orl_rc" 2>/dev/null)
		rm -f "$_orl_rc"
		[ -n "$_orl_status" ] || return 1
		return "$_orl_status"
	}
fi
if ! command -v ota_rc_name >/dev/null 2>&1; then
	ota_rc_name() {
		case "$1" in
		0) echo "ok" ;;
		2) echo "download failed" ;;
		3) echo "verification failed" ;;
		4) echo "apply failed" ;;
		5) echo "precondition failed" ;;
		10) echo "no release" ;;
		11) echo "user cancel" ;;
		*) echo "error" ;;
		esac
	}
fi

# Report a failure the user can act on: console (the SimpleTerminal log) plus
# an infoscreen when the terminal is gone. Never a success wording.
report_failure() {
	_rf_rc="$1"
	_rf_msg="$2"
	_rf_log="${3:-$updatedir/ota_release.log}"
	echo -e "\n${RED}${_rf_msg}${NC}"
	echo -e "${RED}Reason: $(ota_rc_name "$_rf_rc") (exit code $_rf_rc).${NC}"
	echo -e "Details: $_rf_log\n"
	if [ -x "$OTA_SCRIPTS_DIR/infoscreen.sh" ] && [ ! -f /tmp/infoscreen_disabled ]; then
		"$OTA_SCRIPTS_DIR/infoscreen.sh" -m "$_rf_msg (code $_rf_rc)" -t 12 -c orange
	fi
}

run_bootstrap() {
	_bs=/tmp/ota_bootstrap.sh
	rm -f "$_bs"

	# Fetch first. `curl ... | sh` returns the exit status of the shell, so a
	# failed download used to look like a successful bootstrap.
	if ! curl -k -s -L -o "$_bs" "$OTA_BOOTSTRAP_URL"; then
		echo -e "${RED}Could not download the OTA bootstrap.${NC}"
		return "$OTA_EXIT_DOWNLOAD"
	fi
	if [ ! -s "$_bs" ]; then
		echo -e "${RED}OTA bootstrap download is empty.${NC}"
		return "$OTA_EXIT_DOWNLOAD"
	fi

	sh "$_bs"
	return $?
}

run_hotfix() {
	_hf_ver="$Local_CrossMixVersion"
	[ -n "$_hf_ver" ] || _hf_ver=$(cat "/mnt/SDCARD/System/usr/trimui/crossmix-version.txt" 2>/dev/null)
	_hf_url="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/_assets/hotfixes/CrossMix-OS_v${_hf_ver}.sh"

	if ! /mnt/SDCARD/System/bin/wget -q --spider "$_hf_url"; then
		clear
		echo -ne "${PURPLE}Retrieving hotfix information.. ${NC}"
		echo -ne "${GREEN}DONE${NC}\n\n\n"
		echo -e "No hotfix available for CrossMix v$_hf_ver.\n"
		echo -ne "${YELLOW}"
		if [ -t 0 ]; then read -n 1 -s -r -p "Press A to exit"; fi
		return "$OTA_EXIT_NO_RELEASE"
	fi

	echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n" >>"$updatedir/ota_hotfix.log"
	echo -e "${timestamp}\n" >>"$updatedir/ota_hotfix.log"

	# `curl ... | sh | tee` hid both the download and the hotfix status.
	_hf_file=/tmp/ota_hotfix.sh
	rm -f "$_hf_file"
	if ! curl -k -s -L -o "$_hf_file" "$_hf_url"; then
		report_failure "$OTA_EXIT_DOWNLOAD" "Could not download the CrossMix v$_hf_ver hotfix." "$updatedir/ota_hotfix.log"
		return "$OTA_EXIT_DOWNLOAD"
	fi
	if [ ! -s "$_hf_file" ]; then
		report_failure "$OTA_EXIT_DOWNLOAD" "The CrossMix v$_hf_ver hotfix download is empty." "$updatedir/ota_hotfix.log"
		return "$OTA_EXIT_DOWNLOAD"
	fi

	ota_run_logged "$updatedir/ota_hotfix.log" sh "$_hf_file"
	_hf_rc=$?
	if [ "$_hf_rc" -ne 0 ]; then
		report_failure "$_hf_rc" "Hotfix for CrossMix v$_hf_ver was not applied; the installed version is unchanged." "$updatedir/ota_hotfix.log"
		return "$_hf_rc"
	fi

	echo -e "\n${GREEN}Hotfix applied.${NC}\n"
	return "$OTA_EXIT_OK"
}

main() {
	check_connection
	sleep 2
	clear

	run_bootstrap
	_bs_rc=$?
	if [ "$_bs_rc" -ne 0 ]; then
		report_failure "$_bs_rc" "Update preparation failed: the OTA bootstrap did not complete."
		exit "$_bs_rc"
	fi

	# The bootstrap may have replaced update_common.sh and the OTA scripts:
	# pick the refreshed helpers up before running the next child.
	. "$OTA_SCRIPTS_DIR/update_common.sh"
	OTA_EXIT_OK=${OTA_EXIT_OK:-0}
	OTA_EXIT_DOWNLOAD=${OTA_EXIT_DOWNLOAD:-2}
	OTA_EXIT_NO_RELEASE=${OTA_EXIT_NO_RELEASE:-10}
	OTA_EXIT_CANCEL=${OTA_EXIT_CANCEL:-11}

	clear

	echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n" >>"$updatedir/ota_release.log"
	echo -e "${timestamp}\n" >>"$updatedir/ota_release.log"

	ota_run_logged "$updatedir/ota_release.log" sh "$OTA_SCRIPTS_DIR/update_ota_release.sh"
	_rel_rc=$?
	echo "[ota_update] update_ota_release.sh exited $_rel_rc ($(ota_rc_name "$_rel_rc"))" >>"$updatedir/ota_release.log"

	case "$_rel_rc" in
	"$OTA_EXIT_OK")
		echo -e "\n${GREEN}Update flow finished.${NC}\n"
		sleep 2
		killall -2 SimpleTerminal
		exit "$OTA_EXIT_OK"
		;;
	"$OTA_EXIT_NO_RELEASE" | "$OTA_EXIT_CANCEL")
		# Nothing to apply: the hotfix for the installed version is the only
		# thing left to check.
		run_hotfix
		_hf_rc=$?
		sleep 2
		killall -2 SimpleTerminal
		exit "$_hf_rc"
		;;
	*)
		# Keep the terminal (and its log) alive so the reason stays readable.
		report_failure "$_rel_rc" "CrossMix update did not complete."
		exit "$_rel_rc"
		;;
	esac
}

main

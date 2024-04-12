#!/bin/sh

# Installation script for cake-autorate
#
# See https://github.com/lynxthecat/cake-autorate for more details

# This needs to be encapsulated into a function so that we are sure that
# sh reads all the contents of the shell file before we potentially erase it.
#
# Otherwise the read operation might fail and it won't be able to proceed with
# the script as expected.
main() {
	# Set correctness options
	set -eu

	# Setup dependencies to check for
	DEPENDENCIES="jsonfilter uclient-fetch tar grep"

	# Set up remote locations and branch
	REPOSITORY=${CAKE_AUTORATE_REPO:-${1-lynxthecat/cake-autorate}}
	BRANCH=${CAKE_AUTORATE_BRANCH:-${2-master}}
	SRC_DIR=https://github.com/${REPOSITORY}/archive/
	API_URL=https://api.github.com/repos/${REPOSITORY}/commits/${BRANCH}
	DOC_URL=https://github.com/${REPOSITORY}/tree/${BRANCH}#installation-on-openwrt

	# Set SCRIPT_PREFIX and CONFIG_PREFIX
	SCRIPT_PREFIX=${CAKE_AUTORATE_SCRIPT_PREFIX:-}
	CONFIG_PREFIX=${CAKE_AUTORATE_CONFIG_PREFIX:-}

	# Store what OS we are running on
	MY_OS=unknown

	# Check if OS is OpenWRT or derivative
	unset ID_LIKE
	. /etc/os-release 2>/dev/null || :
	for x in ${ID_LIKE:-}
	do
		if [ "${x}" = "openwrt" ]
		then
			MY_OS=openwrt
			[ -z "${SCRIPT_PREFIX}" ] && SCRIPT_PREFIX=/root/cake-autorate
			[ -z "${CONFIG_PREFIX}" ] && CONFIG_PREFIX=/root/cake-autorate
			break
		fi
	done

	# Check if OS is ASUSWRT-Merlin
	if [ "$(uname -o)" = "ASUSWRT-Merlin" ]
	then
		MY_OS=asuswrt
		[ -z "${SCRIPT_PREFIX}" ] && SCRIPT_PREFIX=/jffs/scripts/cake-autorate
		[ -z "${CONFIG_PREFIX}" ] && CONFIG_PREFIX=/jffs/configs/cake-autorate
	fi

	# If we are not running on OpenWRT or ASUSWRT-Merlin, exit
	if [ "${MY_OS}" = "unknown" ]
	then
		printf "This script requires OpenWrt or ASUSWRT-Merlin\n" >&2
		return 1
	fi

	# Check if an instance of cake-autorate is already running and exit if so
	if [ -d /var/run/cake-autorate ]
	then
		printf "At least one instance of cake-autorate appears to be running - exiting\n" >&2
		printf "If you want to install a new version, first stop any running instance of cake-autorate\n" >&2
		printf "If you are sure that no instance of cake-autorate is running, delete the /var/run/cake-autorate directory\n" >&2
		exit 1
	fi

	# Check for required setup.sh script dependencies
	exit_now=0
	for dep in ${DEPENDENCIES}
	do
		if ! type "${dep}" >/dev/null 2>&1; then
			printf >&2 "%s is required, please install it and rerun the script!\n" "${dep}"
			exit_now=1
		fi
	done
	[ "${exit_now}" -ge 1 ] && exit "${exit_now}"

	# Retrieve required packages if not present
	# shellcheck disable=SC2312
	if [ "$(opkg list-installed | grep -Ec '^(bash|fping) ')" -ne 2 ]
	then
		printf "Running opkg update to update package lists:\n"
		opkg update
		printf "Installing bash and fping packages:\n"
		opkg install bash fping
	fi

	# Create the cake-autorate directory if it does not exist
	mkdir -p "${SCRIPT_PREFIX}" "${CONFIG_PREFIX}"

	# Get the latest commit to download
	commit=$(uclient-fetch -qO- "${API_URL}" | jsonfilter -e @.sha)
	if [ -z "${commit:-}" ];
	then
		printf >&2 "Invalid operation occurred, commit variable should not be empty"
		exit 1
	fi

	printf "Detected Operating System: %s\n" "${MY_OS}"
	printf "Installation directories for detected Operating System:\n"
	printf "  - Script prefix: %s\n" "${SCRIPT_PREFIX}"
	printf "  - Config prefix: %s\n" "${CONFIG_PREFIX}"

	printf "Continue with installation? [Y/n] "

	read -r continue_installation
	if [ "${continue_installation}" = "N" ] || [ "${continue_installation}" = "n" ]
	then
		exit
	fi

	printf "Installing cake-autorate using %s (script) and %s (config) directories...\n" "${SCRIPT_PREFIX}" "${CONFIG_PREFIX}"

	# Download the files of the latest version of cake-autorate to a temporary directory, so we can move them to the cake-autorate directory
	tmp=$(mktemp -d)
	trap 'rm -rf "${tmp}"' EXIT INT TERM
	uclient-fetch -qO- "${SRC_DIR}/${commit}.tar.gz" | tar -xozf - -C "${tmp}"
	mv "${tmp}/cake-autorate-"*/* "${tmp}"

	# Migrate old configuration (and new file) files if present
	cd "${CONFIG_PREFIX}"
	for file in cake-autorate_config.*.sh*
	do
		[ -e "${file}" ] || continue   # handle case where there are no old config files
		new_fname="$(printf '%s\n' "${file}" | cut -c15-)"
		mv "${file}" "${new_fname}"
	done

	# Check if a configuration file exists, and ask whether to keep it
	cd "${CONFIG_PREFIX}"
	editmsg="\nNow edit the config.primary.sh file as described in:\n   ${DOC_URL}"
	if [ -f config.primary.sh ]
	then
		printf "Previous configuration present - keep it? [Y/n] "
		read -r keep_previous_configuration
		if [ "${keep_previous_configuration}" = "N" ] || [ "${keep_previous_configuration}" = "n" ]; then
			mv "${tmp}/config.primary.sh" config.primary.sh
			rm -f config.primary.sh.new   # delete config.primary.sh.new if exists
		else
			editmsg="Using prior configuration"
			mv "${tmp}/config.primary.sh" config.primary.sh.new
		fi
	else
		mv "${tmp}/config.primary.sh" config.primary.sh
	fi

	# remove old program files from cake-autorate directory
	cd "${SCRIPT_PREFIX}"
	old_fnames="cake-autorate.sh cake-autorate_defaults.sh cake-autorate_launcher.sh cake-autorate_lib.sh cake-autorate_setup.sh"
	for file in ${old_fnames}
	do
		rm -f "${file}"
	done

	# move the program files to the cake-autorate directory
	# scripts that need to be executable are already marked as such in the tarball
	cd "${SCRIPT_PREFIX}"
	files="cake-autorate.sh defaults.sh lib.sh setup.sh uninstall.sh"
	for file in ${files}
	do
		mv "${tmp}/${file}" "${file}"
	done

	# Generate a launcher.sh file from the launcher.sh.template file
	sed -e "s|%%SCRIPT_PREFIX%%|${SCRIPT_PREFIX}|g" -e "s|%%CONFIG_PREFIX%%|${CONFIG_PREFIX}|g" \
		"${tmp}/launcher.sh.template" > "${SCRIPT_PREFIX}/launcher.sh"

	# Also generate the service file from cake-autorate.template but DO NOT ACTIVATE IT
	sed "s|%%SCRIPT_PREFIX%%|${SCRIPT_PREFIX}|g" "${tmp}/cake-autorate.template" > /etc/init.d/cake-autorate
	chmod +x /etc/init.d/cake-autorate

	# Get version and generate a file containing version information
	cd "${SCRIPT_PREFIX}"
	version=$(grep -m 1 ^cake_autorate_version= "${SCRIPT_PREFIX}/cake-autorate.sh" | cut -d= -f2 | cut -d'"' -f2)
	cat > version.txt <<-EOF
		version=${version}
		commit=${commit}
	EOF

	# Tell how to handle the config file - use old, or edit the new one
	# shellcheck disable=SC2059
	printf "${editmsg}\n"

	printf '\n%s\n\n' "${version} successfully installed, but not yet running"
	printf '%s\n' "Start the software manually with:"
	printf '%s\n' "   cd ${SCRIPT_PREFIX}; ./cake-autorate.sh"
	printf '%s\n' "Run as a service with:"
	printf '%s\n\n' "   service cake-autorate enable; service cake-autorate start"
}

# Now that we are sure all code is loaded, we could execute the function
main "${@}"

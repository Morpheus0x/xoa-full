#!/bin/bash
# shellcheck disable=SC2155,SC2207,SC2015

#########################################################################
# Title: XenOrchestraInstallerUpdater                                   #
# Author: Roni Väyrynen                                                 #
# Repository: https://github.com/ronivay/XenOrchestraInstallerUpdater   #
#########################################################################

SAMPLE_CONFIG_FILE="$(dirname "$0")/sample.xo-install.cfg"
CONFIG_FILE="$(dirname "$0")/xo-install.cfg"

# Deploy default configuration file if the user doesn't have their own yet.
if [[ ! -s "$CONFIG_FILE" ]]; then
	cp "$SAMPLE_CONFIG_FILE" "$CONFIG_FILE"
fi

# See this file for all script configuration variables.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Set some default variables if sourcing config file fails for some reason
PORT=${PORT:-80}
INSTALLDIR=${INSTALLDIR:-"/opt/xo"}
BRANCH=${BRANCH:-"master"}
LOGPATH=${LOGPATH:-$(dirname "$(realpath "$0")")/logs}
AUTOUPDATE=${AUTOUPDATE:-"true"}
PRESERVE=${PRESERVE:-"3"}
XOUSER=${XOUSER:-"root"}
CONFIGPATH=$(getent passwd "$XOUSER" | cut -d: -f6)
PLUGINS="${PLUGINS:-"none"}"
ADDITIONAL_PLUGINS="${ADDITIONAL_PLUGINS:-"none"}"
REPOSITORY="${REPOSITORY:-"https://github.com/vatesfr/xen-orchestra"}"
OS_CHECK="${OS_CHECK:-"true"}"
ARCH_CHECK="${ARCH_CHECK:-"true"}"
PATH_TO_HTTPS_CERT="${PATH_TO_HTTPS_CERT:-""}"
PATH_TO_HTTPS_KEY="${PATH_TO_HTTPS_KEY:-""}"

# set variables not changeable in configfile
TIME=$(date +%Y%m%d%H%M)
LOGTIME=$(date "+%Y-%m-%d %H:%M:%S")
LOGFILE="${LOGPATH}/xo-install.log-$TIME"
NODEVERSION="14"
FORCE="false"
INTERACTIVE="false"

# Set path where new source is cloned/pulled
XO_SRC_DIR="$INSTALLDIR/xo-src/xen-orchestra"

# Set variables for stdout print
COLOR_N='\e[0m'
COLOR_GREEN='\e[1;32m'
COLOR_RED='\e[1;31m'
COLOR_BLUE='\e[1;34m'
COLOR_WHITE='\e[1;97m'
OK="[${COLOR_GREEN}ok${COLOR_N}]"
FAIL="[${COLOR_RED}fail${COLOR_N}]"
INFO="[${COLOR_BLUE}info${COLOR_N}]"
PROGRESS="[${COLOR_BLUE}..${COLOR_N}]"

# Protocol to use for webserver. If both of the X.509 certificate files exist,
# then assume that we want to enable HTTPS for the server.
if [[ -s "$PATH_TO_HTTPS_CERT" ]] && [[ -s "$PATH_TO_HTTPS_KEY" ]]; then
	HTTPS=true
else
	HTTPS=false
fi

# create logpath if doesn't exist
if [[ ! -d "$LOGPATH" ]]; then
	mkdir -p "$LOGPATH"
fi

function CheckUser {

	# Make sure the script is ran as root

	if [[ ! "$(id -u)" == "0" ]]; then
		printfail "This script needs to be ran as root"
		exit 1
	fi

}

function scriptInfo {

	SCRIPTVERSION=$(runcmd_stdout "cd '$(dirname "$0")' 2>/dev/null && git rev-parse --short HEAD 2>/dev/null")

	[ -z "$SCRIPTVERSION" ] && SCRIPTVERSION="undefined"
	echo "Running script version $SCRIPTVERSION with config:" >> "$LOGFILE"
	echo >> "$LOGFILE"
        # shellcheck disable=SC2005,SC2002
	[ -s "$CONFIG_FILE" ] && echo "$(cat "$CONFIG_FILE" | grep -Eo '^[A-Z_]+.*')" >> "$LOGFILE" || echo "No config file found" >> "$LOGFILE"
	echo >> "$LOGFILE"
}

function runcmd {

	echo "+ $1" >>"$LOGFILE"
	bash -c -o pipefail "$1" >>"$LOGFILE" 2>&1
}

function runcmd_stdout {

	echo "+ $1" >>"$LOGFILE"
	# shellcheck disable=SC2094
	bash -c -o pipefail "$1" 2>>"$LOGFILE" | tee -a "$LOGFILE"
}

function printprog {
	echo -ne "${PROGRESS} $*"
}

function printok {
        # shellcheck disable=SC1117
	echo -e "\r${OK} $*"
}

function printfail {
	echo -e "${FAIL} $*"
}

function printinfo {
	echo -e "${INFO} $*"
}

function ErrorHandling {

	set -eu

	echo
	printfail "Something went wrong, exiting. Check $LOGFILE for more details and use rollback feature if needed"

	if [[ -d "$INSTALLDIR/xo-builds/xen-orchestra-$TIME" ]]; then
		echo
		printfail "Removing $INSTALLDIR/xo-builds/xen-orchestra-$TIME because of failed installation."
		runcmd "rm -rf $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
	fi

	exit 1
}

function InstallDependenciesRPM {

	set -uo pipefail

	trap ErrorHandling ERR INT

	# Install necessary dependencies for XO build

	# install packages
	echo
	printprog "Installing build dependencies, redis server, python, git, nfs-utils, cifs-utils"
	runcmd "yum -y install gcc gcc-c++ make openssl-devel redis libpng-devel python3 git nfs-utils cifs-utils lvm2"
	printok "Installing build dependencies, redis server, python, git, nfs-utils, cifs-utils"

	# only run automated node install if executable not found
	if [[ -z $(runcmd_stdout "command -v node") ]]; then
		echo
		printprog "Installing node.js"
		runcmd "curl -s -L https://rpm.nodesource.com/setup_${NODEVERSION}.x | bash -"
		printok "Installing node.js"
	else
		UpdateNodeYarn
	fi

	# only install yarn repo and package if not found
	if [[ -z $(runcmd_stdout "command -v yarn") ]] ; then
		echo
		printprog "Installing yarn"
		runcmd "curl -s -o /etc/yum.repos.d/yarn.repo https://dl.yarnpkg.com/rpm/yarn.repo && yum -y install yarn"
		printok "Installing yarn"
	fi

	# only install epel-release if doesn't exist
	if [[ -z $(runcmd_stdout "rpm -q epel-release") ]] ; then
		echo
		printprog "Installing epel-repo"
		runcmd "yum -y install epel-release"
		printok "Installing epel-repo"
	fi

	# only install libvhdi-tools if vhdimount is not present
	if [[ -z $(runcmd_stdout "command -v vhdimount") ]] ; then
		echo
		printprog "Installing libvhdi-tools from forensics repository"
		runcmd "rpm -ivh https://forensics.cert.org/cert-forensics-tools-release-el8.rpm"
		runcmd "sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/cert-forensics-tools.repo"
		runcmd "yum --enablerepo=forensics install -y libvhdi-tools"
		printok "Installing libvhdi-tools from forensics repository"
	fi

	echo
	printprog "Enabling and starting redis service"
	runcmd "/bin/systemctl enable redis && /bin/systemctl start redis"
	printok "Enabling and starting redis service"

	echo
	printprog "Enabling and starting rpcbind service"
	runcmd "/bin/systemctl enable rpcbind && /bin/systemctl start rpcbind"
	printok "Enabling and starting rpcbind service"

}

function InstallDependenciesDeb {

	set -uo pipefail

	trap ErrorHandling ERR INT

	# Install necessary dependencies for XO build

	if [[ "$OSNAME" == "Ubuntu" ]]; then
		echo
		printprog "OS Ubuntu so making sure universe repository is enabled"
		runcmd "add-apt-repository -y universe"
		printok "OS Ubuntu so making sure universe repository is enabled"
	fi

	echo
	printprog "Running apt-get update"
	runcmd "apt-get update"
	printok "Running apt-get update"

	#determine which python package is needed. Ubuntu 20 requires python2-minimal, 16 and 18 are python-minimal
	if [[ "$OSNAME" == "Ubuntu" ]] && [[ "$OSVERSION" == "20" ]]; then
		PYTHON="python2-minimal"
	else
		PYTHON="python-minimal"
	fi

	# install packages
	echo
	printprog "Installing build dependencies, redis server, python, git, libvhdi-utils, lvm2, nfs-common, cifs-utils, curl"
	runcmd "apt-get install -y build-essential redis-server libpng-dev git libvhdi-utils $PYTHON lvm2 nfs-common cifs-utils curl"
	printok "Installing build dependencies, redis server, python, git, libvhdi-utils, lvm2, nfs-common, cifs-utils, curl"

	# Install apt-transport-https and ca-certificates because of yarn https repo url
	echo
	printprog "Installing apt-transport-https and ca-certificates packages to support https repos"
	runcmd "apt-get install -y apt-transport-https ca-certificates"
	printok "Installing apt-transport-https and ca-certificates packages to support https repos"

	if [[ "$OSNAME" == "Debian" ]] && [[ "$OSVERSION" == "10" ]]; then
		echo
		printprog "Debian 10, so installing gnupg also"
		runcmd "apt-get install gnupg -y"
		printok "Debian 10, so installing gnupg also"
	fi

	# install setcap for non-root port binding if missing
	if [[ -z $(runcmd_stdout "command -v setcap") ]]; then
		echo
		printprog "Installing setcap"
		runcmd "apt-get install -y libcap2-bin"
		printok "Installing setcap"
	fi


	# only run automated node install if executable not found
	if [[ -z $(runcmd_stdout "command -v node") ]] || [[ -z $(runcmd_stdout "command -v npm") ]]; then
		echo
		printprog "Installing node.js"
		runcmd "curl -sL https://deb.nodesource.com/setup_${NODEVERSION}.x | bash -"
		runcmd "apt-get install -y nodejs"
		printok "Installing node.js"
	else
		UpdateNodeYarn
	fi

	# only install yarn repo and package if not found
	if [[ -z $(runcmd_stdout "command -v yarn") ]]; then
		echo
		printprog "Installing yarn"
		runcmd "curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -"
		runcmd "echo \"deb https://dl.yarnpkg.com/debian/ stable main\" | tee /etc/apt/sources.list.d/yarn.list"
		runcmd "apt-get update"
		runcmd "apt-get install -y yarn"
		printok "Installing yarn"
	fi

	echo
	printprog "Enabling and starting redis service"
	runcmd "/bin/systemctl enable redis-server && /bin/systemctl start redis-server"
	printok "Enabling and starting redis service"

	echo
	printprog "Enabling and starting rpcbind service"
	runcmd "/bin/systemctl enable rpcbind && /bin/systemctl start rpcbind"
	printok "Enabling and starting rpcbind service"

}

function UpdateNodeYarn {

	if [[ "$AUTOUPDATE" != "true" ]]; then
		return 0
	fi

	echo
	printinfo "Checking current node.js version"
	NODEV=$(node -v 2>/dev/null| grep -Eo '[0-9.]+' | cut -d'.' -f1)

	if [ "$PKG_FORMAT" == "rpm" ]; then
		if [[ -n "$NODEV" ]] && [[ "$NODEV" -lt "${NODEVERSION}" ]]; then
			echo
			printprog "node.js version is $NODEV, upgrading to ${NODEVERSION}.x"
			runcmd "curl -sL https://rpm.nodesource.com/setup_${NODEVERSION}.x | bash -"
			runcmd "yum clean all"
			runcmd "yum install -y nodejs"
			printok "node.js version is $NODEV, upgrading to ${NODEVERSION}.x"
		else
			if [[ "$TASK" == "Update" ]]; then
				echo
				printprog "node.js version already on $NODEV, checking updates"
				runcmd "yum update -y nodejs yarn"
				printok "node.js version already on $NODEV, checking updates"
			elif [[ "$TASK" == "Installation" ]]; then
				echo
				printinfo "node.js version already on $NODEV"
			fi
		fi
	fi

	if [ "$PKG_FORMAT" == "deb" ]; then
		if [[ -n "$NODEV" ]] && [[ "$NODEV" -lt "${NODEVERSION}" ]]; then
			echo
			printprog "node.js version is $NODEV, upgrading to ${NODEVERSION}.x"
			runcmd "curl -sL https://deb.nodesource.com/setup_${NODEVERSION}.x | bash -"
			runcmd "apt-get install -y nodejs"
			printok	"node.js version is $NODEV, upgrading to ${NODEVERSION}.x"
		else
			if [[ "$TASK" == "Update" ]]; then
				echo
				printprog "node.js version already on $NODEV, checking updates"
				runcmd "apt-get install -y --only-upgrade nodejs yarn"
				printok "node.js version already on $NODEV, checking updates"
			elif [[ "$TASK" == "Installation" ]]; then
				echo
				printinfo "node.js version already on $NODEV"
			fi
		fi
	fi
}

function InstallAdditionalXOPlugins {

	set -uo pipefail

	trap ErrorHandling ERR INT

	if [[ -z "$ADDITIONAL_PLUGINS" ]] || [[ "$ADDITIONAL_PLUGINS" == "none" ]]; then
		echo
		printinfo "No 3rd party plugins to install"
		return 0
	fi

	echo
	printprog "Fetching 3rd party plugin(s) source code"

	local ADDITIONAL_PLUGINSARRAY=($(echo "$ADDITIONAL_PLUGINS" | tr ',' ' '))
	for x in "${ADDITIONAL_PLUGINSARRAY[@]}"; do
		local PLUGIN_NAME=$(runcmd_stdout "basename '$x' | rev | cut -c 5- | rev")
		local PLUGIN_SRC_DIR=$(runcmd_stdout "realpath -m '$XO_SRC_DIR/../$PLUGIN_NAME'")

		if [[ ! -d "$PLUGIN_SRC_DIR" ]]; then
			runcmd "mkdir -p \"$PLUGIN_SRC_DIR\""
			runcmd "git clone \"${x}\" \"$PLUGIN_SRC_DIR\""
		else
			runcmd "cd \"$PLUGIN_SRC_DIR\" && git pull"
			runcmd "cd $(dirname "$0")"
		fi

		runcmd "cp -r $PLUGIN_SRC_DIR $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/"
	done
	printok "Fetching 3rd party plugin(s) source code"
}

function InstallXOPlugins {

	set -uo pipefail

	trap ErrorHandling ERR INT

	if [[ -z "$PLUGINS" ]] || [[ "$PLUGINS" == "none" ]]; then
		echo
		printinfo "No plugins to install"
		return 0
	fi

	echo
	printprog "Installing plugins"

	if [[ "$PLUGINS" == "all" ]]; then
		# shellcheck disable=SC1117
		runcmd "find \"$INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/\" -maxdepth 1 -mindepth 1 -not -name \"xo-server\" -not -name \"xo-web\" -not -name \"xo-server-cloud\" -exec ln -sn {} \"$INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/node_modules/\" \;"
	else
		local PLUGINSARRAY=($(echo "$PLUGINS" | tr ',' ' '))
		for x in "${PLUGINSARRAY[@]}"; do
		if [[ $(find "$INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages" -type d -name "$x") ]]; then
			runcmd "ln -sn $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/$x $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/node_modules/"
		fi
		done
	fi

	printok "Installing plugins"

}

function InstallXO {

	set -uo pipefail

	trap ErrorHandling ERR INT

	# Create user if doesn't exist (if defined)

	if [[ "$XOUSER" != "root" ]]; then
		if [[ -z $(runcmd_stdout "getent passwd $XOUSER") ]]; then
			echo
			printprog "Creating missing $XOUSER user"
			runcmd "useradd -s /sbin/nologin $XOUSER -m"
			printok "Creating missing $XOUSER user"
			sleep 2
		fi
	fi

	# Create installation directory if doesn't exist already
	if [[ ! -d "$INSTALLDIR" ]] ; then
		echo
		printprog "Creating missing basedir to $INSTALLDIR"
		runcmd "mkdir -p \"$INSTALLDIR\""
		printok "Creating missing basedir to $INSTALLDIR"
	fi

	# Create missing xo-builds directory if doesn't exist already
	if [[ ! -d "$INSTALLDIR/xo-builds" ]]; then
		echo
		printprog "Creating missing xo-builds directory to $INSTALLDIR/xo-builds"
		runcmd "mkdir \"$INSTALLDIR/xo-builds\""
		printok "Creating missing xo-builds directory to $INSTALLDIR/xo-builds"
	fi

	echo
	printinfo "Fetching Xen Orchestra source code"
	if [[ ! -d "$XO_SRC_DIR" ]]; then
		runcmd "mkdir -p \"$XO_SRC_DIR\""
		runcmd "git clone \"${REPOSITORY}\" \"$XO_SRC_DIR\""
	else
		runcmd "cd \"$XO_SRC_DIR\" && git pull"
		runcmd "cd $(dirname "$0")"
	fi

	# Deploy the latest xen-orchestra source to the new install directory.
	echo
	printinfo "Creating install directory: $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
	runcmd "rm -rf \"$INSTALLDIR/xo-builds/xen-orchestra-$TIME\""
	runcmd "cp -r \"$XO_SRC_DIR\" \"$INSTALLDIR/xo-builds/xen-orchestra-$TIME\""

	if [[ "$BRANCH" == "release" ]]; then
		runcmd "cd $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
		TAG=$(runcmd_stdout "git describe --tags '$(git rev-list --tags --max-count=1)'")

		echo
		printinfo "Checking out latest tagged release '$TAG'"

		runcmd "git checkout $TAG"
		runcmd "cd $(dirname "$0")"
	elif [[ "$BRANCH" != "master" ]]; then
		echo
		printinfo "Checking out source code from branch '$BRANCH'"

		runcmd "cd $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
		runcmd "git checkout $BRANCH"
		runcmd "cd $(dirname "$0")"
	fi

	# Check if the new repo is any different from the currently-installed
	# one. If not, then skip the build and delete the repo we just cloned.

	# Get the commit ID of the to-be-installed xen-orchestra.
#	runcmd "cd $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
	NEW_REPO_HASH=$(runcmd_stdout "cd $INSTALLDIR/xo-builds/xen-orchestra-$TIME && git rev-parse HEAD")
	NEW_REPO_HASH_SHORT=$(runcmd_stdout "cd $INSTALLDIR/xo-builds/xen-orchestra-$TIME && git rev-parse --short HEAD")
	runcmd "cd $(dirname "$0")"

	# Get the commit ID of the currently-installed xen-orchestra (if one
	# exists).
	if [[ -L "$INSTALLDIR/xo-server" ]] && [[ -n $(runcmd_stdout "readlink -e $INSTALLDIR/xo-server") ]]; then
		OLD_REPO_HASH=$(runcmd_stdout "cd $INSTALLDIR/xo-server && git rev-parse HEAD")
		OLD_REPO_HASH_SHORT=$(runcmd_stdout "cd $INSTALLDIR/xo-server && git rev-parse --short HEAD")
		runcmd "cd $(dirname "$0")"
	else
		# If there's no existing installation, then we definitely want
		# to proceed with the bulid.
		OLD_REPO_HASH=""
		OLD_REPO_HASH_SHORT=""
	fi

	# If the new install is no different from the existing install, then don't
	# proceed with the build.
	if [[ "$NEW_REPO_HASH" == "$OLD_REPO_HASH" ]] && [[ "$FORCE" != "true" ]]; then
		echo
		if [[ "$INTERACTIVE" == "true" ]]; then
			printinfo "No changes to xen-orchestra since previous install. Run update anyway?"
			read -r -p "[y/N]: " answer
			answer="${answer:-n}"
				case "$answer" in
				y)
				:
				;;
				n)
				printinfo "Cleaning up install directory: $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
				runcmd "rm -rf $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
				exit 0
				;;
			esac
		else
			printinfo "No changes to xen-orchestra since previous install. Skipping xo-server and xo-web build."
			printinfo "Cleaning up install directory: $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
			runcmd "rm -rf $INSTALLDIR/xo-builds/xen-orchestra-$TIME"
			exit 0
		fi
	fi

	# Now that we know we're going to be building a new xen-orchestra, make
	# sure there's no already-running xo-server process.
	if [[ $(runcmd_stdout "pgrep -f xo-server") ]]; then
		echo
		printprog "Shutting down xo-server"
		/bin/systemctl stop xo-server || { printfail "failed to stop service, exiting..." ; exit 1; }
		printok "Shutting down xo-server"
	fi

	# If this isn't a fresh install, then list the upgrade the user is making.
	if [[ -n "$OLD_REPO_HASH" ]]; then
		echo
		if [[ "$FORCE" != "true" ]]; then
			printinfo "Updating xen-orchestra from '$OLD_REPO_HASH_SHORT' to '$NEW_REPO_HASH_SHORT'"
			echo "Updating xen-orchestra from '$OLD_REPO_HASH_SHORT' to '$NEW_REPO_HASH_SHORT'" >> "$LOGFILE"
		else
			printinfo "Updating xen-orchestra (forced) from '$OLD_REPO_HASH_SHORT' to '$NEW_REPO_HASH_SHORT'"
			echo "Updating xen-orchestra (forced) from '$OLD_REPO_HASH_SHORT' to '$NEW_REPO_HASH_SHORT'" >> "$LOGFILE"
		fi
	else
		printinfo "Installing xen-orchestra from branch: $BRANCH - commit: $NEW_REPO_HASH_SHORT"
		echo "Installing xen-orchestra from branch: $BRANCH - commit: $NEW_REPO_HASH_SHORT" >> "$LOGFILE"
		TASK="Installation"
	fi

	# Install additional plugins
	InstallAdditionalXOPlugins

	echo
	printinfo "xo-server and xo-web build takes quite a while. Grab a cup of coffee and lay back"
	echo
	printprog "Running installation"
	runcmd "cd $INSTALLDIR/xo-builds/xen-orchestra-$TIME && yarn && yarn build"
	printok "Running installation"

	# Install plugins
	InstallXOPlugins

	echo
	printinfo "Fixing binary path in systemd service configuration file"
	# shellcheck disable=SC1117
	runcmd "sed -i \"s#ExecStart=.*#ExecStart=$INSTALLDIR\/xo-server\/dist\/cli.mjs#\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/xo-server.service"
	printinfo "Adding WorkingDirectory parameter to systemd service configuration file"
	# shellcheck disable=SC1117
	runcmd "sed -i \"/ExecStart=.*/a WorkingDirectory=$INSTALLDIR/xo-server\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/xo-server.service"

	if [[ "$XOUSER" != "root" ]]; then
		printinfo "Adding user to systemd config"
		# shellcheck disable=SC1117
		runcmd "sed -i \"/SyslogIdentifier=.*/a User=$XOUSER\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/xo-server.service"

		if [ "$PORT" -le "1024" ]; then
			NODEBINARY=$(runcmd_stdout "command -v node")
			if [[ -L "$NODEBINARY" ]]; then
				NODEBINARY=$(runcmd_stdout "readlink -e $NODEBINARY")
			fi

			if [[ -n "$NODEBINARY" ]]; then
				printprog "Attempting to set cap_net_bind_service permission for $NODEBINARY"
				runcmd "setcap 'cap_net_bind_service=+ep' $NODEBINARY" && printok "Attempting to set cap_net_bind_service permission for $NODEBINARY" \
				|| { printfail "Attempting to set cap_net_bind_service permission for $NODEBINARY" ; echo "	Non-privileged user might not be able to bind to <1024 port. xo-server won't start most likely" ; }
			else
				printfail "Can't find node executable, or it's a symlink to non existing file. Not trying to setcap. xo-server won't start most likely"
			fi
		fi
	fi

        if [[ ! -f "$CONFIGPATH/.config/xo-server/config.toml" ]] || [[ "$CONFIGUPDATE" == "true" ]]; then

		printinfo "Fixing relative path to xo-web installation in xo-server configuration file"

		INSTALLDIRESC=$(echo "$INSTALLDIR" | sed 's/\//\\\//g')
		# shellcheck disable=SC1117
		runcmd "sed -i \"s/#'\/any\/url' = '\/path\/to\/directory'/'\/' = '$INSTALLDIRESC\/xo-web\/dist\/'/\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/sample.config.toml"
                sleep 2

                if [[ "$PORT" != "80" ]]; then
			printinfo "Changing port in xo-server configuration file"
			# shellcheck disable=SC1117
			runcmd "sed -i \"s/port = 80/port = $PORT/\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/sample.config.toml"
			sleep 2
                fi

                if [[ "$HTTPS" == "true" ]] ; then
			printinfo "Enabling HTTPS in xo-server configuration file"
			# shellcheck disable=SC1117
			runcmd "sed -i \"s%# cert = '.\/certificate.pem'%cert = '$PATH_TO_HTTPS_CERT'%\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/sample.config.toml"
			# shellcheck disable=SC1117
			runcmd "sed -i \"s%# key = '.\/key.pem'%key = '$PATH_TO_HTTPS_KEY'%\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/sample.config.toml"
			# shellcheck disable=SC1117
			runcmd "sed -i \"s/# redirectToHttps/redirectToHttps/\" $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/sample.config.toml"
			sleep 2
		fi

		printinfo "Activating modified configuration file"
		runcmd "mkdir -p $CONFIGPATH/.config/xo-server"
		runcmd "mv -f $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/sample.config.toml $CONFIGPATH/.config/xo-server/config.toml"


        fi

	echo
	printinfo "Symlinking fresh xo-server install/update to $INSTALLDIR/xo-server"
	runcmd "ln -sfn $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server $INSTALLDIR/xo-server"
	sleep 2
	printinfo "Symlinking fresh xo-web install/update to $INSTALLDIR/xo-web"
	runcmd "ln -sfn $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-web $INSTALLDIR/xo-web"

	if [[ "$XOUSER" != "root" ]]; then
		runcmd "chown -R $XOUSER:$XOUSER $INSTALLDIR/xo-builds/xen-orchestra-$TIME"

		if [ ! -d /var/lib/xo-server ]; then
			runcmd "mkdir /var/lib/xo-server"
		fi

		runcmd "chown -R $XOUSER:$XOUSER /var/lib/xo-server"

		runcmd "chown -R $XOUSER:$XOUSER $CONFIGPATH/.config/xo-server"
	fi

	# fix to prevent older installations to not update because systemd service is not symlinked anymore
	if [[ $(find /etc/systemd/system -maxdepth 1 -type l -name "xo-server.service") ]]; then
		runcmd "rm -f /etc/systemd/system/xo-server.service"
	fi

	echo
	printinfo "Replacing systemd service configuration file"

	runcmd "/bin/cp -f $INSTALLDIR/xo-builds/xen-orchestra-$TIME/packages/xo-server/xo-server.service /etc/systemd/system/xo-server.service"
	sleep 2
	printinfo "Reloading systemd configuration"
	echo
	runcmd "/bin/systemctl daemon-reload"
	sleep 2

	echo
	printinfo "Starting xo-server..."
	runcmd "/bin/systemctl start xo-server"

	# no need to exit/trap on errors anymore
	set +eo pipefail
	trap - ERR INT

	count=0
	limit=6
	# shellcheck disable=SC1117
	servicestatus="$(journalctl --since "$LOGTIME" -u xo-server | grep "Web server listening on https\{0,1\}:\/\/.*:$PORT")"
	while [[ -z "$servicestatus" ]] && [[ "$count" -lt "$limit" ]]; do
		echo " waiting for port to be open"
		sleep 10
		# shellcheck disable=SC1117
		servicestatus="$(journalctl --since "$LOGTIME" -u xo-server | grep "Web server listening on https\{0,1\}:\/\/.*:$PORT")"
		(( count++ ))
	done

	if [[ -n "$servicestatus" ]]; then
		echo
		echo -e "	${COLOR_GREEN}WebUI started in port $PORT. Make sure you have firewall rules in place to allow access.${COLOR_N}"
		if [[ "$TASK" == "Installation" ]]; then
			echo -e "	${COLOR_GREEN}Default username: admin@admin.net password: admin${COLOR_N}"
		fi
		echo
		printinfo "$TASK successful. Enabling xo-server service to start on reboot"
		echo "" >> "$LOGFILE"
		echo "$TASK succesful" >> "$LOGFILE"
		runcmd "/bin/systemctl enable xo-server"
		echo
	else
		echo
		printfail "$TASK completed, but looks like there was a problem when starting xo-server/reading journalctl. Please see logs for more details"
		# shellcheck disable=SC2129
		echo "" >> "$LOGFILE"
		echo "$TASK failed" >> "$LOGFILE"
		echo "xo-server service log:" >> "$LOGFILE"
		echo "" >> "$LOGFILE"
		journalctl --since "$LOGTIME" -u xo-server >> "$LOGFILE"
		echo
		echo "Control xo-server service with systemctl for stop/start/restart etc."
		exit 1
	fi

}


function UpdateXO {

	InstallXO

	set -uo pipefail

	if [[ "$PRESERVE" == "0" ]]; then
		printinfo "PRESERVE variable is set to 0. This needs to be at least 1. Not doing a cleanup"
		return 0
	fi

	# remove old builds. leave as many as defined in PRESERVE variable
	echo
	printprog "Removing old installations. Leaving $PRESERVE latest"
	runcmd "find $INSTALLDIR/xo-builds/ -maxdepth 1 -type d -name \"xen-orchestra*\" -printf \"%T@ %p\\n\" | sort -n | cut -d' ' -f2- | head -n -$PRESERVE | xargs -r rm -r"
	printok "Removing old installations. Leaving $PRESERVE latest"

}

function HandleArgs {

	OPTS=$(getopt -o: --long force,rollback,update,install -- "$@")

        #shellcheck disable=SC2181
	if [[ $? != 0 ]]; then
		echo "Usage: $(dirname "$0")/$(basename "$0") [--install | --update | --rollback ] [--force]"
		exit 1
	fi

	eval set -- "$OPTS"

	local UPDATEARG=0
	local INSTALLARG=0
	local ROLLBACKARG=0

	while true; do
	case "$1" in
		--force)
			shift
			FORCE="true"
			;;
		--update)
			shift
			local UPDATEARG=1
			TASK="Update"
			;;
		--install)
			shift
			local INSTALLARG=1
			TASK="Installation"
			;;
		--rollback)
			shift
			local ROLLBACKARG=1
			;;
		--)
			shift
			break
			;;
		*)
			shift
			break
			;;
		esac
	done

	if [[ "$((INSTALLARG+UPDATEARG+ROLLBACKARG))" -gt 1 ]]; then
		echo "Define either install/update or rollback"
		exit 1
	fi

	if [[ "$UPDATEARG" -gt 0 ]]; then
		UpdateNodeYarn
		UpdateXO
		exit
	fi

	if [[ "$INSTALLARG" -gt 0 ]]; then
		if [ "$PKG_FORMAT" == "rpm" ]; then
			InstallDependenciesRPM
			InstallXO
			exit
		else
			InstallDependenciesDeb
			InstallXO
			exit
		fi
	fi

	if [[ "$ROLLBACKARG" -gt 0 ]]; then
		RollBackInstallation
		exit
	fi

}

function RollBackInstallation {

	set -uo pipefail

	INSTALLATIONS=($(runcmd_stdout "find '$INSTALLDIR/xo-builds/' -maxdepth 1 -type d -name 'xen-orchestra-*'"))

	if [[ ${#INSTALLATIONS[@]} -le 1 ]]; then
		printinfo "One or less installations exist, nothing to change"
		exit 0
	fi

	echo "Which installation to roll back?"
	echo
	local PS3="Pick a number. CTRL+C to exit: "
	select INSTALLATION in "${INSTALLATIONS[@]}"; do
		case $INSTALLATION in
			*xen-orchestra*)
				echo
				printinfo "Setting $INSTALLDIR/xo-server symlink to $INSTALLATION/packages/xo-server"
				runcmd "ln -sfn $INSTALLATION/packages/xo-server $INSTALLDIR/xo-server"
				printinfo "Setting $INSTALLDIR/xo-web symlink to $INSTALLATION/packages/xo-web"
				runcmd "ln -sfn $INSTALLATION/packages/xo-web $INSTALLDIR/xo-web"
				echo
				printinfo "Replacing xo.server.service systemd configuration file"
				runcmd "/bin/cp -f $INSTALLATION/packages/xo-server/xo-server.service /etc/systemd/system/xo-server.service"
				runcmd "/bin/systemctl daemon-reload"
				echo
				printinfo "Restarting xo-server..."
				runcmd "/bin/systemctl restart xo-server"
				echo
				break
			;;
			*)
				printfail "Try again"
			;;
			esac
		done

}

function CheckOS {

	OSVERSION=$(runcmd_stdout "grep ^VERSION_ID /etc/os-release | cut -d'=' -f2 | grep -Eo '[0-9]{1,2}' | head -1")
	OSNAME=$(runcmd_stdout "grep ^NAME /etc/os-release | cut -d'=' -f2 | sed 's/\"//g' | awk '{print \$1}'")

	if [[ $(runcmd_stdout "command -v yum") ]]; then
		PKG_FORMAT="rpm"
	fi

	if [[ $(runcmd_stdout "command -v apt-get") ]]; then
		PKG_FORMAT="deb"
	fi

	if [[ -z "$PKG_FORMAT" ]]; then
		printfail "this script requires either yum or apt-get"
		exit 1
	fi

	if [[ "$OS_CHECK" != "true" ]]; then
		return 0
	fi

	if [[ ! "$OSNAME" =~ ^(Debian|Ubuntu|CentOS|Rocky|AlmaLinux)$ ]]; then
		printfail "Only Ubuntu/Debian/CentOS/Rocky/AlmaLinux supported"
		exit 1
	fi

	if [[ "$OSNAME" == "CentOS" ]] && [[ "$OSVERSION" != "8" ]]; then
		printfail "Only CentOS 8 supported"
		exit 1
	fi

	if [[ "$OSNAME" == "Rocky" ]] && [[ "$OSVERSION" != "8" ]]; then
		printfail "Only Rocky Linux 8 supported"
		exit 1
	fi

	# for future if/when something above 8 is released
	if [[ "$OSNAME" == "AlmaLinux" ]] && [[ "$OSVERSION" != "8" ]]; then
		printfail "Only AlmaLinux 8 supported"
		exit 1
	fi

	if [[ "$OSNAME" == "Debian" ]] && [[ ! "$OSVERSION" =~ ^(8|9|10)$ ]]; then
		printfail "Only Debian 8/9/10 supported"
		exit 1
	fi

	if [[ "$OSNAME" == "Ubuntu" ]] && [[ ! "$OSVERSION" =~ ^(16|18|20)$ ]]; then
		printfail "Only Ubuntu 16/18/20 supported"
		exit 1
	fi

}

function CheckXE {

	if [[ $(runcmd_stdout "command -v xe") ]]; then
		printfail "xe binary found, don't try to run install on xcp-ng/xenserver host. use xo-appliance.sh instead"
		exit 1
	fi
}

function CheckArch {

	if [[ "$ARCH_CHECK" != "true" ]]; then
		return 0
	fi

	if [[ $(runcmd_stdout "uname -m") != "x86_64" ]]; then
		printfail "Installation supports only x86_64. You seem to be running architecture: $(uname -m)"
		exit 1
	fi
}

function CheckSystemd {

	if [[ -z $(runcmd_stdout "command -v systemctl") ]]; then
		printfail "This tool is designed to work with systemd enabled systems only"
		exit 1
	fi
}

function CheckCertificate {
	if [[ "$HTTPS" == "true" ]]; then
		local CERT="$(runcmd_stdout "openssl x509 -modulus -noout -in $PATH_TO_HTTPS_CERT | openssl md5")"
		local KEY="$(runcmd_stdout "openssl rsa -modulus -noout -in $PATH_TO_HTTPS_KEY | openssl md5")"
		if [[ "$CERT" != "$KEY" ]]; then
			echo
			printinfo "$PATH_TO_HTTPS_CERT:"
			printinfo "$CERT"
			printinfo "$PATH_TO_HTTPS_KEY:"
			printinfo "$KEY"
			echo
			printfail "MD5 of your TLS key and certificate dont match. Please check files and try again."
			exit 1
		fi
	fi

}

function CheckMemory {
	SYSMEM=$(runcmd_stdout "grep MemTotal /proc/meminfo | awk '{print \$2}'")

	if [[ "$SYSMEM" -lt 3000000 ]]; then
		echo
		echo -e "${COLOR_RED}WARNING: you have less than 3GB of RAM in your system. Installation might run out of memory, continue anyway?${COLOR_N}"
		echo
		read -r -p "y/N: " answer
		case $answer in
			y)
				:
				;;
			n)
				exit 0
				;;
			*)
				exit 0
				;;
		esac
	fi

}

function CheckDiskFree {
	FREEDISK=$(runcmd_stdout "df -P -k '${INSTALLDIR%/*}' | tail -1 | awk '{print \$4}'")

	if [[ "$FREEDISK" -lt 1048576 ]]; then
		echo
		echo -e "${COLOR_RED}free disk space in ${INSTALLDIR%/*} seems to be less than 1GB. Install/update will most likely fail, continue anyway?${COLOR_N}"
		echo
		read -r -p "y/N: " answer
			case $answer in
			y)
				:
				;;
			n)
				exit 0
				;;
			*)
				exit 0
				;;
		esac
	fi
}

function StartUpScreen {

echo "-----------------------------------------"
echo
echo "Welcome to automated Xen Orchestra install"
echo
echo "Following options will be used for installation:"
echo
echo -e "OS: ${COLOR_WHITE}$OSNAME $OSVERSION ${COLOR_N}"
echo -e "Basedir: ${COLOR_WHITE}$INSTALLDIR ${COLOR_N}"

if [ "$XOUSER" ]; then
	echo -e "User: ${COLOR_WHITE}$XOUSER ${COLOR_N}"
else
	echo -e "User: ${COLOR_WHITE}root ${COLOR_N}"
fi

echo -e "Port: ${COLOR_WHITE}$PORT${COLOR_N}"
echo -e "HTTPS: ${COLOR_WHITE}${HTTPS}${COLOR_N}"
echo -e "Git Branch for source: ${COLOR_WHITE}$BRANCH${COLOR_N}"
echo -e "Following plugins will be installed: ${COLOR_WHITE}$PLUGINS${COLOR_N}"
echo -e "Number of previous installations to preserve: ${COLOR_WHITE}$PRESERVE${COLOR_N}"
echo -e "Node.js and yarn auto update: ${COLOR_WHITE}$AUTOUPDATE${COLOR_N}"
echo
echo -e "Errorlog is stored to ${COLOR_WHITE}$LOGFILE${COLOR_N} for debug purposes"
echo
echo -e "Xen Orchestra configuration will be stored to ${COLOR_WHITE}$CONFIGPATH/.config/xo-server/config.toml${COLOR_N}, if you don't want it to be replaced with every update, set ${COLOR_WHITE}CONFIGUPDATE${COLOR_N} to false in ${COLOR_WHITE}xo-install.cfg${COLOR_N}"
echo "-----------------------------------------"

echo
echo -e "${COLOR_WHITE}1. Install${COLOR_N}"
echo -e "${COLOR_WHITE}2. Update${COLOR_N}"
echo -e "${COLOR_WHITE}3. Rollback${COLOR_N}"
echo -e "${COLOR_WHITE}4. Exit${COLOR_N}"
echo
read -r -p ": " option

		case $option in
		1)
			if [[ $(pgrep -f xo-server) ]]; then
				echo "Looks like xo-server process is already running, consider running update instead. Continue anyway?"
				read -r -p "[y/N]: " answer
					case $answer in
						y)
						echo "Stopping xo-server..."
						runcmd "/bin/systemctl stop xo-server" \
						|| { printfail "failed to stop service, exiting..." ; exit 1; }
					;;
						n)
						exit 0
					;;
						*)
						exit 0
					;;
						esac
			fi

			if [ "$PKG_FORMAT" == "rpm" ]; then
				TASK="Installation"
				INTERACTIVE="true"
				InstallDependenciesRPM
				InstallXO
				exit 0
			fi
			if [ "$PKG_FORMAT" == "deb" ]; then
				TASK="Installation"
				INTERACTIVE="true"
				InstallDependenciesDeb
				InstallXO
				exit 0
			fi
		;;
		2)
			TASK="Update"
			INTERACTIVE="true"
			UpdateNodeYarn
			UpdateXO
			exit 0
		;;
		3)
			RollBackInstallation
			exit 0
		;;
		4)
			exit 0
		;;
		*)
			echo "Please choose one of the options"
			echo
			exit 0
		;;
esac

}

scriptInfo
CheckUser
CheckArch
CheckOS
CheckSystemd
CheckXE
CheckCertificate

if [[ $# != "0" ]]; then
	HandleArgs "$@"
	exit 0
else
	CheckDiskFree
	CheckMemory
	StartUpScreen
fi

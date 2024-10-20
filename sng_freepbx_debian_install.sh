#!/bin/bash
#####################################################################################
# * Copyright 2024 by Sangoma Technologies
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3.0
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# @author kgupta@sangoma.com
#
# This FreePBX install script and all concepts are property of
# Sangoma Technologies.
# This install script is free to use for installing FreePBX
# along with dependent packages only but carries no guarantee on performance
# and is used at your own risk.  This script carries NO WARRANTY.
#####################################################################################
#                                               FreePBX 17                          #
#####################################################################################
set -e
SCRIPTVER="1.14"
ASTVERSION=21
PHPVERSION="8.2"
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
log=$LOG_FILE
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEBIAN_MIRROR="http://ftp.debian.org/debian"
NPM_MIRROR=""

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Setup a sane PATH for script execution as root
export PATH=$SANE_PATH

while [[ $# -gt 0 ]]; do
    case $1 in
        --testing)
            testrepo=true
            shift # past argument
            ;;
        --nofreepbx)
            nofpbx=true
            shift # past argument
            ;;
        --noasterisk)
            noast=true
            shift # past argument
            ;;
        --opensourceonly)
            opensourceonly=true
            shift # past argument
            ;;
        --noaac)
            noaac=true
            shift # past argument
            ;;
        --skipversion)
            skipversion=true
            shift # past argument
            ;;
        --dahdi)
            dahdi=true
            shift # past argument
            ;;
        --dahdi-only)
            nofpbx=true
            noast=true
            noaac=true
            dahdi=true
            shift # past argument
            ;;
        --nochrony)
            nochrony=true
            shift # past argument
            ;;
        --debianmirror)
            DEBIAN_MIRROR=$2
            shift; shift # past argument
            ;;
        --npmmirror)
            NPM_MIRROR=$2
            shift; shift # past argument
            ;;
        -*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            echo "Unknown argument \"$1\""
            exit 1
            ;;
    esac
done

# Create the log file
mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"

# Redirect stderr to the log file
exec 2>>"${LOG_FILE}"

#Comparing version
compare_version() {
    # Skipped in Docker environment
    echo "Skipping version compare in Docker environment"
}

check_version() {
    # Skipped in Docker environment
    echo "Skipping version check in Docker environment"
}

# Function to log messages
log() {
    echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

message() {
    echo "$(date +"%Y-%m-%d %T") - $*"
    log "$*"
}

#Function to record and display the current step
setCurrentStep () {
    currentStep="$1"
    message "${currentStep}"
}

# Function to cleanup installation
terminate() {
    # removing pid file
    message "Exiting script"
    rm -f "$pidfile"
}

#Function to log error and location
errorHandler() {
    log "****** INSTALLATION FAILED *****"
    message "Installation failed at step ${currentStep}. Please check log ${LOG_FILE} for details."
    message "Error at line: $1 exiting with code $2 (last command was: $3)"
    exit "$2"
}

# Checking if the package is already installed or not
isinstalled() {
    PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$@" 2>/dev/null|grep "install ok installed")
    if [ "" = "$PKG_OK" ]; then
        false
    else
        true
    fi
}

# Function to install the package
pkg_install() {
    log "############################### "
    PKG=$@
    if isinstalled $PKG; then
        log "$PKG already present ...."
    else
        message "Installing $PKG ...."
        apt-get -y --ignore-missing -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-overwrite" install $PKG >> $log
        if isinstalled $PKG; then
            message "$PKG installed successfully...."
        else
            message "$PKG failed to install ...."
            message "Exiting the installation process as dependent $PKG failed to install ...."
            terminate
        fi
    fi
    log "############################### "
}

# Function to install the asterisk and dependent packages
install_asterisk() {
    astver=$1
    ASTPKGS=("addons"
        "addons-bluetooth"
        "addons-core"
        "addons-mysql"
        "addons-ooh323"
        "core"
        "curl"
        "dahdi"
        "doc"
        "odbc"
        "ogg"
        "flite"
        "g729"
        "resample"
        "snmp"
        "speex"
        "sqlite3"
        "res-digium-phone"
        "voicemail"
    )

    # creating directories
    mkdir -p /var/lib/asterisk/moh
    pkg_install asterisk$astver

    for i in "${!ASTPKGS[@]}"; do
        pkg_install asterisk$astver-${ASTPKGS[$i]}
    done

    pkg_install asterisk$astver.0-freepbx-asterisk-modules
    pkg_install asterisk-version-switch
    pkg_install asterisk-sounds-*
}

setup_repositories() {
    # Remove old GPG key if it exists
    apt-key del "9641 7C6E 0423 6E0A 986B 69EF DE82 7447 3C8D 0E52" >> "$log" || true

    # Import the GPG key for the FreePBX repository
    wget -O - http://deb.freepbx.org/gpg/aptly-pubkey.asc | gpg --dearmor -o /usr/share/keyrings/freepbx-archive-keyring.gpg >> "$log"

    # Determine which repository to use
    if [ "$testrepo" ]; then
        REPO_URL="http://deb.freepbx.org/freepbx17-dev"
    else
        REPO_URL="http://deb.freepbx.org/freepbx17-prod"
    fi

    # Add the FreePBX repository directly to sources.list.d
    echo "deb [signed-by=/usr/share/keyrings/freepbx-archive-keyring.gpg arch=amd64] $REPO_URL bookworm main" > /etc/apt/sources.list.d/freepbx.list

    # If not skipping AAC, add the Debian non-free repository
    if [ ! "$noaac" ]; then
        echo "deb $DEBIAN_MIRROR stable main non-free non-free-firmware" > /etc/apt/sources.list.d/debian-non-free.list
    fi

    setCurrentStep "Setting up Sangoma repository"

    local aptpref="/etc/apt/preferences.d/99sangoma-fpbx-repository"
    cat <<EOF> $aptpref
Package: *
Pin: origin deb.freepbx.org
Pin-Priority: ${MIRROR_PRIO}
EOF

    if [ "$noaac" ]; then
        cat <<EOF>> $aptpref

Package: ffmpeg
Pin: origin deb.freepbx.org
Pin-Priority: 1
EOF
    fi
}

# Create a dummy systemctl script
create_dummy_systemctl() {
    if [ ! -e /usr/bin/systemctl ]; then
        cat << EOF > /usr/bin/systemctl
#!/bin/bash
echo "Warning: systemctl command is not available in this Docker container."
exit 0
EOF
        chmod +x /usr/bin/systemctl
    fi
}

refresh_signatures() {
  fwconsole ma refreshsignatures >> "$log"
}

check_services() {
    # Skipping service checks in Docker environment
    echo "Skipping service checks in Docker environment"
}

check_php_version() {
    php_version=$(php -v | grep built: | awk '{print $2}')
    if [[ "${php_version:0:3}" == "8.2" ]]; then
        message "Installed PHP version $php_version is compatible with FreePBX."
    else
        message "Installed PHP version  $php_version is not compatible with FreePBX. Please install PHP version '8.2.x'"
    fi

    # Checking whether enabled PHP modules are of PHP 8.2 version
    php_module_version=$(a2query -m | grep php | awk '{print $1}')

    if [[ "$php_module_version" == "php8.2" ]]; then
       log "The PHP module version $php_module_version is compatible with FreePBX. Proceeding with the script."
    else
       log "The installed PHP module version $php_module_version is not compatible with FreePBX. Please install PHP version '8.2'."
       exit 1
    fi
}

verify_module_status() {
    modules_list=$(fwconsole ma list | grep -Ewv "Enabled|----|Module|No repos")
    if [ -z "$modules_list" ]; then
        message "All Modules are Enabled."
    else
        message "List of modules which are not Enabled:"
        message "$modules_list"
    fi
}

check_freepbx() {
     # Check if FreePBX is installed
    if ! dpkg -l | grep -q 'freepbx'; then
        message "FreePBX is not installed. Please install FreePBX to proceed."
    else
        verify_module_status
        if [ ! $opensourceonly ] ; then
            echo "Skipping network port inspection in Docker environment"
        fi
        echo "Skipping process inspection in Docker environment"
        inspect_job_status=$(fwconsole job --list)
        message "Job list : $inspect_job_status"
    fi
}

check_digium_phones_version() {
    installed_version=$(asterisk -rx 'digium_phones show version' | awk '/Version/{print $NF}' 2>/dev/null)
    if [[ -n "$installed_version" ]]; then
        required_version="21.0_3.6.8"
        present_version=$(echo "$installed_version" | sed 's/_/./g')
        required_version=$(echo "$required_version" | sed 's/_/./g')
        if dpkg --compare-versions "$present_version" "lt" "$required_version"; then
            message "A newer version of Digium Phones module is available."
        else
            message "Installed Digium Phones module version: ($installed_version)"
        fi
    else
        message "Failed to check Digium Phones module version."
    fi
}

check_asterisk() {
    if ! dpkg -l | grep -q 'asterisk'; then
        message "Asterisk is not installed. Please install Asterisk to proceed."
    else
        check_asterisk_version=$(asterisk -V)
        message "$check_asterisk_version"
        if asterisk -rx "module show" | grep -q "res_digium_phone.so"; then
            check_digium_phones_version
        else
            message "Digium Phones module is not loaded. Please make sure it is installed and loaded correctly."
        fi
    fi
}

hold_packages() {
    # Skipping package hold in Docker environment
    echo "Skipping package hold in Docker environment"
}

################################################################################################################
MIRROR_PRIO=600
kernel=$(uname -a)
host=$(hostname)
fqdn="$(hostname -f)" || true

# Install wget which is required for version check
pkg_install wget

# Script version check
if [[ $skipversion ]]; then
    message "Skipping version check..."
else
    # Perform version check if --skipversion is not provided
    message "Performing version check..."
    check_version
fi

# In Docker, we are in a container
message "Running in a Docker container. Adjusting script for container environment."

# Check if we are running on a 64-bit system
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" != "amd64" ]; then
    message "FreePBX 17 installation can only be made on a 64-bit (amd64) system!"
    message "Current System's Architecture: $ARCH"
    exit 1
fi

# Ensure the script is not running
pid="$$"
pidfile='/var/run/freepbx17_installer.pid'

if [ -f "$pidfile" ]; then
    log "Previous PID file found."
    if ps -p "${pid}" > /dev/null
    then
        message "FreePBX 17 installation process is already going on (PID=${pid}), hence not starting new process"
        exit 1;
    fi
    log "Removing stale PID file"
    rm -f "${pidfile}"
fi

setCurrentStep "Starting installation."
trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
trap "terminate" EXIT
echo "${pid}" > $pidfile

start=$(date +%s)
message "  Starting FreePBX 17 installation process for $host $kernel"
message "  Please refer to the $log to know the process..."
log "  Executing script v$SCRIPTVER ..."

setCurrentStep "Making sure installation is sane"
# Fixing broken install
apt-get -y --fix-broken install >> $log
apt-get autoremove -y >> "$log"

# Check if the CD-ROM repository is present in the sources.list file
if grep -q "^deb cdrom" /etc/apt/sources.list; then
  # Comment out the CD-ROM repository line in the sources.list file
  sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list
  message "Commented out CD-ROM repository in sources.list"
fi

apt-get update >> $log

# Adding iptables and postfix  inputs so "iptables-persistent" and postfix will not ask for the input
setCurrentStep "Setting up default configuration"
debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
echo "postfix postfix/mailname string ${fqdn}" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

# Install below packages which are required for repositories setup
pkg_install software-properties-common
pkg_install gnupg

setCurrentStep "Creating dummy systemctl"
create_dummy_systemctl

setCurrentStep "Setting up repositories"
setup_repositories

lat_dahdi_supp_ver=$(apt-cache search dahdi | grep -E "^dahdi-linux-kmod-[0-9]" | awk '{print $1}' | awk -F'-' '{print $4"-"$5}' | sort -n | tail -1)
kernel_version=$(uname -r | cut -d'-' -f1-2)

message " You are installing FreePBX 17 on kernel $kernel_version."
message " Please note that if you have plan to use DAHDI then:"
message " Ensure that you either choose DAHDI option so script will configure DAHDI"
message "                                  OR"
message " Ensure you are running a DAHDI supported Kernel. Current latest supported kernel version is $lat_dahdi_supp_ver."

if [ $dahdi ]; then
    setCurrentStep "Making sure we allow only proper kernel upgrade and version installation"
    echo "Skipping kernel compatibility check in Docker environment"
fi

setCurrentStep "Updating repository"
apt-get update >> $log

# log the apt-cache policy
apt-cache policy  >> $log

# Install dependent packages
setCurrentStep "Installing required packages"
DEPPKGS=("redis-server"
    "libsnmp-dev"
    "libtonezone-dev"
    "libpq-dev"
    "liblua5.2-dev"
    "libpri-dev"
    "libbluetooth-dev"
    "libunbound-dev"
    "libsybdb5"
    "libspeexdsp-dev"
    "libiksemel-dev"
    "libresample1-dev"
    "libgmime-3.0-dev"
    "libc-client2007e-dev"
    "dpkg-dev"
    "ghostscript"
    "libtiff-tools"
    "iptables-persistent"
    "net-tools"
    "rsyslog"
    "libavahi-client3"
    "nmap"
    "apache2"
    "zip"
    "incron"
    "wget"
    "vim"
    "build-essential"
    "openssh-server"
    "mariadb-server"
    "mariadb-client"
    "bison"
    "flex"
    "flite"
    "php${PHPVERSION}"
    "php${PHPVERSION}-curl"
    "php${PHPVERSION}-zip"
    "php${PHPVERSION}-redis"
    "php${PHPVERSION}-curl"
    "php${PHPVERSION}-cli"
    "php${PHPVERSION}-common"
    "php${PHPVERSION}-mysql"
    "php${PHPVERSION}-gd"
    "php${PHPVERSION}-mbstring"
    "php${PHPVERSION}-intl"
    "php${PHPVERSION}-xml"
    "php${PHPVERSION}-bz2"
    "php${PHPVERSION}-ldap"
    "php${PHPVERSION}-sqlite3"
    "php${PHPVERSION}-bcmath"
    "php${PHPVERSION}-soap"
    "php${PHPVERSION}-ssh2"
    "php-pear"
    "curl"
    "sox"
    "libncurses5-dev"
    "libssl-dev"
    "mpg123"
    "libxml2-dev"
    "libnewt-dev"
    "sqlite3"
    "libsqlite3-dev"
    "pkg-config"
    "automake"
    "libtool"
    "autoconf"
    "git"
    "unixodbc-dev"
    "uuid"
    "uuid-dev"
    "libasound2-dev"
    "libogg-dev"
    "libvorbis-dev"
    "libicu-dev"
    "libcurl4-openssl-dev"
    "odbc-mariadb"
    "libical-dev"
    "libneon27-dev"
    "libsrtp2-dev"
    "libspandsp-dev"
    "sudo"
    "subversion"
    "libtool-bin"
    "python-dev-is-python3"
    "unixodbc"
    "libjansson-dev"
    "nodejs"
    "npm"
    "ipset"
    "iptables"
    "fail2ban"
    "htop"
    "liburiparser-dev"
    "postfix"
    "tcpdump"
    "sngrep"
    "libavdevice-dev"
    "tftpd-hpa"
    "xinetd"
    "lame"
    "haproxy"
    "screen"
    "easy-rsa"
    "openvpn"
    "sysstat"
    "apt-transport-https"
    "lsb-release"
    "ca-certificates"
    "cron"
    "python3-mysqldb"
    "default-libmysqlclient-dev"
    "at"
    "avahi-daemon"
    "avahi-utils"
    "libnss-mdns"
)
if [ "$nochrony" != true ]; then
    DEPPKGS+=("chrony")
fi
for i in "${!DEPPKGS[@]}"; do
    pkg_install ${DEPPKGS[$i]}
done

if  dpkg -l | grep -q 'postfix'; then
    warning_message="# WARNING: Changing the inet_interfaces to an IP other than 127.0.0.1 may expose Postfix to external network connections.\n# Only modify this setting if you understand the implications and have specific network requirements."

    if ! grep -q "WARNING: Changing the inet_interfaces" /etc/postfix/main.cf; then
        # Add the warning message above the inet_interfaces configuration
        sed -i "/^inet_interfaces\s*=/i $warning_message" /etc/postfix/main.cf
    fi

    sed -i "s/^inet_interfaces\s*=.*/inet_interfaces = 127.0.0.1/" /etc/postfix/main.cf

    # Restart postfix
    service postfix restart
fi

# OpenVPN EasyRSA configuration
if [ ! -d "/etc/openvpn/easyrsa3" ]; then
    make-cadir /etc/openvpn/easyrsa3
fi
# Remove below files which will be generated by sysadmin later
rm -f /etc/openvpn/easyrsa3/pki/vars || true
rm -f /etc/openvpn/easyrsa3/vars

# Install Dahdi card support if --dahdi option is provided
if [ "$dahdi" ]; then
    message "Installing DAHDI card support..."
    DAHDIPKGS=("asterisk${ASTVERSION}-dahdi"
           "dahdi-firmware"
           "dahdi-linux"
           "dahdi-linux-devel"
           "dahdi-tools"
           "libpri"
           "libpri-devel"
           "wanpipe"
           "wanpipe-devel"
           "dahdi-linux-kmod-${kernel_version}"
           "kmod-wanpipe-${kernel_version}"
    )

        for i in "${!DAHDIPKGS[@]}"; do
                pkg_install ${DAHDIPKGS[$i]}
        done
fi

# Install libfdk-aac2
if [ $noaac ] ; then
    message "Skipping libfdk-aac2 installation due to noaac option"
else
    pkg_install libfdk-aac2
fi

setCurrentStep "Removing unnecessary packages"
apt-get autoremove -y >> "$log"

execution_time="$(($(date +%s) - start))"
message "Execution time to install all the dependent packages : $execution_time s"

setCurrentStep "Setting up folders and asterisk config"
groupExists="$(getent group asterisk || echo '')"
if [ "${groupExists}" = "" ]; then
    groupadd -r asterisk
fi

userExists="$(getent passwd asterisk || echo '')"
if [ "${userExists}" = "" ]; then
    useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk
fi

# Adding asterisk to the sudoers list
#echo "%asterisk ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Creating /tftpboot directory
mkdir -p /tftpboot
chown -R asterisk:asterisk /tftpboot
# Changing the tftp process path to tftpboot
sed -i -e "s|^TFTP_DIRECTORY=\"/srv\/tftp\"$|TFTP_DIRECTORY=\"/tftpboot\"|" /etc/default/tftpd-hpa
# Change the tftp & chrony options when IPv6 is not available, to allow successful execution
if [ ! -f /proc/net/if_inet6 ]; then
    sed -i -e "s|^TFTP_OPTIONS=\"--secure\"$|TFTP_OPTIONS=\"--secure --ipv4\"|" /etc/default/tftpd-hpa
    if [ "$nochrony" != true ]; then
        sed -i -e "s|^DAEMON_OPTS=\"-F 1\"$|DAEMON_OPTS=\"-F 1 -4\"|" /etc/default/chrony
    fi
fi
# Start the tftp & chrony daemons
# Skipping systemctl commands in Docker environment

# Creating asterisk sound directory
mkdir -p /var/lib/asterisk/sounds
chown -R asterisk:asterisk /var/lib/asterisk

# Changing openssl to make it compatible with the katana
sed -i -e 's/^openssl_conf = openssl_init$/openssl_conf = default_conf/' /etc/ssl/openssl.cnf

isSSLConfigAdapted=$(grep "FreePBX 17 changes" /etc/ssl/openssl.cnf |wc -l)
if [ "0" = "${isSSLConfigAdapted}" ]; then
    cat <<EOF >> /etc/ssl/openssl.cnf
# FreePBX 17 changes - begin
[ default_conf ]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MinProtocol = TLSv1.2
CipherString = DEFAULT:@SECLEVEL=1
# FreePBX 17 changes - end
EOF
fi

#Setting higher precedence value to IPv4
sed -i 's/^#\s*precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

# Setting screen configuration
isScreenRcAdapted=$(grep "FreePBX 17 changes" /root/.screenrc |wc -l)
if [ "0" = "${isScreenRcAdapted}" ]; then
    cat <<EOF >> /root/.screenrc
# FreePBX 17 changes - begin
hardstatus alwayslastline
hardstatus string '%{= kG}[ %{G}%H %{g}][%= %{=kw}%?%-Lw%?%{r}(%{W}%n*%f%t%?(%u)%?%{r})%{w}%?%+Lw%?%?%= %{g}][%{B}%Y-%m-%d %{W}%c %{g}]'
# FreePBX 17 changes - end
EOF
fi

# Setting VIM configuration for mouse copy paste
isVimRcAdapted=$(grep "FreePBX 17 changes" /etc/vim/vimrc.local |wc -l)
if [ "0" = "${isVimRcAdapted}" ]; then
    VIMRUNTIME=$(vim -e -T dumb --cmd 'exe "set t_cm=\<C-M>"|echo $VIMRUNTIME|quit' | tr -d '\015' )
    VIMRUNTIME_FOLDER=$(echo $VIMRUNTIME | sed 's/ //g')

    cat <<EOF >> /etc/vim/vimrc.local
" FreePBX 17 changes - begin
" This file loads the default vim options at the beginning and prevents
" that they are being loaded again later. All other options that will be set,
" are added, or overwrite the default settings. Add as many options as you
" whish at the end of this file.

" Load the defaults
source $VIMRUNTIME_FOLDER/defaults.vim

" Prevent the defaults from being loaded again later, if the user doesn't
" have a local vimrc (~/.vimrc)
let skip_defaults_vim = 1


" Set more options (overwrites settings from /usr/share/vim/vim80/defaults.vim)
" Add as many options as you whish

" Set the mouse mode to 'r'
if has('mouse')
  set mouse=r
endif
" FreePBX 17 changes - end
EOF
fi

# Setting apt configuration to always DO NOT overwrite existing configurations
cat <<EOF >> /etc/apt/apt.conf.d/00freepbx
DPkg::options { "--force-confdef"; "--force-confold"; }
EOF

#chown -R asterisk:asterisk /etc/ssl

# Install Asterisk
if [ $noast ] ; then
    message "Skipping Asterisk installation due to noasterisk option"
else
    # Install Asterisk 21
    setCurrentStep "Installing Asterisk packages."
    install_asterisk $ASTVERSION
fi

# Install PBX dependent packages
setCurrentStep "Installing FreePBX packages"

FPBXPKGS=("sysadmin17"
       "sangoma-pbx17"
       "ffmpeg"
   )
for i in "${!FPBXPKGS[@]}"; do
    pkg_install ${FPBXPKGS[$i]}
done

#Enabling freepbx.ini file
setCurrentStep "Enabling modules."
phpenmod freepbx
mkdir -p /var/lib/php/session

#Creating default config files
mkdir -p /etc/asterisk
touch /etc/asterisk/extconfig_custom.conf
touch /etc/asterisk/extensions_override_freepbx.conf
touch /etc/asterisk/extensions_additional.conf
touch /etc/asterisk/extensions_custom.conf
chown -R asterisk:asterisk /etc/asterisk

# Skipping restarting fail2ban
setCurrentStep "Skipping restart of fail2ban in Docker environment"
# systemctl restart fail2ban  >> $log

if [ $nofpbx ] ; then
  message "Skipping FreePBX 17 installation due to nofreepbx option"
else
  setCurrentStep "Installing FreePBX 17"
  pkg_install ioncube-loader-82
  pkg_install freepbx17

  if [ -n "$NPM_MIRROR" ] ; then
    setCurrentStep "Setting environment variable npm_config_registry=$NPM_MIRROR"
    export npm_config_registry="$NPM_MIRROR"
  fi

  # Check if only opensource required then remove the commercial modules
  if [ "$opensourceonly" ]; then
    setCurrentStep "Removing commercial modules"
    fwconsole ma list | awk '/Commercial/ {print $2}' | xargs -I {} fwconsole ma -f remove {} >> "$log"
    # Remove firewall module also because it depends on commercial sysadmin module
    fwconsole ma -f remove firewall >> "$log" || true
  fi

  if [ $dahdi ]; then
    fwconsole ma downloadinstall dahdiconfig >> $log
    echo 'export PERL5LIB=$PERL5LIB:/etc/wanpipe/wancfg_zaptel' | sudo tee -a /root/.bashrc
  fi

  setCurrentStep "Installing all local modules"
  fwconsole ma installlocal >> $log

  setCurrentStep "Upgrading FreePBX 17 modules"
  fwconsole ma upgradeall >> $log

  setCurrentStep "Reloading and restarting FreePBX 17"
  fwconsole reload >> $log
  fwconsole restart >> $log

  if [ "$opensourceonly" ]; then
    # Uninstall the sysadmin helper package for the sysadmin commercial module
    message "Uninstalling sysadmin17"
    apt-get purge -y sysadmin17 >> "$log"
    # Uninstall ionCube loader required for commercial modules and to install the freepbx17 package
    message "Uninstalling ioncube-loader-82"
    apt-get purge -y ioncube-loader-82 >> "$log"
  fi
fi

setCurrentStep "Wrapping up the installation process"
# Skipping systemctl daemon-reload and enable services in Docker
# systemctl daemon-reload >> "$log"
if [ ! $nofpbx ] ; then
  # systemctl enable freepbx >> "$log"
  echo "Skipping enabling freepbx service in Docker environment"
fi

#delete apache2 index.html as we do not need that file
rm -f /var/www/html/index.html

#enable apache mod ssl
a2enmod ssl  >> "$log"

#enable apache mod expires
a2enmod expires  >> "$log"

#enable apache
a2enmod rewrite >> "$log"

#Enabling freepbx apache configuration
if [ ! $nofpbx ] ; then 
  a2ensite freepbx.conf >> "$log"
  a2ensite default-ssl >> "$log"
fi

#Setting postfix size to 100MB
postconf -e message_size_limit=102400000

# Disable expose_php for provide less information to attacker
sed -i 's/\(^expose_php = \).*/\1Off/' /etc/php/${PHPVERSION}/apache2/php.ini

# Disable ServerTokens and ServerSignature for provide less information to attacker
sed -i 's/\(^ServerTokens \).*/\1Prod/' /etc/apache2/conf-available/security.conf
sed -i 's/\(^ServerSignature \).*/\1Off/' /etc/apache2/conf-available/security.conf

# Restart apache2
# systemctl restart apache2 >> "$log"
service apache2 restart >> "$log"

setCurrentStep "Holding Packages"

hold_packages

# Update logrotate configuration
if grep -q '^#dateext' /etc/logrotate.conf; then
   message "Setting up logrotate.conf"
   sed -i 's/^#dateext/dateext/' /etc/logrotate.conf
fi

#setting permissions
chown -R asterisk:asterisk /var/www/html/

#Creating post apt scripts
echo "Skipping creation of post-apt script in Docker environment"

# Refresh signatures
setCurrentStep "Refreshing modules signatures."
count=1
if [ ! $nofpbx ]; then
  while [ $count -eq 1 ]; do
    set +e
    refresh_signatures
    exit_status=$?
    set -e
    if [ $exit_status -eq 0 ]; then
      break
    else
      log "Command 'fwconsole ma refreshsignatures' failed to execute with exit status $exit_status, running as a background job"
      refresh_signatures &
      log "Continuing the remaining script execution"
      break
    fi
  done
fi

setCurrentStep "FreePBX 17 Installation finished successfully."

############ POST INSTALL VALIDATION ############################################
# Commands for post-installation validation
# Disable automatic script termination upon encountering non-zero exit code to prevent premature termination.
set +e
setCurrentStep "Post-installation validation"

check_services

check_php_version

if [ ! $nofpbx ] ; then
 check_freepbx
fi

check_asterisk

execution_time="$(($(date +%s) - start))"
message "Total script Execution Time: $execution_time"
message "Finished FreePBX 17 installation process for $host $kernel"
message "Join us on the FreePBX Community Forum: https://community.freepbx.org/ ";

if [ ! $nofpbx ] ; then
  fwconsole motd
fi

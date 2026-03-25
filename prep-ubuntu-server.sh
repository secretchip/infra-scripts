#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    echo
    echo "==> $1"
}

die() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Run this script with sudo."
    fi
}

prompt_hostname() {
    local current_hostname new_hostname
    current_hostname="$(hostnamectl --static status 2>/dev/null || hostname)"

    echo
    echo "Current hostname: ${current_hostname}"
    read -r -p "Enter new hostname: " new_hostname

    [[ -n "${new_hostname}" ]] || die "Hostname cannot be empty."

    log "Setting hostname to ${new_hostname}"
    hostnamectl set-hostname "${new_hostname}"
}

prompt_timezone() {
    local tz

    echo
    echo "Examples: Europe/Warsaw, Europe/Bucharest, UTC, America/New_York"
    echo "To browse all available timezones, run separately: timedatectl list-timezones"
    read -r -p "Enter timezone: " tz

    [[ -n "${tz}" ]] || die "Timezone cannot be empty."

    if ! timedatectl list-timezones | grep -Fxq "${tz}"; then
        die "Invalid timezone: ${tz}"
    fi

    log "Setting timezone to ${tz}"
    timedatectl set-timezone "${tz}"

    SELECTED_TIMEZONE="${tz}"
}

derive_ntp_pool() {
    local tz="$1"
    local zone_tab country_codes primary_country region region_pool country_pool
    zone_tab="/usr/share/zoneinfo/zone1970.tab"

    [[ -f "${zone_tab}" ]] || die "Cannot find ${zone_tab}"

    country_codes="$(awk -F'\t' -v tz="${tz}" '$3 == tz {print $1}' "${zone_tab}" | head -n1)"
    primary_country="${country_codes%%,*}"

    region="${tz%%/*}"
    region="$(echo "${region}" | tr '[:upper:]' '[:lower:]')"

    case "${region}" in
        europe|asia|africa|oceania|northamerica|southamerica)
            region_pool="${region}.pool.ntp.org"
            ;;
        america)
            region_pool="north-america.pool.ntp.org"
            ;;
        etc|utc)
            region_pool="pool.ntp.org"
            ;;
        *)
            region_pool="pool.ntp.org"
            ;;
    esac

    if [[ -n "${primary_country}" ]]; then
        primary_country="$(echo "${primary_country}" | tr '[:upper:]' '[:lower:]')"
        country_pool="${primary_country}.pool.ntp.org"
    else
        country_pool=""
    fi

    if [[ -n "${country_pool}" ]]; then
        NTP_SERVERS="${country_pool} 0.${region_pool} 1.${region_pool} 2.${region_pool}"
    else
        NTP_SERVERS="0.${region_pool} 1.${region_pool} 2.${region_pool} 3.${region_pool}"
    fi
}

configure_timesyncd() {
    local conf="/etc/systemd/timesyncd.conf"

    log "Configuring systemd-timesyncd with pool.ntp.org servers"
    cp -f "${conf}" "${conf}.backup-prep-script" 2>/dev/null || true

    cat > "${conf}" <<EOF
[Time]
NTP=${NTP_SERVERS}
FallbackNTP=ntp.ubuntu.com
EOF

    timedatectl set-ntp false || true
    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd
    timedatectl set-ntp true
}

install_packages() {
    log "Updating package lists"
    apt-get update -y

    log "Upgrading installed packages"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    log "Removing obsolete packages"
    apt-get autoremove -y

    log "Installing admin tools"
    apt-get install -y \
        git \
        mc \
        htop \
        nano \
        curl \
        wget \
        jq

    log "Installing DNS debugging tools"
    apt-get install -y \
        dnsutils \
        bind9-dnsutils \
        ldnsutils

    log "Installing network troubleshooting tools"
    apt-get install -y \
        net-tools \
        iproute2 \
        traceroute \
        mtr \
        tcpdump \
        nmap \
        lsof \
        ethtool \
        iputils-ping \
        iputils-tracepath \
        telnet \
        netcat-openbsd
}

show_summary() {
    echo
    echo "======================================="
    echo "Server preparation completed"
    echo
    echo "Hostname : $(hostnamectl --static status 2>/dev/null || hostname)"
    echo "Timezone : $(timedatectl show --property=Timezone --value)"
    echo "NTP      : ${NTP_SERVERS}"
    echo
    echo "timesyncd status:"
    timedatectl status || true
    echo "======================================="
}

main() {
    require_root
    prompt_hostname
    prompt_timezone
    derive_ntp_pool "${SELECTED_TIMEZONE}"
    install_packages
    configure_timesyncd
    show_summary

    log "Rebooting system"
    reboot
}

main "$@"
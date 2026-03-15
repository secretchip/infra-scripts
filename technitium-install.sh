#!/usr/bin/env bash
set -Eeuo pipefail

TEMP_RESOLV=$'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
FINAL_RESOLV=$'nameserver 127.0.0.1\n'

log(){ echo -e "\n==> $*"; }
die(){ echo -e "\nERROR: $*" >&2; exit 1; }

require_root(){
 if [[ $EUID -ne 0 ]]; then
  die "Run with sudo"
 fi
}

check_os(){
 . /etc/os-release
 [[ "$ID" == "ubuntu" ]] || die "Only Ubuntu supported"
 [[ "$VERSION_ID" == "24.04" ]] || die "Script built for Ubuntu 24.04"
 log "Detected $PRETTY_NAME"
}

backup_resolv(){
 [[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.backup-technitium ]] && \
 cp /etc/resolv.conf /etc/resolv.conf.backup-technitium
}

set_temp_dns(){
 log "Setting temporary external DNS"
 backup_resolv
 rm -f /etc/resolv.conf
 printf "%s" "$TEMP_RESOLV" >/etc/resolv.conf
}

set_local_dns(){
 log "Switching resolver to Technitium"
 rm -f /etc/resolv.conf
 printf "%s" "$FINAL_RESOLV" >/etc/resolv.conf
}

apt_update(){
 apt-get update -y
}

install_base_packages(){
 log "Installing base packages"
 DEBIAN_FRONTEND=noninteractive apt-get install -y \
 curl wget tar unzip \
 ca-certificates software-properties-common \
 apt-transport-https gnupg jq \
 dnsutils net-tools iproute2 lsof procps
}

install_qemu_agent(){
 log "Installing QEMU guest agent"
 DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent

 systemctl enable qemu-guest-agent
 systemctl start qemu-guest-agent

 systemctl is-active qemu-guest-agent >/dev/null || die "qemu-guest-agent failed to start"
}

install_dotnet(){
 log "Installing .NET runtime"

 if ! grep -Rqs dotnet/backports /etc/apt/sources.list*; then
  add-apt-repository -y ppa:dotnet/backports
 fi

 apt_update

 DEBIAN_FRONTEND=noninteractive apt-get install -y aspnetcore-runtime-9.0

 dotnet --list-runtimes
}

install_doq_dependencies(){
 log "Installing DoQ / HTTP3 dependencies"

 DEBIAN_FRONTEND=noninteractive apt-get install -y \
 libxdp1 \
 libnl-3-dev \
 libnl-route-3-dev
}

log "Installing Microsoft package repository for libmsquic"
source /etc/os-release
wget "https://packages.microsoft.com/config/$ID/$VERSION_ID/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
rm -f packages-microsoft-prod.deb

log "Updating package lists after adding Microsoft repo"
apt-get update -y

log "Installing libmsquic"
DEBIAN_FRONTEND=noninteractive apt-get install -y libmsquic

log "Installing Ubuntu 24.04 DoQ / HTTP3 dependencies"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libxdp1 \
    libnl-3-dev \
    libnl-route-3-dev

disable_conflicting_services(){
 log "Disabling services that may occupy port 53"

 systemctl disable --now systemd-resolved 2>/dev/null || true
 systemctl disable --now dnsmasq 2>/dev/null || true
}

check_port53(){
 log "Checking port 53 availability"

 if ss -lntup | grep ':53 ' ; then
  die "Port 53 is still in use"
 fi
}

install_technitium(){
 log "Running Technitium installer"
 curl -sSL https://download.technitium.com/dns/install.sh | bash
}

enable_service(){
 log "Starting Technitium DNS service"

 systemctl daemon-reload
 systemctl enable dns.service
 systemctl restart dns.service
}

verify_service(){
 log "Verifying dns.service"

 systemctl is-active dns.service >/dev/null || {
  journalctl -u dns.service -n 50
  die "dns.service failed"
 }
}

verify_ports(){
 log "Checking listening ports"

 ss -lntup | egrep ':(53|5380|853|443|53443)' || true
}

wait_for_dns(){
 log "Testing DNS via localhost"

 for i in {1..15}; do
  if dig @127.0.0.1 google.com +short | grep -q '.'; then
   return
  fi
  sleep 3
 done

 die "DNS not responding via localhost"
}

final_test(){
 log "Testing system resolver"

 getent hosts google.com >/dev/null || die "Resolver test failed"
}

summary(){
 IP=$(hostname -I | awk '{print $1}')

 echo
 echo "======================================="
 echo "Technitium installation completed"
 echo
 echo "Web interface:"
 echo "http://$IP:5380"
 echo
 echo "Service status:"
 systemctl status dns.service --no-pager
 echo
 echo "QEMU guest agent:"
 systemctl status qemu-guest-agent --no-pager
 echo
 echo "Recommended next step:"
 echo "Reboot the server to ensure all networking and services start cleanly."
 echo
 echo "Command:"
 echo "reboot"
 echo "======================================="
}

main(){
 require_root
 check_os
 set_temp_dns
 apt_update
 install_base_packages
 install_qemu_agent
 disable_conflicting_services
 check_port53
 install_dotnet
 install_doq_dependencies
 install_technitium
 enable_service
 verify_service
 verify_ports
 wait_for_dns
 set_local_dns
 final_test
 summary
}

main
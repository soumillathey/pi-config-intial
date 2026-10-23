#!/usr/bin/env bash
# ==============================================================================
# Hermes Raspberry Pi Initial Setup Script
#
# Tasks performed:
#   1. Enable Hardware UART & disable serial console (free up /dev/serial0)
#   2. Configure Ethernet (eth0 / end0) with static IP on Subnet 10 (192.168.10.50/24)
#      without disrupting default gateway (so Wi-Fi retains internet)
#   3. Set hostname to 'hermes' and configure Avahi mDNS for http://hermes.local:8080
#   4. Grant dialout/serial permissions to current user
# ==============================================================================

set -euo pipefail

# ANSI Color codes for clean output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"
}

# Ensure script is run with root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "Please run this script as root (e.g., sudo bash setup_pi.sh)"
    exit 1
fi

# Detect non-root real user (e.g., prototype, pi)
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "pi")}"
log_info "Running setup for target user: ${BOLD}${TARGET_USER}${NC}"

# Detect Raspberry Pi boot config file (Bookworm uses /boot/firmware/config.txt, older uses /boot/config.txt)
if [ -f "/boot/firmware/config.txt" ]; then
    CONFIG_TXT="/boot/firmware/config.txt"
    CMDLINE_TXT="/boot/firmware/cmdline.txt"
elif [ -f "/boot/config.txt" ]; then
    CONFIG_TXT="/boot/config.txt"
    CMDLINE_TXT="/boot/cmdline.txt"
else
    CONFIG_TXT="/boot/firmware/config.txt"
    CMDLINE_TXT="/boot/firmware/cmdline.txt"
    mkdir -p /boot/firmware
    touch "$CONFIG_TXT" "$CMDLINE_TXT"
fi

# ==============================================================================
# SECTION 1: Enable Hardware UART & Free Up Serial Port
# ==============================================================================
log_section "Step 1: Enabling Hardware UART & Configuring Serial"

# 1.1 Add enable_uart=1 to config.txt if not present
if grep -q "^enable_uart=" "$CONFIG_TXT"; then
    log_info "Updating enable_uart=1 in $CONFIG_TXT"
    sed -i 's/^enable_uart=.*/enable_uart=1/' "$CONFIG_TXT"
else
    log_info "Appending enable_uart=1 to $CONFIG_TXT"
    echo "" >> "$CONFIG_TXT"
    echo "# Enable hardware UART for Hermes scale communication" >> "$CONFIG_TXT"
    echo "enable_uart=1" >> "$CONFIG_TXT"
fi

# Ensure primary UART overlay is enabled and not conflicting with bluetooth if needed
if ! grep -q "^dtoverlay=miniuart-bt" "$CONFIG_TXT" && ! grep -q "^dtoverlay=disable-bt" "$CONFIG_TXT"; then
    log_info "Configuring UART overlay in $CONFIG_TXT"
    echo "dtoverlay=miniuart-bt" >> "$CONFIG_TXT"
fi

# 1.2 Remove Linux serial console from cmdline.txt so serial port is free for data
if [ -f "$CMDLINE_TXT" ]; then
    log_info "Checking $CMDLINE_TXT for serial console..."
    # Remove console=serial0,115200 or console=ttyAMA0,115200
    sed -i -E 's/console=(serial0|ttyAMA0|ttyS0),[0-9]+ //g' "$CMDLINE_TXT"
    sed -i -E 's/console=(serial0|ttyAMA0|ttyS0),[0-9]+//g' "$CMDLINE_TXT"
fi

# 1.3 Disable systemd serial getty service that locks the serial port
log_info "Disabling serial-getty systemd services..."
for svc in serial-getty@ttyAMA0.service serial-getty@ttyS0.service serial-getty@serial0.service; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done

# 1.4 Grant dialout and tty permissions to target user
if id "$TARGET_USER" &>/dev/null; then
    usermod -a -G dialout,tty "$TARGET_USER"
    log_success "User '$TARGET_USER' added to 'dialout' and 'tty' groups"
fi

# 1.5 Create udev rule to allow read/write access to serial devices
UDEV_RULE_FILE="/etc/udev/rules.d/99-hermes-serial.rules"
log_info "Creating udev rule for serial access in $UDEV_RULE_FILE..."
cat << 'EOF' > "$UDEV_RULE_FILE"
# Allow dialout group full read/write to USB and hardware serial devices
KERNEL=="ttyUSB[0-9]*", MODE="0666", GROUP="dialout"
KERNEL=="ttyACM[0-9]*", MODE="0666", GROUP="dialout"
KERNEL=="ttyAMA[0-9]*", MODE="0666", GROUP="dialout"
KERNEL=="serial0", MODE="0666", GROUP="dialout"
KERNEL=="serial1", MODE="0666", GROUP="dialout"
EOF
udevadm control --reload-rules && udevadm trigger || true

log_success "UART port enabled and serial access configured."

# ==============================================================================
# SECTION 2: Subnet 10 Configuration for Camera Access (192.168.10.250)
# ==============================================================================
log_section "Step 2: Configuring Ethernet for Subnet 10 (192.168.10.x)"

# Detect ethernet interface (typically eth0 on Pi 3/4 or end0 on Pi 5)
ETH_IFACE=""
for iface in eth0 end0 eth1; do
    if ip link show "$iface" &>/dev/null; then
        ETH_IFACE="$iface"
        break
    fi
done

if [ -z "$ETH_IFACE" ]; then
    log_warning "No active physical ethernet interface detected right now (eth0/end0). Defaulting to 'eth0'."
    ETH_IFACE="eth0"
else
    log_info "Detected Ethernet interface: ${BOLD}${ETH_IFACE}${NC}"
fi

PI_CAM_SUBNET_IP="192.168.10.50/24"
CAMERA_IP="192.168.10.250"

# Check whether NetworkManager or dhcpcd is in use
if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
    log_info "NetworkManager is active. Configuring via nmcli..."

    CON_NAME="Camera-ETH-Subnet10"
    
    # Check if a connection for this interface already exists
    EXISTING_CON=$(nmcli -t -f NAME,DEVICE con show | grep ":${ETH_IFACE}$" | cut -d: -f1 | head -n1 || true)
    
    if [ -n "$EXISTING_CON" ]; then
        log_info "Modifying existing connection '$EXISTING_CON' on $ETH_IFACE..."
        # Assign static IP on subnet 10 without taking over default gateway
        nmcli con mod "$EXISTING_CON" \
            ipv4.addresses "$PI_CAM_SUBNET_IP" \
            ipv4.method manual \
            ipv4.never-default true \
            connection.autoconnect yes
        nmcli con up "$EXISTING_CON" || true
    else
        log_info "Creating new NetworkManager profile '$CON_NAME' on $ETH_IFACE..."
        nmcli con add type ethernet \
            con-name "$CON_NAME" \
            ifname "$ETH_IFACE" \
            ip4 "$PI_CAM_SUBNET_IP" \
            ipv4.method manual \
            ipv4.never-default true \
            connection.autoconnect yes
        nmcli con up "$CON_NAME" || true
    fi

elif [ -f "/etc/dhcpcd.conf" ]; then
    log_info "Legacy dhcpcd detected. Configuring /etc/dhcpcd.conf..."
    
    # Remove any existing config block for this interface
    sed -i "/# BEGIN HERMES CAMERA SUBNET/,/# END HERMES CAMERA SUBNET/d" /etc/dhcpcd.conf
    
    cat << EOF >> /etc/dhcpcd.conf
# BEGIN HERMES CAMERA SUBNET
interface $ETH_IFACE
static ip_address=$PI_CAM_SUBNET_IP
nogateway
# END HERMES CAMERA SUBNET
EOF
    systemctl restart dhcpcd || true
else
    log_info "Configuring network interface directly via iproute2 and systemd-networkd / interfaces..."
    ip addr add "$PI_CAM_SUBNET_IP" dev "$ETH_IFACE" 2>/dev/null || true
    ip link set "$ETH_IFACE" up 2>/dev/null || true
fi

# Ensure direct route exists for 192.168.10.0/24 over ethernet
ip route replace 192.168.10.0/24 dev "$ETH_IFACE" scope link 2>/dev/null || true

log_success "Ethernet assigned ${PI_CAM_SUBNET_IP}. Pi can now communicate directly with camera at ${CAMERA_IP}."
log_info "(Default gateway on Wi-Fi was preserved so internet access is NOT lost)"

# ==============================================================================
# SECTION 3: Hostname & Avahi mDNS Setup for http://hermes.local:8080
# ==============================================================================
log_section "Step 3: Setting Hostname to 'hermes' & Enabling Avahi mDNS"

NEW_HOSTNAME="hermes"
CURRENT_HOSTNAME=$(hostname)

# 3.1 Update hostname
if [ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    log_info "Changing system hostname from '$CURRENT_HOSTNAME' to '$NEW_HOSTNAME'..."
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME" 2>/dev/null || true
fi

# 3.2 Update /etc/hosts so local resolution is fast and error-free
log_info "Updating /etc/hosts..."
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
    echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi

# 3.3 Install and configure Avahi daemon for mDNS (.local domains)
log_info "Installing and configuring avahi-daemon..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq avahi-daemon avahi-utils libnss-mdns

# Ensure avahi config permits IPv4 and sets host-name
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"
if [ -f "$AVAHI_CONF" ]; then
    sed -i 's/^#host-name=.*/host-name=hermes/' "$AVAHI_CONF"
    sed -i 's/^use-ipv4=.*/use-ipv4=yes/' "$AVAHI_CONF"
fi

# 3.4 Create Avahi service advertisement for Hermes Config Web Portal (port 8080)
AVAHI_SERVICES_DIR="/etc/avahi/services"
mkdir -p "$AVAHI_SERVICES_DIR"
cat << 'EOF' > "$AVAHI_SERVICES_DIR/hermes-http.service"
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Hermes Diagnostics &amp; Config Portal</name>
  <service>
    <type>_http._tcp</type>
    <port>8080</port>
    <txt-record>path=/config</txt-record>
  </service>
</service-group>
EOF

# 3.5 Restart and enable Avahi daemon
systemctl enable avahi-daemon
systemctl restart avahi-daemon

# 3.6 If ufw firewall is active, allow ports 8080 (web) and 5353 (mDNS)
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log_info "Adjusting firewall rules..."
    ufw allow 8080/tcp comment "Hermes Config Web Portal" || true
    ufw allow 5353/udp comment "mDNS Multicast" || true
fi

log_success "mDNS enabled! Devices on same Wi-Fi/Hotspot can access via: http://hermes.local:8080"

# ==============================================================================
# SUMMARY & NEXT STEPS
# ==============================================================================
echo ""
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}         HERMES INITIAL SETUP COMPLETED SUCCESSFULLY!           ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo ""
echo -e "  ${BOLD}1. Hardware UART:${NC} Enabled on GPIO (/dev/serial0). Serial console detached."
echo -e "  ${BOLD}2. Camera Subnet:${NC} Ethernet configured at ${CYAN}${PI_CAM_SUBNET_IP}${NC}"
echo -e "                    Target camera reachable at: ${CYAN}http://${CAMERA_IP}${NC}"
echo -e "  ${BOLD}3. Local Access:${NC}  Access the config portal on your phone/laptop at:"
echo -e "                    ${BOLD}${GREEN}http://hermes.local:8080/config${NC}"
echo -e "                    ${YELLOW}(Note: Use http://, NOT https://)${NC}"
echo ""
echo -e "${BOLD}${YELLOW}[ACTION REQUIRED]${NC} A reboot is recommended to apply UART & kernel overlays."
read -p "Would you like to reboot now? [y/N]: " REBOOT_CHOICE || REBOOT_CHOICE="n"
case "$REBOOT_CHOICE" in
    [yY][eE][sS]|[yY])
        echo -e "${GREEN}Rebooting now...${NC}"
        reboot
        ;;
    *)
        echo -e "${CYAN}Please remember to reboot later using: sudo reboot${NC}"
        ;;
esac

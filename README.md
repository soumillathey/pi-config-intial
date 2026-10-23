# Hermes Raspberry Pi Initial Setup Guide

This script automates the full one-time initial provisioning of your Raspberry Pi for Hermes:
1. **Hardware UART Enablement**: Enables the hardware serial port, frees it from the Linux serial login console, grants non-root serial permissions, and generates udev rules for `/dev/ttyUSB*` and `/dev/serial0`.
2. **Subnet 10 Camera Network Routing**: Assigns static IP `192.168.10.50/24` to the physical Ethernet port (`eth0`/`end0`) so the Pi can directly talk to your camera at `192.168.10.250`, without hijacking your default gateway (keeping Wi-Fi internet alive).
3. **mDNS & Hostname Setup**: Sets hostname to `hermes` and configures `avahi-daemon` to broadcast `hermes.local`, allowing you to open `http://hermes.local:8080` or `http://hermes.local:8080/config` on your phone or laptop.

---

## 🚀 How to Run on the Pi via GitHub

### Method 1: Fast 1-Liner (Recommended for Fresh Pi)
Run this single command directly in your Pi terminal without needing to clone the repository:
```bash
curl -sSL https://raw.githubusercontent.com/soumillathey/pi-config-intial/main/setup_pi.sh | sudo bash
```
*(Or with `wget`):*
```bash
wget -qO- https://raw.githubusercontent.com/soumillathey/pi-config-intial/main/setup_pi.sh | sudo bash
```

---

### Method 2: Git Clone
```bash
git clone https://github.com/soumillathey/pi-config-intial.git
cd pi-config-intial
sudo bash setup_pi.sh
```

---

## 📱 Accessing from Phone Browser

Once the Pi reboots:

1. **Connect your phone** to the same Wi-Fi network as the Pi (or connect to the Hermes emergency hotspot `hermes` / password `12345678`).
2. Open your phone's browser (Safari or Chrome).
3. Type in the address bar:
   ```text
   http://hermes.local:8080/config
   ```

> [!IMPORTANT]
> **Always type `http://` explicitly, NOT `https://`!**
> Modern mobile browsers default to `https://`. Since the internal diagnostics server runs on HTTP, typing `hermes.local:8080` without `http://` might fail to load.

---

## 🔍 Verification Commands on the Pi

To verify everything is active after reboot:

- **Check UART**:
  ```bash
  ls -l /dev/serial0 /dev/ttyUSB* 2>/dev/null
  ```
- **Check Subnet 10 Ethernet IP**:
  ```bash
  ip addr show eth0
  # Test pinging the camera:
  ping -c 3 192.168.10.250
  ```
- **Check Hostname & Avahi mDNS**:
  ```bash
  hostname
  systemctl status avahi-daemon --no-pager
  ```

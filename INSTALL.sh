#!/bin/bash
set -euo pipefail

# --- helper: require root ---
if [[ $EUID -ne 0 ]]; then
  echo "[INSTALL] This script needs sudo. Re-running as root..."
  exec sudo -E bash "$0" "$@"
fi

# --- detect the target user (the person who invoked sudo) ---
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
TARGET_HOME=$(eval echo ~"${TARGET_USER}")

ETC_DIR="/etc/sdrsync"
SYSTEMD_UNIT="/etc/systemd/system/sdrsync.service"
ENV_FILE="${ETC_DIR}/sdrsync.env"
WRAPPER_DST="${ETC_DIR}/sdrsync.sh"
SYNC_DST="${ETC_DIR}/sync.py"

# --- source paths (relative to repo folder where this script lives) ---
REPO_DIR="$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 ; pwd -P)"
WRAPPER_SRC="${REPO_DIR}/sdrsync.sh"
SERVICE_SRC="${REPO_DIR}/sdrsync.service"  # will be regenerated below
SYNC_SRC="${REPO_DIR}/sync.py"

# --- create target dir ---
mkdir -p "${ETC_DIR}"

# --- copy wrapper & python ---
install -m 755 "${WRAPPER_SRC}" "${WRAPPER_DST}"
if [[ -f "${SYNC_SRC}" ]]; then
  install -m 644 "${SYNC_SRC}" "${SYNC_DST}"
else
  echo "[INSTALL] WARNING: ${SYNC_SRC} not found; skipping copy. Place your sync.py at ${SYNC_DST} later."
fi

# --- install dependencies ---
apt-get update -y
apt-get install -y git build-essential cmake libusb-1.0-0-dev pkg-config netcat-openbsd

# --- purge old librtlsdr/rtl-sdr installs to avoid conflicts ---
echo "[INSTALL] Purging any previous librtlsdr/rtl-sdr packages and headers..."
apt-get purge -y '^librtlsdr' 'rtl-sdr' || true
rm -rf /usr/lib/librtlsdr* /usr/include/rtl-sdr* /usr/local/lib/librtlsdr* \
       /usr/local/include/rtl-sdr* /usr/local/include/rtl_* /usr/local/bin/rtl_* || true

# --- build & install RTL-SDR Blog v4 drivers (librtlsdr) ---
# This provides rtl_tcp compatible with RTL-SDR Blog v4 dongles.
if ! command -v rtl_tcp >/dev/null 2>&1; then
  echo "[INSTALL] Building RTL-SDR Blog drivers..."
  SRC_DIR="/usr/local/src/rtl-sdr-blog"
  if [[ ! -d "$SRC_DIR" ]]; then
    git clone --depth=1 https://github.com/rtlsdrblog/rtl-sdr-blog.git "$SRC_DIR"
  else
    (cd "$SRC_DIR" && git pull --ff-only || true)
  fi
  mkdir -p "$SRC_DIR/build"
  cd "$SRC_DIR/build"
  # Install udev rules during build per upstream instructions
  cmake .. -DINSTALL_UDEV_RULES=ON -DDETACH_KERNEL_DRIVER=ON
  make -j"$(nproc)"
  make install
  # If rules didn't copy, do it explicitly
  if [[ -f ../rtl-sdr.rules ]]; then
    install -m 644 ../rtl-sdr.rules /etc/udev/rules.d/
  fi
  ldconfig

  # Blacklist conflicting DVB-T drivers
  echo 'blacklist dvb_usb_rtl28xxu' | tee /etc/modprobe.d/blacklist-dvb_usb_rtl28xxu.conf >/dev/null
  # Refresh initramfs if available
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || true
  fi
  # Reload udev rules so devices are usable without reboot
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger || true
  fi
  cd "$REPO_DIR"
else
  echo "[INSTALL] rtl_tcp already present: $(command -v rtl_tcp)"
fi

# --- install wfview ---
echo "[INSTALL] Installing wfview using official build script..."
WFVIEW_BUILD_SCRIPT_URL="https://gitlab.com/eliggett/scripts/-/raw/master/fullbuild-wfview.sh"
WFVIEW_BUILD_SCRIPT_PATH="/tmp/fullbuild-wfview.sh"
curl -fsSL "$WFVIEW_BUILD_SCRIPT_URL" -o "$WFVIEW_BUILD_SCRIPT_PATH"
chmod +x "$WFVIEW_BUILD_SCRIPT_PATH"
# Run the build script as the target user to build and install wfview system-wide
sudo -u "$TARGET_USER" "$WFVIEW_BUILD_SCRIPT_PATH"

# --- detect binaries ---
# If WFVIEW_BIN was set earlier (e.g., Flatpak), preserve it; else detect a binary path
if [[ -z "${WFVIEW_BIN:-}" ]]; then
  WFVIEW_BIN="$(command -v wfview || true)"
  [[ -z "$WFVIEW_BIN" ]] && WFVIEW_BIN="/usr/local/bin/wfview"
fi
RTL_TCP_BIN="$(command -v rtl_tcp || true)"; [[ -z "$RTL_TCP_BIN" ]] && RTL_TCP_BIN="/usr/local/bin/rtl_tcp"
PYTHON_BIN="$(command -v python3 || true)"; [[ -z "$PYTHON_BIN" ]] && PYTHON_BIN="/usr/bin/python3"


# --- write env file (editable by user) ---
cat > "${ENV_FILE}" <<EOF
# sdrsync environment configuration
SDRSYNC_USER=${TARGET_USER}
SDRSYNC_DISPLAY=:0
WFVIEW_BIN=${WFVIEW_BIN}
RTL_TCP_BIN=${RTL_TCP_BIN}
PYTHON_BIN=${PYTHON_BIN}
SYNC_PY=${SYNC_DST}
WF_PORT=4533
SDR_PORT=14423
# Extra args for rtl_tcp if needed (space-separated)
RTL_TCP_EXTRA_ARGS="-a 0.0.0.0"
# Sync script environment variables
WF_HOST=127.0.0.1
SDR_HOST=127.0.0.2

EOF
chmod 644 "${ENV_FILE}"

# --- write systemd unit (system-level) ---
cat > "${SYSTEMD_UNIT}" <<'UNIT'
[Unit]
Description=wfview + rtl_tcp + bidirectional sync
After=graphical.target network-online.target systemd-user-sessions.service display-manager.service
Wants=graphical.target network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/sdrsync/sdrsync.env
# Delay to ensure desktop/X and audio stack are ready
ExecStartPre=/bin/sleep 30
ExecStart=/etc/sdrsync/sdrsync.sh
KillMode=control-group
TimeoutStopSec=10
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 "${SYSTEMD_UNIT}"
chmod +700 /run/user/1000/


# --- reload & enable ---
systemctl daemon-reload
systemctl enable sdrsync.service
systemctl restart sdrsync.service || true

# --- summary ---
echo "\n[INSTALL] Done. Files installed:"
echo "  - ${WRAPPER_DST} (runner)"
echo "  - ${ENV_FILE} (edit this to change user/paths/ports)"
echo "  - ${SYSTEMD_UNIT} (systemd unit)"
[[ -f "${SYNC_DST}" ]] && echo "  - ${SYNC_DST} (sync script)"

echo "\nManage service with:"
echo "  sudo systemctl status sdrsync.service"
echo "  sudo systemctl restart sdrsync.service"
echo "  sudo journalctl -u sdrsync.service -f"

echo "\nNOTE: If this is your first RTL-SDR Blog v4 install, a reboot is recommended so the DVB-T kernel module blacklist takes effect."

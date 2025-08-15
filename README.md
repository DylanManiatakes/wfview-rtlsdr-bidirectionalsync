


# SDRSync

**SDRSync** is an automated setup for synchronizing frequencies between [wfview](https://wfview.org/) and an RTL-SDR receiver over `rtl_tcp`.  
It installs all required dependencies (including RTL-SDR Blog v4 drivers and wfview), configures a systemd service, and runs three processes together:

1. **rtl_tcp** – Serves your RTL-SDR dongle over the network.
2. **wfview** – Provides rig control and CAT interface.
3. **sync.py** – Keeps frequencies in sync between wfview and your SDR software.

---

## 📦 Features
- Automatic installation of RTL-SDR Blog v4 drivers.
- Automatic build and install of wfview using the official build script.
- Configurable via `/etc/sdrsync/sdrsync.env`.
- System-level service (`sdrsync.service`) that starts on boot.
- Handles proper start order and delays for stable operation.

---

## 🛠 Installation

Run the following commands on your Raspberry Pi or Debian-based system:

```bash
git clone https://github.com/DylanManiatakes/SDRSync---IC7100-Panadapter
mv SDRSync---IC7100-Panadapter SDRSync
cd SDRSync
chmod +x INSTALL.sh
./INSTALL.sh
```

The installer will:
- Detect your username automatically.
- Install build dependencies.
- Install RTL-SDR Blog v4 drivers (with DVB-T blacklist).
- Build and install wfview from source.
- Install SDRSync to `/etc/sdrsync`.
- Set up and enable the systemd service.

---

## ⚙ Configuration

After installation, you can edit:

```bash
sudo nano /etc/sdrsync/sdrsync.env
```

Key variables:
- `SDRSYNC_USER` – User account that runs wfview and the sync script.
- `WFVIEW_BIN` – Path to wfview binary.
- `RTL_TCP_BIN` – Path to rtl_tcp binary.
- `PYTHON_BIN` – Path to python3 binary.
- `WF_PORT` – wfview rigctl port (default `4533`).
- `RTL_PORT` – rtl_tcp port (default `14423`).
- `RTL_TCP_EXTRA_ARGS` – Additional rtl_tcp options.

---

## ▶ Managing the Service

Start SDRSync:
```bash
sudo systemctl start sdrsync.service
```

Stop SDRSync:
```bash
sudo systemctl stop sdrsync.service
```

Restart SDRSync:
```bash
sudo systemctl restart sdrsync.service
```

Check status:
```bash
sudo systemctl status sdrsync.service
```

View logs:
```bash
sudo journalctl -u sdrsync.service -f
```

---

## 🔄 Updating
To update SDRSync:
```bash
cd SDRSync
git pull
chmod +x INSTALL.sh
./INSTALL.sh
```

---

## 🖥 Requirements
- Raspberry Pi OS, Debian, Ubuntu, or other Debian-based distro.
- RTL-SDR Blog v4 dongle.
- Internet connection for installation.
- Android Tablet with SDR++ Installed

---

## 📜 License
MIT License – You may freely use, modify, and distribute this project.

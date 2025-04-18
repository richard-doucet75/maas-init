# MAAS Bootstrap Script (Gold Standard v3)

This script automates a clean, repeatable setup of MAAS (Metal as a Service) using PostgreSQL and NGINX on Ubuntu 24.04. It's built to reflect production-like patterns while keeping things simple and transparent.

## 🔧 Features

- 💣 Cleans any previous MAAS and PostgreSQL install
- 📦 Installs PostgreSQL 16 and MAAS 3.6 from Snap
- 🧑 Creates PostgreSQL role/database for MAAS
- 🌐 Configures NGINX reverse proxy (MAAS accessible at `http://maas.jaded/`)
- 🚦 Initializes MAAS with full non-interactive setup
- 🧹 Automatically handles Snap state wipe and directory recreation to prevent known startup crashes

## ✅ Fixes / Improvements in v3

- Replaces old `systemctl stop snap.maas.supervisor.service` with `snap stop maas`
- Ensures the required `/var/snap/maas/common/maas/image-storage/bootloaders` directory exists (fixes `FileNotFoundError`)
- Script works cleanly on MAAS 3.6 + Ubuntu 24.04 (noble)

## 📋 Requirements

- Ubuntu 24.04 LTS (tested)
- Internet access (for Snap & APT installs)
- Sudo privileges

## 🚀 Usage

Make it executable:

```bash
chmod +x bootstrap-maas.sh

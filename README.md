# MAAS Bootstrap Script

This script automates the full setup of a clean MAAS (Metal as a Service) environment with a manually configured PostgreSQL database and NGINX reverse proxy.

## Features

✅ Cleans up any previous MAAS and PostgreSQL installations  
✅ Installs and configures PostgreSQL manually (no `maas-test-db`)  
✅ Installs MAAS from Snap  
✅ Creates PostgreSQL database and user  
✅ Configures MAAS with a proper database URI  
✅ Sets up NGINX as a reverse proxy for cleaner URLs (`http://maas.jaded/MAAS/`)  
✅ Updates `/etc/hosts` with a chosen or detected IP  
✅ Runs non-interactive `maas init`  
✅ Creates an MAAS admin user

## Requirements

- Ubuntu 22.04 or 24.04 LTS
- Run as a user with `sudo` privileges
- Clean install is recommended

## Usage

```bash
./bootstrap-maas.sh

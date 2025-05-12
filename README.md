i# MAAS Bootstrap Scripts

This repository contains a modular, script-based workflow for fully installing, configuring, and launching [MAAS](https://maas.io/) (Metal as a Service) using Ubuntu Snap packages and PostgreSQL.

---

## 🚀 Features

* Interactive `.env` configuration
* Secure runtime password prompts
* Modular scripts for:

  * PostgreSQL setup
  * MAAS initialization
  * Network + DHCP config
  * Admin user creation
  * Reverse proxy setup (Nginx)
* Clean, repeatable automation
* MIT Licensed (see `LICENSE`)

---

## 🔧 Setup Instructions

1. **Clone the repo** (excluding private `.env`):

   ```bash
   git clone https://github.com/your-username/maas-init.git
   cd maas-init
   ```

2. **Run the bootstrap process**:

   ```bash
   ./bootstrap-maas.sh
   ```

3. **Follow the prompts** to:

   * Wipe an existing install (optional)
   * Configure network and subnet details
   * Supply admin and DB passwords (not stored)

4. **Access MAAS**:

   * URL: `http://<your-ip>`
   * Username: `admin`
   * Password: (what you entered at install time)

---

## 📁 Directory Overview

| File                 | Purpose                               |
| -------------------- | ------------------------------------- |
| `bootstrap-maas.sh`  | Full setup orchestrator               |
| `configure.sh`       | Interactive config for `.env`         |
| `install.sh`         | Installs MAAS and PostgreSQL          |
| `login.sh`           | Logs into the MAAS CLI using API key  |
| `finalize.sh`        | Finalizes MAAS settings via CLI       |
| `dhcp_setup.sh`      | Fabric + VLAN + Subnet + DHCP setup   |
| `remove-snippets.sh` | Deletes old DHCP snippets (optional)  |
| `proxy.sh`           | Nginx reverse proxy for web access    |
| `.gitignore`         | Excludes `.env`, keys, and temp files |
| `LICENSE`            | MIT License                           |

---

## 🔐 Security

* `.env` is excluded from Git and should be stored **privately**
* Passwords are prompted at runtime and never written to disk

---

## 🥪 Requirements

* Ubuntu 22.04+ or 24.04+
* Snap support
* Internet access for image imports
* `jq`, `curl`, and `nginx` (installed automatically if missing)

---

## 👤 Author

Richard Doucet
MIT License © 2025

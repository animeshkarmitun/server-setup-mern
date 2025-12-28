# EC2 Deployment Script (API-First → Optional MERN)

This document explains how to **create and maintain** a fault-tolerant deployment script for an EC2 instance that:

- Starts as **Node / Express (API-only)** by default
- Detects a **React frontend after cloning the repo**
- Asks whether to **upgrade to MERN** (frontend build + static hosting + `/api` proxy)
- Generates a **GitHub SSH deploy key**, waits for you to add it, then clones the repo
- Is **idempotent** (safe to re-run)
- Supports **step jumping** (`--from N`)
- Collects **all configuration via prompts at startup**

Target OS: **Ubuntu 20.04 / 22.04**

---

## 1. Overall Behavior

### Default (API-only)
1. Install system dependencies
2. Install Node.js + PM2
3. Create GitHub deploy key
4. Clone backend repo
5. Install backend dependencies
6. Configure Nginx as reverse proxy to backend
7. Run backend with PM2

### Optional MERN Upgrade
After the repo is cloned:
- Script detects React / Vite / CRA / Next.js frontend
- Prompts:
  > “React detected — enable MERN setup?”
- If **yes**:
  - Builds frontend
  - Serves frontend via Nginx
  - Proxies `/api` to backend

---

## 2. Key Design Principles

- **API-first**: MERN is optional, never forced
- **Idempotent**:
  - Skips installing tools already present
  - Skips builds if output exists
  - Restarts PM2 if process exists
- **Fault-tolerant**:
  - Stops only on critical failures
  - Can resume from any step
- **Interactive**:
  - Prompts for config at the start
  - MERN decision happens after repo detection
- **Safe GitHub access**:
  - Uses deploy keys (no personal tokens)

---

## 3. Step Layout (Stable Contract)

Steps are numbered and should not be reordered:

1. System update
2. Base packages (`git`, `curl`, `build-essential`, `openssh-client`)
3. Nginx + optional UFW
4. Node.js via NVM (LTS)
5. PM2
6. GitHub setup + clone/pull + React detection + MERN toggle
7. Backend dependencies
8. Frontend build (only if MERN enabled)
9. Nginx configuration
10. PM2 start + startup on reboot

### Step Jumping
Run from any step:
```bash
bash deploy-auto.sh --from 6
```

List steps:
```bash
bash deploy-auto.sh --steps
```

---

## 4. Configuration Prompts (Shown at Start)

The script prompts for:

- App mode: `auto | api | mern` (default: auto)
- GitHub repo URL (SSH preferred)
- Branch
- App directory
- App name
- Backend folder, entry file, port, start method
- Frontend folder + build directory (used only if MERN enabled)
- Nginx + UFW enable/disable
- SSH deploy key path + label
- Whether to wait for deploy key to be added

> MERN enable prompt appears **after repo detection**, not at startup.

---

## 5. GitHub Deploy Key Flow (Step 6)

1. Script asks for GitHub repo link
2. Creates SSH deploy key if missing:
   ```bash
   ~/.ssh/deploy_key_<app_name>
   ```
3. Prints the **public key**
4. Pauses:
   ```text
   Press ENTER after you add the deploy key to GitHub...
   ```
5. You add the key in:
   - GitHub → Repo → Settings → Deploy Keys
6. Script resumes and clones repo using the key

> HTTPS repos will prompt you to switch to SSH.

---

## 6. React Frontend Detection

After cloning, the script checks:
- `client/package.json` exists
- Contains any of:
  - `react`
  - `react-dom`
  - `react-scripts`
  - `vite`
  - `@vitejs/plugin-react`
  - `next`

If detected and `APP_MODE=auto`, it asks:
```
React detected — enable MERN setup?
```

---

## 7. Nginx Modes

### API-only (Reverse Proxy)
```
/ → backend
```

### MERN
```
/      → React build
/api   → backend
```

IP-based access uses:
```nginx
server_name _;
```
Domain can be added later without changing the script.

---

## 8. PM2 Startup Modes

Supported backend start styles:
- **File**
  ```bash
  pm2 start index.js
  ```
- **NPM**
  ```bash
  pm2 start npm -- start
  ```

Environment:
```bash
PORT=<configured_port>
NODE_ENV=production
```

PM2 startup enabled via:
```bash
pm2 save
pm2 startup systemd
```

---

## 9. Supported Project Layouts

### API-Only
```
repo/
  package.json
  index.js
```

or

```
repo/
  server/
    package.json
    index.js
```

### MERN
```
repo/
  server/
    package.json
  client/
    package.json
```

---

## 10. Common Commands

Initial deploy:
```bash
bash deploy-auto.sh
```

Resume from GitHub setup:
```bash
bash deploy-auto.sh --from 6
```

Resume from Nginx config:
```bash
bash deploy-auto.sh --from 9
```

---

## 11. Troubleshooting

### Git clone fails (publickey)
- Ensure SSH repo URL
- Ensure deploy key added to GitHub
- Resume from step 6

### Site not loading
- Check nginx:
  ```bash
  sudo nginx -t
  sudo systemctl reload nginx
  ```

### Backend not running
```bash
pm2 status
pm2 logs <app_name>
```

---

## 12. Future Extensions

- HTTPS via Certbot
- `.env` management
- MongoDB Atlas integration
- GitHub Enterprise support
- Auto-detect frontend build output
- Auto-detect backend entry file

---

## Summary

This script provides a **safe, repeatable, and flexible** EC2 deployment workflow that works for:
- API-only Node apps
- Full MERN stacks
- Early IP-only setups that later move to domains

It is designed to grow with the project without forcing architectural decisions too early.

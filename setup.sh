#!/usr/bin/env bash
set -Eeuo pipefail

FROM_STEP=1

log()  { echo -e "\n==> $*"; }
warn() { echo -e "\n[WARN] $*" >&2; }
die()  { echo -e "\n[ERROR] $*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local var="$1" msg="$2" def="${3:-}" input=""
  if [ -n "$def" ]; then
    read -r -p "$msg [$def]: " input
    input="${input:-$def}"
  else
    read -r -p "$msg: " input
  fi
  export "$var"="$input"
}

prompt_yn() {
  local var="$1" msg="$2" def="${3:-y}" input=""
  read -r -p "$msg (y/n) [$def]: " input
  input="${input:-$def}"
  input="$(echo "$input" | tr '[:upper:]' '[:lower:]')"
  if [[ "$input" =~ ^y ]]; then export "$var"="y"; else export "$var"="n"; fi
}

step_enabled() { local s="$1"; (( s >= FROM_STEP )); }

show_steps() {
  cat <<'EOF'
Steps:
  1) System update (apt update/upgrade)
  2) Install base packages (git, curl, build-essential, openssh-client)
  3) Install/enable Nginx (and UFW optional)
  4) Install Node (nvm + Node LTS)
  5) Install PM2
  6) GitHub setup: ask repo link, create SSH key (optional), wait for you to add key, clone/pull, detect React, ask MERN enable
  7) Install backend deps
  8) Install/build frontend (only if MERN enabled)
  9) Configure Nginx (API reverse proxy OR MERN static + /api proxy)
 10) Start/Restart backend with PM2 + startup on reboot

Usage:
  bash deploy-auto.sh
  bash deploy-auto.sh --from 6
  bash deploy-auto.sh --steps
EOF
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "$pkg already installed. Skipping."
  else
    log "Installing $pkg..."
    sudo apt-get update -y
    sudo apt-get install -y "$pkg"
  fi
}

ensure_dir_owner() {
  local dir="$1"
  sudo mkdir -p "$dir"
  sudo chown -R "$USER":"$USER" "$dir"
}

source_nvm_if_present() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
}

# -------- args --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) shift; FROM_STEP="${1:-1}" ;;
    --steps) show_steps; exit 0 ;;
    *) warn "Unknown arg: $1" ;;
  esac
  shift || true
done

# -------- prompts at start --------
echo "Auto deploy (API-first, offers MERN if React detected) — step-jump with --from N (current: $FROM_STEP)"
echo "-----------------------------------------------------------------------------------------------"

prompt APP_MODE "Mode: auto/api/mern (auto = detect React after clone)" "auto"

# GitHub setup prompts (repo link asked at start as you requested)
prompt REPO_URL "GitHub repo link (SSH preferred: git@github.com:org/repo.git)" ""
prompt BRANCH   "Git branch to deploy" "main"
prompt APP_DIR  "Install path on server" "/var/www/app"
prompt APP_NAME "PM2/Nginx app name" "app"

# SSH key behavior
prompt_yn USE_SSH_KEY     "Use SSH deploy key for GitHub access?" "y"
prompt SSH_KEY_PATH       "SSH key path (private key file)" "$HOME/.ssh/deploy_key_${APP_NAME}"
prompt SSH_KEY_COMMENT    "SSH key comment label" "${APP_NAME}@$(hostname)"
prompt_yn WAIT_FOR_KEY    "Pause and wait for you to add the key in GitHub?" "y"

# Backend settings
prompt SERVER_DIR     "Backend folder (relative to repo root; '.' if root)" "server"
prompt SERVER_ENTRY   "Backend entry (file or npm script target)" "index.js"
prompt START_METHOD   "Backend start method: file or npm" "file"
prompt SERVER_PORT    "Backend internal port (Express listens here)" "5000"

# Frontend defaults (used only if MERN enabled)
prompt CLIENT_DIR        "Frontend folder (relative to repo root)" "client"
prompt CLIENT_BUILD_DIR  "Frontend build output dir (CRA=build, Vite=dist)" "build"

prompt SERVER_NAME "Nginx server_name (use '_' for IP; later set domain)" "_"
prompt_yn ENABLE_NGINX "Configure Nginx?" "y"
prompt_yn ENABLE_UFW   "Enable UFW firewall?" "y"
prompt_yn SKIP_UPGRADE "Skip 'apt upgrade'?" "n"

# Optional express scaffolding if MERN enabled but backend missing
prompt_yn OFFER_EXPRESS "If MERN enabled and backend missing, offer to scaffold Express?" "y"

echo ""
log "Summary (initial)"
echo " Mode:        $APP_MODE"
echo " Repo:        $REPO_URL (branch: $BRANCH)"
echo " App dir:     $APP_DIR"
echo " SSH key:     $USE_SSH_KEY (path: $SSH_KEY_PATH)"
echo " Backend:     $SERVER_DIR | entry=$SERVER_ENTRY | start=$START_METHOD | port=$SERVER_PORT"
echo " Frontend:    $CLIENT_DIR | build=$CLIENT_BUILD_DIR (only if MERN enabled)"
echo " Nginx:       $ENABLE_NGINX | server_name=$SERVER_NAME"
echo " Start step:  $FROM_STEP"
echo ""

trap 'warn "Failed near line $LINENO. Resume with: bash deploy-auto.sh --from <step>."' ERR

# ============================================================
# Detection helpers
# ============================================================
frontend_detected="n"
MERN_ENABLED="n"

detect_react_frontend() {
  local pkg="$APP_DIR/$CLIENT_DIR/package.json"
  if [ ! -f "$pkg" ]; then
    frontend_detected="n"; return 0
  fi
  if grep -Eq '"react"\s*:' "$pkg" \
    || grep -Eq '"react-dom"\s*:' "$pkg" \
    || grep -Eq '"react-scripts"\s*:' "$pkg" \
    || grep -Eq '"vite"\s*:' "$pkg" \
    || grep -Eq '"@vitejs/plugin-react"\s*:' "$pkg" \
    || grep -Eq '"next"\s*:' "$pkg"; then
    frontend_detected="y"
  else
    frontend_detected="n"
  fi
}

maybe_enable_mern() {
  if [[ "$APP_MODE" == "mern" ]]; then MERN_ENABLED="y"; return 0; fi
  if [[ "$APP_MODE" == "api"  ]]; then MERN_ENABLED="n"; return 0; fi

  # auto mode
  if [[ "$frontend_detected" == "y" ]]; then
    log "React-like frontend detected in '$CLIENT_DIR/'."
    prompt_yn MERN_ENABLED "Enable MERN steps? (build frontend + Nginx static + /api proxy)" "y"
  else
    MERN_ENABLED="n"
  fi
}

ensure_backend_exists_or_offer_express() {
  local backend_path="$APP_DIR/$SERVER_DIR"
  [ "$SERVER_DIR" == "." ] && backend_path="$APP_DIR"

  if [ -d "$backend_path" ] && [ -f "$backend_path/package.json" ]; then
    return 0
  fi

  if [[ "$MERN_ENABLED" == "y" && "$OFFER_EXPRESS" == "y" ]]; then
    warn "Backend folder/package.json not found at: $backend_path"
    prompt_yn DO_SCAFFOLD "Scaffold a minimal Express backend now?" "n"
    if [[ "$DO_SCAFFOLD" == "y" ]]; then
      mkdir -p "$backend_path"
      cd "$backend_path"
      [ -f package.json ] || npm init -y
      npm install express

      if [ ! -f "$backend_path/index.js" ]; then
        cat > "$backend_path/index.js" <<'EOF'
const express = require('express');
const app = express();

app.use(express.json());
app.get('/api/health', (req, res) => res.json({ ok: true }));

const port = process.env.PORT || 5000;
app.listen(port, () => console.log(`API listening on ${port}`));
EOF
        log "Created minimal Express server at $backend_path/index.js"
      else
        log "index.js exists; not overwriting."
      fi

      node -e "
        const fs=require('fs');
        const p='package.json';
        const j=JSON.parse(fs.readFileSync(p,'utf8'));
        j.scripts=j.scripts||{};
        j.scripts.start=j.scripts.start||'node index.js';
        fs.writeFileSync(p, JSON.stringify(j,null,2));
      " || true
    fi
  fi
}

# ============================================================
# GitHub SSH helpers
# ============================================================
setup_github_ssh_key() {
  # Creates deploy key if missing, prints pubkey, waits for user, and (best-effort) tests.
  # Does NOT automatically add key to GitHub (you do that).
  local priv="$SSH_KEY_PATH"
  local pub="${SSH_KEY_PATH}.pub"

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Ensure openssh client tools
  apt_install_if_missing openssh-client

  if [[ -f "$priv" && -f "$pub" ]]; then
    log "SSH key already exists at $priv. Skipping creation."
  else
    log "Creating SSH deploy key at: $priv"
    ssh-keygen -t ed25519 -f "$priv" -N "" -C "$SSH_KEY_COMMENT"
    chmod 600 "$priv"
    chmod 644 "$pub"
  fi

  # Ensure ssh-agent has the key (optional, best effort)
  if has_cmd ssh-add; then
    eval "$(ssh-agent -s)" >/dev/null 2>&1 || true
    ssh-add "$priv" >/dev/null 2>&1 || true
  fi

  echo ""
  log "PUBLIC KEY (add this in GitHub repo settings → Deploy keys)"
  echo "-----------------------------------------------------------"
  cat "$pub"
  echo "-----------------------------------------------------------"
  echo "Title suggestion: ${APP_NAME}-deploy-key"
  echo "Tip: enable 'Allow write access' only if your update script needs to push tags/commits."
  echo ""

  if [[ "$WAIT_FOR_KEY" == "y" ]]; then
    read -r -p "Press ENTER after you add the deploy key to GitHub... " _
  fi

  # Best effort host key + connection test (won't fail the script if it can't)
  log "Testing SSH connection to GitHub (best effort)..."
  mkdir -p "$HOME/.ssh"
  ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

  # If repo url isn't github.com (enterprise), skip test
  if echo "$REPO_URL" | grep -qi "github.com"; then
    ssh -o StrictHostKeyChecking=yes -i "$priv" -T git@github.com || true
  else
    warn "Repo doesn't look like github.com; skipping SSH test."
  fi
}

git_clone_or_pull() {
  ensure_dir_owner "$APP_DIR"

  if [ -d "$APP_DIR/.git" ]; then
    cd "$APP_DIR"
    log "Repo exists. Resetting to origin/$BRANCH..."
    git fetch --all
    git checkout "$BRANCH"
    git reset --hard "origin/$BRANCH"
  else
    log "Cloning repo..."
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR"
    git checkout "$BRANCH" || git checkout -b "$BRANCH" "origin/$BRANCH"
  fi
}

# ============================================================
# Steps
# ============================================================

step1_system_update() {
  if ! step_enabled 1; then return 0; fi
  log "Step 1: System update"
  sudo apt-get update -y
  if [[ "$SKIP_UPGRADE" == "n" ]]; then
    sudo apt-get upgrade -y
  else
    log "Skipping apt upgrade."
  fi
}

step2_base_packages() {
  if ! step_enabled 2; then return 0; fi
  log "Step 2: Base packages"
  apt_install_if_missing git
  apt_install_if_missing curl
  apt_install_if_missing build-essential
  apt_install_if_missing openssh-client
}

step3_nginx_and_ufw() {
  if ! step_enabled 3; then return 0; fi
  log "Step 3: Nginx + optional UFW"
  if [[ "$ENABLE_NGINX" == "y" ]]; then
    apt_install_if_missing nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx || sudo systemctl restart nginx || true
  else
    log "Nginx disabled. Skipping install."
  fi

  if [[ "$ENABLE_UFW" == "y" ]]; then
    apt_install_if_missing ufw
    sudo ufw allow OpenSSH >/dev/null 2>&1 || true
    if [[ "$ENABLE_NGINX" == "y" ]]; then
      sudo ufw allow 'Nginx Full' >/dev/null 2>&1 || true
    fi
    sudo ufw --force enable >/dev/null 2>&1 || true
    sudo ufw status verbose || true
  else
    log "UFW disabled."
  fi
}

step4_node() {
  if ! step_enabled 4; then return 0; fi
  log "Step 4: Node.js via NVM (LTS)"
  if [ ! -d "$HOME/.nvm" ]; then
    log "Installing nvm..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  else
    log "nvm already installed."
  fi

  source_nvm_if_present
  if ! has_cmd nvm; then
    die "nvm not loaded. Try: source ~/.bashrc and rerun."
  fi

  nvm install --lts
  nvm use --lts
  log "Node: $(node -v)"
  log "NPM:  $(npm -v)"
}

step5_pm2() {
  if ! step_enabled 5; then return 0; fi
  log "Step 5: PM2"
  source_nvm_if_present || true
  if has_cmd pm2; then
    log "PM2 already installed: $(pm2 -v)"
  else
    npm install -g pm2
    log "PM2 installed: $(pm2 -v)"
  fi
}

step6_github_setup_and_repo() {
  if ! step_enabled 6; then return 0; fi
  log "Step 6: GitHub setup + clone/pull + detect React + optional MERN toggle"

  [ -n "$REPO_URL" ] || die "REPO_URL required."

  # If using SSH, create key + show + wait.
  if [[ "$USE_SSH_KEY" == "y" ]]; then
    # Strongly recommend SSH URL when using key
    if echo "$REPO_URL" | grep -Eq '^https?://'; then
      warn "You chose SSH key but REPO_URL is HTTPS. SSH key won't be used for HTTPS clones."
      prompt_yn SWITCH_URL "Switch to SSH repo URL now?" "y"
      if [[ "$SWITCH_URL" == "y" ]]; then
        prompt REPO_URL "Enter SSH repo URL (git@github.com:org/repo.git)" ""
      fi
    fi
    setup_github_ssh_key

    # Use key for this git operation (without altering global SSH config)
    export GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
  fi

  git_clone_or_pull

  # Detect frontend and decide MERN
  detect_react_frontend
  maybe_enable_mern
  log "Decision: MERN_ENABLED=$MERN_ENABLED (frontend_detected=$frontend_detected, APP_MODE=$APP_MODE)"

  ensure_backend_exists_or_offer_express
}

step7_backend_deps() {
  if ! step_enabled 7; then return 0; fi
  log "Step 7: Backend deps"

  local backend_path="$APP_DIR/$SERVER_DIR"
  [ "$SERVER_DIR" == "." ] && backend_path="$APP_DIR"

  cd "$backend_path" || die "Backend path not found: $backend_path"
  [ -f package.json ] || die "No package.json found in backend path: $backend_path"

  if [ -d node_modules ]; then
    log "Backend node_modules exists. Skipping install."
    return 0
  fi
  if [ -f package-lock.json ]; then npm ci; else npm install; fi
}

step8_frontend_build() {
  if ! step_enabled 8; then return 0; fi
  if [[ "$MERN_ENABLED" != "y" ]]; then
    log "Step 8: Frontend skipped (MERN not enabled)."
    return 0
  fi

  log "Step 8: Frontend deps + build (MERN enabled)"
  cd "$APP_DIR/$CLIENT_DIR" || die "Frontend dir not found: $APP_DIR/$CLIENT_DIR"
  [ -f package.json ] || die "No package.json found in frontend dir: $APP_DIR/$CLIENT_DIR"

  if [ ! -d node_modules ]; then
    if [ -f package-lock.json ]; then npm ci; else npm install; fi
  else
    log "Frontend node_modules exists. Skipping install."
  fi

  if [ -d "$CLIENT_BUILD_DIR" ]; then
    log "Frontend build output exists ($CLIENT_BUILD_DIR). Skipping build."
  else
    npm run build
  fi
}

step9_nginx_config() {
  if ! step_enabled 9; then return 0; fi
  if [[ "$ENABLE_NGINX" != "y" ]]; then
    log "Step 9: Nginx config skipped (disabled)."
    return 0
  fi

  log "Step 9: Configure Nginx (API-only or MERN)"
  local site_avail="/etc/nginx/sites-available/$APP_NAME"
  local site_enabled="/etc/nginx/sites-enabled/$APP_NAME"
  local backend_upstream="http://127.0.0.1:${SERVER_PORT}"

  if [[ "$MERN_ENABLED" == "y" ]]; then
    local web_root="$APP_DIR/$CLIENT_DIR/$CLIENT_BUILD_DIR"
    [ -d "$web_root" ] || die "Frontend build dir missing: $web_root"

    sudo tee "$site_avail" >/dev/null <<EOF
server {
  listen 80;
  server_name ${SERVER_NAME};

  root ${web_root};
  index index.html;

  location / {
    try_files \$uri /index.html;
  }

  location /api/ {
    proxy_pass ${backend_upstream}/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF
  else
    sudo tee "$site_avail" >/dev/null <<EOF
server {
  listen 80;
  server_name ${SERVER_NAME};

  location / {
    proxy_pass ${backend_upstream};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF
  fi

  sudo ln -sf "$site_avail" "$site_enabled"
  sudo rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1 || true

  sudo nginx -t
  sudo systemctl reload nginx || sudo systemctl restart nginx
}

step10_pm2_run() {
  if ! step_enabled 10; then return 0; fi
  log "Step 10: PM2 start/restart backend"

  local backend_path="$APP_DIR/$SERVER_DIR"
  [ "$SERVER_DIR" == "." ] && backend_path="$APP_DIR"
  cd "$backend_path" || die "Backend path not found: $backend_path"

  export PORT="$SERVER_PORT"
  export NODE_ENV="production"

  if pm2 describe "$APP_NAME" >/dev/null 2>&1; then
    pm2 restart "$APP_NAME" --update-env
  else
    if [[ "$START_METHOD" == "npm" ]]; then
      pm2 start npm --name "$APP_NAME" -- start --update-env
    else
      pm2 start "$SERVER_ENTRY" --name "$APP_NAME" --update-env
    fi
  fi

  pm2 save || true
  pm2 startup systemd -u "$USER" --hp "$HOME" | tail -n 1 | sudo bash || true
}

# ============================================================
# Run
# ============================================================
step1_system_update
step2_base_packages
step3_nginx_and_ufw
step4_node
step5_pm2
step6_github_setup_and_repo
step7_backend_deps
step8_frontend_build
step9_nginx_config
step10_pm2_run

log "✅ Done."
echo "Open: http://<YOUR_EC2_PUBLIC_IP>/"
echo "Resume example: bash deploy-auto.sh --from 6"

#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
DOWNLOAD_URL="${SHELFEYE_DOWNLOAD_URL:-https://github.com/ProLevelTech/shelfeye-releases/releases/latest/download/shelfeye.tar.gz}"
INSTALL_DIR="/opt/shelfeye"
DATA_DIR="/opt/shelfeye-data"

# Determine the real user who invoked sudo (falls back to current user)
REAL_USER="${SUDO_USER:-${USER}}"
[[ -z "$REAL_USER" || "$REAL_USER" == "root" ]] && error "Cannot determine the target user. Run via: sudo bash install.sh (not as root directly)"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && error "Cannot determine home directory for user '$REAL_USER'"
UV_BIN="${REAL_HOME}/.local/bin/uv"
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"
command -v curl >/dev/null || error "curl not found. Run: sudo apt-get install -y curl"

# ─── Install uv ───────────────────────────────────────────────────────────────
if [[ ! -x "$UV_BIN" ]]; then
    info "Installing uv..."
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    [[ -x "$UV_BIN" ]] || error "uv install failed, expected at $UV_BIN"
else
    info "uv already installed: $($UV_BIN --version)"
fi

# ─── Check camera drivers ─────────────────────────────────────────────────────
info "Checking camera drivers..."

DRIVER_OK=true

# libcamera stack
if ! command -v rpicam-hello >/dev/null 2>&1; then
    warn "rpicam-hello not found — install: sudo apt-get install -y libcamera-apps"
    DRIVER_OK=false
fi

# picamera2 Python library
if ! python3 -c "import picamera2" 2>/dev/null; then
    warn "picamera2 not found — install: sudo apt-get install -y python3-picamera2"
    DRIVER_OK=false
fi

# camera_auto_detect or dtoverlay in config.txt
if ! grep -qE "^(camera_auto_detect=1|dtoverlay=imx708)" /boot/firmware/config.txt /boot/config.txt 2>/dev/null; then
    warn "Camera overlay not found in /boot/config.txt — add 'camera_auto_detect=1' and reboot"
    DRIVER_OK=false
fi

# Check at least one camera is detected by libcamera
if command -v rpicam-hello >/dev/null 2>&1; then
    CAM_COUNT=$(rpicam-hello --list 2>&1 | grep -c "^\s*[0-9]" || true)
    if [[ "$CAM_COUNT" -eq 0 ]]; then
        warn "No cameras detected by libcamera. Check hardware connections."
        DRIVER_OK=false
    else
        info "Detected $CAM_COUNT camera(s) via libcamera."
    fi
fi

if [[ "$DRIVER_OK" == "false" ]]; then
    warn "Camera driver issues detected above. The service will fall back to mock capture."
    warn "Fix warnings and reboot before production use."
fi

# ─── Download & extract ───────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

info "Downloading from $DOWNLOAD_URL..."
curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/shelfeye.tar.gz"

info "Extracting to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_DIR/shelfeye.tar.gz" --strip-components=1 -C "$INSTALL_DIR"
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

# ─── Install Python dependencies ──────────────────────────────────────────────
info "Installing Python dependencies..."
cd "$INSTALL_DIR"
sudo -u "$REAL_USER" HOME="$REAL_HOME" "$UV_BIN" venv --system-site-packages
sudo -u "$REAL_USER" HOME="$REAL_HOME" "$UV_BIN" sync --frozen --no-dev

# ─── Data directory & .env ───────────────────────────────────────────────────
info "Setting up data directory at $DATA_DIR..."
mkdir -p "$DATA_DIR"

if [[ ! -f "$DATA_DIR/.env" ]]; then
    if [[ -f "$INSTALL_DIR/.env.example" ]]; then
        cp "$INSTALL_DIR/.env.example" "$DATA_DIR/.env"
        warn ".env created from example — edit $DATA_DIR/.env before starting the service"
    else
        warn ".env.example not found, creating empty $DATA_DIR/.env"
        touch "$DATA_DIR/.env"
    fi
else
    info ".env already exists at $DATA_DIR/.env — skipping"
fi

chown -R "$REAL_USER:$REAL_USER" "$DATA_DIR"

# ─── Configure environment ────────────────────────────────────────────────────
set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$DATA_DIR/.env" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$DATA_DIR/.env"
    else
        echo "${key}=${val}" >> "$DATA_DIR/.env"
    fi
}

prompt_env() {
    local key="$1" label="$2"
    local current
    current=$(grep "^${key}=" "$DATA_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    printf "  %-30s [%s]: " "$label" "$current"
    local val
    read -r val </dev/tty || true
    [[ -n "$val" ]] && set_env "$key" "$val"
}

echo ""
info "Configure main settings (Enter to keep current value):"
prompt_env "SHELFEYE_SERVER_URL"  "Backend server URL"
prompt_env "SHELFEYE_CLIENT_ID"   "Device client ID"
prompt_env "SHELFEYE_API_KEY"     "API key"
prompt_env "SHELFEYE_SSE_API_KEY" "SSE API key"

printf "  %-30s [y/N]: " "Enable S3 storage?"
read -r s3_enable </dev/tty || true
if [[ "$s3_enable" =~ ^[Yy]$ ]]; then
    set_env "SHELFEYE_S3_ENABLED" "true"
    prompt_env "SHELFEYE_S3_URL"        "S3 endpoint URL"
    prompt_env "SHELFEYE_S3_ACCESS_KEY" "S3 access key"
    prompt_env "SHELFEYE_S3_SECRET_KEY" "S3 secret key"
    prompt_env "SHELFEYE_S3_BUCKET"     "S3 bucket name"
fi

# ─── nginx ───────────────────────────────────────────────────────────────────
if command -v nginx >/dev/null 2>&1; then
    info "nginx already installed: $(nginx -v 2>&1)"
else
    info "Installing nginx..."
    apt-get install -y nginx
fi

NGINX_CONF="/etc/nginx/sites-available/shelfeye"
info "Configuring nginx..."
cp "$INSTALL_DIR/deploy/nginx.conf" "$NGINX_CONF"

NGINX_ENABLED="/etc/nginx/sites-enabled/shelfeye"
if [[ ! -L "$NGINX_ENABLED" ]]; then
    ln -s "$NGINX_CONF" "$NGINX_ENABLED"
fi

# Remove default site if it conflicts on port 80
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    warn "Removing nginx default site (conflicts on port 80)"
    rm /etc/nginx/sites-enabled/default
fi

nginx -t || error "nginx config test failed — check $NGINX_CONF"
systemctl enable nginx
systemctl reload nginx

# ─── Systemd services ─────────────────────────────────────────────────────────
info "Installing systemd services..."
for svc in shelfeye.service shelfeye-updater.service; do
    cp "$INSTALL_DIR/deploy/$svc" /etc/systemd/system/
    # Inject User= into [Service] section so the service runs as $REAL_USER
    if ! grep -q "^User=" /etc/systemd/system/"$svc"; then
        sed -i "s/^\[Service\]/[Service]\nUser=${REAL_USER}/" /etc/systemd/system/"$svc"
    fi
done
systemctl daemon-reload
systemctl enable shelfeye shelfeye-updater
systemctl restart shelfeye shelfeye-updater

# ─── Done ─────────────────────────────────────────────────────────────────────
get_env() { grep "^${1}=" "$DATA_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "(not set)"; }

echo ""
info "Installation complete!"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │           Current configuration          │"
echo "  ├─────────────────────────────────────────┤"
printf "  │  %-20s %s\n" "Server URL:"    "$(get_env SHELFEYE_SERVER_URL)│"
printf "  │  %-20s %s\n" "Client ID:"     "$(get_env SHELFEYE_CLIENT_ID)│"
printf "  │  %-20s %s\n" "API Key:"       "$(get_env SHELFEYE_API_KEY)│"
printf "  │  %-20s %s\n" "SSE API Key:"   "$(get_env SHELFEYE_SSE_API_KEY)│"
printf "  │  %-20s %s\n" "S3 Enabled:"    "$(get_env SHELFEYE_S3_ENABLED)│"
echo "  └─────────────────────────────────────────┘"
echo ""
info "Check status:  systemctl status shelfeye"
info "View logs:     journalctl -u shelfeye -f"
info "Edit config:   $DATA_DIR/.env  (then: systemctl restart shelfeye)"

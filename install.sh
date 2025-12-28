#!/usr/bin/env bash
set -euo pipefail

echo "== MacBook Pro Intel - Ubuntu Server post-install =="

# -------- Helpers --------
log() { echo -e "[*] $*"; }
warn() { echo -e "[!] $*" >&2; }

# -------- 1) Empêcher la veille au capot --------
log "Configuring lid switch (no suspend)..."
LOGIND="/etc/systemd/logind.conf"

# Appliquer (ou créer) les clés sans dupliquer
grep -q '^HandleLidSwitch=' "$LOGIND" 2>/dev/null \
  && sed -i 's/^HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LOGIND" \
  || echo 'HandleLidSwitch=ignore' >> "$LOGIND"

grep -q '^HandleLidSwitchDocked=' "$LOGIND" 2>/dev/null \
  && sed -i 's/^HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LOGIND" \
  || echo 'HandleLidSwitchDocked=ignore' >> "$LOGIND"

systemctl restart systemd-logind

# -------- 2) Détection automatique du backlight --------
log "Detecting backlight controller..."
BACKLIGHT_DIR=""
if [ -d /sys/class/backlight ]; then
  # Priorité aux implémentations Apple/Intel, sinon premier disponible
  for c in apple_backlight intel_backlight acpi_video0; do
    if [ -d "/sys/class/backlight/$c" ]; then
      BACKLIGHT_DIR="/sys/class/backlight/$c"
      break
    fi
  done
  if [ -z "$BACKLIGHT_DIR" ]; then
    BACKLIGHT_DIR="$(ls -d /sys/class/backlight/* 2>/dev/null | head -n1 || true)"
  fi
fi

if [ -z "$BACKLIGHT_DIR" ] || [ ! -f "$BACKLIGHT_DIR/brightness" ]; then
  warn "No backlight controller found; skipping backlight steps."
  SKIP_BACKLIGHT=1
else
  SKIP_BACKLIGHT=0
  log "Using backlight: $BACKLIGHT_DIR"
fi

# -------- 3) Couper le rétroéclairage immédiatement --------
if [ "$SKIP_BACKLIGHT" -eq 0 ]; then
  log "Turning backlight OFF now..."
  echo 0 > "$BACKLIGHT_DIR/brightness" || warn "Failed to write brightness"
fi

# -------- 4) Service systemd persistant --------
if [ "$SKIP_BACKLIGHT" -eq 0 ]; then
  log "Creating systemd service to keep backlight OFF at boot..."
  cat > /etc/systemd/system/disable-backlight.service <<EOF
[Unit]
Description=Disable laptop backlight (MacBook Server)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > "$BACKLIGHT_DIR/brightness"'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable disable-backlight
fi

# -------- 5) Commande backlight (on|off|toggle|status) --------
if [ "$SKIP_BACKLIGHT" -eq 0 ]; then
  log "Installing /usr/local/bin/backlight helper..."
  cat > /usr/local/bin/backlight <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BL_BASE=""
for c in apple_backlight intel_backlight acpi_video0; do
  [ -d "/sys/class/backlight/$c" ] && BL_BASE="/sys/class/backlight/$c" && break
done
[ -z "$BL_BASE" ] && BL_BASE="$(ls -d /sys/class/backlight/* 2>/dev/null | head -n1 || true)"
[ -z "$BL_BASE" ] && { echo "No backlight controller found"; exit 1; }

BR="$BL_BASE/brightness"
MAX="$BL_BASE/max_brightness"

cur() { cat "$BR"; }
max() { cat "$MAX"; }

case "${1:-}" in
  off)    echo 0 > "$BR" ;;
  on)     echo "$(max)" > "$BR" ;;
  toggle) [ "$(cur)" -eq 0 ] && echo "$(max)" > "$BR" || echo 0 > "$BR" ;;
  status) echo "Controller: $BL_BASE  Brightness: $(cur)/$(max)" ;;
  *) echo "Usage: backlight {on|off|toggle|status}" ; exit 1 ;;
esac
EOF
  chmod +x /usr/local/bin/backlight

  # Autoriser sans mot de passe (facultatif mais pratique)
  USER_NAME="$(logname || echo root)"
  echo "$USER_NAME ALL=(ALL) NOPASSWD: /usr/local/bin/backlight" > /etc/sudoers.d/backlight
fi

# -------- 6) Outils utiles (sans rien casser) --------
log "Installing helpful server utilities..."
apt update
apt install -y htop lm-sensors curl git || true

log "Done. Reboot recommended."

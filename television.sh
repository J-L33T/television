#!/bin/bash
# ╔═════════════════════════════════════════════════════════╗
# ║        TELEVISION — Telegram MTProxy Manager            ║
# ║  Powered by telemt (Rust/Tokio) · J-L33T/television     ║
# ╚═════════════════════════════════════════════════════════╝
# Version: 0.1.0  |  License: MIT

set -o pipefail
[[ "$EUID" -ne 0 ]] && { echo "[ERROR] Run as root: sudo bash $0"; exit 1; }
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "[ERROR] Bash 4.0+ required."; exit 1
fi

# ── Constants ────────────────────────────────────────────
readonly VERSION="0.1.0"
readonly INSTALL_DIR="/opt/television"
readonly SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
readonly SECRETS_FILE="${INSTALL_DIR}/secrets.conf"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly CONFIG_FILE="${INSTALL_DIR}/telemt.toml"
readonly LINKS_FILE="${INSTALL_DIR}/proxy_links.txt"
readonly TELEMT_API="https://api.github.com/repos/telemt/telemt/releases/latest"
readonly DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"
# ── Colors & Symbols ─────────────────────────────────
RED="\033[0;31m";    LRED="\033[1;31m"
GREEN="\033[0;32m";  LGREEN="\033[1;32m"
YELLOW="\033[1;33m"; CYAN="\033[0;36m"
WHITE="\033[1;37m";  DIM="\033[2m"
BOLD="\033[1m";      NC="\033[0m"
SYM_OK="✓"; SYM_ERR="✗"; SYM_WARN="!"
SYM_ARROW="›"; SYM_ON="●"; SYM_OFF="○"

# ── Logging ─────────────────────────────────────────────────
log_ok()   { echo -e "  ${LGREEN}${SYM_OK}${NC}  $*"; }
log_err()  { echo -e "  ${LRED}${SYM_ERR}${NC}  $*" >&2; }
log_warn() { echo -e "  ${YELLOW}${SYM_WARN}${NC}  $*"; }
log_info() { echo -e "  ${CYAN}${SYM_ARROW}${NC}  $*"; }
log_dim()  { echo -e "  ${DIM}$*${NC}"; }

# ── Settings defaults ────────────────────────────────────
PROXY_PORT="443"
PROXY_DOMAIN="cloudflare.com"
PROXY_PROTOCOL="tls"
CUSTOM_IP=""
METRICS_PORT="9090"
load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  while IFS="=" read -r key val; do
    [[ "$key" =~ ^[[:space:]]*# || -z "$key" ]] && continue
    key="${key// /}"; val="${val// /}"
    case "$key" in
      PROXY_PORT)     PROXY_PORT="$val" ;;
      PROXY_DOMAIN)   PROXY_DOMAIN="$val" ;;
      PROXY_PROTOCOL) PROXY_PROTOCOL="$val" ;;
      CUSTOM_IP)      CUSTOM_IP="$val" ;;
      METRICS_PORT)   METRICS_PORT="$val" ;;
    esac
  done < "$SETTINGS_FILE"
}

save_settings() {
  mkdir -p "$INSTALL_DIR"
  cat > "$SETTINGS_FILE" <<EOF
PROXY_PORT=${PROXY_PORT}
PROXY_DOMAIN=${PROXY_DOMAIN}
PROXY_PROTOCOL=${PROXY_PROTOCOL}
CUSTOM_IP=${CUSTOM_IP}
METRICS_PORT=${METRICS_PORT}
EOF
}
# ── Helpers ────────────────────────────────────────────────
get_ip() {
  if [[ -n "$CUSTOM_IP" ]]; then echo "$CUSTOM_IP"; return; fi
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
  curl -s --max-time 5 https://ifconfig.me  2>/dev/null || echo "?.?.?.?"
}

gen_secret() { openssl rand -hex 16; }

secret_to_tls() {
  local secret="$1" domain="$2"
  local domain_hex
  domain_hex=$(echo -n "$domain" | xxd -p | tr -d '\n')
  echo "ee${secret}${domain_hex}"
}

proxy_link() {
  local secret="$1" domain="${2:-$PROXY_DOMAIN}" ip port tls_secret
  ip=$(get_ip); port="$PROXY_PORT"
  tls_secret=$(secret_to_tls "$secret" "$domain")
  echo "tg://proxy?server=${ip}&port=${port}&secret=${tls_secret}"
}

is_running() {
  [[ -f "$COMPOSE_FILE" ]] && \
    docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -qE "running|Up" 2>/dev/null
}

get_latest_release() {
  curl -s --max-time 10 "$TELEMT_API" 2>/dev/null | \
    grep '"tag_name"' | head -1 | cut -d'"' -f4
}
# ── TUI Drawing ────────────────────────────────────────────
COLS=62

draw_line() {
  local char="${1:-─}"; local w="${2:-$COLS}"
  printf "%${w}s\n" | tr ' ' "$char"
}

draw_header() {
  local title="$1"
  local title_len=${#title}
  local pad=$(( (COLS - title_len - 2) / 2 ))
  clear
  echo
  echo -e "${CYAN}$(draw_line '═')${NC}"
  printf "${CYAN}║${NC}%${pad}s${BOLD}${WHITE}%s${NC}%${pad}s${CYAN}║${NC}\n" "" "$title" ""
  echo -e "${CYAN}$(draw_line '═')${NC}"
  echo
}

draw_section() {
  echo -e "  ${CYAN}${BOLD}$1${NC}"
  echo -e "  ${DIM}$(draw_line '─' 58)${NC}"
}

draw_row() {
  local label="$1" value="$2" color="${3:-$NC}"
  printf "  ${DIM}%-20s${NC}  ${color}%s${NC}\n" "$label" "$value"
}

press_enter() {
  echo
  echo -en "  ${DIM}Press Enter to continue...${NC}"
  read -r _
}

read_choice() {
  local prompt="${1:-Choice}" default="${2:-}"
  [[ -n "$default" ]] && echo -en "  ${BOLD}${prompt} [${default}]: ${NC}" || echo -en "  ${BOLD}${prompt}: ${NC}"
  read -r CHOICE
  [[ -z "$CHOICE" ]] && CHOICE="$default"
}

confirm() {
  echo -en "  ${YELLOW}$1 [y/N]: ${NC}"
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}
# ── Status Panel ───────────────────────────────────────────
draw_status_panel() {
  local status_str status_color installed_str installed_color
  if is_running; then
    status_str="${SYM_ON} Active"; status_color="$LGREEN"
  else
    status_str="${SYM_OFF} Inactive"; status_color="$RED"
  fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    installed_str="${SYM_ON} Installed"; installed_color="$LGREEN"
  else
    installed_str="${SYM_OFF} Not installed"; installed_color="$RED"
  fi
  local ip; ip=$(get_ip)
  local user_count=0
  [[ -f "$SECRETS_FILE" ]] && user_count=$(grep -c '^[^#]' "$SECRETS_FILE" 2>/dev/null || echo 0)

  draw_section "📶 STATUS"
  draw_row "Installation"  "$installed_str"  "$installed_color"
  draw_row "Proxy"         "$status_str"     "$status_color"
  draw_row "IP"            "$ip"             "$WHITE"
  draw_row "Port"          "$PROXY_PORT"     "$WHITE"
  draw_row "Domain (FakeTLS)" "$PROXY_DOMAIN" "$WHITE"
  draw_row "Protocol"      "$PROXY_PROTOCOL" "$WHITE"
  draw_row "Users"         "$user_count"     "$WHITE"
  echo
}
# -- Docker Compose & Config --
write_compose() {
  mkdir -p "$INSTALL_DIR"
  cat > "$COMPOSE_FILE" <<'COMPOSE_EOF'
services:
  television:
    image: ghcr.io/telemt/telemt:latest
    container_name: television
    restart: unless-stopped
    network_mode: host
    environment:
      RUST_LOG: "info"
    volumes:
      - /opt/television:/etc/telemt
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=32m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE_EOF
  log_ok "docker-compose.yml written"
}

write_config() {
  mkdir -p "$INSTALL_DIR"
  chmod 755 "$INSTALL_DIR"
  local users_block=""
  if [[ -f "$SECRETS_FILE" ]]; then
    while IFS="|" read -r label secret enabled; do
      [[ "$label" =~ ^# || -z "$label" || -z "$secret" ]] && continue
      users_block+="${label} = \"${secret}\"\n"
    done < "$SECRETS_FILE"
  fi
  local tls_val="false" secure_val="false"
  [[ "$PROXY_PROTOCOL" == "tls"    ]] && tls_val="true"
  [[ "$PROXY_PROTOCOL" == "secure" ]] && secure_val="true"
  {
    echo "[server]"
    echo "port = ${PROXY_PORT}"
    echo "workers = 0"
    echo ""
    echo "[tls]"
    echo "enabled = ${tls_val}"
    echo "domain = \"${PROXY_DOMAIN}\""
    echo ""
    echo "[secure]"
    echo "enabled = ${secure_val}"
    echo ""
    echo "[metrics]"
    echo "enabled = true"
    echo "port = ${METRICS_PORT}"
    echo "bind = \"127.0.0.1\""
    echo ""
    echo "[access]"
    echo "show_link = [\"tls\"]"
    echo ""
    echo "[access.users]"
    echo -e "${users_block}"
  } > "$CONFIG_FILE"
  chmod 644 "$CONFIG_FILE"
  log_ok "telemt.toml written"
}
# -- Dependencies Check --
check_deps() {
  local missing=()
  command -v docker  &>/dev/null || missing+=("docker")
  command -v curl    &>/dev/null || missing+=("curl")
  command -v openssl &>/dev/null || missing+=("openssl")
  command -v xxd     &>/dev/null || missing+=("xxd")
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing: ${missing[*]}"
    log_info "Installing dependencies..."
    if command -v apt-get &>/dev/null; then
      apt-get update -qq 2>/dev/null
      for pkg in "${missing[@]}"; do
        if [[ "$pkg" == "docker" ]]; then
          curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
          systemctl enable --now docker >/dev/null 2>&1
        else
          apt-get install -y -qq "$pkg" >/dev/null 2>&1
        fi
      done
    elif command -v yum &>/dev/null; then
      for pkg in "${missing[@]}"; do
        if [[ "$pkg" == "docker" ]]; then
          curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
          systemctl enable --now docker >/dev/null 2>&1
        else
          yum install -y -q "$pkg" >/dev/null 2>&1
        fi
      done
    fi
  fi
  log_ok "Dependencies OK"
}

# -- Install --
do_install() {
  draw_header "\U0001f4e1  TELEVISION — INSTALL"
  check_deps
  echo
  draw_section "CONFIGURATION"
  echo
  read_choice "Proxy port" "443"
  PROXY_PORT="$CHOICE"
  echo
  log_dim "FakeTLS domain: your traffic will look like HTTPS to this site."
  log_dim "Use a real domain, e.g. cloudflare.com, amazon.com"
  echo
  read_choice "FakeTLS domain" "cloudflare.com"
  PROXY_DOMAIN="$CHOICE"
  echo
  echo -e "  Select protocol:"
  echo -e "    ${LGREEN}1${NC}) TLS Mode     ${DIM}(recommended)${NC}"
  echo -e "    ${YELLOW}2${NC}) Secure Mode  ${DIM}(dd-prefix)${NC}"
  echo -e "    ${DIM}3${NC}) Classic Mode ${DIM}(legacy)${NC}"
  echo
  read_choice "Protocol" "1"
  case "$CHOICE" in
    2) PROXY_PROTOCOL="secure" ;;
    3) PROXY_PROTOCOL="classic" ;;
    *) PROXY_PROTOCOL="tls" ;;
  esac
  echo
  local auto_ip; auto_ip=$(get_ip)
  log_dim "Detected server IP: ${auto_ip}"
  read_choice "Custom IP for links (leave empty = auto)" ""
  CUSTOM_IP="$CHOICE"
  echo
  draw_section "FIRST USER"
  echo
  read_choice "Name for first user" "default"
  local first_label="$CHOICE"
  local first_secret; first_secret=$(gen_secret)
  echo
  draw_section "SETUP"
  echo
  mkdir -p "$INSTALL_DIR"
  chmod 777 "$INSTALL_DIR"
  echo "${first_label}|${first_secret}|enabled" > "$SECRETS_FILE"
  save_settings
  write_config
  write_compose
  log_info "Pulling telemt image (first pull may take a minute)..."
  if ! docker compose -f "$COMPOSE_FILE" pull; then
    log_err "Failed to pull image"; press_enter; return 1
  fi
  log_ok "Image pulled"
  log_info "Starting proxy..."
  if ! docker compose -f "$COMPOSE_FILE" up -d; then
    log_err "Failed to start"; press_enter; return 1
  fi
  log_ok "Proxy started!"
  echo
  draw_section "DONE"
  echo
  local link; link=$(proxy_link "$first_secret" "$PROXY_DOMAIN")
  echo -e "  ${BOLD}${WHITE}User:${NC}  ${first_label}"
  echo -e "  ${BOLD}${WHITE}Link:${NC}"
  echo -e "  ${LGREEN}${link}${NC}"
  echo "${first_label}: ${link}" > "$LINKS_FILE"
  echo
  log_dim "Link saved to: ${LINKS_FILE}"
  press_enter
}
# -- Start / Stop / Restart --
do_start() {
  [[ ! -f "$COMPOSE_FILE" ]] && { log_err "Not installed."; sleep 2; return; }
  log_info "Starting..."
  docker compose -f "$COMPOSE_FILE" up -d && log_ok "Started" || log_err "Failed"
  sleep 1
}

do_stop() {
  [[ ! -f "$COMPOSE_FILE" ]] && { log_err "Not installed."; sleep 2; return; }
  log_info "Stopping..."
  docker compose -f "$COMPOSE_FILE" stop && log_ok "Stopped" || log_err "Failed"
  sleep 1
}

do_restart() {
  [[ ! -f "$COMPOSE_FILE" ]] && { log_err "Not installed."; sleep 2; return; }
  log_info "Restarting..."
  docker compose -f "$COMPOSE_FILE" restart && log_ok "Restarted" || log_err "Failed"
  sleep 1
}

# -- Update --
do_update() {
  draw_header "\U0001f4e1  UPDATE"
  echo
  [[ ! -f "$COMPOSE_FILE" ]] && { log_err "Not installed."; press_enter; return; }
  local latest; latest=$(get_latest_release)
  log_info "Latest telemt: ${BOLD}${latest:-unknown}${NC}"
  echo
  log_info "Pulling latest image..."
  if ! docker compose -f "$COMPOSE_FILE" pull; then
    log_err "Pull failed"; press_enter; return 1
  fi
  log_ok "Image updated"
  log_info "Restarting with new image..."
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate && log_ok "Done!" || log_err "Restart failed"
  press_enter
}

# -- Uninstall --
do_uninstall() {
  draw_header "⚠  UNINSTALL"
  echo
  log_warn "This will STOP the proxy and DELETE all configuration."
  echo
  confirm "Proceed with full uninstall?" || { log_info "Cancelled."; sleep 1; return; }
  if [[ -f "$COMPOSE_FILE" ]]; then
    log_info "Stopping container..."
    docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null
    log_ok "Container stopped"
  fi
  if [[ -d "$INSTALL_DIR" ]]; then
    log_info "Removing files..."
    rm -rf "$INSTALL_DIR"
    log_ok "Files removed"
  fi
  log_ok "Uninstall complete."
  press_enter
}
# -- User Management --
list_users_inline() {
  [[ ! -f "$SECRETS_FILE" ]] && return
  while IFS="|" read -r label secret enabled; do
    [[ "$label" =~ ^# || -z "$label" ]] && continue
    local icon="$SYM_ON" color="$LGREEN"
    [[ "$enabled" != "enabled" ]] && icon="$SYM_OFF" && color="$RED"
    printf "  ${color}%s${NC}  ${BOLD}%s${NC}\n" "$icon" "$label"
  done < "$SECRETS_FILE"
}

show_links() {
  draw_header "\U0001f517  PROXY LINKS"
  echo
  if [[ ! -f "$SECRETS_FILE" ]] || ! grep -q '^[^#]' "$SECRETS_FILE" 2>/dev/null; then
    log_warn "No users configured."; press_enter; return
  fi
  local ip; ip=$(get_ip)
  : > "$LINKS_FILE"
  while IFS="|" read -r label secret enabled; do
    [[ "$label" =~ ^# || -z "$label" || -z "$secret" ]] && continue
    local link; link=$(proxy_link "$secret" "$PROXY_DOMAIN")
    local color="$LGREEN"
    [[ "$enabled" != "enabled" ]] && color="$RED"
    echo -e "  ${BOLD}${color}${label}${NC}  ${DIM}[${enabled}]${NC}"
    echo -e "  ${DIM}${link}${NC}"
    echo
    echo "${label}: ${link}" >> "$LINKS_FILE"
  done < "$SECRETS_FILE"
  log_dim "Links saved to: ${LINKS_FILE}"
  press_enter
}

add_user() {
  draw_header "\u2795  ADD USER"
  echo
  read_choice "Username"
  local label="$CHOICE"
  [[ -z "$label" ]] && { log_warn "Name cannot be empty."; sleep 2; return; }
  grep -q "^${label}|" "$SECRETS_FILE" 2>/dev/null && { log_err "User '$label' already exists."; sleep 2; return; }
  local secret; secret=$(gen_secret)
  echo "${label}|${secret}|enabled" >> "$SECRETS_FILE"
  write_config
  do_restart
  echo
  local link; link=$(proxy_link "$secret" "$PROXY_DOMAIN")
  log_ok "User '${label}' added!"
  echo -e "  ${BOLD}${WHITE}Link:${NC}"
  echo -e "  ${LGREEN}${link}${NC}"
  echo "${label}: ${link}" >> "$LINKS_FILE"
  press_enter
}

remove_user() {
  draw_header "\u2796  REMOVE USER"
  echo
  [[ ! -f "$SECRETS_FILE" ]] && { log_warn "No users."; sleep 2; return; }
  list_users_inline
  echo
  read_choice "Username to remove"
  local label="$CHOICE"
  [[ -z "$label" ]] && return
  grep -q "^${label}|" "$SECRETS_FILE" 2>/dev/null || { log_err "User '$label' not found."; sleep 2; return; }
  confirm "Remove user '${label}'?" || return
  sed -i "/^${label}|/d" "$SECRETS_FILE"
  write_config
  do_restart
  log_ok "User '${label}' removed."
  press_enter
}

toggle_user() {
  draw_header "\u26a1  TOGGLE USER"
  echo
  [[ ! -f "$SECRETS_FILE" ]] && { log_warn "No users."; sleep 2; return; }
  list_users_inline
  echo
  read_choice "Username"
  local label="$CHOICE"
  [[ -z "$label" ]] && return
  grep -q "^${label}|" "$SECRETS_FILE" 2>/dev/null || { log_err "User '$label' not found."; sleep 2; return; }
  local cur_state
  cur_state=$(grep "^${label}|" "$SECRETS_FILE" | cut -d'|' -f3)
  local new_state="enabled"
  [[ "$cur_state" == "enabled" ]] && new_state="disabled"
  sed -i "s|^${label}|\(.*\)|.*$|${label}|\1|${new_state}|" "$SECRETS_FILE"
  write_config
  do_restart
  log_ok "User '${label}' is now ${new_state}."
  sleep 1
}
users_menu() {
  while true; do
    draw_header "\U0001f465  USER MANAGEMENT"
    load_settings
    echo
    draw_section "USERS"
    list_users_inline
    echo
    draw_section "ACTIONS"
    echo
    echo -e "  ${LGREEN}1${NC}) Add user"
    echo -e "  ${LGREEN}2${NC}) Remove user"
    echo -e "  ${LGREEN}3${NC}) Enable / Disable user"
    echo -e "  ${CYAN}4${NC}) Show proxy links"
    echo
    echo -e "  ${DIM}0) Back${NC}"
    echo
    read_choice "Option" "0"
    case "$CHOICE" in
      1) add_user ;;
      2) remove_user ;;
      3) toggle_user ;;
      4) show_links ;;
      0|"") return ;;
    esac
  done
}

# -- Logs --
show_logs() {
  [[ ! -f "$COMPOSE_FILE" ]] && { log_err "Not installed."; sleep 2; return; }
  echo -e "  ${DIM}Streaming logs (Ctrl+C to stop)...${NC}"
  echo
  docker compose -f "$COMPOSE_FILE" logs -f --tail=50
}
# -- Main Menu --
main_menu() {
  while true; do
    load_settings
    draw_header "\U0001f4e1  TELEVISION  v${VERSION}"
    draw_status_panel
    draw_section "MAIN MENU"
    echo
    if [[ -f "$COMPOSE_FILE" ]]; then
      if is_running; then
        echo -e "  ${YELLOW}1${NC}) Stop proxy"
        echo -e "  ${YELLOW}2${NC}) Restart proxy"
      else
        echo -e "  ${LGREEN}1${NC}) Start proxy"
        echo -e "  ${DIM}2${NC}) Restart proxy"
      fi
      echo -e "  ${CYAN}3${NC}) User management"
      echo -e "  ${CYAN}4${NC}) Show proxy links"
      echo -e "  ${CYAN}5${NC}) Update telemt"
      echo -e "  ${CYAN}6${NC}) View logs"
      echo -e "  ${CYAN}7${NC}) Reconfigure / Reinstall"
      echo
      echo -e "  ${RED}0${NC}) Full uninstall"
    else
      echo -e "  ${LGREEN}1${NC}) ${BOLD}Install Television${NC}"
      echo
      echo -e "  ${DIM}0) Exit${NC}"
    fi
    echo
    read_choice "Option" ""
    if [[ -f "$COMPOSE_FILE" ]]; then
      case "$CHOICE" in
        1) is_running && do_stop || do_start ;;
        2) do_restart ;;
        3) users_menu ;;
        4) show_links ;;
        5) do_update ;;
        6) show_logs ;;
        7) do_install ;;
        0) do_uninstall ;;
        "") continue ;;
        *) log_warn "Invalid option"; sleep 1 ;;
      esac
    else
      case "$CHOICE" in
        1) do_install ;;
        0|"") echo; exit 0 ;;
        *) log_warn "Invalid option"; sleep 1 ;;
      esac
    fi
  done
}

# ============================================================
# ENTRY POINT
# ============================================================
case "${1:-}" in
  start)     load_settings; do_start ;;
  stop)      load_settings; do_stop ;;
  restart)   load_settings; do_restart ;;
  update)    load_settings; do_update ;;
  install)   load_settings; do_install ;;
  uninstall) load_settings; do_uninstall ;;
  logs)      load_settings; show_logs ;;
  links)     load_settings; show_links ;;
  status)
    load_settings
    if is_running; then
      echo -e "${LGREEN}${SYM_ON} Television is running${NC} (port ${PROXY_PORT})"
    else
      echo -e "${RED}${SYM_OFF} Television is not running${NC}"
    fi
    ;;
  "")
    load_settings
    main_menu
    ;;
  *)
    echo "Usage: television [start|stop|restart|update|status|logs|links|install|uninstall]"
    exit 1
    ;;
esac

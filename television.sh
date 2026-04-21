#!/bin/bash
# ┌─────────────────────────────────────────────────────────┐
# │          TELEVISION — Telegram MTProxy Manager          │
# │    Powered by telemt (Rust/tokio) · J-L33T/television   │
# └─────────────────────────────────────────────────────────┘
# Version: 0.1.2  |  License: MIT

set -eo pipefail
[[ "${EUID}" -ne 0 ]] && { echo "[ERROR] Run as root: sudo bash $0"; exit 1; }
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then echo "[ERROR] Bash 4.0+ required."; exit 1; fi

readonly VERSION="0.1.2"
readonly INSTALL_DIR="/opt/television"
readonly SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
readonly SECRETS_FILE="${INSTALL_DIR}/secrets.conf"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
# Config mounts to /etc/telemt/config.toml inside container (official telemt path)
readonly CONFIG_FILE="${INSTALL_DIR}/config.toml"
readonly LINKS_FILE="${INSTALL_DIR}/proxy_links.txt"
readonly TELEMT_API="https://api.github.com/repos/telemt/telemt/releases/latest"
readonly DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"

RED="\033[0;31m";    LRED="\033[1;31m"
GREEN="\033[0;32m";  LGREEN="\033[1;32m"
YELLOW="\033[0;33m"; CYAN="\033[0;36m"
WHITE="\033[1;37m";  DIM="\033[2m"
BOLD="\033[1m";      NC="\033[0m"
SYM_OK="✓"; SYM_ERR="✗"; SYM_WARN="!"; SYM_ARROW="→"; SYM_ON="●"; SYM_OFF="○"

log_ok()   { echo -e " ${LGREEN}${SYM_OK}${NC}  $*"; }
log_err()  { echo -e " ${LRED}${SYM_ERR}${NC}  $*" >&2; }
log_warn() { echo -e " ${YELLOW}${SYM_WARN}${NC}  $*"; }
log_info() { echo -e " ${CYAN}${SYM_ARROW}${NC}  $*"; }
log_dim()  { echo -e " ${DIM}$*${NC}"; }

PROXY_PORT="443"; PROXY_DOMAIN="cloudflare.com"; PROXY_PROTOCOL="tls"; CUSTOM_IP=""; METRICS_PORT="9090"

load_settings() {
  [[ -f "${SETTINGS_FILE}" ]] || return 0
  while IFS="=" read -r key val; do
    [[ -z "${key}" ]] && continue
    key="${key//[[:space:]]/}"; val="${val//[[:space:]]/}"
    case "${key}" in
      PROXY_PORT)     PROXY_PORT="${val}" ;;
      PROXY_DOMAIN)   PROXY_DOMAIN="${val}" ;;
      PROXY_PROTOCOL) PROXY_PROTOCOL="${val}" ;;
      CUSTOM_IP)      CUSTOM_IP="${val}" ;;
      METRICS_PORT)   METRICS_PORT="${val}" ;;
    esac
  done < "${SETTINGS_FILE}"
}
save_settings() {
  mkdir -p "${INSTALL_DIR}"
  printf "PROXY_PORT=%s\nPROXY_DOMAIN=%s\nPROXY_PROTOCOL=%s\nCUSTOM_IP=%s\nMETRICS_PORT=%s\n" \
    "${PROXY_PORT}" "${PROXY_DOMAIN}" "${PROXY_PROTOCOL}" "${CUSTOM_IP}" "${METRICS_PORT}" > "${SETTINGS_FILE}"
}
get_ip() {
  [[ -n "${CUSTOM_IP}" ]] && { echo "${CUSTOM_IP}"; return; }
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "?.?.?.?"
}
gen_secret() { openssl rand -hex 16; }
secret_to_tls() {
  local secret="$1" domain="$2" dh
  dh=$(echo -n "${domain}" | xxd -p | tr -d '\n')
  echo "ee${secret}${dh}"
}
proxy_link() {
  local secret="$1" domain="${2:-$PROXY_DOMAIN}" ip ts
  ip=$(get_ip); ts=$(secret_to_tls "${secret}" "${domain}")
  echo "tg://proxy?server=${ip}&port=${PROXY_PORT}&secret=${ts}"
}
is_running() {
  [[ -f "${COMPOSE_FILE}" ]] && \
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null | grep -qE "running|Up" 2>/dev/null
}
get_latest_release() {
  curl -s --max-time 10 "${TELEMT_API}" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4
}COLS=62
draw_line() { printf "%${2:-$COLS}s\n" | tr ' ' "${1:--}"; }
draw_header() {
  local t="$1" tl pad
  tl=${#t}; pad=$(( (COLS - tl - 2) / 2 ))
  clear; echo
  echo -e "${CYAN}$(draw_line '=')${NC}"
  printf "${CYAN}|${NC}${BOLD}${WHITE}%${pad}s${NC}${BOLD}%s${NC}${WHITE}%${pad}s${CYAN}|${NC}\n" "" "${t}" ""
  echo -e "${CYAN}$(draw_line '=')${NC}"
  echo
}
draw_section() { echo -e " ${BOLD}$*${NC}"; echo -e " ${DIM}$(draw_line '-' 58)${NC}"; }
draw_row()    { printf "  ${DIM}%-20s${NC}  %b\n" "$1" "$2"; }
press_enter() { echo; echo -e " ${DIM}Press [Enter]...${NC}"; read -r; }
read_choice() { echo; printf " ${BOLD}${CYAN}[?]${NC} ${1:-Option}: "; read -r CHOICE; }
show_status() {
  local ip rs is uc=0
  ip=$(get_ip)
  is_running && rs="${LGREEN}${SYM_ON} Active${NC}" || rs="${LRED}${SYM_OFF} Stopped${NC}"
  [[ -f "${INSTALL_DIR}/.installed" ]] && is="${LGREEN}${SYM_ON} Installed${NC}" || is="${YELLOW}${SYM_OFF} Not installed${NC}"
  [[ -f "${SECRETS_FILE}" ]] && uc=$(grep -vc '^$' "${SECRETS_FILE}" 2>/dev/null || echo 0)
  draw_header "\U0001f4e1  TELEVISION  v${VERSION}"
  draw_section "STATUS"
  draw_row "Installation" "${is}"
  draw_row "Proxy" "${rs}"
  draw_row "IP" "${ip}"
  draw_row "Port" "${PROXY_PORT}"
  draw_row "Domain (FakeTLS)" "${PROXY_DOMAIN}"
  draw_row "Protocol" "${PROXY_PROTOCOL}"
  draw_row "Users" "${uc}"
  echo
}

# FIXED: official docker-compose format from github.com/telemt/telemt
# Key fixes:
#  - config mounts to /etc/telemt/config.toml (not /app/)
#  - working_dir: /etc/telemt (needed for tlsfront/ TLS cache)
#  - tmpfs: /etc/telemt:rw (container is read_only, telemt writes cache here)
#  - ports: instead of network_mode: host (safer, bridge mode)
#  - cap_drop: ALL + security_opt: no-new-privileges
write_compose() {
  mkdir -p "${INSTALL_DIR}"
  cat > "${COMPOSE_FILE}" <<'CEOF'
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "PORT_PLACEHOLDER:PORT_PLACEHOLDER"
      - "127.0.0.1:9091:9091"
    working_dir: /etc/telemt
    volumes:
      - CONFIG_PLACEHOLDER:/etc/telemt/config.toml:ro
    tmpfs:
      - /etc/telemt:rw,mode=1777,size=4m
    environment:
      - RUST_LOG=info
    healthcheck:
      test: ["CMD", "/app/telemt", "healthcheck", "/etc/telemt/config.toml", "--mode", "liveness"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 262144
CEOF
  # Replace placeholders with actual values
  sed -i "s|PORT_PLACEHOLDER|${PROXY_PORT}|g" "${COMPOSE_FILE}"
  sed -i "s|CONFIG_PLACEHOLDER|${CONFIG_FILE}|g" "${COMPOSE_FILE}"
  log_ok "docker-compose.yml written"
}

# FIXED: official telemt.toml format
# - log_level added
# - [general.links] section added
# - [[server.listeners]] added
# - tls_front_dir added to [censorship]
# - [access.users]: label = "32_hex_secret" (NO ee prefix in config!)
write_config() {
  mkdir -p "${INSTALL_DIR}"
  local ub="" tv="false" sv="false" cv="false"
  if [[ -f "${SECRETS_FILE}" ]]; then
    while IFS="|" read -r label secret enabled; do
      [[ "${label}" =~ ^# ]] || [[ -z "${label}" ]] || [[ -z "${secret}" ]] && continue
      [[ "${enabled}" == "disabled" ]] && continue
      ub+="${label} = \"${secret}\"\n"
    done < "${SECRETS_FILE}"
  fi
  case "${PROXY_PROTOCOL}" in
    tls)     tv="true" ;; secure) sv="true" ;; classic) cv="true" ;;
    all)     tv="true"; sv="true"; cv="true" ;;
  esac
  {
    echo "### Generated by television v${VERSION}"
    echo "[general]"
    echo "use_middle_proxy = true"
    echo "log_level = \"normal\""
    echo ""
    echo "[general.modes]"
    echo "classic = ${cv}"
    echo "secure = ${sv}"
    echo "tls = ${tv}"
    echo ""
    echo "[general.links]"
    echo "show = \"*\""
    echo ""
    echo "[server]"
    echo "port = ${PROXY_PORT}"
    echo ""
    echo "[[server.listeners]]"
    echo "ip = \"0.0.0.0\""
    echo ""
    echo "[censorship]"
    echo "tls_domain = \"${PROXY_DOMAIN}\""
    echo "mask = true"
    echo "tls_emulation = true"
    echo "tls_front_dir = \"tlsfront\""
    echo ""
    echo "[access.users]"
    if [[ -n "${ub}" ]]; then
      printf "%b" "${ub}"
    else
      echo "# no active users — add via User management"
    fi
  } > "${CONFIG_FILE}"
  log_ok "config.toml written"
}do_start() {
  command -v docker &>/dev/null || { log_err "Docker not installed."; return 1; }
  write_config; write_compose
  docker compose -f "${COMPOSE_FILE}" up -d --pull always 2>&1 | tail -5
  sleep 3
  if is_running; then log_ok "Proxy started"
  else log_err "Failed — check logs (option 6)"; docker compose -f "${COMPOSE_FILE}" logs --tail=30; fi
}
do_stop() {
  [[ -f "${COMPOSE_FILE}" ]] || { log_warn "Not installed"; return; }
  docker compose -f "${COMPOSE_FILE}" down && log_ok "Proxy stopped"
}
do_restart() {
  write_config
  [[ -f "${COMPOSE_FILE}" ]] && docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
  write_compose
  docker compose -f "${COMPOSE_FILE}" up -d 2>&1 | tail -3; sleep 2
}
do_update() {
  draw_header "UPDATE TELEMT"
  local latest; latest=$(get_latest_release)
  [[ -z "${latest}" ]] && latest="unknown"
  log_info "Latest release: ${latest}"; log_info "Pulling new image..."
  docker pull "${DOCKER_IMAGE}" 2>&1 | tail -5
  log_ok "Image updated"
  if is_running; then
    log_info "Restarting with new image..."
    do_restart && log_ok "Restarted"
  fi
  press_enter
}
install_deps() {
  log_info "Checking dependencies..."
  local pkgs=()
  command -v docker  &>/dev/null || pkgs+=(docker.io docker-compose-plugin)
  command -v curl    &>/dev/null || pkgs+=(curl)
  command -v xxd     &>/dev/null || pkgs+=(xxd)
  command -v openssl &>/dev/null || pkgs+=(openssl)
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    log_info "Installing: ${pkgs[*]}"
    if command -v apt-get &>/dev/null; then
      apt-get update -qq && apt-get install -y -qq "${pkgs[@]}"
    elif command -v yum &>/dev/null; then yum install -y -q "${pkgs[@]}"
    else log_err "Unsupported pkg manager"; exit 1; fi
  fi
  if ! docker compose version &>/dev/null; then
    log_info "Installing Docker Compose plugin..."
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  systemctl enable --now docker 2>/dev/null || true
  log_ok "Dependencies ready"
}
do_install() {
  draw_header "INSTALL TELEVISION"
  install_deps
  echo; draw_section "CONFIGURATION"; echo
  printf "  Port [%s]: " "${PROXY_PORT}"; read -r i; [[ -n "${i}" ]] && PROXY_PORT="${i}"
  printf "  FakeTLS domain [%s]: " "${PROXY_DOMAIN}"; read -r i; [[ -n "${i}" ]] && PROXY_DOMAIN="${i}"
  echo "  Protocol: 1) tls (FakeTLS)  2) secure  3) classic  4) all"
  printf "  Choice [1]: "; read -r i
  case "${i}" in 2) PROXY_PROTOCOL="secure" ;; 3) PROXY_PROTOCOL="classic" ;; 4) PROXY_PROTOCOL="all" ;; *) PROXY_PROTOCOL="tls" ;; esac
  printf "  Custom IP (blank=auto-detect): "; read -r i; [[ -n "${i}" ]] && CUSTOM_IP="${i}"
  echo; draw_section "FIRST USER"
  printf "  Username [default]: "; read -r fl; [[ -z "${fl}" ]] && fl="default"
  local fs; fs=$(gen_secret)
  echo "${fl}|${fs}|enabled" > "${SECRETS_FILE}"
  save_settings; write_config; write_compose
  log_info "Pulling Docker image (may take a minute)..."
  docker pull "${DOCKER_IMAGE}" 2>&1 | tail -3
  docker compose -f "${COMPOSE_FILE}" up -d 2>&1 | tail -5
  sleep 3; touch "${INSTALL_DIR}/.installed"
  echo; draw_section "YOUR PROXY LINK"; echo
  local link; link=$(proxy_link "${fs}" "${PROXY_DOMAIN}")
  echo -e "  ${BOLD}${WHITE}User: ${fl}${NC}"
  echo -e "  ${LGREEN}${link}${NC}"
  echo "${fl}: ${link}" > "${LINKS_FILE}"
  echo; log_ok "Installation complete!"; press_enter
}list_users_inline() {
  [[ -f "${SECRETS_FILE}" ]] && [[ -s "${SECRETS_FILE}" ]] || { log_warn "No users configured."; return 1; }
  echo; local n=0
  while IFS="|" read -r label secret enabled; do
    [[ "${label}" =~ ^# ]] || [[ -z "${label}" ]] && continue
    n=$(( n + 1 ))
    local sym; [[ "${enabled}" == "enabled" ]] && sym="${LGREEN}${SYM_ON}${NC}" || sym="${LRED}${SYM_OFF}${NC}"
    printf "  ${DIM}%2d.${NC}  %-20s  %b\n" "${n}" "${label}" "${sym}"
  done < "${SECRETS_FILE}"
  echo; return 0
}
add_user() {
  draw_header "\U0001f464  ADD USER"
  printf "  Username: "; read -r label
  [[ -z "${label}" ]] && { log_warn "Empty name."; press_enter; return; }
  grep -q "^${label}|" "${SECRETS_FILE}" 2>/dev/null && { log_warn "User already exists."; press_enter; return; }
  local secret; secret=$(gen_secret)
  echo "${label}|${secret}|enabled" >> "${SECRETS_FILE}"
  write_config; do_restart
  local link; link=$(proxy_link "${secret}" "${PROXY_DOMAIN}")
  log_ok "User '${label}' added!"
  echo -e "  ${LGREEN}${link}${NC}"
  echo "${label}: ${link}" >> "${LINKS_FILE}"
  press_enter
}
remove_user() {
  draw_header "\U0001f5d1  REMOVE USER"
  echo; list_users_inline || { sleep 2; return; }
  read_choice "Username to remove"; local label="${CHOICE}"
  grep -q "^${label}|" "${SECRETS_FILE}" 2>/dev/null || { log_warn "User not found."; press_enter; return; }
  sed -i "/^${label}|/d" "${SECRETS_FILE}"
  sed -i "/^${label}: /d" "${LINKS_FILE}" 2>/dev/null || true
  write_config; do_restart; log_ok "User '${label}' removed."; press_enter
}
toggle_user() {
  draw_header "TOGGLE USER"
  echo; list_users_inline || { sleep 2; return; }
  read_choice "Username to toggle"; local label="${CHOICE}"
  grep -q "^${label}|" "${SECRETS_FILE}" 2>/dev/null || { log_warn "User not found."; press_enter; return; }
  if grep -q "^${label}|.*|enabled$" "${SECRETS_FILE}"; then
    sed -i "s/^${label}|\(.*\)|enabled$/${label}|\1|disabled/" "${SECRETS_FILE}"
    log_ok "Disabled."
  else
    sed -i "s/^${label}|\(.*\)|disabled$/${label}|\1|enabled/" "${SECRETS_FILE}"
    log_ok "Enabled."
  fi
  write_config; do_restart; press_enter
}
show_links() {
  draw_header "\U0001f517  PROXY LINKS"; echo
  [[ -f "${SECRETS_FILE}" ]] && [[ -s "${SECRETS_FILE}" ]] || { log_warn "No users configured."; press_enter; return; }
  > "${LINKS_FILE}"
  while IFS="|" read -r label secret enabled; do
    [[ "${label}" =~ ^# ]] || [[ -z "${label}" ]] && continue
    local link; link=$(proxy_link "${secret}" "${PROXY_DOMAIN}")
    local stat; [[ "${enabled}" == "enabled" ]] && stat="${LGREEN}[active]${NC}" || stat="${LRED}[disabled]${NC}"
    echo -e "  ${BOLD}${label}${NC}  ${stat}"
    echo -e "  ${CYAN}${link}${NC}"; echo
    echo "${label}: ${link}" >> "${LINKS_FILE}"
  done < "${SECRETS_FILE}"
  log_dim "Saved to ${LINKS_FILE}"; press_enter
}
user_menu() {
  while true; do
    show_status; draw_section "USER MANAGEMENT"; echo
    list_users_inline || true
    echo -e "  ${BOLD}1)${NC} Add user"
    echo -e "  ${BOLD}2)${NC} Remove user"
    echo -e "  ${BOLD}3)${NC} Toggle (enable/disable)"
    echo -e "  ${BOLD}4)${NC} Show links"
    echo -e "  ${BOLD}0)${NC} Back"
    read_choice "Option"
    case "${CHOICE}" in 1) add_user ;; 2) remove_user ;; 3) toggle_user ;; 4) show_links ;; 0) return ;; esac
  done
}show_logs() {
  draw_header "LOGS"
  [[ -f "${COMPOSE_FILE}" ]] || { log_warn "Not installed"; press_enter; return; }
  docker compose -f "${COMPOSE_FILE}" logs --tail=60 --no-color 2>&1 | head -70
  press_enter
}
do_reconfigure() {
  draw_header "RECONFIGURE"; echo
  log_info "Change settings (Enter = keep current):"; echo
  printf "  Port [%s]: " "${PROXY_PORT}"; read -r i; [[ -n "${i}" ]] && PROXY_PORT="${i}"
  printf "  FakeTLS domain [%s]: " "${PROXY_DOMAIN}"; read -r i; [[ -n "${i}" ]] && PROXY_DOMAIN="${i}"
  echo "  Protocol: 1) tls  2) secure  3) classic  4) all  [current: ${PROXY_PROTOCOL}]"
  printf "  Choice (Enter=keep): "; read -r i
  case "${i}" in 1) PROXY_PROTOCOL="tls" ;; 2) PROXY_PROTOCOL="secure" ;; 3) PROXY_PROTOCOL="classic" ;; 4) PROXY_PROTOCOL="all" ;; esac
  printf "  Custom IP [%s] (-=clear): " "${CUSTOM_IP:-auto}"; read -r i
  [[ "${i}" == "-" ]] && CUSTOM_IP="" || [[ -n "${i}" ]] && CUSTOM_IP="${i}"
  save_settings; write_config; write_compose
  is_running && { log_info "Restarting..."; do_restart; }
  log_ok "Reconfigured!"; press_enter
}
do_uninstall() {
  draw_header "UNINSTALL"; echo
  log_warn "This will STOP and REMOVE all proxy data and configuration."
  printf "  Type 'yes' to confirm: "; read -r confirm
  [[ "${confirm}" != "yes" ]] && { log_info "Cancelled."; press_enter; return; }
  [[ -f "${COMPOSE_FILE}" ]] && docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  docker rmi "${DOCKER_IMAGE}" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}"; log_ok "Television uninstalled."; press_enter; exit 0
}
main_menu() {
  load_settings
  while true; do
    show_status; draw_section "MAIN MENU"; echo
    if [[ -f "${INSTALL_DIR}/.installed" ]]; then
      echo -e "  ${BOLD}1)${NC} Stop proxy"
      echo -e "  ${BOLD}2)${NC} Restart proxy"
      echo -e "  ${BOLD}3)${NC} User management"
      echo -e "  ${BOLD}4)${NC} Show proxy links"
      echo -e "  ${BOLD}5)${NC} Update telemt"
      echo -e "  ${BOLD}6)${NC} View logs"
      echo -e "  ${BOLD}7)${NC} Reconfigure"
      echo; echo -e "  ${BOLD}0)${NC} Full uninstall"
    else
      echo -e "  ${BOLD}1)${NC} Install television"
      echo; echo -e "  ${BOLD}0)${NC} Exit"
    fi
    read_choice "Option"
    if [[ -f "${INSTALL_DIR}/.installed" ]]; then
      case "${CHOICE}" in
        1) do_stop; press_enter ;; 2) do_restart; press_enter ;;
        3) user_menu ;; 4) show_links ;; 5) do_update ;;
        6) show_logs ;; 7) do_reconfigure ;; 0) do_uninstall ;;
        *) log_warn "Invalid option" ;;
      esac
    else
      case "${CHOICE}" in
        1) do_install ;; 0) exit 0 ;; *) log_warn "Invalid option" ;;
      esac
    fi
  done
}
if [[ $# -gt 0 ]]; then
  load_settings
  case "$1" in
    install)    do_install ;;
    start)      do_start ;;
    stop)       do_stop ;;
    restart)    do_restart ;;
    update)     do_update ;;
    status)     show_status; is_running && log_ok "Running" || log_warn "Stopped" ;;
    logs)       show_logs ;;
    add-user)
      [[ -z "$2" ]] && { echo "Usage: $0 add-user <name>"; exit 1; }
      secret=$(gen_secret)
      echo "$2|${secret}|enabled" >> "${SECRETS_FILE}"
      write_config; do_restart
      echo "Added: $2"; proxy_link "${secret}"
      ;;
    list-users) [[ -f "${SECRETS_FILE}" ]] && cut -d'|' -f1,3 "${SECRETS_FILE}" || echo "No users" ;;
    links)
      [[ -f "${SECRETS_FILE}" ]] || exit 0
      while IFS="|" read -r label secret enabled; do
        [[ "${label}" =~ ^# ]] || [[ -z "${label}" ]] && continue
        echo "${label}: $(proxy_link "${secret}")"
      done < "${SECRETS_FILE}"
      ;;
    *) echo "Usage: $0 {install|start|stop|restart|update|status|logs|add-user <n>|list-users|links}"; exit 1 ;;
  esac
  exit 0
fi
main_menu

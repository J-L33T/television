#!/bin/bash
# ┌─────────────────────────────────────────────────────────┐
# │          TELEVISION — Telegram MTProxy Manager          │
# │    Powered by telemt (Rust/tokio) · J-L33T/television   │
# └─────────────────────────────────────────────────────────┘
# Version: 0.2.0  |  License: MIT

set -eo pipefail
[[ "${EUID}" -ne 0 ]] && { echo "[ERROR] Run as root: sudo bash $0"; exit 1; }
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then echo "[ERROR] Bash 4.0+ required."; exit 1; fi

readonly VERSION="0.2.0"
readonly INSTALL_DIR="/opt/television"
readonly SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
readonly SECRETS_FILE="${INSTALL_DIR}/secrets.conf"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly CONFIG_FILE="${INSTALL_DIR}/config.toml"
readonly LINKS_FILE="${INSTALL_DIR}/proxy_links.txt"
readonly SELF_BIN="/usr/local/bin/television"
readonly DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"
readonly METRICS_LOCAL_PORT="9091"   # всегда 127.0.0.1:9091 внутри контейнера

RED="\033[0;31m";    LRED="\033[1;31m"
GREEN="\033[0;32m";  LGREEN="\033[1;32m"
YELLOW="\033[0;33m"; CYAN="\033[0;36m"
WHITE="\033[1;37m";  DIM="\033[2m"
BOLD="\033[1m";      NC="\033[0m"
SYM_OK="✓"; SYM_ERR="✗"; SYM_WARN="!"; SYM_ARROW="→"; SYM_ON="●"; SYM_OFF="○"

show_banner() {
  clear
  echo -e "${CYAN}"
  echo '  ████████╗███████╗██╗     ███████╗'
  echo '  ╚══██╔══╝██╔════╝██║     ██╔════╝'
  echo '     ██║   █████╗  ██║     █████╗  '
  echo '     ██║   ██╔══╝  ██║     ██╔══╝  '
  echo '     ██║   ███████╗███████╗███████╗ '
  echo '     ╚═╝   ╚══════╝╚══════╝╚══════╝ '
  echo '  ██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗'
  echo '  ██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║'
  echo '  ██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║'
  echo '  ╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║'
  echo '   ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║'
  echo '    ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝'
  echo -e "${NC}"
  echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}║${NC}  ${DIM}Telegram MTProxy Manager  v${VERSION}${NC}           ${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${DIM}Powered by telemt (Rust/tokio)${NC}              ${CYAN}║${NC}"
  echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo
  sleep 0.5
}

log_ok()   { echo -e " ${LGREEN}${SYM_OK}${NC}  $*"; }
log_err()  { echo -e " ${LRED}${SYM_ERR}${NC}  $*" >&2; }
log_warn() { echo -e " ${YELLOW}${SYM_WARN}${NC}  $*"; }
log_info() { echo -e " ${CYAN}${SYM_ARROW}${NC}  $*"; }
log_dim()  { echo -e " ${DIM}$*${NC}"; }

# ──────────────────────────────────────────────────────────────
# SETTINGS
# ──────────────────────────────────────────────────────────────
PROXY_PORT="443"; PROXY_DOMAIN="cloudflare.com"; PROXY_PROTOCOL="tls"; CUSTOM_IP=""; METRICS_PORT="9091"

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

# ──────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────
get_ip() {
  [[ -n "${CUSTOM_IP}" ]] && { echo "${CUSTOM_IP}"; return; }
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
  curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "?.?.?.?"
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

# Проверка — занят ли порт другим процессом
port_in_use() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} " || \
  netstat -tlnp 2>/dev/null | grep -q ":${port} " || \
  lsof -iTCP:"${port}" -sTCP:LISTEN -t &>/dev/null
}

# ──────────────────────────────────────────────────────────────
# DOCKER COMPOSE  (FIX: tmpfs НЕ перекрывает volume с конфигом)
# ──────────────────────────────────────────────────────────────
# Правильная схема:
#   - config.toml монтируется в /etc/telemt/config.toml:ro
#   - tmpfs вешается на /tmp (для tlsfront-кэша TLS)
#   - working_dir: /tmp  (telemt пишет tlsfront/ туда)
#   - НЕ вешаем tmpfs на /etc/telemt — иначе volume пропадает
# ──────────────────────────────────────────────────────────────
write_compose() {
  mkdir -p "${INSTALL_DIR}"
  cat > "${COMPOSE_FILE}" <<CEOF
services:
  telemt:
    image: ${DOCKER_IMAGE}
    container_name: telemt
    restart: unless-stopped
    command: ["/app/telemt", "/app/config.toml"]
    ports:
      - "${PROXY_PORT}:${PROXY_PORT}"
      - "127.0.0.1:${METRICS_PORT}:9091"
    volumes:
      - ${CONFIG_FILE}:/app/config.toml:ro
    tmpfs:
      - /tmp:rw,mode=1777,size=16m
      - /etc/telemt:rw,mode=1777,size=8m
    environment:
      - RUST_LOG=info
    healthcheck:
      test: ["CMD", "/app/telemt", "healthcheck", "/app/config.toml", "--mode", "liveness"]
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
  log_ok "docker-compose.yml written (port ${PROXY_PORT}, metrics 127.0.0.1:${METRICS_PORT})"
}

# ──────────────────────────────────────────────────────────────
# CONFIG TOML
# ──────────────────────────────────────────────────────────────
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
    tls)     tv="true" ;;
    secure)  sv="true" ;;
    classic) cv="true" ;;
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
    echo "[metrics]"
    echo "port = 9091"
    echo "whitelist = [\"127.0.0.1\"]"
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
}

# ──────────────────────────────────────────────────────────────
# PROXY CONTROL
# ──────────────────────────────────────────────────────────────
do_start() {
  command -v docker &>/dev/null || { log_err "Docker not installed."; return 1; }
  write_config
  write_compose
  docker compose -f "${COMPOSE_FILE}" up -d --pull always 2>&1 | tail -5
  sleep 3
  if is_running; then log_ok "Proxy started on port ${PROXY_PORT}"
  else log_err "Failed — check logs (option 6)"; docker compose -f "${COMPOSE_FILE}" logs --tail=30; fi
}

do_stop() {
  [[ -f "${COMPOSE_FILE}" ]] || { log_warn "Not installed"; return; }
  docker compose -f "${COMPOSE_FILE}" down && log_ok "Proxy stopped"
}

do_restart() {
  write_config
  write_compose
  [[ -f "${COMPOSE_FILE}" ]] && docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
  docker compose -f "${COMPOSE_FILE}" up -d 2>&1 | tail -3
  sleep 2
  is_running && log_ok "Proxy restarted" || log_err "Restart failed"
}

do_update() {
  draw_header "UPDATE TELEMT"
  log_info "Pulling latest image..."
  docker pull "${DOCKER_IMAGE}" 2>&1 | tail -5
  log_ok "Image updated"
  if is_running; then
    log_info "Restarting with new image..."
    do_restart
  fi
  press_enter
}

# ──────────────────────────────────────────────────────────────
# METRICS / STATISTICS
# ──────────────────────────────────────────────────────────────
fetch_metrics() {
  curl -s --max-time 3 "http://127.0.0.1:${METRICS_PORT}/metrics" 2>/dev/null || echo ""
}

# Возвращает значение конкретной метрики по имени и label
get_metric_value() {
  local metrics="$1" name="$2" label_key="$3" label_val="$4"
  if [[ -n "${label_key}" ]]; then
    echo "${metrics}" | grep "^${name}{" | grep "${label_key}=\"${label_val}\"" | \
      awk '{print $NF}' | head -1
  else
    echo "${metrics}" | grep "^${name} " | awk '{print $NF}' | head -1
  fi
}

format_bytes() {
  local bytes="${1:-0}"
  bytes="${bytes%%.*}"  # обрезаем дробь если есть
  [[ -z "${bytes}" || "${bytes}" == "0" ]] && { echo "0 B"; return; }
  if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; ${bytes}/1073741824" | bc)"
  elif (( bytes >= 1048576 ))   ; then printf "%.1f MB" "$(echo "scale=1; ${bytes}/1048576" | bc)"
  elif (( bytes >= 1024 ))      ; then printf "%.1f KB" "$(echo "scale=1; ${bytes}/1024" | bc)"
  else echo "${bytes} B"
  fi
}

show_stats() {
  draw_header "TRAFFIC & STATS"
  echo
  if ! is_running; then
    log_warn "Proxy is not running."; press_enter; return
  fi
  set +eo pipefail 2>/dev/null || true

  local logs; logs=$(docker logs telemt --tail=1000 --no-color 2>/dev/null)

  local total_conns=0 unique_ips=0 last_ip="" errors=0 uptime_str=""
  total_conns=$(echo "${logs}" | grep -c "Connection closed" 2>/dev/null); total_conns=${total_conns:-0}
  unique_ips=$(echo "${logs}" | grep -oE "peer=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" 2>/dev/null | sort -u | wc -l); unique_ips=${unique_ips:-0}
  last_ip=$(echo "${logs}" | grep "Connection closed" 2>/dev/null | tail -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1); last_ip=${last_ip:-""}
  errors=$(echo "${logs}" | grep -c " ERROR\| WARN" 2>/dev/null); errors=${errors:-0}

  local started; started=$(docker inspect telemt --format='{{.State.StartedAt}}' 2>/dev/null || true)
  if [[ -n "${started}" ]]; then
    local start_epoch; start_epoch=$(date -d "${started}" +%s 2>/dev/null || echo "0")
    local diff=$(( $(date +%s) - start_epoch ))
    local d=$(( diff/86400 )) h=$(( (diff%86400)/3600 )) m=$(( (diff%3600)/60 ))
    [[ $d -gt 0 ]] && uptime_str="${d}d ${h}h ${m}m" || \
    { [[ $h -gt 0 ]] && uptime_str="${h}h ${m}m" || uptime_str="${m}m"; }
  fi

  printf "  ${DIM}%-22s${NC}  %s\n" "Uptime:"           "${uptime_str:-unknown}"
  printf "  ${DIM}%-22s${NC}  %s\n" "Sessions (log):"   "${total_conns}"
  printf "  ${DIM}%-22s${NC}  %s\n" "Unique IPs seen:"  "${unique_ips}"
  [[ -n "${last_ip}" ]] && \
  printf "  ${DIM}%-22s${NC}  %s\n" "Last client IP:"   "${last_ip}"
  printf "  ${DIM}%-22s${NC}  %s\n" "Warnings/Errors:"  "${errors}"
  echo

  if [[ -f "${SECRETS_FILE}" ]] && [[ -s "${SECRETS_FILE}" ]]; then
    echo -e "  ${BOLD}Users:${NC}"
    echo -e "  ${DIM}$(_rep '─' 36)${NC}"
    while IFS="|" read -r label secret enabled; do
      [[ "${label}" =~ ^# ]] || [[ -z "${label}" ]] && continue
      local sym
      [[ "${enabled}" == "enabled" ]] && sym="${LGREEN}● active${NC}" || sym="${LRED}○ disabled${NC}"
      printf "  %-20s  %b\n" "${label}" "${sym}"
    done < "${SECRETS_FILE}"
  fi
  echo
  press_enter
}

# ──────────────────────────────────────────────────────────────
# TUI DRAWING
# ──────────────────────────────────────────────────────────────

# Ширина терминала, макс 80
TERM_W=$(tput cols 2>/dev/null || echo 70)
[[ $TERM_W -gt 120 ]] && TERM_W=120
[[ $TERM_W -lt 50 ]]  && TERM_W=60

# Длина строки без ANSI — через printf + sed (надёжно для любых escape-последовательностей)
_strlen() {
  local clean
  clean=$(printf '%b' "$1" | sed 's/\[[0-9;]*m//g; s/[^[]*//g')
  echo "${#clean}"
}

# Повторить символ N раз (pure bash, без subshell)
_rep() {
  local char="$1" n="$2" str
  printf -v str '%*s' "$n" ''
  printf '%s' "${str// /$char}"
}

# Строка рамки с текстом по центру
# $1 = текст (может содержать цвета), $2 = тот же текст без цветов
_box_center() {
  local text="$1" plain="$2" inner=$(( TERM_W - 2 ))
  local len=${#plain}
  local lpad=$(( (inner - len) / 2 ))
  local rpad=$(( inner - len - lpad ))
  [[ $lpad -lt 0 ]] && lpad=0
  [[ $rpad -lt 0 ]] && rpad=0
  echo -ne "${CYAN}║${NC}"
  _rep ' ' $lpad
  echo -ne "$text"
  _rep ' ' $rpad
  echo -e "${CYAN}║${NC}"
}

# KV строка внутри рамки
_box_kv() {
  local label="$1" val="$2"
  local inner=$(( TERM_W - 2 ))
  local vclean; vclean=$(echo -e "$val" | sed "s/\[[0-9;]*m//g")
  local prefix="  ${label}   "
  local pad=$(( inner - ${#prefix} - ${#vclean} ))
  [[ $pad -lt 0 ]] && pad=0
  echo -ne "${CYAN}║${NC}${DIM}${prefix}${NC}"
  echo -ne "$val"
  _rep ' ' $pad
  echo -e "${CYAN}║${NC}"
}

# Пункт меню (без рамки, просто строка)
_menu_item() {
  local key="$1" label="$2" red="${3:-}"
  if [[ -n "$red" ]]; then
    printf "  ${BOLD}${LRED}[%s]${NC}  %b
" "$key" "$label"
  else
    printf "  ${BOLD}${CYAN}[%s]${NC}  %b
" "$key" "$label"
  fi
}

# Верх/низ/разделитель рамки
_box_top()  { printf "${CYAN}╔%s╗${NC}
" "$(_rep '═' $((TERM_W-2)))"; }
_box_bot()  { printf "${CYAN}╚%s╝${NC}
" "$(_rep '═' $((TERM_W-2)))"; }
_box_sep()  { printf "${CYAN}╠%s╣${NC}
" "$(_rep '═' $((TERM_W-2)))"; }
_box_sep2() { printf "${CYAN}╟%s╢${NC}
" "$(_rep '─' $((TERM_W-2)))"; }
_box_empty(){ printf "${CYAN}║%s║${NC}
" "$(_rep ' ' $((TERM_W-2)))"; }

draw_header() {
  local title="$1"
  clear; echo
  _box_top
  _box_center "${BOLD}${WHITE}${title}${NC}" "${title}"
  _box_bot
  echo
}

draw_section() {
  echo
  printf "  ${BOLD}${CYAN}%b${NC}
" "$*"
  printf "  ${DIM}%s${NC}
" "$(_rep '─' $((TERM_W-6)))"
}

draw_row()    { printf "  ${DIM}%-12s${NC}  %b
" "$1" "$2"; }
press_enter() { echo; printf "  ${DIM}Press [Enter]...${NC}"; read -r; }
read_choice() { echo; printf "  ${BOLD}${CYAN}[?]${NC} %s: " "${1:-Option}"; read -r CHOICE; }

_draw_menu_box() {
  TERM_W=$(tput cols 2>/dev/null || echo 70)
  [[ $TERM_W -gt 120 ]] && TERM_W=120
  [[ $TERM_W -lt 50 ]]  && TERM_W=60
  echo
  printf "${CYAN}╔%s╗${NC}
" "$(_rep '═' $((TERM_W-2)))"
  _box_center "${BOLD}${WHITE}$1${NC}" "$1"
  printf "${CYAN}╠%s╣${NC}
" "$(_rep '═' $((TERM_W-2)))"
  echo
}

_draw_menu_bottom() {
  echo
  printf "${CYAN}╚%s╝${NC}
" "$(_rep '═' $((TERM_W-2)))"
}

show_status() {
  # Обновляем ширину терминала каждый раз
  TERM_W=$(tput cols 2>/dev/null || echo 70)
  [[ $TERM_W -gt 120 ]] && TERM_W=120
  [[ $TERM_W -lt 50 ]]  && TERM_W=60

  local ip rs_text rs_color is_text uc=0 traffic_info="" conns="—"
  ip=$(get_ip)

  if is_running; then
    rs_text="● RUNNING"; rs_color="${LGREEN}"
    local m; m=$(curl -s --max-time 1 "http://127.0.0.1:${METRICS_PORT}/metrics" 2>/dev/null || true)
    if [[ -n "${m}" ]]; then
      conns=$(echo "${m}" | grep "^telemt_connections_active " | awk '{print $NF}' 2>/dev/null || echo "0")
      local rx tx
      rx=$(echo "${m}" | grep "^telemt_bytes_received_total " | awk '{print $NF}' 2>/dev/null || echo "0")
      tx=$(echo "${m}" | grep "^telemt_bytes_sent_total "     | awk '{print $NF}' 2>/dev/null || echo "0")
      traffic_info="↓ $(format_bytes "${rx:-0}")  ↑ $(format_bytes "${tx:-0}")"
    fi
  else
    rs_text="○ STOPPED"; rs_color="${LRED}"
  fi

  if [[ -f "${INSTALL_DIR}/.installed" ]]; then
    is_text="${LGREEN}Installed${NC}"
    [[ -f "${SECRETS_FILE}" ]] && uc=$(grep -c '|' "${SECRETS_FILE}" 2>/dev/null || echo 0)
  else
    is_text="${YELLOW}Not installed${NC}"
    uc=0
  fi

  clear; echo
  _box_top
  _box_center "${BOLD}${WHITE} TELEVISION  v${VERSION}${NC}" " TELEVISION  v${VERSION}"
  _box_center "${DIM}Telegram MTProxy - Rust/tokio - J-L33T${NC}" "Telegram MTProxy - Rust/tokio - J-L33T"
  _box_sep
  _box_kv "Engine " "telemt :latest  Status: ${rs_color}${rs_text}${NC}"
  _box_kv "IP:Port" "${WHITE}${ip}:${PROXY_PORT}${NC}"
  _box_kv "Domain " "${PROXY_DOMAIN}"
  [[ -n "${traffic_info}" ]] && _box_kv "Traffic" "${DIM}${traffic_info}${NC}  Conns: ${WHITE}${conns}${NC}"
  _box_kv "Secrets" "${uc} active"
  _box_bot
  echo
}

# ──────────────────────────────────────────────────────────────
# INSTALL DEPS
# ──────────────────────────────────────────────────────────────
install_deps() {
  log_info "Checking dependencies..."
  local pkgs=()
  command -v docker  &>/dev/null || pkgs+=(docker.io docker-compose-plugin)
  command -v curl    &>/dev/null || pkgs+=(curl)
  command -v xxd     &>/dev/null || pkgs+=(xxd)
  command -v openssl &>/dev/null || pkgs+=(openssl)
  command -v bc      &>/dev/null || pkgs+=(bc)
  command -v ss      &>/dev/null || pkgs+=(iproute2)
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
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  systemctl enable --now docker 2>/dev/null || true
  log_ok "Dependencies ready"
}

# ──────────────────────────────────────────────────────────────
# SELF-INSTALL (бинарь + systemd watcher)
# ──────────────────────────────────────────────────────────────
do_self_install() {
  # Если уже на месте — ничего не делаем
  if [[ "$(realpath "$0" 2>/dev/null)" == "${SELF_BIN}" ]]; then
    log_ok "Binary already at ${SELF_BIN}"
  elif [[ -f "$0" ]] && [[ "$0" != /proc/* ]]; then
    # Запущен из реального файла
    cp "$0" "${SELF_BIN}"
    chmod +x "${SELF_BIN}"
    log_ok "Installed to ${SELF_BIN}"
  else
    # Запущен через pipe (bash <(curl ...)) — скачиваем с GitHub
    local repo_url="https://raw.githubusercontent.com/J-L33T/television/main/television.sh"
    if curl -fsSL "${repo_url}" -o "${SELF_BIN}" 2>/dev/null; then
      chmod +x "${SELF_BIN}"
      log_ok "Downloaded and installed to ${SELF_BIN}"
    else
      log_warn "Could not install to ${SELF_BIN} — run 'television self-install' later"
      return 0
    fi
  fi

  # Создаём systemd сервис для автозапуска прокси при перезагрузке сервера
  cat > /etc/systemd/system/television.service << 'UNIT'
[Unit]
Description=Television MTProxy
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose -f /opt/television/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/television/docker-compose.yml down

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable television.service 2>/dev/null || true
  log_ok "Systemd service installed — proxy will auto-start on reboot"
  log_ok "You can now run: ${BOLD}television${NC}"
}

# ──────────────────────────────────────────────────────────────
# INSTALL WIZARD
# ──────────────────────────────────────────────────────────────
do_install() {
  draw_header "INSTALL TELEVISION"
  install_deps

  echo; draw_section "CONFIGURATION"; echo

  # Порт — с проверкой на занятость
  while true; do
    printf "  Proxy port [%s]: " "${PROXY_PORT}"; read -r i
    [[ -n "${i}" ]] && PROXY_PORT="${i}"
    if port_in_use "${PROXY_PORT}"; then
      log_warn "Port ${PROXY_PORT} is already in use! (hint: try 4443 or 8443)"
      printf "  Enter a different port: "; read -r i
      [[ -n "${i}" ]] && PROXY_PORT="${i}" || continue
      continue
    fi
    break
  done

  printf "  FakeTLS domain [%s]: " "${PROXY_DOMAIN}"; read -r i; [[ -n "${i}" ]] && PROXY_DOMAIN="${i}"

  echo -e "  Protocol:"
  echo -e "    ${BOLD}${CYAN}1)${NC} tls     ${DIM}(FakeTLS — recommended)${NC}"
  echo -e "    ${BOLD}${CYAN}2)${NC} secure  ${DIM}(MTProto secure)${NC}"
  echo -e "    ${BOLD}${CYAN}3)${NC} classic ${DIM}(MTProto classic)${NC}"
  echo -e "    ${BOLD}${CYAN}4)${NC} all     ${DIM}(all protocols)${NC}"
  printf "  Choice [1]: "; read -r i
  case "${i}" in 2) PROXY_PROTOCOL="secure" ;; 3) PROXY_PROTOCOL="classic" ;; 4) PROXY_PROTOCOL="all" ;; *) PROXY_PROTOCOL="tls" ;; esac

  printf "  Custom IP (blank=auto-detect): "; read -r i; [[ -n "${i}" ]] && CUSTOM_IP="${i}"

  # Порт метрик (не должен пересекаться)
  printf "  Metrics port [%s]: " "${METRICS_PORT}"; read -r i; [[ -n "${i}" ]] && METRICS_PORT="${i}"

  echo; draw_section "FIRST USER"
  printf "  Username [default]: "; read -r fl; [[ -z "${fl}" ]] && fl="default"
  local fs; fs=$(gen_secret)
  mkdir -p "${INSTALL_DIR}"
  echo "${fl}|${fs}|enabled" > "${SECRETS_FILE}"

  save_settings
  write_config
  write_compose

  log_info "Pulling Docker image (may take a minute)..."
  docker pull "${DOCKER_IMAGE}" 2>&1 | tail -3
  docker compose -f "${COMPOSE_FILE}" up -d 2>&1 | tail -5
  sleep 3
  touch "${INSTALL_DIR}/.installed"

  # Self-install в /usr/local/bin
  do_self_install

  echo; draw_section "YOUR PROXY LINK"; echo
  local link; link=$(proxy_link "${fs}" "${PROXY_DOMAIN}")
  echo -e "  ${BOLD}${WHITE}User: ${fl}${NC}"
  echo -e "  ${LGREEN}${link}${NC}"
  echo "${fl}: ${link}" > "${LINKS_FILE}"
  echo; log_ok "Installation complete!"; press_enter
}

# ──────────────────────────────────────────────────────────────
# USER MANAGEMENT
# ──────────────────────────────────────────────────────────────
list_users_inline() {
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
  echo; log_ok "User '${label}' added!"
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
  write_config; do_restart
  log_ok "User '${label}' removed."; press_enter
}

toggle_user() {
  draw_header "TOGGLE USER"
  echo; list_users_inline || { sleep 2; return; }
  read_choice "Username to toggle"; local label="${CHOICE}"
  grep -q "^${label}|" "${SECRETS_FILE}" 2>/dev/null || { log_warn "User not found."; press_enter; return; }
  if grep -q "^${label}|.*|enabled$" "${SECRETS_FILE}"; then
    sed -i "s/^${label}|\(.*\)|enabled$/${label}|\1|disabled/" "${SECRETS_FILE}"
    log_ok "User '${label}' disabled."
  else
    sed -i "s/^${label}|\(.*\)|disabled$/${label}|\1|enabled/" "${SECRETS_FILE}"
    log_ok "User '${label}' enabled."
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
    show_status
    _draw_menu_box "SECRET MANAGEMENT"
    list_users_inline || true
    echo
    _menu_item "1" "Add user"
    _menu_item "2" "Remove user"
    _menu_item "3" "Toggle (enable/disable)"
    _menu_item "4" "Show proxy links"
    _menu_item "5" "User statistics"
    echo
    _menu_item "0" "Back"
    _draw_menu_bottom
    read_choice "Option"
    case "${CHOICE}" in
      1) add_user ;; 2) remove_user ;; 3) toggle_user ;;
      4) show_links ;; 5) show_stats ;; 0) return ;;
    esac
  done
}

# ──────────────────────────────────────────────────────────────
# LOGS & RECONFIGURE & UNINSTALL
# ──────────────────────────────────────────────────────────────
show_logs() {
  draw_header "LOGS"
  [[ -f "${COMPOSE_FILE}" ]] || { log_warn "Not installed"; press_enter; return; }
  set +eo pipefail 2>/dev/null || true
  echo -e "  ${DIM}Showing important events (errors, connections, startup)${NC}\n"
  local raw; raw=$(docker logs telemt --tail=200 --no-color 2>&1)
  local filtered; filtered=$(echo "${raw}" | grep -E "ERROR|WARN|Listening|ME pool READY|ME startup|Downloaded proxy-secret|Connection closed|config watcher" 2>/dev/null | tail -30)
  if [[ -z "${filtered}" ]]; then
    log_dim "No notable events found in recent logs."
  else
    echo "${filtered}" |       sed "s/telemt  | //" |       sed "s/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T\([0-9:]\{8\}\)\.[0-9]*Z/\1/" |       while IFS= read -r line; do
        if echo "${line}" | grep -q "ERROR"; then
          echo -e "  ${LRED}${line}${NC}"
        elif echo "${line}" | grep -q "WARN"; then
          echo -e "  ${YELLOW}${line}${NC}"
        elif echo "${line}" | grep -q "Listening\|ME pool READY\|Downloaded"; then
          echo -e "  ${LGREEN}${line}${NC}"
        else
          echo -e "  ${DIM}${line}${NC}"
        fi
      done
  fi
  echo
  echo -e "  ${DIM}(full logs: sudo docker logs telemt -f)${NC}"
  press_enter
}

do_reconfigure() {
  draw_header "RECONFIGURE"; echo
  log_info "Change settings (Enter = keep current):"; echo

  # Порт с проверкой
  while true; do
    printf "  Port [%s]: " "${PROXY_PORT}"; read -r i
    local new_port="${PROXY_PORT}"
    [[ -n "${i}" ]] && new_port="${i}"
    if [[ "${new_port}" != "${PROXY_PORT}" ]] && port_in_use "${new_port}"; then
      log_warn "Port ${new_port} is already in use! (hint: try 4443 or 8443)"
      printf "  Enter a different port: "; read -r i
      [[ -n "${i}" ]] && new_port="${i}" || continue
      continue
    fi
    PROXY_PORT="${new_port}"; break
  done

  printf "  FakeTLS domain [%s]: " "${PROXY_DOMAIN}"; read -r i; [[ -n "${i}" ]] && PROXY_DOMAIN="${i}"
  echo -e "  Protocol: ${DIM}[current: ${PROXY_PROTOCOL}]${NC}"
  echo -e "    ${BOLD}${CYAN}1)${NC} tls  ${BOLD}${CYAN}2)${NC} secure  ${BOLD}${CYAN}3)${NC} classic  ${BOLD}${CYAN}4)${NC} all"
  printf "  Choice (Enter=keep): "; read -r i
  case "${i}" in 1) PROXY_PROTOCOL="tls" ;; 2) PROXY_PROTOCOL="secure" ;; 3) PROXY_PROTOCOL="classic" ;; 4) PROXY_PROTOCOL="all" ;; esac
  printf "  Custom IP [%s] (-=clear): " "${CUSTOM_IP:-auto}"; read -r i
  [[ "${i}" == "-" ]] && CUSTOM_IP="" || [[ -n "${i}" ]] && CUSTOM_IP="${i}"
  printf "  Metrics port [%s]: " "${METRICS_PORT}"; read -r i; [[ -n "${i}" ]] && METRICS_PORT="${i}"

  save_settings; write_config; write_compose
  is_running && { log_info "Restarting..."; do_restart; }
  log_ok "Reconfigured!"; press_enter
}

do_uninstall() {
  draw_header "UNINSTALL"; echo
  log_warn "This will STOP and REMOVE all proxy data and configuration."
  printf "  Type 'yes' to confirm: "; read -r confirm
  [[ "${confirm}" != "yes" ]] && { log_info "Cancelled."; press_enter; return; }
  systemctl disable --now television.service 2>/dev/null || true
  rm -f /etc/systemd/system/television.service
  systemctl daemon-reload 2>/dev/null || true

  [[ -f "${COMPOSE_FILE}" ]] && docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  docker stop telemt 2>/dev/null || true
  docker rm telemt 2>/dev/null || true
  docker rmi "${DOCKER_IMAGE}" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}"
  [[ -f "${SELF_BIN}" ]] && rm -f "${SELF_BIN}" && log_ok "Removed ${SELF_BIN}"
  log_ok "Television uninstalled."; press_enter; exit 0
}

# ──────────────────────────────────────────────────────────────
# MAIN MENU
# ──────────────────────────────────────────────────────────────
menu_item() {
  # menu_item "1" "Start proxy"  или  menu_item "u" "Uninstall" "red"
  local key="$1" label="$2" color="${3:-}"
  if [[ "${color}" == "red" ]]; then
    echo -e "${CYAN}║${NC}  ${BOLD}${LRED}[${key}]${NC}  ${label}"
  else
    echo -e "${CYAN}║${NC}  ${BOLD}${CYAN}[${key}]${NC}  ${label}"
  fi
}

main_menu() {
  load_settings
  show_banner
  # Если запущен не из /usr/local/bin — предложить установить
  if [[ "$(realpath "$0" 2>/dev/null)" != "${SELF_BIN}" ]] && [[ ! -f "${SELF_BIN}" ]]; then
    echo -e "  ${YELLOW}!${NC}  Script is not installed as a system command."
    printf "  Install as '${BOLD}television${NC}' command? [Y/n]: "; read -r yn
    if [[ "${yn,,}" != "n" ]]; then
      do_self_install
      echo
    fi
  fi
  while true; do
    show_status
    if [[ -f "${INSTALL_DIR}/.installed" ]]; then
      _draw_menu_box "MAIN MENU"
      _menu_item "1" "Proxy Management  ${DIM}(start / stop / restart)${NC}"
      _menu_item "2" "Secret Management ${DIM}(add / remove / toggle)${NC}"
      _menu_item "3" "Share Links"
      _menu_item "4" "Traffic & Stats"
      _menu_item "5" "Logs"
      _menu_item "6" "Settings          ${DIM}(port / domain / reconfigure)${NC}"
      _menu_item "7" "Update telemt"
      echo
      _menu_item "u" "Uninstall" "red"
      _menu_item "0" "Exit"
      if [[ "$(realpath "$0" 2>/dev/null)" != "${SELF_BIN}" ]]; then
        echo
        _menu_item "s" "Install as '${BOLD}television${NC}' command"
      fi
    else
      _draw_menu_box "MAIN MENU"
      _menu_item "1" "Install television"
      if [[ "$(realpath "$0" 2>/dev/null)" != "${SELF_BIN}" ]]; then
        _menu_item "s" "Install as '${BOLD}television${NC}' command"
      fi
      echo
      _menu_item "0" "Exit"
    fi
    _draw_menu_bottom
    read_choice "Option"
    if [[ -f "${INSTALL_DIR}/.installed" ]]; then
      case "${CHOICE}" in
        1) proxy_mgmt_menu ;;
        2) user_menu ;;
        3) show_links ;;
        4) show_stats ;;
        5) show_logs ;;
        6) do_reconfigure ;;
        7) do_update ;;
        u|U) do_uninstall ;;
        s|S) do_self_install; press_enter ;;
        0) exit 0 ;;
        *) log_warn "Invalid option"; sleep 1 ;;
      esac
    else
      case "${CHOICE}" in
        1) do_install ;;
        s|S) do_self_install; press_enter ;;
        0) exit 0 ;;
        *) log_warn "Invalid option"; sleep 1 ;;
      esac
    fi
  done
}

proxy_mgmt_menu() {
  while true; do
    show_status
    _draw_menu_box "PROXY MANAGEMENT"
    if is_running; then
      _menu_item "1" "Stop proxy"
      _menu_item "2" "Restart proxy"
    else
      _menu_item "1" "Start proxy"
    fi
    echo
    _menu_item "0" "Back"
    _draw_menu_bottom
    read_choice "Option"
    case "${CHOICE}" in
      1) is_running && { do_stop; press_enter; } || { do_start; press_enter; } ;;
      2) is_running && { do_restart; press_enter; } || { log_warn "Proxy is not running"; sleep 1; } ;;
      0) return ;;
    esac
  done
}

# ──────────────────────────────────────────────────────────────
# CLI MODE
# ──────────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
  load_settings
  case "$1" in
    install)    do_install ;;
    start)      do_start ;;
    stop)       do_stop ;;
    restart)    do_restart ;;
    update)     do_update ;;
    status)
      show_status
      is_running && log_ok "Running" || log_warn "Stopped"
      ;;
    logs)       show_logs ;;
    stats)      show_stats ;;
    self-install)
      do_self_install
      ;;
    add-user)
      [[ -z "$2" ]] && { echo "Usage: $0 add-user <name>"; exit 1; }
      secret=$(gen_secret)
      echo "$2|${secret}|enabled" >> "${SECRETS_FILE}"
      write_config; do_restart
      log_ok "Added: $2"
      proxy_link "${secret}"
      ;;
    list-users)
      [[ -f "${SECRETS_FILE}" ]] && cut -d'|' -f1,3 "${SECRETS_FILE}" || echo "No users"
      ;;
    links)
      [[ -f "${SECRETS_FILE}" ]] || exit 0
      while IFS="|" read -r label secret enabled; do
        [[ "${label}" =~ ^# ]] || [[ -z "${label}" ]] && continue
        echo "${label}: $(proxy_link "${secret}")"
      done < "${SECRETS_FILE}"
      ;;
    *)
      echo "Usage: $0 {install|start|stop|restart|update|status|logs|stats|self-install|add-user <n>|list-users|links}"
      exit 1
      ;;
  esac
  exit 0
fi

main_menu

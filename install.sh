#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_INSTALL_DIR="/opt/remnanode"
readonly DEFAULT_NODE_PORT="2222"
readonly DEFAULT_NODE_IMAGE="remnawave/node:latest"

INSTALL_DIR="${REMNAWAVE_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
NODE_PORT="${REMNAWAVE_NODE_PORT:-$DEFAULT_NODE_PORT}"
NODE_IMAGE="${REMNAWAVE_NODE_IMAGE:-$DEFAULT_NODE_IMAGE}"
SECRET_KEY="${REMNAWAVE_SECRET_KEY:-}"
OPEN_UFW="${REMNAWAVE_OPEN_UFW:-}"
BACKUP_DIR=""
COMPOSE_FILE=""
HAD_EXISTING_INSTALL="false"

if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_RED=$'\033[31m'
  readonly C_CYAN=$'\033[36m'
else
  readonly C_RESET=""
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_RED=""
  readonly C_CYAN=""
fi

log() { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fatal() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '%s[ERROR]%s Сбой в строке %s (код %s).\n' \
    "$C_RED" "$C_RESET" "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<'EOF'
Интерактивная установка или обновление Remnawave Node.

Использование:
  sudo bash install.sh
  curl -fsSL RAW_URL/install.sh | sudo bash

Неинтерактивные переменные:
  REMNAWAVE_SECRET_KEY       секрет ноды (лучше использовать *_FILE)
  REMNAWAVE_SECRET_KEY_FILE  файл с секретом ноды
  REMNAWAVE_NODE_PORT        порт панели -> нода (по умолчанию 2222)
  REMNAWAVE_NODE_IMAGE       образ/тег (по умолчанию remnawave/node:latest)
  REMNAWAVE_INSTALL_DIR      каталог (по умолчанию /opt/remnanode)
  REMNAWAVE_OPEN_UFW         yes или no
  REMNAWAVE_ASSUME_YES       yes — принять ответы по умолчанию
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Запустите скрипт от root: sudo bash install.sh"
[[ "$(uname -s)" == "Linux" ]] || fatal "Поддерживается только Linux."

has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

ask_default() {
  local prompt=$1
  local default=$2
  local value=""

  if [[ "${REMNAWAVE_ASSUME_YES:-no}" == "yes" ]] || ! has_tty; then
    printf '%s' "$default"
    return
  fi

  read -r -p "$prompt [$default]: " value </dev/tty
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt=$1
  local default=${2:-yes}
  local hint="Y/n"
  local answer=""

  [[ "$default" == "no" ]] && hint="y/N"
  if [[ "${REMNAWAVE_ASSUME_YES:-no}" == "yes" ]] || ! has_tty; then
    [[ "$default" == "yes" ]]
    return
  fi

  read -r -p "$prompt [$hint]: " answer </dev/tty
  answer=${answer:-$default}
  [[ "$answer" =~ ^([yY]|[yY][eE][sS]|[дД]|[дД][аА])$ ]]
}

normalize_secret() {
  local value=$1
  value=${value#SECRET_KEY=}
  if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
    value=${value:1:${#value}-2}
  elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "$value"
}

validate_secret() {
  local secret_json=""

  [[ -n "$SECRET_KEY" ]] || fatal "SECRET_KEY не может быть пустым."
  if ! secret_json=$(printf '%s' "$SECRET_KEY" | base64 --decode 2>/dev/null); then
    fatal "SECRET_KEY не является корректной строкой Base64. Скопируйте ключ из панели целиком."
  fi

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$secret_json" | jq -e '
      (.nodeCertPem | type == "string" and length > 0) and
      (.nodeKeyPem | type == "string" and length > 0) and
      (.caCertPem | type == "string" and length > 0) and
      (.jwtPublicKey | type == "string" and length > 0)
    ' >/dev/null || fatal "В SECRET_KEY нет всех обязательных полей Remnawave."
  else
    local field
    for field in nodeCertPem nodeKeyPem caCertPem jwtPublicKey; do
      grep -q "\"${field}\"" <<<"$secret_json" || fatal "В SECRET_KEY отсутствует поле ${field}."
    done
  fi

  unset secret_json
}

validate_settings() {
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || fatal "Порт должен быть числом."
  (( NODE_PORT >= 1 && NODE_PORT <= 65535 )) || fatal "Порт должен быть от 1 до 65535."
  [[ "$INSTALL_DIR" == /* ]] || fatal "Каталог установки должен быть абсолютным путём."
  case "$INSTALL_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/usr|/var)
      fatal "Выберите отдельный каталог, например /opt/remnanode."
      ;;
  esac
  [[ "$NODE_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]] || fatal "Некорректное имя Docker-образа."
}

ensure_dependencies() {
  local packages=()
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v base64 >/dev/null 2>&1 || packages+=(coreutils)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)

  if ((${#packages[@]} > 0)); then
    command -v apt-get >/dev/null 2>&1 || fatal "Нужны пакеты: ${packages[*]}. Установите их вручную."
    log "Устанавливаю зависимости: ${packages[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker уже установлен: $(docker --version)"
  else
    local installer=""
    installer=$(mktemp /tmp/get-docker.XXXXXX.sh)
    trap 'rm -f "$installer"' RETURN
    log "Docker не найден — загружаю официальный установщик Docker."
    curl --proto '=https' --tlsv1.2 -fsSL https://get.docker.com -o "$installer"
    sh "$installer"
    rm -f "$installer"
    trap - RETURN
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  fi
  docker info >/dev/null 2>&1 || fatal "Docker установлен, но daemon недоступен."
  docker compose version >/dev/null 2>&1 || fatal "Не найден Docker Compose v2."
}

read_existing_value() {
  local key=$1
  local file=$2
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

select_compose_file() {
  local candidate
  for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "$INSTALL_DIR/$candidate" ]]; then
      COMPOSE_FILE="$INSTALL_DIR/$candidate"
      return
    fi
  done
  COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
}

collect_settings() {
  local env_file=""
  local existing_secret=""

  INSTALL_DIR=$(ask_default "Каталог установки" "$INSTALL_DIR")
  env_file="$INSTALL_DIR/.env"
  select_compose_file

  if [[ -f "$COMPOSE_FILE" ]]; then
    HAD_EXISTING_INSTALL="true"
    if ! ask_yes_no "Найдена существующая установка в $INSTALL_DIR. Обновить её?" yes; then
      info "Изменений не внесено."
      exit 0
    fi
  fi

  if [[ -f "$env_file" ]]; then
    if [[ -z "${REMNAWAVE_NODE_PORT+x}" ]]; then
      NODE_PORT=$(read_existing_value NODE_PORT "$env_file")
      NODE_PORT=${NODE_PORT:-$DEFAULT_NODE_PORT}
    fi
    if [[ -z "${REMNAWAVE_NODE_IMAGE+x}" ]]; then
      NODE_IMAGE=$(read_existing_value NODE_IMAGE "$env_file")
      NODE_IMAGE=${NODE_IMAGE:-$DEFAULT_NODE_IMAGE}
    fi
  fi

  NODE_PORT=$(ask_default "Порт ноды" "$NODE_PORT")
  NODE_IMAGE=$(ask_default "Docker-образ и тег ноды" "$NODE_IMAGE")

  if [[ -n "${REMNAWAVE_SECRET_KEY_FILE:-}" ]]; then
    [[ -r "$REMNAWAVE_SECRET_KEY_FILE" ]] || fatal "Не могу прочитать REMNAWAVE_SECRET_KEY_FILE."
    SECRET_KEY=$(tr -d '\r\n' <"$REMNAWAVE_SECRET_KEY_FILE")
  elif [[ -z "$SECRET_KEY" && -f "$env_file" ]]; then
    existing_secret=$(read_existing_value SECRET_KEY "$env_file")
    if [[ -n "$existing_secret" ]] && ask_yes_no "Оставить текущий SECRET_KEY?" yes; then
      SECRET_KEY=$existing_secret
    fi
  fi

  if [[ -z "$SECRET_KEY" ]]; then
    has_tty || fatal "Нет TTY. Передайте секрет через REMNAWAVE_SECRET_KEY_FILE."
    read -r -s -p "SECRET_KEY из панели (ввод скрыт): " SECRET_KEY </dev/tty
    printf '\n' >/dev/tty
  fi

  SECRET_KEY=$(normalize_secret "$SECRET_KEY")
  if [[ "${REMNAWAVE_OPEN_UFW:-}" == "" ]]; then
    if ask_yes_no "Разрешить TCP-порт $NODE_PORT в активном UFW?" yes; then
      OPEN_UFW="yes"
    else
      OPEN_UFW="no"
    fi
  fi
}

backup_existing() {
  local stamp
  stamp=$(date -u +%Y%m%d-%H%M%S)
  BACKUP_DIR="$INSTALL_DIR/backups/$stamp"

  if [[ -f "$COMPOSE_FILE" || -f "$INSTALL_DIR/.env" ]]; then
    mkdir -p "$BACKUP_DIR"
    [[ -f "$COMPOSE_FILE" ]] && cp -a "$COMPOSE_FILE" "$BACKUP_DIR/"
    [[ -f "$INSTALL_DIR/.env" ]] && cp -a "$INSTALL_DIR/.env" "$BACKUP_DIR/"
    log "Резервная копия: $BACKUP_DIR"
  fi
}

write_configuration() {
  local env_tmp compose_tmp
  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_DIR"
  backup_existing

  env_tmp=$(mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")
  compose_tmp=$(mktemp "$INSTALL_DIR/.compose.tmp.XXXXXX")

  printf 'NODE_PORT=%s\nNODE_IMAGE=%s\nSECRET_KEY=%s\n' \
    "$NODE_PORT" "$NODE_IMAGE" "$SECRET_KEY" >"$env_tmp"

  cat >"$compose_tmp" <<'YAML'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE:-remnawave/node:latest}
    network_mode: host
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: ${NODE_PORT:-2222}
      SECRET_KEY: ${SECRET_KEY:?SECRET_KEY is required}
YAML

  chmod 600 "$env_tmp" "$compose_tmp"
  mv -f "$env_tmp" "$INSTALL_DIR/.env"
  mv -f "$compose_tmp" "$COMPOSE_FILE"
}

configure_firewall() {
  [[ "$OPEN_UFW" == "yes" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "$NODE_PORT/tcp" comment 'Remnawave Node'
    log "UFW разрешает TCP/$NODE_PORT."
  else
    info "UFW не активен. Проверьте внешний firewall хостинга: TCP/$NODE_PORT должен быть доступен панели."
  fi
}

restore_previous_configuration() {
  [[ "$HAD_EXISTING_INSTALL" == "true" && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 0
  warn "Возвращаю предыдущую конфигурацию."
  local compose_name
  compose_name=$(basename "$COMPOSE_FILE")
  [[ -f "$BACKUP_DIR/$compose_name" ]] && cp -a "$BACKUP_DIR/$compose_name" "$COMPOSE_FILE"
  [[ -f "$BACKUP_DIR/.env" ]] && cp -a "$BACKUP_DIR/.env" "$INSTALL_DIR/.env"
  docker compose --env-file "$INSTALL_DIR/.env" -f "$COMPOSE_FILE" up -d --force-recreate || true
}

deploy_node() {
  log "Проверяю конфигурацию Docker Compose."
  if ! docker compose --env-file "$INSTALL_DIR/.env" -f "$COMPOSE_FILE" config --quiet; then
    restore_previous_configuration
    fatal "Конфигурация Docker Compose некорректна."
  fi

  log "Загружаю свежий образ $NODE_IMAGE."
  if ! docker compose --env-file "$INSTALL_DIR/.env" -f "$COMPOSE_FILE" pull remnanode; then
    restore_previous_configuration
    fatal "Не удалось загрузить образ ноды."
  fi

  log "Запускаю Remnawave Node."
  if ! docker compose --env-file "$INSTALL_DIR/.env" -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans; then
    restore_previous_configuration
    fatal "Не удалось запустить контейнер."
  fi
}

wait_for_node() {
  local running restarts
  for _ in {1..30}; do
    running=$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || true)
    if [[ "$running" == "true" ]] && docker logs remnanode 2>&1 | grep -q 'Nest application successfully started'; then
      restarts=$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null || printf '?')
      log "Нода запущена (перезапусков: $restarts)."
      return 0
    fi
    sleep 2
  done

  docker logs --tail 80 remnanode 2>&1 || true
  restore_previous_configuration
  fatal "Нода не стала готовой за 60 секунд. Последние строки журнала показаны выше."
}

show_result() {
  local node_version xray_version image_id
  node_version=$(docker logs remnanode 2>&1 | sed -n 's/.*Remnawave Node v\([^[:space:]]*\).*/\1/p' | tail -n 1)
  xray_version=$(docker logs remnanode 2>&1 | sed -n 's/.*XRay Core v\([^[:space:]]*\).*/\1/p' | tail -n 1)
  image_id=$(docker inspect -f '{{.Image}}' remnanode)

  printf '\n'
  log "Установка завершена."
  printf '  Каталог:       %s\n' "$INSTALL_DIR"
  printf '  Порт:          %s/tcp\n' "$NODE_PORT"
  printf '  Образ:         %s\n' "$NODE_IMAGE"
  printf '  Image ID:      %s\n' "$image_id"
  [[ -n "$node_version" ]] && printf '  Версия ноды:   %s\n' "$node_version"
  [[ -n "$xray_version" ]] && printf '  Версия Xray:   %s\n' "$xray_version"
  printf '\n'
  info "Добавьте адрес этого сервера и порт $NODE_PORT в соответствующую ноду панели."
  info "Проверка: cd '$INSTALL_DIR' && docker compose ps && docker compose logs -f --tail=100"
}

main() {
  printf 'Remnawave Node Installer v%s\n\n' "$SCRIPT_VERSION"
  collect_settings
  validate_settings
  ensure_dependencies
  validate_secret
  install_docker
  write_configuration
  configure_firewall
  deploy_node
  wait_for_node
  show_result
}

main "$@"

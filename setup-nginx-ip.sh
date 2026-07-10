#!/usr/bin/env bash
set -Eeuo pipefail

# Publishes Monkey Wisdom on the server's public IP over HTTP port 80.
# Nginx listens on every network interface and proxies requests internally
# to FastAPI on 127.0.0.1:8000.

SITE_PORT="${SITE_PORT:-8000}"
HTTP_PORT="${HTTP_PORT:-80}"
SERVICE_NAME="monkey-wisdom"
NGINX_SITE="/etc/nginx/sites-available/${SERVICE_NAME}"
NGINX_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}"

log() { printf '\n\033[1;32m[Monkey Wisdom]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[Ошибка]\033[0m %s\n' "$*" >&2; exit 1; }
as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  fail "Запусти скрипт от root или установи sudo."
fi

if ! [[ "${SITE_PORT}" =~ ^[0-9]+$ && "${HTTP_PORT}" =~ ^[0-9]+$ ]]; then
  fail "SITE_PORT и HTTP_PORT должны быть номерами портов."
fi

backend_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${SITE_PORT}/api/health" || true)"
if [[ "${backend_code}" != "200" ]]; then
  fail "Backend или модель не готовы (health HTTP ${backend_code:-000}). Сначала выполни setup-ubuntu.sh и проверь: systemctl status ${SERVICE_NAME} ollama"
fi

log "Устанавливаю Nginx и UFW"
as_root apt-get update
as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx ufw curl

ssh_port="${SSH_PORT:-}"
if [[ -z "${ssh_port}" && -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ ssh_port <<< "${SSH_CONNECTION}"
fi
ssh_port="${ssh_port:-22}"
if ! [[ "${ssh_port}" =~ ^[0-9]+$ ]]; then
  fail "Не удалось определить SSH-порт. Передай его явно: SSH_PORT=22 ./setup-nginx-ip.sh"
fi

log "Создаю Nginx reverse proxy на публичном порту ${HTTP_PORT}"
config_file="$(mktemp)"
trap 'rm -f "${config_file:-}"' EXIT
cat > "${config_file}" <<EOF
server {
    listen ${HTTP_PORT} default_server;
    listen [::]:${HTTP_PORT} default_server;

    server_name _;
    client_max_body_size 32k;

    location / {
        proxy_pass http://127.0.0.1:${SITE_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 10s;
        proxy_send_timeout 130s;
        proxy_read_timeout 130s;
    }
}
EOF

as_root install -m 0644 "${config_file}" "${NGINX_SITE}"
rm -f "${config_file}"
trap - EXIT

as_root rm -f /etc/nginx/sites-enabled/default
as_root ln -sfn "${NGINX_SITE}" "${NGINX_LINK}"
as_root nginx -t
as_root systemctl enable --now nginx
as_root systemctl reload nginx

log "Открываю SSH ${ssh_port}/tcp и HTTP ${HTTP_PORT}/tcp в UFW"
as_root ufw allow "${ssh_port}/tcp" comment 'SSH'
as_root ufw allow "${HTTP_PORT}/tcp" comment 'Monkey Wisdom HTTP'
as_root ufw --force enable

public_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${HTTP_PORT}/api/health" || true)"
if [[ "${public_code}" != "200" ]]; then
  as_root systemctl status nginx --no-pager || true
  fail "Nginx настроен, но локальная проверка вернула HTTP ${public_code:-000}."
fi

public_ip="$(curl --fail --silent --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "${public_ip}" ]]; then
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

log "Готово"
printf 'Сайт доступен по адресу: http://%s' "${public_ip:-ПУБЛИЧНЫЙ_IP}"
if [[ "${HTTP_PORT}" != "80" ]]; then
  printf ':%s' "${HTTP_PORT}"
fi
printf '\n\nПроверка сервисов:\n'
printf '  systemctl status nginx %s ollama\n' "${SERVICE_NAME}"
printf '  ufw status\n'
printf '\nЕсли сайт не открывается извне, разреши TCP-порт %s в сетевом firewall панели VPS-провайдера.\n' "${HTTP_PORT}"


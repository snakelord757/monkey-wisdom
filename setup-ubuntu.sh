#!/usr/bin/env bash
set -Eeuo pipefail

# One-command Ubuntu setup for Monkey Wisdom + local Qwen2.5 0.5B Q4_K_M.
# Run from the project directory as a regular user with sudo access:
#   chmod +x setup-ubuntu.sh
#   ./setup-ubuntu.sh
# For access from the LAN:
#   SITE_HOST=0.0.0.0 ./setup-ubuntu.sh

MODEL="${MODEL:-qwen2.5:0.5b-instruct-q4_K_M}"
SITE_HOST="${SITE_HOST:-127.0.0.1}"
SITE_PORT="${SITE_PORT:-8000}"
APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="$(id -un)"
VENV_DIR="${APP_DIR}/.venv"
SERVICE_NAME="monkey-wisdom"

log() { printf '\n\033[1;32m[Monkey Wisdom]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[Ошибка]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  log "Скрипт запущен через sudo; продолжаю от пользователя ${SUDO_USER}"
  exec sudo -u "${SUDO_USER}" -H env \
    MODEL="${MODEL}" SITE_HOST="${SITE_HOST}" SITE_PORT="${SITE_PORT}" \
    bash "${APP_DIR}/setup-ubuntu.sh"
fi

if [[ "${EUID}" -eq 0 ]]; then
  fail "Скрипт запущен из root-сессии. Создай обычного пользователя: adduser deploy && usermod -aG sudo deploy, затем перенеси проект в /home/deploy и запусти скрипт от deploy."
fi

if [[ ! -f "${APP_DIR}/requirements.txt" || ! -f "${APP_DIR}/app/main.py" ]]; then
  fail "Скрипт должен находиться в корне проекта рядом с requirements.txt."
fi

if ! command -v sudo >/dev/null 2>&1; then
  fail "Команда sudo не найдена. Установи sudo или выполни установку от администратора вручную."
fi

if ! command -v systemctl >/dev/null 2>&1 || [[ "$(systemctl is-system-running 2>/dev/null || true)" == "offline" ]]; then
  fail "Для автоматического запуска требуется Ubuntu с systemd (на WSL сначала включи systemd)."
fi

log "Устанавливаю системные зависимости"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl python3 python3-pip python3-venv

if ! command -v ollama >/dev/null 2>&1; then
  log "Устанавливаю Ollama из официального установочного скрипта"
  installer="$(mktemp)"
  trap 'rm -f "${installer:-}"' EXIT
  curl --fail --silent --show-error --location https://ollama.com/install.sh --output "${installer}"
  sh "${installer}"
  rm -f "${installer}"
  trap - EXIT
else
  log "Ollama уже установлен: $(ollama --version 2>/dev/null || echo unknown-version)"
fi

log "Запускаю локальный сервер Ollama"
sudo systemctl enable --now ollama

for _ in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:11434/api/version >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:11434/api/version >/dev/null \
  || fail "Ollama не запустился. Проверь: journalctl -u ollama -n 100 --no-pager"

log "Загружаю модель ${MODEL} (около 398 МБ)"
ollama pull "${MODEL}"

log "Создаю Python-окружение и устанавливаю зависимости сайта"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install -r "${APP_DIR}/requirements.txt"

log "Настраиваю подключение сайта к локальной модели"
cat > "${APP_DIR}/.env" <<EOF
LLM_BASE_URL=http://127.0.0.1:11434/v1
LLM_MODEL=${MODEL}
LLM_API_KEY=ollama
LLM_TIMEOUT_SECONDS=120
MAX_QUESTION_LENGTH=4000
EOF
chmod 600 "${APP_DIR}/.env"

log "Создаю systemd-сервис сайта"
service_file="$(mktemp)"
trap 'rm -f "${service_file:-}"' EXIT
cat > "${service_file}" <<EOF
[Unit]
Description=Monkey Wisdom website
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/python -m uvicorn app.main:app --host ${SITE_HOST} --port ${SITE_PORT}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 0644 "${service_file}" "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "${service_file}"
trap - EXIT

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

for _ in $(seq 1 30); do
  if curl --silent "http://127.0.0.1:${SITE_PORT}/api/health" >/dev/null; then
    break
  fi
  sleep 1
done

health="$(curl --silent --write-out '\n%{http_code}' "http://127.0.0.1:${SITE_PORT}/api/health" || true)"
health_body="$(printf '%s' "${health}" | head -n -1)"
health_code="$(printf '%s' "${health}" | tail -n 1)"
if [[ "${health_code}" != "200" ]]; then
  sudo systemctl status "${SERVICE_NAME}" --no-pager || true
  fail "Сайт запущен некорректно (health HTTP ${health_code}: ${health_body})."
fi

log "Готово"
printf 'Сайт:      http://%s:%s\n' "${SITE_HOST}" "${SITE_PORT}"
printf 'Модель:    %s\n' "${MODEL}"
printf 'Состояние: %s\n' "${health_body}"
printf '\nПолезные команды:\n'
printf '  sudo systemctl status %s\n' "${SERVICE_NAME}"
printf '  sudo journalctl -u %s -f\n' "${SERVICE_NAME}"
printf '  sudo systemctl restart %s\n' "${SERVICE_NAME}"
printf '  journalctl -u ollama -f\n'
if [[ "${SITE_HOST}" == "0.0.0.0" ]]; then
  printf '\nСайт открыт для LAN. При необходимости разреши TCP-порт %s только из доверенной сети в firewall.\n' "${SITE_PORT}"
fi

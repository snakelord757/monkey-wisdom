#!/usr/bin/env bash
set -Eeuo pipefail

# Safely switches Monkey Wisdom to a new Ollama model.
# The previous model is removed only after the site answers successfully.

NEW_MODEL="${NEW_MODEL:-qwen2.5:3b-instruct-q4_K_M}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="${SERVICE_NAME:-monkey-wisdom}"
SITE_PORT="${SITE_PORT:-8000}"

if [[ -n "${APP_DIR:-}" ]]; then
  TARGET_DIR="${APP_DIR}"
elif [[ -f /opt/monkey-wisdom/.env ]]; then
  TARGET_DIR="/opt/monkey-wisdom"
else
  TARGET_DIR="${SOURCE_DIR}"
fi
ENV_FILE="${TARGET_DIR}/.env"

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
if ! command -v ollama >/dev/null 2>&1; then
  fail "Ollama не установлен. Сначала выполни setup-ubuntu.sh."
fi
if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Не найден ${ENV_FILE}. Передай каталог приложения явно: APP_DIR=/путь/к/приложению ./switch-model.sh"
fi
if ! [[ "${NEW_MODEL}" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  fail "Некорректное имя модели: ${NEW_MODEL}"
fi

previous_model="$(sed -n 's/^LLM_MODEL=//p' "${ENV_FILE}" | tail -n 1)"
OLD_MODEL="${OLD_MODEL:-${previous_model:-qwen2.5:0.5b-instruct-q4_K_M}}"
if ! [[ "${OLD_MODEL}" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  fail "Некорректное имя старой модели: ${OLD_MODEL}"
fi

log "Текущая модель: ${previous_model:-не указана}"
log "Загружаю новую модель: ${NEW_MODEL}"
ollama pull "${NEW_MODEL}"

log "Проверяю новую модель напрямую через Ollama"
probe_file="$(mktemp)"
trap 'rm -f "${probe_file:-}"' EXIT
probe_code="$(curl --silent --show-error --max-time 180 \
  --output "${probe_file}" --write-out '%{http_code}' \
  http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${NEW_MODEL}\",\"prompt\":\"Ответь одним словом: готов\",\"stream\":false}" || true)"
if [[ "${probe_code}" != "200" ]]; then
  fail "Новая модель не прошла проверку Ollama (HTTP ${probe_code:-000}). Старая конфигурация не изменена."
fi

log "Обновляю ${ENV_FILE}"
if grep -q '^LLM_MODEL=' "${ENV_FILE}"; then
  as_root sed -i "s|^LLM_MODEL=.*|LLM_MODEL=${NEW_MODEL}|" "${ENV_FILE}"
else
  printf 'LLM_MODEL=%s\n' "${NEW_MODEL}" | as_root tee -a "${ENV_FILE}" >/dev/null
fi

rollback() {
  if [[ -n "${previous_model}" ]]; then
    as_root sed -i "s|^LLM_MODEL=.*|LLM_MODEL=${previous_model}|" "${ENV_FILE}"
    as_root systemctl restart "${SERVICE_NAME}" || true
  fi
}

log "Перезапускаю сайт"
if ! as_root systemctl restart "${SERVICE_NAME}"; then
  rollback
  fail "Не удалось перезапустить ${SERVICE_NAME}; конфигурация возвращена на ${previous_model}."
fi

site_code="000"
for _ in $(seq 1 30); do
  site_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "http://127.0.0.1:${SITE_PORT}/api/health" || true)"
  [[ "${site_code}" == "200" ]] && break
  sleep 1
done
if [[ "${site_code}" != "200" ]]; then
  rollback
  as_root systemctl status "${SERVICE_NAME}" --no-pager || true
  fail "Сайт не прошёл health-check; конфигурация возвращена на ${previous_model}."
fi

log "Удаляю предыдущую модель после успешного переключения"
if [[ "${OLD_MODEL}" != "${NEW_MODEL}" ]] && ollama list | awk 'NR > 1 {print $1}' | grep -Fxq "${OLD_MODEL}"; then
  ollama stop "${OLD_MODEL}" >/dev/null 2>&1 || true
  ollama rm "${OLD_MODEL}"
else
  printf 'Модель %s не установлена или совпадает с новой — удаление не требуется.\n' "${OLD_MODEL}"
fi

rm -f "${probe_file}"
trap - EXIT

log "Готово"
printf 'Активная модель: %s\n' "${NEW_MODEL}"
printf 'Конфигурация:    %s\n' "${ENV_FILE}"
printf 'Health-check:    http://127.0.0.1:%s/api/health — HTTP %s\n' "${SITE_PORT}" "${site_code}"
ollama list


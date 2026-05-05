#!/usr/bin/env bash
# cat get-sshd-settings.sh

set -euo pipefail

main() {
    export LANG="C"
    export LC_ALL="C"

    _HOST="No set"
    _IP=$(hostname -I | awk '{print $1}')
    _HN="$(hostname -s)"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        _ID=${ID:-unknown}
        _VER_ID=${VERSION_ID:-unknown}
        _EDITION=${EDITION:-""}
    fi
    _HOST="$_IP;$_HN;$_ID;$_VER_ID;$_EDITION"

    if [[ $EUID -eq 0 ]]; then
        _error "Запуск от 'root' или 'sudo' запрещен"
        exit 10
    fi

    # Проверка наличия sudo в системе
    if ! command -v sudo >/dev/null 2>&1; then
        _error "Утилита 'sudo' не найдена"
        exit 30
    fi

    # Проверка прав на выполнение sudo
    # -n (non-interactive) — не запрашивать пароль, если он нужен
    # -v (validate) — проверить права
    if ! sudo -n -v >/dev/null 2>&1; then
        _error "У пользователя нет прав на 'sudo' или требуется ввод пароля"
        exit 40
    fi

    if ! CONFIG=$(sudo -n sshd -T 2>/dev/null); then
        _error "Не удалось получить конфигурацию sshd"
        exit 50
    fi

    # Извлекаем конкретные параметры
    _ROOT_LOGIN=$(echo "$CONFIG" | grep -i '^permitrootlogin' | awk '{print $2}')
    _PASSWORD_AUTH=$(echo "$CONFIG" | grep -i '^passwordauthentication' | awk '{print $2}')
    _PUBKEY_AUTH=$(echo "$CONFIG" | grep -i '^pubkeyauthentication' | awk '{print $2}')
    _KEX_ALGORITHMS=$(echo "$CONFIG" | grep -i '^kexalgorithms' | awk '{print $2}')
    _CIPHERS=$(echo "$CONFIG" | grep -i '^ciphers' | awk '{print $2}')
    _MACS=$(echo "$CONFIG" | grep -i '^macs' | awk '{print $2}')

    # Вывод результатов
    _log "--- Параметры безопасности SSH ---"
    _log "Доступ для root:             ${_ROOT_LOGIN}"
    _log "Вход по паролю:              ${_PASSWORD_AUTH}"
    _log "Вход по ключу:               ${_PUBKEY_AUTH}"
    _log "--- Алгоритмы ---"
    _log "KEX (Key Exchange):          ${_KEX_ALGORITHMS}"
    _log "Шифры (Ciphers):             ${_CIPHERS}"
    _log "Проверка целостности (MACs): ${_MACS}"

    _csv "${_ROOT_LOGIN};${_PASSWORD_AUTH};${_PUBKEY_AUTH};${_KEX_ALGORITHMS};${_CIPHERS};${_MACS}"
}

# Переменные для функции 'getDateTime()'
_LAST_SEC=""
_MS_COUNTER=0
if date +%N | grep -qv 'N'; then
    _HAS_NATIVE_MS=true
else
    _HAS_NATIVE_MS=false
fi

getDateTime() {
    if [ "${_HAS_NATIVE_MS}" = true ]; then
        # Вызываем date ОДИН раз, получаем время и наносекунды сразу
        local _RAW_TIME
        _RAW_TIME=$(date +"%Y-%m-%d %H:%M:%S.%N")
        # Обрезаем до 5 знаков после точки (с 20-го символа берем 5)
        echo "${_RAW_TIME:0:25}"
    else
        # Вариант со счетчиком (тоже один вызов date)
        local _CURRENT_SEC
        _CURRENT_SEC=$(date +"%Y-%m-%d %H:%M:%S")

        if [ "${_CURRENT_SEC}" != "$_LAST_SEC" ]; then
            _MS_COUNTER=0
            _LAST_SEC="${_CURRENT_SEC}"
        else
            ((_MS_COUNTER++))
        fi
        printf "%s.%05d\n" "${_CURRENT_SEC}" "${_MS_COUNTER}"
    fi
}

_log() {
    local _OUT="${1}"
    printf "%s [INFO ]: %s\n" "$(getDateTime)" "${_OUT}"
}

_error() {
    local _OUT="${1}"
    printf "%s [ERROR]: %s\n" "$(getDateTime)" "${_OUT}"
    _csv "${_OUT}"
}

_csv()
{
    printf "[Result]: %s\n" "${_HOST};${1}"
}

main

#!/usr/bin/env bash

# Скрипт создает пользователя mpuser:
# 1. При возможности скачивает ключ с Git, иначе берет из переменной в скрипте
# 2. Проверяет, есть ли права в sudoers (деф конфиг или доп конфиги) исключая пресональный файл: /etc/sudoers.d/mpuser
# 3. Создает пользователя, если еще не создан
# 4. Блокирует пароль (установкой значения хеша как "*")
# 5. Обнуляется политика по времени действия пароля
# 6. Созадется файл sudo /etc/sudoers.d/mpuser, проверяется на корректность, если проверка прошла успешно - применяется
# 7. Создаются необходимые директорияя для файла ssh-ключа, назначаются права
# 8. Для AstraLinux при необходимости назначается IntegrityLevel = 63
#
# Запустить на сервере:
#    curl -sk https://git.local/leha/playbooks/-/raw/main/automation/user/install-mpuser.sh?ref_type=heads | sudo bash

_USER="mpuser"
_AUTHORIZED_KEY="ssh-rsa AAAA"
_ARCHIVE="sudo_wrappers_static.tar"
_TARGET_DIR="/home/$_USER"

set -euo pipefail

main() {
    export LANG="C"
    export LC_ALL=C
    #_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ $EUID -eq 0 ]]; then
       echo "Запускать от root запрещен!"
        exit 1
    fi

    # Проверить ключ в гите
    _AUTHORIZED_KEY_GIT="$(curl -kqm 3 https://git.local/leha/playbooks/-/raw/main/automation/user/AUTHORIZED_KEY?ref_type=heads 2>/dev/null)" && _AUTHORIZED_KEY="${_AUTHORIZED_KEY_GIT}"

    if [ -z "$_AUTHORIZED_KEY" ]; then
        _error "SSH ключ не получен (пустое значение)"
        exit 10
    fi
    if [ -n "$_AUTHORIZED_KEY" ] && ! echo "$_AUTHORIZED_KEY" | ssh-keygen -l -f - &>/dev/null; then
        _error "Невалидный SSH ключ: ${_AUTHORIZED_KEY}"
        #exit 15
    fi

    # Определить ID операционной системы
    if [ -f /etc/os-release ]; then
        OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        _error "Не удалось определить ОС"
        exit 20
    fi

    _log "Определена ОС: ${OS_ID}"
    # Стандартизация OS_ID для путей в архиве
    case "${OS_ID}" in
        "linuxmint")
            OS_ID="ubuntu"
            ;;
    esac
    _log "Выбрана директория источник в архиве: ${OS_ID}"

    # Проверить существование архива
    if [ ! -f "${_ARCHIVE}" ]; then
        curl -kqm 3 https://git.local/leha/playbooks/-/raw/main/automation/user/sudo_wrappers_static.tar -o ./sudo_wrappers_static.tar || {
            _error "Архив не найден: ${_ARCHIVE}"
            exit 30
        }
    fi

    [ "$(tar -tf "$_ARCHIVE" | grep -E "sudo_wrappers_static/${OS_ID}/bin/$|sudo_wrappers_static/${OS_ID}/mpuser$|sudo_wrappers_static/${OS_ID}/.bash_profile$" | wc -l)" -ne 3 ] && {
        _log "В архиве отсутствует один из файлов (mpuser, .bash_profile) или директория bin"
        exit 40
    }

    if ! command -v visudo &> /dev/null; then
       _error "Утилита 'visudo' не найдена. Для работы скрипта необходимо установить 'visudo'!"
       exit 50
    fi

    # Проверка дубликатов в sudoers (исключая личный файл юзера)
    if sudo grep -rE "^[[:space:]]*${_USER}[[:space:]]*" /etc/sudoers /etc/sudoers.d/ | \
                 grep -v "/etc/sudoers.d/${_USER}:" | grep -q .; then
        _error "Пользователь '${_USER}' найден в сторонних конфигах sudoers. Проверьте вручную!"
        exit 60
    fi

    #############################
    # Создание или обновление пользователя
    if id "$_USER" >/dev/null 2>&1; then
        _log "Пользователь '${_USER}' уже существует. Обновляем параметры..."
    else
        _log "Создаем нового пользователя '${_USER}'"
        sudo useradd -m "${_USER}"
    fi

    # Проверить хеш пароля на присутствие '*'
    if [[ "$(sudo getent shadow "$_USER" | cut -d: -f2)" == *"*"* ]]; then
        _log "Пользователь ${_USER} уже заблокирован (в хеше пароля есть '*')"
    else
        # Заблокировать пользователя по паролю (исключая возможность разблокировки командами: 'passwd -l ...' и 'chmod -U ...')
        sudo usermod -p '*' "$_USER"
        _log "Заблокирован пароль пользователя ${_USER} (в хеше пароля не было '*')"
    fi

    # Применить политику для УЗ, только если не соответствет требования ПТК ЕИВЦ
    if ! check_chage_param "Minimum number of days between password change" "0" || \
       ! check_chage_param "Maximum number of days between password change" "99999" || \
       ! check_chage_param "Password expires" "never" || \
       ! check_chage_param "Account expires" "never"; then
        sudo chage -I -1 -m 0 -M 99999 -E -1 "$_USER"
        _log "Политика chage обновлена"
    else
        _log "Политика chage корректна - изменений не требуется"
    fi
    # SSH ключи - обновляем только при несовпадении
    sudo mkdir -p "${_TARGET_DIR}/.ssh"
    # Получить отпечаток (fingerprints) ключа из скрипта
    _NEW_KEY_FP=$(echo "${_AUTHORIZED_KEY}" | ssh-keygen -l -f - | awk '{print $2}')
    _EXISTING_KEY_FP=""
    # Получить отпечаток (fingerprints) ключа из файла 'authorized_keys', если файл существует
    if sudo test -f "${_TARGET_DIR}/.ssh/authorized_keys"; then
        _EXISTING_KEY_FP=$(sudo ssh-keygen -l -f "${_TARGET_DIR}/.ssh/authorized_keys" 2>/dev/null | awk '{print $2}')
    fi

    # Обновить ключ, если отпечатки SSH-ключей разные
    if [ "${_NEW_KEY_FP}" != "${_EXISTING_KEY_FP}" ] || [ -z "${_EXISTING_KEY_FP}" ]; then
        _log "Обновляем SSH ключи для пользователя $_USER"
        echo "${_AUTHORIZED_KEY}" | sudo tee "${_TARGET_DIR}/.ssh/authorized_keys" > /dev/null
        fix_permissions_if_needed "${_TARGET_DIR}/.ssh" "${_USER}:${_USER}" "700"
        fix_permissions_if_needed "${_TARGET_DIR}/.ssh/authorized_keys" "${_USER}:${_USER}" "600"
    else
        _log "SSH ключ актуальный (fingerprint: ${_NEW_KEY_FP})"
    fi

    _log "Проверка контрольных сумм файлов..."
    # Вычисляем хеш файлов в архиве
    _ARCHIVE_CHECKSUM=$(tar -tf "$_ARCHIVE" | grep "sudo_wrappers_static/${OS_ID}/" | grep -v '/$' | sort | \
                            xargs -I{} tar -xf "$_ARCHIVE" -O {} 2>/dev/null | md5sum | cut -d' ' -f1)
    # Вычисляем хеш файлов в директории ${_USER}
    _TARGET_CHECKSUM=$(
        (
            # Файлы в bin (сортируем по имени)
            if sudo test -d "${_TARGET_DIR}/bin"; then
                sudo find "${_TARGET_DIR}/bin" -maxdepth 1 -type f -exec basename {} \; | sort | while read -r file; do
                    sudo cat "${_TARGET_DIR}/bin/${file}" 2>/dev/null
                done
            fi
            # Файлы mpuser и .bash_profile
            sudo test -f "${_TARGET_DIR}/mpuser" && sudo cat "${_TARGET_DIR}/mpuser" 2>/dev/null
            sudo test -f "${_TARGET_DIR}/.bash_profile" && sudo cat "${_TARGET_DIR}/.bash_profile" 2>/dev/null
        ) | md5sum | cut -d' ' -f1
    )

    _log "Хеши файлов в директории ${_USER} и в архиве"
    _log "${_TARGET_CHECKSUM} ? ${_ARCHIVE_CHECKSUM}"    
    # Сравниваем хеши
    if [ "$_TARGET_CHECKSUM" != "$_ARCHIVE_CHECKSUM" ]; then
        _log "Обнаружены изменения, обновляем файлы из архива..."
        sudo rm -rf "${_TARGET_DIR}/bin" "${_TARGET_DIR}/mpuser" "${_TARGET_DIR}/.bash_profile"
        sudo tar -xf "$_ARCHIVE" -C "$_TARGET_DIR" --strip-components=2 "sudo_wrappers_static/${OS_ID}/"
    else
        _log "Все файлы актуальны"
    fi

    # Установить права
    # Проверяем каждый файл/директорию
    fix_permissions_if_needed "${_TARGET_DIR}/bin" "${_USER}:${_USER}" "755"
    fix_permissions_if_needed "${_TARGET_DIR}/mpuser" "${_USER}:${_USER}" "644"
    fix_permissions_if_needed "${_TARGET_DIR}/.bash_profile" "${_USER}:${_USER}" "644"

    # Проверка и обновление sudoers файла через хеш
    # Проверяли файл из архива вначале скрипта, но проверим еще раз!
    SUDOERS_FILE="/etc/sudoers.d/${_USER}"
    if sudo visudo -cf "${_TARGET_DIR}/mpuser" &> /dev/null; then
        # Получаем хеши (если файл существует)
        NEW_HASH=$(sudo md5sum "${_TARGET_DIR}/mpuser" | cut -d' ' -f1)
        CURRENT_HASH=$(sudo test -e "${SUDOERS_FILE}" && sudo md5sum "${SUDOERS_FILE}" | cut -d' ' -f1 || echo "none")
        if [ "${NEW_HASH}" != "${CURRENT_HASH}" ]; then
            _log "Обновляем sudoers (хеш: ${CURRENT_HASH} -> ${NEW_HASH})"
            sudo cp "${_TARGET_DIR}/mpuser" "${SUDOERS_FILE}"
        else
            _log "Файл '${SUDOERS_FILE}' актуален"
        fi
        fix_permissions_if_needed "${SUDOERS_FILE}" "root:root" "440"
    else
        _log "Ошибка: Некорректный синтаксис sudoers!"
        exit 110
    fi

    # Astra Linux / PDP
    if command -v pdpl-user > /dev/null 2>&1; then
        sudo pdpl-user -i 63 "${_USER}"
        sudo su "${_USER}" -c pdp-id
    fi

    _log "Список inode для проверки изменялись ли файлы скриптом при повторном запуске:"
    _log "$(sudo ls -li "${_TARGET_DIR}/.ssh/authorized_keys" 2>/dev/null)"
    _log "$(sudo ls -li "${SUDOERS_FILE}" 2>/dev/null)"

    _log "Готово! Пользователь ${_USER} настроен."
}

# Проверяем и исправляем права на файлы
fix_permissions_if_needed() {
    local target="$1"
    local expected_owner="$2"
    local expected_perms="$3"

    if [ -e "${target}" ]; then
        local current_owner=$(sudo stat -c "%U:%G" "${target}" 2>/dev/null)
        local current_perms=$(sudo stat -c "%a" "${target}" 2>/dev/null)

        if [ "${current_owner}" != "${expected_owner}" ] || [ "${current_perms}" != "${expected_perms}" ]; then
            _log "Исправляем права на '${target}'"
            sudo chown "${expected_owner}" "${target}"
            sudo chmod "${expected_perms}" "${target}"
        fi
    fi
}

check_chage_param() {
    local param="$1"
    local expected="$2"
    sudo chage -l "$_USER" 2>/dev/null | grep -qE "^[[:space:]]*${param}[[:space:]]*:[[:space:]]*${expected}[[:space:]]*$"
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
    if [ "$_HAS_NATIVE_MS" = true ]; then
        # Вызываем date ОДИН раз, получаем время и наносекунды сразу
        local raw_time
        raw_time=$(date +"%Y-%m-%d %H:%M:%S.%N")
        # Обрезаем до 5 знаков после точки (с 20-го символа берем 5)
        echo "${raw_time:0:25}"
    else
        # Вариант со счетчиком (тоже один вызов date)
        local current_sec
        current_sec=$(date +"%Y-%m-%d %H:%M:%S")

        if [ "${current_sec}" != "$_LAST_SEC" ]; then
            _MS_COUNTER=0
            _LAST_SEC="${current_sec}"
        else
            ((_MS_COUNTER++))
        fi
        printf "%s.%05d\n" "${current_sec}" "${_MS_COUNTER}"
    fi
}

_log() {
    printf "%s [INFO ]: %s\n" "$(getDateTime)" "${1}"
}

_error() {
    printf "%s [ERROR]: %s\n" "$(getDateTime)" "${1}"
}

main

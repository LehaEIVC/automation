#!/usr/bin/env sh

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
#    curl -sk https://git.net-07.local/leha/playbooks/-/raw/main/scripts/install-mpuser.sh?ref_type=heads | bash
#
# Запуск через Ansible:
# - скачать плейбук: curl https://git.net-07.local/leha/playbooks/-/raw/main/ansible-run-script.yaml?ref_type=heads&inline=false -o ansible-run-script.yaml
#     в ansible-run-script.yaml можно поменять параметр cmd для переустановки пользователя (с предварительным его удалением)
# - при необходимости конфиг: curl https://git.net-07.local/leha/playbooks/-/raw/main/ansible.cfg?ref_type=heads&inline=false -o ansible.cfg
# - создать инвентарь, примеры: https://git.net-07.local/leha/playbooks/-/blob/main/inventory/hosts?ref_type=heads
# - запустить: ansible-playbook -i inventory/hosts.test ansible-run-script.yaml --extra-vars "script=install-mpuser.sh"
#
# Ansible отчет:
# echo "ip;host;OS;Ver OS;Edition;Count change;Info" > check.csv
# grep fatal ansible.log | grep -o "\[10.*" | sed "s|]: |;|g" | sed "s|^\[||g" >> check.csv
# cat ansible.log | grep -o "\[Result\].*" | sed 's|\\r\\n|\n|g' | grep -o "\[Result\].*" |  sed 's|\[Result\]: ||g' |  sort | uniq >> check.csv




_USER="mpuser"
_AUTHORIZED_KEY="ssh-rsa AAAA"
_ARCHIVE="sudo_wrappers_static.tar"
_URL_ARCHIVE="https://git.net-07.local/leha/playbooks/-/raw/main/scripts/files/sudo_wrappers_static_27.6.405.tar?ref_type=heads&inline=false"
_TARGET_DIR="/home/$_USER"
_TARGET_DIR_BIN="/mpx"




export LANG="C"
export LC_ALL="${LANG}"
_HOST="No set"
_COUNT_CHANGE=0

set -euo pipefail

main() {
    #_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    [ $EUID -eq 0 ] && { _error "Запуск от root запрещен!"; exit 1; }

    _IP="$(hostname -I | awk '{print $1}')"
    _HN="$(hostname -s)"
    [ -f /etc/os-release ] && {
        . /etc/os-release
        _ID="${ID:-unknown}"
        _VER_ID="${VERSION_ID:-unknown}"
        _EDITION="${EDITION:-""}"
    }
    _HOST="$_IP;$_HN;$_ID;$_VER_ID;$_EDITION"

    _REINSTALL=false

    [ $# -gt 1 ] && { _error "Неверное количество параметров. USE: ${0} [--reinstall]"; exit 1; }

    [ $# -eq 1 ] && {
        [ "$1" == "--reinstall" ] && _REINSTALL=true || { _error "Неверный параметр '$1'. USE: $0 [--reinstall]"; exit 3; }
    }

    if [ -z "$_TARGET_DIR" ] || [ "$_TARGET_DIR" == "/" ]; then
        _error "Критическая ошибка: путь _TARGET_DIR='${_TARGET_DIR}' небезопасен!"
        return 5
    fi

    # Проверить ключ в гите
    _AUTHORIZED_KEY_GIT="$(curl -ksqm 3 https://git.net-07.local/leha/playbooks/-/raw/main/files/mp_ssh_key.pub?ref_type=heads 2>/dev/null)" && _AUTHORIZED_KEY="${_AUTHORIZED_KEY_GIT}"

    if [ -z "$_AUTHORIZED_KEY" ]; then
        _error "SSH ключ не получен (пустое значение)"
        exit 10
    fi
    if [ -n "$_AUTHORIZED_KEY" ] && ! echo "$_AUTHORIZED_KEY" | ssh-keygen -l -f - &>/dev/null; then
        _error "Невалидный SSH ключ: ${_AUTHORIZED_KEY}"
        exit 15
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

    _log "Проверка локального архива ${_ARCHIVE}..."
    if [ ! -f "${_ARCHIVE}" ]; then
        _log "    Отсутствует локальный архив: ${_ARCHIVE}. Попытка загрузить с git"
        curl -skqm 3 "${_URL_ARCHIVE}" -o ./sudo_wrappers_static.tar && {
            _log "    Архив загружен с Git"
        } || {
            _error "   Архив не найден"
            exit 30
        }
    else
        _log "    Локальный архив обнаружен. Если нужно загрузить новую версию, то удалите локальный архив."
    fi

    _ARCH_PREFIX="sudo_wrappers_static/${OS_ID}"
    _log "Проверка целостности архива (не битый ли файл)"
    if ! tar -tf "$_ARCHIVE" >/dev/null 2>&1; then
        _error "Файл $_ARCHIVE поврежден или не является архивом"
        exit 40
    else
        _log "    Архив корректный"
    fi

    _log "Проверка в архиве наличия директории для ОС '${OS_ID}'"
    if ! tar -tf "$_ARCHIVE" "sudo_wrappers_static/${OS_ID}/" >/dev/null 2>&1; then
        _error "В архиве отсутствует директория для ОС: ${OS_ID}"
        exit 45
    else
        _log "    Директория определена"
    fi

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
    [ "${_REINSTALL}" = true ] && id "${_USER}" >/dev/null 2>&1 && {
        if sudo userdel -r "${_USER}"; then
            _log "Режим '--reinstall': пользователь '${_USER}' удален"
            ((++_COUNT_CHANGE))
        else
            _error "Режим '--reinstall': не удалось удалить пользователя '${_USER}'"
            exit 65
        fi
    }

    _ASTRA_LINUX_MAX_IL=""
    command -v pdpl-user > /dev/null 2>&1 && [ -f /sys/module/parsec/parameters/max_ilev ] && {
        _ASTRA_LINUX_MAX_IL="$(cat /sys/module/parsec/parameters/max_ilev)"
        _log "AstraLinux IntegrityLevel=${_ASTRA_LINUX_MAX_IL}"
    }

    # Создание или обновление пользователя
    if id "$_USER" >/dev/null 2>&1; then
        _log "Пользователь '${_USER}' уже существует"
    else
        sudo useradd -m "${_USER}"
        _log "Создан новвй пользователь '${_USER}'"
        ((++_COUNT_CHANGE))
    fi

    _log "Настройка параметров УЗ пользователя '${_USER}':"
    if [[ "$(sudo getent shadow "$_USER" | cut -d: -f2)" == *"*"* ]]; then
        _log "    Изменений не требуется: пользователь уже заблокирован (в хеше пароля есть '*')"
    else
        # Заблокировать пользователя по паролю (исключая возможность разблокировки командами: 'passwd -l ...' и 'chmod -U ...')
        sudo usermod -p '*' "$_USER"
        _log "    Заблокирован пароль пользователя (в хеше пароля не было '*')"
        ((++_COUNT_CHANGE))
    fi

    if ! check_chage_param "Minimum number of days between password change" "0" || \
       ! check_chage_param "Maximum number of days between password change" "99999" || \
       ! check_chage_param "Password expires" "never" || \
       ! check_chage_param "Account expires" "never"; then
        sudo chage -I -1 -m 0 -M 99999 -E -1 "${_USER}"
        _log "    Политика пароля обновлена"
        ((++_COUNT_CHANGE))
    else
        _log "    Изменений не требуется: политика пароля корректна"
    fi

    _log "Проверка SSH ключа пользователя '${_USER}'..."
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
        echo "${_AUTHORIZED_KEY}" | sudo tee "${_TARGET_DIR}/.ssh/authorized_keys" > /dev/null
        _log "    Обновлен SSH ключ для пользователя $_USER"
        ((++_COUNT_CHANGE))
    else
        _log "    Изменений не требуется: SSH ключ актуальный (fingerprint: ${_NEW_KEY_FP})"
    fi
    fix_permissions_if_needed "${_TARGET_DIR}/.ssh" "${_USER}:${_USER}" "700"
    fix_permissions_if_needed "${_TARGET_DIR}/.ssh/authorized_keys" "${_USER}:${_USER}" "600"


    _log "Проверка контрольных сумм файлов в домашней директории ${_USER} и в архиве..."
    _ARCH_FILES_LIST=$(tar -tf "${_ARCHIVE}" "${_ARCH_PREFIX}/" | grep -v '/$')
    # Если список пустой или путь не найден, выходим
    if [ -z "${_ARCH_FILES_LIST}" ]; then
        _error "    Файлы в архиве по пути $_ARCH_PREFIX не найдены"
        return 70
    fi
    # Список относительных путей для локальной проверки (тоже с \0), в том же порядке как и в архииве (но удаляем $_ARCH_PREFIX)
    _LOCAL_FILES_LIST=$(echo "${_ARCH_FILES_LIST}" | sed "s|^${_ARCH_PREFIX}/||")

    # Преобразуем \n в \0 прямо в пайпе, чтобы tar прочитал их корректно
    # --null и -T - заставляют tar читать список файлов из stdin с разделителем \0
    _ARCHIVE_CHECKSUM=$(printf '%s\n' "${_ARCH_FILES_LIST}" | tr '\n' '\0' | \
                        tar -xf "${_ARCHIVE}" --null -T - --no-recursion -O | md5sum | cut -d' ' -f1)
    # Считаем хеш локальных файлов
    # xargs -0 читает имена, разделенные NULL-символом
    _TARGET_CHECKSUM=$( (printf '%s\n' "$_LOCAL_FILES_LIST" | sed "s|^|${_TARGET_DIR}/|" | tr '\n' '\0' | \
                         xargs -0 sudo cat 2>/dev/null || true) | md5sum | cut -d' ' -f1)

    _log "    Хеши файлов в домашней директории '${_USER}' и в архиве:"
    _log "    ${_TARGET_CHECKSUM} ? ${_ARCHIVE_CHECKSUM}"
    # Сравниваем хеши
    if [ "$_TARGET_CHECKSUM" != "$_ARCHIVE_CHECKSUM" ]; then
        _log "    Хеши разные - обновляем файлы из архива..."
        # Удаляем локально файлы только из списка в архиве.
        # Есть риск "замусорить", если в архиве не будет директории, которая была в прошлой версии.
        # В начале скрипта проверка переменной _TARGET_DIR на недопустимые значения, например пусто или '/'
        printf '%s\n' "$_LOCAL_FILES_LIST" | sed "s|^|${_TARGET_DIR}/|" | tr '\n' '\0' | xargs -0 sudo rm -f
        sudo tar -xf "$_ARCHIVE" -C "$_TARGET_DIR" --strip-components=2 "${_ARCH_PREFIX}/"

        # бинари копируем в /mpx
        # (поговаривают... на Астре 1.8 какие-то проблемы с дом. директорией mpuser)
        sudo rm -rf "${_TARGET_DIR_BIN}"
        sudo mkdir -p "${_TARGET_DIR_BIN}/bin"
        sudo cp -r "${_TARGET_DIR}/bin" "${_TARGET_DIR_BIN}/"
        fix_permissions_if_needed "${_TARGET_DIR_BIN}/bin" "root:root" "505"
        ((++_COUNT_CHANGE))

        #command -v pdpl-file > /dev/null 2>&1 && [ -f /sys/module/parsec/parameters/max_ilev ] && \
        [ -n "${_ASTRA_LINUX_MAX_IL}" ] && {
            sudo pdpl-file -R :"$(cat /sys/module/parsec/parameters/max_ilev)" "${_TARGET_DIR}/bin/*"
            _log "AstraLinux установлен IL для файлов: ${_ASTRA_LINUX_MAX_IL}"
            ((++_COUNT_CHANGE))
        }
    else
        _log "    Изменений не требуется: файлы актуальны"
    fi

    # Установить права
    # Проверяем каждый файл/директорию
    #fix_permissions_if_needed "${_TARGET_DIR}/bin" "${_USER}:${_USER}" "505"
    fix_permissions_if_needed "${_TARGET_DIR}/mpuser" "${_USER}:${_USER}" "600"
    fix_permissions_if_needed "${_TARGET_DIR}/.bash_profile" "${_USER}:${_USER}" "600"

    # Проверка и обновление sudoers файла через хеш
    _log "Проверка хеша файла sudoers пользователя '${_USER}'..."
    SUDOERS_FILE="/etc/sudoers.d/${_USER}"
    if sudo visudo -cf "${_TARGET_DIR}/mpuser" &> /dev/null; then
        # Получаем хеши (если файл существует)
        NEW_HASH=$(sudo md5sum "${_TARGET_DIR}/mpuser" | cut -d' ' -f1)
        CURRENT_HASH=$(sudo test -e "${SUDOERS_FILE}" && sudo md5sum "${SUDOERS_FILE}" | cut -d' ' -f1 || echo "none")
        if [ "${NEW_HASH}" != "${CURRENT_HASH}" ]; then
            _log "    Обновляем sudoers (хеш: ${CURRENT_HASH} -> ${NEW_HASH})"
            sudo cp "${_TARGET_DIR}/mpuser" "${SUDOERS_FILE}"
            ((++_COUNT_CHANGE))
        else
            _log "    Изменений не требуется: файл '${SUDOERS_FILE}' актуален"
        fi
        fix_permissions_if_needed "${SUDOERS_FILE}" "root:root" "440"
    else
        _error "    Некорректный синтаксис sudoers!"
        exit 110
    fi

    # Astra Linux / PDP
    #command -v pdpl-user > /dev/null 2>&1 && [ -f /sys/module/parsec/parameters/max_ilev ] && {
    [ -n "${_ASTRA_LINUX_MAX_IL}" ] && {
        _log "AstraLinux настройка IL пользователю"
        [ "$(sudo pdpl-user mpuser | grep -E '^\s*[0-9]+:' | tail -n 1 | awk -F':' '{print $2}')" != \
                                                             "${_ASTRA_LINUX_MAX_IL}" ] && {
            sudo pdpl-user -i "${_ASTRA_LINUX_MAX_IL}" "${_USER}"
            sudo su "${_USER}" -c pdp-id
            _"    Пользователю '${_USER}' установлен IL: ${_ASTRA_LINUX_MAX_IL}"
            ((++_COUNT_CHANGE))
        } || _log "    Изменений не требуется"
    }

    _log "Список inode для проверки изменялись ли файлы скриптом при повторном запуске:"
    _log "    $(sudo ls -li "${_TARGET_DIR}/.ssh/authorized_keys" 2>/dev/null)"
    _log "    $(sudo ls -li "${SUDOERS_FILE}" 2>/dev/null)"

    _log "Пользователь '${_USER}' настроен, изменений: ${_COUNT_CHANGE}"
    _csv "OK"
}

# Проверяем и исправляем права на файлы
fix_permissions_if_needed() {
    local target="$1"
    local expected_owner="$2"
    local expected_perms="$3"

    _log "Проверка прав для '${target}': ${expected_perms}, ${expected_owner}"
    if sudo test -e "${target}"; then
        local current_owner=$(sudo stat -c "%U:%G" "${target}" 2>/dev/null)
        local current_perms=$(sudo stat -c "%a" "${target}" 2>/dev/null)

        if [ "${current_owner}" != "${expected_owner}" ] || [ "${current_perms}" != "${expected_perms}" ]; then
            sudo chown "${expected_owner}" "${target}"
            sudo chmod "${expected_perms}" "${target}"
            _log "    Права изменены (старые занчения: ${current_perms}, ${current_owner})"
            ((++_COUNT_CHANGE))
        else
            _log "    Изменений не требуется"
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
    _csv "${1}"
}

_csv()
{
    local _OUT="${1}"
    printf "[Result]: %s\n" "${_HOST};$(getDateTime);${_COUNT_CHANGE};${_OUT}"
}

main "$@"

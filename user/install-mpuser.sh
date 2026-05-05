#!/usr/bin/env sh

# Скрипт создает пользователя mpuser:
# 1.  При возможности скачивает ключ с Git, иначе берет из переменной в скрипте
# 2.  Проверяет, есть ли права в sudoers (деф конфиг или доп конфиги) исключая персональный файл: /etc/sudoers.d/mpuser
# 3.  Создает пользователя, если еще не создан
# 4.  Блокирует пароль (установкой значения хеша "*", без возможности разблокировать по паролю)
# 5.  Обнуляется политика по времени действия пароля
# 6.  Загружается архив или берется локально - sudo_wrappers_static.tar
# 7.  Создается файл sudo /etc/sudoers.d/mpuser, проверяется на корректность, если проверка прошла успешно - применяется
# 8.  Создаются необходимые директория для файла ssh-ключа, назначаются права
# 9.  Устанавливаются "обертки" системных утилит
# 10. Для AstraLinux при необходимости назначается IntegrityLevel = 63
# 11. При изменениях или ошибке отправляет в локальную почту root, если настроена пересылка - уйдет в почту админов
#          https://git.net-07.local/leha/playbooks/-/blob/main/automation/localMail/set-send-local-mail-to-admins.sh?ref_type=heads
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
# cat ansible.log | grep -o "\[Result\].*" | sed 's|\\r\\n|\n|g' | grep -o "\[Result\].*" | sed 's|\[Result\]: ||g; s|"]}$||g; s|"}$||g' |  sort | uniq >> check.csv




declare -r USER_TARGET="mpuser"
AUTHORIZED_KEY="ssh-rsa AAAA"
declare -r VERSION_ARCHIVE="27.6.405"
declare -r ARCHIVE="sudo_wrappers_static.tar"
declare -r URL_ARCHIVE="https://git.net-07.local/leha/playbooks/-/raw/main/scripts/files/mpuser/sudo_wrappers_static_${VERSION_ARCHIVE}.tar?ref_type=heads&inline=false"
declare -r URL_KEY_PUB="https://git.net-07.local/leha/playbooks/-/raw/main/scripts/files/mpuser/mpuser_authorized_keys?ref_type=heads"
declare -r TARGET_DIR="/home/${USER_TARGET}"
declare -r TARGET_DIR_BIN="/mpx"




export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LANG="C.UTF-8" 2>/dev/null || export LC_ALL="C"
export LC_ALL="${LANG}"
_HOST="No set"
count_change=0

declare -r SCRIPT_NAME="${0##*/}"
declare -r LOG_FILE="/var/log/automation/mpuser/${SCRIPT_NAME}.log"
declare -r LOG_FILE_TMP=$(mktemp ~/${SCRIPT_NAME}.XXXXXX.log)

set -euo pipefail


main() {
    if [[ $EUID -eq 0 ]]; then
        _error "Запуск от root запрещен!"
        return 1
    fi

    _IP="$(hostname -I | awk '{print $1}')"
    _HN="$(hostname -s)"
    [ -f /etc/os-release ] && {
        . /etc/os-release
        _ID="${ID:-unknown}"
        _VER_ID="${VERSION_ID:-unknown}"
        _EDITION="${EDITION:-""}"
    }
    _HOST="$_IP;$_HN;$_ID;$_VER_ID;$_EDITION"

    ASTRA_LINUX_MAX_IL=""
    command -v pdp-id > /dev/null 2>&1 && [ -f /sys/module/parsec/parameters/max_ilev ] && {
        ASTRA_LINUX_MAX_IL="$(cat /sys/module/parsec/parameters/max_ilev)"
        _current_il="$(pdp-id -i)"
        _log "AstraLinux max IntegrityLevel=${ASTRA_LINUX_MAX_IL}, пользователь '${USER}' имеет IL: ${_current_il}"

        [ "${_current_il}" != "${ASTRA_LINUX_MAX_IL}" ] && {
            _error "Пользователь '${USER}' не имеет максимального уровня целостности (IL). Установлен '${_current_il}', необходим '${ASTRA_LINUX_MAX_IL}'"
            return 3
        }
    }
    readonly ASTRA_LINUX_MAX_IL

    REINSTALL=false

    [ $# -gt 1 ] && { _error "Неверное количество параметров. USE: ${0} [--reinstall]"; return 1; }

    [ $# -eq 1 ] && {
        [ "$1" == "--reinstall" ] && REINSTALL=true || { _error "Неверный параметр '$1'. USE: $0 [--reinstall]"; return 3; }
    }
    readonly REINSTALL

    if [ -z "$TARGET_DIR" ] || [ "$TARGET_DIR" == "/" ]; then
        _error "Критическая ошибка: путь TARGET_DIR='${TARGET_DIR}' небезопасен!"
        return 5
    fi

    # Проверить ключ в гите
    AUTHORIZED_KEY_GIT="$(curl -fksqm 3 "${URL_KEY_PUB}" 2>/dev/null)" && AUTHORIZED_KEY="${AUTHORIZED_KEY_GIT}"
    readonly AUTHORIZED_KEY

    if [ -z "$AUTHORIZED_KEY" ]; then
        _error "SSH ключ не получен (пустое значение)"
        return 10
    fi
    if [ -n "$AUTHORIZED_KEY" ] && ! echo "$AUTHORIZED_KEY" | ssh-keygen -l -f - &>/dev/null; then
        _error "Невалидный SSH ключ: ${AUTHORIZED_KEY}"
        return 15
    fi

    if [ -z "${_ID}" ] || [ "${_ID}" = "unknown" ]; then
        _error "Не удалось определить ОС"
        return 20
    fi
    OS_ID="${_ID}"

    _log "Определена ОС: ${OS_ID}"
    # Стандартизация OS_ID для путей в архиве ()
    OS_ID_LOWER=$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')
    case "${OS_ID_LOWER}" in
        "linuxmint")
            OS_ID="ubuntu" ;;
        "centos"|"sintez")
            OS_ID="rhel" ;;
        *) ;;
    esac
    _log "Определена директория источник в архиве: ${OS_ID}"


    if [ ! -f "${ARCHIVE}" ] || [ "${REINSTALL}" = true ]; then
        [ ! -f "${ARCHIVE}" ] && _log "    Отсутствует локальный архив: ${ARCHIVE}"
        _log "    Загрузка архива с Git"
        declare -r _archive_tmp=$(mktemp "${ARCHIVE}.XXXXXX") || {
            _error "    Не удалось создать временный файл рядом с ${ARCHIVE}"
            return 23
        }
        _log "    Временный файл создан"
        # Удалить tmp при любом выходе (успех/ошибка/сигнал), если rename не успел переименовать
        trap 'rm -f "${_archive_tmp}"' EXIT INT TERM

        if ! curl -fsSkm 10 "${URL_ARCHIVE}" -o "${_archive_tmp}"; then
            _log "    Не удалось скачать архив с Git"
            [ ! -f "${ARCHIVE}" ] && {
                _error "    Отсутствует локальный архив: ${ARCHIVE}"
                return 30
            }
        else
            mv -f "${_archive_tmp}" "${ARCHIVE}"
            # Удалить trap, т.к. временного файла уже нет (переименован строкой выше)
            trap - EXIT INT TERM
            _log "    Архив загружен с Git"
        fi
    else
        _log "    Локальный архив найден: ${ARCHIVE}"
    fi

    _ARCH_PREFIX="sudo_wrappers_static/${OS_ID}"
    _log "Проверка целостности архива (не битый ли файл)"
    if ! tar -tf "$ARCHIVE" >/dev/null 2>&1; then
        _error "Файл $ARCHIVE поврежден или не является архивом"
        return 40
    else
        _log "    Архив корректный"
    fi

    _log "Проверка в архиве наличия директории для ОС '${OS_ID}'"
    if ! tar -tf "$ARCHIVE" "sudo_wrappers_static/${OS_ID}/" >/dev/null 2>&1; then
        _error "В архиве отсутствует директория для ОС: ${OS_ID}"
        return 45
    else
        _log "    Директория определена"
    fi

    if ! command -v visudo &> /dev/null; then
       _error "Утилита 'visudo' не найдена. Для работы скрипта необходимо установить 'visudo'!"
       return 50
    fi

    # Экранируем ${USER_TARGET} для использования в расширенном regex.
    # sed экранирует все метасимволы (в имени пользователя) ERE: . * + ? ( ) [ ] { } | ^ $ \
    _log "Поиск пользователя во всех файлах sudoers"
    _user_ere=$(printf '%s' "${USER_TARGET}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    readonly _user_ere
    _log "    Экранировать имя пользователя: ${_user_ere}"

    # Список путей sudoers файлов и директорий, начинаем с дефолтного
    _sudoers_paths="/etc/sudoers"

    # Парсим include-директивы из дефолтного конфига /etc/sudoers
    # Поддерживаем оба синтаксиса: #include[dir] (старый) и @include[dir] (новый).
    while read -r _ _target; do
        # Относительные пути резолвим относительно /etc/
        case "${_target}" in
            /*) ;;                           # путь начинается с /... - значит полный
            *) _target="/etc/${_target}" ;;  # путь НЕ начинается с /... - значит относительный
        esac
        _sudoers_paths="${_sudoers_paths} ${_target}"
    done < <(sudo grep -hE '^[[:space:]]*[#@]include(dir)?[[:space:]]+' /etc/sudoers 2>/dev/null || true)
    readonly _sudoers_paths

    _log "    Файлы и директории для проверки sudoers: ${_sudoers_paths}"
    # Ищем пользователя в sudoers, исключая ИМЕННО его персональный файл по полному пути.
    # -l выводит только имена файлов с совпадениями
    declare -r _foreign_sudoers=$(
        sudo grep -rlE "^[[:space:]]*${_user_ere}[[:space:]]+" ${_sudoers_paths} 2>/dev/null \
            | grep -Fxv "/etc/sudoers.d/${USER_TARGET}" \
            || true
    )
    # Показать "сторонние" файлы
    if [ -n "${_foreign_sudoers}" ]; then
        _log "[!] Пользователь '${USER_TARGET}' найден в сторонних конфигах sudoers:"
        _log "    ${_foreign_sudoers}"
        _error "    Пользователь '${USER_TARGET}' найден в сторонних конфигах sudoers. Проверить вручную!"
        return 60
    fi

    #############################
    [ "${REINSTALL}" = true ] && id "${USER_TARGET}" >/dev/null 2>&1 && {
        if sudo userdel -r "${USER_TARGET}"; then
            _log "[+] Режим '--reinstall': пользователь '${USER_TARGET}' удален"
            count_change=$((count_change + 1))
        else
            _error "Режим '--reinstall': не удалось удалить пользователя '${USER_TARGET}'"
            return 65
        fi
    }

    # Создание или обновление пользователя
    if id "${USER_TARGET}" >/dev/null 2>&1; then
        _log "Пользователь '${USER_TARGET}' уже существует"
    else
        sudo useradd -m "${USER_TARGET}"
        _log "[+] Создан новый пользователь '${USER_TARGET}'"
        count_change=$((count_change + 1))
    fi

    if ! getent group "${USER_TARGET}" >/dev/null 2>&1; then
        _log "Создана группа ${USER_TARGET}"
        sudo groupadd "${USER_TARGET}"
    else
        _log "Группа '${USER_TARGET}' уже существует"
    fi

    if ! id -Gn "${USER_TARGET}" | grep -qw "${USER_TARGET}"; then
        _log "Пользователь '${USER_TARGET}' добавлен в группу '${USER_TARGET}'"
        sudo usermod -g "${USER_TARGET}" "${USER_TARGET}"
    else
        _log "Пользователь '${USER_TARGET}' уже участник группы '${USER_TARGET}'"
    fi

    _log "Настройка параметров УЗ пользователя '${USER_TARGET}':"
    if [[ "$(sudo getent shadow "${USER_TARGET}" | cut -d: -f2)" == *"*"* ]]; then
        _log "    Изменений не требуется: пользователь уже заблокирован (в хеше пароля есть '*')"
    else
        # Заблокировать пользователя по паролю (исключая возможность разблокировки командами: 'passwd -l ...' и 'chmod -U ...')
        sudo usermod -p '*' "${USER_TARGET}"
        _log "[+]  Заблокирован пароль пользователя (в хеше пароля не было '*')"
        count_change=$((count_change + 1))
    fi

    if ! check_chage_param "Minimum number of days between password change" "0" || \
       ! check_chage_param "Maximum number of days between password change" "99999" || \
       ! check_chage_param "Password expires" "never" || \
       ! check_chage_param "Account expires" "never"; then
        sudo chage -I -1 -m 0 -M 99999 -E -1 "${USER_TARGET}"
        _log "[+] Политика пароля обновлена"
        count_change=$((count_change + 1))
    else
        _log "    Изменений не требуется: политика пароля корректна"
    fi

    _log "Проверка SSH ключа пользователя '${USER_TARGET}'..."
    # SSH ключи - обновляем только при несовпадении
    sudo mkdir -p "${TARGET_DIR}/.ssh"

    _NEW_KEY_STR=$(echo "${AUTHORIZED_KEY}" | xargs)
    # 2. Читаем существующий ключ (берем только первую строку, если их несколько)
    _EXISTING_KEY_STR=""
    if sudo test -f "${TARGET_DIR}/.ssh/authorized_keys"; then
        # Читаем файл, убираем лишние пробелы
        _EXISTING_KEY_STR=$(sudo cat "${TARGET_DIR}/.ssh/authorized_keys" | head -n 1 | xargs)
    fi

    # 3. Сравниваем строки напрямую
    if [ "${_NEW_KEY_STR}" != "${_EXISTING_KEY_STR}" ]; then
        echo "${AUTHORIZED_KEY}" | sudo tee "${TARGET_DIR}/.ssh/authorized_keys" > /dev/null
        _log "[+] Обновлен SSH ключ (включая опции) для пользователя $USER_TARGET"
        count_change=$((count_change + 1))
    else
        _log "    Изменений не требуется: SSH ключ и опции актуальны"
    fi
    fix_permissions_if_needed "${TARGET_DIR}/.ssh" "${USER_TARGET}:${USER_TARGET}" "700"
    fix_permissions_if_needed "${TARGET_DIR}/.ssh/authorized_keys" "${USER_TARGET}:${USER_TARGET}" "600"


    _log "Проверка контрольных сумм файлов в домашней директории ${USER_TARGET} и в архиве..."
    _ARCH_FILES_LIST=$(tar -tf "${ARCHIVE}" "${_ARCH_PREFIX}/" | grep -v '/$')
    # Если список пустой или путь не найден, выходим
    if [ -z "${_ARCH_FILES_LIST}" ]; then
        _error "    Файлы в архиве по пути $_ARCH_PREFIX не найдены"
        return 70
    fi
    # Список относительных путей для локальной проверки (тоже с \0), в том же порядке как и в архиве (но удаляем $_ARCH_PREFIX)
    _LOCAL_FILES_LIST=$(echo "${_ARCH_FILES_LIST}" | sed "s|^${_ARCH_PREFIX}/||")

    # Преобразуем \n в \0 прямо в пайпе, чтобы tar прочитал их корректно
    # --null и -T - заставляют tar читать список файлов из stdin с разделителем \0
    _ARCHIVE_CHECKSUM=$(printf '%s\n' "${_ARCH_FILES_LIST}" | tr '\n' '\0' | \
                        tar -xf "${ARCHIVE}" --null -T - --no-recursion -O | md5sum | cut -d' ' -f1)
    # Считаем хеш локальных файлов
    # xargs -0 читает имена, разделенные NULL-символом
    _TARGET_CHECKSUM=$( (printf '%s\n' "$_LOCAL_FILES_LIST" | sed "s|^|${TARGET_DIR}/|" | tr '\n' '\0' | \
                         xargs -0 sudo cat 2>/dev/null || true) | md5sum | cut -d' ' -f1)

    _log "    Хеши файлов в домашней директории '${USER_TARGET}' и в архиве:"
    _log "    ${_TARGET_CHECKSUM} ? ${_ARCHIVE_CHECKSUM}"
    # Сравниваем хеши
    if [ "$_TARGET_CHECKSUM" != "$_ARCHIVE_CHECKSUM" ]; then
        _log "[+] Хеши разные - обновляем файлы из архива..."
        # Удаляем локально файлы только из списка в архиве.
        # Есть риск "замусорить", если в архиве не будет директории, которая была в прошлой версии.
        # В начале скрипта проверка переменной TARGET_DIR на недопустимые значения, например пусто или '/'
        printf '%s\n' "$_LOCAL_FILES_LIST" | sed "s|^|${TARGET_DIR}/|" | tr '\n' '\0' | xargs -0 sudo rm -f
        sudo tar -xf "$ARCHIVE" -C "$TARGET_DIR" --strip-components=2 "${_ARCH_PREFIX}/"

        # бинари копируем в /mpx
        # (поговаривают... на Астре 1.8 какие-то проблемы с дом. директорией mpuser)
        sudo rm -rf "${TARGET_DIR_BIN}"
        sudo mkdir -p "${TARGET_DIR_BIN}/bin"
        sudo cp -r "${TARGET_DIR}/bin" "${TARGET_DIR_BIN}/"
        fix_permissions_if_needed "${TARGET_DIR_BIN}/bin" "root:root" "555"
        count_change=$((count_change + 1))

        #command -v pdpl-file > /dev/null 2>&1 && [ -f /sys/module/parsec/parameters/max_ilev ] && \
        [ -n "${ASTRA_LINUX_MAX_IL}" ] && {
            sudo pdpl-file -R :"${ASTRA_LINUX_MAX_IL}" "${TARGET_DIR}"/bin/*
            _log "[+] AstraLinux установлен IL для файлов: ${ASTRA_LINUX_MAX_IL}"
            count_change=$((count_change + 1))
        }
    else
        _log "    Изменений не требуется: файлы актуальны"
    fi

    # Установить права
    # Проверяем каждый файл/директорию
    fix_permissions_if_needed "${TARGET_DIR}/mpuser" "${USER_TARGET}:${USER_TARGET}" "600"
    fix_permissions_if_needed "${TARGET_DIR}/.bash_profile" "${USER_TARGET}:${USER_TARGET}" "600"

    # Проверка и обновление sudoers файла через хеш
    _log "Проверка хеша файла sudoers пользователя '${USER_TARGET}'..."
    SUDOERS_FILE="/etc/sudoers.d/${USER_TARGET}"
    if sudo visudo -cf "${TARGET_DIR}/mpuser" &> /dev/null; then
        # Получаем хеши (если файл существует)
        NEW_HASH=$(sudo md5sum "${TARGET_DIR}/mpuser" | cut -d' ' -f1)
        CURRENT_HASH=$(sudo test -e "${SUDOERS_FILE}" && sudo md5sum "${SUDOERS_FILE}" | cut -d' ' -f1 || echo "none")
        if [ "${NEW_HASH}" != "${CURRENT_HASH}" ]; then
            sudo install -m 0440 -o root -g root "${TARGET_DIR}/mpuser" "${SUDOERS_FILE}"
            # Контрольная валидация
            if ! sudo visudo -cf "${SUDOERS_FILE}" &>/dev/null; then
                _error "  Установленный '${SUDOERS_FILE}' не прошёл валидацию, удален"
                sudo rm -f "${SUDOERS_FILE}"
                exit 110
            fi
            _log "[+] Обновляен sudoers (хеш: ${CURRENT_HASH} -> ${NEW_HASH})"
            count_change=$((count_change + 1))
        else
            _log "    Изменений не требуется: файл '${SUDOERS_FILE}' актуален"
        fi
        fix_permissions_if_needed "${SUDOERS_FILE}" "root:root" "440"
    else
        _error "    Некорректный синтаксис sudoers!"
        return 110
    fi

    # Astra Linux / PDP
    [ -n "${ASTRA_LINUX_MAX_IL}" ] && {
        _log "AstraLinux настройка IL пользователю"
        [ "$(sudo pdpl-user mpuser | grep -E '^\s*[0-9]+:' | tail -n 1 | awk -F':' '{print $2}')" != \
                                                             "${ASTRA_LINUX_MAX_IL}" ] && {
            sudo pdpl-user -i "${ASTRA_LINUX_MAX_IL}" "${USER_TARGET}"
            sudo -u "${USER_TARGET}" pdp-id
            _log "[+] Пользователю '${USER_TARGET}' установлен IL: ${ASTRA_LINUX_MAX_IL}"
            count_change=$((count_change + 1))
        } || _log "    Изменений не требуется"
    }

    #_log "Список inode для проверки изменялись ли файлы скриптом при повторном запуске:"
    #_log "    $(sudo ls -li "${TARGET_DIR}/.ssh/authorized_keys" 2>/dev/null)"
    #_log "    $(sudo ls -li "${SUDOERS_FILE}" 2>/dev/null)"

    _log "Пользователь '${USER_TARGET}' настроен, изменений: ${count_change}"

    if [ "${count_change}" -gt 0 ]; then
        send_mail
    fi

    _csv "OK"
}

send_mail() {
    _msg_error="${1:-}"
    # Определяем имя скрипта для текста письма
    local -r _script_name=$(basename "$0")
    local -r _body_file=$(mktemp)
    if [ -n "${_msg_error}" ]; then
        _subject="Script: ${_script_name} [Error]. ${_HOST}"
        #_msg="${_HOST}\n\nScript ${_script_name} execution failed.\n\nError details: ${_msg_error}"
        echo -e "${_HOST}\n\nScript ${_script_name} execution failed.\n\nError details: ${_msg_error}\n" > "$_body_file"
    else
        _subject="Script: ${_script_name} [Chg.: ${count_change}]. ${_HOST}"
        #_msg="${_HOST}\n\nScript ${_script_name} executed successfully.\n\nChanges applied: ${count_change}"
        echo -e "${_HOST}\n\nScript ${_script_name} executed successfully.\n\nChanges applied: ${count_change:-0}\n" > "$_body_file"
    fi

    [ -f "${LOG_FILE_TMP}" ] && _msg+="\n$(cat "${LOG_FILE_TMP}")"
    if [ -f "${LOG_FILE_TMP}" ]; then
        echo -e "--- LOG ---\n" >> "$_body_file"
        cat "${LOG_FILE_TMP}" >> "$_body_file"
    fi

    # Проверка наличия команды mail
    if command -v mail >/dev/null 2>&1; then
        if mail -s "${_subject}" root < "$_body_file"; then
            _log "Отчет отправлен пользователю 'root'"
        else
            _log "Ошибка: не удалось отправить почту через 'mail'"
        fi
#       {
#            echo -e "${_msg}" | mail -s "${_subject}" root && _log "Отчет отправлен пользователю 'root' в локальную почту"
#        } || _log "Неуспешная доставка локальной почты пользователю 'root'!"
    else
        _log "Утилита 'mail' не найдена. Уведомление не отправлено."
    fi
}

# Проверяем и исправляем права на файлы
fix_permissions_if_needed() {
    local -r target="$1"
    local -r expected_owner="$2"
    local -r expected_perms="$3"

    _log "Проверка прав для '${target}': ${expected_perms}, ${expected_owner}"
    if sudo test -e "${target}"; then
        local -r current_owner=$(sudo stat -c "%U:%G" "${target}" 2>/dev/null)
        local -r current_perms=$(sudo stat -c "%a" "${target}" 2>/dev/null)

        if [ "${current_owner}" != "${expected_owner}" ] || [ "${current_perms}" != "${expected_perms}" ]; then
            sudo chown -R "${expected_owner}" "${target}"
            sudo chmod -R "${expected_perms}" "${target}"
            _log "[+] Права изменены (старые занчения: ${current_perms}, ${current_owner})"
            count_change=$((count_change + 1))
        else
            _log "    Изменений не требуется"
        fi
    fi
}

check_chage_param() {
    local -r param="$1"
    local -r expected="$2"
    sudo chage -l "$USER_TARGET" 2>/dev/null | grep -qE "^[[:space:]]*${param}[[:space:]]*:[[:space:]]*${expected}[[:space:]]*$"
}

# Переменные для функции 'getDateTime()'
last_sec=""
ms_counter=0
if [[ "$(date +%N)" =~ ^[0-9]+$ ]]; then
    declare -r HAS_NATIVE_MS=true
else
    declare -r HAS_NATIVE_MS=false
fi

getDateTime() {
    if [ "$HAS_NATIVE_MS" = true ]; then
        # Вызываем date ОДИН раз, получаем время и наносекунды сразу
        local raw_time
        raw_time=$(date +"%Y-%m-%d %H:%M:%S.%N")
        readonly raw_time
        # Обрезаем до 5 знаков после точки (с 20-го символа берем 5)
        #echo "${raw_time:0:25}"
        # Берём секунды + 5 знаков после точки
        printf '%s.%.5s\n' "${raw_time%.*}" "${raw_time##*.}"
    else
        # Вариант со счетчиком вместо ms
        local current_sec
        current_sec=$(date +"%Y-%m-%d %H:%M:%S")
        readonly current_sec

        if [ "${current_sec}" != "$last_sec" ]; then
            ms_counter=0
            last_sec="${current_sec}"
        else
            ms_counter=$((ms_counter + 1))
        fi
        printf "%s.%05d\n" "${current_sec}" "${ms_counter}"
    fi
}

_log() {
    local -r out="${1}"
    printf "%s [INFO ]: %s\n" "$(getDateTime)" "${out}" | tee -a "${LOG_FILE_TMP}"
}

_error() {
    local -r out="${1}"
    printf "%s [ERROR]: %s\n" "$(getDateTime)" "${out}" | tee -a "${LOG_FILE_TMP}"
    count_change=-1
    send_mail "${out}"
    _csv "${out}"
}

_csv()
{
    local -r out="${1}"
    printf "[Result]: %s\n" "${_HOST};$(getDateTime);${count_change};${out}" | tee -a "${LOG_FILE_TMP}"
}

_append_to_log_file() {
    if [ -f "${LOG_FILE_TMP}" ]; then
        sudo mkdir -p "$(dirname "${LOG_FILE}")"
        cat "${LOG_FILE_TMP}" | sudo tee -a "${LOG_FILE}" > /dev/null

        rm -f "${LOG_FILE_TMP}"
    fi
}

trap _append_to_log_file EXIT SIGTERM SIGINT

main "$@"
_return=$?
exit ${_return}

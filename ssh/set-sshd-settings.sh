#!/usr/bin/env bash
# cat set-sshd-settings.sh

# Скрипт устанавливает SSHD параметры в максимально безопасные значения («Hardening»)

# Количество бекапаов
readonly MAX_BACKUPS=2

set -euo pipefail

main() {
    export LANG="C"
    export LC_ALL="C"

    _HOST="No set"
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

    [[ $# -gt 1 ]] && { _error "Неверное количество параметров. USE: ${0} [--reinstall]"; exit 10; }

    [[ $# -eq 1 ]] && {
        [[ "$1" == "--reinstall" ]] && _REINSTALL=true || { _error "Неверный параметр '$1'. USE: $0 [--reinstall]"; exit 15; }
    }

    [[ $EUID -eq 0 ]] && { _error "Запуск от 'root' или 'sudo' запрещен"; exit 20; }

    # Проверка наличия sudo в системе
    command -v sudo >/dev/null 2>&1 || { _error "Утилита 'sudo' не найдена"; exit 30; }

    # Проверка прав на выполнение sudo
    # -n (non-interactive) — не запрашивать пароль, если он нужен
    # -v (validate) — проверить права
    sudo -n -v >/dev/null 2>&1 || { _error "У пользователя нет прав на 'sudo' или требуется ввод пароля"; exit 40; }

    command -v sshd >/dev/null 2>&1 || { _error "sshd не установлен"; exit 41; }
    command -v ssh-keygen >/dev/null 2>&1 || { _error "ssh-keygen не установлен"; exit 43; }

    _GROUP_INFO=$(getent group ssh-users) || { _error "Группа 'ssh-users' не найдена. Создайте группу и добавьте в неё пользователей: sudo groupadd ssh-users"; exit 45; }
    _USERS=$(echo "${_GROUP_INFO}" | cut -d: -f4 | tr ',' ' ')
    [[ -z "${_USERS}" ]] && { _error "Группа 'ssh-users' пуста. Добавьте в неё пользователей: sudo usermod -aG ssh-users <пользователь>"; exit 47; }

    _log "Проверка участников группы ssh-users"
    _USERS_OK=true
    for _USER in ${_USERS}; do
        # Проверяем существование пользователя в системе
        id "${_USER}" >/dev/null 2>&1 || { _error "    [${_USER}]: Пользователь не найден в системе. Создайте пользователя"; _USERS_OK=false; continue; }

        # Определяем путь к папке .ssh и файлу ключей
        _USER_HOME=$(getent passwd "${_USER}" | cut -d: -f6)
        _USER_AUTH_KEY="${_USER_HOME}/.ssh/authorized_keys"
        _USER_SSH_DIR="${_USER_HOME}/.ssh"

        [ -d "${_USER_HOME}" ] || { echo " [-] ${_USER}: Директория '${_USER_HOME}' не найдена. Пересоздайте пользователя."; _USERS_OK=false; continue; }

        _HOME_OWNER=$(stat -c "%U" "${_USER_HOME}")
        _HOME_PERMS=$(stat -c "%a" "${_USER_HOME}")
        [ "${_HOME_OWNER}" != "${_USER}" ] && { _error "[-] [${_USER}]: Владелец домашней директории '${_USER_HOME}' — ${_HOME_OWNER}. Исправьте: sudo chown ${_USER}:${_USER} ${_USER_HOME}"; _USERS_OK=false; }

        # Проверка прав на запись (группа и остальные не должны иметь прав на запись — это цифры 2, 3, 6, 7 в разряде)
        # Права не должны быть выше 755 (или 750)
        _HOME_WRITE_BIT=$(stat -c "%A" "${_USER_HOME}" | cut -c 6,9 | grep "w")
        [ -n "$_HOME_WRITE_BIT" ] && { _error "[-] [${_USER}]: Домашняя дректория '${_USER_HOME}' открыта на запись для посторонних (${_HOME_PERMS}). Исправьте: sudo chmod 755 ${_USER_HOME}"; _USERS_OK=false; }


        [ -d "${_USER_SSH_DIR}" ] || { echo " [-] ${_USER}: Директория '${_USER_SSH_DIR}' не найдена. Пересоздайте пользователя."; _USERS_OK=false; continue; }

        _SSH_DIR_OWNER=$(stat -c "%U" "${_USER_SSH_DIR}")
        [ "${_SSH_DIR_OWNER}" != "${_USER}" ] && { _error "[-] [${_USER}]: Неверный владелец '${_USER_SSH_DIR}' — ${_SSH_DIR_OWNER}. Исправьте:  sudo chown ${_USER}:${_USER} ${_USER_SSH_DIR}"; _USERS_OK=false; }

        _SSH_DIR_PERMS=$(stat -c "%a" "${_USER_SSH_DIR}")
        [ "${_SSH_DIR_PERMS}" != "700" ] && { _error "[-] [${_USER}]: Неверные права у директории '${_USER_SSH_DIR}' (сейчас ${_SSH_DIR_PERMS}, необходимо 700): sudo chmod 700 ${_USER_SSH_DIR}"; _USERS_OK=false; }


        # Проверяем наличие файла ключей
        [ -f "${_USER_AUTH_KEY}" ] || { echo "[-] [${_USER}]: Файл authorized_keys отсутствует. Добавьте публичный ключ пользователя"; _USERS_OK=false; continue; }

        _USER_AUTH_KEY_OWNER=$(stat -c "%U" "${_USER_AUTH_KEY}")
        [ "${_USER_AUTH_KEY_OWNER}" != "${_USER}" ] && { _error "[-] [${_USER}]: Неверный владелец '${_USER_AUTH_KEY}' — ${_USER_AUTH_KEY_OWNER}. Исправьте: sudo chown ${_USER}:${_USER} ${_USER_AUTH_KEY}"; _USERS_OK=false; }

        _USER_AUTH_KEY_PERMS=$(stat -c "%a" "${_USER_AUTH_KEY}")
        [ "${_USER_AUTH_KEY_PERMS}" != "600" ] && { _error "[-] [${_USER}]: Неверные права у файла '${_USER_AUTH_KEY}' (сейчас ${_USER_AUTH_KEY_PERMS}, необходимо 600): sudo chmod 600 ${_USER_AUTH_KEY}"; _USERS_OK=false; }


        # Проверка валидности ключей через ssh-keygen
        # -l (list fingerprint) проверяет синтаксис ключа, -f указывает файл
        ssh-keygen -l -f "${_USER_AUTH_KEY}" >/dev/null 2>&1 && echo "[+] [${_USER}]: Ключ валидный" || {
            _error "[-] [${_USER}]: Файл ключей поврежден или имеет неверный формат. Обновите публичный ключ пользователя"
            _USERS_OK=false
        }
    done

    [ "${_USERS_OK}" = false ] && { _error "При проверке пользователей из группы  'ssh-users' были ошибки. См лог"; exit 49; }


#####################################
    readonly _SSH_DEST="/etc/ssh/sshd_config.d/00-ptk.conf"
    readonly _SYSTEMD_DEST="/etc/systemd/system/sshd.service.d/override.conf"
    readonly _TMP_CONF="./00-ptk.conf.tmp"
    #_TMP_CONF=$(mktemp) || { _error "Не удалось создать временный файл"; exit 17; }
    readonly _MAIN_SSH_CONF="/etc/ssh/sshd_config"
    
    _ERROR_LOG=$(mktemp)
    trap 'rm -f "${_TMP_CONF}" "${_ERROR_LOG}"' EXIT

    tee "${_TMP_CONF}" > /dev/null << 'EOF'
# Порт для подключения клиентов
Port 22
# На каих интерфейсах принимать подключения. 0.0.0.0 - на всех и только ipv4
ListenAddress 0.0.0.0
# Только IPv4
AddressFamily inet

# Уровень логирования
#LogLevel INFO
LogLevel VERBOSE

# Запрет логона пользователм root
PermitRootLogin no
# Разрешить авторизацию по ssh-ключам
PubkeyAuthentication yes
# Метод аутентификации только по ssh-ключам
AuthenticationMethods publickey
# Запрет авторизации по паролю
PasswordAuthentication no
# Запрет пустого пароля
PermitEmptyPasswords no

# Максимальное количество попыток аутентификации для одной сессии.
# После 3 неудач сервер разорвет соединение.
MaxAuthTries 3
# Время (в секундах), в течение которого пользователь должен успеть
# залогиниться. Защищает от зависших сессий.
LoginGraceTime 30

# Запрет проброса графического интерфейса (снижает риск атак на X-сервер клиента)
X11Forwarding no
# Разрешить TCP-туннелирование (необходимо для работы SSH-туннелей)
AllowTcpForwarding yes

# Алгоритмы, с помощью которых клиент и сервер договариваются об общем секретном ключе для шифрования трафика
# sntrup761x25519-sha512@openssh.com: Это «звезда» современного SSH. Гибридный алгоритм, устойчивый к атакам квантовых компьютеров. Он комбинирует классическую кривую Curve25519 и постквантовый алгоритм Streamlined NTRU Prime.
# curve25519-sha256: Золотой стандарт на сегодняшний день. Быстрый, безопасный, без «закладок» спецслужб.
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org

# Шифры
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# Алгоритмы проверки целостности
#MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
MACs hmac-sha2-512-etm@openssh.com

# Используем только алгоритны ssh-ed25519
# Определяет, какие типы ключей сервера может использовать клиент для проверки подлинности сервера (предотвращение Man-in-the-middle)
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com
# Определяет, какие типы пользовательских ключей сервер примет для входа (ssh-ed25519 и аппаратные ключи)
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,sk-ssh-ed25519-cert-v01@openssh.com

# Даже если PasswordAuthentication выключен, интерактивная аутентификация может позволить ввод пароля через PAM.
# Для работы строго по ключам должно быть no
KbdInteractiveAuthentication no
UsePAM yes

# Проброс агента опасен. Если злоумышленник получит root на удаленном сервере, он сможет использовать ваш локальный сокет SSH-агента для входа на другие ваши сервера
AllowAgentForwarding no
AllowStreamLocalForwarding no

# Установка интервала заставит сервер разрывать «зависшие» или заброшенные сессии, если клиент не отвечает (в сек), устанавливаем в 15 мин.
ClientAliveInterval 900
ClientAliveCountMax 0

# Участники только этомй группы могут подключаться по SSH
AllowGroups ssh-users
EOF

    sudo test -f "${_SSH_DEST}" && sudo test -f "${_SYSTEMD_DEST}" && [ "${_REINSTALL}" = false ] && {
        _log "Изменений не произодилось. Файлы конфигураций существуют. Для переустановки используйте параметр '--reinstall'"
        exit 0
    }

    _log "Проверка конфигурации..."
    if ! sudo sshd -t -f "${_TMP_CONF}" -f "${_MAIN_SSH_CONF}" 2>"${_ERROR_LOG}"; then
        echo "--- ОШИБКА КОНФИГУРАЦИИ ---"
        cat "${_ERROR_LOG}"
        _error "Конфигурация не валидна"
        exit 50
    fi

    _log "Применение настроек SSH..."
    sudo mkdir -p /etc/ssh/sshd_config.d/
    backupFileAndRotate "${_SSH_DEST}"
    sudo mv "${_TMP_CONF}" "${_SSH_DEST}"
    sudo chown root:root "${_SSH_DEST}"
    sudo chmod 644 "${_SSH_DEST}"

    _log "Настройка sshd.service override..."
    sudo mkdir -p /etc/systemd/system/sshd.service.d/
    backupFileAndRotate /etc/systemd/system/sshd.service.d/override.conf
    sudo tee "/etc/systemd/system/sshd.service.d/override.conf" > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_config.d/00-ptk.conf -f /etc/ssh/sshd_config $SSHD_OPTS
EOF

    sudo systemctl daemon-reload
    if sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null; then
        _log "SSH успешно перезапущен с новыми параметрами."
    else
        _error "Не удалось перезапустить SSH. Проверьте journalctl -xe."
    fi
}

backupFileAndRotate() {
    local _SRC=${1}
    local _SRC_DIR
    local _BACKUP_DIR

    [ -f "${_SRC}" ] || { _log "Файл ${_SRC} не существует, пропус бекапa"; return 0; }

    # Определяем директорию исходного файла
    _SRC_DIR=$(dirname "${_SRC}")
    _BACKUP_DIR="${_SRC_DIR}/bak"

    # Создаем директорию для бекапов если её нет
    sudo mkdir -p "${_BACKUP_DIR}"

    # Получаем имя файла без пути
    local _FILENAME
    _FILENAME=$(basename "${_SRC}")

    # Создаем бекап с меткой времени в директории bak
    local _BACKUP_PATH="${_BACKUP_DIR}/${_FILENAME}.$(date +%Y-%m-%d_%H-%M-%S)"
    sudo cp "${_SRC}" "${_BACKUP_PATH}"
    _log "Создан бекап: ${_BACKUP_PATH}"

    local _BACKUP_COUNT
    _BACKUP_COUNT=$(sudo find "${_BACKUP_DIR}" -maxdepth 1 -name "${_FILENAME}.*" -type f 2>/dev/null | wc -l)
    _log "Найдено бекапов: ${_BACKUP_COUNT}, хранить максимум: ${MAX_BACKUPS}"

    if [ "${_BACKUP_COUNT}" -gt "${MAX_BACKUPS}" ]; then
        _log "Ротация бекапов: ${_BACKUP_DIR}"
        #sudo bash -c "ls -1tr '${_BACKUP_DIR}/${_FILENAME}'.* 2>/dev/null | head -n -${MAX_BACKUPS} | xargs -d '\n' rm -f"
        sudo find "${_BACKUP_DIR}" -maxdepth 1 -name "${_FILENAME}.*" -type f -printf '%T@ %p\n' | \
                   sort -n | head -n -${MAX_BACKUPS} | cut -d' ' -f2- | while read -r file; do
            sudo rm -f "$file"
            _log "Удален бекап: $file"
        done
    fi
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
    local _OUT="${1}"
    printf "[Result]: %s\n" "${_HOST};${_OUT}"
}

main "$@"

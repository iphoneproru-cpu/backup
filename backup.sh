#!/usr/bin/env bash
# Полная резервная копия сервера: панель Remnawave, бот Remnashop, nginx, сайт, сертификаты, cron.
# Что где лежит, скрипт находит сам по запущенным контейнерам и перед копией объясняет по пунктам.
#
#   bash /opt/server-backup/backup.sh     меню: копия сейчас, просмотр, настройка, расписание,
#                                         сервер копий, Telegram
#
# Без терминала (cron) тот же запуск сразу делает копию. Ключи ниже — служебные, для cron и
# агента RemnaDiag; человеку они не нужны, всё есть в меню:
#   --setup --plan --no-upload --only П --skip П --add ПУТЬ --apply-cron --remove-cron
#   --check-remote --remote-cmds --test-notify
#
# Настройки: backup.conf рядом со скриптом. Лог: /var/log/server-backup.log.
# Восстановление на чистом сервере: restore.sh (лежит рядом и внутри каждого архива).
set -euo pipefail

SELF="$(realpath "$0")"
DIR="$(dirname "$SELF")"
CONF="${BACKUP_CONF:-$DIR/backup.conf}"

# ---------------------------------------------------------------- настройки по умолчанию
OUT_DIR="/root/backups"
CRON_TIME="00:30"        # время запуска по часам сервера (в --setup спрашивается по Москве)
KEEP_LOCAL=7             # сколько копий хранить на этом сервере
REMOTE_HOST=""           # IP или домен сервера для копий; пусто — не отправлять
REMOTE_USER="backup"     # пользователь там (ему разрешена только загрузка файлов)
REMOTE_DIR=""            # папка там (относительно домашней); по умолчанию — имя этого сервера
SSH_PORT=22
KEEP_REMOTE=30           # сколько копий этого сервера хранить там
SSH_KEY="/root/.ssh/server_backup_ed25519"
TG_MODE="bot"            # bot — бот магазина владельцу; custom — TG_TOKEN/TG_CHAT; off
TG_TOKEN=""
TG_CHAT=""
TG_NOTIFY="all"          # all — успех и ошибки; errors — только ошибки
SKIP_PROJECTS=""
ONLY_PROJECTS=""         # если задано — только эти проекты compose и EXTRA_PATHS (без остального сервера)
EXTRA_PATHS=""
STATUS_FILE=""           # если задано — итог каждой копии (key=value) для внешних программ
LOG="/var/log/server-backup.log"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"
REMOTE_DIR="${REMOTE_DIR:-$(hostname)}"
DEST=""; [[ -z "$REMOTE_HOST" ]] || DEST="$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"

MODE="backup"; UPLOAD=1; ARGC=$#
while (( $# )); do
    case "$1" in
        --setup) MODE="setup" ;;
        --plan|--check) MODE="plan" ;;
        --test-notify) MODE="test-notify" ;;
        --no-upload) UPLOAD=0 ;;
        --skip) SKIP_PROJECTS+=" $2"; shift ;;
        --only) ONLY_PROJECTS+=" $2"; shift ;;
        --apply-cron) MODE="apply-cron" ;;
        --remove-cron) MODE="remove-cron" ;;
        --check-remote) MODE="check-remote" ;;
        --remote-cmds) MODE="remote-cmds" ;;
        --add) EXTRA_PATHS+=" $2"; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; exit 0 ;;
        *) echo "Неизвестный параметр: $1 (запустите без параметров — откроется меню)" >&2; exit 1 ;;
    esac
    shift
done
# без повторов: проект из backup.conf, выбранный ещё раз разово
ONLY_PROJECTS="$(printf '%s\n' $ONLY_PROJECTS | awk 'NF && !seen[$0]++' | xargs || true)"
SKIP_PROJECTS="$(printf '%s\n' $SKIP_PROJECTS | awk 'NF && !seen[$0]++' | xargs || true)"

# Цвета — только в терминале (cron и агент RemnaDiag получают чистый текст).
if [[ -t 1 ]]; then
    C_R=$'\e[0m' C_B=$'\e[1m' C_D=$'\e[2m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m' C_MAG=$'\e[35m' C_CYN=$'\e[36m'
else
    C_R="" C_B="" C_D="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_MAG="" C_CYN=""
fi
nocolor() { sed -u $'s/\e\\[[0-9;]*m//g'; }
step() { echo; echo "${C_B}${C_CYN}==>${C_R}${C_B} $*${C_R}"; }
warn() { echo "  ${C_YEL}! $*${C_R}"; WARNINGS+=("$*"); }
die() { echo; echo "${C_B}${C_RED}ОШИБКА:${C_R}${C_RED} $*${C_R}" >&2; exit 1; }
WARNINGS=()
[[ $EUID -eq 0 ]] || die "запустите от root"
HOST="$(hostname)"

# ================================================================ Telegram
tg_creds() {  # → TOKEN CHAT
    TOKEN=""; CHAT=""
    case "$TG_MODE" in
        custom) TOKEN="$TG_TOKEN"; CHAT="$TG_CHAT" ;;
        bot)
            local env=/opt/remnashop/.env
            TOKEN="$(grep -E '^BOT_TOKEN=' "$env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"' " || true)"
            CHAT="$(grep -E '^BOT_OWNER_ID=' "$env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"' " || true)" ;;
    esac
    [[ -n "$TOKEN" && -n "$CHAT" ]]
}
tg_send() {  # tg_send ТЕКСТ → 0, если Telegram принял
    tg_creds || return 1
    local code
    code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' "https://api.telegram.org/bot$TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$1" \
        -d disable_web_page_preview=true || true)"
    [[ "$code" == 200 ]]
}

# ================================================================ sftp
sftp_opts() { echo -P "$SSH_PORT" -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20; }
dest_host() { echo "$REMOTE_USER@$REMOTE_HOST"; }
dest_dir() { echo "$REMOTE_DIR"; }
sftp_ok() { echo "pwd" | sftp $(sftp_opts) -o StrictHostKeyChecking=accept-new -b - "$(dest_host)" >/dev/null 2>&1; }
# remote_path: полный путь папки копий там (домашняя папка пользователя + REMOTE_DIR), если доступ есть.
remote_path() {
    local home
    home="$(echo "pwd" | sftp $(sftp_opts) -o StrictHostKeyChecking=accept-new -b - "$(dest_host)" 2>/dev/null \
        | sed -n 's/^Remote working directory: //p')"
    [[ -n "$home" ]] && echo "${home%/}/$REMOTE_DIR"
}

# ================================================================ общее для --setup и режимов без вопросов
# remote_cmds: команды для сервера копий (выполнить там под root): пользователь без shell, папка, ключ только для sftp.
remote_cmds() {
    local pub auth; pub="$(cat "$SSH_KEY.pub")"; auth="restrict,command=\"internal-sftp\" $pub"
    echo "set -e
id $REMOTE_USER >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin $REMOTE_USER
H=\$(getent passwd $REMOTE_USER | cut -d: -f6)
mkdir -p \"\$H/.ssh\" \"\$H/$REMOTE_DIR\"
touch \"\$H/.ssh/authorized_keys\"
grep -qF '$(echo "$pub" | awk '{print $2}')' \"\$H/.ssh/authorized_keys\" || echo '$auth' >> \"\$H/.ssh/authorized_keys\"
chmod 700 \"\$H/.ssh\"; chmod 600 \"\$H/.ssh/authorized_keys\"
chown -R $REMOTE_USER: \"\$H/.ssh\" \"\$H/$REMOTE_DIR\"
echo \"готово: \$H/$REMOTE_DIR\""
}
# ensure_key: ключ для отправки копий (без пароля — для cron).
ensure_key() {
    [[ -f "$SSH_KEY" ]] || { mkdir -p "$(dirname "$SSH_KEY")"; ssh-keygen -t ed25519 -N "" -C "server-backup-$HOST" -f "$SSH_KEY" -q; }
    [[ -f "$SSH_KEY.pub" ]] || ssh-keygen -y -f "$SSH_KEY" > "$SSH_KEY.pub"
}
# apply_cron: строка cron из CRON_TIME (часы сервера); печатает её.
apply_cron() {
    local line
    line="${CRON_TIME#*:} ${CRON_TIME%:*} * * * bash $SELF >/dev/null 2>&1  # server-backup"
    line="$(echo "$line" | sed -E 's/^0([0-9]) /\1 /; s/ 0([0-9]) / \1 /')"
    { crontab -l 2>/dev/null | grep -vF "$SELF" || true; echo "$line"; } | crontab -
    echo "$line"
}

case "$MODE" in
    apply-cron)
        [[ "$CRON_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "CRON_TIME: ЧЧ:ММ"
        echo "${C_GRN}cron: $(apply_cron)${C_R}"; exit 0 ;;
    remove-cron)
        { crontab -l 2>/dev/null | grep -vF "$SELF" || true; } | crontab -
        echo "${C_GRN}расписание снято${C_R}"; exit 0 ;;
    check-remote)
        [[ -n "$REMOTE_HOST" ]] || die "сервер копий не задан (REMOTE_HOST)"
        [[ -f "$SSH_KEY" ]] || die "нет ключа $SSH_KEY"
        if path="$(remote_path)"; then echo "${C_GRN}доступ к $(dest_host) (порт $SSH_PORT) есть, копии будут в $path${C_R}"; exit 0; fi
        die "нет доступа к $(dest_host) (порт $SSH_PORT) по ключу $SSH_KEY" ;;
    remote-cmds)
        [[ -n "$REMOTE_HOST" ]] || die "сервер копий не задан (REMOTE_HOST)"
        ensure_key; remote_cmds; exit 0 ;;
esac

# ================================================================ меню
# Запуск без параметров в терминале — меню. Каждый пункт запускает этот же скрипт в нужном режиме
# (SB_NO_MENU=1 — чтобы «сделать копию» не открыло меню снова).
menu_status() {
    local cron last n
    lbl() { local t="$1"; printf "  %s%*s " "$t" $((16 - ${#t})) ""; }  # подпись по числу букв, не байт
    cron="$(crontab -l 2>/dev/null | grep -F "$SELF" | grep -v '^\s*#' | head -1 || true)"
    echo "${C_B}${C_BLU}╭──────────────────────────────────────────────────────────╮${C_R}"
    printf "${C_B}${C_BLU}│${C_R}  ${C_B}Резервные копии${C_R} · ${C_CYN}%-38s${C_R}${C_B}${C_BLU}│${C_R}\n" "$HOST"
    echo "${C_B}${C_BLU}╰──────────────────────────────────────────────────────────╯${C_R}"
    if [[ -n "$cron" ]]; then
        lbl "Расписание:"; printf "${C_GRN}каждый день в %02d:%02d${C_R} ${C_D}(по часам сервера)${C_R}\n" "$((10#$(awk '{print $2}' <<< "$cron")))" "$((10#$(awk '{print $1}' <<< "$cron")))"
    else
        lbl "Расписание:"; printf "${C_YEL}не стоит${C_R}\n"
    fi
    if [[ -n "$DEST" ]]; then
        lbl "Сервер копий:"; printf "${C_GRN}%s${C_R} ${C_D}(хранить %s)${C_R}\n" "$DEST" "$KEEP_REMOTE"
    else
        lbl "Сервер копий:"; printf "${C_YEL}не настроен — копии только здесь${C_R}\n"
    fi
    case "$TG_MODE" in
        off) lbl "Telegram:"; printf "${C_YEL}выключен${C_R}\n" ;;
        *) lbl "Telegram:"; printf "${C_GRN}%s${C_R}, %s\n" "$([[ $TG_MODE == bot ]] && echo 'бот магазина' || echo 'свой бот')" \
               "$([[ $TG_NOTIFY == all ]] && echo 'после каждой копии' || echo 'только об ошибках')" ;;
    esac
    last="$(ls -t "$OUT_DIR"/server-backup-*.tgz 2>/dev/null | head -1 || true)"
    n="$(ls "$OUT_DIR"/server-backup-*.tgz 2>/dev/null | wc -l || true)"
    if [[ -n "$last" ]]; then
        lbl "Последняя копия:"; printf "${C_GRN}%s${C_R} ${C_D}(%s, %s; здесь копий: %s из %s)${C_R}\n" "$(basename "$last")" \
            "$(du -h "$last" | cut -f1)" "$(date -r "$last" '+%d.%m %H:%M')" "$n" "$KEEP_LOCAL"
    else
        lbl "Последняя копия:"; printf "${C_YEL}копий ещё нет${C_R}\n"
    fi
    if [[ -n "${ONLY_PROJECTS// /}" ]]; then lbl "Что копируем:"; printf "${C_MAG}только: %s${C_R}\n" "$(echo $ONLY_PROJECTS)"; fi
}
menu_item() { printf "   ${C_B}${C_CYN}%2s${C_R}  %s\n" "$1" "$2"; }
menu_run() {  # menu_run ПАРАМЕТРЫ… — этот же скрипт в нужном режиме; MENU_RC — его код
    echo
    MENU_RC=0
    SB_NO_MENU=1 bash "$SELF" "$@" || MENU_RC=$?
    (( MENU_RC == 0 )) || echo "${C_RED}Завершилось с ошибкой (код $MENU_RC).${C_R}"
    return 0
}
menu_projects() {  # список проектов compose на этом сервере
    docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | grep -v '^$' | sort -u || true
}
menu_once() {  # разовая копия: только / без проектов, дополнительные пути, без отправки
    local projects=() i a args=() p
    mapfile -t projects < <(menu_projects)
    echo
    echo "${C_B}Разовая копия${C_R} ${C_D}(настройки в backup.conf не меняются)${C_R}"
    if (( ${#projects[@]} )); then
        echo "Проекты docker compose на этом сервере:"
        for i in "${!projects[@]}"; do printf "   ${C_CYN}%2d${C_R}  %s\n" "$((i + 1))" "${projects[$i]}"; done
        read -r -p "Копировать только эти проекты — номера через пробел (Enter — весь сервер): " a
        for i in $a; do [[ "$i" =~ ^[0-9]+$ ]] && p="${projects[$((i - 1))]:-}" && [[ -n "$p" ]] && args+=(--only "$p"); done
        if (( ${#args[@]} == 0 )); then
            read -r -p "Не включать проекты — номера через пробел (Enter — ничего не исключать): " a
            for i in $a; do [[ "$i" =~ ^[0-9]+$ ]] && p="${projects[$((i - 1))]:-}" && [[ -n "$p" ]] && args+=(--skip "$p"); done
        fi
    fi
    read -r -p "Добавить файлы или папки — полные пути через пробел (Enter — нет): " a
    for p in $a; do args+=(--add "$p"); done
    if [[ -n "$DEST" ]]; then
        read -r -p "Отправить копию на $DEST? [Y/n] " a
        [[ "$a" =~ ^[NnНн] ]] && args+=(--no-upload)
    fi
    read -r -p "Посмотреть сначала, что попадёт в копию? [y/N] " a
    if [[ "$a" =~ ^[YyДд] ]]; then
        menu_run --plan "${args[@]}"
        read -r -p "Делать копию? [Y/n] " a
        [[ "$a" =~ ^[NnНн] ]] && return 0
    fi
    menu_run "${args[@]}"
}
if (( ARGC == 0 )) && [[ -t 0 && -t 1 && -z "${SB_NO_MENU:-}" ]]; then
    while true; do
        clear 2>/dev/null || true
        menu_status
        echo
        echo "  ${C_B}${C_MAG}Копия${C_R}"
        menu_item 1 "Сделать копию сейчас"
        menu_item 2 "Сделать копию без отправки на сервер копий"
        menu_item 3 "Разовая копия: выбрать проекты, добавить файлы"
        menu_item 4 "Показать, что попадёт в копию ${C_D}(ничего не копирует)${C_R}"
        echo "  ${C_B}${C_MAG}Настройка${C_R}"
        menu_item 5 "Настроить: время, хранение, сервер копий, Telegram"
        menu_item 6 "Поставить расписание из настроек"
        menu_item 7 "Снять расписание"
        echo "  ${C_B}${C_MAG}Сервер копий и уведомления${C_R}"
        menu_item 8 "Проверить доступ к серверу копий"
        menu_item 9 "Команды для настройки сервера копий"
        menu_item 10 "Отправить проверочное сообщение в Telegram"
        echo
        menu_item 0 "Выход"
        echo
        read -r -p "${C_B}Выберите пункт:${C_R} " choice || exit 0
        case "$choice" in
            1) menu_run ;;
            2) menu_run --no-upload ;;
            3) menu_once ;;
            4) menu_run --plan ;;
            5) menu_run --setup ;;
            6) menu_run --apply-cron ;;
            7) read -r -p "Снять расписание — копии по cron перестанут делаться? [y/N] " a
               [[ "$a" =~ ^[YyДд] ]] && menu_run --remove-cron ;;
            8) menu_run --check-remote ;;
            9) menu_run --remote-cmds ;;
            10) menu_run --test-notify ;;
            0|q|Q|й|Й) exit 0 ;;
            *) echo "${C_YEL}Нет такого пункта.${C_R}" ;;
        esac
        echo
        read -r -p "${C_D}Enter — вернуться в меню${C_R} " _ || exit 0
        # настройки могли поменяться
        # shellcheck disable=SC1090
        [[ -f "$CONF" ]] && source "$CONF"
        REMOTE_DIR="${REMOTE_DIR:-$(hostname)}"
        DEST=""; [[ -z "$REMOTE_HOST" ]] || DEST="$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
    done
fi

# ================================================================ настройка
if [[ "$MODE" == setup ]]; then
    [[ -t 0 ]] || die "настройку нужно запускать в терминале: bash $SELF → «Настроить»"
    ask() { local a; read -r -p "$1 [$2]: " a; echo "${a:-$2}"; }
    msk2srv() { date -d "@$(TZ=Europe/Moscow date -d "today $1" +%s)" +%H:%M; }
    srv2msk() { TZ=Europe/Moscow date -d "@$(date -d "today $1" +%s)" +%H:%M; }

    step "Настройка резервного копирования ($HOST)"
    echo "  Часовой пояс сервера: $(date +%Z) (сейчас $(date +%H:%M), в Москве $(TZ=Europe/Moscow date +%H:%M))"

    echo; echo "1) Расписание"
    t="$(ask "   Во сколько делать копию каждый день, время МОСКОВСКОЕ (ЧЧ:ММ)" "$(srv2msk "$CRON_TIME")")"
    [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || die "время в формате ЧЧ:ММ, например 03:30"
    CRON_TIME="$(msk2srv "$t")"
    echo "   → по часам сервера: $CRON_TIME"

    echo; echo "2) Хранение на этом сервере"
    OUT_DIR="$(ask "   Папка для копий на этом сервере" "$OUT_DIR")"
    [[ "$OUT_DIR" == /* && "$OUT_DIR" != / && "$OUT_DIR" != *" "* ]] || die "папка: полный путь без пробелов, например /root/backups"
    KEEP_LOCAL="$(ask "   Сколько последних копий хранить в $OUT_DIR" "$KEEP_LOCAL")"
    [[ "$KEEP_LOCAL" =~ ^[1-9][0-9]*$ ]] || die "нужно число"

    echo; echo "3) Копия на другой сервер (по SSH/SFTP)"
    echo "   Пусто или «-» — не отправлять, хранить копии только здесь."
    a="$(ask "   IP или домен сервера для копий" "${REMOTE_HOST:--}")"; [[ "$a" == - ]] && a=""; REMOTE_HOST="$a"
    if [[ -n "$REMOTE_HOST" ]]; then
        SSH_PORT="$(ask "   Порт SSH" "$SSH_PORT")"
        echo
        echo "   На сервере $REMOTE_HOST копии будут лежать у отдельного пользователя (логин),"
        echo "   в его домашней папке (обычно /home/логин), в подпапке. Например: логин backup, подпапка $HOST"
        echo "   → копии в /home/backup/$HOST на $REMOTE_HOST."
        REMOTE_USER="$(ask "   ЛОГИН пользователя на $REMOTE_HOST (создам, если нет)" "$REMOTE_USER")"
        [[ "$REMOTE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "логин: латиница, цифры, - и _, например backup"
        REMOTE_DIR="$(ask "   ПОДПАПКА для копий в домашней папке $REMOTE_USER" "$REMOTE_DIR")"
        [[ -n "$REMOTE_DIR" && "$REMOTE_DIR" != /* ]] || die "подпапка: имя без / в начале, например $HOST"
        echo "   → копии будут в ~$REMOTE_USER/$REMOTE_DIR на $REMOTE_HOST (вход как $REMOTE_USER); точный путь покажу после проверки доступа"
        KEEP_REMOTE="$(ask "   Сколько копий хранить там" "$KEEP_REMOTE")"
        [[ "$KEEP_REMOTE" =~ ^[1-9][0-9]*$ ]] || die "нужно число"

        echo
        echo "   SSH-ключ, которым этот сервер заходит туда:"
        echo "   1 — отдельный ключ для копий $SSH_KEY ($([[ -f "$SSH_KEY" ]] && echo есть || echo 'будет создан'))"
        echo "   2 — указать свой файл ключа"
        if [[ "$(ask "   Выбор" 1)" == 2 ]]; then
            SSH_KEY="$(ask "   Путь к закрытому ключу" "$SSH_KEY")"
            [[ -f "$SSH_KEY" ]] || die "нет файла $SSH_KEY"
            [[ -f "$SSH_KEY.pub" ]] || ssh-keygen -y -f "$SSH_KEY" > "$SSH_KEY.pub" || die "не удалось прочитать ключ (с паролем ключ не подойдёт для cron)"
        else
            SSH_KEY="/root/.ssh/server_backup_ed25519"
            [[ -f "$SSH_KEY" ]] || { ssh-keygen -t ed25519 -N "" -C "server-backup-$HOST" -f "$SSH_KEY" -q; echo "   ключ создан: $SSH_KEY"; }
        fi
        REMOTE_CMDS="$(remote_cmds)"

        echo
        echo "   Проверяю доступ к $(dest_host) (порт $SSH_PORT)..."
        until sftp_ok; do
            echo "   Доступа пока нет. Как настроить тот сервер:"
            echo "   1 — автоматически: зайду туда под root один раз (спросит пароль root того сервера),"
            echo "       создам пользователя $REMOTE_USER без shell, папку $REMOTE_DIR и добавлю ключ"
            echo "   2 — вручную: покажу команды, выполните их на том сервере под root"
            echo "   3 — пропустить (копии не будут отправляться, пока не настроите)"
            case "$(ask "   Выбор" 1)" in
                1) ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=yes \
                       "root@$REMOTE_HOST" "bash -s" <<< "$REMOTE_CMDS" || echo "   ! не получилось зайти под root" ;;
                2) echo; echo "----- выполните на $REMOTE_HOST под root -----"; echo "$REMOTE_CMDS"; echo "-----"
                   read -r -p "   Выполнили? Enter — проверить " _ ;;
                *) echo "   отправка отключена до настройки доступа"; REMOTE_HOST=""; break ;;
            esac
        done
        if [[ -n "$REMOTE_HOST" ]]; then
            printf -- '-mkdir %s\n' "$REMOTE_DIR" | sftp $(sftp_opts) -b - "$(dest_host)" >/dev/null 2>&1 || true
            echo "   доступ есть: копии будут в $(remote_path || echo "~$REMOTE_USER/$REMOTE_DIR") на $REMOTE_HOST"
            if ssh -p "$SSH_PORT" -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$(dest_host)" true >/dev/null 2>&1 \
                && [[ "$(ssh -p "$SSH_PORT" -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$(dest_host)" echo shell 2>/dev/null)" == shell ]]; then
                echo "   ! этим ключом там доступна командная строка — лучше ограничить ключ (вариант 2 покажет как)"
            fi
        fi
    fi
    DEST=""; [[ -z "$REMOTE_HOST" ]] || DEST="$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"

    echo; echo "4) Уведомления в Telegram"
    TG_MODE=bot; bot_ok="не найден"; tg_creds && bot_ok="найден, владелец $CHAT"
    echo "   1 — от бота магазина владельцу (BOT_TOKEN/BOT_OWNER_ID из /opt/remnashop/.env: $bot_ok)"
    echo "   2 — от другого бота (токен и chat id)"
    echo "   3 — не присылать"
    case "$(ask "   Выбор" 1)" in
        1) TG_MODE=bot ;;
        2) TG_MODE=custom
           TG_TOKEN="$(ask "   Токен бота" "${TG_TOKEN:--}")"
           TG_CHAT="$(ask "   chat id (свой id — у @userinfobot; группа — с минусом)" "${TG_CHAT:--}")" ;;
        *) TG_MODE=off ;;
    esac
    if [[ "$TG_MODE" != off ]]; then
        case "$(ask "   Когда писать: 1 — после каждой копии, 2 — только при ошибке" "$([[ $TG_NOTIFY == errors ]] && echo 2 || echo 1)")" in
            2) TG_NOTIFY=errors ;; *) TG_NOTIFY=all ;;
        esac
        if tg_send "🔧 Резервные копии $HOST настроены: каждый день в $t МСК, хранить $KEEP_LOCAL здесь${DEST:+ и $KEEP_REMOTE на $REMOTE_HOST}."; then
            echo "   проверочное сообщение отправлено — проверьте Telegram"
        else
            echo "   ! Telegram не принял сообщение: проверьте токен и chat id (бот должен быть запущен через /start)"
        fi
    fi

    {
        echo "# Настройки backup.sh. Меняются через меню: bash $SELF → «Настроить»"
        printf 'CRON_TIME=%q\nKEEP_LOCAL=%q\nOUT_DIR=%q\n' "$CRON_TIME" "$KEEP_LOCAL" "$OUT_DIR"
        printf 'REMOTE_HOST=%q\nREMOTE_USER=%q\nREMOTE_DIR=%q\nSSH_PORT=%q\nKEEP_REMOTE=%q\nSSH_KEY=%q\n' \
            "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_DIR" "$SSH_PORT" "$KEEP_REMOTE" "$SSH_KEY"
        printf 'TG_MODE=%q\nTG_TOKEN=%q\nTG_CHAT=%q\nTG_NOTIFY=%q\n' "$TG_MODE" "$TG_TOKEN" "$TG_CHAT" "$TG_NOTIFY"
        printf 'SKIP_PROJECTS=%q\nEXTRA_PATHS=%q\n' "$SKIP_PROJECTS" "$EXTRA_PATHS"
    } > "$CONF"
    chmod 600 "$CONF"

    line="$(apply_cron)"
    others="$(crontab -l | grep -vF "$SELF" | grep -iE 'backup' || true)"

    step "Готово"
    echo "  настройки: $CONF"
    echo "  cron:      $line"
    echo "  копии:     $OUT_DIR (последние $KEEP_LOCAL)${DEST:+, на $DEST (последние $KEEP_REMOTE)}"
    echo "  Telegram:  $([[ $TG_MODE == off ]] && echo выключен || { [[ $TG_NOTIFY == all ]] && echo 'после каждой копии' || echo 'только об ошибках'; })"
    echo "  лог:       $LOG"
    if [[ -n "$others" ]]; then
        echo
        echo "  На сервере есть и другие задания бэкапа (они не мешают, отключить — crontab -e):"
        echo "$others" | sed 's/^/    /'
    fi
    echo
    read -r -p "Сделать первую копию сейчас? [Y/n] " a
    [[ "$a" =~ ^[NnНн] ]] && exit 0
    SB_NO_MENU=1 exec bash "$SELF"
fi

if [[ "$MODE" == test-notify ]]; then
    tg_send "🔔 Проверка уведомлений резервных копий $HOST" && echo "${C_GRN}отправлено${C_R}" || die "Telegram не принял сообщение (TG_MODE=$TG_MODE)"
    exit 0
fi

# ================================================================ подготовка
# write_status: итог копии для внешних программ (STATUS_FILE), по строке key=value.
write_status() {  # write_status СОСТОЯНИЕ [key=value ...]
    [[ -n "$STATUS_FILE" ]] || return 0
    local f="$STATUS_FILE" kv
    mkdir -p "$(dirname "$f")"
    {
        echo "status=$1"; shift
        echo "host=$HOST"
        echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for kv in "$@"; do echo "${kv//$'\n'/ }"; done
    } > "$f.tmp" && mv "$f.tmp" "$f"
}

WORK="$(mktemp -d)"
TS="$(date -u +%Y%m%d-%H%M%S)"
NAME="server-backup-$HOST-$TS"
B="$WORK/$NAME"
mkdir -p "$B/db" "$B/redis" "$B/volumes"
FAILED_AT=""
RUNLOG="$WORK/run.log"

if [[ "$MODE" == backup ]]; then
    exec 9>/run/server-backup.lock
    flock -n 9 || die "копия уже делается (другой запуск ещё идёт)"
    if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG") > 5242880 )); then
        tail -n 3000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
    exec > >(tee >(nocolor | tee -a "$LOG" "$RUNLOG" >/dev/null)) 2>&1
    echo; echo "################ $(date '+%Y-%m-%d %H:%M:%S %Z') — резервная копия $HOST"
    write_status running "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

on_exit() {
    local rc=$?
    if [[ "$MODE" == backup ]] && (( rc )); then
        write_status failed "failed_at=${FAILED_AT:-?}" "code=$rc" "error=$(tail -n 3 "$RUNLOG" 2>/dev/null | nocolor | tr '\n' ' ' | cut -c1-300)"
    fi
    if [[ "$MODE" == backup ]] && (( rc )) && [[ "$TG_MODE" != off ]]; then
        sleep 1
        tg_send "❌ Резервная копия $HOST НЕ сделана
Шаг: ${FAILED_AT:-?}, код $rc

$(tail -n 8 "$RUNLOG" 2>/dev/null | nocolor | cut -c1-200)

Лог: $LOG" || true
    fi
    rm -rf "$WORK"
}
trap on_exit EXIT

dk() { docker inspect "$1" --format "$2" 2>/dev/null || true; }
lbl() { dk "$1" "{{index .Config.Labels \"$2\"}}"; }
cnt() { awk -F'|' -v p="$1" '$5==p' "$B/containers.txt" | wc -l; }
in_proj() { awk -F'|' -v p="$1" '$5==p {print $1}' "$B/containers.txt"; }
pg_user() { local u; u="$(docker exec "$1" printenv POSTGRES_USER 2>/dev/null || true)"; echo "${u:-postgres}"; }
pg_db() { local d; d="$(docker exec "$1" printenv POSTGRES_DB 2>/dev/null || true)"; echo "${d:-$(pg_user "$1")}"; }
psql_q() { docker exec "$1" psql -U "$(pg_user "$1")" -d "$(pg_db "$1")" -tAqc "$2" 2>/dev/null || true; }
COUNT_SQL="select coalesce(string_agg(t || '=' || (xpath('/row/c/text()', query_to_xml(
  'select count(*) as c from public.' || quote_ident(t), false, true, '')))[1]::text, ' ' order by o), '')
  from unnest(array['users','nodes','hosts','subscriptions','transactions']) with ordinality as a(t, o)
  where to_regclass('public.' || quote_ident(t)) is not null"
ru_counts() {
    local kv out=()
    for kv in $1; do
        case "${kv%%=*}" in
            users) out+=("пользователей ${kv#*=}") ;;
            nodes) out+=("нод ${kv#*=}") ;;
            hosts) out+=("хостов ${kv#*=}") ;;
            subscriptions) out+=("подписок ${kv#*=}") ;;
            transactions) out+=("платежей ${kv#*=}") ;;
        esac
    done
    local IFS=';'; echo "${out[*]}" | sed 's/;/, /g'
}
is_running() { [[ "$(dk "$1" '{{.State.Running}}')" == true ]]; }
is_pg() { [[ "$1" == postgres:* || "$1" == */postgres:* ]]; }
is_redis() { [[ "$1" == *valkey* || "$1" == *redis* ]]; }
has_data_vol() { dk "$1" '{{range .Mounts}}{{.Destination}} {{end}}' | grep -qw /data; }
human() { du -sh "$1" 2>/dev/null | cut -f1; }
d_fmt() { date -d "$1" +%d.%m.%Y; }
d_left() { echo $(( ( $(date -d "$1" +%s) - $(date +%s) ) / 86400 )); }
proj_title() {
    local imgs; imgs="$(awk -F'|' -v p="$1" '$5==p {print $2}' "$B/containers.txt")"
    case "$imgs" in
        *remnawave/backend*) echo "REMNAWAVE — панель" ;;
        *remnashop*) echo "REMNASHOP — бот" ;;
        *subscription-page*) echo "Страница подписки Remnawave" ;;
        *nginx*) echo "NGINX — веб-сервер" ;;
        *) echo "${1^^}" ;;
    esac
}

# ================================================================ что есть на сервере
FAILED_AT="поиск контейнеров"
{
    echo "created_utc=$TS"
    echo "hostname=$HOST"
    echo "ips=$(hostname -I | xargs)"
    if [[ -z "${ONLY_PROJECTS// /}" ]]; then
        echo "bot_commit=$(git -C /opt/remnashop-src rev-parse HEAD 2>/dev/null || true)"
        echo "bot_branch=$(git -C /opt/remnashop-src rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
} > "$B/MANIFEST"
# имя|образ|id образа|digest|проект|сервис|папка|файлы compose|состояние
for c in $(docker ps -a --format '{{.Names}}'); do
    iid="$(dk "$c" '{{.Image}}')"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$c" "$(dk "$c" '{{.Config.Image}}')" "$iid" \
        "$(docker image inspect "$iid" --format '{{join .RepoDigests " "}}' 2>/dev/null | awk '{print $1}')" \
        "$(lbl "$c" com.docker.compose.project)" "$(lbl "$c" com.docker.compose.service)" \
        "$(lbl "$c" com.docker.compose.project.working_dir)" \
        "$(lbl "$c" com.docker.compose.project.config_files)" "$(dk "$c" '{{.State.Status}}')"
done > "$B/containers.txt"

SKIP_DIRS=()
for sp in $SKIP_PROJECTS; do
    while IFS='|' read -r _ _ _ _ proj _ dir _; do
        [[ "$proj" == "$sp" && -n "$dir" ]] && SKIP_DIRS+=("$dir")
    done < "$B/containers.txt"
    [[ -d "/opt/$sp" ]] && SKIP_DIRS+=("/opt/$sp")
    awk -F'|' -v p="$sp" '$5!=p' "$B/containers.txt" > "$B/c.tmp" && mv "$B/c.tmp" "$B/containers.txt"
done
[[ -z "${SKIP_PROJECTS// /}" ]] || echo "skipped=${SKIP_PROJECTS# }" >> "$B/MANIFEST"
ONLY=0
if [[ -n "${ONLY_PROJECTS// /}" ]]; then  # только эти проекты: остальные контейнеры и разделы сервера не трогаем
    ONLY=1
    awk -F'|' -v l=" $ONLY_PROJECTS " 'index(l, " " $5 " ") && $5 != ""' "$B/containers.txt" > "$B/c.tmp" && mv "$B/c.tmp" "$B/containers.txt"
    for op in $ONLY_PROJECTS; do grep -q "^[^|]*|[^|]*|[^|]*|[^|]*|$op|" "$B/containers.txt" || warn "проект $op не найден среди контейнеров"; done
    echo "only=${ONLY_PROJECTS# }" >> "$B/MANIFEST"
fi

# Порядок: панель, бот, остальные.
mapfile -t PROJECTS < <(awk -F'|' '$5!="" {
    o = ($2 ~ /remnawave\/backend/) ? 1 : ($2 ~ /remnashop/) ? 2 : 3
    if (!($5 in best) || o < best[$5]) best[$5] = o; if (!($5 in first)) first[$5] = NR }
    END { for (p in best) print best[p] "|" first[p] "|" p }' "$B/containers.txt" \
    | sort -t'|' -k1,1n -k2,2n | cut -d'|' -f3)

PATHS=()           # что архивировать (без ведущего /)
EXCLUDES=()        # что не архивировать
add_path() {  # без дублей: вложенное в уже добавленное не добавляется, вложенное в новое убирается
    local p q keep=(); p="$(realpath -m "$1")"
    [[ -e "$p" ]] || return 0
    for q in "${PATHS[@]}"; do [[ "/$q" == "$p" || "$p" == "/$q/"* ]] && return 0; done
    for q in "${PATHS[@]}"; do [[ "/$q" == "$p/"* ]] || keep+=("$q"); done
    PATHS=("${keep[@]}" "${p#/}")
}
DB_LIST=(); REDIS_LIST=(); VOL_LIST=(); TG_LINES=()
N=0
item() { N=$((N + 1)); echo; echo "$N) $*"; }
line() { echo "   $*"; }

SUMMARY_FILE="$B/SUMMARY.txt"
{
echo "Резервная копия $HOST ($(hostname -I | awk '{print $1}')), $(date '+%d.%m.%Y %H:%M %Z')"
[[ "$MODE" == plan ]] && echo "РЕЖИМ ПРОСМОТРА: ничего не копируется, показано, что попадёт в копию."
echo "Что кладу в копию:"

# ---------------------------------------------------------------- проекты compose
for proj in "${PROJECTS[@]}"; do
    dir="$(awk -F'|' -v p="$proj" '$5==p {print $7; exit}' "$B/containers.txt")"
    title="$(proj_title "$proj")"
    item "$title"
    files="$(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' -o -name '.env' -o -name '*.conf' -o -name '*.json' -o -name '*.pem' -o -name '*.key' \) -printf '%f ' 2>/dev/null | xargs -n1 2>/dev/null | sort | xargs || true)"
    line "папка: $dir${files:+ ($files)}"
    line "контейнеры: $(in_proj "$proj" | xargs)"
    add_path "$dir"
    tg="$title"
    tg_parts=()
    while IFS='|' read -r c img _ _ _ svc _; do
        if is_pg "$img"; then
            if ! is_running "$c"; then warn "$c не запущен — дамп базы не снять"; continue; fi
            u="$(pg_user "$c")"; db="$(pg_db "$c")"
            pgv="$(docker exec "$c" psql -V 2>/dev/null | grep -oE '[0-9]+' | head -1)"
            size="$(psql_q "$c" "select pg_size_pretty(pg_database_size(current_database()))")"
            counts="$(ru_counts "$(psql_q "$c" "$COUNT_SQL")")"
            line "база: $c — PostgreSQL $pgv, «$db», $size${counts:+: $counts}"
            DB_LIST+=("$c|$proj|$svc|$u|$db|$pgv")
            tg_parts+=("база $size${counts:+, $counts}")
            while read -r src; do [[ -n "$src" ]] && EXCLUDES+=("$src"); done < <(dk "$c" \
                '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}')
        elif is_redis "$img"; then
            if has_data_vol "$c" && is_running "$c"; then
                keys="$(docker exec "$c" sh -c 'c=valkey-cli; command -v $c >/dev/null || c=redis-cli; $c DBSIZE' 2>/dev/null || true)"
                line "valkey: $c — данные (очереди, кэш)${keys:+, ключей $keys}; сохраняю dump.rdb"
                REDIS_LIST+=("$c|$proj|$svc")
            else
                line "valkey: $c — только кэш без тома, сохранять нечего"
            fi
        else
            # Именованные тома остальных контейнеров (кроме сокетов) — архивом тома.
            while IFS='|' read -r vol dst; do
                [[ -n "$vol" && "$dst" != /var/run* && "$dst" != /run* ]] || continue
                [[ " ${VOL_LIST[*]} " == *" $vol|"* ]] && continue
                mp="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
                line "том: $vol ($c:$dst) — $(human "$mp")"
                VOL_LIST+=("$vol|$c|$proj")
            done < <(dk "$c" '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}|{{.Destination}}{{"\n"}}{{end}}{{end}}')
        fi
        if [[ "$img" == *nginx* ]] && is_running "$c"; then
            confs="$(dk "$c" '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' | grep -E '\.conf$' | xargs || true)"
            doms="$(docker exec "$c" nginx -T 2>/dev/null | grep -oE '^\s*server_name\s[^;]+' \
                | awk '{for (i=2;i<=NF;i++) print $i}' | grep -vE '^(_|localhost)$' | sort -u | xargs || true)"
            line "nginx: конфиг ${confs:-внутри образа}"
            line "домены: ${doms:-—}"
        fi
        # Папки хоста, подключённые в контейнер (сайт, сертификаты), — тоже в копию.
        while read -r src; do
            case "$src" in ""|/dev*|/proc*|/sys*|/run*|/var/run*|/var/lib/docker*|/etc/localtime|/etc/timezone|/tmp*) continue ;; esac
            is_pg "$img" && continue
            add_path "$src"
        done < <(dk "$c" '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}')
    done < <(awk -F'|' -v p="$proj" '$5==p' "$B/containers.txt")
    (( ${#tg_parts[@]} )) && tg+=": ${tg_parts[*]}"
    TG_LINES+=("• $tg")
done
others="$(awk -F'|' '$5=="" {printf "%s ", $1}' "$B/containers.txt")"
[[ -z "$others" ]] || { echo; echo "   (контейнеры не из compose, не копируются: $others)"; }

if (( ! ONLY )); then  # ---------------------------------------- разделы всего сервера

# ---------------------------------------------------------------- исходники и прочее в /opt
OPT_OTHER=()
for d in /opt/*/; do
    d="${d%/}"
    case "$d" in /opt/containerd) continue ;; esac
    [[ " ${SKIP_DIRS[*]} " == *" $d "* ]] && continue
    covered=0; for q in "${PATHS[@]}"; do [[ "/$q" == "$d" || "$d" == "/$q/"* ]] && covered=1; done
    (( covered )) && continue
    OPT_OTHER+=("$d")
done
if (( ${#OPT_OTHER[@]} )); then
    item "Остальное в /opt (исходники, скрипты)"
    for d in "${OPT_OTHER[@]}"; do
        what=""
        if [[ -d "$d/.git" ]]; then
            what="git: ветка $(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null), коммит $(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
            [[ -z "$(git -C "$d" status --porcelain 2>/dev/null | head -1)" ]] || what+=", есть незакоммиченные изменения"
        fi
        [[ "$d" == /opt/remnashop-src ]] && what="исходники бота (из них собирается образ), $what"
        line "$d — $(human "$d")${what:+, $what}"
        add_path "$d"
    done
fi
for f in /opt/*; do [[ -f "$f" ]] && add_path "$f"; done

# ---------------------------------------------------------------- сайты
if compgen -G "/var/www/*" >/dev/null; then
    item "Сайты (/var/www)"
    for d in /var/www/*; do line "$d — $(human "$d")"; done
    add_path /var/www
fi

# ---------------------------------------------------------------- сертификаты
item "Сертификаты"
ncert=0; soon=""
cert_line() {  # cert_line ДОМЕН ФАЙЛ ДОП
    local end left; end="$(openssl x509 -enddate -noout -in "$2" 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "$end" ]] || { line "$1 — файл сертификата не читается"; return; }
    left="$(d_left "$end")"; ncert=$((ncert + 1))
    line "$1 — до $(d_fmt "$end") (осталось $left дн.)$3"
    (( left < 14 )) && warn "сертификат $1 истекает через $left дн."
    if [[ -z "$soon" ]] || (( left < ${soon%%|*} )); then soon="$left|$(echo $1)|$(d_fmt "$end")"; fi
}
if [[ -d /root/.acme.sh ]]; then
    line "acme.sh (/root/.acme.sh, продление по cron):"
    for d in /root/.acme.sh/*/; do
        dom="$(basename "$d")"; dom="${dom%_ecc}"
        conf="$d$dom.conf"; [[ -f "$conf" && -f "$d$dom.cer" ]] || continue
        inst="$(grep -E "^Le_RealFullChainPath=" "$conf" | cut -d= -f2- | tr -d "'" || true)"
        rel="$(grep -E "^Le_ReloadCmd=" "$conf" | cut -d= -f2- | tr -d "'" || true)"
        extra="${inst:+, копируется в $inst}"
        [[ -n "$inst" && -z "$rel" ]] && extra+=" ⚠ после продления nginx сам не перезагружается"
        cert_line "  $dom" "$d$dom.cer" "$extra"
    done
    add_path /root/.acme.sh
fi
if [[ -d /etc/letsencrypt/live ]]; then
    line "certbot (/etc/letsencrypt):"
    for d in /etc/letsencrypt/live/*/; do
        [[ -f "${d}cert.pem" ]] && cert_line "  $(basename "$d")" "${d}cert.pem" ""
    done
    add_path /etc/letsencrypt
fi
(( ncert )) || line "не найдено"
[[ -z "$soon" ]] || TG_LINES+=("• Сертификаты: $ncert, ближайший ${soon#*|} → ${soon##*|} (${soon%%|*} дн.)")
[[ -d /usr/local/remnawave_reverse ]] && add_path /usr/local/remnawave_reverse
command -v nginx >/dev/null 2>&1 && [[ -d /etc/nginx ]] && add_path /etc/nginx

# ---------------------------------------------------------------- cron, firewall, ssh
item "Расписания cron, firewall, SSH"
crontab -l 2>/dev/null > "$B/crontab.txt" || true
jobs="$(grep -vE '^\s*(#|$|[A-Z_]+=)' "$B/crontab.txt" || true)"
line "crontab root, заданий: $(echo -n "$jobs" | grep -c '' || true)"
[[ -z "$jobs" ]] || echo "$jobs" | cut -c1-140 | sed 's/^/     /'
CRON_D=()
for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in e2scrub_all|sysstat|popularity-contest|anacron|.placeholder|php) continue ;; esac
    CRON_D+=("$f"); add_path "$f"
done
(( ${#CRON_D[@]} )) && line "/etc/cron.d: ${CRON_D[*]}"
if command -v ufw >/dev/null; then
    ufw status numbered > "$B/ufw.txt" 2>&1 || true
    line "ufw: $(head -1 "$B/ufw.txt" | sed 's/Status: //'), правил: $(grep -c '^\[' "$B/ufw.txt" || true) (для справки при переезде)"
fi
if [[ -d /root/.ssh ]]; then
    line "/root/.ssh: ключи доступа и деплой-ключи (пар ключей: $(find /root/.ssh -maxdepth 1 -type f -name '*.pub' | wc -l))"
    add_path /root/.ssh
fi
fi  # разделы всего сервера
for p in $EXTRA_PATHS; do
    [[ -e "$p" ]] || { warn "$p (дополнительный путь) не найден"; continue; }
    item "Дополнительно: $p — $(human "$p")"; add_path "$p"
done

# ---------------------------------------------------------------- исключения
# '*.log' — на любой глубине; остальные пути — от корня и '*' только в одной папке: без --anchored /
# --no-wildcards-match-slash 'opt/*/backup' совпадал и с opt/remnashop-src/src/…/backup (исходники бота).
TAR_EX=(--exclude='*.log' --anchored --no-wildcards-match-slash
        --exclude=opt/containerd --exclude='opt/*/logs' --exclude='opt/*/backups' --exclude='opt/*/backup'
        --exclude="${OUT_DIR#/}" --exclude='root/restore-*' --exclude='root/.cache')
for e in "${EXCLUDES[@]}" $(printf '%s\n' "${SKIP_DIRS[@]}" | sort -u); do TAR_EX+=("--exclude=${e#/}"); done
echo
if (( ONLY )); then
    echo "Только проекты: ${ONLY_PROJECTS}${EXTRA_PATHS:+ и дополнительные пути}. Остальное на сервере не копируется"
    echo "(другие проекты, /opt, сайты, сертификаты, cron, /root/.ssh)."
else
    echo "Не кладу: логи, папки backup(s) внутри /opt (старые дампы и архивы других скриптов),"
    echo "файлы баз (вместо них дампы), /opt/containerd, $OUT_DIR${SKIP_PROJECTS:+, проекты:$SKIP_PROJECTS}."
fi
} > "$SUMMARY_FILE"   # не через pipe: переменные из блока нужны дальше
cat "$SUMMARY_FILE"

# ================================================================ куда и как
echo
echo "Архив: $OUT_DIR/$NAME.tgz, хранится последних копий: $KEEP_LOCAL"
if [[ -n "$DEST" ]] && (( UPLOAD )); then
    echo "Отправка: $DEST (порт $SSH_PORT), там хранится последних копий: $KEEP_REMOTE"
else
    echo "Отправка на другой сервер: $([[ -n "$DEST" ]] && echo 'в этот раз не отправляется' || echo "не настроена (bash $SELF → «Настроить»)")"
fi
echo "Telegram: $([[ $TG_MODE == off ]] && echo выключен || { [[ $TG_NOTIFY == all ]] && echo 'после каждой копии' || echo 'только об ошибках'; })"

if [[ "$MODE" == plan ]]; then
    echo
    echo "${C_B}Режим просмотра: ничего не скопировано.${C_R}"
    exit 0
fi

# ================================================================ копия
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
free_mb="$(df -Pm "$OUT_DIR" | awk 'NR==2 {print $4}')"
(( free_mb > 500 )) || die "мало места на диске: свободно ${free_mb} МБ"

step "Дампы баз PostgreSQL"
FAILED_AT="дамп баз"
: > "$B/db/list.txt"
for row in "${DB_LIST[@]}"; do
    IFS='|' read -r c proj svc u db pgv <<< "$row"
    docker exec "$c" pg_dump -U "$u" -d "$db" -Fc > "$B/db/$c.dump"
    echo "$row" >> "$B/db/list.txt"
    echo "  $c ($db): $(human "$B/db/$c.dump")"
done

step "Данные valkey / redis"
FAILED_AT="valkey"
: > "$B/redis/list.txt"
for row in "${REDIS_LIST[@]}"; do
    IFS='|' read -r c proj svc <<< "$row"
    cli="valkey-cli"; docker exec "$c" sh -c 'command -v valkey-cli' >/dev/null 2>&1 || cli="redis-cli"
    if docker exec "$c" "$cli" SAVE >/dev/null 2>&1 && docker cp "$c:/data/dump.rdb" "$B/redis/$c.rdb" 2>/dev/null; then
        echo "$row" >> "$B/redis/list.txt"
        echo "  $c: $(human "$B/redis/$c.rdb")"
    else
        warn "$c: не удалось сохранить dump.rdb (пропущен)"
    fi
done

if (( ${#VOL_LIST[@]} )); then
    step "Тома docker"
    FAILED_AT="тома"
    : > "$B/volumes/list.txt"
    for row in "${VOL_LIST[@]}"; do
        IFS='|' read -r vol c proj <<< "$row"
        mp="$(docker volume inspect -f '{{.Mountpoint}}' "$vol")"
        tar -C "$mp" -czf "$B/volumes/$vol.tgz" .
        echo "$row" >> "$B/volumes/list.txt"
        echo "  $vol: $(human "$B/volumes/$vol.tgz")"
    done
fi

step "Файлы"
FAILED_AT="архив файлов"
tar -C / "${TAR_EX[@]}" -czf "$B/files.tgz" "${PATHS[@]}"
printf '  /%s\n' "${PATHS[@]}"
echo "  → $(human "$B/files.tgz")"
cp "$SELF" "$B/backup.sh"
[[ -f "$DIR/restore.sh" ]] && cp "$DIR/restore.sh" "$B/restore.sh"

FAILED_AT="упаковка"
ARCHIVE="$OUT_DIR/$NAME.tgz"
tar -C "$WORK" -czf "$ARCHIVE.part" "$NAME"
gzip -t "$ARCHIVE.part"
mv "$ARCHIVE.part" "$ARCHIVE"; chmod 600 "$ARCHIVE"
SIZE="$(human "$ARCHIVE")"
step "Архив: $ARCHIVE ($SIZE)"

ls -1t "$OUT_DIR"/server-backup-"$HOST"-*.tgz 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)) | xargs -r rm -f
rm -f "$OUT_DIR"/*.tgz.part
LOCAL_N="$(ls -1 "$OUT_DIR"/server-backup-"$HOST"-*.tgz 2>/dev/null | wc -l)"
echo "  здесь хранится копий: $LOCAL_N (из $KEEP_LOCAL)"

# ================================================================ отправка и ротация там
UPLOADED=""
if (( UPLOAD )) && [[ -n "$DEST" ]]; then
    step "Отправка на $DEST"
    FAILED_AT="отправка на $(dest_host)"
    host="$(dest_host)"; dir="$(dest_dir)"
    # Под временным именем, затем переименование: недокачанный архив там не окажется.
    printf -- '-mkdir %s\n' "$dir" | sftp $(sftp_opts) -b - "$host" >/dev/null 2>&1 || true
    sftp $(sftp_opts) -b - "$host" >/dev/null <<SFTP
put $ARCHIVE $dir/$NAME.tgz.part
rename $dir/$NAME.tgz.part $dir/$NAME.tgz
SFTP
    echo "  отправлено: $dir/$NAME.tgz"
    FAILED_AT="ротация на $(dest_host)"
    mapfile -t remote < <(echo "ls -1 $dir" | sftp $(sftp_opts) -b - "$host" 2>/dev/null \
        | grep -oE "server-backup-$HOST-[0-9]{8}-[0-9]{6}\.tgz$" | sort)
    old=$(( ${#remote[@]} - KEEP_REMOTE ))
    if (( old > 0 )); then
        for f in "${remote[@]:0:$old}"; do echo "-rm $dir/$f"; done | sftp $(sftp_opts) -b - "$host" >/dev/null 2>&1 || warn "не удалось удалить старые копии там"
        echo "  удалено старых копий там: $old"
    fi
    REMOTE_N=$(( ${#remote[@]} - (old > 0 ? old : 0) ))
    echo "  там хранится копий: $REMOTE_N (из $KEEP_REMOTE)"
    UPLOADED="☁️ Копия на $host: есть (там $REMOTE_N из $KEEP_REMOTE)"
elif (( UPLOAD )); then
    warn "отправка на другой сервер не настроена — копия только здесь (bash $SELF → «Настроить»)"
fi
FAILED_AT=""
write_status ok "archive=$NAME.tgz" "size=$(stat -c %s "$ARCHIVE")" "uploaded=${UPLOADED:+$(dest_host):$(dest_dir)}" \
    "local_count=$LOCAL_N" "warnings=$(printf '%s; ' "${WARNINGS[@]}" | sed 's/; $//')"

# ================================================================ отчёт
if [[ "$TG_MODE" != off && "$TG_NOTIFY" == all ]]; then
    msg="✅ Резервная копия $HOST
📦 $NAME.tgz — $SIZE
$(printf '%s\n' "${TG_LINES[@]}")
${UPLOADED:-⚠️ На другой сервер не отправлялась}
🗂 Здесь хранится: $LOCAL_N из $KEEP_LOCAL"
    (( ${#WARNINGS[@]} )) && msg+="

⚠️ $(printf '%s\n' "${WARNINGS[@]}" | sort -u | head -5)"
    tg_send "$msg" || echo "  ! Telegram не принял сообщение"
fi
echo
echo "${C_B}${C_GRN}Готово.${C_R}"

#!/usr/bin/env bash
# Восстановление сервера из архива backup.sh на ЧИСТОМ сервере (Ubuntu/Debian).
# Запуск:  bash restore.sh — меню: выбор архива, проверка плана, восстановление с запуском или без.
#
# Служебные параметры (для программ; в меню есть всё то же):
#   bash restore.sh АРХИВ [--check] [--yes] [--force] [--no-start]
#   --check    только показать, что будет сделано (ничего не меняет)
#   --yes      не задавать вопросов (кроме установки docker)
#   --force    продолжить, даже если на сервере уже есть контейнеры с такими именами
#              (базы с данными скрипт не перезаписывает и с --force)
#   --no-start всё восстановить, но ничего не запускать: после заливки баз остановить их,
#              cron не ставить (перенос заранее, пока старый сервер ещё главный)
#
# Порядок: файлы (/opt, сертификаты, сайт, ~/.ssh — без замены существующих ключей) → те же
# версии образов (по digest) → контейнеры compose (создаются, не запускаются) → данные valkey →
# базы PostgreSQL из дампов → запуск всего → cron → проверка доменов.
set -euo pipefail

ARCHIVE=""; CHECK_ONLY=0; YES=0; FORCE=0; NO_START=0; ARGC=$#
SELF="$(realpath "$0")"
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --yes) YES=1 ;;
        --force) FORCE=1 ;;
        --no-start) NO_START=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; exit 0 ;;
        -*) echo "Неизвестный параметр: $1 (запустите без параметров — откроется меню)" >&2; exit 1 ;;
        *) ARCHIVE="$1" ;;
    esac
    shift
done

# Цвета — только в терминале. Имена с C_: R и B у скрипта заняты (папки распаковки).
if [[ -t 1 ]]; then
    C_R=$'\e[0m' C_B=$'\e[1m' C_D=$'\e[2m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m' C_MAG=$'\e[35m' C_CYN=$'\e[36m'
else
    C_R="" C_B="" C_D="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_MAG="" C_CYN=""
fi
step() { echo; echo "${C_B}${C_CYN}==>${C_R}${C_B} $*${C_R}"; }
warn() { echo "  ${C_YEL}! $*${C_R}"; }
die() { echo; echo "${C_B}${C_RED}ОШИБКА:${C_R}${C_RED} $*${C_R}" >&2; exit 1; }
confirm() {
    (( YES )) && return 0
    read -r -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[YyДд] ]]
}

[[ $EUID -eq 0 ]] || die "запустите от root"

# ================================================================ меню
# Без параметров в терминале: выбрать архив, потом действие. Действие запускает этот же скрипт
# с архивом и нужными параметрами (SB_NO_MENU=1 — без меню).
menu_archives() {  # архивы backup.sh на этом сервере, новые первыми
    ls -t /root/server-backup-*.tgz /root/backups/server-backup-*.tgz ./server-backup-*.tgz 2>/dev/null \
        | while read -r f; do realpath "$f"; done | awk '!seen[$0]++' || true
}
menu_pick() {  # → ARCHIVE
    local list=() i a
    mapfile -t list < <(menu_archives)
    echo
    if (( ${#list[@]} )); then
        echo "${C_B}Архивы на этом сервере:${C_R}"
        for i in "${!list[@]}"; do
            printf "   ${C_B}${C_CYN}%2d${C_R}  %s ${C_D}(%s, %s)${C_R}\n" "$((i + 1))" "${list[$i]}" "$(du -h "${list[$i]}" | cut -f1)" "$(date -r "${list[$i]}" '+%d.%m.%Y %H:%M')"
        done
        read -r -p "Номер архива или полный путь к другому (0 — выход): " a || exit 0
    else
        echo "${C_YEL}Архивов server-backup-*.tgz в /root и /root/backups нет.${C_R}"
        read -r -p "Полный путь к архиву (Enter — выход): " a || exit 0
    fi
    case "$a" in
        ""|0) exit 0 ;;
        *[!0-9]*) ARCHIVE="$a" ;;
        *) ARCHIVE="${list[$((a - 1))]:-}" ;;
    esac
    [[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "${C_RED}Нет такого архива: ${a}${C_R}"; ARCHIVE=""; }
}
menu_run() {  # menu_run ПАРАМЕТРЫ… — этот же скрипт с выбранным архивом
    echo
    local rc=0
    SB_NO_MENU=1 bash "$SELF" "$ARCHIVE" "$@" || rc=$?
    (( rc == 0 )) || echo "${C_RED}Завершилось с ошибкой (код $rc).${C_R}"
    return 0
}
menu_item() { printf "   ${C_B}${C_CYN}%2s${C_R}  %s\n" "$1" "$2"; }
if (( ARGC == 0 )) && [[ -t 0 && -t 1 && -z "${SB_NO_MENU:-}" ]]; then
    clear 2>/dev/null || true
    echo "${C_B}${C_BLU}╭──────────────────────────────────────────────────────────╮${C_R}"
    printf "${C_B}${C_BLU}│${C_R}  ${C_B}Восстановление сервера${C_R} · ${C_CYN}%-31s${C_R}${C_B}${C_BLU}│${C_R}\n" "$(hostname)"
    echo "${C_B}${C_BLU}╰──────────────────────────────────────────────────────────╯${C_R}"
    while [[ -z "$ARCHIVE" ]]; do menu_pick; done
    while true; do
        echo
        echo "  ${C_B}Архив:${C_R} ${C_GRN}${ARCHIVE}${C_R} ${C_D}($(du -h "$ARCHIVE" | cut -f1), $(date -r "$ARCHIVE" '+%d.%m.%Y %H:%M'))${C_R}"
        if docker ps -aq 2>/dev/null | grep -q .; then
            echo "  ${C_YEL}На этом сервере уже есть контейнеры docker: $(docker ps -a --format '{{.Names}}' | head -5 | xargs)…${C_R}"
        fi
        echo
        echo "  ${C_B}${C_MAG}Проверка${C_R}"
        menu_item 1 "Показать план восстановления ${C_D}(ничего не меняет)${C_R}"
        echo "  ${C_B}${C_MAG}Восстановление${C_R}"
        menu_item 2 "Восстановить и запустить всё"
        menu_item 3 "Восстановить без запуска ${C_D}(перенос заранее, пока старый сервер главный)${C_R}"
        menu_item 4 "Восстановить, даже если такие контейнеры уже есть ${C_D}(базы с данными не перезаписываются)${C_R}"
        echo
        menu_item 5 "Выбрать другой архив"
        menu_item 0 "Выход"
        echo
        read -r -p "${C_B}Выберите пункт:${C_R} " choice || exit 0
        case "$choice" in
            1) menu_run --check ;;
            2) read -r -p "Восстановить из архива и запустить все сервисы на этом сервере? [y/N] " a
               [[ "$a" =~ ^[YyДд] ]] && menu_run ;;
            3) read -r -p "Восстановить из архива, ничего не запуская? [y/N] " a
               [[ "$a" =~ ^[YyДд] ]] && menu_run --no-start ;;
            4) read -r -p "Без запуска сервисов? [y/N] " a
               if [[ "$a" =~ ^[YyДд] ]]; then menu_run --force --no-start; else menu_run --force; fi ;;
            5) ARCHIVE=""; while [[ -z "$ARCHIVE" ]]; do menu_pick; done ;;
            0|q|Q|й|Й) exit 0 ;;
            *) echo "${C_YEL}Нет такого пункта.${C_R}" ;;
        esac
        echo
        read -r -p "${C_D}Enter — вернуться в меню${C_R} " _ || exit 0
    done
fi
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "укажите архив: bash $SELF — откроется меню"

# ================================================================ архив
step "Архив $ARCHIVE"
R="/root/restore-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$R"; chmod 700 "$R"
tar -xzf "$ARCHIVE" -C "$R"
B="$(find "$R" -mindepth 1 -maxdepth 1 -type d -name 'server-backup-*' | head -1)"
[[ -n "$B" && -f "$B/MANIFEST" && -f "$B/containers.txt" && -f "$B/files.tgz" ]] \
    || die "это не архив backup.sh (нет MANIFEST / containers.txt / files.tgz)"
[[ ! -f "$B/SUMMARY.txt" ]] || { echo; sed -n '3,200p' "$B/SUMMARY.txt" | sed '/^Не кладу/,$d'; echo; }
mf() { grep -E "^$1=" "$B/MANIFEST" | cut -d= -f2-; }
echo "сделан: $(mf created_utc) UTC на $(mf hostname) ($(mf ips))"
[[ -z "$(mf bot_commit)" ]] || echo "бот: ветка $(mf bot_branch), коммит $(mf bot_commit | cut -c1-7)"
echo "распакован в $R"

# Проекты compose: имя|папка|файлы — в порядке появления.
mapfile -t PROJECTS < <(awk -F'|' '$5!="" && !seen[$5]++ {print $5"|"$7"|"$8}' "$B/containers.txt")
echo "проекты compose:"
for p in "${PROJECTS[@]}"; do
    IFS='|' read -r name dir files <<< "$p"
    echo "  $name ($dir): $(awk -F'|' -v p="$name" '$5==p {printf "%s ", $1}' "$B/containers.txt")"
done
others="$(awk -F'|' '$5=="" {printf "%s ", $1}' "$B/containers.txt")"
[[ -z "$others" ]] || warn "контейнеры не из compose (не восстанавливаются): $others"

# ================================================================ проверки
step "Сервер"
if ! command -v docker >/dev/null 2>&1; then
    warn "docker не установлен"
    (( CHECK_ONLY )) || { [[ -t 0 ]] && confirm "Установить docker (get.docker.com)?"; } \
        || die "установите docker и запустите снова"
    (( CHECK_ONLY )) || { curl -fsSL https://get.docker.com | sh; }
fi
if command -v docker >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 || die "нет плагина docker compose (apt install docker-compose-plugin)"
    echo "docker: $(docker --version | cut -d, -f1), compose: $(docker compose version --short)"
    busy=""
    for c in $(cut -d'|' -f1 "$B/containers.txt"); do
        docker inspect "$c" >/dev/null 2>&1 && busy+="$c "
    done
    if [[ -n "$busy" ]]; then
        warn "на сервере уже есть контейнеры: $busy"
        (( FORCE )) || die "сервер не чистый. Восстановление рассчитано на новый сервер.
Если вы уверены (например, всё остановлено и базы пустые) — меню → «Восстановить, даже если такие контейнеры уже есть»."
    fi
fi
NEW_IPS="$(hostname -I | xargs)"
echo "IP этого сервера: $NEW_IPS (в копии: $(mf ips))"

step "Базы и данные"
while IFS='|' read -r c proj svc user db pgv; do
    echo "  $c: база $db (PostgreSQL $pgv), дамп $(du -h "$B/db/$c.dump" | cut -f1)"
done < "$B/db/list.txt"
while IFS='|' read -r c proj svc; do
    echo "  $c: dump.rdb $(du -h "$B/redis/$c.rdb" | cut -f1)"
done < "$B/redis/list.txt"
[[ ! -s "$B/volumes/list.txt" ]] || while IFS='|' read -r vol c proj; do
    echo "  том $vol ($c): $(du -h "$B/volumes/$vol.tgz" | cut -f1)"
done < "$B/volumes/list.txt"

if (( CHECK_ONLY )); then
    echo
    echo "${C_B}Режим проверки: ничего не изменено${C_R} (архив распакован в $R — можно удалить)."
    exit 0
fi
echo
confirm "Восстановить всё это на этом сервере?" || die "отменено"

# ================================================================ файлы
step "Файлы"
tar -xzf "$B/files.tgz" -C / --exclude=root/.ssh
# ~/.ssh: добавить ключи из копии (ключ GitHub для бота и т. п.), не трогая существующие файлы.
if tar -tzf "$B/files.tgz" root/.ssh >/dev/null 2>&1; then
    tar -xzf "$B/files.tgz" -C / --skip-old-files root/.ssh
    chmod 700 /root/.ssh
fi
tar -tzf "$B/files.tgz" | awk -F/ 'NF>1 && $2!="" {print "/"$1"/"$2}' | sort -u | sed 's/^/  /' | head -30

# ================================================================ образы
step "Образы (те же версии, что в копии)"
while IFS='|' read -r c img iid dig proj _; do
    [[ -n "$dig" ]] || continue
    echo "$img|$dig"
done < "$B/containers.txt" | sort -u | while IFS='|' read -r img dig; do
    if docker pull -q "$dig" >/dev/null && docker tag "$dig" "$img"; then
        echo "  $img ← ${dig#*@}"
    else
        warn "$img: не удалось скачать $dig — будет взят текущий $img"
    fi
done

# ================================================================ контейнеры
compose() {  # compose ПРОЕКТ ПАПКА ФАЙЛЫ аргументы...
    local name="$1" dir="$2" files="$3"; shift 3
    local args=(-p "$name" --project-directory "$dir")
    local f; IFS=',' read -ra fl <<< "$files"
    for f in "${fl[@]}"; do args+=(-f "$f"); done
    docker compose "${args[@]}" "$@"
}
project_of() { local p; for p in "${PROJECTS[@]}"; do [[ "${p%%|*}" == "$1" ]] && echo "$p" && return; done; }

# Проекты могут зависеть друг от друга (внешняя сеть remnawave-network создаётся панелью) —
# повторяем, пока все не пройдут или пока есть прогресс.
in_order() {  # in_order аргументы compose... — для всех проектов
    local pending=("${PROJECTS[@]}") left progress p name dir files
    while (( ${#pending[@]} )); do
        left=(); progress=0
        for p in "${pending[@]}"; do
            IFS='|' read -r name dir files <<< "$p"
            if compose "$name" "$dir" "$files" "$@" >"$R/compose-$name.log" 2>&1; then
                echo "  $name — ок"; progress=1
            else
                left+=("$p")
            fi
        done
        if (( ! progress )); then
            for p in "${left[@]}"; do
                echo "  ${p%%|*} — ошибка:"; tail -15 "$R/compose-${p%%|*}.log" | sed 's/^/      /'
            done
            return 1
        fi
        pending=("${left[@]}")
    done
}

step "Создание контейнеров (сборка бота из /opt/remnashop-src)"
in_order up --no-start --build || die "контейнеры не созданы. Логи: $R/compose-*.log"

step "Данные valkey / redis"
while IFS='|' read -r c proj svc; do
    docker cp "$B/redis/$c.rdb" "$c:/data/dump.rdb" && echo "  $c — dump.rdb на месте"
done < "$B/redis/list.txt"

if [[ -s "$B/volumes/list.txt" ]]; then
    step "Тома docker"
    while IFS='|' read -r vol c proj; do
        mp="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        if [[ -n "$mp" ]]; then
            tar -xzf "$B/volumes/$vol.tgz" -C "$mp" && echo "  $vol — восстановлен"
        else
            warn "том $vol не создан compose — данные остались в $B/volumes/$vol.tgz"
        fi
    done < "$B/volumes/list.txt"
fi

step "Базы PostgreSQL"
while IFS='|' read -r c proj svc user db pgv; do
    IFS='|' read -r name dir files <<< "$(project_of "$proj")"
    compose "$name" "$dir" "$files" up -d "$svc" >/dev/null 2>&1
    ok=0
    for _ in $(seq 60); do
        if docker exec "$c" pg_isready -U "$user" -d "$db" >/dev/null 2>&1 \
            && docker exec "$c" psql -U "$user" -d "$db" -tAc 'select 1' >/dev/null 2>&1; then ok=1; break; fi
        sleep 2
    done
    (( ok )) || die "$c не запустился. Логи: docker logs $c"
    tables="$(docker exec "$c" psql -U "$user" -d "$db" -tAc \
        "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
    if (( tables > 0 )); then
        die "в базе $db ($c) уже есть таблицы ($tables) — не перезаписываю. Дамп: $B/db/$c.dump"
    fi
    if ! docker exec -i "$c" pg_restore -U "$user" -d "$db" --no-owner --no-privileges \
        < "$B/db/$c.dump" 2>"$R/pg_restore-$c.log"; then
        warn "$c: pg_restore завершился с замечаниями ($R/pg_restore-$c.log):"
        tail -5 "$R/pg_restore-$c.log" | sed 's/^/      /'
    fi
    tables="$(docker exec "$c" psql -U "$user" -d "$db" -tAc \
        "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
    echo "  $c: база $db восстановлена, таблиц: $tables"
done < "$B/db/list.txt"

if (( NO_START )); then
    step "Без запуска"
    in_order stop >/dev/null 2>&1 || true
    docker ps -a --format '{{.Names}}|{{.Status}}' | grep -Ff <(cut -d'|' -f1 "$B/containers.txt") \
        | sed -e 's/|/   /' -e 's/^/  /'
    echo
    echo "${C_B}${C_GRN}Всё восстановлено, контейнеры созданы и остановлены, cron не ставился.${C_R}"
    echo "Распакованная копия: $R. Запуск, когда старый сервер остановлен:"
    echo "  каждый проект: cd ПАПКА && docker compose up -d  (сначала панель — она создаёт сеть)"
    echo "  cron из копии: $B/crontab.txt"
    exit 0
fi

step "Запуск"
in_order up -d || die "не все проекты запустились. Логи: $R/compose-*.log"
sleep 15
docker ps -a --format '{{.Names}}|{{.Status}}' | grep -Ff <(cut -d'|' -f1 "$B/containers.txt") \
    | sed -e 's/|/   /' -e 's/^/  /'

# ================================================================ cron
step "cron"
if [[ -s "$B/crontab.txt" ]]; then
    cur="$(crontab -l 2>/dev/null || true)"
    missing="$(grep -vxF -f <(echo "$cur") "$B/crontab.txt" | grep -vE '^\s*(#|$)' || true)"
    if [[ -z "$missing" ]]; then
        echo "  задачи из копии уже есть"
    else
        echo "  задачи из копии, которых нет здесь:"; echo "$missing" | sed 's/^/    /'
        if confirm "Добавить их в crontab?"; then
            { [[ -n "$cur" ]] && echo "$cur"; echo "$missing"; } | crontab -
            echo "  добавлены"
        fi
    fi
else
    echo "  в копии crontab пуст"
fi
[[ ! -s "$B/ufw.txt" ]] || { echo "  правила ufw старого сервера (для справки): $B/ufw.txt"; }

# ================================================================ проверка
step "Проверка доменов (запрос на этот сервер, мимо DNS)"
NGX="$(awk -F'|' '$2 ~ /(^|\/)nginx[:@]/ {print $1; exit}' "$B/containers.txt")"
DOMAINS=""
if [[ -n "$NGX" ]]; then
    DOMAINS="$(docker exec "$NGX" nginx -T 2>/dev/null | grep -oE '^\s*server_name\s[^;]+' \
        | awk '{for (i=2;i<=NF;i++) print $i}' | grep -vE '^(_|localhost)$|^[~*.]' | sort -u | xargs || true)"
fi
for d in $DOMAINS; do
    code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$d:443:127.0.0.1" "https://$d/" || true)"
    echo "  https://$d → $code"
done
echo "  (444/000 у панели и подписок без секретной cookie — это нормально)"

echo
echo "${C_B}${C_GRN}Восстановление завершено.${C_R} Распакованная копия: $R (удалите после проверки)."
echo
echo "Осталось:"
if [[ " $NEW_IPS " != *" $(mf ips | awk '{print $1}') "* ]]; then
    echo "  - DNS: IP сервера изменился ($(mf ips | awk '{print $1}') → ${NEW_IPS%% *})."
    echo "    Поменяйте A-записи доменов${DOMAINS:+ ($DOMAINS)} в Cloudflare на новый IP."
    echo "    Ноды Remnawave подключатся к панели сами, когда DNS обновится."
fi
echo "  - Откройте порты 80/443 (и 22) в файрволе, если он есть: правила старого сервера в $B/ufw.txt."
echo "  - Проверьте бота (/start), панель и сайт. Вебхук Platega менять не нужно, если домен бота тот же."

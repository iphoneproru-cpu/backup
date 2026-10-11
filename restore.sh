#!/usr/bin/env bash
# Восстановление сервера из архива backup.sh на ЧИСТОМ сервере (Ubuntu/Debian).
# Запуск:  bash restore.sh /root/server-backup-<сервер>-<время>.tgz [параметры]
#
#   --check    только показать, что будет сделано (ничего не меняет)
#   --yes      не задавать вопросов (кроме установки docker)
#   --force    продолжить, даже если на сервере уже есть контейнеры с такими именами
#              (базы с данными скрипт не перезаписывает и с --force)
#
# Порядок: файлы (/opt, сертификаты, сайт, ~/.ssh — без замены существующих ключей) → те же
# версии образов (по digest) → контейнеры compose (создаются, не запускаются) → данные valkey →
# базы PostgreSQL из дампов → запуск всего → cron → проверка доменов.
set -euo pipefail

ARCHIVE=""; CHECK_ONLY=0; YES=0; FORCE=0
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --yes) YES=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        -*) echo "Неизвестный параметр: $1" >&2; exit 1 ;;
        *) ARCHIVE="$1" ;;
    esac
    shift
done

step() { echo; echo "==> $*"; }
warn() { echo "  ! $*"; }
die() { echo; echo "ОШИБКА: $*" >&2; exit 1; }
confirm() {
    (( YES )) && return 0
    read -r -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[YyДд] ]]
}

[[ $EUID -eq 0 ]] || die "запустите от root"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "укажите архив: bash $0 /root/server-backup-….tgz"

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
echo "бот: ветка $(mf bot_branch), коммит $(mf bot_commit | cut -c1-7)"
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
Если вы уверены (например, всё остановлено и базы пустые) — запустите с --force."
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
    echo "Режим --check: ничего не изменено (архив распакован в $R — можно удалить)."
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
echo "Восстановление завершено. Распакованная копия: $R (удалите после проверки)."
echo
echo "Осталось:"
if [[ " $NEW_IPS " != *" $(mf ips | awk '{print $1}') "* ]]; then
    echo "  - DNS: IP сервера изменился ($(mf ips | awk '{print $1}') → ${NEW_IPS%% *})."
    echo "    Поменяйте A-записи доменов${DOMAINS:+ ($DOMAINS)} в Cloudflare на новый IP."
    echo "    Ноды Remnawave подключатся к панели сами, когда DNS обновится."
fi
echo "  - Откройте порты 80/443 (и 22) в файрволе, если он есть: правила старого сервера в $B/ufw.txt."
echo "  - Проверьте бота (/start), панель и сайт. Вебхук Platega менять не нужно, если домен бота тот же."

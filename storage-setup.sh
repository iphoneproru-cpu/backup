#!/usr/bin/env bash
# Сервер копий: у каждого бэкапируемого сервера свой пользователь, закрытый в своей папке (chroot,
# только SFTP), и пользователь наблюдения backup-watch, который видит только сводку — список копий
# и итог последней копии каждого сервера, но не сами архивы.
#
# Запускается на сервере копий под root:
#   bash storage-setup.sh add ИМЯ 'ПУБЛИЧНЫЙ_КЛЮЧ' [IP]   сервер: пользователь backup-ИМЯ, копии в /copies
#   bash storage-setup.sh watch 'ПУБЛИЧНЫЙ_КЛЮЧ' [IP]     наблюдатель backup-watch (RemnaDiag)
#   bash storage-setup.sh move ИМЯ /старая/папка          перенести копии server-backup-*.tgz оттуда
#   bash storage-setup.sh summary                         собрать сводку (cron делает это раз в минуту)
#   bash storage-setup.sh show                            что настроено
#
# IP — откуда разрешён вход по ключу (from=); без него — откуда угодно.
# Раскладка: /srv/backup/ИМЯ (chroot, root) / copies (пользователь, 700);
#            /srv/backup/watch/ИМЯ/{copies.txt,status.txt} — сводка, только чтение для backup-watch.
set -euo pipefail

BASE="${STORAGE_BASE:-/srv/backup}"  # STORAGE_BASE — только для проверки
KEYS=/etc/ssh/backup-keys
GROUP=sftpbackup
SSHD_CONF=/etc/ssh/sshd_config  # блок Match — в самом конце: в sshd_config.d он захватил бы следующие строки
CRON=/etc/cron.d/backup-storage
TOOL=/usr/local/sbin/backup-storage

die() { echo "ОШИБКА: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "запустите от root"

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,20}$ && "$1" != watch ]] || die "имя: латиница, цифры, -, 2–21 символ (не watch)"; }
valid_key() { [[ "$1" =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "это не публичный ключ ssh-ed25519 / ssh-rsa"; }
valid_ip() { [[ -z "$1" || "$1" =~ ^[0-9a-fA-F.:/]+$ ]] || die "IP: адрес или сеть"; }

# Общая часть: группа, sshd (chroot + только SFTP + ключи из /etc/ssh/backup-keys), сводка по cron.
base() {
    getent group "$GROUP" >/dev/null || groupadd --system "$GROUP"
    install -d -m 755 -o root -g root "$BASE" "$BASE/watch" "$KEYS"
    if ! grep -q '^# >>> backup-storage' "$SSHD_CONF"; then
        local bak="$SSHD_CONF.bak-$(date +%Y%m%d-%H%M%S)"
        cp -a "$SSHD_CONF" "$bak"
        cat >> "$SSHD_CONF" <<EOF

# >>> backup-storage (storage-setup.sh): пользователи сервера копий — только SFTP, каждый в своей папке
Match Group $GROUP
    ChrootDirectory %h
    ForceCommand internal-sftp
    AuthorizedKeysFile $KEYS/%u
    PasswordAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
# <<< backup-storage
EOF
        if ! sshd -t 2>/tmp/sshd-test.log; then
            cp -a "$bak" "$SSHD_CONF"
            die "sshd не принял настройку — вернул как было ($bak): $(cat /tmp/sshd-test.log)"
        fi
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
        echo "sshd: блок Match Group $GROUP в конце $SSHD_CONF (копия: $bak)"
    fi
    if [[ "$(realpath "$0")" != "$TOOL" ]]; then install -m 700 "$0" "$TOOL"; fi
    if [[ ! -f "$CRON" ]]; then
        echo "* * * * * root $TOOL summary >/dev/null 2>&1" > "$CRON"
        echo "cron: сводка раз в минуту ($CRON)"
    fi
}

# user ИМЯ_ПОЛЬЗОВАТЕЛЯ ДОМ — системный пользователь без shell в группе GROUP.
user() {
    if ! id "$1" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir "$2" --shell /usr/sbin/nologin -G "$GROUP" "$1"
        echo "пользователь $1 создан"
    fi
}

# key ПОЛЬЗОВАТЕЛЬ КЛЮЧ IP — ключ с ограничениями (заменяет прежний: у пользователя один ключ).
key() {
    local opts="restrict"
    [[ -z "$3" ]] || opts="from=\"$3\",restrict"
    printf '%s %s\n' "$opts" "$2" > "$KEYS/$1"
    chmod 644 "$KEYS/$1"
    echo "ключ для $1${3:+ (только с $3)}"
}

cmd_add() {
    local name="$1" pub="$2" ip="${3:-}" u="backup-$1"
    valid_name "$name"; valid_key "$pub"; valid_ip "$ip"
    base
    user "$u" "$BASE/$name"
    install -d -m 755 -o root -g root "$BASE/$name"
    install -d -m 700 -o "$u" -g "$u" "$BASE/$name/copies"
    install -d -m 750 -o root -g backup-watch "$BASE/watch/$name" 2>/dev/null \
        || install -d -m 750 -o root -g root "$BASE/watch/$name"
    key "$u" "$pub" "$ip"
    echo "готово: $u → $BASE/$name/copies (в backup.conf: REMOTE_USER=$u REMOTE_DIR=copies)"
}

cmd_watch() {
    local pub="$1" ip="${2:-}" d
    valid_key "$pub"; valid_ip "$ip"
    base
    user backup-watch "$BASE/watch"
    for d in "$BASE"/watch/*/; do [[ -d "$d" ]] && chgrp backup-watch "$d" && chmod 750 "$d"; done
    key backup-watch "$pub" "$ip"
    cmd_summary
    echo "готово: backup-watch видит только $BASE/watch (сводку), архивы — нет"
}

cmd_move() {
    local name="$1" from="$2" u="backup-$1" n=0 f
    valid_name "$name"
    [[ -d "$BASE/$name/copies" ]] || die "сначала: add $name"
    [[ -d "$from" ]] || die "нет папки $from"
    for f in "$from"/server-backup-*.tgz "$from"/status-*.txt; do
        [[ -f "$f" ]] || continue
        mv -n "$f" "$BASE/$name/copies/" && n=$((n + 1))
    done
    chown -R "$u:$u" "$BASE/$name/copies"
    chmod 600 "$BASE/$name/copies"/* 2>/dev/null || true
    echo "перенесено файлов: $n ($from → $BASE/$name/copies)"
    cmd_summary
}

# Сводка для наблюдателя: список копий (имя|размер|время) и итог последней копии от самого сервера.
cmd_summary() {
    local dir name out st
    for dir in "$BASE"/*/copies; do
        [[ -d "$dir" ]] || continue
        name="$(basename "$(dirname "$dir")")"
        out="$BASE/watch/$name"
        [[ -d "$out" ]] || install -d -m 750 -o root -g "$(getent group backup-watch >/dev/null && echo backup-watch || echo root)" "$out"
        find "$dir" -maxdepth 1 -type f -name 'server-backup-*.tgz' -printf '%f|%s|%T@\n' | sort > "$out/.copies.tmp"
        df -B1 --output=size,avail "$dir" | tail -1 | awk '{print "disk|" $1 "|" $2}' >> "$out/.copies.tmp"
        mv "$out/.copies.tmp" "$out/copies.txt"
        st="$(ls -t "$dir"/status-*.txt 2>/dev/null | head -1 || true)"
        if [[ -n "$st" ]]; then
            # только строки key=value из известных ключей — ничего лишнего наблюдателю
            grep -E '^(status|host|at|started|archive|size|uploaded|local_count|failed_at|code|error|warnings)=' "$st" \
                | cut -c1-600 > "$out/.status.tmp" || true
            mv "$out/.status.tmp" "$out/status.txt"
        else
            rm -f "$out/status.txt"
        fi
        chmod 640 "$out"/*.txt
        chgrp "$(getent group backup-watch >/dev/null && echo backup-watch || echo root)" "$out"/*.txt
    done
}

cmd_show() {
    local d
    echo "пользователи: $(getent group "$GROUP" | cut -d: -f4)"
    for d in "$BASE"/*/copies; do
        [[ -d "$d" ]] || continue
        printf '  %-12s %s копий, %s\n' "$(basename "$(dirname "$d")")" "$(find "$d" -maxdepth 1 -name '*.tgz' | wc -l)" "$(du -sh "$d" | cut -f1)"
    done
    for f in "$KEYS"/*; do [[ -f "$f" ]] && echo "  ключ $(basename "$f"): $(cut -d' ' -f1 "$f")"; done
}

case "${1:-}" in
    add) (( $# >= 3 )) || die "add ИМЯ 'КЛЮЧ' [IP]"; cmd_add "$2" "$3" "${4:-}" ;;
    watch) (( $# >= 2 )) || die "watch 'КЛЮЧ' [IP]"; cmd_watch "$2" "${3:-}" ;;
    move) (( $# == 3 )) || die "move ИМЯ /папка"; cmd_move "$2" "$3" ;;
    summary) cmd_summary ;;
    show) cmd_show ;;
    *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1 ;;
esac

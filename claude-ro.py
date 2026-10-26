#!/usr/bin/env python3
"""Доступ «только чтение» для ключа диагностики (Claude / RemnaDiag) на боевом сервере.

В /root/.ssh/authorized_keys ключ записан так:
  from="57.131.199.121",restrict,command="/usr/local/sbin/claude-ro" ssh-ed25519 AAAA… remnadiag-migration
Что бы ни прислали по SSH, sshd запускает эту программу, а присланная команда лежит в SSH_ORIGINAL_COMMAND.
Команда разбирается без оболочки (; | && $() > — просто текст) и выполняется, только если она из белого списка
команд, которые ничего не меняют. Каждый вызов — в журнал /var/log/claude-ro.log.

Запросы к базам — только в транзакции «только чтение»:  sql КОНТЕЙНЕР ПОЛЬЗОВАТЕЛЬ БАЗА 'SELECT …'
Проверка без выполнения:  CLAUDE_RO_DRY=1 SSH_ORIGINAL_COMMAND='…' claude-ro
"""
import datetime
import os
import re
import shlex
import sys

LOG = os.environ.get("CLAUDE_RO_LOG", "/var/log/claude-ro.log")

# Команды, которые только читают, с любыми аргументами, кроме перечисленных опасных.
FREE = {
    "ls", "cat", "head", "tail", "wc", "stat", "du", "df", "free", "uptime", "uname", "hostname", "id", "whoami",
    "date", "ps", "ss", "grep", "zgrep", "egrep", "sha256sum", "md5sum", "readlink", "realpath", "file", "last",
    "lastb", "who", "w", "getent", "dig", "nslookup", "lsblk", "findmnt", "nproc", "lscpu", "lsof", "pgrep",
    "zcat", "sshd", "iptables-save", "ip6tables-save",
}
DENY_ARGS = {
    "find": {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"},
    "ss": {"-K", "--kill"},
    "date": {"-s", "--set"},
    "file": {"-C", "--compile"},
    "iptables-save": {"-f", "--file"},
    "ip6tables-save": {"-f", "--file"},
}
IP_WRITE = {"add", "del", "delete", "change", "replace", "set", "flush", "append", "prepend", "save", "restore", "exec", "netns", "monitor"}
SQL_DENY = re.compile(r";|\b(pg_terminate_backend|pg_cancel_backend|pg_reload_conf|pg_rotate_logfile|lo_export|lo_import|lo_unlink|"
                      r"set_config|dblink\w*|pg_promote|pg_switch_wal|pg_create_restore_point|pg_drop_replication_slot|"
                      r"pg_create_\w*slot|nextval|setval|pg_file_write|pg_advisory\w*|pg_sleep\w*)\b", re.I)
# Команды, где разрешены лишь некоторые подкоманды (первый аргумент, не начинающийся с -).
SUB = {
    "systemctl": {"status", "is-active", "is-enabled", "is-failed", "list-units", "list-timers", "list-unit-files", "show", "cat"},
    "docker": {"ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port", "diff", "history"},
    "git": {"log", "status", "diff", "show", "rev-parse", "branch", "remote", "describe", "ls-files", "blame"},
    "ufw": {"status"},
    "fail2ban-client": {"status", "get", "ping", "version"},
    "crontab": {"-l"},
    "dpkg": {"-l", "--list", "-L", "--listfiles", "-S", "--search", "--verify", "-V", "-s", "--status", "--print-architecture"},
    "apt": {"list", "policy", "show"},
    "apt-cache": {"policy", "show", "search", "depends", "rdepends"},
    "ip": {"a", "addr", "address", "r", "route", "l", "link", "n", "neigh", "rule", "-br", "-4", "-6", "-s"},
    "journalctl": None,  # любые, кроме изменяющих (ниже)
    "find": None,
    "docker-compose-ps": None,
}
DOCKER_SUB2 = {"compose": {"ls", "ps", "config", "images", "top", "version"},
               "network": {"ls", "inspect"}, "volume": {"ls", "inspect"}, "system": {"df", "info"},
               "container": {"ls", "inspect", "logs", "top", "port", "diff", "stats"}, "image": {"ls", "inspect", "history"}}
JOURNAL_DENY = ("--vacuum", "--rotate", "--flush", "--sync", "--relinquish", "--smart-relinquish", "--setup-keys", "--update-catalog",
                "--cursor-file")
STATS_NEED = "--no-stream"
SQL_RE = re.compile(r"^\s*(select|with|show|explain|table|values)\b", re.I | re.S)
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


def log(status, cmd):
    try:
        with open(LOG, "a") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {os.environ.get('SSH_CLIENT', '-').split(' ')[0]} {status} {cmd}\n")
    except OSError:
        pass


def deny(cmd, why):
    log("DENY", cmd)
    sys.stderr.write(f"claude-ro: запрещено ({why}). Ключ только для чтения.\n")
    sys.exit(126)


def check(argv):
    """Возвращает argv для запуска или текст причины отказа."""
    if not argv:
        return "нужна команда: интерактивного входа нет"
    prog = os.path.basename(argv[0])
    args = argv[1:]
    if "/" in argv[0] and argv[0] not in (f"/usr/bin/{prog}", f"/bin/{prog}", f"/usr/sbin/{prog}", f"/sbin/{prog}"):
        return f"путь {argv[0]}"

    if prog == "sql":  # sql КОНТЕЙНЕР ПОЛЬЗОВАТЕЛЬ БАЗА 'SELECT …'
        if len(args) != 4 or not all(NAME_RE.match(a) for a in args[:3]) or not SQL_RE.match(args[3]):
            return "sql КОНТЕЙНЕР ПОЛЬЗОВАТЕЛЬ БАЗА 'SELECT …'"
        if SQL_DENY.search(args[3]):
            return "sql: один запрос на чтение, без ; и функций с побочным действием"
        c, user, db, q = args
        # default_transaction_read_only: любая запись в этой сессии — ошибка PostgreSQL
        return ["docker", "exec", "-e", "PGOPTIONS=-c default_transaction_read_only=on", c,
                "psql", "-U", user, "-d", db, "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", q]
    if prog == "backup-plan":  # что попадёт в копию (ничего не делает)
        return ["bash", "/opt/server-backup/backup.sh", "--plan"] if not args else "без аргументов"
    if prog == "backup-check-remote":
        return ["bash", "/opt/server-backup/backup.sh", "--check-remote"] if not args else "без аргументов"

    if prog in FREE:
        bad = DENY_ARGS.get(prog, set()) & set(args)
        if bad:
            return f"{prog} {' '.join(sorted(bad))}"
        if prog == "sshd" and args not in (["-T"], ["-t"]):
            return "sshd: только -T или -t"
        if prog == "hostname" and any(not a.startswith("-") or a in ("-F", "--file", "-b", "--boot") for a in args):
            return "hostname: только просмотр"
        if prog == "date" and any(a.startswith("--set") for a in args):
            return "date: только просмотр"
        return argv
    if prog == "find":
        bad = DENY_ARGS["find"] & set(args)
        return f"find {' '.join(sorted(bad))}" if bad else argv
    if prog == "journalctl":
        if any(a.startswith(JOURNAL_DENY) for a in args):
            return "journalctl: только чтение"
        return argv
    if prog in SUB:
        allowed = SUB[prog]
        words = [a for a in args if not a.startswith("-")] if prog not in ("crontab", "dpkg", "ip") else args
        if prog == "crontab":
            return argv if args == ["-l"] else "crontab: только -l"
        if prog == "dpkg":
            ok = args[:1] and args[0] in allowed and not any(a.startswith("-") for a in args[1:])
            return argv if ok else "dpkg: только просмотр (-l, -L, -S, -s, --verify)"
        if prog == "ip":
            return "ip: только просмотр" if IP_WRITE & set(args) else argv
        if prog == "git":  # git -C ПАПКА подкоманда …
            rest = list(args)
            while rest[:1] == ["-C"] and len(rest) >= 2:
                rest = rest[2:]
            if rest[:1] and rest[0].startswith("-"):
                return "git: перед подкомандой — только -C ПАПКА"
            if any(a.startswith(("--output", "--ext-diff", "--exec")) for a in rest):
                return "git: без --output / --ext-diff"
            words = rest
        if not words:
            return f"{prog}: нужна подкоманда"
        sub = words[0]
        if prog == "docker" and sub in DOCKER_SUB2:
            rest = args[args.index(sub) + 1:]
            while rest[:1] and rest[0] in ("-f", "--file", "-p", "--project-name", "--project-directory", "--env-file") and len(rest) >= 2:
                rest = rest[2:]  # docker compose -f ФАЙЛ ps
            if not rest or rest[0] not in DOCKER_SUB2[sub]:
                return f"docker {sub}: только {', '.join(sorted(DOCKER_SUB2[sub]))}"
            return argv
        if sub not in allowed:
            return f"{prog} {sub}: только {', '.join(sorted(allowed))}"
        if prog == "docker" and sub == "stats" and STATS_NEED not in args:
            return "docker stats: только с --no-stream"
        if prog == "docker" and sub == "logs" and ("-f" in args or "--follow" in args):
            return "docker logs: без -f"
        if prog == "git" and sub == "branch" and any(a in ("-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--set-upstream-to", "-u") for a in words[1:]):
            return "git branch: только просмотр"
        if prog == "git" and sub == "remote" and len(words) > 1 and words[1] not in ("-v", "show", "get-url"):
            return "git remote: только просмотр"
        return argv
    return f"команда {prog} не в списке чтения"


def main():
    cmd = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    try:
        argv = shlex.split(cmd)
    except ValueError as e:
        deny(cmd, f"не разобрать: {e}")
    res = check(argv)
    if isinstance(res, str):
        deny(cmd, res)
    log("OK", cmd)
    if os.environ.get("CLAUDE_RO_DRY"):
        print("OK", shlex.join(res))
        return
    os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    try:
        os.execvp(res[0], res)
    except OSError as e:
        sys.stderr.write(f"claude-ro: {res[0]}: {e}\n")
        sys.exit(127)


if __name__ == "__main__":
    main()

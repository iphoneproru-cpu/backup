#!/usr/bin/env python3
"""Доступ для правок бота магазина и сайта (Claude) на боевом сервере. Remnawave этим ключом не трогается.

В /root/.ssh/authorized_keys ключ записан так (ставит claude-shop-install.sh):
  from="57.131.199.121",restrict,command="/usr/local/sbin/claude-shop" ssh-ed25519 AAAA… claude-shop
Что бы ни прислали по SSH, sshd запускает эту программу, а присланная команда лежит в SSH_ORIGINAL_COMMAND.
Команда разбирается без оболочки (; | && $() > — просто текст) и выполняется, только если она из списка ниже.
Каждый вызов — в журнал /var/log/claude-shop.log.

  git …                     git в /opt/remnashop-src: status, log, diff, show, branch, rev-parse, fetch,
                            pull (только перемотка), checkout ВЕТКА | checkout -B ВЕТКА origin/ВЕТКА, reset --hard REF
  shop ps                   контейнеры бота
  shop build                собрать образ бота из /opt/remnashop-src
  shop up                   пересоздать remnashop, remnashop-taskiq-worker, remnashop-taskiq-scheduler (без БД и redis)
  shop restart [СЕРВИС…]    перезапустить их (все три или названные)
  shop logs СЕРВИС [N]      последние N строк лога (по умолчанию 200, не больше 5000)
  site ls                   файлы сайта /var/www/my.chebur.xyz
  site get ФАЙЛ             содержимое файла
  site put ФАЙЛ             записать файл из stdin (до 10 МБ); старый — в резервную копию
  site rm ФАЙЛ              удалить файл; старый — в резервную копию
  site backups              список резервных копий
  site rollback КОПИЯ       вернуть файлы из резервной копии

Проверка без выполнения:  CLAUDE_SHOP_DRY=1 SSH_ORIGINAL_COMMAND='…' claude-shop
"""
import datetime
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

# Пути можно подменить только при запуске не через SSH (для проверки на другой машине).
_local = "SSH_CONNECTION" not in os.environ
SRC = os.environ.get("CLAUDE_SHOP_SRC", "/opt/remnashop-src") if _local else "/opt/remnashop-src"
COMPOSE_DIR = os.environ.get("CLAUDE_SHOP_COMPOSE", "/opt/remnashop") if _local else "/opt/remnashop"
SITE = os.environ.get("CLAUDE_SHOP_SITE", "/var/www/my.chebur.xyz") if _local else "/var/www/my.chebur.xyz"
BACKUPS = os.environ.get("CLAUDE_SHOP_BACKUPS", "/var/backups/site-my.chebur.xyz") if _local else "/var/backups/site-my.chebur.xyz"
LOG = os.environ.get("CLAUDE_SHOP_LOG", "/var/log/claude-shop.log") if _local else "/var/log/claude-shop.log"
DRY = os.environ.get("CLAUDE_SHOP_DRY") == "1"

APP = ["remnashop", "remnashop-taskiq-worker", "remnashop-taskiq-scheduler"]
MAX_PUT = 10 * 1024 * 1024
REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/~^@{}-]*$")
RANGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/~^-]*(\.\.\.?[A-Za-z0-9][A-Za-z0-9._/~^-]*)?$")
BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
SITE_PATH = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*){0,5}$")
STAMP = re.compile(r"^\d{8}-\d{6}(-\d+)?$")


def log(status, cmd):
    try:
        who = os.environ.get("SSH_CLIENT", "local").split(" ")[0]
        with open(LOG, "a") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {who} {status} {cmd}\n")
    except OSError:
        pass


def deny(cmd, why):
    log("DENY", cmd)
    print(f"claude-shop: запрещено ({why}).", file=sys.stderr)
    sys.exit(126)


def run(argv, cwd):
    if DRY:
        print("DRY:", f"(cd {cwd})", " ".join(shlex.quote(a) for a in argv))
        return 0
    return subprocess.call(argv, cwd=cwd)


# git: only in the bot's source folder, with flags from a short list per subcommand.
GIT_FLAGS = {
    "status": {"-s", "-b", "-sb", "--short", "--branch", "--porcelain"},
    "log": {"--oneline", "--stat", "--graph", "--decorate", "--all", "-p", "--name-only", "--name-status", "--no-merges"},
    "diff": {"--stat", "--name-only", "--name-status", "-p", "--cached"},
    "show": {"--stat", "--name-only", "--name-status", "-p", "--oneline"},
    "branch": {"-a", "-v", "-vv", "--show-current", "-r"},
    "rev-parse": {"--abbrev-ref", "--short", "HEAD"},
    "fetch": {"--prune"},
}


def git_argv(cmd, args):
    if not args:
        deny(cmd, "git без подкоманды")
    sub, rest = args[0], args[1:]
    if sub in GIT_FLAGS:
        paths = False
        for a in rest:
            if a == "--" and sub in ("diff", "show", "log"):
                paths = True
            elif paths:
                if not SITE_PATH.match(a) or ".." in a:
                    deny(cmd, f"путь {a!r}")
            elif a in GIT_FLAGS[sub] or (sub == "log" and re.fullmatch(r"-\d{1,4}", a)):
                pass
            elif a.startswith("-"):
                deny(cmd, f"git {sub}: флаг {a!r} не разрешён")
            elif sub == "fetch":
                if a != "origin" and not BRANCH.match(a):
                    deny(cmd, f"git fetch {a!r}")
            elif sub == "branch":
                deny(cmd, "git branch: только просмотр")
            elif not RANGE.match(a) and not REF.match(a):
                deny(cmd, f"ссылка {a!r}")
        return ["git", "-C", SRC, sub, *rest]
    if sub == "pull":
        if rest and not (len(rest) == 2 and rest[0] == "origin" and BRANCH.match(rest[1])):
            deny(cmd, "git pull: можно без аргументов или origin ВЕТКА")
        return ["git", "-C", SRC, "pull", "--ff-only", *rest]
    if sub == "checkout":
        if len(rest) == 1 and BRANCH.match(rest[0]):
            return ["git", "-C", SRC, "checkout", rest[0]]
        if len(rest) == 3 and rest[0] in ("-B", "-b") and BRANCH.match(rest[1]) and rest[2] == f"origin/{rest[1]}":
            return ["git", "-C", SRC, "checkout", *rest]
        deny(cmd, "git checkout: ВЕТКА или -B ВЕТКА origin/ВЕТКА")
    if sub == "reset":
        if len(rest) == 2 and rest[0] == "--hard" and REF.match(rest[1]):
            return ["git", "-C", SRC, "reset", "--hard", rest[1]]
        deny(cmd, "git reset: только --hard REF")
    deny(cmd, f"git {sub} не разрешён")


def shop_argv(cmd, args):
    dc = ["docker", "compose"]
    if args == ["ps"]:
        return dc + ["ps"]
    if args == ["build"]:
        return dc + ["build", "remnashop"]
    if args == ["up"]:
        return dc + ["up", "-d", "--no-deps", *APP]
    if args and args[0] == "restart":
        svc = args[1:] or APP
        if any(s not in APP for s in svc):
            deny(cmd, "перезапуск только " + ", ".join(APP))
        return dc + ["restart", *svc]
    if args and args[0] == "logs" and len(args) in (2, 3) and args[1] in APP + ["remnashop-db", "remnashop-redis"]:
        n = args[2] if len(args) == 3 else "200"
        if not n.isdigit() or not 0 < int(n) <= 5000:
            deny(cmd, "число строк 1–5000")
        return dc + ["logs", "--no-color", "--tail", n, args[1]]
    deny(cmd, "shop: ps | build | up | restart [сервис…] | logs сервис [N]")


def site_file(cmd, rel):
    if not SITE_PATH.match(rel) or ".." in rel.split("/"):
        deny(cmd, f"имя файла {rel!r}")
    path = os.path.join(SITE, rel)
    root = os.path.realpath(SITE)
    # No symlinks anywhere on the way: the file must really be inside the site folder.
    probe = root
    for part in rel.split("/"):
        probe = os.path.join(probe, part)
        if os.path.islink(probe):
            deny(cmd, f"{rel} — ссылка")
    if os.path.commonpath([root, os.path.realpath(path)]) != root:
        deny(cmd, f"{rel} вне папки сайта")
    return path


def backup_dir():
    # A new folder each time: two calls within a second (a put and a rollback) must not share one.
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    base = os.path.join(BACKUPS, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    d, n = base, 1
    while True:
        try:
            os.mkdir(d, 0o700)
            return d
        except FileExistsError:
            n += 1
            d = f"{base}-{n}"


def site(cmd, args):
    if args == ["ls"]:
        for base, dirs, files in os.walk(SITE):
            dirs.sort()
            for f in sorted(files):
                p = os.path.join(base, f)
                st = os.lstat(p)
                print(f"{st.st_size:>10}  {datetime.datetime.fromtimestamp(st.st_mtime):%Y-%m-%d %H:%M}  {os.path.relpath(p, SITE)}")
        return 0
    if args == ["backups"]:
        if os.path.isdir(BACKUPS):
            for d in sorted(os.listdir(BACKUPS)):
                files = [os.path.relpath(os.path.join(b, f), os.path.join(BACKUPS, d))
                         for b, _, fs in os.walk(os.path.join(BACKUPS, d)) for f in fs]
                print(d, " ".join(sorted(files)))
        return 0
    if len(args) == 2 and args[0] == "get":
        path = site_file(cmd, args[1])
        with open(path, "rb") as f:
            shutil.copyfileobj(f, sys.stdout.buffer)
        return 0
    if len(args) == 2 and args[0] in ("put", "rm"):
        path = site_file(cmd, args[1])
        data = sys.stdin.buffer.read(MAX_PUT + 1) if args[0] == "put" else b""
        if len(data) > MAX_PUT:
            deny(cmd, "файл больше 10 МБ")
        if DRY:
            print(f"DRY: {args[0]} {path} ({len(data)} байт)")
            return 0
        if os.path.exists(path):
            keep = os.path.join(backup_dir(), args[1])
            os.makedirs(os.path.dirname(keep), exist_ok=True)
            shutil.copy2(path, keep)
            print(f"резервная копия: {os.path.relpath(keep, BACKUPS)}")
        if args[0] == "rm":
            if os.path.exists(path):
                os.remove(path)
            return 0
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".claude-shop-")
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
        print(f"записано: {args[1]} ({len(data)} байт)")
        return 0
    if len(args) == 2 and args[0] == "rollback" and STAMP.match(args[1]):
        src = os.path.join(BACKUPS, args[1])
        if not os.path.isdir(src):
            deny(cmd, "нет такой копии")
        files = [os.path.relpath(os.path.join(b, f), src) for b, _, fs in os.walk(src) for f in fs]
        if DRY:
            print("DRY: rollback", " ".join(files))
            return 0
        keep = backup_dir()  # the current versions, so a rollback can be undone too
        for rel in files:
            path = site_file(cmd, rel)
            if os.path.exists(path):
                os.makedirs(os.path.dirname(os.path.join(keep, rel)), exist_ok=True)
                shutil.copy2(path, os.path.join(keep, rel))
            os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
            shutil.copy2(os.path.join(src, rel), path)
            print(f"возвращено: {rel}")
        print(f"прежние версии: {os.path.basename(keep)}")
        return 0
    deny(cmd, "site: ls | get ФАЙЛ | put ФАЙЛ | rm ФАЙЛ | backups | rollback КОПИЯ")


def main():
    cmd = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    try:
        argv = shlex.split(cmd)
    except ValueError:
        deny(cmd, "не разобрать команду")
    if not argv:
        deny(cmd, "пустая команда; список — в начале /usr/local/sbin/claude-shop")
    head, args = argv[0], argv[1:]
    if head == "git":
        a = git_argv(cmd, args)
        log("OK", cmd)
        return run(a, SRC)
    if head == "shop":
        a = shop_argv(cmd, args)
        log("OK", cmd)
        return run(a, COMPOSE_DIR)
    if head == "site":
        log("OK", cmd)
        return site(cmd, args)
    deny(cmd, f"команда {head} не разрешена; можно git, shop, site")


if __name__ == "__main__":
    sys.exit(main())

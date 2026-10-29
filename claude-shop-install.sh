#!/bin/bash
# Ставит ключ Claude для правок бота магазина и сайта (см. claude-shop.py) на этот сервер.
#   bash claude-shop-install.sh            — поставить или обновить
#   bash claude-shop-install.sh --remove   — убрать ключ (программа остаётся, без ключа она не вызывается)
set -euo pipefail
cd "$(dirname "$0")"

KEYS=/root/.ssh/authorized_keys
LINE='from="57.131.199.121",restrict,command="/usr/local/sbin/claude-shop" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICRjvAtQWTl51lHiF8sXoFBwgv29LNMUJ4f1FdsWj7d3 claude-shop'
PUB=AAAAC3NzaC1lZDI1NTE5AAAAICRjvAtQWTl51lHiF8sXoFBwgv29LNMUJ4f1FdsWj7d3

[ "$(id -u)" = 0 ] || { echo "запустите под root"; exit 1; }
cp -p "$KEYS" "$KEYS.bak-$(date +%Y%m%d-%H%M%S)-shop"

if [ "${1:-}" = "--remove" ]; then
  grep -vF "$PUB" "$KEYS" > "$KEYS.tmp" || true
  cat "$KEYS.tmp" > "$KEYS"; rm -f "$KEYS.tmp"
  echo "ключ claude-shop убран"
  exit 0
fi

install -m 755 -o root -g root claude-shop.py /usr/local/sbin/claude-shop
touch /var/log/claude-shop.log; chmod 600 /var/log/claude-shop.log

# The key goes in with exactly these restrictions: a stale line is replaced.
grep -vF "$PUB" "$KEYS" > "$KEYS.tmp" || true
echo "$LINE" >> "$KEYS.tmp"
cat "$KEYS.tmp" > "$KEYS"; rm -f "$KEYS.tmp"

# Self-check: allowed commands pass, the rest are refused.
ok=1
for c in "shop ps" "git status" "site ls"; do
  CLAUDE_SHOP_DRY=1 SSH_ORIGINAL_COMMAND="$c" /usr/local/sbin/claude-shop >/dev/null 2>&1 || { echo "не проходит: $c"; ok=0; }
done
for c in "docker ps" "bash" "shop restart remnawave" "site put ../x" "git config core.pager sh"; do
  if CLAUDE_SHOP_DRY=1 SSH_ORIGINAL_COMMAND="$c" /usr/local/sbin/claude-shop >/dev/null 2>&1; then echo "пропущено лишнее: $c"; ok=0; fi
done
[ "$ok" = 1 ] && echo "ключ claude-shop установлен, проверка пройдена" || { echo "проверка не пройдена"; exit 1; }

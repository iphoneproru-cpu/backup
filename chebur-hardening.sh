#!/usr/bin/env bash
# Chebur после переезда (аудит 27.10): то, что было на старом проде и не перенеслось, и обновления.
#
#   1. fail2ban — бан адресов, которые подбирают вход по SSH (5 неудач за 10 минут — час бана)
#   2. SSH — закрыть лишнее: вход только по ключу, без X11 и туннелей, 3 попытки ключа
#   3. Ротация логов у remnawave-nginx и remnawave-subscription-page (у остальных контейнеров она уже есть)
#   4. Обновления системы; перезагрузка — по вашему ответу в конце
#
# Копии всех изменённых файлов — в /root/hardening-ДАТА. Ничего не удаляется. Запуск: bash chebur-hardening.sh
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BAK="/root/hardening-$TS"
REMNADIAG_IP="57.131.199.121"   # RemnaDiag: проверки и ключ Claude (только чтение) — не банить

say()  { echo; echo "==> $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
die()  { echo; echo "ОШИБКА: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запустите от root"
[[ "$(hostname)" == "vps-c2f922e0" ]] || {
  read -r -p "Это не Chebur (vps-c2f922e0), а $(hostname). Всё равно продолжить? [y/N] " a
  [[ "$a" =~ ^[YyДд] ]] || exit 1
}
mkdir -p "$BAK"
chmod 700 "$BAK"
echo "Копии изменённых файлов: $BAK"

# ---------------------------------------------------------------- 1. fail2ban
say "1/4 fail2ban"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
[[ -f /etc/fail2ban/jail.local ]] && cp -a /etc/fail2ban/jail.local "$BAK/"
cat > /etc/fail2ban/jail.local <<EOF
# Chebur (chebur-hardening.sh $TS)
[DEFAULT]
# не банить: этот сервер и RemnaDiag; свой постоянный адрес можно дописать через пробел
ignoreip = 127.0.0.1/8 ::1 $REMNADIAG_IP
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 3
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "fail2ban работает: $(fail2ban-client status sshd | grep -E 'Currently banned' | xargs)"
else
  warn "fail2ban не поднялся: journalctl -u fail2ban -n 30"
fi

# ---------------------------------------------------------------- 2. SSH
say "2/4 SSH"
HARD=/etc/ssh/sshd_config.d/00-hardening.conf
[[ -f "$HARD" ]] && cp -a "$HARD" "$BAK/"
cat > "$HARD" <<EOF
# Chebur (chebur-hardening.sh $TS). Файл читается первым — его значения главнее остальных
# (в 60-cloudimg-settings.conf стоит PasswordAuthentication yes).
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 5
EOF
chmod 644 "$HARD"
if ! sshd -t 2>"$BAK/sshd-test.txt"; then
  mv "$HARD" "$BAK/00-hardening.conf.rejected"
  die "sshd не принял настройки (файл убран, SSH не трогали): $(cat "$BAK/sshd-test.txt")"
fi
systemctl reload ssh
ok "SSH: только ключ, без X11 и туннелей, 3 попытки ключа"
echo "  Текущее окно НЕ закрывайте: откройте второе и войдите заново (ssh root@162.19.250.189)."
echo "  Если вход не получится — в этом окне: rm $HARD && systemctl reload ssh"

# ---------------------------------------------------------------- 3. Ротация логов
say "3/4 Ротация логов nginx и страницы подписки (100 МБ × 5, как у остальных контейнеров)"
for item in "/opt/remnawave/nginx:remnawave-nginx" "/opt/remnawave/subscription:remnawave-subscription-page"; do
  dir="${item%%:*}"; svc="${item##*:}"
  [[ -f "$dir/docker-compose.yml" ]] || { warn "$dir/docker-compose.yml нет — пропускаю $svc"; continue; }
  [[ -f "$dir/docker-compose.override.yml" ]] && cp -a "$dir/docker-compose.override.yml" "$BAK/$svc.override.yml"
  cat > "$dir/docker-compose.override.yml" <<EOF
# Chebur (chebur-hardening.sh $TS): ротация логов — compose подхватывает этот файл сам
services:
  $svc:
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"
EOF
  # пересоздать только этот контейнер (новые настройки логов); образ — тот же, без скачивания
  (cd "$dir" && docker compose up -d --no-build --pull never "$svc" >/dev/null 2>&1) || warn "$svc: не пересоздался — cd $dir && docker compose up -d $svc"
  sleep 2
  ok "$svc: $(docker inspect -f '{{.State.Status}}, логи {{.HostConfig.LogConfig.Config}}' "$svc")"
done
curl -sk -o /dev/null -m 10 -w "  сайт my.chebur.xyz → %{http_code}\n" --resolve my.chebur.xyz:443:127.0.0.1 https://my.chebur.xyz/ || true

# ---------------------------------------------------------------- 4. Обновления
say "4/4 Обновления системы (несколько минут)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get -y -qq \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y -qq autoremove --purge >/dev/null
ok "обновлено; осталось обновлений: $(apt list --upgradable 2>/dev/null | grep -c upgradable || true)"
docker ps --format '{{.Names}} {{.Status}}' | sed 's/^/  /'

# ---------------------------------------------------------------- итог
say "Готово. Копии: $BAK"
echo "  Проверьте вход по SSH во втором окне, прежде чем закрывать это."
echo "  Разбанить адрес: fail2ban-client set sshd unbanip АДРЕС"
if [[ -f /var/run/reboot-required ]]; then
  echo
  echo "  Нужна перезагрузка (новое ядро). Сайт, бот, панель и обновление подписок будут недоступны ~1–2 минуты,"
  echo "  VPN у клиентов работает. Контейнеры поднимутся сами."
  read -r -p "  Перезагрузить сейчас? [y/N] " a
  if [[ "$a" =~ ^[YyДд] ]]; then
    echo "  Перезагружаю…"
    systemctl reboot
  else
    echo "  Позже: reboot"
  fi
fi

#!/usr/bin/env bash
# HUBProxy — прокси Telegram, который снаружи выглядит обычным сайтом.
#
# Как это работает:
#
#   Caddy :443 (TLS) ──► TProxy :8080 ──┬── браузер  → страница «технические работы»
#                                       └── Telegram → MTProxy :2398 (только localhost)
#
# Провайдер видит одно и то же — HTTPS-запросы к веб-серверу на 443. TProxy сам
# решает, кто пришёл: человек с браузером или клиент Telegram.
#
# Схема повторяет sacoq/web-proxy-tg-installer (MIT). Реализация здесь своя:
# проверки до установки, повторный запуск без поломок, снос одной командой и
# проверка результата по факту.
#
#   Установка: bash <(curl -sL .../install.sh) proxy.example.com
#   Удаление:  bash <(curl -sL .../install.sh) --uninstall
set -Eeuo pipefail

STATE=/etc/hubproxy
INFO="$STATE/connection.txt"
SITE=/var/lib/hubproxy/site
MTPROXY_PORT=2398
TPROXY_PORT=8080
TPROXY_ADMIN=8081
GO_VER=1.23.4

c_ok=$'\e[0;32m'; c_err=$'\e[1;31m'; c_warn=$'\e[1;33m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
step() { printf '\n%s—— %s%s\n' "$c_dim" "$*" "$c_off"; }
trap 'die "оборвалось на строке $LINENO — запустите заново, повтор безопасен"' ERR

uninstall() {
  step "Удаляю HUBProxy"
  systemctl disable --now hubproxy-mtproto hubproxy-tproxy 2>/dev/null || true
  rm -f /etc/systemd/system/hubproxy-*.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$STATE" /var/lib/hubproxy /opt/hubproxy /usr/local/bin/hubproxy-tproxy
  ok "Службы остановлены, файлы удалены"
  say "Caddy и его сертификаты не тронуты (могут быть нужны другим сайтам)."
  exit 0
}
[[ "${1:-}" == "--uninstall" ]] && uninstall

DOMAIN="${1:-}"
[[ -z "$DOMAIN" ]] && die "Укажите домен: bash install.sh proxy.example.com"
[[ $EUID -eq 0 ]] || die "Нужен root: sudo bash install.sh $DOMAIN"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || die "«$DOMAIN» не похож на домен"

# ─── проверки до установки ──────────────────────────────────────────────
# Смысл: не начинать работу, которая заведомо не закончится. Две самые частые
# причины «оно не поставилось» — домен смотрит не сюда и занятый 443.
step "Проверяю условия"
export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null || { apt-get update -qq; apt-get install -y -qq curl >/dev/null; }
command -v dig  >/dev/null || apt-get install -y -qq dnsutils >/dev/null 2>&1 || true

MY_IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
DNS_IP=$(dig +short A "$DOMAIN" 2>/dev/null | tail -1)
[[ -z "$DNS_IP" ]] && die "У $DOMAIN нет A-записи. Направьте её на${MY_IP:+ $MY_IP} и подождите пару минут."
if [[ -n "$MY_IP" && "$DNS_IP" != "$MY_IP" ]]; then
  die "$DOMAIN ведёт на $DNS_IP, а сервер — $MY_IP. Let's Encrypt не выдаст сертификат.
    Если домен за прокси (Cloudflare), временно отключите проксирование."
fi
ok "Домен смотрит на этот сервер"

if ss -ltn 2>/dev/null | grep -qE ':443\s'; then
  holder=$(ss -ltnp 2>/dev/null | grep ':443 ' | grep -oE '"[^"]+"' | head -1 | tr -d '"')
  [[ "$holder" == "caddy" ]] || die "Порт 443 занят процессом «${holder:-неизвестно}» — освободите его"
fi
ok "Порт 443 свободен"

ROTATE=0
if [[ -f "$INFO" ]]; then
  if [[ "${2:-}" == "--rotate" ]]; then
    ROTATE=1; warn "Перевыпускаю секрет — старая ссылка перестанет работать"
  else
    warn "HUBProxy уже установлен:"; cat "$INFO"
    say ""; say "Сменить секрет: bash install.sh $DOMAIN --rotate"
    say "Удалить:        bash install.sh --uninstall"
    exit 0
  fi
fi

# ─── зависимости ────────────────────────────────────────────────────────
step "Ставлю пакеты"
apt-get update -qq
apt-get install -y -qq ca-certificates gnupg git build-essential libssl-dev zlib1g-dev xxd >/dev/null
ok "Зависимости на месте"

step "Ставлю Caddy"
if ! command -v caddy >/dev/null; then
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi
ok "Caddy $(caddy version 2>/dev/null | head -1 | awk '{print $1}')"

step "Собираю MTProxy"
if [[ ! -x /opt/hubproxy/mtproto-proxy ]]; then
  rm -rf /tmp/mtproxy-src
  git clone -q --depth 1 https://github.com/TelegramMessenger/MTProxy /tmp/mtproxy-src
  make -C /tmp/mtproxy-src -j"$(nproc)" >/dev/null 2>&1 || die "MTProxy не собрался (не хватает пакетов сборки)"
  install -D -m 0755 /tmp/mtproxy-src/objs/bin/mtproto-proxy /opt/hubproxy/mtproto-proxy
  rm -rf /tmp/mtproxy-src
fi
ok "MTProxy готов"

step "Собираю TProxy"
# Именно он делает главное: разбирает, кто постучался в 443 — браузер или
# Telegram — и либо отдаёт сайт, либо уводит соединение в MTProxy.
if [[ ! -x /usr/local/bin/hubproxy-tproxy ]]; then
  if ! command -v go >/dev/null; then
    ARCH=$(dpkg --print-architecture)
    curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz || die "не скачался Go"
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    export PATH=$PATH:/usr/local/go/bin
  fi
  rm -rf /tmp/tproxy-src
  git clone -q --depth 1 https://github.com/telegramdesktop/tproxy-server /tmp/tproxy-src
  ( cd /tmp/tproxy-src && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
      -o /usr/local/bin/hubproxy-tproxy ./cmd/tproxy-server ) >/dev/null 2>&1 \
    || die "TProxy не собрался — смотрите вывод go build"
  install -d -m 0755 "$SITE"
  cp -a /tmp/tproxy-src/deploy "$STATE-deploy" 2>/dev/null || true
  rm -rf /tmp/tproxy-src
fi
ok "TProxy готов"

# ─── конфигурация ───────────────────────────────────────────────────────
step "Беру данные Telegram"
install -d -m 0755 "$STATE"
# С серверов в РФ core.telegram.org иногда отвечает по IPv6 и очень медленно
# (замеряли 11 с против 0,07 с из Европы), поэтому просим IPv4, даём запас по
# времени и повторяем попытки: одиночный curl тут регулярно не укладывается.
tg_fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3; do
    curl -fsS --ipv4 --max-time 60 --retry 2 --retry-delay 3 "$url" -o "$out" && return 0
    warn "попытка $i не удалась, повторяю…"
    sleep 3
  done
  return 1
}
tg_fetch https://core.telegram.org/getProxySecret "$STATE/proxy-secret" || die "не скачался proxy-secret с серверов Telegram"
tg_fetch https://core.telegram.org/getProxyConfig "$STATE/proxy-multi.conf" || die "не скачался proxy-multi.conf"
[[ -s "$STATE/proxy-secret" && -s "$STATE/proxy-multi.conf" ]] || die "файлы Telegram пустые — попробуйте позже"
ok "Конфигурация получена"

step "Готовлю секрет и страницу"
SECRET=$(head -c 16 /dev/urandom | xxd -p -c 32)
install -d -m 0755 "$SITE"
# Обычная страница обслуживания: тот, кто откроет домен браузером, не должен
# заподозрить, что здесь есть что-то ещё.
cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Технические работы</title>
<style>
 body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f7f9;
      font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;color:#3c4350}
 .b{max-width:420px;padding:40px 28px;text-align:center}
 h1{margin:0 0 10px;font-size:22px;font-weight:600;color:#222}
 p{margin:0;color:#6b7280}
</style></head>
<body><div class="b"><h1>Технические работы</h1>
<p>Сайт временно недоступен. Мы вернёмся в ближайшее время.</p></div></body></html>
HTML
chmod 0644 "$SITE/index.html"

cat > "$STATE/config.json" <<JSON
{
  "public_hostname": "$DOMAIN",
  "listen": "127.0.0.1:$TPROXY_PORT",
  "admin_listen": "127.0.0.1:$TPROXY_ADMIN",
  "public_dir": "$SITE",
  "profiles_file": "$STATE/profiles.json",
  "enable_pprof": false
}
JSON
cat > "$STATE/profiles.json" <<JSON
{ "profiles": [ { "name": "default", "secret": "$SECRET", "backend": "127.0.0.1:$MTPROXY_PORT" } ] }
JSON
chmod 0600 "$STATE/profiles.json"
ok "Секрет создан"

step "Настраиваю Caddy"
# Весь трафик уходит в TProxy — он сам разделит браузер и Telegram.
cat > /etc/caddy/Caddyfile <<CADDY
{
	email admin@$DOMAIN
	admin off
	servers {
		# Только h1/h2. HTTP/3 здесь лишний: клиент Telegram им не пользуется,
		# а лишний ALPN на 443 делает сервер заметнее.
		protocols h1 h2
		timeouts {
			read_header 10s
			# ⚠️ TProxy держит длинные опросы (~25 с). С дефолтными таймаутами
			# Caddy рвёт их, и клиент показывает «недоступен».
			read_body 60s
		}
	}
}

$DOMAIN {
	encode zstd gzip
	header Strict-Transport-Security "max-age=31536000; includeSubDomains"
	# Весь трафик уходит в TProxy: и сайт, и Telegram. Разделять пути нельзя,
	# иначе поведение двух веток начнёт отличаться и прокси станет заметен.
	reverse_proxy 127.0.0.1:$TPROXY_PORT {
		transport http {
			response_header_timeout 40s
		}
	}
}
CADDY
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddy не принял конфиг"
systemctl enable --now caddy >/dev/null 2>&1
systemctl reload caddy 2>/dev/null || systemctl restart caddy
ok "Caddy настроен"

step "Поднимаю службы"
cat > /etc/systemd/system/hubproxy-mtproto.service <<UNIT
[Unit]
Description=HUBProxy: MTProto (слушает только localhost)
After=network-online.target

[Service]
# ⚠️ Ни --address, ни --nat-info здесь не место. Оба ограничивают ИСХОДЯЩИЕ
# соединения, а MTProxy должен свободно ходить к серверам Telegram: с ними он
# падает в «connect(): Invalid argument» и клиент вечно висит на «соединение».
# Наружу порт закрыт файрволом, этого достаточно.
ExecStart=/opt/hubproxy/mtproto-proxy -u nobody -H $MTPROXY_PORT -S $SECRET \\
  --aes-pwd $STATE/proxy-secret $STATE/proxy-multi.conf -M 1
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/hubproxy-tproxy.service <<UNIT
[Unit]
Description=HUBProxy: TProxy (сайт + вход Telegram)
After=network-online.target hubproxy-mtproto.service
Wants=hubproxy-mtproto.service

[Service]
ExecStart=/usr/local/bin/hubproxy-tproxy --config $STATE/config.json
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now hubproxy-mtproto hubproxy-tproxy >/dev/null 2>&1
sleep 3
systemctl is-active --quiet hubproxy-mtproto || die "MTProxy не запустился: journalctl -u hubproxy-mtproto -n 30"
systemctl is-active --quiet hubproxy-tproxy  || die "TProxy не запустился: journalctl -u hubproxy-tproxy -n 30"
ok "Обе службы работают"

# ─── проверка по факту ──────────────────────────────────────────────────
step "Проверяю результат"
sleep 4
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "https://$DOMAIN/" || echo 000)
case "$CODE" in
  200) ok "Сайт открывается по HTTPS, сертификат выпущен" ;;
  000) warn "Домен пока молчит — сертификат выпускается до минуты. Проверьте: curl -I https://$DOMAIN/" ;;
  *)   warn "Ответ $CODE. Журнал: journalctl -u caddy -n 30" ;;
esac
if ss -ltn | grep -q ":$MTPROXY_PORT"; then
  ok "MTProxy поднят"
  # порт слушается на всех интерфейсах (иначе прокси не сможет ходить к Telegram),
  # поэтому закрываем его снаружи файрволом, а не привязкой к localhost
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "$MTPROXY_PORT"/tcp >/dev/null 2>&1 || true
    ok "Порт $MTPROXY_PORT закрыт снаружи (ufw)"
  else
    warn "ufw выключен: закройте порт $MTPROXY_PORT снаружи вручную, иначе прокси доступен в обход маскировки"
  fi
else warn "MTProxy не слушает $MTPROXY_PORT"; fi
ss -ltn | grep -q "127.0.0.1:$TPROXY_PORT"  && ok "TProxy на месте" || warn "TProxy не слушает $TPROXY_PORT"

DOMAIN_HEX=$(printf '%s' "$DOMAIN" | xxd -p -c 256 | tr -d '\n')
LINK="tg://proxy?server=$DOMAIN&port=443&secret=ee${SECRET}${DOMAIN_HEX}"
umask 077
cat > "$INFO" <<TXT
HUBProxy — подключение
домен:  $DOMAIN
секрет: $SECRET
ссылка: $LINK
создано: $(date '+%F %T')
TXT

step "Готово"
say "Ссылка для Telegram — откройте на телефоне:"
say "  $LINK"
say ""
say "${c_dim}Сохранено в $INFO (только root)${c_off}"
say "${c_dim}Сменить секрет: bash install.sh $DOMAIN --rotate${c_off}"
say "${c_dim}Удалить:        bash install.sh --uninstall${c_off}"

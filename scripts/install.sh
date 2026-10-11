#!/usr/bin/env bash
# Automated installation on a clean Ubuntu 22.04+/Debian 12+ x86_64 server.
#
#   sudo ./scripts/install.sh                         # interactive
#   sudo ./scripts/install.sh --hostname proxy.example.com --email me@example.com
#   sudo ./scripts/install.sh --hostname proxy.example.com --behind-proxy
#
# Options:
#   --hostname NAME     domain whose A record points to this server (required)
#   --email ADDRESS     e-mail for Let's Encrypt (optional)
#   --behind-proxy      TLS is terminated by your own web server; the container
#                       listens on 127.0.0.1:8080 only
#   --base-path SLUG    fixed proxy URI prefix ("none" = site root); random by default
#   --site FILE         HTML file to install as site/index.html
#   --ref REF           upstream tproxy-server commit/branch to build
#   --yes               do not ask questions (fail if something is missing)
set -euo pipefail
caller_dir="$(pwd)"

cd "$(dirname "$0")/.."
repo_dir="$(pwd)"

hostname='' email='' behind_proxy=0 base_path='' site_file='' ref='' assume_yes=0 agree=''
while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname) hostname="${2:-}"; shift 2 ;;
		--email) email="${2:-}"; shift 2 ;;
		--behind-proxy) behind_proxy=1; shift ;;
		--base-path) base_path="${2:-}"; shift 2 ;;
		--site) site_file="${2:-}"; [[ "$site_file" == /* ]] || site_file="$caller_dir/$site_file"; shift 2 ;;
		--ref) ref="${2:-}"; shift 2 ;;
		--yes|-y) assume_yes=1; shift ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

say() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mВнимание:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }
ask() { # var prompt default
	local answer
	if [[ $assume_yes -eq 1 ]]; then printf -v "$1" %s "$3"; return; fi
	read -r -p "$2${3:+ [$3]}: " answer </dev/tty || true
	printf -v "$1" %s "${answer:-$3}"
}

cat <<'EOF'

  tgweb-proxy - учебная сборка telegramdesktop/tproxy-server в Docker.

  Репозиторий предназначен для изучения современных технологий, применяемых
  в Telegram, а не для создания технических средств обхода блокировок.
  Продолжая установку, вы принимаете на себя всю ответственность за
  дальнейшее использование решения.

EOF
if [[ $assume_yes -eq 0 ]]; then
	ask agree "Продолжить? (да/нет)" "нет"
	[[ "$agree" =~ ^(да|д|yes|y)$ ]] || die "установка отменена"
fi

[[ $EUID -eq 0 ]] || die "запустите скрипт от root: sudo $0 $*"
[[ "$(uname -m)" == "x86_64" ]] || die "нужен сервер x86_64 (официальный MTProxy собирается только под эту архитектуру)"

# --- Parameters --------------------------------------------------------------
if [[ -f .env ]]; then
	say "Найден существующий .env - значения из него будут использованы по умолчанию"
	# shellcheck disable=SC1091
	set -a; source .env; set +a
	hostname="${hostname:-${TPROXY_HOSTNAME:-}}"
	email="${email:-${ACME_EMAIL:-}}"
	base_path="${base_path:-${TPROXY_BASE_PATH:-}}"
	[[ "${TLS_MODE:-auto}" == "off" ]] && behind_proxy=1
fi
[[ "$hostname" == "proxy.example.com" ]] && hostname=
[[ -n "$hostname" ]] || ask hostname "Доменное имя сервера (например, myname.example.com)" ""
hostname="$(printf %s "$hostname" | tr 'A-Z' 'a-z')"
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
	die "некорректное доменное имя: '$hostname'"
if [[ $behind_proxy -eq 0 && -z "$email" && $assume_yes -eq 0 ]]; then
	ask email "E-mail для уведомлений Let's Encrypt (можно оставить пустым)" ""
fi

# --- Docker ------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
	say "Устанавливаю Docker (официальный скрипт get.docker.com)"
	command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl ca-certificates; }
	curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "не найден плагин docker compose v2"

# --- DNS check -----------------------------------------------------------------
public_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
resolved="$(getent ahostsv4 "$hostname" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
if [[ -z "$resolved" ]]; then
	warn "имя $hostname пока не находится в DNS. Создайте A-запись на ${public_ip:-IP сервера} и подождите."
elif [[ -n "$public_ip" && "$resolved" != "$public_ip" && $behind_proxy -eq 0 ]]; then
	warn "$hostname указывает на $resolved, а у сервера адрес $public_ip - сертификат не будет получен."
fi

# --- Secret and base path --------------------------------------------------------
secret="${TPROXY_SECRET:-}"
[[ -n "$secret" ]] || secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
if [[ -z "$base_path" ]]; then
	base_path="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '=\n')"
fi

say "Записываю настройки в $repo_dir/.env"
umask 077
cat > .env <<EOF
TPROXY_HOSTNAME=$hostname
ACME_EMAIL=$email
TLS_MODE=$([[ $behind_proxy -eq 1 ]] && echo off || echo auto)
TPROXY_SECRET=$secret
TPROXY_BASE_PATH=$base_path
TPROXY_CARRIER_MODE=${TPROXY_CARRIER_MODE:-https}
MTPROXY_PUBLIC_IP=${MTPROXY_PUBLIC_IP:-$public_ip}
MTPROXY_WORKERS=${MTPROXY_WORKERS:-1}
MTPROXY_MAX_CONNECTIONS=${MTPROXY_MAX_CONNECTIONS:-4096}
PRINT_LINK_ON_START=1
${ref:+TPROXY_REF=$ref}
EOF
umask 022

# --- Website ---------------------------------------------------------------------
mkdir -p site
if [[ -n "$site_file" ]]; then
	install -m 0644 "$site_file" site/index.html
fi
if [[ ! -f site/index.html ]]; then
	warn "site/index.html отсутствует - будет показана временная заглушка."
	warn "Сгенерируйте свою страницу по инструкции docs/SITE-PROMPT.md и выполните: sudo ./scripts/update.sh"
fi

# --- Firewall --------------------------------------------------------------------
if [[ $behind_proxy -eq 0 ]] && command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
	say "Открываю порты 80 и 443 в ufw"
	ufw allow 80/tcp >/dev/null
	ufw allow 443/tcp >/dev/null
fi

# --- Build and start ----------------------------------------------------------------
compose=(docker compose -f compose.yaml)
[[ $behind_proxy -eq 1 ]] && compose+=(-f compose.behind-proxy.yaml)
printf '%s\n' "${compose[@]}" > .compose-files

say "Собираю образ и запускаю контейнер (первая сборка занимает 3-10 минут)"
"${compose[@]}" up -d --build

say "Жду готовности"
for _ in $(seq 1 60); do
	if docker exec tgweb-proxy show-link >/dev/null 2>&1; then break; fi
	sleep 2
done
for _ in $(seq 1 30); do
	if docker exec tgweb-proxy tgweb-net get -o /dev/null http://127.0.0.1:9081/readyz >/dev/null 2>&1; then break; fi
	sleep 2
done

echo
docker exec tgweb-proxy show-link || { "${compose[@]}" logs --tail 50; die "контейнер не запустился"; }
cat <<EOF

Готово. Проверьте сайт: https://$hostname/
Ссылку можно вывести повторно командой:  sudo ./scripts/show-link.sh
Журнал работы:                           sudo docker compose logs -f
EOF
if [[ $behind_proxy -eq 1 ]]; then
	cat <<EOF

Контейнер слушает http://127.0.0.1:8080. Настройте свой веб-сервер по
docs/REVERSE-PROXY.md (готовые примеры: examples/reverse-proxy/).
EOF
fi

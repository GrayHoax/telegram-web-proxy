#!/usr/bin/env bash
# Container entrypoint: prepares configuration from environment variables and
# supervises three processes in one network namespace:
#
#   Caddy :8080/:8443  ->  tproxy-server 127.0.0.1:9080  ->  MTProxy 127.0.0.1:2398
#                                   \->  Caddy file server 127.0.0.1:9000 (/site)
#
# Everything that must survive a restart (secret, base path, token key, TLS
# certificates, MTProxy routing data) lives in /data.
set -euo pipefail
umask 077

log() { printf '%s [tgweb-proxy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

DATA=/data
RUN=/run/tgweb
SITE_SOURCE=/site
SITE=$RUN/site
STOP=$RUN/stopping

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------
TLS_MODE="${TLS_MODE:-auto}"
ACME_EMAIL="${ACME_EMAIL:-}"
TRUSTED_PROXIES="${TRUSTED_PROXIES:-private_ranges}"
TPROXY_CARRIER_MODE="${TPROXY_CARRIER_MODE:-https}"
TPROXY_LIMITS_JSON="${TPROXY_LIMITS_JSON:-}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
MTPROXY_NAT_INFO="${MTPROXY_NAT_INFO:-auto}"
MTPROXY_PUBLIC_IP="${MTPROXY_PUBLIC_IP:-}"
MTPROXY_CONFIG_REFRESH="${MTPROXY_CONFIG_REFRESH:-86400}"
PRINT_LINK_ON_START="${PRINT_LINK_ON_START:-1}"

hostname="$(printf %s "${TPROXY_HOSTNAME:-}" | tr 'A-Z' 'a-z')"
[[ -n "$hostname" ]] || die "TPROXY_HOSTNAME is required (e.g. proxy.example.com)"
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
	die "TPROXY_HOSTNAME must be a plain lowercase DNS name (use the xn-- form for IDN): $hostname"

case "$TLS_MODE" in
	auto|off) ;;
	*) die "TLS_MODE must be 'auto' (Caddy obtains a certificate) or 'off' (behind your reverse proxy)" ;;
esac
case "$TPROXY_CARRIER_MODE" in
	https|https-lanes|websocket|websocket-lanes) ;;
	*) die "TPROXY_CARRIER_MODE must be one of: https, https-lanes, websocket, websocket-lanes" ;;
esac
[[ "$MTPROXY_WORKERS" =~ ^[1-9][0-9]*$ ]] || die "MTPROXY_WORKERS must be a positive integer"
[[ "$MTPROXY_MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || die "MTPROXY_MAX_CONNECTIONS must be a positive integer"
[[ "$MTPROXY_CONFIG_REFRESH" =~ ^[0-9]+$ ]] || die "MTPROXY_CONFIG_REFRESH must be a number of seconds (0 disables)"

# Create a directory only when it is missing, so a restart never needs
# CAP_FOWNER/CAP_DAC_OVERRIDE on directories already owned by a service user.
ensure_dir() { # path owner:group mode
	if [[ ! -d "$1" ]]; then
		install -d -o "${2%%:*}" -g "${2##*:}" -m "$3" "$1"
	fi
}

ensure_dir "$DATA" root:root 0711
# Service users only traverse /data into their own subdirectories; the files
# directly in /data (secret, base_path) stay root-only.
chmod 0711 "$DATA"
mkdir -p "$RUN"
find "$RUN" -mindepth 1 -delete
chmod 0755 "$RUN"

# --------------------------------------------------------------------------
# Secret (32 hex chars, optionally dd-prefixed) - generated once and persisted
# --------------------------------------------------------------------------
secret="$(printf %s "${TPROXY_SECRET:-}" | tr 'A-F' 'a-f')"
if [[ -z "$secret" ]]; then
	if [[ ! -s "$DATA/secret" ]]; then
		od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$DATA/secret"
		log "generated a new proxy secret in $DATA/secret"
	fi
	secret="$(tr -d '[:space:]' < "$DATA/secret")"
fi
[[ "$secret" =~ ^(dd)?[0-9a-f]{32}$ ]] ||
	die "TPROXY_SECRET must be 32 hex characters (optionally prefixed with dd); generate one with: openssl rand -hex 16"

# --------------------------------------------------------------------------
# Base path (random URI of the proxy) - generated once and persisted
# --------------------------------------------------------------------------
base_path="${TPROXY_BASE_PATH:-}"
if [[ "$base_path" == "none" ]]; then
	base_path=
elif [[ -z "$base_path" ]]; then
	if [[ ! -s "$DATA/base_path" ]]; then
		# 10 random bytes -> 16 lowercase base32 characters, as upstream install.sh
		head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '=\n' > "$DATA/base_path"
		log "generated a new random base path in $DATA/base_path"
	fi
	base_path="$(tr -d '[:space:]' < "$DATA/base_path")"
fi
if [[ -n "$base_path" ]]; then
	[[ "$base_path" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]] && [[ ${#base_path} -le 128 ]] ||
		die "TPROXY_BASE_PATH must be '/'-separated segments of [A-Za-z0-9_-] (first char alphanumeric), max 128 chars"
fi

# --------------------------------------------------------------------------
# Relay: token key, profiles, config
# --------------------------------------------------------------------------
ensure_dir "$DATA/relay" root:tproxy 0750
key="$DATA/relay/token.key"
if [[ ! -e "$key" ]]; then
	head -c 32 /dev/urandom > "$key.tmp"
	chmod 0400 "$key.tmp"
	chown tproxy:tproxy "$key.tmp"
	mv "$key.tmp" "$key"
	log "generated a persistent relay token key"
fi
[[ -f "$key" ]] && [[ "$(stat -c %s "$key")" -eq 32 ]] || die "$key must be a regular 32-byte file"

install -d -o root -g tproxy -m 0750 "$RUN/relay"
printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:2398","carrier_mode":"%s"}]}\n' \
	"$secret" "$TPROXY_CARRIER_MODE" > "$RUN/relay/profiles.json"
chmod 0400 "$RUN/relay/profiles.json"
chown tproxy:tproxy "$RUN/relay/profiles.json"

limits_line=
if [[ -n "$TPROXY_LIMITS_JSON" ]]; then
	limits_line="  \"limits\": $TPROXY_LIMITS_JSON,"
fi
cat > "$RUN/relay/config.json" <<EOF
{
  "public_hostname": "$hostname",
  "base_path": "$base_path",
  "listen": "127.0.0.1:9080",
  "admin_listen": "127.0.0.1:9081",
  "public_upstream": "http://127.0.0.1:9000",
$limits_line
  "token_key_file": "$key",
  "profiles_file": "$RUN/relay/profiles.json"
}
EOF
chmod 0640 "$RUN/relay/config.json"
chown root:tproxy "$RUN/relay/config.json"

# Drop root for a command; used both in the foreground and under supervision,
# where setpriv execs the service so that its PID is the one we signal.
AS_TPROXY=(setpriv --reuid=tproxy --regid=tproxy --init-groups --no-new-privs --)
AS_CADDY=(setpriv --reuid=caddy --regid=caddy --init-groups --no-new-privs --)

"${AS_TPROXY[@]}" /usr/local/bin/tproxy-server -config "$RUN/relay/config.json" -check >/dev/null ||
	die "relay configuration check failed (see the message above)"

# --------------------------------------------------------------------------
# Public website (the "cover" page): copied from /site, placeholder if empty
# --------------------------------------------------------------------------
install -d -m 0755 "$SITE"
if [[ -d "$SITE_SOURCE" ]]; then
	# Skip dot entries (Kubernetes ConfigMap mounts contain ..data symlink farms)
	# and this repository's site/README.md.
	find "$SITE_SOURCE" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name 'README.md' -exec cp -rL {} "$SITE/" \;
fi
if [[ ! -f "$SITE/index.html" ]]; then
	cp /usr/local/share/tgweb-proxy/placeholder/index.html "$SITE/index.html"
	log "WARNING: /site/index.html is missing - serving a generic placeholder."
	log "WARNING: generate your own page (docs/SITE-PROMPT.md) and put it into ./site/index.html"
fi
if [[ ! -f "$SITE/404.html" ]]; then
	cp /usr/local/share/tgweb-proxy/placeholder/404.html "$SITE/404.html"
fi
chmod -R a+rX,go-w "$SITE"

# --------------------------------------------------------------------------
# Caddy
# --------------------------------------------------------------------------
ensure_dir "$DATA/caddy" caddy:caddy 0700
install -d -o root -g caddy -m 0750 "$RUN/caddy"

site_body() { # $1 = extra header lines
	cat <<EOF
	encode zstd gzip
	header {
		-Via
$1	}
	reverse_proxy 127.0.0.1:9080 {
		# The relay accepts exactly one address in X-Forwarded-For.
		header_up X-Forwarded-For {client_ip}
		transport http {
			response_header_timeout 40s
		}
	}
	handle_errors {
		header Cache-Control "no-store"
		respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
	}
EOF
}

if [[ "$TLS_MODE" == "auto" ]]; then
	email_line=
	[[ -n "$ACME_EMAIL" ]] && email_line="	email $ACME_EMAIL"
	cat > "$RUN/caddy/Caddyfile" <<EOF
{
	admin off
	http_port 8080
	https_port 8443
$email_line
	servers {
		protocols h1 h2
		timeouts {
			read_header 10s
			read_body 60s
		}
	}
}

$hostname {
$(site_body '		Strict-Transport-Security "max-age=31536000; includeSubDomains"
')
}
EOF
else
	cat > "$RUN/caddy/Caddyfile" <<EOF
{
	admin off
	auto_https off
	servers {
		trusted_proxies static $TRUSTED_PROXIES
		trusted_proxies_strict
		client_ip_headers X-Forwarded-For X-Real-IP
		protocols h1 h2c
		timeouts {
			read_header 10s
			read_body 60s
		}
	}
}

:8080 {
$(site_body '')
}
EOF
fi
cat >> "$RUN/caddy/Caddyfile" <<EOF

# Loopback-only public website used by the relay as public_upstream.
http://:9000 {
	bind 127.0.0.1
	root * $SITE
	file_server {
		hide .*
	}
	handle_errors 404 {
		rewrite * /404.html
		file_server
	}
}
EOF
chmod 0640 "$RUN/caddy/Caddyfile"
chown root:caddy "$RUN/caddy/Caddyfile"
caddy fmt --overwrite "$RUN/caddy/Caddyfile" >/dev/null 2>&1 || true
"${AS_CADDY[@]}" caddy validate --config "$RUN/caddy/Caddyfile" --adapter caddyfile >/dev/null 2>&1 ||
	{ "${AS_CADDY[@]}" caddy validate --config "$RUN/caddy/Caddyfile" --adapter caddyfile; die "Caddy configuration is invalid"; }

# --------------------------------------------------------------------------
# MTProxy: Telegram's proxy secret and routing config, NAT detection
# --------------------------------------------------------------------------
ensure_dir "$DATA/mtproxy" root:mtproxy 0750

fetch() { # url dest minsize
	local tmp
	tmp="$(mktemp "$2.XXXXXX")"
	if tgweb-net get -https -timeout 30s -o "$tmp" "$1" && [[ "$(wc -c < "$tmp")" -ge "$3" ]]; then
		chmod 0640 "$tmp"
		chown root:mtproxy "$tmp"
		printf %s "$tmp"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

refresh_proxy_secret() {
	local tmp
	if tmp="$(fetch https://core.telegram.org/getProxySecret "$DATA/mtproxy/proxy-secret" 128)"; then
		mv -f "$tmp" "$DATA/mtproxy/proxy-secret"
	elif [[ -s "$DATA/mtproxy/proxy-secret" ]]; then
		log "WARNING: could not download proxy-secret, using the cached copy"
	else
		die "could not download https://core.telegram.org/getProxySecret"
	fi
}

# Returns 0 when the routing config changed.
refresh_proxy_config() {
	local tmp
	tmp="$(fetch https://core.telegram.org/getProxyConfig "$DATA/mtproxy/proxy-multi.conf" 100)" || return 1
	if ! grep -q '^default ' "$tmp" || ! grep -q '^proxy_for ' "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	if [[ -e "$DATA/mtproxy/proxy-multi.conf" ]] && cmp -s "$tmp" "$DATA/mtproxy/proxy-multi.conf"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$DATA/mtproxy/proxy-multi.conf"
	return 0
}

refresh_proxy_secret
if ! refresh_proxy_config && [[ ! -s "$DATA/mtproxy/proxy-multi.conf" ]]; then
	die "could not download https://core.telegram.org/getProxyConfig"
fi

# MTProxy hashes its own source address into the middle-end session keys. Behind
# NAT (a Docker bridge, a Kubernetes pod, EC2/GCE) it must be told the public
# address with --nat-info, otherwise clients connect and nothing is answered.
nat_args=()
case "$MTPROXY_NAT_INFO" in
	off|none|"") ;;
	auto)
		local_address="$(tgweb-net local-ip 149.154.175.50 2>/dev/null || true)"
		public_address="$MTPROXY_PUBLIC_IP"
		if [[ -z "$public_address" ]]; then
			for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
				candidate="$(tgweb-net get -https -4 -timeout 15s "$probe" 2>/dev/null |
					tr -d '[:space:]')" || continue
				if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
					public_address="$candidate"
					break
				fi
			done
		fi
		if [[ -z "$public_address" ]]; then
			public_address="$(getent ahostsv4 "$hostname" 2>/dev/null | awk 'NR==1 {print $1}')"
		fi
		if [[ -n "$local_address" && -n "$public_address" && "$local_address" != "$public_address" ]]; then
			nat_args=(--nat-info "$local_address:$public_address")
			log "MTProxy is behind NAT ($local_address -> $public_address)"
		elif [[ -z "$public_address" ]]; then
			log "WARNING: public IPv4 could not be determined; set MTPROXY_PUBLIC_IP"
		fi
		;;
	*:*) nat_args=(--nat-info "$MTPROXY_NAT_INFO") ;;
	*) die "MTPROXY_NAT_INFO must be auto, off, or <local-ip>:<public-ip>" ;;
esac

backend_secret="$secret"
if [[ ${#backend_secret} -eq 34 ]]; then
	backend_secret="${backend_secret:2}"
fi

# --------------------------------------------------------------------------
# Client link
# --------------------------------------------------------------------------
web_proxy_secret() {
	if [[ -z "$base_path" ]]; then
		printf %s "$secret"
		return
	fi
	# Base path links carry base64url(0x70 || secret), exactly as upstream install.sh.
	{
		printf '\x70'
		printf "$(printf %s "$secret" | sed 's/../\\x&/g')"
	} | base64 | tr '+/' '-_' | tr -d '=\n'
}
client_address="$hostname${base_path:+/$base_path}"
proxy_link_secret="$(web_proxy_secret)"
encoded_address="${client_address//\//%2F}"
cat > "$RUN/link.txt" <<EOF
Proxy server (enter manually): $client_address
Proxy secret (enter manually): $secret
Proxy link:                    https://t.me/webproxy?server=$encoded_address&secret=$proxy_link_secret
Proxy link (tg://):            tg://webproxy?server=$encoded_address&secret=$proxy_link_secret
Cover website:                 https://$hostname/
Relay commit:                  $(cat /usr/local/share/tgweb-proxy/tproxy-commit 2>/dev/null || echo unknown)
EOF
chmod 0600 "$RUN/link.txt"

# --------------------------------------------------------------------------
# Supervision
# --------------------------------------------------------------------------
supervise() { # name cmd...
	local name=$1; shift
	(
		while [[ ! -e "$STOP" ]]; do
			"$@" &
			echo $! > "$RUN/$name.pid"
			rc=0
			wait $! || rc=$?
			[[ -e "$STOP" ]] && break
			log "$name exited with code $rc, restarting in 3s"
			sleep 3
		done
	) &
}

shutdown() {
	log "stopping"
	touch "$STOP"
	local name
	# Signal the services, not their restart loops: each loop notices $STOP once
	# its service has exited, so a graceful relay shutdown is waited for.
	for name in refresher caddy relay mtproxy; do
		[[ -s "$RUN/$name.pid" ]] && kill -TERM "$(cat "$RUN/$name.pid")" 2>/dev/null || true
	done
	wait || true
	exit 0
}
trap shutdown TERM INT

supervise mtproxy /usr/local/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398 -S "$backend_secret" \
	"${nat_args[@]}" --aes-pwd "$DATA/mtproxy/proxy-secret" "$DATA/mtproxy/proxy-multi.conf" \
	-M "$MTPROXY_WORKERS" -C "$MTPROXY_MAX_CONNECTIONS"
supervise relay "${AS_TPROXY[@]}" /usr/local/bin/tproxy-server -config "$RUN/relay/config.json"
supervise caddy "${AS_CADDY[@]}" /usr/local/bin/caddy run --config "$RUN/caddy/Caddyfile" --adapter caddyfile

if [[ "$MTPROXY_CONFIG_REFRESH" -gt 0 ]]; then
	(
		while sleep "$MTPROXY_CONFIG_REFRESH"; do
			if refresh_proxy_config; then
				log "Telegram routing config changed, restarting MTProxy"
				kill -TERM "$(cat "$RUN/mtproxy.pid")" 2>/dev/null || true
			fi
		done
	) &
	echo $! > "$RUN/refresher.pid"
fi

log "started: https://$hostname/ (TLS_MODE=$TLS_MODE, carrier=$TPROXY_CARRIER_MODE)"
if [[ "$PRINT_LINK_ON_START" == "1" ]]; then
	log "connection details (also available via: show-link):"
	sed 's/^/    /' "$RUN/link.txt" >&2
else
	log "run 'show-link' inside the container to print the connection details"
fi

while true; do
	wait || true
	[[ -e "$STOP" ]] && exit 0
done

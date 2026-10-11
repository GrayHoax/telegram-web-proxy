# syntax=docker/dockerfile:1.7
#
# Single-image build of https://github.com/telegramdesktop/tproxy-server:
#   Caddy (public gateway, TLS)  ->  tproxy-server (relay)  ->  official MTProxy
#                                          \->  Caddy file server (public site)
#
# The relay accepts requests only from a loopback peer and talks only to loopback
# backends, so all three processes deliberately share one network namespace.
# Official MTProxy is x86_64 only, therefore the image is linux/amd64.
#
# Security maintenance: every Go binary is built with GO_VERSION, Caddy is built
# from source with patched dependencies, Debian packages are upgraded at build
# time, and the runtime has no curl/iproute2 (replaced by tgweb-net). Rebuild
# regularly (the CI workflow does it weekly) to pick up new fixes.

# Floating minor tag: every rebuild picks up the latest Go patch release.
ARG GO_VERSION=1.27
ARG DEBIAN_SUITE=trixie
ARG CADDY_VERSION=2.11.7
# Changing this value (CI passes the ISO week) invalidates the cached layers that
# install OS updates and resolve "latest" Go dependencies.
ARG REFRESH=manual

# ---------------------------------------------------------------------------
# 1. Relay (Go) and the tgweb-net helper
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 golang:${GO_VERSION}-${DEBIAN_SUITE} AS relay

ARG TPROXY_REPO=https://github.com/telegramdesktop/tproxy-server.git
# A tested upstream commit. Pass --build-arg TPROXY_REF=master for the latest code.
ARG TPROXY_REF=c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8
ARG RUN_TESTS=1

WORKDIR /src
RUN git init -q . \
 && git remote add origin "$TPROXY_REPO" \
 && git fetch -q --depth 1 origin "$TPROXY_REF" \
 && git checkout -q --detach FETCH_HEAD \
 && git rev-parse HEAD > /tproxy-commit
RUN go mod download
RUN if [ "$RUN_TESTS" = "1" ]; then go test ./...; fi
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tproxy-server ./cmd/tproxy-server

# Small static helper replacing curl and iproute2 in the runtime image.
WORKDIR /tgweb-net
COPY docker/tgweb-net/main.go ./
RUN go mod init tgweb-net \
 && go vet . \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tgweb-net .

# ---------------------------------------------------------------------------
# 2. Official MTProxy (C), the same pinned commit and checksum as upstream's
#    deploy/install-mtproxy.sh
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 debian:${DEBIAN_SUITE} AS mtproxy

ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_SHA256=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655
ARG REFRESH

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates curl build-essential libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
RUN curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --output /tmp/MTProxy.tar.gz \
        "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
 && echo "${MTPROXY_SHA256}  /tmp/MTProxy.tar.gz" | sha256sum -c - \
 && mkdir /build \
 && tar -C /build --strip-components=1 -xzf /tmp/MTProxy.tar.gz \
 && make -C /build -j"$(nproc)" \
 && install -D -m 0755 /build/objs/bin/mtproto-proxy /out/mtproto-proxy

# ---------------------------------------------------------------------------
# 3. Caddy, built from source with the current Go toolchain and dependencies
#    raised above Caddy's own go.mod where security fixes exist. A plain build
#    also carries no file capabilities (the official binary has
#    cap_net_bind_service, which makes exec fail under cap_drop: ALL).
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 golang:${GO_VERSION}-${DEBIAN_SUITE} AS caddy

ARG CADDY_VERSION
ARG REFRESH
ARG CADDY_DEP_UPGRADES="google.golang.org/grpc@latest golang.org/x/net@latest golang.org/x/crypto@latest golang.org/x/text@latest"

WORKDIR /caddy
COPY docker/caddy/main.go ./
RUN go mod init caddy \
 && go get "github.com/caddyserver/caddy/v2@v${CADDY_VERSION}" \
 && go get ${CADDY_DEP_UPGRADES} \
 && go mod tidy \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/caddy . \
 && /out/caddy version

# ---------------------------------------------------------------------------
# 4. Runtime
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 debian:${DEBIAN_SUITE}-slim

LABEL org.opencontainers.image.title="telegram-web-proxy" \
      org.opencontainers.image.description="Docker build of telegramdesktop/tproxy-server (Telegram WEB proxy relay) with Caddy and official MTProxy" \
      org.opencontainers.image.source="https://github.com/GrayHoax/telegram-web-proxy" \
      org.opencontainers.image.licenses="MIT"

# Only what MTProxy needs at run time (OpenSSL, zlib), CA certificates and tini.
# All base packages are upgraded to the current security releases.
ARG REFRESH
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates tini libssl3t64 zlib1g \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/apt /var/log/dpkg.log \
 && useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy \
 && useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy \
 && useradd --system --home /nonexistent --shell /usr/sbin/nologin caddy

COPY --from=relay   /out/tproxy-server   /usr/local/bin/tproxy-server
COPY --from=relay   /out/tgweb-net       /usr/local/bin/tgweb-net
COPY --from=relay   /tproxy-commit       /usr/local/share/tgweb-proxy/tproxy-commit
COPY --from=mtproxy /out/mtproto-proxy   /usr/local/bin/mtproto-proxy
COPY --from=caddy   /out/caddy           /usr/local/bin/caddy
COPY docker/entrypoint.sh  /usr/local/bin/entrypoint.sh
COPY docker/show-link      /usr/local/bin/show-link
COPY docker/placeholder/   /usr/local/share/tgweb-proxy/placeholder/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/show-link \
 && install -d -m 0755 /site \
 && install -d -m 0711 /data

ENV TLS_MODE=auto \
    XDG_DATA_HOME=/data/caddy/data \
    XDG_CONFIG_HOME=/data/caddy/config

# 8080 = HTTP (ACME challenge / plain HTTP behind a reverse proxy), 8443 = HTTPS
EXPOSE 8080 8443
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/tgweb-net", "get", "-timeout", "4s", "-o", "/dev/null", "http://127.0.0.1:9081/healthz"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

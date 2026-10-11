# syntax=docker/dockerfile:1.7
#
# Single-image build of https://github.com/telegramdesktop/tproxy-server:
#   Caddy (public gateway, TLS)  ->  tproxy-server (relay)  ->  official MTProxy
#                                          \->  Caddy file server (public site)
#
# The relay accepts requests only from a loopback peer and talks only to loopback
# backends, so all three processes deliberately share one network namespace.
# Official MTProxy is x86_64 only, therefore the image is linux/amd64.

ARG GO_VERSION=1.26.5
ARG DEBIAN_SUITE=bookworm
ARG CADDY_VERSION=2.11.4

# ---------------------------------------------------------------------------
# 1. Relay (Go)
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

# ---------------------------------------------------------------------------
# 2. Official MTProxy (C), the same pinned commit and checksum as upstream's
#    deploy/install-mtproxy.sh
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 debian:${DEBIAN_SUITE} AS mtproxy

ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_SHA256=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655

RUN apt-get update \
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
# 3. Caddy (official static binary)
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 caddy:${CADDY_VERSION}-alpine AS caddy
# The official binary carries the cap_net_bind_service file capability, which
# makes exec fail with EPERM under cap_drop: ALL. Caddy here listens on high
# ports only, so a plain copy (no xattrs) is used.
RUN cp /usr/bin/caddy /caddy

# ---------------------------------------------------------------------------
# 4. Runtime
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 debian:${DEBIAN_SUITE}-slim

LABEL org.opencontainers.image.title="tgweb-proxy" \
      org.opencontainers.image.description="Docker build of telegramdesktop/tproxy-server (Telegram WEB proxy relay) with Caddy and official MTProxy" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl iproute2 tini libssl3 zlib1g \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy \
 && useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy \
 && useradd --system --home /nonexistent --shell /usr/sbin/nologin caddy

COPY --from=relay   /out/tproxy-server   /usr/local/bin/tproxy-server
COPY --from=relay   /tproxy-commit       /usr/local/share/tgweb-proxy/tproxy-commit
COPY --from=mtproxy /out/mtproto-proxy   /usr/local/bin/mtproto-proxy
COPY --from=caddy   /caddy               /usr/local/bin/caddy
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
  CMD curl --fail --silent http://127.0.0.1:9081/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

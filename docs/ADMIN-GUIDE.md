# Руководство для ИТ-специалистов

> ⚠️ **Важно.** Этот репозиторий предназначен **не для создания технических средств
> обхода блокировок**, а для изучения современных технологий, применяемых в Telegram
> (MTProto/MTProxy, мультиплексированный транспорт через WebView поверх HTTPS и
> WebSocket, capability-based маскировка служебных путей). Продолжая использовать
> решения из этого репозитория, вы самостоятельно берёте на себя всю ответственность
> за их применение и соблюдение применимого законодательства.

Документ описывает внутреннее устройство образа, все параметры, режимы развёртывания и
эксплуатацию. Протокол и модель угроз апстрима описаны в
[tproxy-server](https://github.com/telegramdesktop/tproxy-server): `README.md`,
`PROTOCOL.md`, `BASE_PATH.md`, `PUBLIC_SITE.md`, `HARDENING.md`.

---

## 1. Архитектура

```text
client WebView ──HTTPS/WSS──► Caddy :8443 (или :8080 при TLS_MODE=off)
                                │  header_up X-Forwarded-For {client_ip}
                                ▼
                          tproxy-server 127.0.0.1:9080   admin 127.0.0.1:9081
                           │ valid capability / token          │ всё остальное
                           ▼                                   ▼
                    MTProxy 127.0.0.1:2398             Caddy file_server 127.0.0.1:9000 (/site)
                    stats 127.0.0.1:8888 (внутр.)      (public_upstream реле)
                           │
                           ▼
                    middle-end серверы Telegram
```

Почему всё в одном контейнере:

- `tproxy-server` в `clientIP()` отклоняет запросы, у которых peer не loopback
  (`request did not arrive through loopback proxy`). Конфигурация валидирует, что `listen`,
  `admin_listen`, `public_upstream` и `backend` каждого профиля – числовые loopback-адреса.
  Поэтому фронт, реле и бэкенды должны находиться в одном сетевом namespace. В Kubernetes
  это мог бы быть один Pod с несколькими контейнерами, но один образ проще
  распространять и одинаково запускать в Compose и в K8s.
- Внутренний Caddy остаётся единственным HTTP-входом в любом режиме. Он нормализует
  `X-Forwarded-For` до одного адреса: реле отвергает список или неразбираемое значение.
  Кроме того, он сохраняет `Host`, держит таймауты длинных опросов и сжатие одинаковыми
  для сайта и транспорта.

Процессы и пользователи:

| Процесс | Пользователь | Слушает | Примечание |
|---|---|---|---|
| `entrypoint.sh` (bash под `tini`) | root | – | готовит файлы, перезапускает упавшие процессы, обновляет `proxy-multi.conf` |
| `caddy` | `caddy` | `:8080`, `:8443`, `127.0.0.1:9000` | высокие порты, file capabilities сняты |
| `tproxy-server` | `tproxy` | `127.0.0.1:9080`, `127.0.0.1:9081` | запускается через `setpriv --no-new-privs` |
| `mtproto-proxy` | root → `mtproxy` (`-u`) | `0.0.0.0:2398`, `:8888` | у стокового MTProxy нет опции bind. **Не публикуйте эти порты** |

## 2. Сборка образа

```bash
docker build -t tgweb-proxy:local .
docker build -t tgweb-proxy:edge --build-arg TPROXY_REF=master .   # свежий апстрим
```

| Build-arg | По умолчанию | Назначение |
|---|---|---|
| `TPROXY_REF` | `c8adb8b7…` (проверенный коммит) | коммит, тег или ветка tproxy-server |
| `TPROXY_REPO` | github.com/telegramdesktop/tproxy-server | форк |
| `RUN_TESTS` | `1` | `go test ./...` во время сборки (тест с node пропускается) |
| `GO_VERSION` | `1.26.5` | как в апстримном `install.sh` |
| `CADDY_VERSION` | `2.11.4` | как в апстримном `install.sh` |
| `MTPROXY_COMMIT` / `MTPROXY_SHA256` | `f36d8af…` / `919795…` | официальный MTProxy; контрольная сумма архива проверяется |
| `DEBIAN_SUITE` | `bookworm` | база для сборки MTProxy и рантайма |

Образ собирается только под `linux/amd64`: MTProxy использует x86-специфичный код. На
Apple Silicon сборка идёт через эмуляцию (`--platform linux/amd64`), в рантайме нужен
x86_64-узел.

CI: `.github/workflows/docker-image.yml` собирает образ при push, по тегам, раз в
неделю (чтобы подтягивать обновления базовых образов) и вручную, после чего
публикует `ghcr.io/grayhoax/telegram-web-proxy:latest|sha-…|<tag>`. Для ручного запуска можно
передать `tproxy_ref`.

## 3. Режимы развёртывания

### 3.1. Standalone (`TLS_MODE=auto`)

`compose.yaml`: контейнер публикует `80→8080` и `443→8443`, Caddy получает и продлевает
сертификат Let's Encrypt (HTTP-01 и TLS-ALPN-01). Внутренний Caddy знает, что внешние
порты стандартные, поэтому редирект HTTP→HTTPS формируется без `:8443`.
Сертификаты хранятся в `/data/caddy`.

```bash
cp .env.example .env && $EDITOR .env
docker compose up -d --build
docker compose exec tgweb-proxy show-link
```

### 3.2. За обратным прокси (`TLS_MODE=off`)

```bash
docker compose -f compose.yaml -f compose.behind-proxy.yaml up -d --build
```

Контейнер слушает `127.0.0.1:${TGWEB_HTTP_PORT:-8080}` по HTTP/1.1 и h2c. Внутренний
Caddy доверяет `X-Forwarded-For`/`X-Real-IP` только от `TRUSTED_PROXIES`
(по умолчанию `private_ranges`; к контейнеру трафик приходит с адреса docker-bridge
шлюза), разбирает цепочку справа налево (`trusted_proxies_strict`) и передаёт реле
ровно один адрес. Требования к внешнему серверу и готовые конфигурации описаны в
[REVERSE-PROXY.md](REVERSE-PROXY.md).

**Режим A** (рекомендуется): весь hostname проксируется в контейнер.
**Режим B**: существующий сайт остаётся на своём сервере, в контейнер уходит только
`/<base_path>/`. Ограничение режима B: ответы на неизвестные URL под префиксом даёт
сайт внутри контейнера. Чтобы они совпадали с остальным сайтом, положите в `./site`
копию того же сайта (подробнее – в `BASE_PATH.md` апстрима, §2 и §4).

### 3.3. Kubernetes

Описано в [k8s/README.md](../k8s/README.md): kustomize, Ingress (ingress-nginx/Traefik
+ cert-manager) или Gateway API HTTPRoute, PVC, NetworkPolicy, read-only root FS.

## 4. Параметры окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `TPROXY_HOSTNAME` | – | **обязательно**; lowercase, IDN – только в форме A-label (`xn--…`). Реле сравнивает `Host` запроса с этим значением |
| `TLS_MODE` | `auto` | `auto` / `off` |
| `ACME_EMAIL` | – | контакт ACME |
| `TPROXY_SECRET` | генерируется в `/data/secret` | `[0-9a-f]{32}` или `dd` + 32 hex. MTProxy получает его без префикса `dd` |
| `TPROXY_BASE_PATH` | генерируется в `/data/base_path` | сегменты `[A-Za-z0-9][A-Za-z0-9_-]*` через `/`, не длиннее 128 символов, регистр значим; `none` – корень |
| `TPROXY_CARRIER_MODE` | `https` | `https` / `https-lanes` / `websocket` / `websocket-lanes` (см. таблицу в README апстрима) |
| `TPROXY_LIMITS_JSON` | – | подставляется как `"limits": {…}` в `config.json` реле; значения проверяет `tproxy-server -check` |
| `TRUSTED_PROXIES` | `private_ranges` | аргументы `trusted_proxies static …` для Caddy (только при `TLS_MODE=off`) |
| `MTPROXY_WORKERS` | `1` | `-M` |
| `MTPROXY_MAX_CONNECTIONS` | `4096` | `-C` (на воркер) |
| `MTPROXY_NAT_INFO` | `auto` | `auto` – `ip route get` + внешнее эхо-API; `off`; или явно `10.0.0.5:203.0.113.7` |
| `MTPROXY_PUBLIC_IP` | – | внешний IPv4 для `auto`, если эхо-сервисы недоступны или egress идёт через другой адрес |
| `MTPROXY_CONFIG_REFRESH` | `86400` | период обновления `getProxyConfig` в секундах (`0` – не обновлять); при изменении MTProxy перезапускается |
| `PRINT_LINK_ON_START` | `1` | печатать ссылку и секрет в stdout; в K8s по умолчанию `0` |

Конфигурация реле (`/run/tgweb/relay/config.json`) пересоздаётся при каждом старте и
перед запуском проверяется командой `tproxy-server -check`. Если проверка не прошла,
контейнер не стартует.

## 5. Состояние (`/data`)

| Путь | Владелец/права | Содержимое |
|---|---|---|
| `/data/secret` | root 0600 | сгенерированный секрет (если не задан `TPROXY_SECRET`) |
| `/data/base_path` | root 0600 | сгенерированный путь (если не задан `TPROXY_BASE_PATH`) |
| `/data/relay/token.key` | tproxy 0400 | 32-байтовый ключ подписи bootstrap/session-токенов. **Делайте резервную копию**; при потере ключа активные сессии сбрасываются |
| `/data/mtproxy/proxy-secret`, `proxy-multi.conf` | root:mtproxy 0640 | данные core.telegram.org (если скачать не удалось, используется кэш) |
| `/data/caddy/` | caddy 0700 | ACME-аккаунт, сертификаты, autosave |

Резервная копия тома:

```bash
docker run --rm -v tgweb-proxy_tgweb-data:/data -v "$PWD":/backup debian:bookworm-slim \
  tar czf /backup/tgweb-data.tgz -C /data .
```

## 6. Ссылка для клиента

`show-link` (и вывод при старте) содержит:

- `Proxy server` – `host` или `host/base_path` для ручного ввода;
- `Proxy secret` – hex-секрет для ручного ввода (при ручном вводе он не меняется и при наличии base path);
- `Proxy link` – `https://t.me/webproxy?server=<host%2Fpath>&secret=<s>`, где при непустом
  base path `s = base64url_nopad(0x70 ‖ secret)`. Маркер `0x70` нужен, чтобы старые
  клиенты не приняли ссылку за прокси без пути (`BASE_PATH.md` §3).

Capability, которую выводит клиент:
`base64url(HMAC-SHA256(secret, "tdesktop-web-proxy-bridge-v2\n" + host + "\n" + path))`.
Смена hostname, base path или секрета делает старые ссылки недействительными.

## 7. Безопасность

- **Capabilities.** Контейнеру нужны только `CHOWN`, `SETUID`, `SETGID` (подготовка
  файлов и сброс привилегий) и `KILL` (корректная остановка процессов других UID).
  Остальное отбрасывается (`cap_drop: ALL`), включён `no-new-privileges`.
- **Read-only root FS** поддерживается: записываемые пути – `/data`, `/run/tgweb`
  (tmpfs) и `/tmp`. Пример: `docker run --read-only --tmpfs /run/tgweb --tmpfs /tmp …`.
- **Порты 2398 и 8888** открыты только внутри сетевого namespace контейнера. В Compose
  их не публикуйте, в Kubernetes их закрывает `NetworkPolicy`. Апстримный nftables-скрипт
  в контейнере не используется (он требует `NET_ADMIN`).
- **Секрет MTProxy** передаётся через `-S` и виден в списке процессов контейнера
  (`docker top`). Это ограничение стокового MTProxy, как и в апстриме. Не давайте
  посторонним доступ к Docker API или узлу.
- **Журналы.** Ни внутренний Caddy, ни реле не пишут access-логи. На внешнем прокси
  отключите журналирование URI и заголовков для этого хоста: bridge URL содержит
  capability, а WebSocket-несущая передаёт bearer в `Sec-WebSocket-Protocol`.
- **Сайт-обложка** работает в том же origin, что и bridge-страница. Не используйте
  Service Worker, сторонние скрипты и аналитику (`PUBLIC_SITE.md`). Промпт в
  [SITE-PROMPT.md](SITE-PROMPT.md) это явно запрещает.
- **Не ставьте CDN/WAF** перед первым развёртыванием (рекомендация апстрима). Не
  добавляйте к ответам `X-Frame-Options`, COOP/COEP или framing-CSP: у bridge-страницы
  собственный CSP.
- Если `/site/index.html` отсутствует, показывается заглушка из образа и в журнал
  пишется предупреждение. Одинаковая заглушка на многих серверах – готовая сигнатура,
  поэтому замените её.

## 8. Эксплуатация

```bash
docker compose logs -f                                     # все процессы
docker compose exec tgweb-proxy curl -s 127.0.0.1:9081/healthz   # liveness реле
docker compose exec tgweb-proxy curl -s 127.0.0.1:9081/readyz    # + доступность MTProxy
docker compose exec tgweb-proxy curl -s 127.0.0.1:9081/metrics
docker compose exec tgweb-proxy curl -s 127.0.0.1:8888/stats     # статистика MTProxy
docker compose exec tgweb-proxy show-link
```

- `HEALTHCHECK` образа проверяет `/healthz`. `readyz` возвращает 503, пока недоступен
  MTProxy; при этом сайт продолжает работать.
- Упавший процесс перезапускается через 3 с. Остановка контейнера (`SIGTERM`)
  корректно завершает реле: `event=shutdown` → `event=stopped`.
- **Обновление:** `sudo ./scripts/update.sh` (`git pull`, `build --pull`, `up -d`) или
  `./scripts/update.sh --latest` для апстримного `master`. Перезапуск реле сбрасывает
  carrier-сессии, клиенты переподключаются автоматически.
- **Смена сайта:** обновите файлы в `./site` и выполните `docker compose restart`.
  Статика копируется при старте.
- **Ротация секрета или пути:** измените или очистите `TPROXY_SECRET` / `TPROXY_BASE_PATH`
  в `.env` (если значения хранились в `/data`, удалите соответствующий файл) и
  выполните `docker compose up -d`. Раздайте новую ссылку.
- **Масштабирование:** один процесс реле обслуживает один hostname, сессии хранятся
  в памяти. Не запускайте больше одной реплики на hostname. Для роста нагрузки
  увеличьте `MTPROXY_WORKERS` (следите за CPU Caddy и реле) и лимиты в
  `TPROXY_LIMITS_JSON`. Для нескольких серверов используйте разные hostname и секреты.
- **Несколько профилей** (несколько секретов или режимов несущей на одном hostname)
  entrypoint пока не генерирует. Для этого расширьте генерацию `profiles.json` и
  запустите отдельный MTProxy на каждый backend-порт (README апстрима, раздел
  «Multiple secrets»).

## 9. Проверка развёртывания

```bash
curl -fsS https://proxy.example.com/ | head                           # сайт
curl -s -o /dev/null -w '%{http_code}\n' https://proxy.example.com/<base>/      # 404 сайта
curl -s -o /dev/null -w '%{http_code}\n' "https://proxy.example.com/?bridge=x"  # 200, главная
nc -vz -w3 <ip> 2398; nc -vz -w3 <ip> 8888                            # должны не открываться
docker compose logs tgweb-proxy | grep -c 'Disconnected from RPC Middle-End'    # должно быть 0
```

Что проверено при подготовке репозитория (локально, Docker 29, `TLS_MODE=off` и `auto`):
сборка с апстримными Go-тестами; запуск с `cap_drop: ALL` + 4 capabilities и `--read-only`;
главная страница и 404; одинаковый ответ сайта на неверный `?bridge=`, на голый
префикс и на `/<base>/api/v1/session`; ответ 200 с CSP bridge-страницы на верную
capability под префиксом; 404 на верную capability вне префикса; нормализация
`X-Forwarded-For` со списком адресов; автоопределение NAT для MTProxy и успешная
загрузка конфигурации Telegram; корректная остановка. Сквозное подключение реальным
клиентом Telegram в рамках подготовки не проверялось.

## 10. Диагностика

| Симптом | Причина и решение |
|---|---|
| Сайт открывается, клиент «подключается» бесконечно; в журнале `Disconnected from RPC Middle-End` | MTProxy за NAT анонсирует не тот адрес. Задайте `MTPROXY_PUBLIC_IP` или `MTPROXY_NAT_INFO=<ip контейнера>:<внешний ip>` |
| Клиент видит сайт вместо bridge | Не совпадает hostname, путь или секрет; внешний прокси не передаёт `Host` или обрезает префикс (у nginx `proxy_pass` не должен содержать URI) |
| `413` на upstream-запросах | `client_max_body_size` и аналоги меньше 4 МБ |
| Сессии рвутся каждые 15–30 с | таймаут чтения на внешнем прокси/ingress меньше длинного опроса (25 с) – ставьте 90 с |
| WebSocket-режимы не работают | внешний прокси не пробрасывает `Upgrade`/`Connection` |
| `relay configuration check failed` | неверные `TPROXY_*` или `TPROXY_LIMITS_JSON`; текст ошибки – строкой выше |
| `setpriv: … Operation not permitted` | не выданы `SETUID`/`SETGID` или исполняемый файл с file capabilities при `cap_drop: ALL` |
| Сертификат не выпускается | A/AAAA должны указывать на сервер напрямую, без CDN; порты 80 и 443 должны быть доступны. Уберите неработающую AAAA-запись |

> ⚠️ Напоминание: материалы репозитория предназначены для изучения технологий
> Telegram. Ответственность за дальнейшее использование несёт пользователь.

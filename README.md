# telegram-web-proxy

Docker-сборка [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server):
серверной части экспериментального типа прокси **WEB** для Telegram. Сюда же входят
готовые настройки Docker Compose и Kubernetes, примеры для популярных веб-серверов
и промпт для генерации страницы-обложки через нейросеть.

> ⚠️ **Важно.** Этот репозиторий предназначен **не для создания технических средств
> обхода блокировок**, а для изучения современных технологий, применяемых в Telegram
> (MTProto, MTProxy, транспорт через WebView поверх HTTPS/WebSocket, маскировка
> служебных путей). Продолжая использовать решения из этого репозитория, вы
> самостоятельно берёте на себя всю ответственность за их применение и соблюдение
> законодательства своей страны.

## Как это устроено

```text
Интернет
  │  :80 / :443
  ▼
контейнер tgweb-proxy (один сетевой namespace)
  Caddy :8080 / :8443  (TLS, единственный внешний вход)
    └─► tproxy-server 127.0.0.1:9080  (реле, Go)
          ├─► MTProxy 127.0.0.1:2398  (официальный, C) ──► серверы Telegram
          └─► сайт-обложка 127.0.0.1:9000  (Caddy file_server, файлы из /site)
```

- **Главная страница** домена – обычный сайт, который вы генерируете сами
  ([промпт для ChatGPT/DeepSeek](docs/SITE-PROMPT.md)).
- **Прокси** живёт под случайным путём (`https://домен/<16 случайных символов>/`).
  Путь генерируется автоматически при первом запуске. Запрос без верного секрета,
  даже по этому пути, получает обычную 404-страницу сайта.
- Реле принимает запросы только с loopback и подключается только к loopback-бэкендам.
  Поэтому Caddy, реле и MTProxy работают в одном контейнере под тремя разными
  непривилегированными пользователями.
- Всё, что нужно сохранять между перезапусками (секрет, путь, ключ токенов,
  сертификаты, конфигурация маршрутизации Telegram), лежит в томе `/data`.

**Про клиентов.** Тип прокси WEB пока экспериментальный (proof of concept). Подключиться
можно только из клиента Telegram, который его поддерживает: тестовой сборки Telegram
Desktop или экспериментального Android-клиента (см. `ANDROID.md` и `IOS.md` в апстриме).
Обычные MTProxy-ссылки `tg://proxy` здесь не работают.

## Быстрый старт из готового образа

Образ [`grayhoax/telegram-web-proxy:latest`](https://hub.docker.com/r/grayhoax/telegram-web-proxy)
собирается и публикуется автоматически, клонировать репозиторий не нужно. Нужны
сервер **x86_64** с Docker и домен, A-запись которого указывает на этот сервер.

### Вариант 1. За вашим веб-сервером (nginx, Caddy, Apache, Traefik, …)

TLS остаётся на вашем веб-сервере, а контейнер слушает только `127.0.0.1:8080` по HTTP:

```bash
docker run -d --name tgweb-proxy --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -e TPROXY_HOSTNAME=proxy.example.com \
  -e TLS_MODE=off \
  -v tgweb-data:/data \
  -v "$PWD/site:/site:ro" \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges \
  grayhoax/telegram-web-proxy:latest

docker exec tgweb-proxy show-link      # адрес, секрет и ссылка для клиента
```

Проксируйте **весь** hostname на `http://127.0.0.1:8080`. Минимальная конфигурация nginx:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name proxy.example.com;
    ssl_certificate     /etc/letsencrypt/live/proxy.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/proxy.example.com/privkey.pem;

    client_max_body_size 4m;   # пакеты до 2 МБ
    access_log off;            # в URL и заголовках передаются секретные токены

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;                    # реле проверяет Host
        proxy_set_header X-Forwarded-For $remote_addr;  # ровно один адрес
        proxy_set_header Upgrade $http_upgrade;         # несущие websocket*
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 90s;                         # long poll = 25 с
        proxy_send_timeout 90s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
```

То же самое для Caddy (сертификат он получит сам):

```caddyfile
proxy.example.com {
	log {
		output discard
	}
	reverse_proxy 127.0.0.1:8080 {
		header_up X-Forwarded-For {client_ip}
		flush_interval -1
	}
}
```

Что важно для любого веб-сервера:

- передавайте исходный `Host` и не обрезайте путь;
- таймаут ответа не меньше 90 с, размер тела не меньше 4 МБ, буферизация выключена;
- пробрасывайте `Upgrade`/`Connection`;
- отключите access-лог для этого хоста.

Если веб-сервер подключается к контейнеру не с частного адреса (например, с другой
машины), добавьте `-e TRUSTED_PROXIES="<его IP>"`. Конфигурации для Apache, Traefik,
HAProxy, а также режим «прокси только под путём существующего сайта» описаны в
[docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md).

### Вариант 2. Контейнер сам принимает 80/443 и получает сертификат

Подходит, если на сервере нет другого веб-сервера:

```bash
docker run -d --name tgweb-proxy --restart unless-stopped \
  -p 80:8080 -p 443:8443 \
  -e TPROXY_HOSTNAME=proxy.example.com \
  -e ACME_EMAIL=you@example.com \
  -v tgweb-data:/data \
  -v "$PWD/site:/site:ro" \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges \
  grayhoax/telegram-web-proxy:latest

docker logs -f tgweb-proxy             # получение сертификата и ссылка для клиента
```

### Что ещё

- **Страница-обложка.** Сгенерируйте её по [docs/SITE-PROMPT.md](docs/SITE-PROMPT.md)
  и положите в `./site/index.html` (можно добавить `404.html`, стили, картинки), затем
  выполните `docker restart tgweb-proxy`. Без своей страницы показывается встроенная заглушка.
- **Секрет и случайный путь** генерируются при первом запуске и хранятся в томе
  `tgweb-data`, поэтому ссылка не меняется после перезапусков. Задать их явно можно
  через `-e TPROXY_SECRET=$(openssl rand -hex 16)` и `-e TPROXY_BASE_PATH=…`. Все
  переменные перечислены [ниже](#основные-параметры-env).
- **Обновление:**
  ```bash
  docker pull grayhoax/telegram-web-proxy:latest
  docker rm -f tgweb-proxy
  ```
  Затем повторите ту же команду `docker run`. Данные в томе сохранятся.

## Автоматическая установка из исходников (Linux-сервер x86_64 с доменом)

```bash
git clone https://github.com/GrayHoax/telegram-web-proxy.git
cd telegram-web-proxy
sudo ./scripts/install.sh --hostname proxy.example.com --email you@example.com
```

Скрипт сам установит Docker, сгенерирует секрет и случайный путь, соберёт образ,
запустит контейнер и выведет ссылку для подключения. Потом сгенерируйте страницу-обложку
по [docs/SITE-PROMPT.md](docs/SITE-PROMPT.md), положите её в `site/index.html` и
выполните `docker compose restart`.

Вручную то же самое:

```bash
cp .env.example .env && nano .env        # TPROXY_HOSTNAME=...
docker compose up -d --build
docker compose exec tgweb-proxy show-link
```

Если хочется Compose без локальной сборки, запустите готовый образ так:
`TGWEB_IMAGE=grayhoax/telegram-web-proxy:latest docker compose up -d --no-build`.

## Документация

| Для кого | Документ |
|---|---|
| Для тех, кто не связан с ИТ: пошагово, с покупкой сервера и домена | [docs/BEGINNER.md](docs/BEGINNER.md) |
| Для ИТ-специалистов: архитектура, параметры, эксплуатация, безопасность | [docs/ADMIN-GUIDE.md](docs/ADMIN-GUIDE.md) |
| Проксирование через nginx, Caddy, Apache, Traefik и HAProxy | [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md) |
| Генерация страницы-обложки через ChatGPT или DeepSeek | [docs/SITE-PROMPT.md](docs/SITE-PROMPT.md) |
| Kubernetes | [k8s/README.md](k8s/README.md) |

## Состав репозитория

```text
Dockerfile                    многоэтапная сборка: реле (Go) + MTProxy (C) + Caddy
docker/entrypoint.sh          генерация конфигурации из переменных окружения и надзор за процессами
docker/show-link              вывод ссылки для подключения (внутри контейнера)
compose.yaml                  самостоятельный режим: контейнер сам получает сертификат (порты 80/443)
compose.behind-proxy.yaml     режим за вашим веб-сервером (127.0.0.1:8080, без TLS)
.env.example                  все настройки с комментариями
scripts/install.sh            автоматическая установка на чистый сервер
scripts/update.sh             обновление и пересборка
site/                         ваша страница-обложка (index.html, 404.html, ...)
examples/reverse-proxy/       готовые конфигурации nginx, Caddy, Apache, HAProxy, Traefik
k8s/                          манифесты Kubernetes (kustomize) и deploy.sh
.github/workflows/            сборка образа и публикация в Docker Hub (grayhoax/telegram-web-proxy)
```

## Основные параметры (`.env`)

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TPROXY_HOSTNAME` | – (обязательно) | домен, A-запись которого указывает на сервер |
| `TLS_MODE` | `auto` | `auto`: сертификат Let's Encrypt получает сам контейнер; `off`: TLS снимает ваш веб-сервер |
| `ACME_EMAIL` | пусто | e-mail для Let's Encrypt |
| `TPROXY_SECRET` | генерируется | 32 hex-символа, секрет MTProxy |
| `TPROXY_BASE_PATH` | генерируется | случайный путь прокси; `none` – корень сайта |
| `TPROXY_CARRIER_MODE` | `https` | `https`, `https-lanes`, `websocket`, `websocket-lanes` |
| `TRUSTED_PROXIES` | `private_ranges` | чьему `X-Forwarded-For` доверять при `TLS_MODE=off` |
| `MTPROXY_PUBLIC_IP` | автоопределение | внешний IPv4 (нужен MTProxy за NAT) |
| `MTPROXY_NAT_INFO` | `auto` | `auto`, `off` или `<внутренний-ip>:<внешний-ip>` |
| `MTPROXY_WORKERS` / `MTPROXY_MAX_CONNECTIONS` | `1` / `4096` | процессы MTProxy и соединения на процесс |
| `TPROXY_LIMITS_JSON` | пусто | JSON-объект `limits` реле, например `{"max_sessions_global":256}` |
| `PRINT_LINK_ON_START` | `1` | печатать ссылку в журнал при запуске |

Подробнее – в [docs/ADMIN-GUIDE.md](docs/ADMIN-GUIDE.md).

## Лицензия

Файлы этого репозитория распространяются по лицензии MIT (см. [LICENSE](LICENSE)).
Исходники tproxy-server, MTProxy и Caddy скачиваются во время сборки и
распространяются на условиях своих лицензий.

> ⚠️ Ещё раз: репозиторий создан для изучения технологий Telegram. Решение о
> дальнейшем использовании и ответственность за него лежат на пользователе.

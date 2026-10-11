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

## Быстрый старт (Linux-сервер x86_64 с доменом)

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
.github/workflows/            сборка образа и публикация в GHCR
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

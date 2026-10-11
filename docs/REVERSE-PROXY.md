# Проксирование из популярных веб-серверов

> ⚠️ **Важно.** Этот репозиторий предназначен **не для создания технических средств
> обхода блокировок**, а для изучения современных технологий, применяемых в Telegram.
> Продолжая использовать решения из этого репозитория, вы самостоятельно берёте на
> себя всю ответственность за их применение.

Этот документ нужен, если на сервере уже работает веб-сервер, который занимает порты
80/443, или если TLS должен снимать ваш балансировщик. В этом случае контейнер
запускается без TLS и слушает только loopback:

```bash
docker compose -f compose.yaml -f compose.behind-proxy.yaml up -d --build
# контейнер доступен на http://127.0.0.1:8080 (порт меняется через TGWEB_HTTP_PORT)
```

`scripts/install.sh --behind-proxy` делает то же самое автоматически.

## Два режима

| | **A – отдельный hostname** (рекомендуется) | **B – существующий сайт** |
|---|---|---|
| Что уходит в контейнер | **все** пути hostname | только `/<base_path>/` |
| Главная страница | сайт из `./site` в контейнере | ваш существующий сайт |
| Маскировка | один стек ответов на всём хосте | два стека; положите копию сайта в `./site`, чтобы 404 под префиксом совпадали |
| Пример | `home.example.com` | `example.com/phcf2vfe7zgbrslg/` |

`base_path` берётся из `.env` (`TPROXY_BASE_PATH`) или из вывода
`docker compose exec tgweb-proxy show-link`. Путь чувствителен к регистру, а завершающий
слэш обязателен: `/<path>` без слэша по замыслу апстрима отдаётся сайту.

## Обязательные требования к внешнему серверу

| Требование | Зачем |
|---|---|
| Передавать исходный `Host` | реле сравнивает `Host` с `TPROXY_HOSTNAME`, а capability привязана к hostname |
| Не переписывать путь (не обрезать префикс) | реле ожидает `/<base_path>/…` целиком |
| Таймаут чтения ответа **≥ 60–90 с** | длинный опрос (long poll) длится 25 с |
| Размер тела запроса **≥ 4 МБ** | пакеты uplink достигают 2 МБ (у nginx по умолчанию 1 МБ → `413`) |
| Выключить буферизацию запросов и ответов | потоковая передача и длинные опросы |
| Пробрасывать `Upgrade`/`Connection` | несущие `websocket`, `websocket-lanes` |
| HTTP/2 к клиенту (желательно) | режим `https-lanes` держит много параллельных опросов |
| Не вести access-лог URI/заголовков для этого хоста | в URL и заголовках передаются capability и bearer |
| Не добавлять `X-Frame-Options`, COOP/COEP, CSP к проксируемым ответам | у bridge-страницы собственный CSP |
| Подключаться к контейнеру с частного адреса (или задать `TRUSTED_PROXIES`) | только тогда контейнер доверяет `X-Forwarded-For` от прокси |

Значение `X-Forwarded-For` контейнер нормализует сам. Можно передавать как
`$remote_addr`, так и цепочку: внутренний Caddy выделит адрес клиента.

## Готовые конфигурации

Все файлы лежат в [`examples/reverse-proxy/`](../examples/reverse-proxy/). Замените в них
`proxy.example.com`, пути к сертификатам и `phcf2vfe7zgbrslg` на свои значения.

### nginx

Режим A – [`nginx.conf`](../examples/reverse-proxy/nginx.conf). Главное:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;      # без URI после адреса!
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 90s;
    proxy_send_timeout 90s;
    proxy_buffering off;
    proxy_request_buffering off;
}
client_max_body_size 4m;
access_log off;
```

Режим B – [`nginx-cohost.conf`](../examples/reverse-proxy/nginx-cohost.conf):
`location ^~ /<base_path>/ { … }` перед `location /` вашего сайта.

Сертификат для nginx: `certbot --nginx -d proxy.example.com`.

### Caddy

[`Caddyfile`](../examples/reverse-proxy/Caddyfile). Caddy сам получит сертификат, передаёт
`Host` и проксирует WebSocket. Нужны только `flush_interval -1`, `read_body 60s` в
глобальных `servers` и отключённый лог.

```caddyfile
proxy.example.com {
	log {
		output discard
	}
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
		transport http {
			response_header_timeout 40s
		}
	}
}
```

### Apache httpd 2.4.47+

[`apache.conf`](../examples/reverse-proxy/apache.conf). Модули:
`a2enmod ssl proxy proxy_http proxy_http2 headers http2`.

```apache
ProxyPreserveHost On
ProxyTimeout 90
LimitRequestBody 4194304
RequestHeader set X-Forwarded-For "expr=%{REMOTE_ADDR}"
ProxyPass        / http://127.0.0.1:8080/ upgrade=websocket flushpackets=on keepalive=On
ProxyPassReverse / http://127.0.0.1:8080/
```

В версиях до 2.4.47 для `/<base_path>/api/v1/ws` нужен `mod_proxy_wstunnel` и отдельный
`ProxyPass … ws://127.0.0.1:8080/…`. Комментарии в конфигурации Apache пишите только
на отдельных строках.

### Traefik v3 (Docker)

[`compose.traefik.yaml`](../examples/reverse-proxy/compose.traefik.yaml). Этот файл
добавляет Traefik и снимает публикацию портов у контейнера:

```bash
docker compose -f compose.yaml -f examples/reverse-proxy/compose.traefik.yaml up -d --build
```

Traefik по умолчанию передаёт `Host`, проксирует WebSocket и не буферизует тела.
Таймаут чтения на entrypoint выставлен в 90 с. Для режима B добавьте в правило
роутера `&& PathPrefix(`/<base_path>/`)`.

Traefik, установленный не в Docker (file provider):

```yaml
http:
  routers:
    tgweb:
      rule: Host(`proxy.example.com`)
      entryPoints: [websecure]
      tls: { certResolver: le }
      service: tgweb
  services:
    tgweb:
      loadBalancer:
        servers:
          - url: http://127.0.0.1:8080
```

### HAProxy 2.x

[`haproxy.cfg`](../examples/reverse-proxy/haproxy.cfg). Ключевое:

```haproxy
timeout client  90s
timeout server  90s
timeout tunnel  1h
http-request set-header X-Forwarded-For %[src]
```

`option httplog` для этого фронтенда не включайте.

### Kubernetes Ingress / Gateway API

См. [k8s/README.md](../k8s/README.md) (аннотации ingress-nginx, Traefik, HTTPRoute с `timeouts.request`).

## Проверка

```bash
curl -sI https://proxy.example.com/                         # 200, ваш сайт
curl -sI https://proxy.example.com/<base_path>/             # 404 сайта
curl -sI https://proxy.example.com/<base_path>/api/v1/ws    # 404 сайта
curl -s  -o /dev/null -w '%{http_code}\n' 'https://proxy.example.com/?bridge=wrong'   # 200, главная
```

Если на неверные запросы все проверки возвращают обычные ответы сайта, а клиент
подключается, проксирование настроено правильно.

> ⚠️ Напоминание: материалы предназначены для изучения технологий Telegram;
> ответственность за использование несёт пользователь.

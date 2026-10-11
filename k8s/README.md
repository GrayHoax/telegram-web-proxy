# Запуск в Kubernetes

> ⚠️ **Важно.** Этот репозиторий предназначен **не для создания технических средств
> обхода блокировок**, а для изучения современных технологий, применяемых в Telegram.
> Продолжая использовать решения из этого репозитория, вы самостоятельно берёте на
> себя всю ответственность за их применение.

## Состав

| Файл | Назначение |
|---|---|
| `kustomization.yaml` | сборка манифестов, генераторы ConfigMap/Secret, образ |
| `namespace.yaml` | namespace `tgweb-proxy` (Pod Security `baseline`) |
| `deployment.yaml` | 1 реплика, `Recreate`, read-only root FS, `cap_drop: ALL` + `CHOWN/SETUID/SETGID/KILL`, exec-пробы |
| `service.yaml` | ClusterIP :80 → контейнер :8080 |
| `pvc.yaml` | `/data`: ключ токенов, данные MTProxy |
| `networkpolicy.yaml` | входящий трафик только на 8080 (MTProxy 2398/8888 закрыты) |
| `ingress.yaml` | Ingress для ingress-nginx/Traefik + cert-manager |
| `httproute.yaml` | альтернатива – Gateway API |
| `config.env` | несекретные параметры (hostname, режим, NAT) |
| `secret.env` | секрет и путь (создаётся `deploy.sh`, в git не попадает) |
| `site/` | страница-обложка (`index.html`, …), попадает в ConfigMap |
| `deploy.sh` | подготовка и `kubectl apply -k` |

Внутри Pod TLS не используется (`TLS_MODE=off`): сертификат обслуживает Ingress или Gateway.
Внутренний Caddy принимает `X-Forwarded-For` только от адресов из `TRUSTED_PROXIES`
(по умолчанию `private_ranges 100.64.0.0/10`). Если Pod CIDR кластера другой, добавьте его.

## Быстрый запуск

1. Соберите и опубликуйте образ (или включите GitHub Actions из `.github/workflows`):

   ```bash
   docker build -t ghcr.io/<you>/tgweb-proxy:latest .
   docker push ghcr.io/<you>/tgweb-proxy:latest
   ```

   Для приватного реестра добавьте `imagePullSecrets` в `deployment.yaml`.

2. Сгенерируйте страницу-обложку по [docs/SITE-PROMPT.md](../docs/SITE-PROMPT.md) и сохраните
   её как `site/index.html` в корне репозитория или в `k8s/site/index.html`. Если нужен
   `404.html` и другие файлы, положите их в `k8s/site/` и раскомментируйте в
   `kustomization.yaml`.

3. Разверните:

   ```bash
   ./k8s/deploy.sh --hostname proxy.example.com --image ghcr.io/<you>/tgweb-proxy:latest
   ```

   Скрипт подставит hostname в `config.env`, `ingress.yaml` и `httproute.yaml`, при
   первом запуске создаст `secret.env` со случайным секретом и путём, скопирует
   страницу, выполнит `kubectl apply -k`, дождётся rollout и выведет ссылку.
   Чтобы только посмотреть манифесты: `./k8s/deploy.sh --dry-run`.

4. Ссылку можно получить позже:

   ```bash
   kubectl -n tgweb-proxy exec deploy/tgweb-proxy -- show-link
   ```

## Требования к кластеру

- Узел **x86_64** (`nodeSelector: kubernetes.io/arch: amd64`).
- StorageClass по умолчанию для PVC (RWO, 256 МиБ).
- Ingress-контроллер и cert-manager с `ClusterIssuer` `letsencrypt` либо Gateway API.
- Исходящий доступ к `core.telegram.org` и серверам Telegram (TCP 8888 middle-end).
- Внешний IPv4, с которого Pod выходит в интернет, должен быть стабильным. MTProxy
  определяет его при старте через `api.ipify.org`. Если egress идёт через NAT-шлюз
  с другим адресом, задайте `MTPROXY_PUBLIC_IP` в `config.env`.

## Ingress-контроллеры

**ingress-nginx.** Аннотации уже заданы в `ingress.yaml`: `proxy-read-timeout`/`proxy-send-timeout` 90 с,
`proxy-body-size` 4m, буферизация выключена, access-лог для хоста отключён. WebSocket
поддерживается по умолчанию. Раскомментируйте `ingressClassName: nginx`.

**Traefik** (в том числе в k3s по умолчанию). Дополнительные аннотации не нужны: `Host`
сохраняется, WebSocket и потоковые тела работают. Укажите `ingressClassName: traefik`.
Если у entrypoint `readTimeout` меньше 60 с, увеличьте его.

**Gateway API.** В `kustomization.yaml` замените `ingress.yaml` на `httproute.yaml` и
укажите свой `parentRefs`. У многих реализаций таймаут маршрута по умолчанию 15 с,
поэтому `timeouts.request: 120s` обязателен.

**LoadBalancer без Ingress.** Можно выдать Pod сертификат самому. Для этого задайте
`TLS_MODE=auto` и `ACME_EMAIL`, откройте порты 8080/8443 в NetworkPolicy и создайте
Service `type: LoadBalancer` с портами `80→8080` и `443→8443`
(`externalTrafficPolicy: Local`, чтобы сохранить адрес клиента).

## Эксплуатация

```bash
kubectl -n tgweb-proxy logs deploy/tgweb-proxy -f
kubectl -n tgweb-proxy exec deploy/tgweb-proxy -- curl -s 127.0.0.1:9081/readyz
kubectl -n tgweb-proxy rollout restart deploy/tgweb-proxy     # после смены страницы
```

- **Одна реплика.** Сессии реле хранятся в памяти. Масштабирование означает отдельные
  hostname и отдельные Deployment.
- **Смена страницы.** Обновите файлы в `k8s/site/` и выполните `kubectl apply -k k8s/`.
  Из-за суффикса-хэша ConfigMap Deployment перезапустится сам.
- **Ротация секрета.** Удалите `k8s/secret.env` и выполните `./k8s/deploy.sh`.
- Логи по умолчанию не содержат секрет (`PRINT_LINK_ON_START=0`).

> ⚠️ Напоминание: материалы предназначены для изучения технологий Telegram;
> ответственность за использование несёт пользователь.

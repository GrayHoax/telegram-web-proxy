#!/usr/bin/env bash
# Prepares the kustomization and deploys it with kubectl.
#
#   ./k8s/deploy.sh --hostname proxy.example.com --image grayhoax/telegram-web-proxy:latest
#
# Options:
#   --hostname NAME   public domain (written into config.env, ingress.yaml, httproute.yaml)
#   --image REF       image reference (registry/name:tag) pushed beforehand
#   --site FILE       HTML file for the cover page (default: ../site/index.html)
#   --no-pvc          keep /data in an emptyDir (no PersistentVolumeClaim); the
#                     relay token key is then stored in secret.env as well
#   --pvc             switch back to the PersistentVolumeClaim (default)
#   --dry-run         only render the manifests (kubectl kustomize)
set -euo pipefail
caller_dir="$(pwd)"
cd "$(dirname "$0")"

hostname='' image='' site_file='' storage='' dry_run=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname) hostname="${2:-}"; shift 2 ;;
		--image) image="${2:-}"; shift 2 ;;
		--site) site_file="${2:-}"; [[ "$site_file" == /* ]] || site_file="$caller_dir/$site_file"; shift 2 ;;
		--no-pvc) storage=emptydir; shift ;;
		--pvc) storage=pvc; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

echo "This repository is for studying the technologies used in Telegram, not for" >&2
echo "building tools to circumvent blocking. You use it at your own responsibility." >&2
echo >&2

if [[ -n "$hostname" ]]; then
	hostname="$(printf %s "$hostname" | tr 'A-Z' 'a-z')"
	current="$(sed -n 's/^TPROXY_HOSTNAME=//p' config.env)"
	sed -i "s/^TPROXY_HOSTNAME=.*/TPROXY_HOSTNAME=$hostname/" config.env
	sed -i "s/\b${current//./\\.}\b/$hostname/g" ingress.yaml httproute.yaml
fi
if [[ -n "$image" ]]; then
	sed -i "s|^\(\s*newName:\).*|\1 ${image%:*}|; s|^\(\s*newTag:\).*|\1 ${image##*:}|" kustomization.yaml
	[[ "$image" == *:* ]] || sed -i "s|^\(\s*newTag:\).*|\1 latest|" kustomization.yaml
fi

case "$storage" in
	emptydir) sed -i 's|^# components:$|components:|; s|^#   - components/no-pvc$|  - components/no-pvc|' kustomization.yaml ;;
	pvc) sed -i 's|^components:$|# components:|; s|^  - components/no-pvc$|#   - components/no-pvc|' kustomization.yaml ;;
esac
no_pvc=0
if grep -q '^  - components/no-pvc$' kustomization.yaml; then no_pvc=1; fi

if [[ ! -f secret.env ]]; then
	umask 077
	{
		echo "TPROXY_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
		echo "TPROXY_BASE_PATH=$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '=\n')"
		echo "TPROXY_TOKEN_KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
	} > secret.env
	umask 022
	echo "generated k8s/secret.env (keep it: it defines the client link)" >&2
elif [[ $no_pvc -eq 1 ]] && ! grep -Eq '^TPROXY_TOKEN_KEY=[0-9a-fA-F]{64}$' secret.env; then
	# Without a PVC the relay token key has to survive pod restarts in the Secret.
	sed -i '/^TPROXY_TOKEN_KEY=/d' secret.env
	echo "TPROXY_TOKEN_KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')" >> secret.env
	echo "added TPROXY_TOKEN_KEY to k8s/secret.env" >&2
fi
if [[ $no_pvc -eq 1 ]]; then
	echo "storage: emptyDir, no PersistentVolumeClaim" >&2
	grep -q '^TLS_MODE=off' config.env ||
		echo "WARNING: without a PVC keep TLS_MODE=off (TLS on the Ingress); otherwise every restart requests a new certificate" >&2
fi

mkdir -p site
if [[ -n "$site_file" ]]; then
	cp "$site_file" site/index.html
elif [[ ! -f site/index.html ]]; then
	if [[ -f ../site/index.html ]]; then
		cp ../site/index.html site/index.html
	else
		cp ../docker/placeholder/index.html site/index.html
		echo "WARNING: no cover page found, using the placeholder (see docs/SITE-PROMPT.md)" >&2
	fi
fi

if [[ $dry_run -eq 1 ]]; then
	kubectl kustomize .
	exit 0
fi

kubectl apply -k .
kubectl -n tgweb-proxy rollout status deployment/tgweb-proxy --timeout=5m
echo
kubectl -n tgweb-proxy exec deploy/tgweb-proxy -- show-link

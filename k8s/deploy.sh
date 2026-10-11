#!/usr/bin/env bash
# Prepares the kustomization and deploys it with kubectl.
#
#   ./k8s/deploy.sh --hostname proxy.example.com --image ghcr.io/me/tgweb-proxy:latest
#
# Options:
#   --hostname NAME   public domain (written into config.env, ingress.yaml, httproute.yaml)
#   --image REF       image reference (registry/name:tag) pushed beforehand
#   --site FILE       HTML file for the cover page (default: ../site/index.html)
#   --dry-run         only render the manifests (kubectl kustomize)
set -euo pipefail
caller_dir="$(pwd)"
cd "$(dirname "$0")"

hostname='' image='' site_file='' dry_run=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname) hostname="${2:-}"; shift 2 ;;
		--image) image="${2:-}"; shift 2 ;;
		--site) site_file="${2:-}"; [[ "$site_file" == /* ]] || site_file="$caller_dir/$site_file"; shift 2 ;;
		--dry-run) dry_run=1; shift ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

echo "This repository is for studying the technologies used in Telegram, not for"
echo "building tools to circumvent blocking. You use it at your own responsibility."
echo

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

if [[ ! -f secret.env ]]; then
	umask 077
	{
		echo "TPROXY_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
		echo "TPROXY_BASE_PATH=$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z' | tr -d '=\n')"
	} > secret.env
	umask 022
	echo "generated k8s/secret.env (keep it: it defines the client link)"
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

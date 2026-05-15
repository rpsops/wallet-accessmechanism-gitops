# SPDX-FileCopyrightText: 2026 Digg - Agency for Digital Government
#
# SPDX-License-Identifier: EUPL-1.2

SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

K3S_NAMESPACE    ?= wallet-hsm
K3S_REPO_NAME    ?= wallet-accessmechanism-gitops
K3S_GIT_REMOTE   ?= k3s
K3S_GIT_INTERNAL ?= http://git-server.git-server.svc.cluster.local/$(K3S_NAMESPACE)/$(K3S_REPO_NAME)
K3S_GIT_EXTERNAL ?= http://git.dev.local:8080/$(K3S_NAMESPACE)/$(K3S_REPO_NAME)
K3S_INTERVAL     ?= 1m
K3S_BRANCH       ?= main
K3S_PATH         ?= ./

.PHONY: k3s-push k3s-register k3s-unregister k3s-rollout k3s-openbao-put help

## Write hsm-worker secrets from .env to OpenBao (run once after 'make up' or when secrets change)
## Requires .env with: PKCS11_LIB, PKCS11_SLOT_TOKEN_LABEL, PKCS11_SO_PIN, PKCS11_USER_PIN,
##   PKCS11_WRAP_KEY_ALIAS, CLIENT_PUBLIC_KEY, OPAQUE_SERVER_IDENTIFIER, OPAQUE_SERVER_SETUP,
##   SERVER_PRIVATE_KEY, SERVER_PUBLIC_KEY
k3s-openbao-put:
	@test -f .env || (echo "ERROR: .env not found"; exit 1)
	@set -a; source .env; set +a; \
	bao kv put secret/$(K3S_NAMESPACE)/hsm-worker-softhsm \
	  "PKCS11_LIB=$$PKCS11_LIB" \
	  "PKCS11_SLOT_TOKEN_LABEL=$$PKCS11_SLOT_TOKEN_LABEL" \
	  "PKCS11_SO_PIN=$$PKCS11_SO_PIN" \
	  "PKCS11_USER_PIN=$$PKCS11_USER_PIN" \
	  "PKCS11_WRAP_KEY_ALIAS=$$PKCS11_WRAP_KEY_ALIAS"
	@set -a; source .env; set +a; \
	bao kv put secret/$(K3S_NAMESPACE)/hsm-worker-opaque \
	  "CLIENT_PUBLIC_KEY=$$CLIENT_PUBLIC_KEY" \
	  "OPAQUE_SERVER_IDENTIFIER=$$OPAQUE_SERVER_IDENTIFIER" \
	  "OPAQUE_SERVER_SETUP=$$OPAQUE_SERVER_SETUP" \
	  "SERVER_PRIVATE_KEY=$$SERVER_PRIVATE_KEY" \
	  "SERVER_PUBLIC_KEY=$$SERVER_PUBLIC_KEY"

## Push this repo to the local k3s git server (initialises bare repo on first push)
## Usage: make k3s-push [K3S_NAMESPACE=wallet-hsm]
k3s-push:
	@kubectl exec -n git-server deploy/git-server -- \
	  bash -c "mkdir -p /repos/$(K3S_NAMESPACE) && \
	           [ -d /repos/$(K3S_NAMESPACE)/$(K3S_REPO_NAME) ] || \
	           git init --bare --initial-branch=main /repos/$(K3S_NAMESPACE)/$(K3S_REPO_NAME) && \
	           chown -R www-data:www-data /repos/$(K3S_NAMESPACE)"
	@git remote get-url $(K3S_GIT_REMOTE) 2>/dev/null | grep -qF "$(K3S_GIT_EXTERNAL)" || \
	  git remote set-url $(K3S_GIT_REMOTE) $(K3S_GIT_EXTERNAL) 2>/dev/null || \
	  git remote add $(K3S_GIT_REMOTE) $(K3S_GIT_EXTERNAL)
	git push $(K3S_GIT_REMOTE) HEAD:$(K3S_BRANCH) --force

## Register this repo with Flux (Namespace + GitRepository + Kustomization + Kyverno exclusion)
## Waits until Flux has fetched the repo and applied the Kustomization.
## Usage: make k3s-register [K3S_NAMESPACE=wallet-hsm]
k3s-register:
	bash scripts/k3s-register.yaml.sh $(K3S_NAMESPACE) $(K3S_INTERVAL) $(K3S_GIT_INTERNAL) $(K3S_BRANCH) $(K3S_PATH) | kubectl apply -f -
	@kubectl patch clusterpolicy verify-internal-images --type=json \
	  -p='[{"op":"add","path":"/spec/rules/0/exclude/any/0/resources/namespaces/-","value":"$(K3S_NAMESPACE)"}]' \
	  2>/dev/null || true
	@echo "Waiting for Flux to fetch repo..."
	kubectl wait gitrepository $(K3S_NAMESPACE) -n flux-system \
	  --for=condition=Ready --timeout=60s
	@echo "Waiting for Flux to apply kustomization..."
	kubectl wait kustomization apps-$(K3S_NAMESPACE) -n flux-system \
	  --for=condition=Ready --timeout=120s
	@echo "Registration complete."

## Remove this namespace's Flux registration from the cluster.
## Waits until the namespace is fully gone before returning.
## Usage: make k3s-unregister [K3S_NAMESPACE=wallet-hsm]
k3s-unregister:
	kubectl delete kustomization apps-$(K3S_NAMESPACE) -n flux-system --ignore-not-found
	kubectl delete gitrepository $(K3S_NAMESPACE) -n flux-system --ignore-not-found
	@kubectl get kafkatopics -n $(K3S_NAMESPACE) -o name 2>/dev/null \
	  | xargs -r -I{} kubectl patch {} -n $(K3S_NAMESPACE) --type=json \
	      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
	kubectl delete namespace $(K3S_NAMESPACE) --ignore-not-found
	@echo "Waiting for namespace to terminate..."
	kubectl wait namespace/$(K3S_NAMESPACE) --for=delete --timeout=120s 2>/dev/null || true
	@echo "Unregistered."

## Authorize rollout: bumps timestamp annotation, commits, tags, pushes to k3s remote.
## Flux reconciles the change and Kubernetes restarts pods to pull the new :k3s image.
## Usage: make k3s-rollout [K3S_NAMESPACE=wallet-hsm]
k3s-rollout:
	@TS=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	TAG="rollout/$$(date -u +"%Y%m%dT%H%M%SZ")"; \
	sed -i.bak "s/rollout-authorized-at: .*/rollout-authorized-at: \"$$TS\"/" \
	  apps/wallet-bff/statefulset.yaml \
	  apps/hsm-worker/statefulset.yaml; \
	rm -f apps/wallet-bff/statefulset.yaml.bak apps/hsm-worker/statefulset.yaml.bak; \
	git add apps/wallet-bff/statefulset.yaml apps/hsm-worker/statefulset.yaml; \
	git commit -s -m "chore: rollout authorized at $$TS"; \
	git tag "$$TAG"; \
	git push $(K3S_GIT_REMOTE) HEAD:$(K3S_BRANCH) --follow-tags
	@echo "Waiting for Flux to apply rollout..."
	flux reconcile kustomization apps-$(K3S_NAMESPACE) -n flux-system --timeout=60s
	kubectl rollout status statefulset/wallet-bff statefulset/hsm-worker \
	  -n $(K3S_NAMESPACE) --timeout=5m
	@echo "Rollout complete."

## Show available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'

# SPDX-FileCopyrightText: 2026 Digg - Agency for Digital Government
#
# SPDX-License-Identifier: EUPL-1.2

SHELL := /bin/bash
.ONESHELL:

K3S_NAMESPACE    ?= wallet-hsm
K3S_REPO_NAME    ?= wallet-accessmechanism-gitops
K3S_GIT_REMOTE   ?= k3s
K3S_GIT_INTERNAL ?= http://git-server.git-server.svc.cluster.local/$(K3S_NAMESPACE)/$(K3S_REPO_NAME)
K3S_GIT_EXTERNAL ?= http://git.dev.local:8080/$(K3S_NAMESPACE)/$(K3S_REPO_NAME)
K3S_INTERVAL     ?= 1m
K3S_BRANCH       ?= main
K3S_PATH         ?= ./

.PHONY: k3s-push k3s-register k3s-unregister help

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
## Run once after k3s-push. Usage: make k3s-register [K3S_NAMESPACE=wallet-hsm]
k3s-register:
	bash scripts/k3s-register.yaml.sh $(K3S_NAMESPACE) $(K3S_INTERVAL) $(K3S_GIT_INTERNAL) $(K3S_BRANCH) $(K3S_PATH) | kubectl apply -f -
	@kubectl patch clusterpolicy verify-internal-images --type=json \
	  -p='[{"op":"add","path":"/spec/rules/0/exclude/any/0/resources/namespaces/-","value":"$(K3S_NAMESPACE)"}]' \
	  2>/dev/null || true

## Remove this namespace's Flux registration from the cluster
## Usage: make k3s-unregister [K3S_NAMESPACE=wallet-hsm]
k3s-unregister:
	kubectl delete kustomization apps-$(K3S_NAMESPACE) -n flux-system --ignore-not-found
	kubectl delete gitrepository $(K3S_NAMESPACE) -n flux-system --ignore-not-found
	@kubectl get kafkatopics -n $(K3S_NAMESPACE) -o name 2>/dev/null \
	  | xargs -r -I{} kubectl patch {} -n $(K3S_NAMESPACE) --type=json \
	      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
	kubectl delete namespace $(K3S_NAMESPACE) --ignore-not-found

## Show available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'

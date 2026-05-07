#!/bin/bash
# Generates the Flux registration manifest for this gitops repo.
# Args: NAMESPACE INTERVAL GIT_INTERNAL_URL BRANCH PATH
NS=$1; INTERVAL=$2; URL=$3; BRANCH=$4; PATH_=$5
cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: $NS
  namespace: flux-system
spec:
  interval: $INTERVAL
  url: $URL
  ref:
    branch: $BRANCH
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-$NS
  namespace: flux-system
spec:
  interval: 10m
  targetNamespace: $NS
  path: $PATH_
  prune: true
  sourceRef:
    kind: GitRepository
    name: $NS
EOF

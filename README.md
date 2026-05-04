<!--
SPDX-FileCopyrightText: 2026 Digg - Agency for Digital Government

SPDX-License-Identifier: EUPL-1.2
-->

# wallet-local-gitops

Self-contained GitOps base for the wallet stack, designed to be **forked
per developer** and watched by Flux in
[wallet-k3s-environment](../wallet-k3s-environment).

Each fork deploys a complete, namespace-isolated copy of the local
ecosystem (the rough k3s equivalent of `wallet-r2ps/docker-compose.yaml`):

- own Kafka cluster (Strimzi, 3 controllers + 3 brokers, KRaft)
- own Valkey (Bitnami, Sentinel HA)
- own KafBat UI
- own Headlamp
- 3× wallet-bff
- 3× hsm-worker

Multiple forks can coexist on the same cluster — they're isolated by
Kubernetes namespace.

## Layout

```
kustomization.yaml      # top-level aggregator (applied by Flux)
apps/
  kafka-cluster/        Strimzi Kafka cluster + shared KafkaTopics
                        (r2ps-wallet-state, hsm-requests, state-init-requests)
  valkey/               Bitnami Valkey HelmRelease (Sentinel HA)
  kafbat/               KafBat Kafka UI HelmRelease
  kafbat-routes/        HTTPRoute for KafBat (kafbat.dev.local)
  headlamp/             Headlamp Kubernetes UI + HTTPRoute
                        (headlamp.dev.local)
  wallet-bff/           r2ps REST API StatefulSet + per-pod KafkaTopics +
                        Service + HTTPRoute (wallet-bff.dev.local)
  hsm-worker/           HSM worker StatefulSet + per-replica SoftHSM token
                        PVC + SealedSecrets for SoftHSM/OPAQUE config
```

No file in this repo carries `metadata.namespace`; Flux's
`Kustomization.spec.targetNamespace` (set to the entry's `name` in
`wallet-k3s-environment/gitops-config.yaml`) injects the fork's
namespace into every namespaced resource — including
`subjects[].namespace` on the headlamp `ClusterRoleBinding`.

The only hard-coded `namespace:` references that remain are
`parentRefs[*].namespace: default` in the three `HTTPRoute`s. That
points at the Cilium `dev-local` Gateway, which lives in `default` (the
gateway is configured `allowedRoutes.namespaces.from: All`, so no
`ReferenceGrant` is needed for cross-namespace attachment).

## Forking

1. Fork this repo to your own git host.
2. In `wallet-k3s-environment`, register the fork:

   ```bash
   cd ../wallet-k3s-environment
   make namespace \
     NAME=<your-fork-namespace> \
     URL=https://<host>/<owner>/wallet-local-gitops.git \
     GITOPS_USER=<git-user> \
     GITOPS_TOKEN=<pat-with-repo-write> \
     IMAGE_AUTOMATION=true
   ```

   `IMAGE_AUTOMATION=true` enables Flux ImageUpdateAutomation for this
   fork (auto-commits image tag bumps back to the fork; see the k3s
   environment README for details).

3. `make up` (or `make sync-apps`) and Flux reconciles the fork into the
   namespace named `<your-fork-namespace>`.

### Running multiple forks simultaneously

The hostnames `wallet-bff.dev.local`, `kafbat.dev.local`, and
`headlamp.dev.local` are baked into the per-fork `HTTPRoute`s. Two forks
on the same cluster will collide on these hostnames. dnsmasq wildcards
`*.dev.local` to the cluster gateway, so any prefix works — sed the
hostnames in your fork before pushing:

```bash
# Pick a unique suffix per fork, e.g. your username.
SUFFIX=alice
sed -i '' "s/wallet-bff\.dev\.local/wallet-bff-${SUFFIX}.dev.local/" \
  apps/wallet-bff/httproute.yaml
sed -i '' "s/kafbat\.dev\.local/kafbat-${SUFFIX}.dev.local/" \
  apps/kafbat-routes/kafbat-ingress.yaml
sed -i '' "s/headlamp\.dev\.local/headlamp-${SUFFIX}.dev.local/" \
  apps/headlamp/headlamp.yaml
git commit -am "fork: rename hostnames"
```

### Fork-only namespaces vs shared infrastructure

Each fork gets its own Kafka, Valkey, KafBat, etc. Cluster-wide
infrastructure stays in `wallet-k3s-environment` and is shared by every
fork:

- Cilium Gateway (`default/dev-local`)
- cert-manager + mkcert ClusterIssuer (`*.dev.local` certs)
- Strimzi operator (cluster-scoped, `watchAnyNamespace: true`)
- Sealed Secrets controller
- Zot registry, Kyverno, Prometheus/Grafana/Loki, Hubble

## Per-pod response topic design

Each `wallet-bff` pod owns dedicated Kafka response topics so replies
are routed back to the originating instance. This mirrors the
multi-instance docker-compose dev setup in
`wallet-r2ps/docker-compose.yaml`.

How it works:

1. `apps/wallet-bff/statefulset.yaml` is a `StatefulSet`, giving each
   pod a stable ordinal name (`wallet-bff-0`, `wallet-bff-1`, ...).
2. The downward API injects `POD_NAME` into the container.
3. Topic-related env vars are templated from `POD_NAME`:
   - `HSM_WORKER_RESPONSE_TOPIC=hsm-worker-responses-$(POD_NAME)`
   - `STATE_INIT_RESPONSE_TOPIC=state-init-responses-$(POD_NAME)`
   - `KAFKA_GROUP_ID=r2ps-rest-api-group-$(POD_NAME)`
4. Matching `KafkaTopic` resources are pre-provisioned by
   `apps/wallet-bff/topics.yaml` (the broker has
   `auto.create.topics.enable=false`).

The `hsm-worker` consumes shared request topics
(`hsm-requests`, `state-init-requests`) and produces back to the
per-pod response topic carried in the request envelope.

### Scaling wallet-bff

The default replica count is `3` and topics for ordinals `0..2` are
pre-provisioned. To scale up:

1. Add new `KafkaTopic` pairs in `apps/wallet-bff/topics.yaml`
   (`hsm-worker-responses-wallet-bff-N`,
   `state-init-responses-wallet-bff-N`).
2. Commit and let Flux reconcile (or
   `flux reconcile kustomization apps-<your-fork>`).
3. Bump `spec.replicas` in `apps/wallet-bff/statefulset.yaml`.

If the StatefulSet is scaled before the topics exist, the new pod will
fail fast on startup.

## Sealing hsm-worker secrets

`apps/hsm-worker/sealed-secrets.yaml` ships placeholder `SealedSecret`
manifests with empty `encryptedData: {}` so a fresh fork applies
cleanly. SealedSecrets are **namespace-scoped** (the encryption is
bound to the namespace passed to `kubeseal --namespace=...`), so each
fork must re-seal its own copies.

```bash
FORK_NS=<your-fork-namespace>

# Build raw Secret manifests from the .env files (NOT committed).
kubectl create secret generic hsm-worker-softhsm \
  --namespace=$FORK_NS \
  --from-env-file=../wallet-r2ps/.env.softhsm \
  --dry-run=client -o yaml > /tmp/hsm-worker-softhsm.secret.yaml

kubectl create secret generic hsm-worker-opaque \
  --namespace=$FORK_NS \
  --from-env-file=../wallet-r2ps/.env.opaque \
  --dry-run=client -o yaml > /tmp/hsm-worker-opaque.secret.yaml

# Seal them with the in-cluster controller, scoped to the fork namespace.
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --namespace=$FORK_NS \
  --format=yaml \
  --secret-file=/tmp/hsm-worker-softhsm.secret.yaml \
  > /tmp/hsm-worker-softhsm.sealed.yaml

kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --namespace=$FORK_NS \
  --format=yaml \
  --secret-file=/tmp/hsm-worker-opaque.secret.yaml \
  > /tmp/hsm-worker-opaque.sealed.yaml
```

Replace the two stub blocks in `apps/hsm-worker/sealed-secrets.yaml`
with the sealed payloads, commit, push.

## Container images

Both StatefulSets pull from the in-cluster Zot registry:

| Workload | Image |
|----------|-------|
| `wallet-bff` | `zot.registry.svc.cluster.local:5000/diggsweden/rust-wallet-bff` |
| `hsm-worker` | `zot.registry.svc.cluster.local:5000/diggsweden/rust-hsm-worker` |

Tag patterns matched by Flux `ImagePolicy` resources in
`wallet-k3s-environment/flux/infrastructure/builds/`:

- `^test-(\d+)-\w+$` — StatefulSets via the
  `# {"$imagepolicy": "flux-system:rust-...-test"}` markers.
- `^stage-(\d+)-\w+$` and `^prod-(\d+)-\w+$` — reserved for future
  promotion gates.

The manifests reference a placeholder tag (`:test-0-placeholder`) that
will not pull. The first manual image push (see the k3s environment
README for `make push-bff` / `make push-hsm` in `wallet-r2ps`) provides
a real `test-<ts>-<sha>` tag. With `IMAGE_AUTOMATION=true` on your
fork's gitops entry, Flux commits the bump back into the fork
automatically; otherwise edit the tag by hand.

All images **must be cosign-signed** with the in-cluster key
(`flux-system/cosign-key`) — Kyverno's `verify-internal-images`
ClusterPolicy is in `Enforce` mode for everything pulled from
`zot.registry.svc.cluster.local:5000/*`. The `wallet-r2ps` Makefile
handles signing automatically.

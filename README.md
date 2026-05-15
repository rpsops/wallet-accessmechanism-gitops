<!--
SPDX-FileCopyrightText: 2026 Digg - Agency for Digital Government

SPDX-License-Identifier: EUPL-1.2
-->

# wallet-accessmechanism-gitops

GitOps base for the wallet stack, watched by Flux in
[k3s-environment](../k3s-environment).

Deploys a complete, namespace-isolated copy of the local ecosystem
(the rough k3s equivalent of `wallet-r2ps/docker-compose.yaml`):

- Kafka cluster (Strimzi, 3 controllers + 3 brokers, KRaft)
- Valkey (Bitnami, Sentinel HA)
- KafBat UI
- Headlamp
- 3× wallet-bff
- 3× hsm-worker

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
`k3s-environment/gitops-config.yaml`) injects the namespace into every
namespaced resource — including `subjects[].namespace` on the headlamp
`ClusterRoleBinding`.

The only hard-coded `namespace:` references are `parentRefs[*].namespace:
default` in the three `HTTPRoute`s, pointing at the Cilium `dev-local`
Gateway (`allowedRoutes.namespaces.from: All`, no `ReferenceGrant` needed).

## Setup

1. Push this repo to the local k3s git server (creates the bare repo on first run):

   ```bash
   make k3s-push
   ```

2. Register with Flux (Namespace + GitRepository + Kustomization + Kyverno exclusion):

   ```bash
   make k3s-register
   ```

3. Flux reconciles automatically (default poll interval: 1m).

To use a different namespace name:

```bash
make k3s-push K3S_NAMESPACE=<ns>
make k3s-register K3S_NAMESPACE=<ns>
```

To tear down:

```bash
make k3s-unregister
```

## Container images

Both StatefulSets pull from the in-cluster Zot registry:

| Workload | Image |
|----------|-------|
| `wallet-bff` | `zot.registry.svc.cluster.local:5000/diggsweden/rust-wallet-bff` |
| `hsm-worker` | `zot.registry.svc.cluster.local:5000/diggsweden/rust-hsm-worker` |

Images are built and pushed via `make emulate-cicd` in `wallet-r2ps` — this
builds, signs with the in-cluster cosign key, and pushes to Zot. Flux
`ImagePolicy` resources in `k3s-environment/flux/infrastructure/builds/`
track tag patterns:

- `^test-(\d+)-\w+$` — matched by the
  `# {"$imagepolicy": "flux-system:rust-...-test"}` markers in the
  StatefulSet manifests.

All images **must be cosign-signed** with the in-cluster key
(`flux-system/cosign-key`) — Kyverno's `verify-internal-images`
ClusterPolicy is in `Enforce` mode for everything pulled from
`zot.registry.svc.cluster.local:5000/*`.

## Per-pod response topic design

Each `wallet-bff` pod owns dedicated Kafka response topics so replies are
routed back to the originating instance.

1. `apps/wallet-bff/statefulset.yaml` is a `StatefulSet` — each pod gets
   a stable ordinal name (`wallet-bff-0`, `wallet-bff-1`, ...).
2. The downward API injects `POD_NAME` into the container.
3. Topic-related env vars are templated from `POD_NAME`:
   - `HSM_WORKER_RESPONSE_TOPIC=hsm-worker-responses-$(POD_NAME)`
   - `STATE_INIT_RESPONSE_TOPIC=state-init-responses-$(POD_NAME)`
   - `KAFKA_GROUP_ID=r2ps-rest-api-group-$(POD_NAME)`
4. Matching `KafkaTopic` resources are pre-provisioned by
   `apps/wallet-bff/topics.yaml`.

The `hsm-worker` consumes shared request topics (`hsm-requests`,
`state-init-requests`) and produces back to the per-pod response topic
carried in the request envelope.

### Scaling wallet-bff

Default replica count is `3`; topics for ordinals `0..2` are
pre-provisioned. To scale up:

1. Add new `KafkaTopic` pairs in `apps/wallet-bff/topics.yaml`
   (`hsm-worker-responses-wallet-bff-N`, `state-init-responses-wallet-bff-N`).
2. Commit and push (`make k3s-push`), then Flux reconciles.
3. Bump `spec.replicas` in `apps/wallet-bff/statefulset.yaml`.

Scaling before topics exist causes the new pod to fail on startup.

## Writing hsm-worker secrets to OpenBao

Secrets are stored in OpenBao and synced into the cluster by External
Secrets Operator. They are never committed to Git.

Create a `.env` file (not committed) with:

```
PKCS11_LIB=...
PKCS11_SLOT_TOKEN_LABEL=...
PKCS11_SO_PIN=...
PKCS11_USER_PIN=...
PKCS11_WRAP_KEY_ALIAS=...
CLIENT_PUBLIC_KEY=...
OPAQUE_SERVER_IDENTIFIER=...
OPAQUE_SERVER_SETUP=...
SERVER_PRIVATE_KEY=...
SERVER_PUBLIC_KEY=...
```

Then write to OpenBao (once after `make up`, or whenever values change):

```bash
make k3s-openbao-put
```

ESO will sync the secrets into the cluster within 1h, or immediately on
`ExternalSecret` reconcile.

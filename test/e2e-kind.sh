#!/usr/bin/env bash
# End-to-end test of the platform package (chart + smoke image) in a local kind cluster.
# Emulates what the platform's app path creates (namespace, secret affine-platform, PVC affine-data,
# Deployment affine-redis, a non-superuser Postgres login) and then:
#   1. installs the chart with the platform's values contract and runs the smoke test (first run)
#   2. restarts AFFiNE and runs the smoke test again (fixture must be found again)
#   3. with --fault: rolls out the L11 fault value (rollout must fail), reverts it, smoke test green again
set -euo pipefail

CLUSTER="affine-e2e"
NS="affine-staging"
SMOKE_IMAGE="affine-smoke:e2e"
REDIS_IMAGE="redis:7.4-alpine@sha256:8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f"
POSTGRES_IMAGE="postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESIRED="$ROOT/platform-delivery/environments/staging/affine.yaml"
FAULT="$ROOT/platform-delivery/fault-invalid-config.yaml"

usage() {
  cat <<EOF
Usage: test/e2e-kind.sh [--fault] [--keep] [--image <repo@sha256:...>]

Creates kind cluster '$CLUSTER' (reused if it exists), deploys AFFiNE like the platform would
and runs the smoke test. Needs docker, kind, kubectl, helm and python3 with PyYAML.

Options:
  --fault   Also check the non-repairable fault value from platform-delivery/fault-invalid-config.yaml.
  --keep    Keep the cluster afterwards (default: delete it).
  --image   AFFiNE image to test (default: image from the staging desired state).
EOF
}

with_fault=false
keep=false
image=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fault) with_fault=true; shift ;;
    --keep) keep=true; shift ;;
    --image) image="${2:?}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
for tool in docker kind kubectl helm python3; do command -v "$tool" >/dev/null || die "$tool not found"; done

# values_file <out> [fault]: the desired state's values, optionally with the fault value applied
values_file() {
  python3 - "$DESIRED" "$FAULT" "$@" <<'EOF'
import sys, yaml
desired, fault, out = sys.argv[1:4]
values = yaml.safe_load(open(desired))["values"]
if len(sys.argv) > 4:
    f = yaml.safe_load(open(fault))
    node = values
    for key in f["path"][:-1]:
        node = node.setdefault(key, {})
    node[f["path"][-1]] = f["value"]
    print(f"    values.{'.'.join(f['path'])} = {f['value']}")
yaml.safe_dump(values, open(out, "w"), sort_keys=False)
EOF
}
yaml_get() { python3 -c 'import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v)' "$@"; }

[[ -n "$image" ]] || image="$(yaml_get "$DESIRED" image)"
[[ "$image" =~ ^(.+)@(sha256:[0-9a-f]{64})$ ]] || die "image must be <repo>@sha256:<digest>, got '$image'"
image_repo="${BASH_REMATCH[1]}"
image_digest="${BASH_REMATCH[2]}"

work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
  if [[ "$keep" == false ]]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

step "kind cluster $CLUSTER"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
kubectl config use-context "kind-$CLUSTER" >/dev/null

step "Smoke image"
docker build -q -t "$SMOKE_IMAGE" "$ROOT/smoke" >/dev/null
kind load docker-image "$SMOKE_IMAGE" --name "$CLUSTER" >/dev/null

step "Platform resources (what the app path creates)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rand() { openssl rand -hex "$(($1 / 2))"; }
if ! kubectl -n "$NS" get secret affine-platform >/dev/null 2>&1; then
  pg_password="$(rand 32)"
  redis_password="$(rand 32)"
  kubectl -n "$NS" create secret generic e2e-postgres --from-literal=password="$pg_password" >/dev/null
  # Same keys the catalog entry maps; SMOKE_USER_PASSWORD has the platform's 40 characters
  kubectl -n "$NS" create secret generic affine-platform \
    --from-literal=DATABASE_URL="postgresql://affine:${pg_password}@e2e-postgres:5432/affine?sslmode=disable" \
    --from-literal=REDIS_SERVER_HOST="affine-redis.$NS.svc.cluster.local" \
    --from-literal=REDIS_SERVER_PASSWORD="$redis_password" \
    --from-literal=SMOKE_USER_PASSWORD="$(rand 40)" >/dev/null
  kubectl -n "$NS" create secret generic affine-redis --from-literal=password="$redis_password" >/dev/null
fi

kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: affine-data }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
# Stand-in for the foundation server: the app login owns its database but is no superuser
apiVersion: apps/v1
kind: Deployment
metadata: { name: e2e-postgres }
spec:
  selector: { matchLabels: { app: e2e-postgres } }
  template:
    metadata: { labels: { app: e2e-postgres } }
    spec:
      containers:
        - name: postgres
          image: $POSTGRES_IMAGE
          env:
            - { name: POSTGRES_PASSWORD, value: admin }
            - { name: APP_PASSWORD, valueFrom: { secretKeyRef: { name: e2e-postgres, key: password } } }
          volumeMounts: [{ name: init, mountPath: /docker-entrypoint-initdb.d }]
          readinessProbe: { exec: { command: [pg_isready, -U, postgres] }, periodSeconds: 3 }
      volumes:
        - name: init
          configMap: { name: e2e-postgres-init }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: e2e-postgres-init }
data:
  init.sh: |
    psql -v ON_ERROR_STOP=1 -U postgres -c "CREATE ROLE affine LOGIN PASSWORD '\$APP_PASSWORD';" -c "CREATE DATABASE affine OWNER affine;"
---
apiVersion: v1
kind: Service
metadata: { name: e2e-postgres }
spec:
  selector: { app: e2e-postgres }
  ports: [{ port: 5432 }]
---
# Mirrors the platform's redis data block: no persistence, password required
apiVersion: apps/v1
kind: Deployment
metadata:
  name: affine-redis
  labels: { app.kubernetes.io/name: redis, app.kubernetes.io/instance: affine-redis }
spec:
  selector: { matchLabels: { app.kubernetes.io/instance: affine-redis } }
  template:
    metadata: { labels: { app.kubernetes.io/name: redis, app.kubernetes.io/instance: affine-redis } }
    spec:
      containers:
        - name: redis
          image: $REDIS_IMAGE
          args: ["--requirepass", "\$(REDIS_PASSWORD)", "--save", "", "--appendonly", "no"]
          env: [{ name: REDIS_PASSWORD, valueFrom: { secretKeyRef: { name: affine-redis, key: password } } }]
          ports: [{ containerPort: 6379 }]
---
apiVersion: v1
kind: Service
metadata: { name: affine-redis }
spec:
  selector: { app.kubernetes.io/instance: affine-redis }
  ports: [{ port: 6379 }]
EOF
kubectl -n "$NS" rollout status deploy/e2e-postgres deploy/affine-redis --timeout=180s >/dev/null

# Values as the app path passes them: desired-state values plus the platform contract
values_file "$work/desired-values.yaml"
cat > "$work/platform-values.yaml" <<EOF
image: { repository: "$image_repo", digest: "$image_digest" }
secretName: affine-platform
imagePullSecretName: ""
rolloutMarker: e2e-$(date +%s)
platform:
  appId: affine
  environment: staging
  namespace: $NS
  host: affine.$NS.svc.cluster.local
  url: http://affine.$NS.svc.cluster.local:3010
  persistentVolumeClaim: affine-data
  replicas: 1
  resources: { requests: { cpu: 100m, memory: 512Mi }, limits: { memory: 2Gi } }
  release: { gitSha: e2e, imageDigest: "$image_digest", chartVersion: 0.0.0-e2e }
EOF

deploy() {
  helm upgrade --install affine "$ROOT/charts/affine" -n "$NS" \
    -f "$work/desired-values.yaml" -f "$work/platform-values.yaml" "$@"
}

smoke() {
  local job="smoke-$1"
  kubectl -n "$NS" delete job "$job" --ignore-not-found >/dev/null
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: { name: $job }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: smoke
          image: $SMOKE_IMAGE
          imagePullPolicy: Never
          env:
            - { name: TARGET_URL, value: "http://affine.$NS.svc.cluster.local:3010" }
            - { name: SMOKE_USER_EMAIL, value: "$(yaml_get "$ROOT/platform-delivery/catalog/affine/app.yaml" smokeTest.env.SMOKE_USER_EMAIL)" }
            - { name: SMOKE_USER_PASSWORD, valueFrom: { secretKeyRef: { name: affine-platform, key: SMOKE_USER_PASSWORD } } }
EOF
  kubectl -n "$NS" wait --for=condition=complete --timeout=300s "job/$job" >/dev/null 2>&1 ||
    kubectl -n "$NS" wait --for=condition=failed --timeout=5s "job/$job" >/dev/null 2>&1 || true
  kubectl -n "$NS" logs "job/$job" > "$work/$job.out" 2>&1 || true
  # Last line is the contract's JSON result; print the evidence, succeed only on success=true
  tail -n 1 "$work/$job.out" | python3 -c 'import json, sys
r = json.loads(sys.stdin.read() or "{}")
for e in r.get("evidence", []): print("   ", e["check"], "ok" if e["success"] else "FAILED", "-", e.get("detail", ""))
sys.exit(0 if r.get("success") is True else 1)'
}

step "Install chart and first smoke run"
deploy --wait --timeout 10m >/dev/null
smoke first || die "smoke test failed on first run (see above)"
grep -q '"detail":"angelegt' "$work/smoke-first.out" || echo "    (fixture already existed, cluster was reused)"

step "Restart AFFiNE and second smoke run (persistence)"
kubectl -n "$NS" rollout restart deploy/affine >/dev/null
kubectl -n "$NS" rollout status deploy/affine --timeout=10m >/dev/null
smoke second || die "smoke test failed after restart"
grep -q 'wiedergefunden' "$work/smoke-second.out" || die "fixture was not found again after restart"

if [[ "$with_fault" == true ]]; then
  step "Fault value (L11): rollout must fail"
  values_file "$work/desired-values.yaml" fault
  if deploy --wait --timeout 3m >/dev/null 2>&1; then die "rollout with fault value succeeded"; fi
  kubectl -n "$NS" logs deploy/affine --tail=50 2>/dev/null | grep -m1 'heap out of memory' | sed 's/^/    log: /' || true
  kubectl -n "$NS" rollout restart deploy/affine >/dev/null
  if kubectl -n "$NS" rollout status deploy/affine --timeout=90s >/dev/null 2>&1; then die "restart repaired the fault"; fi
  smoke fault && die "smoke test passed with fault value"

  step "Revert fault value"
  values_file "$work/desired-values.yaml"
  deploy --wait --timeout 10m >/dev/null
  smoke reverted || die "smoke test failed after revert"
  grep -q 'wiedergefunden' "$work/smoke-reverted.out" || die "fixture lost after fault scenario"
fi

step "OK"

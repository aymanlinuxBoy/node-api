# node-api-poc

A small Node.js + Express REST API backed by PostgreSQL, built to exercise the
DevSecOps CI/CD pipeline with real dependencies, real tests, and a real
database connection (targeting the PostgreSQL HA setup on the downstream
RKE2/Longhorn cluster).

## Endpoints

| Method | Path            | Purpose                                    |
|--------|-----------------|---------------------------------------------|
| GET    | `/health`       | Liveness probe — no DB dependency          |
| GET    | `/ready`        | Readiness probe — runs `SELECT 1` on Postgres |
| GET    | `/api/items`    | List items                                 |
| GET    | `/api/items/:id`| Get one item                               |
| POST   | `/api/items`    | Create an item (`{ "name": "...", "description": "..." }`) |
| DELETE | `/api/items/:id`| Delete an item                             |

## Run locally (Docker, no local Node.js needed)

```bash
# 1. Start Postgres
docker network create node-api-poc-net
docker run -d --name pg --network node-api-poc-net \
  -e POSTGRES_PASSWORD=postgres123 -e POSTGRES_DB=testdb \
  postgres:16-alpine

# 2. Build and run the app
docker build -t node-api-poc:local .
docker run -d --name app --network node-api-poc-net -p 3000:3000 \
  -e DB_HOST=pg -e DB_PORT=5432 -e DB_USER=postgres \
  -e DB_PASSWORD=postgres123 -e DB_NAME=testdb \
  node-api-poc:local

# 3. Test it
curl http://localhost:3000/health
curl http://localhost:3000/ready
curl -X POST http://localhost:3000/api/items \
  -H "Content-Type: application/json" \
  -d '{"name":"widget","description":"a test widget"}'
curl http://localhost:3000/api/items
```

## Run tests

```bash
docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm ci
docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm test
```

## CI/CD Pipeline

`.github/workflows/ci-security.yml` runs on every push/PR to `main`:

1. **lint-and-security**: `npm test`, `npm audit`, Hadolint, yamllint, Gitleaks, Checkov
2. **build-scan-push** (main branch only, after job 1 passes):
   Build → Trivy scan → Smoke test (`/health`, no DB required) → Push to Docker Hub →
   **sign the pushed digest with cosign (keyless)** → verify the signature

Required repo secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.

### Image signing

Images are signed with [cosign](https://docs.sigstore.dev/cosign/overview/) using
**keyless signing**: the workflow's GitHub Actions OIDC identity is exchanged for a
short-lived certificate from Sigstore's public Fulcio CA, and the signature +
certificate are recorded in the public Rekor transparency log. There's no private
signing key to store or rotate as a secret.

To verify an image was built by this repo's CI before pulling/deploying it:

```bash
cosign verify \
  --certificate-identity-regexp "^https://github.com/aymanlinuxBoy/node-api/\.github/workflows/ci-security\.yml@refs/heads/main$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  aimocont2020/node-api-poc@sha256:<digest>
```

## Deploying to Kubernetes

Manifests live under `k8s/base` (Deployment, Service, ConfigMap, ServiceAccount)
and `k8s/overlays/poc` (namespace + image override), managed with Kustomize.

**Before first deploy**, create the DB credentials secret out-of-band — do not
commit real credentials to git (see `k8s/base/secret.example.yaml` for the shape):

```bash
kubectl create secret generic node-api-poc-db-credentials \
  --namespace devsecops \
  --from-literal=DB_USER=postgres \
  --from-literal=DB_PASSWORD='<your-postgres-password>'
```

Update `k8s/base/configmap.yaml` `DB_HOST` if your PostgreSQL service name/
namespace differs from `postgres-postgresql.postgres.svc.cluster.local`.

Deploy:

```bash
kubectl apply -k k8s/overlays/poc
```

Security hardening already applied in the Deployment (from the earlier
CI/CD assessment of the sibling `app-poc` project):
- Non-root user, dropped capabilities, read-only root filesystem
- CPU/memory requests + limits
- Liveness (`/health`) and readiness (`/ready`) probes
- Dedicated ServiceAccount with `automountServiceAccountToken: false`

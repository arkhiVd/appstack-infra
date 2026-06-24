# appstack — MRO Spare Parts Store (application layer)

Internal warehouse spare-parts store running on the `appstack-infra` AWS
architecture (ECS-on-EC2, RDS, OpenSearch, SQS, S3/CloudFront, ALB). Developed
and tested **locally with Docker Compose** against the same components — real
OpenSearch and real SQS (LocalStack), not substitutes — so the whole thing runs
on a laptop with zero AWS cost.

## Run

```bash
cd app
docker compose up --build           # first run pulls images + builds services
```

Open the admin panel: **http://localhost:8090**  (admin@appstack.local / Admin123!)

Reset everything (re-seed DB, re-create queues/buckets): `docker compose down -v`
Stop: `docker compose down`

## What's running (16 containers)

| Group | Components | Maps to (AWS) |
|-------|-----------|----------------|
| Gateway | nginx `:8090` | ALB path-routing + CloudFront/S3 SPA origin |
| Services | auth `:8081`, catalog `:8082`, search `:8083`, inventory `:8084`, orders `:8085`, notification `:8086`, suppliers `:8087`, integration `:8088` | ECS tasks behind the ALB |
| Workers | search-sync-worker, pdf-ingest-worker | ECS worker tasks |
| Data | Postgres `:5432`, OpenSearch `:9200` | RDS, OpenSearch domain |
| Messaging/Storage | LocalStack `:4566` (SQS + S3) | SQS queues, S3 ingest bucket |
| Monitoring | Prometheus `:9090`, Grafana `:3000` | self-managed on the EC2 host |

All 8 microservices from the architecture diagram are live.

## The demo flow (all clickable in the panel at :8090)

1. **Search** — full-text part search served by **OpenSearch**.
2. **Catalog** — browse parts (Postgres).
3. **Bulk upload** — upload a supplier CSV. It PUTs to the **S3** ingest bucket →
   `ObjectCreated` event → **pdf-ingest SQS** → `pdf-ingest-worker` bulk-upserts to
   Postgres and publishes price-sync → new parts appear in Search within seconds.
4. **Requisitions** — raise a basket, admin **approves** → stock is deducted atomically
   via the shared ledger → search stock updates live.
5. **Low stock / Alerts** — `inventory-service` low-stock report; `notification-service`
   background monitor raises low-stock alerts.
6. **Suppliers** — vendor master data.
7. **Grafana** (`:3000`) — per-service request rate, p95 latency, 5xx, up targets.

## Architecture notes

- **.NET 8 Minimal API**, **Dapper + Npgsql** (schema via `db/init/*.sql`, no EF migrations).
- **JWT** issued by auth-service, validated by every service with a shared key; roles
  `admin` / `staff`.
- **One origin** via the nginx gateway → no CORS; path rules mirror the ALB.
- **DB + SQS integration only** between services (no service-to-service HTTP), matching
  the intended design. Canonical stock = `parts.stock_qty`, shared across catalog/
  inventory/search.
- **price-sync SQS** (catalog/inventory/orders publish → search-sync-worker → OpenSearch)
  and **pdf-ingest SQS** (S3 event → pdf-ingest-worker → Postgres) are the two pipelines
  from the `sqs_messaging` module.
- Every Dockerfile is multi-stage and reused as-is for ECR/ECS.

### On AWS (implemented & validated)
The same architecture runs on real AWS — the local pieces map 1:1:

| Local | AWS |
|-------|-----|
| nginx gateway (path routing + SPA origin) | **CloudFront** (S3 SPA origin + ALB API origin → one origin, no CORS) + **ALB** path rules |
| Docker Postgres `db/init` entrypoint | **`db-migrate`** one-shot ECS task applies the same SQL to RDS |
| LocalStack S3 `ObjectCreated:*` | real S3 event → `pdf-ingest` SQS (no suffix filter — bulk import is CSV) |
| `docker compose` services | **ECS-on-EC2** services (`ecs_services` module) |

`notification-service` polls the DB (locally and on AWS) — it can't share the
price-sync queue (competing consumers would steal messages from `search-sync-worker`);
in production this becomes SNS fan-out or its own queue.

### CI/CD — one-merge GitOps deploy (`.github/workflows/apply.yml`)
A merge to `main` runs: `terraform apply` → publish SPA to S3 + CloudFront invalidate
→ build & push 11 images to ECR → `db-migrate` → roll the 10 ECS services → print the
site URL. Tear down with `destroy.yml` (`confirm=destroy-appstack`). The standalone
`app-deploy.yml` (build/push + optional ECS rollout, `workflow_dispatch`) remains as a
manual image-refresh path.

## Layout

```
app/
  docker-compose.yml
  db/init/                 01 schema+seed … 07 integration   (applied in order)
  services/<name>/         Program.cs + Dockerfile per service/worker
  gateway/nginx.conf       ALB + CloudFront stand-in
  frontend/index.html      admin SPA (S3/CloudFront origin)
  localstack/init/         create SQS queues + S3 bucket/notification
  monitoring/              prometheus.yml + grafana provisioning/dashboards
  sample-data/             supplier-catalog.csv
```

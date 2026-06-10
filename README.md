# AppStack — Microservices Platform (AWS Infrastructure, Terraform)

Infrastructure-as-Code for a product search & management platform
(.NET microservices, Angular admin panel, React Native app). Built on AWS with
a **strict free-tier / lowest-cost focus**, fully modular Terraform.

Region: `ap-south-1` · IaC: Terraform (`~> 5.0` AWS provider)

## Architecture

```
                      Internet
                         │
        ┌────────────────┴───────────────┐
        │                                │
   CloudFront (admin SPA)           Application LB
        │                                │
     S3 (private, OAC)            ECS on EC2 (t3.micro, public subnet)
                                         │  ┌─ 8 microservices (auth/user/kyc/
                                         │  │   business/finance/subscription/
                                         │  │   notification/integration)
                                         │  ├─ pdf-ingest-worker
                                         │  ├─ search-sync-worker
                                         │  └─ Prometheus + Grafana (self-host)
                                         │
        ┌────────────────┬───────────────┼───────────────┐
        │                │               │               │
   RDS Postgres    ElastiCache       OpenSearch        SQS
   (private)        Redis (private)  (private, VPC)   price-sync / pdf-ingest
```

### Event-driven workflows
1. **PDF ingestion** — Admin uploads a 5-6k item PDF to S3 → S3 ObjectCreated
   event → `pdf-ingest` SQS queue → `pdf-ingest-worker` parses + batch-inserts
   into Postgres.
2. **DB → Search sync** — A microservice writes a price change to Postgres, then
   publishes to the `price-sync` SQS queue → `search-sync-worker` updates the
   OpenSearch document. User searches hit **OpenSearch only**, never Postgres.

## Cost strategy (free tier)

| Service | Choice | Free tier |
|---|---|---|
| Compute | ECS on **EC2 t3.micro** (not Fargate) | 750 hrs/mo |
| Database | RDS Postgres **db.t3.micro** single-AZ | 750 hrs, 20 GB |
| Cache | ElastiCache **cache.t3.micro** | 750 hrs |
| Search | OpenSearch **t3.small.search** single-node | 750 hrs, 10 GB |
| Frontend | S3 + CloudFront | 5 GB S3, 1 TB CF out |
| Messaging | SQS | 1M requests/mo |
| Registry | ECR (lifecycle: keep 5 images) | 500 MB |
| **NAT** | **None** — public-subnet ECS + S3/DynamoDB gateway endpoints | avoids ~$32/mo |
| Private access | **SSM Session Manager** (no VPN/bastion) | free |
| CI/CD | GitHub Actions + OIDC (no static keys) | free |

## Layout

```
modules/
  vpc_network/            VPC, public/private subnets, IGW, gateway endpoints, SGs
  ecr_registry/           Per-service ECR repos + lifecycle policy
  rds_postgres/           Postgres (private, logical replication on)
  elasticache_redis/      Redis (private)
  ecs_compute/            ECS cluster, EC2 ASG, ALB, IAM (incl. SSM)
  s3_cloudfront_frontend/ Admin SPA: private S3 + CloudFront OAC
  sqs_messaging/          price-sync + pdf-ingest queues, DLQs, PDF bucket events
  opensearch/             Full-text search domain (VPC, SG-locked)
environments/
  dev/                    Wires modules with free-tier sizes
bootstrap/                One-time S3 + DynamoDB remote state backend
.github/workflows/        plan (read-only) · apply (approval) · destroy (manual)
```

## Usage

```bash
# 0. One-time: create remote state backend
cd bootstrap && terraform init && terraform apply

# 1. Per environment
cd environments/dev
export TF_VAR_db_password='<strong-password>'   # never commit
terraform init
terraform plan
terraform apply
```

Security groups enforce least privilege: ALB ← internet, ECS ← ALB only,
data tier (RDS/Redis/OpenSearch) ← ECS only. No public IPs on databases.

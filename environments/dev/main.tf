# =============================================================================
# DEV environment - wires modules with free-tier sizes.
# Build modules one at a time: uncomment as each is written + tested.
# =============================================================================

module "vpc_network" {
  source       = "../../modules/vpc_network"
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
}

module "ecr_registry" {
  source       = "../../modules/ecr_registry"
  project_name = var.project_name
}

module "rds_postgres" {
  source                = "../../modules/rds_postgres"
  project_name          = var.project_name
  subnet_ids            = module.vpc_network.private_subnet_ids
  vpc_security_group_id = module.vpc_network.data_sg_id
  db_password           = var.db_password

  depends_on = [module.vpc_network]
}

module "elasticache_redis" {
  source            = "../../modules/elasticache_redis"
  project_name      = var.project_name
  subnet_ids        = module.vpc_network.private_subnet_ids
  security_group_id = module.vpc_network.data_sg_id

  depends_on = [module.vpc_network]
}

module "ecs_compute" {
  source            = "../../modules/ecs_compute"
  project_name      = var.project_name
  vpc_id            = module.vpc_network.vpc_id
  public_subnet_ids = module.vpc_network.public_subnet_ids
  alb_sg_id         = module.vpc_network.alb_sg_id
  ecs_sg_id         = module.vpc_network.ecs_sg_id

  depends_on = [module.vpc_network]
}

module "s3_cloudfront_frontend" {
  source       = "../../modules/s3_cloudfront_frontend"
  project_name = var.project_name
}

module "sqs_messaging" {
  source       = "../../modules/sqs_messaging"
  project_name = var.project_name
}

module "opensearch" {
  source            = "../../modules/opensearch"
  project_name      = var.project_name
  subnet_id         = module.vpc_network.private_subnet_ids[0]
  security_group_id = module.vpc_network.data_sg_id

  depends_on = [module.vpc_network]
}

module "ecs_services" {
  source = "../../modules/ecs_services"

  project_name            = var.project_name
  region                  = var.region
  vpc_id                  = module.vpc_network.vpc_id
  cluster_arn             = module.ecs_compute.cluster_arn
  alb_listener_arn        = module.ecs_compute.http_listener_arn
  task_execution_role_arn = module.ecs_compute.task_execution_role_arn
  ecr_repository_urls     = module.ecr_registry.repository_urls
  image_tag               = var.image_tag
  worker_policy_arn       = module.sqs_messaging.worker_policy_arn

  db_host               = module.rds_postgres.address
  db_name               = module.rds_postgres.db_name
  db_password           = var.db_password
  opensearch_endpoint   = module.opensearch.endpoint
  price_sync_queue_name = "${var.project_name}-price-sync"
  pdf_ingest_queue_name = "${var.project_name}-pdf-ingest"
  jwt_key               = var.jwt_key

  depends_on = [
    module.ecs_compute,
    module.rds_postgres,
    module.opensearch,
    module.sqs_messaging,
    module.ecr_registry,
  ]
}


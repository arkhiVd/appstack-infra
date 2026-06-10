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


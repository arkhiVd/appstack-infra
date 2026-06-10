output "vpc_id" {
  value = module.vpc_network.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc_network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc_network.private_subnet_ids
}

output "alb_sg_id" {
  value = module.vpc_network.alb_sg_id
}

output "ecs_sg_id" {
  value = module.vpc_network.ecs_sg_id
}

output "data_sg_id" {
  value = module.vpc_network.data_sg_id
}

output "ecr_repository_urls" {
  value = module.ecr_registry.repository_urls
}

output "rds_endpoint" {
  value = module.rds_postgres.endpoint
}

output "rds_db_name" {
  value = module.rds_postgres.db_name
}

output "redis_endpoint" {
  value = module.elasticache_redis.endpoint
}

output "ecs_cluster_name" {
  value = module.ecs_compute.cluster_name
}

output "alb_dns_name" {
  value = module.ecs_compute.alb_dns_name
}

output "admin_bucket_name" {
  value = module.s3_cloudfront_frontend.bucket_name
}

output "admin_cloudfront_domain" {
  value = module.s3_cloudfront_frontend.cloudfront_domain_name
}

output "price_sync_queue_url" {
  value = module.sqs_messaging.price_sync_queue_url
}

output "pdf_ingest_queue_url" {
  value = module.sqs_messaging.pdf_ingest_queue_url
}

output "pdf_bucket_name" {
  value = module.sqs_messaging.pdf_bucket_name
}

output "opensearch_endpoint" {
  value = module.opensearch.endpoint
}

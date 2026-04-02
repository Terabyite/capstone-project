output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "kops_state_bucket" {
  value = module.s3.kops_state_bucket
}

output "etcd_backups_bucket" {
  value = module.s3.etcd_backups_bucket
}

output "route53_nameservers" {
  description = "Set these NS records at your domain registrar"
  value       = module.dns.main_zone_nameservers
}

output "k8s_zone_id" {
  value = module.dns.k8s_zone_id
}

output "cluster_name" {
  value = local.cluster_name
}

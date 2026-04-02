output "main_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "main_zone_nameservers" {
  value = aws_route53_zone.main.name_servers
}

output "k8s_zone_id" {
  value = aws_route53_zone.k8s.zone_id
}

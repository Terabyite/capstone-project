resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Managed by Terraform"
  tags    = var.tags
}

resource "aws_route53_zone" "k8s" {
  name    = "k8s.${var.domain_name}"
  comment = "Kubernetes cluster subdomain"
  tags    = var.tags
}

resource "aws_route53_record" "k8s_delegation" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "k8s.${var.domain_name}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.k8s.name_servers
}

resource "aws_route53_record" "taskapp" {
  count   = var.ingress_lb_hostname != "" ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "taskapp.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.ingress_lb_hostname]
}

resource "aws_route53_record" "api" {
  count   = var.ingress_lb_hostname != "" ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.ingress_lb_hostname]
}

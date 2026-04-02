aws_region   = "us-east-1"
project_name = "taskapp"
domain_name  = "terabbyte.online"

vpc_cidr = "10.0.0.0/16"

availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]

single_nat_gateway  = false
ingress_lb_hostname = ""

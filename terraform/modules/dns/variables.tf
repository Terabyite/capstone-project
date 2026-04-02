variable "domain_name" {
  type = string
}

variable "ingress_lb_hostname" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

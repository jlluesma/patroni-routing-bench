variable "project_id" {
  type = string
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type    = string
  default = "prb-subnet"
}

variable "subnet_cidr" {
  type = string
}

variable "region" {
  type = string
}

variable "admin_cidr" {
  description = "Source CIDR for SSH and external access"
  type        = string
}

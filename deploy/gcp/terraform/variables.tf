variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west1-b"
}

variable "machine_type_patroni" {
  description = "Machine type for Patroni/PostgreSQL nodes"
  type        = string
  default     = "e2-medium"
}

variable "machine_type_consul" {
  description = "Machine type for Consul server"
  type        = string
  default     = "e2-small"
}

variable "machine_type_haproxy" {
  description = "Machine type for HAProxy"
  type        = string
  default     = "e2-small"
}

variable "machine_type_observer" {
  description = "Machine type for observer VM"
  type        = string
  default     = "e2-medium"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "boot_disk_type" {
  description = "Boot disk type"
  type        = string
  default     = "pd-ssd"
}

variable "os_image" {
  description = "OS image"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "network_name" {
  description = "VPC network name"
  type        = string
  default     = "prb-network"
}

variable "subnet_cidr" {
  description = "Subnet CIDR block"
  type        = string
  default     = "10.0.1.0/24"
}

variable "admin_cidr" {
  description = "CIDR allowed for SSH and external access (your IP). Use x.x.x.x/32 for a single IP."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_user" {
  description = "SSH username created on VMs"
  type        = string
  default     = "deploy"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

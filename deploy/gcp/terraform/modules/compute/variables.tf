variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "name" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "os_image" {
  type = string
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "disk_type" {
  type    = string
  default = "pd-ssd"
}

variable "subnetwork_self_link" {
  type = string
}

variable "internal_ip" {
  description = "Static internal IP address"
  type        = string
}

variable "tags" {
  description = "Network tags"
  type        = list(string)
  default     = []
}

variable "ssh_user" {
  type = string
}

variable "ssh_public_key" {
  description = "SSH public key content (not path)"
  type        = string
}

variable "role" {
  description = "Role label (patroni, consul, haproxy, observer)"
  type        = string
}

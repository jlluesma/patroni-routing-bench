terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

locals {
  ssh_public_key = file(var.ssh_public_key_path)

  # Static internal IPs — referenced by Ansible group_vars and .env.gcp
  ip = {
    patroni_1  = "10.0.1.10"
    patroni_2  = "10.0.1.11"
    patroni_3  = "10.0.1.12"
    consul_srv = "10.0.1.20"
    haproxy    = "10.0.1.30"
    observer   = "10.0.1.40"
  }
}

module "network" {
  source       = "./modules/network"
  project_id   = var.project_id
  network_name = var.network_name
  subnet_cidr  = var.subnet_cidr
  region       = var.region
  admin_cidr   = var.admin_cidr
}

module "patroni_1" {
  source               = "./modules/compute"
  project_id           = var.project_id
  zone                 = var.zone
  name                 = "patroni-1"
  machine_type         = var.machine_type_patroni
  os_image             = var.os_image
  disk_size_gb         = var.boot_disk_size_gb
  disk_type            = var.boot_disk_type
  subnetwork_self_link = module.network.subnetwork_self_link
  internal_ip          = local.ip.patroni_1
  tags                 = ["patroni"]
  ssh_user             = var.ssh_user
  ssh_public_key       = local.ssh_public_key
  role                 = "patroni"
}

module "patroni_2" {
  source               = "./modules/compute"
  project_id           = var.project_id
  zone                 = var.zone
  name                 = "patroni-2"
  machine_type         = var.machine_type_patroni
  os_image             = var.os_image
  disk_size_gb         = var.boot_disk_size_gb
  disk_type            = var.boot_disk_type
  subnetwork_self_link = module.network.subnetwork_self_link
  internal_ip          = local.ip.patroni_2
  tags                 = ["patroni"]
  ssh_user             = var.ssh_user
  ssh_public_key       = local.ssh_public_key
  role                 = "patroni"
}

module "patroni_3" {
  source               = "./modules/compute"
  project_id           = var.project_id
  zone                 = var.zone
  name                 = "patroni-3"
  machine_type         = var.machine_type_patroni
  os_image             = var.os_image
  disk_size_gb         = var.boot_disk_size_gb
  disk_type            = var.boot_disk_type
  subnetwork_self_link = module.network.subnetwork_self_link
  internal_ip          = local.ip.patroni_3
  tags                 = ["patroni"]
  ssh_user             = var.ssh_user
  ssh_public_key       = local.ssh_public_key
  role                 = "patroni"
}

module "consul_srv" {
  source               = "./modules/compute"
  project_id           = var.project_id
  zone                 = var.zone
  name                 = "consul-srv"
  machine_type         = var.machine_type_consul
  os_image             = var.os_image
  disk_size_gb         = var.boot_disk_size_gb
  disk_type            = var.boot_disk_type
  subnetwork_self_link = module.network.subnetwork_self_link
  internal_ip          = local.ip.consul_srv
  tags                 = ["consul"]
  ssh_user             = var.ssh_user
  ssh_public_key       = local.ssh_public_key
  role                 = "consul"
}

module "haproxy" {
  source               = "./modules/compute"
  project_id           = var.project_id
  zone                 = var.zone
  name                 = "haproxy"
  machine_type         = var.machine_type_haproxy
  os_image             = var.os_image
  disk_size_gb         = var.boot_disk_size_gb
  disk_type            = var.boot_disk_type
  subnetwork_self_link = module.network.subnetwork_self_link
  internal_ip          = local.ip.haproxy
  tags                 = ["haproxy"]
  ssh_user             = var.ssh_user
  ssh_public_key       = local.ssh_public_key
  role                 = "haproxy"
}

module "observer" {
  source               = "./modules/compute"
  project_id           = var.project_id
  zone                 = var.zone
  name                 = "observer"
  machine_type         = var.machine_type_observer
  os_image             = var.os_image
  disk_size_gb         = var.boot_disk_size_gb
  disk_type            = var.boot_disk_type
  subnetwork_self_link = module.network.subnetwork_self_link
  internal_ip          = local.ip.observer
  tags                 = ["observer"]
  ssh_user             = var.ssh_user
  ssh_public_key       = local.ssh_public_key
  role                 = "observer"
}

# Generate Ansible inventory from actual IPs
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/gcp.ini"
  content  = <<-INI
    [patroni]
    patroni-1 ansible_host=${module.patroni_1.external_ip} internal_ip=${local.ip.patroni_1}
    patroni-2 ansible_host=${module.patroni_2.external_ip} internal_ip=${local.ip.patroni_2}
    patroni-3 ansible_host=${module.patroni_3.external_ip} internal_ip=${local.ip.patroni_3}

    [consul]
    consul-srv ansible_host=${module.consul_srv.external_ip} internal_ip=${local.ip.consul_srv}

    [haproxy]
    haproxy ansible_host=${module.haproxy.external_ip} internal_ip=${local.ip.haproxy}

    [observer]
    observer ansible_host=${module.observer.external_ip} internal_ip=${local.ip.observer}

    [all:vars]
    ansible_user=${var.ssh_user}
    ansible_ssh_private_key_file=~/.ssh/id_rsa
    ansible_ssh_common_args='-o StrictHostKeyChecking=no'
  INI
}

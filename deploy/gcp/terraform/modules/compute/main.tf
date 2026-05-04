resource "google_compute_instance" "vm" {
  project      = var.project_id
  zone         = var.zone
  name         = var.name
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    subnetwork = var.subnetwork_self_link
    network_ip = var.internal_ip

    access_config {
      # Ephemeral public IP — restrict via firewall, not here
    }
  }

  metadata = {
    ssh-keys               = "${var.ssh_user}:${var.ssh_public_key}"
    block-project-ssh-keys = "true"
  }

  tags = var.tags

  labels = {
    role = var.role
    env  = "prb"
  }

  # Allow stopping for machine type changes
  allow_stopping_for_update = true
}

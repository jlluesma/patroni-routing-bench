resource "google_compute_network" "prb" {
  project                 = var.project_id
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "prb" {
  project       = var.project_id
  name          = var.subnet_name
  network       = google_compute_network.prb.self_link
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# --- Internal rules (within the subnet) ---

resource "google_compute_firewall" "internal" {
  project  = var.project_id
  name     = "${var.network_name}-internal"
  network  = google_compute_network.prb.self_link
  priority = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}

# --- SSH from admin CIDR ---

resource "google_compute_firewall" "ssh" {
  project  = var.project_id
  name     = "${var.network_name}-ssh"
  network  = google_compute_network.prb.self_link
  priority = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["patroni", "consul", "haproxy", "observer"]
}

# --- External access to observer (Grafana, TimescaleDB) ---

resource "google_compute_firewall" "observer_external" {
  project  = var.project_id
  name     = "${var.network_name}-observer-external"
  network  = google_compute_network.prb.self_link
  priority = 1000

  allow {
    protocol = "tcp"
    ports    = ["3000", "5433"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["observer"]
}

# --- External access to HAProxy (PostgreSQL via HAProxy) ---

resource "google_compute_firewall" "haproxy_external" {
  project  = var.project_id
  name     = "${var.network_name}-haproxy-external"
  network  = google_compute_network.prb.self_link
  priority = 1000

  allow {
    protocol = "tcp"
    ports    = ["5000", "5001", "8404"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["haproxy"]
}

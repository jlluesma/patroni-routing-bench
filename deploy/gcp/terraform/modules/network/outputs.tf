output "network_self_link" {
  value = google_compute_network.prb.self_link
}

output "subnetwork_self_link" {
  value = google_compute_subnetwork.prb.self_link
}

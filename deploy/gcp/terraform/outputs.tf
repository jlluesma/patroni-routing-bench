output "patroni_1_external_ip" {
  value = module.patroni_1.external_ip
}

output "patroni_2_external_ip" {
  value = module.patroni_2.external_ip
}

output "patroni_3_external_ip" {
  value = module.patroni_3.external_ip
}

output "consul_external_ip" {
  value = module.consul_srv.external_ip
}

output "haproxy_external_ip" {
  value = module.haproxy.external_ip
}

output "observer_external_ip" {
  value = module.observer.external_ip
}

output "ssh_commands" {
  description = "SSH commands for each VM"
  value = {
    patroni_1  = "ssh ${var.ssh_user}@${module.patroni_1.external_ip}"
    patroni_2  = "ssh ${var.ssh_user}@${module.patroni_2.external_ip}"
    patroni_3  = "ssh ${var.ssh_user}@${module.patroni_3.external_ip}"
    consul_srv = "ssh ${var.ssh_user}@${module.consul_srv.external_ip}"
    haproxy    = "ssh ${var.ssh_user}@${module.haproxy.external_ip}"
    observer   = "ssh ${var.ssh_user}@${module.observer.external_ip}"
  }
}

output "haproxy_stats_url" {
  value = "http://${module.haproxy.external_ip}:8404/stats"
}

output "consul_ui_url" {
  value = "http://${module.consul_srv.external_ip}:8500/ui"
}

output "pg_connstring_haproxy" {
  description = "psql connection string through HAProxy (from your machine)"
  value       = "host=${module.haproxy.external_ip} port=5000 dbname=postgres user=postgres password=postgres connect_timeout=5"
}

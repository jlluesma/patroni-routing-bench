# failure_injection role

Injects and recovers from failure scenarios on a Patroni cluster running on GCP VMs.
Called via `inject.yml` playbook — do not include directly in `site.yml`.

## Scenarios

| Scenario | Mechanism | Recovery |
|---|---|---|
| `hard_stop` | `systemctl stop patroni` (SIGTERM) | `systemctl start patroni` |
| `hard_kill` | `kill -9` Patroni + PostgreSQL postmaster | `systemctl start patroni` |
| `switchover` | `patronictl switchover --force` | Automatic (planned) |
| `network_partition` | `iptables DROP` on cluster subnet | `iptables -F` |
| `postgres_crash` | `kill -9` postmaster only, Patroni stays up | Patroni auto-restarts |

## Usage

```bash
# Inject failure on patroni-1
ansible-playbook -i inventory/gcp.ini inject.yml \
    -e scenario=hard_stop \
    -e target=patroni-1

# Recover patroni-1
ansible-playbook -i inventory/gcp.ini inject.yml \
    -e scenario=hard_stop \
    -e recover=true \
    -e target=patroni-1

# Full network partition (all cluster traffic blocked)
ansible-playbook -i inventory/gcp.ini inject.yml \
    -e scenario=network_partition \
    -e target=patroni-1

# Asymmetric partition (block only consul-srv and patroni-2)
ansible-playbook -i inventory/gcp.ini inject.yml \
    -e scenario=network_partition \
    -e partition_mode=asymmetric \
    -e '{"partition_block_ips": ["10.0.1.20", "10.0.1.11"]}' \
    -e target=patroni-1

# Recover from partition
ansible-playbook -i inventory/gcp.ini inject.yml \
    -e scenario=network_partition \
    -e recover=true \
    -e target=patroni-1
```

Or via the wrapper script (recommended):

```bash
cd deploy/gcp
./scripts/failover-test.sh --scenario network_partition --target patroni-1
./scripts/failover-test.sh --scenario network_partition --target patroni-1 --recover
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `scenario` | — | Scenario name (required unless `recover=true`) |
| `recover` | `false` | Run recovery actions instead of injection |
| `cluster_subnet` | `10.0.1.0/24` | Subnet to block for full partition |
| `partition_mode` | `full` | `full` or `asymmetric` |
| `partition_block_ips` | `[]` | IPs to block for asymmetric partition |
| `patroni_service` | `patroni` | systemd service name |
| `pg_data_dir` | `/var/lib/postgresql/18/main` | PostgreSQL data dir (for postmaster.pid) |
| `recovery_wait_seconds` | `10` | Pause after recovery actions |

## Notes on network_partition recovery

`recover.yml` always flushes all INPUT and OUTPUT iptables rules (`-F`). This
is safe for the benchmark environment because the VMs have no other custom
firewall rules — GCP firewall handles external access, not iptables. On a
hardened VM with existing iptables rules, use `-D` to delete specific rules
instead.

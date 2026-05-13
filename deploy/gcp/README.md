# deploy/gcp — Patroni Routing Bench on GCP

Deploy a real Patroni + Consul cluster on GCP Compute Engine VMs and run
the `tool/` measurement suite against it. This validates benchmark results
on production-representative infrastructure: real VMs, real networking, no
Docker overlay.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  GCP VPC (10.0.1.0/24)                                      │
│                                                             │
│  patroni-1 (10.0.1.10)   patroni-2 (10.0.1.11)             │
│  patroni-3 (10.0.1.12)   consul-srv (10.0.1.20)            │
│  haproxy   (10.0.1.30)   observer  (10.0.1.40)             │
│                                                             │
│  observer VM:                                               │
│    docker compose up (tool/)                                │
│    ├── observer-patroni  → 10.0.1.10-12:8008               │
│    ├── observer-consul   → 10.0.1.20:8500                   │
│    ├── observer-haproxy  → 10.0.1.30:8404                   │
│    ├── observer-postgres → 10.0.1.10-12:5432                │
│    ├── client-failover   → 10.0.1.30:5000                   │
│    └── timescaledb + charts                                 │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth login`)
- Terraform >= 1.5 (`brew install terraform` or [tfenv](https://github.com/tfutils/tfenv))
- Ansible >= 2.14 (`pip install ansible`)
- SSH key pair at `~/.ssh/id_rsa` (or configure `ssh_public_key_path` in tfvars)

## Quick Start

```bash
# 1. Deploy infrastructure (~3 min)
cd deploy/gcp/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit: set project_id, optionally restrict admin_cidr to your IP
terraform init
terraform apply

# 2. Configure the cluster (~5 min)
cd ../ansible
ansible-playbook -i inventory/gcp.ini site.yml

# 3. Verify the cluster
ansible patroni -i inventory/gcp.ini -m shell \
    -a "patronictl -c /etc/patroni/patroni.yml list" --become -l patroni-1

# 4. Start the observer tool (from your laptop, no SSH needed)
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=start
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=start-client

# 5. Trigger a failover (auto-discovers leader)
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=hard_stop

# 6. Check results
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=query \
    -e "sql=SELECT * FROM failover_window ORDER BY first_failure DESC LIMIT 5;"

# 7. Recover the stopped node
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=hard_stop -e recover=true -e target=patroni-1

# 8. Generate and download the report
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=generate-report
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=download-report
# Report saved to deploy/gcp/results/batch_report.html

# 9. Tear down everything
cd ../terraform
terraform destroy
```

## Directory Structure

```
deploy/gcp/
├── README.md
├── terraform/
│   ├── main.tf                   # VMs, network, inventory generation
│   ├── variables.tf
│   ├── outputs.tf                # IPs, SSH commands, connection strings
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── network/              # VPC, subnet, firewall rules
│       └── compute/              # Generic VM instance module
├── ansible/
│   ├── site.yml                  # Main playbook
│   ├── inventory/
│   │   └── gcp.ini.example       # Template (Terraform writes actual gcp.ini)
│   ├── group_vars/
│   │   ├── all.yml               # IP addresses, repo URL
│   │   ├── patroni.yml           # PostgreSQL + Patroni config
│   │   ├── consul.yml            # Consul version + settings
│   │   └── haproxy.yml           # HAProxy health check params
│   └── roles/
│       ├── common/               # Packages, NTP, sysctl
│       ├── consul/               # Consul server + agent
│       ├── postgresql/           # PostgreSQL 18 from PGDG
│       ├── patroni/              # Patroni + systemd unit
│       ├── haproxy/              # HAProxy + health checks
│       └── observer/             # Docker + tool/ clone + .env.gcp
└── scripts/
    ├── failover-test.sh          # Trigger failure scenarios via SSH
    └── teardown.sh               # Stop tool stack + terraform destroy
```

## Cost Estimate

| Resource | Count | Type | $/hr | Monthly (8h/day) |
|---|---|---|---|---|
| Patroni VMs | 3 | e2-medium | $0.034 | ~$16 |
| Consul VM | 1 | e2-small | $0.017 | ~$4 |
| HAProxy VM | 1 | e2-small | $0.017 | ~$4 |
| Observer VM | 1 | e2-medium | $0.034 | ~$5 |
| **Total** | **6** | | **~$0.17/hr** | **~$29/mo** |

A typical test session (~2 hours): **~$0.35**. Always run `terraform destroy`
when done.

## Failover Scenarios

```bash
# hard_stop — graceful Patroni shutdown (SIGTERM)
./scripts/failover-test.sh --scenario hard_stop --target patroni-1
./scripts/failover-test.sh --scenario hard_stop --target patroni-1 --recover

# hard_kill — abrupt crash (SIGKILL), no cleanup
./scripts/failover-test.sh --scenario hard_kill --target patroni-1
./scripts/failover-test.sh --scenario hard_kill --target patroni-1 --recover

# switchover — planned, orchestrated (no recovery needed)
./scripts/failover-test.sh --scenario switchover --target patroni-1

# network_partition — real iptables DROP (not Docker disconnect)
./scripts/failover-test.sh --scenario network_partition --target patroni-1
./scripts/failover-test.sh --scenario network_partition --target patroni-1 --recover
```

Or directly via SSH if you prefer explicit control:

```bash
# hard_stop
ssh deploy@PATRONI_1_IP "sudo systemctl stop patroni"

# hard_kill
ssh deploy@PATRONI_1_IP "sudo kill -9 \$(pgrep -f patroni); sudo kill -9 \$(pgrep -o postgres) || true"

# network_partition
ssh deploy@PATRONI_1_IP "sudo iptables -A INPUT -s 10.0.1.0/24 -j DROP && sudo iptables -A OUTPUT -d 10.0.1.0/24 -j DROP"
# Recover:
ssh deploy@PATRONI_1_IP "sudo iptables -F INPUT && sudo iptables -F OUTPUT"

# switchover
ssh deploy@PATRONI_1_IP "patronictl -c /etc/patroni/patroni.yml switchover --master patroni-1 --force"
```

## Full Workflow (from your laptop)

All commands run from `deploy/gcp/ansible/`.

### 1. Start observers

```bash
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=start
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=start-client
```

### 2. Check cluster state

```bash
ansible patroni -i inventory/gcp.ini -m shell \
    -a "patronictl -c /etc/patroni/patroni.yml list" --become -l patroni-1
```

### 3. Inject failure (auto-discovers leader)

```bash
# Stop the leader gracefully
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=hard_stop

# Or target a specific node
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=hard_stop -e target=patroni-2

# Other scenarios
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=hard_kill
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=switchover
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=network_partition
ansible-playbook -i inventory/gcp.ini inject.yml -e scenario=postgres_crash
```

### 4. Check results

```bash
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=query \
    -e "sql=SELECT * FROM failover_window ORDER BY first_failure DESC LIMIT 5;"
```

### 5. Recovery

```bash
ansible-playbook -i inventory/gcp.ini inject.yml \
    -e scenario=hard_stop -e recover=true -e target=patroni-1
```

### 6. View observer logs

```bash
ansible-playbook -i inventory/gcp.ini observer.yml \
    -e obs_action=logs -e container=prb-obs-patroni
```

Available containers: `prb-obs-patroni`, `prb-obs-consul`, `prb-obs-haproxy`,
`prb-obs-postgres`, `prb-client-failover`, `prb-timescaledb`.

### 7. Generate and download report

```bash
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=generate-report
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=download-report
# Report saved to deploy/gcp/results/batch_report.html

# Specific batch directory
ansible-playbook -i inventory/gcp.ini observer.yml \
    -e obs_action=generate-report -e batch_dir=batch_20260429_220606
```

### 8. Clean up before next batch

```bash
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=truncate
```

Truncates `observer_events`, `client_events`, and `test_runs` — clean slate
for the next batch without restarting containers.

### 9. Stop everything

```bash
ansible-playbook -i inventory/gcp.ini observer.yml -e obs_action=stop
```

---

## NTP Verification

GCP VMs use Google's NTP (`metadata.google.internal`) by default. Verify
synchronization before running tests — accurate clocks are required for
meaningful Gantt charts.

```bash
# On each Patroni node:
timedatectl status | grep "synchronized"
# Expected: System clock synchronized: yes

chronyc tracking | grep "System time"
# Expected: offset < 1ms on GCP
```

## Key Differences from Docker Benchmark

| Aspect | Docker (benchmark lab) | GCP (this) |
|---|---|---|
| Networking | Docker bridge overlay | Real VPC, no NAT overhead |
| ARP/VIP | Slow Docker bridge ARP | Real ARP, sub-ms |
| CPU | Shared host CPU | Dedicated e2 vCPU |
| Disk | Docker overlay2 | pd-ssd |
| NTP | Containers share host clock | Google NTP, <1ms skew |
| Network partition | `docker disconnect` (unreliable) | `iptables DROP` (real) |
| Cost | Free | ~$0.17/hr |

Expected impact on results:
- VIP combos (03, 04): **faster** — real ARP vs Docker bridge
- HAProxy combos: **similar** — health check timing unchanged
- Network partition: **works reliably** — iptables is authoritative
- Variance: **lower** — dedicated resources, no WSL2 overhead

## Troubleshooting

**Terraform fails on internal IP conflict:** another resource may hold
`10.0.1.x` in your VPC. Change `locals.ip` in `main.tf` to unused addresses.

**Ansible fails with "unreachable":** VMs may still be booting. Wait 60s
after `terraform apply` and retry.

**Patroni won't form a cluster:** check Consul is healthy first:
```bash
ssh deploy@CONSUL_IP "consul members"
ssh deploy@PATRONI_1_IP "consul members"   # agent must see the server
```

**HAProxy shows all backends DOWN:** Patroni may not have elected a
primary yet. Wait 30–60s and check:
```bash
ssh deploy@PATRONI_1_IP "patronictl -c /etc/patroni/patroni.yml list"
curl http://PATRONI_1_IP:8008/primary   # should return 200 on the leader
```

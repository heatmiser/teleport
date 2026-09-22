# Teleport Containerized Deployment & Automation Guide

This directory contains the Systemd Quadlet unit definitions, Ansible deployment automation, and custom container definitions for deploying Teleport in a production-grade Split Architecture backed by PostgreSQL and FreeIPA / Red Hat IdM.

---

## 1. Architecture & Design Overview

Teleport is deployed in a **Split Architecture** separating the external DMZ Proxy from the internal Auth Server and PostgreSQL state backend.

```text
                  DMZ (External Network)                         INTERNAL LAB (Private Network)
┌─────────────────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────────┐
│  Podman Quadlet: teleport-proxy.container               │   │  Podman Quadlet: teleport-auth.container                │
│  - Service: Proxy (`proxy_service.enabled: true`)       │   │  - Service: Auth (`auth_service.enabled: true`)         │
│  - Listener: Web UI & API (3023/tcp)                    │   │  - Listener: Auth API (3025/tcp)                        │
│  - Listener: SSH Proxy (3022/tcp)                       │   │  - Storage: PostgreSQL Backend (`pgbk`)                 │
│  - Listener: Reverse Tunnel Proxy (3024/tcp)            │   │  - Identity: FreeIPA LDAPS (`idm.internal.lab:636`)     │
└────────────────────────────┬────────────────────────────┘   └────────────────────────────┬────────────────────────────┘
                             │                                                             │
                             │ Outbound Reverse Tunnel                                     │
                             │ (Port 3024 mTLS)                                            │
                             └──────────────────────────────┬──────────────────────────────┘
                                                            │
                                                            │
                              INTERNAL INFRASTRUCTURE SERVICES (Private Subnet)
┌───────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────┐
│                                                                                                                       │
│  ┌───────────────────────────────────────────────────┐           ┌─────────────────────────────────────────────────┐  │
│  │  Podman Quadlet: postgresql.container             │           │  FreeIPA / Red Hat IdM (Identity & PKI)         │  │
│  │  - Image: `localhost/teleport-postgres:latest`    │           │  - Web UI TLS Certificates                      │  │
│  │  - Engine: PostgreSQL 15 + `wal2json`             │           │  - User Directory & Authentication (LDAPS)      │  │
│  │  - Config: `wal_level = logical`                  │           │  - Role / Group Mapping                         │  │
│  │  - Databases: `teleport_state`, `teleport_audit`  │           │                                                 │  │
│  └───────────────────────────────────────────────────┘           └─────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Port Allocation Summary

| Service | Port | Direction | Description |
| :--- | :--- | :--- | :--- |
| **Proxy Web UI** | `3023/tcp` | Inbound DMZ | Teleport Web Console & HTTPS API |
| **Proxy SSH** | `3022/tcp` | Inbound DMZ | Teleport SSH Proxy Listener |
| **Proxy Reverse Tunnel** | `3024/tcp` | Inbound DMZ | Outbound mTLS tunnel listener for internal Auth/Nodes |
| **Auth API** | `3025/tcp` | Internal Only | Cluster Management API |
| **PostgreSQL DB** | `5432/tcp` | Internal Only | State & Audit Log Database |
| **FreeIPA LDAPS** | `636/tcp` | Internal Only | Directory Authentication |

---

## 2. Container Images

### A. Teleport Runtime Image (`localhost/teleport:latest`)
- **Containerfile:** `build.assets/Containerfile.ubi`
- **Base:** `registry.access.redhat.com/ubi9/ubi-minimal:latest`
- **User:** Non-root UID/GID `10007:10007`
- **PQC / FIPS Compliance:** Binaries compiled in `buildbox-centosstream9` dynamically link against RHEL OpenSSL 3.x, inheriting host RHEL/Fedora Post-Quantum Cryptography policies (`update-crypto-policies --set PQC`).

### B. PostgreSQL State Backend Image (`localhost/teleport-postgres:latest`)
- **Containerfile:** `deploy/quadlet/Containerfile.postgres`
- **Base:** `registry.redhat.io/rhel9/postgresql-15:9.8-1788330321`
- **Extension:** Installs PGDG `wal2json_15` logical decoding plugin and symlinks `/usr/pgsql-15/lib/wal2json.so` to `/usr/lib64/pgsql/wal2json.so`.
- **Runtime Command:** Executed via `run-postgresql -c wal_level=logical`.

---

## 3. Stage 1 Sandbox Verification (Single Host)

To verify the stack locally before deploying across the virtual network fabric:

### 1. Build Container Images
```bash
podman build -t localhost/teleport:latest -f build.assets/Containerfile.ubi .
podman build -t localhost/teleport-postgres:latest -f deploy/quadlet/Containerfile.postgres .
```

### 2. Create Podman Network & Volumes
```bash
podman network create teleport-net
mkdir -p /tmp/teleport-sandbox/etc
```

### 3. Launch PostgreSQL
```bash
podman run -d \
  --name sandbox-postgres \
  --network teleport-net \
  --network-alias postgres.internal.lab \
  -e POSTGRESQL_USER=teleport_user \
  -e POSTGRESQL_PASSWORD=SandboxPassword123! \
  -e POSTGRESQL_DATABASE=teleport_state \
  -v sandbox-db-data:/var/lib/pgsql/data:Z \
  localhost/teleport-postgres:latest \
  run-postgresql -c wal_level=logical

sleep 5

podman exec -i sandbox-postgres psql -U postgres -d postgres -c "ALTER USER teleport_user WITH REPLICATION;"
podman exec -i sandbox-postgres psql -U postgres -d postgres -c "CREATE DATABASE teleport_audit WITH OWNER teleport_user;"
podman exec -i sandbox-postgres psql -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE teleport_state TO teleport_user;"
podman exec -i sandbox-postgres psql -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE teleport_audit TO teleport_user;"
```

### 4. Copy Sandbox Configurations & Launch Auth / Proxy
```bash
cp tmp/sandbox-auth.yaml /tmp/teleport-sandbox/etc/teleport-auth.yaml
cp tmp/sandbox-proxy.yaml /tmp/teleport-sandbox/etc/teleport-proxy.yaml

podman run -d \
  --name sandbox-auth \
  --network teleport-net \
  --network-alias auth.internal.lab \
  -v /tmp/teleport-sandbox/etc/teleport-auth.yaml:/etc/teleport/teleport.yaml:Z \
  -v sandbox-auth-data:/var/lib/teleport:Z \
  localhost/teleport:latest

sleep 5

podman run -d \
  --name sandbox-proxy \
  --network teleport-net \
  -p 3023:3023 \
  -p 3022:3022 \
  -v /tmp/teleport-sandbox/etc/teleport-proxy.yaml:/etc/teleport/teleport.yaml:Z \
  localhost/teleport:latest
```

### 5. Generate Initial Admin & Access Web UI
```bash
podman exec -it sandbox-auth tctl users add admin --roles=access,editor,auditor
```
Open `https://localhost:3023/web/invite/...` in your browser to complete password setup and MFA registration.

---

## 4. Stage 2 Multi-Node Enterprise Deployment (Ansible + Quadlets)

For production deployment across 3 distinct hosts (DMZ Proxy, Private Auth, PostgreSQL DB):

### Playbook Execution
```bash
ansible-playbook \
  -i inventory.yaml \
  deploy/ansible/playbooks/deploy-teleport.yaml \
  -e "teleport_deploy_postgres_password=YourSecurePassword123!"
```

### Ansible Role Layout (`deploy/ansible/roles/teleport_deploy/`)
- `defaults/main.yaml`: Default image names and domain variables.
- `meta/argument_specs.yaml`: Argument validation enforcing required input parameters.
- `tasks/postgres.yaml`: Provisions `/etc/containers/systemd/teleport-postgres.container` and initializes DB permissions.
- `tasks/auth.yaml`: Provisions `/etc/containers/systemd/teleport-auth.container`, `teleport-auth.yaml`, and `freeipa-connector.yaml`.
- `tasks/proxy.yaml`: Provisions `/etc/containers/systemd/teleport-proxy.container` and `teleport-proxy.yaml`.

---

## 5. FreeIPA / Red Hat IdM LDAP Integration

Once the Auth Server is running in production:

1. Copy `freeipa-connector.yaml` to the Auth Server host.
2. Register the LDAP connector using `tctl`:

```bash
podman exec -i teleport-auth tctl create -f /etc/teleport/freeipa-connector.yaml
```

Users in FreeIPA groups (`teleport-admins`, `teleport-users`) can now log into Teleport via LDAPS (`idm.internal.lab:636`) using their FreeIPA credentials and MFA.

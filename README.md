```bash
sudo bash <(curl -s https://raw.githubusercontent.com/multi81/remnawave-installer/main/install.sh)
```
# Remnawave Production Installer

Production-ready installer for Remnawave VPN panel with:

- Docker
- PostgreSQL
- Valkey
- Subscription page
- System Caddy
- Automatic HTTPS
- Auto-generated `.env`
- Firewall configuration
- Fail2Ban
- Production optimizations

---

# Requirements

- Ubuntu 24.04
- Clean VPS
- Root access
- Domain names pointed to server IP

Example:

| Type | Domain |
|---|---|
| Panel | panel.example.com |
| Subscription | sub.example.com |

---

# DNS Setup

Create A records:

| Host | Type | Value |
|---|---|---|
| panel | A | SERVER_IP |
| sub | A | SERVER_IP |

Wait until DNS propagates.

Check:

```bash
ping panel.example.com
ping sub.example.com
```

---

# Quick Install

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/multi81/remnawave-installer/main/install.sh)
```

Installer will ask:

- PANEL DOMAIN
- SUB DOMAIN
- EMAIL FOR SSL

Example:

```text
Panel domain: panel.example.com
Subscription domain: sub.example.com
Email: admin@example.com
```

---

# After Installation

Open:

```text
https://panel.example.com
```

Subscription page:

```text
https://sub.example.com
```

---

# Default Ports

| Service | Port |
|---|---|
| Panel | 3000 |
| Subscription | 3010 |
| PostgreSQL | internal |
| Valkey | internal |

---

# Useful Commands

## View containers

```bash
docker ps
```

## Restart stack

```bash
cd /opt/remnawave
docker compose restart
```

## View logs

```bash
docker compose logs -f
```

## Backend logs

```bash
docker logs -f remnawave-backend
```

## Caddy logs

```bash
journalctl -u caddy -f
```

---

# Update Remnawave

```bash
cd /opt/remnawave

docker compose pull

docker compose up -d
```

---

# Restart Caddy

```bash
systemctl restart caddy
```

---

# SSL Certificate Check

```bash
caddy list-modules | grep tls
```

---

# Firewall

Installed automatically:

- UFW
- Fail2Ban

Open ports:

- 22
- 80
- 443

---

# File Structure

```text
/opt/remnawave/
├── .env
├── docker-compose.yml
├── backups/
└── data/
```

---

# Troubleshooting

## Panel not opening

Check backend:

```bash
docker ps
```

Check port:

```bash
ss -tulpn | grep 3000
```

---

## HTTPS not working

Check DNS:

```bash
dig panel.example.com
dig sub.example.com
```

Check Caddy:

```bash
journalctl -u caddy -f
```

---

## Backend restarting

Usually `.env` issue.

Check:

```bash
cat /opt/remnawave/.env
```

---

# Security Recommendations

- Use strong passwords
- Disable password SSH login
- Use SSH keys
- Enable Cloudflare proxy
- Regular backups

---

# Backup

## Database backup

```bash
docker exec remnawave-db pg_dump -U remnawave remnawave > backup.sql
```

---

# Restore Backup

```bash
cat backup.sql | docker exec -i remnawave-db psql -U remnawave remnawave
```

---

# Production Recommendations

Recommended VPS:

- 2 CPU
- 4 GB RAM
- NVMe SSD
- Ubuntu 24.04

Recommended providers:

- Hetzner
- OVH
- Vultr

---

# License

MIT

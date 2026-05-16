bash <(curl -s https://raw.githubusercontent.com/multi81/remnawave-install/master/install2.sh)

# Remnawave Production Installer

Production-ready installer for Remnawave VPN platform.

Includes:

- Remnawave Backend
- Subscription Page
- PostgreSQL 17
- Valkey
- System Caddy
- Automatic HTTPS
- Firewall (UFW)
- Fail2Ban
- Production Docker setup
- Auto-generated `.env`
- Automatic SSL certificates

---

# Features

✅ One-command installation  
✅ Clean Ubuntu 24.04 support  
✅ Automatic SSL setup  
✅ Secure reverse proxy  
✅ Production-ready Docker networking  
✅ Automatic restart policies  
✅ Secure localhost-only backend ports  
✅ Ready for VPN business deployment

---

# System Requirements

Recommended:

| Resource | Recommended |
|---|---|
| OS | Ubuntu 24.04 |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 25 GB NVMe |

---

# DNS Configuration

Before installation create DNS records:

| Type | Host | Value |
|---|---|---|
| A | panel | SERVER_IP |
| A | sub | SERVER_IP |

Example:

```text
panel.example.com
sub.example.com
```

Check DNS:

```bash
ping panel.example.com
ping sub.example.com
```

---

# Installation

## 1. Connect to server

```bash
ssh root@SERVER_IP
```

---

## 2. Download installer

```bash
nano install2.sh
```

Paste installer content.

Save:

- CTRL + O
- ENTER
- CTRL + X

---

## 3. Make executable

```bash
chmod +x install2.sh
```

---

## 4. Run installer

```bash
./install2.sh
```

Installer will ask:

```text
Panel domain:
Subscription domain:
Email for SSL:
```

Example:

```text
Panel domain: panel.example.com
Subscription domain: sub.example.com
Email: admin@example.com
```

---

# After Installation

Panel:

```text
https://panel.example.com
```

Subscription page:

```text
https://sub.example.com
```

---

# Installed Components

| Service | Description |
|---|---|
| Remnawave Backend | Main VPN panel |
| Subscription Page | User subscription frontend |
| PostgreSQL 17 | Database |
| Valkey | Cache/queue |
| Caddy | Reverse proxy + HTTPS |
| UFW | Firewall |
| Fail2Ban | SSH protection |

---

# File Structure

```text
/opt/remnawave/
├── .env
├── docker-compose.yml
└── postgres_data
```

---

# Useful Commands

## View containers

```bash
docker ps
```

---

## Restart services

```bash
cd /opt/remnawave
docker compose restart
```

---

## Restart full stack

```bash
cd /opt/remnawave
docker compose down
docker compose up -d
```

---

## View logs

```bash
docker compose logs -f
```

---

## Backend logs

```bash
docker logs -f remnawave-backend
```

---

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

# Firewall

Automatically configured ports:

| Port | Purpose |
|---|---|
| 22 | SSH |
| 80 | HTTP |
| 443 | HTTPS |

---

# SSL Certificates

Certificates are automatically issued by Let's Encrypt through Caddy.

No manual SSL configuration required.

---

# Troubleshooting

## Panel not opening

Check containers:

```bash
docker ps
```

Check backend:

```bash
docker logs remnawave-backend
```

---

## HTTPS errors

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

Usually caused by broken `.env`.

Check:

```bash
cat /opt/remnawave/.env
```

---

## 502 Bad Gateway

Backend is not running.

Restart stack:

```bash
cd /opt/remnawave
docker compose restart
```

---

# Backup

## Create database backup

```bash
docker exec remnawave-db pg_dump -U remnawave remnawave > backup.sql
```

---

## Restore backup

```bash
cat backup.sql | docker exec -i remnawave-db psql -U remnawave remnawave
```

---

# Security Recommendations

Recommended:

- SSH keys only
- Disable root password login
- Use Cloudflare proxy
- Regular backups
- Monitor logs
- Keep system updated

---

# Recommended Providers

- Hetzner
- OVH
- Vultr
- Contabo

---

# License

MIT

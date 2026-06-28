# Mastodon on Proxmox (LXC + Garage + Cloudflare Tunnel)

A self-hosted, single-user-friendly Mastodon deployment for a Proxmox VE Ceph cluster.

- **Container**: privileged Debian 12 LXC. Rootfs on the Ceph **RBD** pool (`ceph`).
- **Object storage**: [Garage](https://garagehq.deuxfleurs.fr/) S3 server. Metadata on the RBD rootfs; data blocks on **CephFS** (`cephfs`) via a bind mount at `/mnt/garage-data`.
- **Ingress**: a single locally-managed **Cloudflare Tunnel**. No open ports, no public static IP. nginx serves plain HTTP on loopback; the tunnel provides edge encryption.
- **Mobility**: rootfs (RBD) is a managed, migratable volume; Garage data (CephFS) is cluster-wide, so the container relocates between nodes during reboot cycles.

```
Internet → Cloudflare edge → cloudflared tunnel ─┬─ social.<domain> → nginx :80 → web :3000 / streaming :4000
                                                 └─ media.<domain>  → garage web :3902
```

---

## Files in this package

| File | Runs where | Purpose |
|------|-----------|---------|
| `bootstrap.sh` | PVE host | Creates the LXC (RBD rootfs, CephFS data bind mount) and copies the installer in. |
| `setup.sh` | inside LXC | Installs and configures everything, in 14 resumable phases. |
| `garage/garage.toml` | inside LXC | Garage config template (S3 API + web endpoint). |
| `nginx/mastodon` | inside LXC | nginx site (plain HTTP on loopback). |
| `cloudflared/config.yml` | inside LXC | Tunnel ingress template. |
| `systemd/garage.service` | inside LXC | Garage daemon unit. |
| `systemd/cloudflared.service` | inside LXC | Locally-managed tunnel unit. |
| `env.production.template` | inside LXC | Annotated `.env.production`. |

Templates use `%%TOKEN%%` substitution markers; `setup.sh` fills them in. See **Token reference** below.

---

## 1. Prerequisites checklist

Complete all of these **before** running any script.

### Domain & Cloudflare
- [ ] Domain registered; nameservers pointing to Cloudflare; the domain added to your Cloudflare account.
- [ ] **Cloudflare Tunnel created (locally-managed).** On any machine with `cloudflared` installed and logged in:
  ```bash
  cloudflared tunnel login                     # browser auth; downloads cert.pem for management
  cloudflared tunnel create mastodon           # prints the TUNNEL UUID; writes ~/.cloudflared/<UUID>.json
  cloudflared tunnel route dns mastodon social.<domain>
  cloudflared tunnel route dns mastodon media.<domain>
  ```
  Note the **tunnel UUID** and keep the `<UUID>.json` credentials file — you copy it into the container in step 3.
  (If you prefer, create the two DNS records by hand as proxied — orange-cloud — CNAMEs to `<UUID>.cfargotunnel.com`.)
- [ ] **Bot Fight Mode disabled**: Security → Bots. (It breaks federation link previews, domain verification, and `fediverse:creator` — Mastodon's crawler can't solve JS challenges. Also check Super Bot Fight Mode.)
- [ ] **WebSockets ON**: Network → WebSockets (default on; verify on free plans).

### Proxmox / Ceph
- [ ] A PVE 8.x cluster with an RBD pool exposed as storage **`ceph`** and CephFS exposed as storage **`cephfs`**, both active on the target node.
- [ ] **≥ 100 GB free on `cephfs`** for Garage data.

### Mail
- [ ] SMTP provider credentials (Postmark, Mailgun, SES, …). Do **not** self-host SMTP for a homelab instance.

---

## 2. Run `bootstrap.sh` on the PVE host

Copy this package to a PVE node and run:
```bash
chmod +x bootstrap.sh
./bootstrap.sh
```
It prompts for the container ID, hostname, resources, storage names (`ceph` / `cephfs`), the CephFS quota (default 100 GB), and network settings. It then creates the LXC, attaches the CephFS bind mount, starts the container, and copies `setup.sh` + templates to `/root/mastodon-setup/` inside it.

---

## 3. Copy the tunnel credentials in, then run `setup.sh`

From the PVE host, copy your tunnel credentials file into the container:
```bash
pct exec <CTID> -- mkdir -p /etc/cloudflared
pct push <CTID> /path/to/<UUID>.json /etc/cloudflared/<UUID>.json
```

Then enter the container and run the installer:
```bash
pct enter <CTID>
/root/mastodon-setup/setup.sh
```
`setup.sh` is interactive in Phase 0 (domains, owner account, SMTP, tunnel UUID, bucket name) and runs phases 1–14. If a phase fails, fix the cause and re-run the same command — completed phases are skipped via `/root/mastodon-setup/.install-state`.

At the end it prints a health-check table and the generated **owner password** — save it.

---

## 4. Post-deploy steps

- [ ] Save the generated owner password (also stored, chmod 600, in `/root/mastodon-setup/.secrets`).
- [ ] Log in at `https://social.<domain>` and complete **Admin → Site Settings**.
- [ ] (Optional) Enable single-user mode: uncomment `SINGLE_USER_MODE=true` in `/home/mastodon/live/.env.production`, then `systemctl restart mastodon-web`.
- [ ] Verify **federation**: search for a known remote account (e.g. `@Gargron@mastodon.social`).
- [ ] Verify **media**: post an image and confirm it loads from `https://media.<domain>/...`.

---

## 5. Upgrade procedure

```bash
sudo -u mastodon -i
cd ~/live
git fetch --tags
```
1. **Read the GitHub release notes first** for the target tag.
2. **Back up the database**: `pg_dump -Fc mastodon_production > ~/mastodon_$(date +%F).dump` (run as the `mastodon` user, or `sudo -u postgres pg_dump …`).
3. Check `.ruby-version` and `.nvmrc` for version bumps; install the new Ruby/Node if they changed.
4. `git checkout <new-tag>`, then `bundle install` and `yarn install --immutable`.
5. Pre-deployment migrations: `SKIP_POST_DEPLOYMENT_MIGRATIONS=true RAILS_ENV=production bundle exec rails db:migrate`.
6. `RAILS_ENV=production bundle exec rails assets:precompile`.
7. Restart: `systemctl reload mastodon-web` (zero-downtime) and `systemctl restart mastodon-sidekiq mastodon-streaming` (restart streaming explicitly when its code changed).
8. Post-deployment migrations: `RAILS_ENV=production bundle exec rails db:migrate` (a second run, after the restart).

---

## 6. Transferring an existing account in

1. On the **source** instance, start the move: Settings → Account → Move to a different account, pointing at `you@social.<domain>`.
2. Wait for federation to propagate (can take hours).
3. The transferred account arrives as a **regular user**. Elevate it:
   ```bash
   cd /home/mastodon/live
   sudo -u mastodon RAILS_ENV=production bin/tootctl accounts modify <username> --role Owner
   ```
4. Delete the bootstrap admin account via **Admin → Accounts** in the web UI.

---

## 7. Sysadmin primer — how to check that each piece is healthy

New to Linux service administration? This section shows the exact commands, what healthy output looks like, and what a problem looks like. Everything is copy-pasteable from inside the container (`pct enter <CTID>`).

### Services (systemd)
Each component is a systemd service. Check one:
```bash
systemctl status nginx
```
Healthy shows `Active: active (running)`. A problem shows `active (exited)` unexpectedly, or `failed`. Quick yes/no:
```bash
systemctl is-active mastodon-web        # prints "active" or "failed"
```
Check all at once:
```bash
for u in postgresql redis-server nginx mastodon-web mastodon-sidekiq mastodon-streaming garage cloudflared; do
  printf '%-22s %s\n' "$u" "$(systemctl is-active "$u")"
done
```
Restart / reload:
```bash
systemctl restart mastodon-sidekiq      # full restart
systemctl reload nginx                  # reload config without dropping connections
```
> If your streaming unit is templated, it is `mastodon-streaming@4000` instead of `mastodon-streaming`.

### Logs (journald)
```bash
journalctl -u mastodon-web -n 100 --no-pager     # last 100 lines
journalctl -u mastodon-sidekiq -f                # follow live (Ctrl-C to stop)
journalctl -u garage --since "10 min ago"        # recent window
```
Healthy logs are steady request/job lines. Trouble looks like repeated Ruby backtraces, `FATAL`, `connection refused`, or a service that logs a start then immediately exits.

### HTTP health endpoints
```bash
curl -fsS http://127.0.0.1:3000/health                       # web    -> "OK"
curl -fsS http://127.0.0.1:4000/api/v1/streaming/health      # stream -> "OK"
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: social.<domain>" http://127.0.0.1:80/health   # nginx -> 200
```
`200` / `OK` = good. `Connection refused` = the service behind it is down (check `systemctl`/`journalctl`). `502/504` = nginx is up but the app behind it isn't answering.

### PostgreSQL
```bash
systemctl is-active postgresql
sudo -u mastodon psql mastodon_production -c '\dt' | head    # lists tables -> DB reachable
```
If you see tables, connectivity and auth are fine. `could not connect` means Postgres is down; an auth error means the `mastodon` role/socket setup is off. Pending migrations usually surface as errors in `journalctl -u mastodon-web` mentioning `PendingMigrationError`.

### Redis
```bash
redis-cli ping                          # -> PONG
```

### Garage (object storage)
```bash
garage status                           # node should be listed and "Up"
garage stats                            # data/metadata sizes, object counts
garage bucket info mastodon             # bucket exists; shows website + alias + key grants
garage bucket list                      # all buckets
garage key list                         # 'mastodon-key' should be present
```
Healthy: `garage status` shows your single node as `Up`, and `garage bucket info mastodon` lists the `media.<domain>` alias, `Website access: true`, and the key with read/write. If media is broken, this is the first place to look.

### Object storage, end-to-end
After posting an image, copy its media URL from the web UI (it will be under `https://media.<domain>/...`) and fetch it:
```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://media.<domain>/<path-from-a-real-post>"
```
`200` = public read works. `403`/`404` = check `garage bucket website --allow mastodon`, the `media.<domain>` alias, and that the tunnel routes `media.<domain>` to `:3902`.

### Cloudflare Tunnel
```bash
journalctl -u cloudflared -n 50 --no-pager       # look for "Registered tunnel connection"
```
Several `Registered tunnel connection` lines = healthy. Also confirm the tunnel shows green in **Cloudflare → Zero Trust → Networks → Tunnels**. If the tunnel itself is blocked, check Super Bot Fight Mode.

### Storage & capacity
```bash
df -h /                          # rootfs (RBD) usage
df -h /mnt/garage-data           # Garage data (CephFS) usage
mountpoint /mnt/garage-data      # -> "/mnt/garage-data is a mountpoint"
du -sh /mnt/garage-data          # actual bytes used by Garage data
swapon --show                    # swap present/active
free -h                          # memory pressure
```
Read the CephFS quota from the **PVE host** (not inside the container):
```bash
getfattr -n ceph.quota.max_bytes /mnt/pve/cephfs/ct-<CTID>-garage-data
```

### Monitoring the media cache
The cron keeps remote media to a 28-day rolling cache, which is larger than a short window. Watch it:
```bash
du -sh /mnt/garage-data          # trend this over days/weeks
garage stats                     # object counts and sizes
```
Run the prune on demand:
```bash
cd /home/mastodon/live && sudo -u mastodon RAILS_ENV=production bin/tootctl media remove --days=28
```
If usage approaches the 100 GB cap, raise the quota from the **PVE host**:
```bash
setfattr -n ceph.quota.max_bytes -v 161061273600 /mnt/pve/cephfs/ct-<CTID>-garage-data   # e.g. 150 GB
```

### tootctl (Mastodon admin CLI)
Run it as the `mastodon` user from the live dir:
```bash
cd /home/mastodon/live
sudo -u mastodon RAILS_ENV=production bin/tootctl <command>
```
Useful read-only commands:
```bash
sudo -u mastodon RAILS_ENV=production bin/tootctl accounts modify --help
sudo -u mastodon RAILS_ENV=production bin/tootctl media usage
sudo -u mastodon RAILS_ENV=production bin/tootctl feeds build --help
```
> Some `tootctl` commands are destructive (e.g. `self-destruct`, `accounts delete`). Read `--help` before running anything that isn't clearly read-only.

### Re-running the health-check table
You can re-run the installer at any time to reprint the Phase 14 pass/fail table — all earlier phases are skipped:
```bash
/root/mastodon-setup/setup.sh
```

---

## 8. Maintenance reference

- **Cron** (installed for the `mastodon` user — `crontab -u mastodon -l`):
  - hourly: `tootctl media remove --days=28` (prune remote media cache)
  - weekly: `tootctl media remove-orphans` (drop orphaned media)
  - weekly: `tootctl statuses remove --days=90` (vacuum old statuses from un-followed accounts)
- **Logs**: `journalctl -u mastodon-web` (and `-sidekiq`, `-streaming`, `-u garage`, `-u cloudflared`).
- **Garage admin**: `garage status`, `garage bucket info mastodon`, `garage stats`.
- **Storage layout**: rootfs + Garage metadata (`/var/lib/garage/meta`) live on RBD; Garage data (`/mnt/garage-data`) lives on CephFS. Quota is read/set host-side with `getfattr`/`setfattr` on `/mnt/pve/cephfs/ct-<CTID>-garage-data`.

---

## 9. Container mobility (Ceph)

- **Rootfs** is on RBD (`ceph`) — a managed, migratable volume.
- **`/mnt/garage-data`** is a CephFS bind mount: Proxmox does not auto-copy bind mounts during migration, but the data is cluster-wide, so the container starts cleanly on the target node.
- To relocate (e.g. before a node reboot):
  ```bash
  pct migrate <CTID> <target-node> --restart
  ```
- After relocation, confirm storage and Garage:
  ```bash
  mountpoint /mnt/garage-data && garage status
  ```

---

## 10. Troubleshooting quick reference

| Symptom | Check |
|---------|-------|
| Federation not working | Bot Fight Mode disabled? `journalctl -u mastodon-sidekiq`; confirm nginx sends `X-Forwarded-Proto https`. |
| Media not loading | `garage status`; `media.<domain>` DNS/tunnel route; `garage bucket info mastodon` (website + alias); tunnel routes media → `:3902`. |
| WebSocket disconnects | Cloudflare WebSockets ON; streaming service active; nginx `/api/v1/streaming` upgrade headers present. |
| Tunnel unhealthy | `journalctl -u cloudflared`; Super Bot Fight Mode; confirm credentials-file mode (a `<UUID>.json` exists and `config.yml` references it). |
| After a node move | `mountpoint /mnt/garage-data`? `garage status` healthy? |

---

## Token reference

`setup.sh` substitutes these `%%TOKEN%%` markers when rendering templates:

| Token | Source |
|-------|--------|
| `DOMAIN`, `SOCIAL_DOMAIN`, `MEDIA_DOMAIN` | Phase 0 prompts |
| `MASTODON_USERNAME`, `MASTODON_USER_EMAIL` | Phase 0 prompts |
| `SMTP_SERVER`, `SMTP_PORT`, `SMTP_LOGIN`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS` | Phase 0 prompts |
| `CF_TUNNEL_ID` | Phase 0 prompt (the tunnel UUID from `cloudflared tunnel create`) |
| `GARAGE_BUCKET` | Phase 0 prompt (default `mastodon`) |
| `SECRET_KEY_BASE`, `OTP_SECRET` | Generated in Phase 6 (`rails secret`) |
| `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY` | Generated in Phase 6 (`mastodon:webpush:generate_vapid_key`) |
| `AR_ENCRYPTION_PRIMARY_KEY`, `AR_ENCRYPTION_DETERMINISTIC_KEY`, `AR_ENCRYPTION_KEY_DERIVATION_SALT` | Generated in Phase 6 (`db:encryption:init`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Generated in Phase 5 (`garage key create`) |
| `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`, `GARAGE_METRICS_TOKEN` | Generated in Phase 5 (`openssl rand`) |

Generated secrets are written to `/root/mastodon-setup/.secrets` (chmod 600) and reused on re-runs.

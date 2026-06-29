# Mastodon on Proxmox (LXC + Garage + Cloudflare Tunnel)

A self-hosted, single-user-friendly Mastodon deployment for a Proxmox VE Ceph cluster.

- **Container**: privileged Debian 12 LXC. Rootfs on the Ceph **RBD** pool (`ceph`). (The container OS is independent of the host; this targets **Proxmox VE 9.x**.)
- **Object storage**: [Garage](https://garagehq.deuxfleurs.fr/) S3 server. Metadata on the RBD rootfs; data blocks on **CephFS** (`cephfs`) via a bind mount at `/mnt/garage-data`.
- **Ingress**: a single Cloudflare Tunnel, **created automatically by `setup.sh` via the Cloudflare API** — no `cloudflared` on any other machine. No open ports, no public static IP. nginx serves plain HTTP on loopback; the tunnel provides edge encryption.
- **Mobility**: rootfs (RBD) is a managed, migratable volume; Garage data (CephFS) is cluster-wide, so the container relocates between nodes during reboot cycles.

You choose two hostnames — a **web domain** (where Mastodon lives) and a **media domain** — anywhere in your Cloudflare zone(s). Nothing assumes a `social.` prefix.

```
Internet → Cloudflare edge → cloudflared tunnel ─┬─ <web-domain>   → nginx :80 → web :3000 / streaming :4000
                                                 └─ <media-domain> → garage web :3902
```

---

## Files in this package

| File | Runs where | Purpose |
|------|-----------|---------|
| `bootstrap.sh` | PVE host | Creates the LXC (RBD rootfs, CephFS data bind mount) and copies the installer in. |
| `setup.sh` | inside LXC | Installs and configures everything, in 14 resumable phases (incl. tunnel + DNS via API). |
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
- [ ] Your domain is added to Cloudflare (nameservers pointing to Cloudflare) and the zone is **Active**.
- [ ] Pick your two hostnames:
  - **web domain** — where Mastodon lives. Your apex (`example.com`) or any subdomain (`social.example.com`, `mastodon.example.com`, …). This is also your fediverse identity (handles become `@you@<web-domain>`).
  - **media domain** — e.g. `media.example.com`. Can be in the same zone or a different zone.
- [ ] **Create a Cloudflare API token** (dashboard → My Profile → API Tokens → Create Token → *Custom token*) with these permissions:
  - **Account » Cloudflare Tunnel » Edit**
  - **Zone » DNS » Edit**
  - **Zone » Zone » Read**

  Scope it to the account and the zone(s) that hold your two hostnames. Copy the token — you paste it once during setup (Phase 11) and it is **not stored on disk**.
- [ ] Note your **Cloudflare Account ID** (dashboard → any domain → Overview, right-hand sidebar; or Account Home).
- [ ] **Bot Fight Mode disabled**: Security → Bots. (It breaks federation link previews, domain verification, and `fediverse:creator` — Mastodon's crawler can't solve JS challenges. Also check Super Bot Fight Mode.)
- [ ] **WebSockets ON**: Network → WebSockets (default on; verify on free plans).

> `setup.sh` creates the tunnel **and** the proxied DNS records for both hostnames automatically through the API. You do not run `cloudflared` anywhere else, and you do not create DNS records by hand.

### Proxmox / Ceph
- [ ] A **PVE 9.x** cluster with an RBD pool exposed as storage **`ceph`** and CephFS exposed as storage **`cephfs`**, both active on the target node.
- [ ] **≥ 100 GB free on `cephfs`** for Garage data.

### Mail
- [ ] SMTP provider credentials. Do **not** self-host SMTP for a homelab instance.

**Mailgun** (used here): the template's defaults (port 587, `plain` auth, STARTTLS auto) already fit Mailgun — just enter the right values at the Phase 0 prompts:
- [ ] **Verify a sending domain** in Mailgun (Sending → Domains → Add domain). Add the SPF (`TXT`), DKIM (`TXT`), and tracking (`CNAME`) records Mailgun gives you into Cloudflare DNS, and wait for Mailgun to mark the domain **Verified**. (The free *sandbox* domain only delivers to authorized recipients — use a real domain.)
- [ ] **Create an SMTP credential for the domain** (Sending → [your domain] → Domain settings → SMTP credentials → *Add new SMTP user*). A new domain starts with none — the old auto-created `postmaster@…` default is gone. Pick any login local-part (e.g. `mastodon`) and set/copy its password; Mailgun stores it as the full address `mastodon@<your-mailgun-domain>`. **An SMTP credential is separate from API keys — don't use an API key or your account password.**
- [ ] Values to enter in Phase 0:
  - `SMTP_SERVER` = `smtp.mailgun.org` (US region) or `smtp.eu.mailgun.org` (EU region)
  - `SMTP_PORT` = `587`
  - `SMTP_LOGIN` = the full SMTP credential address you created, e.g. `mastodon@<your-mailgun-domain>`
  - `SMTP_PASSWORD` = that credential's password
  - `SMTP_FROM_ADDRESS` = an address on your verified domain, e.g. `Mastodon <notifications@<your-domain>>`
- [ ] After deploy, confirm delivery by triggering an email (e.g. the account-confirmation or a password-reset mail) and watching `journalctl -u mastodon-sidekiq` for the `ActionMailer`/delivery line — a Mailgun auth or domain error shows up there.

---

## 2. Run `bootstrap.sh` on the PVE host

**Without cloning** (fetches from GitHub `main`; cache-bust query avoids stale CDN copies):

```bash
bash -c "$(curl -fsSL -H 'Cache-Control: no-cache' \
  "https://raw.githubusercontent.com/sethvoltz/mastodon-setup-lxc/main/bootstrap.sh?$(date +%s)")"
```

You should see `bootstrap.sh v3` near the top of the run. If the IP prompt says **blank for DHCP** or lacks a **`[dhcp]`** default, you have an old copy — re-run with the command above, pin a commit SHA in the URL, or use a git checkout.

Or from a checkout on the PVE node:
```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

Pin a branch, tag, or commit by exporting `MASTODON_SETUP_REF` before either command (e.g. `export MASTODON_SETUP_REF=v1.0.0`). **Push your chosen ref to GitHub before using the curl one-liner** — it fetches from the remote, not your local tree.

It prompts for the container ID, hostname, resources (default **40 GB** root disk), storage names (`ceph` / `cephfs`), the CephFS quota (default 100 GB), and network settings. Press **Enter** at the IP prompt to accept the default **`dhcp`**. It then creates the LXC, attaches the CephFS bind mount, starts the container, and copies `setup.sh` + templates to `/root/mastodon-setup/` inside it.

---

## 3. Run `setup.sh` inside the LXC

```bash
pct enter <CTID>
/root/mastodon-setup/setup.sh
```

If the package was not copied in (or you want to re-fetch templates), run without a checkout:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sethvoltz/mastodon-setup-lxc/main/setup.sh)"
```
Templates land in `/root/mastodon-setup/` for re-runs. Use `MASTODON_SETUP_REF` to pin a release the same way as bootstrap.

Optional environment variables before running setup:

| Variable | Purpose |
|----------|---------|
| `MASTODON_TAG` | Pin Mastodon release (e.g. `v4.6.2`); default = latest stable non-rc tag |
| `GARAGE_LAYOUT_CAPACITY` | Capacity passed to `garage layout assign` (default `100G`; independent of CephFS quota) |

- **Phase 0** prompts for your web/media domains, owner account, SMTP, Cloudflare **Account ID**, and tunnel name (default `mastodon`).
- **Phase 3** checks out Mastodon and compiles Ruby; **Phase 4** installs Node.js from the checked-out `.nvmrc`.
- **Phase 11** prompts for your Cloudflare **API token** (not stored), then creates the tunnel, writes its credentials, and provisions proxied DNS records for both hostnames (replacing conflicting A/AAAA records if present).

Phases 0–14 run in order. If a phase fails, fix the cause and re-run the same command — completed phases are skipped via `/root/mastodon-setup/.install-state`.

At the end it prints a health-check table and the generated **owner password** — save it.

---

## 4. Post-deploy steps

- [ ] Save the generated owner password (also stored, chmod 600, in `/root/mastodon-setup/.secrets`).
- [ ] Log in at `https://<web-domain>` and complete **Admin → Site Settings**.
- [ ] (Optional) Enable single-user mode: uncomment `SINGLE_USER_MODE=true` in `/home/mastodon/live/.env.production`, then `systemctl restart mastodon-web`.
- [ ] Verify **federation**: search for a known remote account (e.g. `@Gargron@mastodon.social`).
- [ ] Verify **media**: post an image and confirm it loads from `https://<media-domain>/...`.

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

1. On the **source** instance, start the move: Settings → Account → Move to a different account, pointing at `you@<web-domain>`.
2. Wait for federation to propagate (can take hours).
3. The transferred account arrives as a **regular user**. Elevate it:
   ```bash
   cd /home/mastodon/live
   sudo -u mastodon RAILS_ENV=production bin/tootctl accounts modify <username> --role Owner
   ```
4. Delete the bootstrap admin account via **Admin → Accounts** in the web UI.

---

## 7. Sysadmin primer — how to check that each piece is healthy

New to Linux service administration? This section shows the exact commands, what healthy output looks like, and what a problem looks like. Everything is copy-pasteable from inside the container (`pct enter <CTID>`). Replace `<web-domain>` / `<media-domain>` with the hostnames you chose.

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
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: <web-domain>" http://127.0.0.1:80/health   # nginx -> 200
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
Healthy: `garage status` shows your single node as `Up`, and `garage bucket info mastodon` lists the `<media-domain>` alias, `Website access: true`, and the key with read/write. If media is broken, this is the first place to look.

### Object storage, end-to-end
After posting an image, copy its media URL from the web UI (under `https://<media-domain>/...`) and fetch it:
```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://<media-domain>/<path-from-a-real-post>"
```
`200` = public read works. `403`/`404` = check `garage bucket website --allow mastodon`, the `<media-domain>` alias, and that the tunnel routes `<media-domain>` to `:3902`.

### Cloudflare Tunnel
```bash
journalctl -u cloudflared -n 50 --no-pager       # look for "Registered tunnel connection"
```
Several `Registered tunnel connection` lines = healthy. Also confirm the tunnel shows green in **Cloudflare → Zero Trust → Networks → Tunnels** (it will be listed as locally-managed). If the tunnel itself is blocked, check Super Bot Fight Mode.

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
| Media not loading | `garage status`; `<media-domain>` DNS/tunnel route; `garage bucket info mastodon` (website + alias); tunnel routes media → `:3902`. |
| WebSocket disconnects | Cloudflare WebSockets ON; streaming service active; nginx `/api/v1/streaming` upgrade headers present. |
| Tunnel unhealthy | `journalctl -u cloudflared`; Super Bot Fight Mode; confirm `/etc/cloudflared/<tunnel-id>.json` exists and `config.yml` references it. |
| Tunnel/DNS not created | Re-run `setup.sh` (re-prompts for the API token); confirm token scopes (Tunnel:Edit, DNS:Edit, Zone:Read) and that both hostnames' zones are Active. Conflicting A/AAAA records are removed automatically when the tunnel CNAME is created. |
| After a node move | `mountpoint /mnt/garage-data`? `garage status` healthy? |

---

## Token & input reference

**Operator inputs** (prompted by `setup.sh`):

| Input | When | Stored? |
|-------|------|---------|
| `WEB_DOMAIN`, `MEDIA_DOMAIN` | Phase 0 | yes (state file) |
| `MASTODON_USERNAME`, `MASTODON_USER_EMAIL` | Phase 0 | yes |
| `SMTP_SERVER`, `SMTP_PORT`, `SMTP_LOGIN`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS` | Phase 0 | yes (state file, chmod 600) |
| `CF_ACCOUNT_ID`, `CF_TUNNEL_NAME` | Phase 0 | yes |
| `GARAGE_BUCKET` (default `mastodon`) | Phase 0 | yes |
| `CF_API_TOKEN` | Phase 11 | **no** — used in-memory, then unset |

**Template tokens** filled in when rendering configs:

| Token | Source |
|-------|--------|
| `WEB_DOMAIN`, `MEDIA_DOMAIN`, `GARAGE_BUCKET` | Phase 0 inputs |
| `SMTP_*` | Phase 0 inputs |
| `CF_TUNNEL_ID` | Generated in Phase 11 (created via the Cloudflare API) |
| `SECRET_KEY_BASE`, `OTP_SECRET` | Generated in Phase 6 (`rails secret`) |
| `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY` | Generated in Phase 6 (`mastodon:webpush:generate_vapid_key`) |
| `AR_ENCRYPTION_PRIMARY_KEY`, `AR_ENCRYPTION_DETERMINISTIC_KEY`, `AR_ENCRYPTION_KEY_DERIVATION_SALT` | Generated in Phase 6 (`db:encryption:init`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Generated in Phase 5 (`garage key create`) |
| `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`, `GARAGE_METRICS_TOKEN` | Generated in Phase 5 (`openssl rand`) |

Generated secrets are written to `/root/mastodon-setup/.secrets` (chmod 600) and reused on re-runs. The Cloudflare API token is never written to disk.

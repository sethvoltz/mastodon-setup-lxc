#!/usr/bin/env bash
#
# setup.sh — INSIDE-LXC installer for a self-hosted Mastodon instance.
#
# Runs as root inside the privileged Debian 12 LXC created by bootstrap.sh.
# Structured in phases; each phase is gated by a marker in .install-state so the
# script can be re-run after a failure without redoing completed work.
#
#   Storage: rootfs + Garage metadata on RBD rootfs; Garage data on the CephFS
#   bind mount at /mnt/garage-data (provided by Proxmox before container init).
#
set -euo pipefail

# ===========================================================================
# Constants
# ===========================================================================
SETUP_DIR="/root/mastodon-setup"
STATE_FILE="${SETUP_DIR}/.install-state"
SECRETS_FILE="${SETUP_DIR}/.secrets"
MASTODON_HOME="/home/mastodon"
LIVE="${MASTODON_HOME}/live"
GARAGE_DATA="/mnt/garage-data"
export GARAGE_CONFIG_FILE="/etc/garage/garage.toml"   # used by the garage CLI

# Garage release to install. Bump GARAGE_VERSION as new stable releases land.
# Leave GARAGE_SHA256 empty to verify against the upstream .sha256sum file, or
# pin a known-good hash here to fail closed on any mismatch.
GARAGE_VERSION="v1.0.1"
GARAGE_SHA256=""
GARAGE_BASE="https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl"

NODE_MAJOR_DEFAULT="20"   # Mastodon 4.3+ needs Node 20+; overridden by repo .nvmrc if present

# ===========================================================================
# Helpers
# ===========================================================================
c_hdr() { printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"; }
c_ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
c_warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
c_err() { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }
die()   { c_err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root inside the LXC."
mkdir -p "$SETUP_DIR"

# State: KEY=value (quoted) lines, sourced on startup. Inputs + PHASE_n_DONE markers.
# shellcheck source=/dev/null
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
state_put() {           # state_put KEY VALUE  (upsert + export into env)
  local k="$1" v="$2"
  touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  grep -vE "^${k}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  printf '%s=%q\n' "$k" "$v" >> "$STATE_FILE"
  printf -v "$k" '%s' "$v"
}
mark_done() { state_put "PHASE_${1}_DONE" 1; }
is_done()   { local v="PHASE_${1}_DONE"; [[ "${!v:-}" == "1" ]]; }

# Secrets: KEY=value lines, chmod 600, reused across re-runs.
[[ -f "$SECRETS_FILE" ]] && chmod 600 "$SECRETS_FILE"
secret_get() { [[ -f "$SECRETS_FILE" ]] && grep -E "^$1=" "$SECRETS_FILE" | head -1 | cut -d= -f2- || true; }
secret_set() {
  local k="$1" v="$2"
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  grep -vE "^${k}=" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp" 2>/dev/null || true
  mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
  printf '%s=%s\n' "$k" "$v" >> "$SECRETS_FILE"
}

prompt() {              # prompt VAR "Question" [default]
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [[ -n "$__def" ]]; then
    read -r -p "$__q [$__def]: " __ans || true; __ans="${__ans:-$__def}"
  else
    while [[ -z "${__ans:-}" ]]; do read -r -p "$__q: " __ans || true; done
  fi
  printf -v "$__var" '%s' "$__ans"
}
prompt_secret() {       # prompt_secret VAR "Question"
  local __var="$1" __q="$2" __ans
  while [[ -z "${__ans:-}" ]]; do read -r -s -p "$__q: " __ans || true; echo; done
  printf -v "$__var" '%s' "$__ans"
}
need() {                # need VAR "Question" [default] — prompt only if unset, then persist
  local var="$1"
  [[ -n "${!var:-}" ]] && return 0
  prompt "$var" "$2" "${3:-}"
  state_put "$var" "${!var}"
}
need_secret() {
  local var="$1"
  [[ -n "${!var:-}" ]] && return 0
  prompt_secret "$var" "$2"
  state_put "$var" "${!var}"
}

# Run a command as the mastodon user, in the live dir, with rbenv shims on PATH.
m_run() {
  runuser -l mastodon -c "export PATH=\$HOME/.rbenv/bin:\$HOME/.rbenv/shims:\$PATH; cd $LIVE && $*"
}

# Template rendering — replaces every %%TOKEN%% from the TOKENS map (literal, regex-safe).
declare -A TOKENS=()
render_template() {     # render_template SRC DST
  local src="$1" dst="$2" content key
  content="$(cat "$src")"
  for key in "${!TOKENS[@]}"; do
    content="${content//"%%${key}%%"/${TOKENS[$key]}}"
  done
  printf '%s\n' "$content" > "$dst"
}

# --- Cloudflare API helpers (Phase 11: provision the tunnel + DNS, no browser) ---
cf_api() {              # cf_api METHOD PATH [JSON_BODY] -> response JSON on stdout
  local method="$1" path="$2" body="${3:-}" resp
  if [[ -n "$body" ]]; then
    resp="$(curl -sS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$body")"
  else
    resp="$(curl -sS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")"
  fi
  if [[ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    c_err "Cloudflare API error: $method $path"
    jq -r '.errors' <<<"$resp" >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    return 1
  fi
  printf '%s' "$resp"
}
cf_zone_id() {          # cf_zone_id HOST -> id of the longest-matching active zone
  local cand="$1" resp zid
  while [[ "$cand" == *.* ]]; do
    resp="$(cf_api GET "/zones?name=${cand}&status=active")" || return 1
    zid="$(jq -r '.result[0].id // empty' <<<"$resp")"
    [[ -n "$zid" ]] && { printf '%s' "$zid"; return 0; }
    cand="${cand#*.}"
  done
  return 1
}
cf_dns_upsert() {       # cf_dns_upsert ZONE_ID FQDN TARGET  (proxied CNAME, upsert)
  local zone="$1" fqdn="$2" target="$3" resp rec_id data
  resp="$(cf_api GET "/zones/${zone}/dns_records?type=CNAME&name=${fqdn}")" || return 1
  rec_id="$(jq -r '.result[0].id // empty' <<<"$resp")"
  data="$(jq -nc --arg n "$fqdn" --arg c "$target" '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')"
  if [[ -n "$rec_id" ]]; then
    cf_api PUT "/zones/${zone}/dns_records/${rec_id}" "$data" >/dev/null
  else
    cf_api POST "/zones/${zone}/dns_records" "$data" >/dev/null
  fi
}

# ===========================================================================
# Phase 0: Collect inputs
# ===========================================================================
if is_done 0; then c_warn "Phase 0 done — skipping input collection."; else
  c_hdr "Phase 0: Collect inputs"
  need WEB_DOMAIN          "Mastodon web domain (full hostname, e.g. example.com or social.example.com)"
  need MEDIA_DOMAIN        "Media domain (full hostname, e.g. media.example.com)"
  need MASTODON_USER_EMAIL "Owner account email"
  need MASTODON_USERNAME   "Owner account username"
  need SMTP_SERVER         "SMTP server"
  need SMTP_PORT           "SMTP port"                        "587"
  need SMTP_LOGIN          "SMTP login"
  need_secret SMTP_PASSWORD "SMTP password"
  need SMTP_FROM_ADDRESS   "SMTP From address"                "Mastodon <notifications@${WEB_DOMAIN}>"
  need CF_ACCOUNT_ID       "Cloudflare Account ID"
  need CF_TUNNEL_NAME      "Cloudflare tunnel name"           "mastodon"
  need GARAGE_BUCKET       "Garage S3 bucket name"            "mastodon"

  mountpoint -q "$GARAGE_DATA" && [[ -w "$GARAGE_DATA" ]] \
    || die "$GARAGE_DATA is not a writable mountpoint. Re-check the bootstrap bind-mount step."
  c_ok "$GARAGE_DATA is mounted and writable."
  c_warn "The Cloudflare API token is requested in Phase 11 and is NOT stored on disk."
  mark_done 0
fi

# ===========================================================================
# Phase 1: System baseline
# ===========================================================================
if is_done 1; then c_warn "Phase 1 done — skipping."; else
  c_hdr "Phase 1: System baseline"
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt upgrade -y
  # Debian 12 (bookworm) package names: libidn-dev and libncurses-dev.
  apt install -y curl wget gnupg lsb-release ca-certificates git sudo \
    build-essential libssl-dev libreadline-dev zlib1g-dev \
    libpq-dev libxml2-dev libxslt1-dev file imagemagick ffmpeg \
    libidn-dev libicu-dev libjemalloc-dev \
    libprotobuf-dev protobuf-compiler pkg-config \
    autoconf bison libncurses-dev libffi-dev libgdbm-dev \
    nginx redis-server attr jq

  # Swap backstop — asset precompile (Phase 8) peaks ~1.5 GB RSS.
  if ! swapon --show | grep -q '/swapfile'; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    c_ok "2 GB swap added."
  fi
  mark_done 1
fi

# ===========================================================================
# Phase 2: PostgreSQL 16
# ===========================================================================
if is_done 2; then c_warn "Phase 2 done — skipping."; else
  c_hdr "Phase 2: PostgreSQL 16"
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt update
  fi
  apt install -y postgresql-16
  systemctl enable --now postgresql
  # Role with CREATEDB + peer auth (no password); db:setup (Phase 7) creates the DB.
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='mastodon'" | grep -q 1; then
    runuser -u postgres -- psql -c "CREATE USER mastodon CREATEDB;"
    c_ok "Created postgres role 'mastodon' (CREATEDB)."
  fi
  mark_done 2
fi

# ===========================================================================
# Phase 3: Node.js
# ===========================================================================
if is_done 3; then c_warn "Phase 3 done — skipping."; else
  c_hdr "Phase 3: Node.js"
  NODE_MAJOR="$NODE_MAJOR_DEFAULT"
  [[ -f "${LIVE}/.nvmrc" ]] && NODE_MAJOR="$(tr -dc '0-9.' < "${LIVE}/.nvmrc" | cut -d. -f1)"
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)" != "$NODE_MAJOR" ]]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt install -y nodejs
  fi
  corepack enable
  corepack prepare yarn@stable --activate
  c_ok "Node $(node -v), corepack/yarn enabled."
  mark_done 3
fi

# ===========================================================================
# Phase 4: Ruby via rbenv + Mastodon checkout
# ===========================================================================
if is_done 4; then c_warn "Phase 4 done — skipping."; else
  c_hdr "Phase 4: Ruby via rbenv + Mastodon checkout"
  id mastodon &>/dev/null || adduser --disabled-login --gecos "" mastodon

  # shellcheck disable=SC2016  # literal $HOME / $(rbenv init) written verbatim into the rc files
  RBENV_INIT='export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"'
  for f in .bashrc .profile; do
    if ! grep -q 'rbenv init' "${MASTODON_HOME}/${f}" 2>/dev/null; then
      printf '%s\n' "$RBENV_INIT" >> "${MASTODON_HOME}/${f}"
      chown mastodon:mastodon "${MASTODON_HOME}/${f}"
    fi
  done

  [[ -d "${MASTODON_HOME}/.rbenv/.git" ]] || \
    runuser -l mastodon -c 'git clone https://github.com/rbenv/rbenv.git ~/.rbenv'
  [[ -d "${MASTODON_HOME}/.rbenv/plugins/ruby-build/.git" ]] || \
    runuser -l mastodon -c 'git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build'

  [[ -d "${LIVE}/.git" ]] || \
    runuser -l mastodon -c 'git clone https://github.com/mastodon/mastodon.git ~/live'
  # shellcheck disable=SC2016  # $(...) intentionally evaluated in the mastodon login shell
  runuser -l mastodon -c 'cd ~/live && git fetch --tags && git checkout "$(git tag -l | grep -v rc | sort -V | tail -1)"'

  RUBY_V="$(cat "${LIVE}/.ruby-version")"
  m_run "RUBY_CONFIGURE_OPTS=--with-jemalloc rbenv install -s ${RUBY_V}"
  m_run "rbenv global ${RUBY_V}"
  m_run "gem install bundler --no-document"
  c_ok "Ruby ${RUBY_V} installed; Mastodon checked out at $(runuser -l mastodon -c 'cd ~/live && git describe --tags')."
  mark_done 4
fi

# ===========================================================================
# Phase 5: Garage S3 server
# ===========================================================================
if is_done 5; then c_warn "Phase 5 done — skipping."; else
  c_hdr "Phase 5: Garage S3 server"

  if [[ ! -x /usr/local/bin/garage ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL "${GARAGE_BASE}/garage" -o "${tmp}/garage"
    actual="$(sha256sum "${tmp}/garage" | awk '{print $1}')"
    if [[ -n "$GARAGE_SHA256" ]]; then
      expected="$GARAGE_SHA256"
    else
      curl -fsSL "${GARAGE_BASE}/garage.sha256sum" -o "${tmp}/garage.sha256sum"
      expected="$(awk '{print $1}' "${tmp}/garage.sha256sum" | head -1)"
    fi
    [[ -n "$expected" ]] || die "Could not determine expected Garage sha256."
    [[ "$actual" == "$expected" ]] || die "Garage checksum mismatch (expected $expected, got $actual)."
    install -m 0755 "${tmp}/garage" /usr/local/bin/garage
    rm -rf "$tmp"
    c_ok "Garage ${GARAGE_VERSION} installed (sha256 verified)."
  fi

  id garage &>/dev/null || adduser --system --group --no-create-home garage
  install -d -o garage -g garage /etc/garage /var/lib/garage/meta "${GARAGE_DATA}/data"
  chown -R garage:garage "$GARAGE_DATA"

  # Garage secrets (generated once, reused on re-run).
  GARAGE_RPC_SECRET="$(secret_get GARAGE_RPC_SECRET)";   [[ -n "$GARAGE_RPC_SECRET" ]]   || { GARAGE_RPC_SECRET="$(openssl rand -hex 32)"; secret_set GARAGE_RPC_SECRET "$GARAGE_RPC_SECRET"; }
  GARAGE_ADMIN_TOKEN="$(secret_get GARAGE_ADMIN_TOKEN)"; [[ -n "$GARAGE_ADMIN_TOKEN" ]]  || { GARAGE_ADMIN_TOKEN="$(openssl rand -hex 32)"; secret_set GARAGE_ADMIN_TOKEN "$GARAGE_ADMIN_TOKEN"; }
  GARAGE_METRICS_TOKEN="$(secret_get GARAGE_METRICS_TOKEN)"; [[ -n "$GARAGE_METRICS_TOKEN" ]] || { GARAGE_METRICS_TOKEN="$(openssl rand -hex 32)"; secret_set GARAGE_METRICS_TOKEN "$GARAGE_METRICS_TOKEN"; }

  TOKENS=(
    [MEDIA_DOMAIN]="$MEDIA_DOMAIN"
    [GARAGE_RPC_SECRET]="$GARAGE_RPC_SECRET"
    [GARAGE_ADMIN_TOKEN]="$GARAGE_ADMIN_TOKEN"
    [GARAGE_METRICS_TOKEN]="$GARAGE_METRICS_TOKEN"
  )
  render_template "${SETUP_DIR}/garage/garage.toml" /etc/garage/garage.toml
  chown garage:garage /etc/garage/garage.toml; chmod 640 /etc/garage/garage.toml

  install -m 0644 "${SETUP_DIR}/systemd/garage.service" /etc/systemd/system/garage.service
  systemctl daemon-reload
  systemctl enable --now garage

  # Wait until the daemon answers.
  for _ in $(seq 1 30); do garage status >/dev/null 2>&1 && break; sleep 2; done
  garage status >/dev/null 2>&1 || die "Garage did not become healthy — check 'journalctl -u garage'."

  # Single-node layout (idempotent).
  NODE_ID="$(garage node id -q 2>/dev/null | cut -d@ -f1)"
  [[ -n "$NODE_ID" ]] || die "Could not read Garage node id."
  if ! garage layout show 2>/dev/null | grep -q "${NODE_ID:0:12}"; then
    garage layout assign -z dc1 -c 100G "$NODE_ID"
    CUR_VER="$(garage layout show 2>/dev/null | sed -n 's/.*layout version:[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)"
    CUR_VER="${CUR_VER:-0}"
    garage layout apply --version "$((CUR_VER + 1))"
    c_ok "Garage single-node layout applied."
  fi

  # Bucket, key, public web read (idempotent).
  garage bucket info "$GARAGE_BUCKET" >/dev/null 2>&1 || garage bucket create "$GARAGE_BUCKET"
  garage key info mastodon-key >/dev/null 2>&1 || garage key create mastodon-key

  KEY_INFO="$(garage key info mastodon-key --show-secret 2>/dev/null)"
  KEY_ID="$(printf '%s' "$KEY_INFO" | grep -oE 'GK[0-9a-fA-F]+' | head -1)"
  SECRET_KEY="$(printf '%s' "$KEY_INFO" | awk -F'[:[:space:]]+' '/[Ss]ecret key/{print $NF}' | grep -oE '[0-9a-fA-F]{64}' | head -1)"
  [[ -n "$KEY_ID" && -n "$SECRET_KEY" ]] || die "Could not parse Garage key id/secret from 'garage key info'."

  garage bucket allow --read --write --owner "$GARAGE_BUCKET" --key "$KEY_ID"
  garage bucket website --allow "$GARAGE_BUCKET"
  garage bucket alias "$GARAGE_BUCKET" "$MEDIA_DOMAIN" 2>/dev/null || true   # alias may already exist

  secret_set AWS_ACCESS_KEY_ID "$KEY_ID"
  secret_set AWS_SECRET_ACCESS_KEY "$SECRET_KEY"
  c_ok "Garage bucket '${GARAGE_BUCKET}' ready; public web reads enabled; key stored."
  mark_done 5
fi

# ===========================================================================
# Phase 6: Mastodon dependencies & config
# ===========================================================================
if is_done 6; then c_warn "Phase 6 done — skipping."; else
  c_hdr "Phase 6: Mastodon dependencies & config"
  m_run "bundle config set --local deployment 'true'"
  m_run "bundle config set --local without 'development test'"
  m_run "bundle install -j\$(nproc)"
  m_run "yarn install --immutable"

  # Application secrets (generated once; reused on re-run).
  SECRET_KEY_BASE="$(secret_get SECRET_KEY_BASE)"; [[ -n "$SECRET_KEY_BASE" ]] || { SECRET_KEY_BASE="$(m_run 'RAILS_ENV=production bundle exec rails secret')"; secret_set SECRET_KEY_BASE "$SECRET_KEY_BASE"; }
  OTP_SECRET="$(secret_get OTP_SECRET)";           [[ -n "$OTP_SECRET" ]]       || { OTP_SECRET="$(m_run 'RAILS_ENV=production bundle exec rails secret')"; secret_set OTP_SECRET "$OTP_SECRET"; }

  VAPID_PRIVATE_KEY="$(secret_get VAPID_PRIVATE_KEY)"
  VAPID_PUBLIC_KEY="$(secret_get VAPID_PUBLIC_KEY)"
  if [[ -z "$VAPID_PRIVATE_KEY" || -z "$VAPID_PUBLIC_KEY" ]]; then
    VAPID_OUT="$(m_run "SECRET_KEY_BASE=${SECRET_KEY_BASE} OTP_SECRET=${OTP_SECRET} RAILS_ENV=production bundle exec rails mastodon:webpush:generate_vapid_key")"
    VAPID_PRIVATE_KEY="$(printf '%s' "$VAPID_OUT" | awk -F= '/^VAPID_PRIVATE_KEY=/{print $2}')"
    VAPID_PUBLIC_KEY="$(printf '%s' "$VAPID_OUT" | awk -F= '/^VAPID_PUBLIC_KEY=/{print $2}')"
    secret_set VAPID_PRIVATE_KEY "$VAPID_PRIVATE_KEY"
    secret_set VAPID_PUBLIC_KEY "$VAPID_PUBLIC_KEY"
  fi

  AR_PRIMARY="$(secret_get AR_ENCRYPTION_PRIMARY_KEY)"
  AR_DETERMINISTIC="$(secret_get AR_ENCRYPTION_DETERMINISTIC_KEY)"
  AR_SALT="$(secret_get AR_ENCRYPTION_KEY_DERIVATION_SALT)"
  if [[ -z "$AR_PRIMARY" || -z "$AR_DETERMINISTIC" || -z "$AR_SALT" ]]; then
    ENC_OUT="$(m_run "SECRET_KEY_BASE=${SECRET_KEY_BASE} RAILS_ENV=production bundle exec rails db:encryption:init")"
    AR_PRIMARY="$(printf '%s' "$ENC_OUT" | awk -F': ' '/primary_key:/{gsub(/ /,"",$2); print $2}')"
    AR_DETERMINISTIC="$(printf '%s' "$ENC_OUT" | awk -F': ' '/deterministic_key:/{gsub(/ /,"",$2); print $2}')"
    AR_SALT="$(printf '%s' "$ENC_OUT" | awk -F': ' '/key_derivation_salt:/{gsub(/ /,"",$2); print $2}')"
    [[ -n "$AR_PRIMARY" && -n "$AR_DETERMINISTIC" && -n "$AR_SALT" ]] || die "Could not parse db:encryption:init output."
    secret_set AR_ENCRYPTION_PRIMARY_KEY "$AR_PRIMARY"
    secret_set AR_ENCRYPTION_DETERMINISTIC_KEY "$AR_DETERMINISTIC"
    secret_set AR_ENCRYPTION_KEY_DERIVATION_SALT "$AR_SALT"
  fi

  TOKENS=(
    [WEB_DOMAIN]="$WEB_DOMAIN"
    [MEDIA_DOMAIN]="$MEDIA_DOMAIN"
    [GARAGE_BUCKET]="$GARAGE_BUCKET"
    [SECRET_KEY_BASE]="$SECRET_KEY_BASE"
    [OTP_SECRET]="$OTP_SECRET"
    [VAPID_PRIVATE_KEY]="$VAPID_PRIVATE_KEY"
    [VAPID_PUBLIC_KEY]="$VAPID_PUBLIC_KEY"
    [AR_ENCRYPTION_PRIMARY_KEY]="$AR_PRIMARY"
    [AR_ENCRYPTION_DETERMINISTIC_KEY]="$AR_DETERMINISTIC"
    [AR_ENCRYPTION_KEY_DERIVATION_SALT]="$AR_SALT"
    [AWS_ACCESS_KEY_ID]="$(secret_get AWS_ACCESS_KEY_ID)"
    [AWS_SECRET_ACCESS_KEY]="$(secret_get AWS_SECRET_ACCESS_KEY)"
    [SMTP_SERVER]="$SMTP_SERVER"
    [SMTP_PORT]="$SMTP_PORT"
    [SMTP_LOGIN]="$SMTP_LOGIN"
    [SMTP_PASSWORD]="$SMTP_PASSWORD"
    [SMTP_FROM_ADDRESS]="$SMTP_FROM_ADDRESS"
  )
  render_template "${SETUP_DIR}/env.production.template" "${LIVE}/.env.production"
  chown mastodon:mastodon "${LIVE}/.env.production"; chmod 600 "${LIVE}/.env.production"
  c_ok ".env.production rendered."
  mark_done 6
fi

# ===========================================================================
# Phase 7: Database setup
# ===========================================================================
if is_done 7; then c_warn "Phase 7 done — skipping."; else
  c_hdr "Phase 7: Database setup"
  m_run "RAILS_ENV=production bundle exec rails db:setup"
  c_ok "Database created, schema loaded, seeded."
  mark_done 7
fi

# ===========================================================================
# Phase 8: Asset compilation
# ===========================================================================
if is_done 8; then c_warn "Phase 8 done — skipping."; else
  c_hdr "Phase 8: Asset compilation"
  m_run "RAILS_ENV=production NODE_OPTIONS=--max-old-space-size=2048 bundle exec rails assets:precompile"
  c_ok "Assets precompiled."
  mark_done 8
fi

# ===========================================================================
# Phase 9: Mastodon systemd services
# ===========================================================================
if is_done 9; then c_warn "Phase 9 done — skipping."; else
  c_hdr "Phase 9: Mastodon systemd services"
  for u in mastodon-web mastodon-sidekiq; do
    install -m 0644 "${LIVE}/dist/${u}.service" "/etc/systemd/system/${u}.service"
  done
  STREAMING_UNIT="mastodon-streaming"
  if [[ -f "${LIVE}/dist/mastodon-streaming.service" ]]; then
    install -m 0644 "${LIVE}/dist/mastodon-streaming.service" /etc/systemd/system/mastodon-streaming.service
  elif [[ -f "${LIVE}/dist/mastodon-streaming@.service" ]]; then
    install -m 0644 "${LIVE}/dist/mastodon-streaming@.service" /etc/systemd/system/mastodon-streaming@.service
    STREAMING_UNIT="mastodon-streaming@4000"
  else
    die "No streaming unit found in ${LIVE}/dist/."
  fi
  state_put STREAMING_UNIT "$STREAMING_UNIT"
  systemctl daemon-reload
  systemctl enable --now mastodon-web mastodon-sidekiq "$STREAMING_UNIT"
  c_ok "Started mastodon-web, mastodon-sidekiq, ${STREAMING_UNIT}."
  mark_done 9
fi

# ===========================================================================
# Phase 10: nginx (HTTP on loopback — no TLS at origin)
# ===========================================================================
if is_done 10; then c_warn "Phase 10 done — skipping."; else
  c_hdr "Phase 10: nginx"
  TOKENS=( [WEB_DOMAIN]="$WEB_DOMAIN" )
  render_template "${SETUP_DIR}/nginx/mastodon" /etc/nginx/sites-available/mastodon
  ln -sf /etc/nginx/sites-available/mastodon /etc/nginx/sites-enabled/mastodon
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
  c_ok "nginx configured and reloaded."
  mark_done 10
fi

# ===========================================================================
# Phase 11: Cloudflare Tunnel (created here via the Cloudflare API)
# ===========================================================================
# The tunnel, its credentials, and the proxied DNS records are all provisioned
# from inside the container via the Cloudflare API — no browser login and no
# cloudflared run on any other machine. The tunnel is locally-managed
# (config_src=local), so ingress comes from our rendered config.yml.
if is_done 11; then c_warn "Phase 11 done — skipping."; else
  c_hdr "Phase 11: Cloudflare Tunnel"
  # API token is requested here (only when this phase runs) and never persisted.
  [[ -n "${CF_API_TOKEN:-}" ]] || prompt_secret CF_API_TOKEN \
    "Cloudflare API token (Account:Cloudflare Tunnel:Edit + Zone:DNS:Edit + Zone:Read)"

  if ! command -v cloudflared >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main" \
      > /etc/apt/sources.list.d/cloudflared.list
    apt update && apt install -y cloudflared
  fi

  # 1) Find or create the named, locally-managed tunnel.
  RESP="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${CF_TUNNEL_NAME}&is_deleted=false")" \
    || die "Cloudflare API call failed — check the API token and account ID."
  CF_TUNNEL_ID="$(jq -r '.result[0].id // empty' <<<"$RESP")"
  if [[ -z "$CF_TUNNEL_ID" ]]; then
    RESP="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
      "$(jq -nc --arg n "$CF_TUNNEL_NAME" '{name:$n, config_src:"local"}')")"
    CF_TUNNEL_ID="$(jq -r '.result.id' <<<"$RESP")"
    c_ok "Created tunnel '${CF_TUNNEL_NAME}' (${CF_TUNNEL_ID})."
  else
    c_ok "Reusing existing tunnel '${CF_TUNNEL_NAME}' (${CF_TUNNEL_ID})."
  fi
  state_put CF_TUNNEL_ID "$CF_TUNNEL_ID"

  # 2) Fetch the connector token and derive the credentials file cloudflared needs.
  TOKEN="$(jq -r '.result' <<<"$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/token")")"
  TOKDEC="$(base64 -d <<<"$TOKEN" 2>/dev/null)" || die "Could not decode the tunnel token."
  mkdir -p /etc/cloudflared
  jq -n --argjson t "$TOKDEC" '{AccountTag:$t.a, TunnelID:$t.t, TunnelSecret:$t.s}' \
    > "/etc/cloudflared/${CF_TUNNEL_ID}.json"
  chmod 600 "/etc/cloudflared/${CF_TUNNEL_ID}.json"

  # 3) Provision proxied DNS (CNAME -> <tunnel>.cfargotunnel.com) for both hostnames.
  CF_TARGET="${CF_TUNNEL_ID}.cfargotunnel.com"
  WEB_ZONE="$(cf_zone_id "$WEB_DOMAIN")"     || die "No active Cloudflare zone found for ${WEB_DOMAIN}."
  MEDIA_ZONE="$(cf_zone_id "$MEDIA_DOMAIN")" || die "No active Cloudflare zone found for ${MEDIA_DOMAIN}."
  cf_dns_upsert "$WEB_ZONE"   "$WEB_DOMAIN"   "$CF_TARGET"
  cf_dns_upsert "$MEDIA_ZONE" "$MEDIA_DOMAIN" "$CF_TARGET"
  c_ok "DNS set (proxied): ${WEB_DOMAIN}, ${MEDIA_DOMAIN} -> ${CF_TARGET}"

  # 4) Render ingress and run the tunnel from our systemd unit.
  TOKENS=( [CF_TUNNEL_ID]="$CF_TUNNEL_ID" [MEDIA_DOMAIN]="$MEDIA_DOMAIN" [WEB_DOMAIN]="$WEB_DOMAIN" )
  render_template "${SETUP_DIR}/cloudflared/config.yml" /etc/cloudflared/config.yml
  systemctl disable --now cloudflared 2>/dev/null || true
  install -m 0644 "${SETUP_DIR}/systemd/cloudflared.service" /etc/systemd/system/cloudflared.service
  systemctl daemon-reload
  systemctl enable --now cloudflared
  unset CF_API_TOKEN
  c_ok "cloudflared tunnel ${CF_TUNNEL_ID} started."
  mark_done 11
fi

# ===========================================================================
# Phase 12: Create initial owner account
# ===========================================================================
if is_done 12; then c_warn "Phase 12 done — skipping."; else
  c_hdr "Phase 12: Create initial owner account"
  OWNER_PW="$(secret_get OWNER_PASSWORD)"
  if [[ -z "$OWNER_PW" ]]; then
    OUT="$(m_run "RAILS_ENV=production bin/tootctl accounts create ${MASTODON_USERNAME} --email ${MASTODON_USER_EMAIL} --confirmed --role Owner" 2>&1)" || true
    OWNER_PW="$(printf '%s' "$OUT" | grep -iE 'password' | grep -oE '[A-Za-z0-9]{16,}' | head -1)"
    if [[ -n "$OWNER_PW" ]]; then
      secret_set OWNER_PASSWORD "$OWNER_PW"
    else
      c_warn "Could not parse a generated password. tootctl output was:"
      printf '%s\n' "$OUT"
    fi
  fi
  if [[ -n "$OWNER_PW" ]]; then
    printf '\n\033[1;33m*** SAVE THIS — owner password for %s: %s ***\033[0m\n\n' "$MASTODON_USERNAME" "$OWNER_PW"
  fi
  mark_done 12
fi

# ===========================================================================
# Phase 13: Maintenance cron
# ===========================================================================
if is_done 13; then c_warn "Phase 13 done — skipping."; else
  c_hdr "Phase 13: Maintenance cron"
  crontab -u mastodon - <<'CRON'
# Remove remote media cache older than 28 days (runs at :15 past every hour)
15 * * * * cd /home/mastodon/live && RAILS_ENV=production bin/tootctl media remove --days=28 2>/dev/null
# Weekly: remove orphaned media
0 3 * * 0 cd /home/mastodon/live && RAILS_ENV=production bin/tootctl media remove-orphans 2>/dev/null
# Weekly: vacuum old statuses from accounts you don't follow (keeps DB lean)
0 4 * * 0 cd /home/mastodon/live && RAILS_ENV=production bin/tootctl statuses remove --days=90 2>/dev/null
CRON
  c_ok "Cron installed for the mastodon user."
  mark_done 13
fi

# ===========================================================================
# Phase 14: Final health check
# ===========================================================================
c_hdr "Phase 14: Final health check"
STREAMING_UNIT="${STREAMING_UNIT:-mastodon-streaming}"
declare -a RESULTS=()
check_unit() { systemctl is-active --quiet "$1" && RESULTS+=("$1|PASS") || RESULTS+=("$1|FAIL"); }
check_http() {  # name url
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$2" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && RESULTS+=("$1|PASS ($code)") || RESULTS+=("$1|FAIL ($code)")
}

for u in postgresql redis-server nginx mastodon-web mastodon-sidekiq "$STREAMING_UNIT" garage cloudflared; do
  check_unit "$u"
done
check_http "web /health"        "http://127.0.0.1:3000/health"
check_http "streaming /health"  "http://127.0.0.1:4000/api/v1/streaming/health"
RESULTS+=("nginx loopback|$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${WEB_DOMAIN}" http://127.0.0.1:80/health 2>/dev/null || echo 000)")
garage bucket info "$GARAGE_BUCKET" >/dev/null 2>&1 && RESULTS+=("garage bucket|PASS") || RESULTS+=("garage bucket|FAIL")
( mountpoint -q "$GARAGE_DATA" && [[ -w "$GARAGE_DATA" ]] ) && RESULTS+=("garage-data mount|PASS") || RESULTS+=("garage-data mount|FAIL")

echo
printf '%-26s %s\n' "CHECK" "RESULT"
printf '%-26s %s\n' "-----" "------"
for r in "${RESULTS[@]}"; do printf '%-26s %s\n' "${r%%|*}" "${r##*|}"; done

OWNER_PW="$(secret_get OWNER_PASSWORD)"
cat <<EOF

==========================================================================
 Mastodon deployment complete.

 1. Your instance:  https://${WEB_DOMAIN}
 2. Log in as '${MASTODON_USERNAME}'$( [[ -n "$OWNER_PW" ]] && echo " with password: ${OWNER_PW}" || true )
 3. Admin -> Site Settings: fill in instance details
 4. Confirm the tunnel is healthy: Cloudflare Zero Trust -> Networks -> Tunnels
 5. Disable Bot Fight Mode (Security -> Bots); confirm WebSockets ON (Network -> WebSockets)

 Secrets are stored (chmod 600) at: ${SECRETS_FILE}
==========================================================================
EOF

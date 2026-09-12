# Deploying the Geonix Wrench API to your own server

Everything here is self-hosted: FastAPI plus a SQLite file, with Whisper running
locally. No managed service is required, and the only outbound dependencies are
Stripe, Firebase, and whichever model provider you choose.

## What the server needs

| | |
|---|---|
| RAM | 2 GB minimum, 4 GB comfortable. Whisper `small` holds its weights in memory. |
| Disk | ~5 GB. The model is ~500 MB, the rest is Docker images and your data. |
| CPU | Any modern x86-64 or ARM64. No GPU needed; transcription is slower without one. |
| Ports | 80 and 443 reachable from the internet, and a DNS A record pointing at the box. |

Both mobile platforms refuse plain HTTP to a public host, so **a real
certificate is not optional** — an API without one is an API the app cannot use.
Caddy handles that for you below.

## First deploy

```bash
git clone <your-repo> && cd geonix_wrench/geonix_wrench_backend

cp .env.example .env          # then fill it in — see the notes in the file
# Put the real Firebase service account next to the compose file:
#   firebase-service-account.json

# Set your hostname in the Caddyfile (replace api.example.com)
$EDITOR Caddyfile

docker compose up -d --build
docker compose logs -f api
```

First boot downloads the Whisper model, so it takes several minutes and the
container reports unhealthy until it finishes. That is expected — the healthcheck
allows 10 minutes for it. Watch for `Whisper model ready` in the logs.

Verify from anywhere:

```bash
curl https://api.example.com/health            # {"status":"ok"}
curl -i https://api.example.com/api/auth/me    # 401 — alive and enforcing auth
```

A 401 on the second is the **correct** answer: it proves the API is up and that
authentication is being enforced. It was a 403 until the two were separated —
every authentication failure is a 401 now, and 403 is reserved for a caller who
is authenticated and still not allowed to do the thing. The app signs itself
out on the first and shows a message on the second, so the distinction is load
bearing.

## Point the app at it

```bash
flutter build apk    --release --dart-define=API_BASE_URL=https://api.example.com
flutter build ipa    --release --dart-define=API_BASE_URL=https://api.example.com
flutter build macos  --release --dart-define=API_BASE_URL=https://api.example.com
```

Release builds have no default host and fail loudly at startup without this.
Debug builds can be repointed from **Settings → Development server** instead of
rebuilt.

## Stripe webhook

Stripe must be able to reach you, or a cancellation or failed payment never
reflects in the app and a lapsed customer keeps working:

1. Stripe Dashboard → Developers → Webhooks → Add endpoint.
2. URL: `https://api.example.com/api/billing/webhook`
3. Events: `customer.subscription.created`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.payment_succeeded`,
   `invoice.payment_failed`.
4. Copy the signing secret into `STRIPE_WEBHOOK_SECRET` and restart.

Then confirm the advertised prices actually match Stripe's price objects — the
site says €35 and €60/seat for North America and Australia, €29 and €50/seat
for Europe, and €10 and €18/seat for Latin America and the rest of the world,
and Stripe charges whatever its own objects hold. Every region needs its own
pair of price objects (the `*_EU` / `*_AU` / `*_LATAM` / `*_ROW` variables in
`.env`; the un-suffixed pair is the North America baseline); a region left
unconfigured is served the baseline prices:

```bash
docker compose exec api python -m price_check
```

## Backups

Everything that matters is in the `wrench-data` volume: the SQLite database, the
uploaded logos, and the model cache. Only the first two are irreplaceable.

```bash
# SQLite must be copied with its own tooling — plain cp of a live database can
# capture a half-written page.
docker compose exec api sqlite3 /data/geonix_wrench.db ".backup '/data/backup.db'"
docker compose cp api:/data/backup.db ./backup-$(date +%F).db
docker compose cp api:/data/logos ./logos-backup
```

Job cards contain customer names, vehicles and transcripts, so treat those
backups as personal data: encrypt them at rest and delete them on a schedule.

## Updating

```bash
git pull
docker compose up -d --build
```

The database migrates itself on startup (`init_db` adds columns idempotently),
so there is no separate migration step.

## Without Docker

If you would rather run it directly, `systemd/geonix-wrench.service` is a unit
file for that. You still need a reverse proxy terminating TLS in front of it —
never expose uvicorn to the internet directly.

### The geonix.site deployment

That is what the repository root is set up for, and it is a different shape
from the Docker path above:

```
internet ──▶ Cloudflare ──▶ cloudflared ──▶ nginx ──▶ uvicorn (127.0.0.1:8000)
```

| File | What it is |
|---|---|
| `config.yml` | Tunnel ingress. Both hostnames point at nginx on **:80**, not at uvicorn. |
| `nginx-geonix.conf` | Serves `geonix_website/dist` at geonix.site, proxies `/api/` and api.geonix.site to uvicorn. |
| `setup_nginx.sh` | Inspects the server's nginx, installs the site, `nginx -t`, reloads, verifies. |
| `geonix-backend.service` | The systemd unit for uvicorn. |

TLS is Cloudflare's here, so nginx listens on plain HTTP on loopback and needs
no certificate — Caddy above exists to solve a problem this deployment does not
have.

Two things that look like nginx faults and are not:

- **A tunnel still pointing at `http://localhost:8000`** skips nginx entirely,
  so the website 404s however the site file is written.
- **`FRONTEND_DIST_DIR` set** makes uvicorn serve the site as well, which is a
  second copy to keep in step. Leave it empty when nginx is in front.

## Things that will bite you

- **`ALLOWED_ORIGINS` unset.** The API accepts any origin without credentials and
  warns on every boot. Set it before you take payment.
- **`LLM_PROVIDER=stub`.** Job cards become keyword-matched guesses with no AI at
  all. The server warns loudly at boot; believe it.
- **`ENABLE_API_DOCS=true`.** Publishes your entire route map and schemas
  publicly. Leave it off.
- **SQLite and concurrency.** Fine for a handful of shops. If you outgrow one
  box, that is the piece to replace first.
- **Whisper memory.** Each concurrent transcription worker holds its own copy of
  the model. `WHISPER_MAX_CONCURRENT=1` is the default for that reason; raise it
  only with RAM to spare.
- **`REQUIRE_DEVICE_ID` left `false`.** Device limits are only enforced for
  clients that send an `X-Device-Id` header, so until this is `true` an old app
  build — or anyone dropping the header — is simply not counted. Leave it off
  until every shipped build sends it, then turn it on; a quota you cannot opt
  out of is the whole point.
- **`DEVICE_LIMIT_POLICY=reject` with no way to free a slot.** The default
  (`evict_oldest`) signs the least recently used device out and lets the new one
  in. `reject` refuses the new sign-in instead, which means the user has to sign
  a device out from another device — make sure that is a workflow your customers
  can actually follow before switching.
- **Running more than one API worker.** The device table is in SQLite and is
  written under `BEGIN IMMEDIATE`, so the quota itself stays correct across
  workers — unlike the in-process rate limiter, which does not. Both are on the
  list to move if you ever run more than one box.

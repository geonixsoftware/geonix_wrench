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
curl -i https://api.example.com/api/auth/me    # 403 — alive and enforcing auth
```

A 403 on the second is the **correct** answer: it proves the API is up and that
authentication is being enforced.

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
site says €29 and €25/seat, and Stripe charges whatever its own objects hold:

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

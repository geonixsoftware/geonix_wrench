import os
from dotenv import load_dotenv

load_dotenv()

DB_PATH = os.getenv("DB_PATH", "geonix_wrench.db")

# "ollama" | "anthropic" | "stub".
#
# `stub` is a DEV-ONLY offline extractor (see stub_extraction.py): no model, no
# network, keyword matching only. It exists so the app can be worked on when no
# provider is reachable. It produces guesses, not extractions — the server logs
# a warning on every startup while it is selected, and every job card it makes
# is flagged as machine-guessed. Never ship it.
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "ollama")

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.1:8b")
# How long Ollama keeps the model resident after a request. Its default is 5
# minutes, so the first job card after a quiet spell pays a full model load
# before any tokens are generated. "-1" pins it in memory for good.
OLLAMA_KEEP_ALIVE = os.getenv("OLLAMA_KEEP_ALIVE", "30m")

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
ANTHROPIC_MODEL = os.getenv("ANTHROPIC_MODEL", "claude-opus-5")

# How long one extraction call may take, and how many times the SDK may retry
# it. Both are bounded on purpose.
#
# The SDK defaults are a 10-minute timeout and 2 retries, and timeouts are
# retried — so a provider that stops responding holds a thread for up to half
# an hour on a request whose client gave up after 180s (AudioUploadService.
# timeout). The server was still working on recordings nobody was waiting for,
# which is exactly the pile-up the transcription queue ceiling exists to avoid.
#
# 45s x 2 attempts = 90s worst case, leaving the rest of the client's 180s
# budget to transcription.
ANTHROPIC_TIMEOUT_SECONDS = float(os.getenv("ANTHROPIC_TIMEOUT_SECONDS", "45"))
ANTHROPIC_MAX_RETRIES = int(os.getenv("ANTHROPIC_MAX_RETRIES", "1"))

# `small` rather than `medium`. Measured on a 24s job-card recording, 4 requests
# at once on an 8-core box: medium/beam=3 took 62s per request, small/beam=1 took
# 16.5s — 3.7x the throughput. Transcripts were equivalent on the details a job
# card is built from (vehicle, parts, quantities, labour time): both produced
# "2019 Volkswagen Golf", "5W-30", "3mm", "2.5 hours".
#
# Caveat worth knowing: that was clean audio. `small` degrades faster than
# `medium` on noisy workshops and strong accents, so if extraction quality drops
# in the field, set WHISPER_MODEL_SIZE=medium (and expect the old latency back).
WHISPER_MODEL_SIZE = os.getenv("WHISPER_MODEL_SIZE", "small")
WHISPER_DEVICE = "cpu"
# int8 is much faster than float32 on CPU with only a small accuracy cost —
# needed to keep transcription within the client's upload timeout.
WHISPER_COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
# Auto language-detection runs on the first ~30s and is unreliable on short
# or noisy clips (low-confidence guesses cascade into garbled transcripts).
# Pin a language by default; set WHISPER_LANGUAGE=auto to re-enable detection.
_raw_whisper_language = os.getenv("WHISPER_LANGUAGE", "en")
WHISPER_LANGUAGE = None if _raw_whisper_language.lower() == "auto" else _raw_whisper_language

CPU_COUNT = os.cpu_count() or 4

# How many recordings may be transcribed simultaneously.
#
# Transcription is CPU-bound and runs at roughly 1x real time on the medium
# model, so raising this does not make a single request faster — it only lets
# more of them share the same cores and finish later. Each concurrent slot also
# holds its own model instance (~1.5 GB for `medium`), so raise it only with
# both spare cores and spare RAM.
#
# The default used to be a flat 4, and paired with the core split below that
# was actively slow on the box this runs on. Four slots on a 4-core VPS means
# one core each, so a mechanic recording alone — the normal case, all day —
# had three idle cores while their transcription crawled on the fourth. The
# ceiling was sized for a burst that a single-shop server almost never sees,
# and every ordinary request paid for it.
#
# Scaling with the machine instead: small boxes hand the whole CPU to one
# recording and let the queue absorb bursts, and only a genuinely wide server
# splits itself up.
_default_whisper_concurrency = 1 if CPU_COUNT <= 4 else max(1, CPU_COUNT // 4)
WHISPER_MAX_CONCURRENT = max(
    1, int(os.getenv("WHISPER_MAX_CONCURRENT", str(_default_whisper_concurrency)))
)

# How many more recordings may wait for a slot before new uploads are rejected.
#
# Without a ceiling, a burst queues without bound: every client waits past its
# own upload timeout, gives up, and retries — so the server keeps transcribing
# recordings nobody is still waiting for. Shedding load early is what keeps the
# queue drainable.
WHISPER_MAX_QUEUED = max(0, int(os.getenv("WHISPER_MAX_QUEUED", "10")))

# Roughly how long one queued recording takes to clear, used for Retry-After.
# Measured ~16.5s for a 24s recording at 4-way concurrency; 20 leaves headroom.
WHISPER_SECONDS_PER_JOB = max(1, int(os.getenv("WHISPER_SECONDS_PER_JOB", "20")))

# CPU threads per model instance.
#
# CTranslate2 grabs every core by default, so N concurrent models each try to
# use the whole machine and spend their time fighting each other. Dividing the
# cores between the slots is what makes raising WHISPER_MAX_CONCURRENT actually
# increase throughput rather than just latency.
WHISPER_CPU_THREADS = max(
    1,
    int(
        os.getenv(
            "WHISPER_CPU_THREADS",
            str(max(1, CPU_COUNT // WHISPER_MAX_CONCURRENT)),
        )
    ),
)

# Greedy decoding. Beam search multiplies decoder cost for accuracy that did not
# show up in job-card fields — on the benchmark recording beam=3 was 2x slower
# and, on `small`, very slightly worse ("notice" for "noticed", dropped "Used").
WHISPER_BEAM_SIZE = max(1, int(os.getenv("WHISPER_BEAM_SIZE", "1")))

ALLOWED_AUDIO_EXTENSIONS = {".m4a", ".wav", ".webm"}

# Audio was previously read into memory whole with no ceiling, so one request
# could exhaust the process. 25 MB is roughly 25 minutes of m4a at 128 kbps,
# far past any realistic job-card dictation.
MAX_AUDIO_SIZE_BYTES = int(os.getenv("MAX_AUDIO_SIZE_BYTES", str(25 * 1024 * 1024)))

# Read uploads in chunks so the cap can be enforced before the whole body is
# resident.
UPLOAD_CHUNK_BYTES = 1024 * 1024

# Caps on text that reaches the LLM prompt and the PDF renderer. Unbounded
# strings inflate model cost and can stall reportlab.
MAX_TRANSCRIPT_CHARS = int(os.getenv("MAX_TRANSCRIPT_CHARS", "20000"))
MAX_FIELD_CHARS = int(os.getenv("MAX_FIELD_CHARS", "2000"))
MAX_PARTS_PER_JOBCARD = int(os.getenv("MAX_PARTS_PER_JOBCARD", "100"))

# CORS. Wildcard plus credentials let any origin call the API and read the
# response; Starlette echoes the caller's Origin back in that combination.
# Set ALLOWED_ORIGINS to a comma-separated list in production.
_raw_origins = os.getenv("ALLOWED_ORIGINS", "").strip()
ALLOWED_ORIGINS = [o.strip() for o in _raw_origins.split(",") if o.strip()]

# The built website, optionally served by this same process.
#
# Empty by default because nginx owns the site in the deployed setup: it serves
# geonix_website/dist itself and proxies only /api/ here, so a second copy
# served from this process would be a second thing to keep in step. main.py
# skips the mount when this is empty or missing rather than failing to boot.
#
# Set it to run without nginx at all — uvicorn will then serve the site and the
# API on one port:
#
#   FRONTEND_DIST_DIR=/var/www/geonix_wrench/geonix_website/dist
FRONTEND_DIST_DIR = os.getenv("FRONTEND_DIST_DIR", "").strip()

# How long a closed account is remembered, so a Firebase token issued before
# the deletion cannot put the row back. Firebase ID tokens last an hour; a day
# is comfortable headroom without keeping the record any longer than the job
# needs. See the deleted_accounts table in database.py.
DELETED_ACCOUNT_TOMBSTONE_HOURS = int(os.getenv("DELETED_ACCOUNT_TOMBSTONE_HOURS", "24"))

# Public /docs, /redoc and /openapi.json hand an attacker the whole route map.
# Off unless explicitly enabled.
ENABLE_API_DOCS = os.getenv("ENABLE_API_DOCS", "false").lower() == "true"

# Simple per-user request ceilings. Transcription runs Whisper and calls a paid
# model, so it gets its own tighter budget.
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
RATE_LIMIT_DEFAULT_PER_WINDOW = int(os.getenv("RATE_LIMIT_DEFAULT_PER_WINDOW", "120"))
RATE_LIMIT_AUDIO_PER_WINDOW = int(os.getenv("RATE_LIMIT_AUDIO_PER_WINDOW", "10"))

# Everything a shop is plausibly handed its logo as. SVG is included and
# rasterised on save (see logo_storage) — it is the format a designer delivers,
# and rejecting it was the most common reason an upload failed.
ALLOWED_LOGO_EXTENSIONS = {
    ".svg",
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".gif",
    ".bmp",
    ".tif",
    ".tiff",
    ".heic",
    ".heif",
}
MAX_LOGO_SIZE_BYTES = 5 * 1024 * 1024
LOGO_STORAGE_DIR = os.getenv("LOGO_STORAGE_DIR", "storage/logos")
MAX_LOGO_DIMENSION_PX = 1000
DEFAULT_LOGO_PATH = os.path.join("assets", "default_logo.png")

FIREBASE_SERVICE_ACCOUNT_PATH = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH", "firebase-service-account.json")
HANDLE_MIN_LENGTH = 3
HANDLE_MAX_LENGTH = 30

SUPPORTED_CURRENCIES = {
    "USD": "$",
    "EUR": "€",
    "GBP": "£",
    "ZAR": "R",
    "AUD": "A$",
    "CAD": "C$",
}
DEFAULT_CURRENCY = "USD"
DEFAULT_LABOR_RATE = float(os.getenv("DEFAULT_LABOR_RATE", "85.0"))

# Stripe billing configuration. Prices are monthly recurring prices configured
# in the Stripe dashboard; the webhook secret is used to verify event signatures.
STRIPE_API_KEY = os.getenv("STRIPE_API_KEY")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET")

# Prices are regional. Five regions, resolved from the customer's country by
# regions.region_for_country:
#
#   na      North America — the baseline price
#   eu      Europe
#   au      Australia
#   latam   Latin America and the Caribbean
#   row     everywhere else
#
# Each region has its own pair of Stripe price objects and its own advertised
# figures. The baseline pair keeps the un-suffixed names so existing deploys and
# imports stay valid.
INDIVIDUAL_PRICE_ID = os.getenv("INDIVIDUAL_PRICE_ID", "price_1U3FIdAsnEuiNQHH9y7WdAqI")
TEAM_PRICE_ID = os.getenv("TEAM_PRICE_ID", "price_1U3JqDAsnEuiNQHHLIXIjlV7")
# Empty until the operator creates the regional price objects in the Stripe
# dashboard. While a region's ids are unset, regions.pricing_for_region serves
# that region the baseline prices — quote and charge always travel together.
INDIVIDUAL_PRICE_ID_EU = os.getenv("INDIVIDUAL_PRICE_ID_EU", "")
TEAM_PRICE_ID_EU = os.getenv("TEAM_PRICE_ID_EU", "")
INDIVIDUAL_PRICE_ID_AU = os.getenv("INDIVIDUAL_PRICE_ID_AU", "")
TEAM_PRICE_ID_AU = os.getenv("TEAM_PRICE_ID_AU", "")
INDIVIDUAL_PRICE_ID_LATAM = os.getenv("INDIVIDUAL_PRICE_ID_LATAM", "")
TEAM_PRICE_ID_LATAM = os.getenv("TEAM_PRICE_ID_LATAM", "")
INDIVIDUAL_PRICE_ID_ROW = os.getenv("INDIVIDUAL_PRICE_ID_ROW", "")
TEAM_PRICE_ID_ROW = os.getenv("TEAM_PRICE_ID_ROW", "")
TEAM_MIN_SEATS = int(os.getenv("TEAM_MIN_SEATS", "2"))

# Advertised prices, served to the app and the website so the figure is defined
# once instead of being retyped in each client.
#
# !! These are DISPLAY values only. Stripe charges whatever the price objects
# above are set to in the dashboard — changing a number here does not change
# what a customer pays. Keep the two in step, or a customer is quoted one amount
# and billed another. `python -m price_check` verifies they match, per region.
INDIVIDUAL_PRICE_PER_MONTH = float(os.getenv("INDIVIDUAL_PRICE_PER_MONTH", "35"))
TEAM_PRICE_PER_SEAT = float(os.getenv("TEAM_PRICE_PER_SEAT", "60"))
INDIVIDUAL_PRICE_PER_MONTH_EU = float(os.getenv("INDIVIDUAL_PRICE_PER_MONTH_EU", "29"))
TEAM_PRICE_PER_SEAT_EU = float(os.getenv("TEAM_PRICE_PER_SEAT_EU", "50"))
INDIVIDUAL_PRICE_PER_MONTH_AU = float(os.getenv("INDIVIDUAL_PRICE_PER_MONTH_AU", "35"))
TEAM_PRICE_PER_SEAT_AU = float(os.getenv("TEAM_PRICE_PER_SEAT_AU", "60"))
INDIVIDUAL_PRICE_PER_MONTH_LATAM = float(os.getenv("INDIVIDUAL_PRICE_PER_MONTH_LATAM", "10"))
TEAM_PRICE_PER_SEAT_LATAM = float(os.getenv("TEAM_PRICE_PER_SEAT_LATAM", "18"))
INDIVIDUAL_PRICE_PER_MONTH_ROW = float(os.getenv("INDIVIDUAL_PRICE_PER_MONTH_ROW", "10"))
TEAM_PRICE_PER_SEAT_ROW = float(os.getenv("TEAM_PRICE_PER_SEAT_ROW", "18"))
BILLING_CURRENCY = os.getenv("BILLING_CURRENCY", "EUR")

# One row per region: the Stripe price ids that charge and the figures that are
# advertised, kept side by side so they cannot be read from different regions.
# Consumed through regions.pricing_for_region, which applies the fallback rule
# above — read it through that, not directly.
REGION_PRICING = {
    "na": {
        "region": "na",
        "individual_price_id": INDIVIDUAL_PRICE_ID,
        "team_price_id": TEAM_PRICE_ID,
        "individual_price_per_month": INDIVIDUAL_PRICE_PER_MONTH,
        "team_price_per_seat": TEAM_PRICE_PER_SEAT,
    },
    "eu": {
        "region": "eu",
        "individual_price_id": INDIVIDUAL_PRICE_ID_EU,
        "team_price_id": TEAM_PRICE_ID_EU,
        "individual_price_per_month": INDIVIDUAL_PRICE_PER_MONTH_EU,
        "team_price_per_seat": TEAM_PRICE_PER_SEAT_EU,
    },
    "au": {
        "region": "au",
        "individual_price_id": INDIVIDUAL_PRICE_ID_AU,
        "team_price_id": TEAM_PRICE_ID_AU,
        "individual_price_per_month": INDIVIDUAL_PRICE_PER_MONTH_AU,
        "team_price_per_seat": TEAM_PRICE_PER_SEAT_AU,
    },
    "latam": {
        "region": "latam",
        "individual_price_id": INDIVIDUAL_PRICE_ID_LATAM,
        "team_price_id": TEAM_PRICE_ID_LATAM,
        "individual_price_per_month": INDIVIDUAL_PRICE_PER_MONTH_LATAM,
        "team_price_per_seat": TEAM_PRICE_PER_SEAT_LATAM,
    },
    "row": {
        "region": "row",
        "individual_price_id": INDIVIDUAL_PRICE_ID_ROW,
        "team_price_id": TEAM_PRICE_ID_ROW,
        "individual_price_per_month": INDIVIDUAL_PRICE_PER_MONTH_ROW,
        "team_price_per_seat": TEAM_PRICE_PER_SEAT_ROW,
    },
}

# Where Stripe may send a customer back to after checkout or the billing
# portal. The app supplies these URLs per request, and Stripe will redirect to
# whatever it is given — so without a host check any account holder could mint
# a Stripe-hosted page that lands on a site of their choosing. Comma-separated
# hostnames; the defaults are the public site and local development.
_raw_return_hosts = os.getenv("ALLOWED_RETURN_HOSTS", "").strip()
ALLOWED_RETURN_HOSTS = {
    h.strip().lower() for h in _raw_return_hosts.split(",") if h.strip()
} or {"geonix.site", "www.geonix.site", "localhost", "127.0.0.1"}

# Stripe enables "Managed Payments" by default on new accounts, and it requires
# every product in a checkout line item to carry an eligible product tax code.
# Ours have none, so Stripe rejected every session with:
#   "Invalid line_items[0]: this product tax code is ineligible for Managed
#    Payments" -> our /api/billing/checkout-session returned 502.
# Opting out per session unblocks checkout without a dashboard change. To switch
# it on instead, set eligible tax codes on both products in the Stripe dashboard
# and then set STRIPE_MANAGED_PAYMENTS=true.
STRIPE_MANAGED_PAYMENTS = os.getenv("STRIPE_MANAGED_PAYMENTS", "false").lower() == "true"

# Transactional email (subscription confirmations, etc.), sent over plain SMTP
# so this works against whatever relay the operator already has — SendGrid,
# Mailgun, Postmark, Gmail, or a local catcher like MailHog for development —
# without a vendor-specific SDK. See email_service.py.
#
# SMTP_HOST unset (the default) turns every send into a no-op that only logs,
# so a laptop with nothing configured never tries to reach a real mail server.
SMTP_HOST = os.getenv("SMTP_HOST", "").strip()
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USERNAME = os.getenv("SMTP_USERNAME", "").strip()
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "").strip()
SMTP_USE_TLS = os.getenv("SMTP_USE_TLS", "true").strip().lower() == "true"
EMAIL_FROM_ADDRESS = os.getenv("EMAIL_FROM_ADDRESS", "billing@geonix.site").strip()
EMAIL_FROM_NAME = os.getenv("EMAIL_FROM_NAME", "Geonix Wrench").strip()

# What the admin dashboard subtracts from estimated revenue to show "profit".
#
# Nothing in this app tracks Stripe fees, server costs or payroll, so this is
# not derived — it is whatever the operator sets it to. Zero (the default)
# means profit is shown equal to revenue, which is a placeholder, not a real
# profit figure, until this is filled in. See admin.get_stats.
ADMIN_MONTHLY_COSTS = float(os.getenv("ADMIN_MONTHLY_COSTS", "0"))

# The admin portal (admin_portal.py) refuses to start without this. It binds to
# loopback by default, but loopback is not a boundary a browser respects: any
# page open on the same machine can post to it. HTTP Basic auth with this
# password is what makes the revenue figures and the hide/unhide buttons
# actually private. Any length; generate one with
#   python -c 'import secrets; print(secrets.token_urlsafe(24))'
ADMIN_PORTAL_PASSWORD = os.getenv("ADMIN_PORTAL_PASSWORD", "").strip()

# ── Device limits ─────────────────────────────────────────────────────────
#
# How many devices may be signed in to one account at once. The quota follows
# the *role*, not the plan row, because that is the thing that actually differs:
# an Individual subscriber and a shop owner are both one person with a phone, a
# tablet and a workshop desktop, while an employee is issued one device by the
# shop and sharing that login is exactly what the limit exists to stop.
#
#   Individual subscription ....... 3
#   Team subscription, owner ...... 3
#   Team subscription, employee ... 1
#
# An account with no active subscription is quoted the individual figure. It is
# deliberately not the strictest number: an unsubscribed account cannot record
# or export anything anyway, so there is nothing to protect there, and locking
# someone to one device before they have paid only gets in the way of the
# screen where they would pay.
DEVICE_LIMIT_INDIVIDUAL = int(os.getenv("DEVICE_LIMIT_INDIVIDUAL", "3"))
DEVICE_LIMIT_TEAM_OWNER = int(os.getenv("DEVICE_LIMIT_TEAM_OWNER", "3"))
DEVICE_LIMIT_TEAM_MEMBER = int(os.getenv("DEVICE_LIMIT_TEAM_MEMBER", "1"))

# What happens when a sign-in would be one device over the quota.
#
#   "evict_oldest" — the least recently used device is signed out and the new
#                    one is let in. The default, because the alternative
#                    strands someone on the device in their hand with an error
#                    naming a laptop they may be nowhere near.
#   "reject"       — the new sign-in is refused with 403 and the user has to
#                    free a slot from Settings first.
DEVICE_LIMIT_POLICY = os.getenv("DEVICE_LIMIT_POLICY", "evict_oldest").strip().lower()

# Whether a request with no X-Device-Id header is refused.
#
# Off by default so builds of the app that predate device tracking keep working
# — they simply go uncounted. Turn it on once every shipped client sends the
# header, otherwise dropping it is a one-line way around the quota.
REQUIRE_DEVICE_ID = os.getenv("REQUIRE_DEVICE_ID", "false").strip().lower() == "true"

# How long a signed-out device is remembered.
#
# The row is kept rather than deleted so the device learns it was signed out
# instead of silently re-registering itself on its next request — which would
# undo the eviction that just happened. 30 days is far past any Firebase
# token's life; the row is only an identifier-shaped hash after that.
DEVICE_SESSION_RETENTION_HOURS = int(os.getenv("DEVICE_SESSION_RETENTION_HOURS", "720"))

# Don't rewrite last_seen_at on every single request. Eviction picks the least
# recently used device, so the timestamp only has to be accurate to within a
# few minutes, and a write per request would triple the database traffic of a
# read-only screen.
DEVICE_LAST_SEEN_REFRESH_SECONDS = int(os.getenv("DEVICE_LAST_SEEN_REFRESH_SECONDS", "300"))

# Bounds on the client-supplied strings. The id is hashed before storage, so
# the cap is only there to stop an unbounded body reaching the hash function;
# the name is shown back to the user and is truncated to fit.
DEVICE_ID_MAX_LENGTH = 200
DEVICE_NAME_MAX_LENGTH = 80

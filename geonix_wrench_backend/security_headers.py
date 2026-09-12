"""Response hardening headers, applied to everything this process serves.

Put here rather than in the reverse proxy because there may not be one. The
same app serves the API behind nginx in one deployment and serves the website
itself in another (FRONTEND_DIST_DIR), and a header that only exists when a
particular proxy is in front is a header nobody can rely on. Setting them here
means they hold in every deployment, and a proxy adding its own on top is
harmless.

Written as raw ASGI rather than BaseHTTPMiddleware on purpose: job-card PDFs
and shop logos go out as FileResponse, and BaseHTTPMiddleware wraps streaming
bodies in a way that has a history of breaking them. This only rewrites the
header list on the response-start message and never touches the body.
"""

from typing import Iterable

# Applied to every response.
#
# X-Frame-Options and frame-ancestors: nothing here is meant to be embedded —
# not the API, not the marketing pages. Clickjacking a "delete my account"
# button is the concrete thing this prevents.
_BASE_HEADERS = {
    b"x-content-type-options": b"nosniff",
    b"x-frame-options": b"DENY",
    b"referrer-policy": b"no-referrer",
    b"cross-origin-opener-policy": b"same-origin",
    # No page here uses a camera, microphone or location. The recording happens
    # in the native app, not in a browser.
    b"permissions-policy": b"camera=(), microphone=(), geolocation=(), payment=()",
}

# For HTML — i.e. the website, when this process is serving it.
#
# 'unsafe-inline' is present for styles only, and only because the pages carry
# inline style="..." attributes. Scripts have no such allowance: the one script
# on the site is an external file, so script-src stays 'self' and an injected
# <script> block cannot run.
_HTML_CSP = (
    b"default-src 'self'; "
    b"script-src 'self'; "
    b"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
    b"img-src 'self' data:; "
    b"font-src 'self' https://fonts.gstatic.com; "
    b"connect-src 'self' https://api.geonix.site; "
    b"object-src 'none'; "
    b"base-uri 'none'; "
    b"frame-ancestors 'none'; "
    b"form-action 'self'"
)

# For everything else — JSON, PDFs, images. None of it should ever load a
# subresource or be framed.
#
# Never send this on a 304. See the note in send_with_headers below: a 304
# carries no Content-Type, so the choice between the two policies cannot be
# made there, and guessing wrong on a page is a site that renders bare.
_NON_HTML_CSP = b"default-src 'none'; frame-ancestors 'none'; base-uri 'none'"

_HSTS = b"max-age=31536000; includeSubDomains"

# Static assets. Nothing under /assets/ is generated per-visitor, and the CSS
# and JS are versioned in the URL (site.css?v=10), so a client that has one
# never needs to ask about it again — which is the point: a reload that does
# not re-request the stylesheet cannot render unstyled because the request
# failed. Unversioned files there (the logo SVGs) get a week rather than a
# year, so replacing one does not need a rename to take effect.
_ASSET_CACHE_VERSIONED = b"public, max-age=31536000, immutable"
_ASSET_CACHE_PLAIN = b"public, max-age=604800"


def _header_value(headers: Iterable, name: bytes) -> bytes | None:
    for key, value in headers:
        if key.lower() == name:
            return value
    return None


class SecurityHeadersMiddleware:
    def __init__(self, app, hsts: bool = True):
        self.app = app
        self.hsts = hsts

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        # TLS terminates at Cloudflare, so scope["scheme"] is http even for a
        # request the visitor made over https. The forwarded header is the only
        # honest signal, and HSTS on a plaintext response is ignored anyway.
        forwarded_proto = _header_value(scope.get("headers", []), b"x-forwarded-proto")
        is_https = scope.get("scheme") == "https" or forwarded_proto == b"https"

        async def send_with_headers(message):
            if message["type"] != "http.response.start":
                await send(message)
                return

            headers = list(message.get("headers", []))
            present = {k.lower() for k, _ in headers}

            # A 304 has no body and therefore no Content-Type, and a browser
            # merges the headers off a 304 into the copy it already holds. So
            # a CSP added here does not describe this response — it silently
            # replaces the one stored alongside the cached page.
            #
            # That is not hypothetical: StaticFiles answers a reload of the
            # website with 304, the missing Content-Type read as "not HTML",
            # and the deny-everything policy below landed on the cached home
            # page. Every reload after that blocked its own stylesheet, script
            # and favicon, and the site rendered as bare markup — until a
            # shift-reload skipped the conditional request and got a 200 with
            # the right policy back. Leave a 304's policy alone; the stored
            # one came from the 200 and is already correct.
            not_modified = message.get("status") == 304

            for name, value in _BASE_HEADERS.items():
                if name not in present:
                    headers.append((name, value))

            # The shop-logo route sets a much tighter, sandboxed CSP of its own
            # for SVGs. Never overwrite a policy a route chose deliberately.
            if b"content-security-policy" not in present and not not_modified:
                content_type = _header_value(headers, b"content-type") or b""
                is_html = content_type.lower().startswith(b"text/html")
                headers.append(
                    (b"content-security-policy", _HTML_CSP if is_html else _NON_HTML_CSP)
                )

            # Long-lived caching for the static assets, but never for the HTML
            # that references them: the pages must be free to point at a new
            # ?v= immediately.
            if b"cache-control" not in present and scope.get("path", "").startswith("/assets/"):
                versioned = b"v=" in scope.get("query_string", b"")
                headers.append((
                    b"cache-control",
                    _ASSET_CACHE_VERSIONED if versioned else _ASSET_CACHE_PLAIN,
                ))

            if self.hsts and is_https and b"strict-transport-security" not in present:
                headers.append((b"strict-transport-security", _HSTS))

            message["headers"] = headers
            await send(message)

        await self.app(scope, receive, send_with_headers)

"""Transactional email, sent over plain SMTP.

Configured entirely through the SMTP_* env vars in config.py so it works
against whatever relay the operator already has — SendGrid, Mailgun,
Postmark, Gmail, or a local catcher like MailHog for development — without
pulling in a vendor-specific SDK.
"""

import logging
import smtplib
from email.message import EmailMessage
from typing import Optional

from config import (
    EMAIL_FROM_ADDRESS,
    EMAIL_FROM_NAME,
    SMTP_HOST,
    SMTP_PASSWORD,
    SMTP_PORT,
    SMTP_USERNAME,
    SMTP_USE_TLS,
)

logger = logging.getLogger(__name__)


def send_email(*, to: str, subject: str, body: str) -> bool:
    """Best-effort send. Returns whether it actually went out.

    Never raises. This is called from the Stripe webhook handler, after the
    subscription itself has already been recorded — a customer who was really
    charged must not see that undone or retried because their mail server
    timed out. The caller logs the outcome and moves on either way.

    SMTP_HOST unset is "email is off" rather than a misconfiguration: a
    laptop running this locally, or the test suite, has no relay to send
    through, and neither should try to open a real network connection.
    """
    if not SMTP_HOST:
        logger.info("SMTP_HOST is unset - skipping email to %s: %s", to, subject)
        return False

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = f"{EMAIL_FROM_NAME} <{EMAIL_FROM_ADDRESS}>" if EMAIL_FROM_NAME else EMAIL_FROM_ADDRESS
    message["To"] = to
    message.set_content(body)

    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
            if SMTP_USE_TLS:
                server.starttls()
            if SMTP_USERNAME:
                server.login(SMTP_USERNAME, SMTP_PASSWORD)
            server.send_message(message)
        return True
    except Exception:
        logger.exception("Could not send email to %s", to)
        return False


def send_subscription_confirmation(*, email: str, plan: str, seats: Optional[int] = None) -> bool:
    if plan == "team":
        seat_note = f" for {seats} seat{'' if seats == 1 else 's'}" if seats else ""
        subject = "Your Geonix Wrench Team subscription is active"
        body = (
            f"Thanks for subscribing to Geonix Wrench Team{seat_note}.\n\n"
            "Your subscription is now active. You can manage seats, invites and "
            "billing from Settings in the app at any time.\n\n"
            "- The Geonix Wrench team"
        )
    else:
        subject = "Your Geonix Wrench subscription is active"
        body = (
            "Thanks for subscribing to Geonix Wrench.\n\n"
            "Your subscription is now active. You can manage your billing from "
            "Settings in the app at any time.\n\n"
            "- The Geonix Wrench team"
        )
    return send_email(to=email, subject=subject, body=body)

#!/usr/bin/env python3
"""
remind_unbooked.py

Find people who completed the questionnaire but haven't booked a session, and
email them a booking reminder.

Reads the "who completed" list from the Google Sheet that Qualtrics writes each
response into, checks Supabase for who has booked, and emails the difference via
Resend.

SAFETY: by default this is a DRY RUN. It prints who would be emailed and sends
nothing. Add --send to actually send. Always dry-run first, eyeball the list,
send a test to yourself (--send --limit 1), then send for real.

One-time setup:
  pip install gspread google-auth           (in your venv)
  - put the service-account JSON key file in this folder (e.g. google_key.json)
  - share the sheet with the JSON's client_email (...@...iam.gserviceaccount.com)

Secrets go in .env.local beside this script (gitignored), never in the code:
  SUPABASE_SERVICE_KEY=...      # the service_role (admin) key: keep it secret
  RESEND_API_KEY=...
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from dotenv import load_dotenv

# --------------------------------------------------------------------------
# Settings you edit (none of these are secret).
# --------------------------------------------------------------------------
CONFIG = {
    # the service-account key file, sitting in this folder
    "google_key_file": "google_key.json",
    # your sheet's URL, and the tab the responses land on
    "sheet_url": "https://docs.google.com/spreadsheets/d/1dYRt3X3JLHe3mmmg26DPc1IUbnlUassr3gZtf6oIsak/edit",
    "worksheet": "emails",
    # column headers in that sheet
    "email_col": "email",
    "code_col": "ParticipantCode",
    "group_col": "group_flag",

    "supabase_url": "https://rkxzshpwipcgyjvcofid.supabase.co",
    "booking_base": "https://antikitten.github.io/catchpinch-study/booking/",

    # Resend sender must be on a domain you've verified in Resend
    "from_email": "catchpinch <noreply@FILL_ME_IN>",
    "reply_to": "axc103@student.bham.ac.uk",
    "subject": "You're almost in \u2013 book your catchpinch session",

    # public URL for the header image, or "" to leave it out of the email
    "image_url": "https://antikitten.github.io/catchpinch-study/device_rig.png",

    # the "booking is now fixed" reassurance line. Leave True for this first
    # catch-up batch; set it to False and re-run for later reminders.
    "site_fixed_note": True,

    # file that remembers who has already been emailed, so nobody is reminded
    # twice. Written only on a real --send. Keep it out of git (it has emails).
    "already_emailed_file": "emailed.txt",

    # Qualtrics marks even a rapid click-through as "finished". This floor skips
    # --csv responses that finished in fewer than this many seconds (the genuine
    # median is ~12 min, so speed-runs stand out). Raise it to be stricter, set
    # 0 to turn it off. Only the --csv path can use this (the sheet carries no
    # duration column).
    "min_completion_seconds": 120,
}


def sheet_completed():
    """Read the sheet and return [{code, email}, ...] for rows that have both."""
    import gspread
    from google.oauth2.service_account import Credentials
    here = os.path.dirname(os.path.abspath(__file__))
    key_path = CONFIG["google_key_file"]
    if not os.path.isabs(key_path):
        key_path = os.path.join(here, key_path)
    if not os.path.isfile(key_path):
        raise RuntimeError(f"Google key file not found: {key_path}")

    creds = Credentials.from_service_account_file(
        key_path, scopes=["https://www.googleapis.com/auth/spreadsheets.readonly"])
    ws = gspread.authorize(creds).open_by_url(CONFIG["sheet_url"]).worksheet(CONFIG["worksheet"])

    out = []
    seen = set()
    no_group = 0
    for row in ws.get_all_records():           # list of dicts keyed by header
        code = str(row.get(CONFIG["code_col"], "")).strip()
        email = str(row.get(CONFIG["email_col"], "")).strip()
        group = str(row.get(CONFIG["group_col"], "")).strip()
        if not (code and email and code not in seen):
            continue
        if group not in ("group_a", "group_b"):   # no flag -> booking link can't work
            no_group += 1
            continue
        seen.add(code)
        out.append({"code": code, "email": email, "group": group})
    if no_group:
        print(f"(skipped {no_group} sheet row(s) with no group_flag)")
    return out


def csv_completed(csv_path):
    """Read a full Qualtrics export CSV and return [{code, email}, ...] for
    completed responses. For a one-off catch-up over everyone who finished
    before the sheet existed. The email column is found by looking for the
    column of @ addresses (Qualtrics' RecipientEmail is often empty; the real
    email is a survey question); ParticipantCode is matched by name; and the two
    extra Qualtrics header rows are skipped the way the analysis does."""
    import csv as _csv
    if not os.path.isfile(csv_path):
        raise RuntimeError(f"Export CSV not found: {csv_path}")
    with open(csv_path, newline="", encoding="utf-8") as f:
        rows = list(_csv.reader(f))
    if len(rows) < 4:
        return []
    hdr = rows[0]
    data = rows[3:]                       # skip the question-text and ImportId rows

    code_i = next((i for i, h in enumerate(hdr) if h == "ParticipantCode"), None)
    if code_i is None:
        raise RuntimeError("No ParticipantCode column in the export.")
    fin_i = next((i for i, h in enumerate(hdr) if h == "Finished"), None)
    dur_i = next((i for i, h in enumerate(hdr) if h == "Duration (in seconds)"), None)
    grp_i = next((i for i, h in enumerate(hdr) if h == "group_flag"), None)
    email_i, best = None, 0                # email column = most @ addresses
    for i in range(len(hdr)):
        n = sum(1 for r in data if i < len(r) and "@" in str(r[i]))
        if n > best:
            email_i, best = i, n
    if email_i is None:
        raise RuntimeError("No email column found (no @ addresses in the export).")

    min_sec = int(CONFIG.get("min_completion_seconds", 0) or 0)
    out, seen = [], set()
    too_fast = 0
    no_group = 0
    for r in data:
        if code_i >= len(r) or email_i >= len(r):
            continue
        code = str(r[code_i]).strip()
        email = str(r[email_i]).strip()
        group = str(r[grp_i]).strip() if grp_i is not None and grp_i < len(r) else ""
        finished = fin_i is None or str(r[fin_i]).strip().lower() in ("1", "true")
        if not (code and "@" in email and finished and code not in seen):
            continue
        # Qualtrics marks a click-through as "finished"; skip a response that
        # completed too fast to be a genuine sitting.
        if min_sec > 0 and dur_i is not None and dur_i < len(r):
            try:
                if int(float(r[dur_i])) < min_sec:
                    too_fast += 1
                    continue
            except ValueError:
                pass
        # the booking link needs the group flag; without it the page can't book
        if group not in ("group_a", "group_b"):
            no_group += 1
            continue
        seen.add(code)
        out.append({"code": code, "email": email, "group": group})
    if too_fast:
        print(f"(skipped {too_fast} response(s) that finished in under "
              f"{min_sec}s, too fast to be a genuine sitting)")
    if no_group:
        print(f"(skipped {no_group} response(s) with a blank group_flag, "
              f"their booking link could not work)")
    return out


def _already_emailed(here):
    """Set of emails already reminded on a previous real send."""
    path = os.path.join(here, CONFIG["already_emailed_file"])
    if not os.path.isfile(path):
        return set()
    with open(path, encoding="utf-8") as f:
        return {line.strip().lower() for line in f if line.strip()}


def _record_emailed(here, email):
    """Append one email to the record so it is skipped next time."""
    path = os.path.join(here, CONFIG["already_emailed_file"])
    with open(path, "a", encoding="utf-8") as f:
        f.write(email.strip().lower() + "\n")


def booked_codes(service_key):
    """Codes that already have an active booking in Supabase."""
    url = f"{CONFIG['supabase_url']}/rest/v1/bookings?select=code&status=eq.active"
    req = urllib.request.Request(url, headers={
        "apikey": service_key, "Authorization": f"Bearer {service_key}",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/122.0.0.0 Safari/537.36"})
    rows = json.loads(urllib.request.urlopen(req, timeout=30).read())
    return {str(r["code"]).strip() for r in rows if r.get("code")}


def send_reminder(resend_key, person, template):
    """Send one reminder via Resend."""
    link = f"{CONFIG['booking_base']}?code={person['code']}&group_flag={person['group']}"
    html = (template
            .replace("{first_name}", "there")
            .replace("{booking_link}", link)
            .replace("{image_url}", CONFIG["image_url"]))
    body = {"from": CONFIG["from_email"], "to": [person["email"]],
            "reply_to": CONFIG["reply_to"], "subject": CONFIG["subject"], "html": html}
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {resend_key}",
                 "Content-Type": "application/json",
                 "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                               "AppleWebKit/537.36 (KHTML, like Gecko) "
                               "Chrome/122.0.0.0 Safari/537.36"})
    urllib.request.urlopen(req, timeout=30)


def main():
    ap = argparse.ArgumentParser(
        description="Email questionnaire-completers who haven't booked a session.")
    ap.add_argument("--send", action="store_true",
                    help="actually send the emails (default is a dry run)")
    ap.add_argument("--limit", type=int, default=None,
                    help="only act on the first N non-bookers (for a test send)")
    ap.add_argument("--template", default="booking_reminder_email.html",
                    help="the HTML email template")
    ap.add_argument("--csv", default=None,
                    help="one-off catch-up: read completers from a full Qualtrics "
                         "export CSV instead of the sheet (reaches people who "
                         "finished before the sheet existed)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    load_dotenv(os.path.join(here, ".env.local"))

    missing = [k for k in ("SUPABASE_SERVICE_KEY", "RESEND_API_KEY")
               if not os.environ.get(k)]
    if missing:
        print("Missing from .env.local: " + ", ".join(missing))
        return 1
    if args.send and "FILL_ME_IN" in CONFIG["from_email"]:
        print("Before sending, set CONFIG['from_email'] to your Resend-verified")
        print("sender (the address your booking emails come from). The dry run")
        print("works without it.")
        return 1

    tpl = args.template if os.path.isabs(args.template) else os.path.join(here, args.template)
    if not os.path.isfile(tpl):
        print(f"Email template not found: {tpl}")
        return 1
    template = open(tpl, encoding="utf-8").read()
    if not CONFIG.get("site_fixed_note", False):
        import re
        template = re.sub(r"\s*<p[^>]*>[^<]*<!--FIXED_NOTE-->\s*</p>", "", template)

    try:
        completed = csv_completed(args.csv) if args.csv else sheet_completed()
        booked = booked_codes(os.environ["SUPABASE_SERVICE_KEY"])
    except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, KeyError) as exc:
        print(f"Could not fetch data: {exc}")
        return 1
    except Exception as exc:   # gspread / google auth errors
        print(f"Google Sheets error: {exc}")
        print("Check the sheet is shared with the service account's client_email.")
        return 1

    # Group by email so someone who did the questionnaire more than once (a few
    # different codes, one person) is emailed at most once, and counts as booked
    # if ANY of their codes has a booking.
    from collections import defaultdict
    by_email = defaultdict(list)
    for p in completed:
        by_email[p["email"]].append((p["code"], p["group"]))
    done = _already_emailed(here)
    unbooked = []
    for e, pairs in by_email.items():
        if any(code in booked for code, _ in pairs):
            continue
        if e.lower() in done:
            continue
        code0, group0 = pairs[0]
        unbooked.append({"email": e, "code": code0, "group": group0})
    unbooked.sort(key=lambda p: p["email"])
    if args.limit is not None:
        unbooked = unbooked[:args.limit]

    print(f"{len(by_email)} people completed the questionnaire, "
          f"{len(booked)} bookings on file, {len(done)} already emailed, "
          f"{len(unbooked)} to remind"
          + (f" (limited to {args.limit})" if args.limit is not None else ""))

    sent = 0
    for p in unbooked:
        if args.send:
            try:
                send_reminder(os.environ["RESEND_API_KEY"], p, template)
                _record_emailed(here, p["email"])
                sent += 1
                print(f"  sent -> {p['email']}  (code {p['code']})")
            except urllib.error.HTTPError as exc:
                try:
                    detail = exc.read().decode("utf-8", "replace")
                except Exception:
                    detail = ""
                print(f"  FAILED -> {p['email']}: HTTP {exc.code} :: {detail}")
            except urllib.error.URLError as exc:
                print(f"  FAILED -> {p['email']}: {exc}")
        else:
            print(f"  would email <{p['email']}>  code {p['code']}  ({p['group']})")

    print(f"\nSent {sent} reminder(s)." if args.send
          else "\nDry run: nothing sent. Add --send to send for real.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
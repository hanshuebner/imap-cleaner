#!/usr/bin/env python3
"""
Test harness for imap-cleaner SMTP filter.

Connects to an IMAP server, lets the user browse and select messages,
then sends them through the SMTP filter and reports the verdicts.
"""

import argparse
import email
import getpass
import imaplib
import re
import smtplib
import ssl
import sys
from email.header import decode_header


def decode_mime_header(raw):
    """Decode a MIME-encoded header into a plain string."""
    if raw is None:
        return "(none)"
    parts = decode_header(raw)
    decoded = []
    for data, charset in parts:
        if isinstance(data, bytes):
            decoded.append(data.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(data)
    return "".join(decoded)


def connect_imap(host, port, user, password):
    """Connect and authenticate to an IMAP server over SSL."""
    ctx = ssl.create_default_context()
    imap = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
    imap.login(user, password)
    return imap


def list_mailboxes(imap):
    """List available mailboxes."""
    status, data = imap.list()
    if status != "OK":
        print("Failed to list mailboxes", file=sys.stderr)
        return []
    mailboxes = []
    for item in data:
        if isinstance(item, bytes):
            # Parse: (\\flags) "delimiter" "name"
            m = re.search(rb'"([^"]+)"$', item)
            if m:
                mailboxes.append(m.group(1).decode("utf-8", errors="replace"))
    return mailboxes


def list_messages(imap, mailbox, count=40):
    """Select mailbox and return the last `count` messages as (uid, from, subject) tuples."""
    status, data = imap.select(mailbox, readonly=True)
    if status != "OK":
        print(f"Failed to select mailbox: {mailbox}", file=sys.stderr)
        return []
    # Search for all messages
    status, data = imap.uid("search", None, "ALL")
    if status != "OK":
        return []
    uids = data[0].split()
    # Take the last `count`
    uids = uids[-count:]
    messages = []
    for uid in uids:
        status, data = imap.uid("fetch", uid, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])")
        if status != "OK":
            continue
        raw_headers = data[0][1]
        msg = email.message_from_bytes(raw_headers)
        from_hdr = decode_mime_header(msg.get("From", ""))
        subject_hdr = decode_mime_header(msg.get("Subject", ""))
        messages.append((uid.decode(), from_hdr, subject_hdr))
    return messages


def fetch_raw_message(imap, uid):
    """Fetch the complete raw message by UID."""
    status, data = imap.uid("fetch", uid.encode() if isinstance(uid, str) else uid,
                            "(BODY.PEEK[])")
    if status != "OK":
        return None
    return data[0][1]


def send_through_filter(raw_message, smtp_host, smtp_port, sender, recipient):
    """Send a raw message through the SMTP filter.
    Returns (accepted: bool, response_code: int, response_text: str)."""
    try:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=120) as smtp:
            smtp.ehlo("test-harness")
            code, msg = smtp.docmd("MAIL", f"FROM:<{sender}>")
            if code != 250:
                return False, code, msg.decode(errors="replace")
            code, msg = smtp.docmd("RCPT", f"TO:<{recipient}>")
            if code != 250:
                return False, code, msg.decode(errors="replace")
            code, msg = smtp.docmd("DATA")
            if code != 354:
                return False, code, msg.decode(errors="replace")
            # Send message data with dot-stuffing
            if isinstance(raw_message, bytes):
                text = raw_message.decode("utf-8", errors="replace")
            else:
                text = raw_message
            # Ensure CRLF line endings
            text = text.replace("\r\n", "\n").replace("\n", "\r\n")
            # Dot-stuff lines starting with "."
            lines = text.split("\r\n")
            stuffed = []
            for line in lines:
                if line.startswith("."):
                    stuffed.append("." + line)
                else:
                    stuffed.append(line)
            data = "\r\n".join(stuffed)
            # Send the data and terminating "."
            smtp.send(data.encode("utf-8", errors="replace"))
            code, msg = smtp.docmd("", "\r\n.")
            return code == 250, code, msg.decode(errors="replace")
    except Exception as e:
        return False, 0, str(e)


def prompt_choice(prompt_text, max_val):
    """Prompt for a number in range [1, max_val]. Returns 0-based index or None."""
    while True:
        try:
            raw = input(prompt_text).strip()
            if raw.lower() in ("q", "quit", ""):
                return None
            n = int(raw)
            if 1 <= n <= max_val:
                return n - 1
            print(f"  Enter a number between 1 and {max_val}")
        except (ValueError, EOFError):
            return None


def prompt_selection(messages):
    """Let user select messages. Returns list of (uid, from, subject) tuples."""
    print(f"\n{'#':>3}  {'From':<40} Subject")
    print("-" * 80)
    for i, (uid, from_hdr, subject) in enumerate(messages, 1):
        from_short = from_hdr[:38] if len(from_hdr) > 38 else from_hdr
        subj_short = subject[:35] if len(subject) > 35 else subject
        print(f"{i:3}  {from_short:<40} {subj_short}")
    print()
    print("Enter message numbers to test (comma-separated, ranges with -, or 'all'):")
    raw = input("> ").strip()
    if raw.lower() == "all":
        return messages
    selected = []
    for part in raw.split(","):
        part = part.strip()
        if "-" in part:
            try:
                start, end = part.split("-", 1)
                start, end = int(start.strip()), int(end.strip())
                for i in range(start, end + 1):
                    if 1 <= i <= len(messages):
                        selected.append(messages[i - 1])
            except ValueError:
                print(f"  Skipping invalid range: {part}")
        else:
            try:
                i = int(part)
                if 1 <= i <= len(messages):
                    selected.append(messages[i - 1])
            except ValueError:
                print(f"  Skipping invalid number: {part}")
    return selected


def main():
    parser = argparse.ArgumentParser(
        description="Test imap-cleaner SMTP filter against real IMAP messages")
    parser.add_argument("--imap-host", required=True, help="IMAP server hostname")
    parser.add_argument("--imap-port", type=int, default=993, help="IMAP port (default: 993)")
    parser.add_argument("--imap-user", required=True, help="IMAP username")
    parser.add_argument("--imap-password", help="IMAP password (prompted if omitted)")
    parser.add_argument("--smtp-host", default="127.0.0.1", help="SMTP filter host (default: 127.0.0.1)")
    parser.add_argument("--smtp-port", type=int, default=10025, help="SMTP filter port (default: 10025)")
    parser.add_argument("--mailbox", default="INBOX", help="IMAP mailbox/folder (default: INBOX)")
    parser.add_argument("--count", type=int, default=5, help="Number of recent messages to list (default: 5)")
    args = parser.parse_args()

    password = args.imap_password or getpass.getpass("IMAP password: ")

    # Connect to IMAP
    print(f"Connecting to {args.imap_host}:{args.imap_port} as {args.imap_user}...")
    try:
        imap = connect_imap(args.imap_host, args.imap_port, args.imap_user, password)
    except Exception as e:
        print(f"IMAP connection failed: {e}", file=sys.stderr)
        sys.exit(1)
    print("Connected.\n")

    mailbox = args.mailbox

    # List messages
    print(f"\nFetching last {args.count} messages from {mailbox}...")
    messages = list_messages(imap, mailbox, args.count)
    if not messages:
        print("No messages found.")
        sys.exit(0)

    # Select messages
    selected = prompt_selection(messages)
    if not selected:
        print("No messages selected.")
        sys.exit(0)

    # Process selected messages through SMTP filter
    print(f"\nSending {len(selected)} message(s) through SMTP filter at "
          f"{args.smtp_host}:{args.smtp_port}...\n")

    results = []
    for i, (uid, from_hdr, subject) in enumerate(selected, 1):
        print(f"[{i}/{len(selected)}] Fetching UID {uid}...", end=" ", flush=True)
        raw = fetch_raw_message(imap, uid)
        if raw is None:
            print("FETCH FAILED")
            results.append((from_hdr, subject, "ERROR", "Could not fetch message"))
            continue

        print("classifying...", end=" ", flush=True)
        accepted, code, response = send_through_filter(
            raw, args.smtp_host, args.smtp_port,
            sender=f"test@test.invalid",
            recipient=f"test@test.invalid")

        if accepted:
            verdict = "HAM"
            detail = response
        elif code == 550:
            verdict = "SPAM"
            detail = response
        elif code == 451:
            verdict = "ERROR"
            detail = response
        else:
            verdict = "ERROR"
            detail = f"{code} {response}"

        print(verdict)
        results.append((from_hdr, subject, verdict, detail))

    imap.logout()

    # Print report
    print("\n" + "=" * 80)
    print("REPORT")
    print("=" * 80)

    spam_count = sum(1 for r in results if r[2] == "SPAM")
    ham_count = sum(1 for r in results if r[2] == "HAM")
    error_count = sum(1 for r in results if r[2] == "ERROR")

    for from_hdr, subject, verdict, detail in results:
        marker = {"SPAM": "X", "HAM": " ", "ERROR": "!"}[verdict]
        from_short = from_hdr[:35] if len(from_hdr) > 35 else from_hdr
        subj_short = subject[:30] if len(subject) > 30 else subject
        print(f"  [{marker}] {from_short:<37} {subj_short:<32} {detail}")

    print("-" * 80)
    print(f"Total: {len(results)} | Ham: {ham_count} | Spam: {spam_count} | Errors: {error_count}")


if __name__ == "__main__":
    main()

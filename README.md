# imap-cleaner

An IMAP spam filter that uses the Claude API to classify messages. Written in Common Lisp.

## How it works

imap-cleaner connects to an IMAP mailbox over SSL and classifies incoming messages as spam or ham using a two-stage approach:

1. **Header analysis** -- Email headers are sent to Claude for classification. Most spam is caught at this stage based on sender domains, authentication results, subject patterns, and spam filter headers.

2. **Body analysis** -- If the header verdict is below the confidence threshold (default 80%), the message body is also fetched and sent for a second classification pass.

Messages classified as spam are either flagged (dry-run mode) or moved to a spam folder.

### IMAP IDLE

The program uses two IMAP connections for real-time mail processing:

- A **monitor connection** stays in IMAP IDLE mode, receiving instant push notifications when new mail arrives.
- A **worker connection** opens on-demand to fetch and process messages, then disconnects.

This avoids race conditions between unsolicited server pushes and command responses, and eliminates keepalive concerns during potentially long Claude API calls.

If the server doesn't support IDLE, imap-cleaner falls back to polling.

### Dry-run mode

When `:dry-run t` is set (the default), spam messages are flagged with `\Flagged` instead of being moved. This lets you review classifications in your mail client before trusting the system. Set `:dry-run nil` once you're satisfied.

## Requirements

- [SBCL](http://www.sbcl.org/) (tested with 2.5.x)
- [Quicklisp](https://www.quicklisp.org/)
- An IMAP server with SSL (port 993)
- A [Claude API key](https://console.anthropic.com/)

## Setup

### 1. Clone the repository

```sh
git clone --recurse-submodules https://github.com/hanshuebner/imap-cleaner.git
cd imap-cleaner
```

The `--recurse-submodules` flag is needed because mel-base (the IMAP library) is included as a git submodule with patches for large mailbox support.

### 2. Create a configuration file

```sh
mkdir -p ~/.imap-cleaner
cp config.lisp.example ~/.imap-cleaner/config.lisp
```

Edit `~/.imap-cleaner/config.lisp` with your settings:

```lisp
(
 :imap-host "mail.example.com"
 :imap-port 993
 :imap-user "user@example.com"

 ;; Direct value or shell command:
 :imap-password "your-password"
 ;; :imap-password-command "pass show email/imap"

 :inbox "INBOX"
 :spam-folder "Junk"

 ;; Direct value or shell command:
 :claude-api-key "sk-ant-..."
 ;; :claude-api-key-command "pass show api/anthropic"

 :dry-run t  ; set to nil once you trust the classifications
)
```

Secrets can be provided directly or via shell commands (e.g. using `pass`, `op`, or `security`).

### 3. Customize the classification prompts (optional)

The prompts that guide Claude's classification are in `prompts/headers-prompt.txt` and `prompts/body-prompt.txt`. You can copy them to `~/.imap-cleaner/` and customize them for your mailbox. For example, you might add context about what kind of mail your address typically receives, or whitelist specific senders.

### 4. Test the configuration

```sh
sbcl --noinform --non-interactive --load test-config.lisp
```

This tests the IMAP connection, checks IDLE capability, calls the Claude API, and classifies the last message in the inbox. Review the output to make sure everything works before running the full program.

### 5. Run

```sh
sbcl --noinform --non-interactive --load run.lisp
```

On startup, imap-cleaner will:
1. Check the last 10 messages in the inbox
2. Test for IDLE support
3. Enter IDLE mode (or fall back to polling)

## Configuration reference

| Key | Default | Description |
|-----|---------|-------------|
| `:imap-host` | *(required)* | IMAP server hostname |
| `:imap-port` | `993` | IMAP port (SSL) |
| `:imap-user` | *(required)* | IMAP username |
| `:imap-password` | *(required)* | IMAP password (or use `:imap-password-command`) |
| `:inbox` | `"INBOX"` | Mailbox to monitor |
| `:spam-folder` | `"Junk"` | Folder to move spam to |
| `:claude-api-key` | *(required)* | Anthropic API key (or use `:claude-api-key-command`) |
| `:claude-model` | `"claude-haiku-4-5-20251001"` | Claude model to use |
| `:use-idle` | `t` | Use IMAP IDLE for push notifications |
| `:idle-timeout-seconds` | `1500` | Re-issue IDLE every N seconds (max ~29 min per RFC) |
| `:poll-interval-seconds` | `120` | Polling interval when IDLE is disabled |
| `:max-messages-per-poll` | `50` | Max messages to process per cycle |
| `:header-confidence-threshold` | `80` | Below this, also check body content |
| `:body-max-chars` | `4000` | Truncate body text sent to API |
| `:dry-run` | `nil` | Flag spam instead of moving it |
| `:headers-prompt-file` | *(auto-detected)* | Custom headers classification prompt |
| `:body-prompt-file` | *(auto-detected)* | Custom body classification prompt |
| `:log-file` | *(stderr)* | Log file path |
| `:debug` | `nil` | Enable debug logging |

## Compatibility

imap-cleaner is developed and tested with SBCL. It uses `sb-ext:exit` in the helper scripts (`run.lisp`, `test-config.lisp`). The core system (`imap-cleaner.asd`) does not use SBCL-specific features and may work on other Common Lisp implementations, but this has not been tested. The mel-base IMAP library supports SBCL, CCL, and LispWorks.

## Dependencies

Loaded via Quicklisp:
- [mel-base](https://github.com/hanshuebner/mel-base) -- IMAP/SSL (included as submodule, forked from 40ants/mel-base)
- [dexador](https://github.com/fukamachi/dexador) -- HTTP client for Claude API
- [yason](https://github.com/phmarek/yason) -- JSON parsing
- [alexandria](https://gitlab.common-lisp.net/alexandria/alexandria) -- Utilities
- [cl-ppcre](https://edicl.github.io/cl-ppcre/) -- Regular expressions
- [babel](https://github.com/cl-babel/babel) -- Character encoding

## License

MIT

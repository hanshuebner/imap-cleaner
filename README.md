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

## Building

### Requirements

- [SBCL](http://www.sbcl.org/) (tested with 2.5.x)
- [Quicklisp](https://www.quicklisp.org/)
- [buildapp](https://www.xach.com/lisp/buildapp/)
- An IMAP server with SSL (port 993)
- A [Claude API key](https://console.anthropic.com/)

### Install Quicklisp

```sh
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --noinform --non-interactive \
  --load quicklisp.lisp \
  --eval '(quicklisp-quickstart:install)' \
  --eval '(ql:add-to-init-file)'
```

### Install buildapp

```sh
sbcl --noinform --non-interactive \
  --eval '(ql:quickload "buildapp")' \
  --eval '(buildapp:build-buildapp "buildapp")'
sudo install buildapp /usr/local/bin/
```

### Build

```sh
git clone --recurse-submodules https://github.com/hanshuebner/imap-cleaner.git
cd imap-cleaner
make
```

This produces a standalone `imap-cleaner` binary.

### Install

```sh
sudo make install
```

This installs:
- The binary to `/usr/local/bin/imap-cleaner`
- Prompt files and example config to `/usr/local/etc/imap-cleaner/`

On Debian, use `SYSCONFDIR=/etc` to put config files in `/etc/imap-cleaner/`:

```sh
sudo make install SYSCONFDIR=/etc
```

## Configuration

Edit the config file (installed to `/usr/local/etc/imap-cleaner/config.lisp` or `/etc/imap-cleaner/config.lisp`):

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

### Classification prompts

The prompts that guide Claude's classification are installed alongside the config. You can customize `headers-prompt.txt` and `body-prompt.txt` for your mailbox -- for example, adding context about what kind of mail your address typically receives, or whitelisting specific senders.

### Configuration reference

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

## Usage

```
imap-cleaner [OPTIONS]

Options:
  --config PATH   Configuration file (default: ~/.imap-cleaner/config.lisp)
  --scan N        Scan last N messages, print statistics, and exit
  --help          Show help message
```

Test your configuration by scanning a few messages:

```sh
imap-cleaner --config /usr/local/etc/imap-cleaner/config.lisp --scan 5
```

Run in monitoring mode:

```sh
imap-cleaner --config /usr/local/etc/imap-cleaner/config.lisp
```

## Deployment

### Debian / Ubuntu

Create a service user and install the systemd service:

```sh
sudo useradd --system --create-home --shell /usr/sbin/nologin imap-cleaner
sudo chown imap-cleaner:imap-cleaner /etc/imap-cleaner/config.lisp
sudo mkdir -p /home/imap-cleaner/.imap-cleaner
sudo chown imap-cleaner:imap-cleaner /home/imap-cleaner/.imap-cleaner
sudo make install-service-debian SYSCONFDIR=/etc
sudo systemctl enable imap-cleaner
sudo systemctl start imap-cleaner
```

View logs:

```sh
journalctl -u imap-cleaner -f
```

### FreeBSD

Create a service user and install the rc script:

```sh
sudo pw useradd imap-cleaner -d /home/imap-cleaner -m -s /usr/sbin/nologin -c "IMAP Cleaner"
sudo chown imap-cleaner:imap-cleaner /usr/local/etc/imap-cleaner/config.lisp
sudo mkdir -p /home/imap-cleaner/.imap-cleaner
sudo chown imap-cleaner:imap-cleaner /home/imap-cleaner/.imap-cleaner
sudo touch /var/log/imap-cleaner.log
sudo chown imap-cleaner:imap-cleaner /var/log/imap-cleaner.log
sudo gmake install-service-freebsd
sudo sysrc imap_cleaner_enable=YES
sudo service imap_cleaner start
```

View logs:

```sh
tail -f /var/log/imap-cleaner.log
```

### Monitoring

imap-cleaner logs to stderr (or a configured log file) and reconnects automatically on connection failures with backoff. The systemd service is configured with `Restart=on-failure` and the FreeBSD rc script uses `daemon(8)`, so the process will be restarted if it exits unexpectedly.

To check if the service is running:

```sh
# Debian
systemctl status imap-cleaner

# FreeBSD
service imap_cleaner status
```

## Running from source

For development, you can run directly with SBCL without building:

```sh
sbcl --noinform --non-interactive --load run.lisp [--config PATH] [--scan N]
```

Or use the test script to verify your configuration:

```sh
sbcl --noinform --non-interactive --load test-config.lisp
```

## Compatibility

imap-cleaner is developed and tested with SBCL. The built binary and helper scripts (`run.lisp`, `test-config.lisp`) use SBCL-specific features. The core system (`imap-cleaner.asd`) does not use SBCL-specific features and may work on other Common Lisp implementations, but this has not been tested. The mel-base IMAP library supports SBCL, CCL, and LispWorks.

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

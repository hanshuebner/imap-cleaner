PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
SYSCONFDIR ?= $(PREFIX)/etc
CONFDIR = $(SYSCONFDIR)/imap-cleaner

SBCL ?= sbcl
BUILDAPP ?= buildapp

BINARY = imap-cleaner

all: $(BINARY)

$(BINARY):
	$(BUILDAPP) \
		--output $(BINARY) \
		--require asdf \
		--load ~/quicklisp/setup.lisp \
		--eval '(pushnew (truename ".") asdf:*central-registry* :test (function equal))' \
		--eval '(pushnew (truename "mel-base/") asdf:*central-registry* :test (function equal))' \
		--eval '(ql:quickload "imap-cleaner" :silent t)' \
		--entry imap-cleaner:toplevel

clean:
	rm -f $(BINARY)

install: $(BINARY)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 $(BINARY) $(DESTDIR)$(BINDIR)/
	install -d $(DESTDIR)$(CONFDIR)
	install -m 644 prompts/headers-prompt.txt $(DESTDIR)$(CONFDIR)/
	install -m 644 prompts/body-prompt.txt $(DESTDIR)$(CONFDIR)/
	@if [ ! -f $(DESTDIR)$(CONFDIR)/config.lisp ]; then \
		install -m 640 config.lisp.example $(DESTDIR)$(CONFDIR)/config.lisp; \
		echo ">>> Edit $(CONFDIR)/config.lisp with your settings"; \
	fi

install-service-freebsd: install
	install -m 555 deploy/freebsd/imap-cleaner.rc $(DESTDIR)$(PREFIX)/etc/rc.d/imap_cleaner
	install -d $(DESTDIR)$(PREFIX)/etc/newsyslog.conf.d
	install -m 644 deploy/freebsd/newsyslog.conf $(DESTDIR)$(PREFIX)/etc/newsyslog.conf.d/imap-cleaner.conf
	@echo "Enable with: sysrc imap_cleaner_enable=YES"
	@echo "Start with:  service imap_cleaner start"

install-service-debian: install
	install -m 644 deploy/debian/imap-cleaner.service $(DESTDIR)/etc/systemd/system/
	systemctl daemon-reload
	@echo "Enable with: systemctl enable imap-cleaner"
	@echo "Start with:  systemctl start imap-cleaner"

.PHONY: all clean install install-service-freebsd install-service-debian

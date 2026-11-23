PREFIX ?= $(HOME)/.local
SHELL  := /bin/bash

.PHONY: test lint install uninstall
test:
	tests/run.sh

lint:
	@for f in bin/sjob lib/*.sh lib/cmd/*.sh lib/backend/*.sh tests/run.sh; do bash -n $$f || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck -x bin/sjob lib/*.sh lib/cmd/*.sh lib/backend/*.sh; \
	 else echo "shellcheck not installed: only 'bash -n' was run"; fi

install:
	install -d $(PREFIX)/share/sjob $(PREFIX)/bin
	cp -r bin lib etc $(PREFIX)/share/sjob/
	ln -sf $(PREFIX)/share/sjob/bin/sjob $(PREFIX)/bin/sjob
	@echo "installed: $(PREFIX)/bin/sjob  (make sure $(PREFIX)/bin is on PATH)"

uninstall:
	rm -rf $(PREFIX)/share/sjob $(PREFIX)/bin/sjob

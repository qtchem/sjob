PREFIX ?= $(HOME)/.local
SHELL  := /bin/bash

.PHONY: test lint install uninstall
test:
	tests/run.sh

lint:
	@for f in bin/spartflow lib/*.sh lib/cmd/*.sh lib/backend/*.sh tests/run.sh; do bash -n $$f || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck -x bin/spartflow lib/*.sh lib/cmd/*.sh lib/backend/*.sh; \
	 else echo "shellcheck not installed: only 'bash -n' was run"; fi

install:
	install -d $(PREFIX)/share/spartflow $(PREFIX)/bin
	cp -r bin lib etc $(PREFIX)/share/spartflow/
	ln -sf $(PREFIX)/share/spartflow/bin/spartflow $(PREFIX)/bin/spartflow
	@echo "installed: $(PREFIX)/bin/spartflow  (make sure $(PREFIX)/bin is on PATH)"

uninstall:
	rm -rf $(PREFIX)/share/spartflow $(PREFIX)/bin/spartflow

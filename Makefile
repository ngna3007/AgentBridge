SHELL := /bin/bash

REPO := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
AB   := $(REPO)/scripts/agentbridge

.PHONY: help test smoke bootstrap install uninstall clean

help:
	@echo "AgentBridge — make targets:"
	@echo "  make test       Run full test suite (tests/run_all.sh)."
	@echo "  make smoke      Single-shot bootstrap smoke in /tmp."
	@echo "  make install    Symlink agentbridge into /usr/local/bin (sudo)."
	@echo "  make uninstall  Remove the /usr/local/bin symlink."
	@echo "  make clean      Remove .agent-bus/ in this directory."

test:
	@tests/run_all.sh

smoke:
	@tmp=$$(mktemp -d -t agentbridge-smoke-XXXXXX); \
	cd $$tmp && $(REPO)/scripts/bootstrap.sh; \
	rm -rf $$tmp

bootstrap:
	@scripts/bootstrap.sh

install:
	@if [[ ! -x "$(AB)" ]]; then echo "missing $(AB)"; exit 1; fi
	@if [[ -w /usr/local/bin ]]; then \
	   ln -sf "$(AB)" /usr/local/bin/agentbridge; \
	else \
	   sudo ln -sf "$(AB)" /usr/local/bin/agentbridge; \
	fi
	@which agentbridge

uninstall:
	@rm -f /usr/local/bin/agentbridge 2>/dev/null || sudo rm -f /usr/local/bin/agentbridge

clean:
	@rm -rf .agent-bus/

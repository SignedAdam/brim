# brim. Run `make` to see everything below.
.DEFAULT_GOAL := help
SHELL := /bin/bash

SRC        := $(wildcard src/*.swift)
BIN        := bin/brim
APP        := bin/Brim.app
FRAMEWORKS := -framework Cocoa -framework SwiftUI -framework Security
SWIFTFLAGS := -parse-as-library -swift-version 5 -target $(shell uname -m)-apple-macos14.0
PREFIX     ?= $(HOME)/.local/bin

.PHONY: help build check run snap install uninstall clean

help: ## show this
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[38;5;190m%-10s\033[0m %s\n", $$1, $$2}'

build: $(BIN) ## compile bin/brim

$(BIN): $(SRC)
	@mkdir -p bin
	@swiftc -O $(SWIFTFLAGS) -o $(BIN) $(SRC) $(FRAMEWORKS)
	@./tools/sign.sh $(BIN)
	@printf '  built %s  %s\n' $(BIN) "$$(du -h $(BIN) | cut -f1)"

check: $(BIN) ## selftest
	@$(BIN) selftest

run: $(BIN) ## run in the foreground
	@$(BIN) run

snap: $(BIN) ## render docs/*.png offscreen
	@mkdir -p docs
	@$(BIN) snapshot docs/closed.png >/dev/null
	@$(BIN) snapshot docs/open.png --open >/dev/null
	@$(BIN) snapshot docs/hover.png --hover >/dev/null
	@$(BIN) snapshot docs/flash.png --flash >/dev/null
	@$(BIN) snapshot docs/external.png --external >/dev/null
	@$(BIN) snapshot docs/external-open.png --external --open >/dev/null
	@$(BIN) snapshot docs/settings.png --settings >/dev/null
	@ls docs/*.png

install: $(BIN) ## link onto PATH and run at login
	@mkdir -p $(PREFIX)
	@ln -sf $(CURDIR)/$(BIN) $(PREFIX)/brim
	@$(BIN) install

uninstall: ## stop running at login, unlink
	@$(BIN) uninstall || true
	@rm -f $(PREFIX)/brim

clean: ## remove bin/
	@rm -rf bin

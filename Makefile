.DEFAULT_GOAL := help
SHELL := /bin/bash

SRC        := $(wildcard src/*.swift)
BIN        := bin/brim
APP        := bin/Brim.app
FRAMEWORKS := -framework Cocoa -framework SwiftUI -framework Security
SWIFTFLAGS := -parse-as-library -swift-version 5 -target $(shell uname -m)-apple-macos14.0
PREFIX     ?= $(HOME)/.local/bin
APPDIR     ?= /Applications
VERSION    := $(shell sed -n 's/^let VERSION = "\(.*\)"/\1/p' src/Model.swift)
ZIP        := dist/Brim-$(VERSION)-macos.zip

.PHONY: help build app run snap install uninstall release clean

help: ## show this
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[38;5;190m%-10s\033[0m %s\n", $$1, $$2}'

build: $(BIN) ## compile bin/brim

$(BIN): $(SRC)
	@mkdir -p bin
	@swiftc -O $(SWIFTFLAGS) -o $(BIN) $(SRC) $(FRAMEWORKS)
	@./tools/sign.sh $(BIN)
	@printf '  built %s  %s\n' $(BIN) "$$(du -h $(BIN) | cut -f1)"

app: $(APP) ## bundle bin/Brim.app

$(APP): $(BIN) tools/Info.plist
	@rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	@sed 's/__VERSION__/$(VERSION)/' tools/Info.plist > $(APP)/Contents/Info.plist
	@cp $(BIN) $(APP)/Contents/MacOS/brim
	@./tools/sign.sh $(APP)

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

install: $(APP) ## copy Brim.app to /Applications, put brim on PATH, run at login
	@$(APPDIR)/Brim.app/Contents/MacOS/brim quit >/dev/null 2>&1 || true
	@rm -rf $(APPDIR)/Brim.app && ditto $(APP) $(APPDIR)/Brim.app
	@mkdir -p $(PREFIX) && ln -sf $(APPDIR)/Brim.app/Contents/MacOS/brim $(PREFIX)/brim
	@$(APPDIR)/Brim.app/Contents/MacOS/brim install

uninstall: ## stop running at login, remove the app
	@$(PREFIX)/brim uninstall || true
	@rm -f $(PREFIX)/brim
	@rm -rf $(APPDIR)/Brim.app

release: ## universal Brim.app, zipped into dist/
	@mkdir -p dist bin/rel
	@swiftc -O $(subst $(shell uname -m)-apple,arm64-apple,$(SWIFTFLAGS)) -o bin/rel/arm64 $(SRC) $(FRAMEWORKS)
	@swiftc -O $(subst $(shell uname -m)-apple,x86_64-apple,$(SWIFTFLAGS)) -o bin/rel/x86_64 $(SRC) $(FRAMEWORKS)
	@rm -rf bin/rel/Brim.app && mkdir -p bin/rel/Brim.app/Contents/MacOS
	@sed 's/__VERSION__/$(VERSION)/' tools/Info.plist > bin/rel/Brim.app/Contents/Info.plist
	@lipo -create bin/rel/arm64 bin/rel/x86_64 -output bin/rel/Brim.app/Contents/MacOS/brim
	@codesign -f -s - -i com.signedadam.brim bin/rel/Brim.app
	@rm -f $(ZIP) && ditto -c -k --keepParent bin/rel/Brim.app $(ZIP)
	@printf '  %s  %s\n' $(ZIP) "$$(lipo -archs bin/rel/Brim.app/Contents/MacOS/brim)"

clean: ## remove bin/
	@rm -rf bin

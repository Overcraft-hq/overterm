APP := Overterm.app

# This Mac's own settings, untracked (see .gitignore): SIGN_IDENTITY.
-include local.mk

.PHONY: ghosttykit treesitter icon themes build test e2e app dmg run install clean hooks

## ghosttykit: build Frameworks/GhosttyKit.xcframework from the pinned Ghostty
ghosttykit:
	./Scripts/build-ghosttykit.sh

## treesitter: build Frameworks/TreeSitterKit.xcframework and the editor's
## highlight queries (Frameworks/TreeSitterQueries) from the pinned grammars
treesitter:
	./Scripts/build-treesitter.sh

## icon: regenerate Resources/AppIcon.icns from Resources/AppIcon.png
icon:
	./Scripts/make-icon.sh

## themes: refresh Resources/themes — the themes our pinned Ghostty doesn't ship
themes:
	./Scripts/fetch-themes.sh

## build: compile the release binary via SPM
build:
	swift build -c release

## test: run the unit tests (E2E scenarios are skipped)
test:
	swift test --skip OvertermE2ETests

## e2e: build the app, then run every end-to-end scenario in it (opens windows briefly)
e2e: app
	OVERTERM_E2E_TESTS=1 swift test --filter OvertermE2ETests

## app: assemble and ad-hoc sign $(APP)
app:
	./Scripts/make-app.sh

## dmg: pack the built $(APP) as dist/Overterm-$(VERSION).dmg (VERSION as for make app)
dmg:
	./Scripts/make-dmg.sh

## run: build the .app and launch it
run: app
	open $(APP)

## install: build and copy $(APP) into /Applications (Launchpad, Spotlight);
## with SIGN_IDENTITY set (environment or local.mk), re-sign that copy with it
install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
ifneq ($(strip $(SIGN_IDENTITY)),)
	@# Ad hoc, every build is a new app to macOS and loses its privacy grants
	@# (the microphone); one identity keeps them. No timestamp: no network.
	codesign --force --deep --timestamp=none --sign "$(SIGN_IDENTITY)" /Applications/$(APP)
endif
	@# So Finder's Open With and the "New Overterm Tab Here" service see it now.
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/$(APP)
	/System/Library/CoreServices/pbs -update
	@echo "==> installed /Applications/$(APP)"

## hooks: use the repository's git hooks (once per clone): pre-commit refuses an
## app change without a VERSION bump, post-commit tags v<VERSION>
hooks:
	git config core.hooksPath .githooks

## clean: remove build products and the assembled app (keeps GhosttyKit)
clean:
	swift package clean
	rm -rf .build $(APP) dist

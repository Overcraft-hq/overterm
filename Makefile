APP := Overterm.app

# This Mac's own settings, untracked (see .gitignore): SIGN_IDENTITY.
-include local.mk

.PHONY: ghosttykit treesitter icon themes build test test-changed e2e app dmg run install signed-spike clean hooks

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

## test-changed: only the unit tests this branch's changes reach — against
## BASE (origin/main), what isn't committed yet too (Scripts/affected-tests.sh)
BASE ?= origin/main
test-changed:
	@filter="$$( { git diff --name-only $(BASE)...HEAD; git diff --name-only HEAD; \
		git ls-files --others --exclude-standard; } | sort -u | ./Scripts/affected-tests.sh )"; \
	case "$$filter" in \
		none) echo "No unit test is reached by the changes since $(BASE)." ;; \
		all) swift test --skip OvertermE2ETests ;; \
		*) echo "Running: $$filter"; swift test --skip OvertermE2ETests --filter "$$filter" ;; \
	esac

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

## signed-spike: a copy of $(APP) signed as a release would be — hardened
## runtime, $SIGN_IDENTITY — in dist/signed-spike, for the checks of
## docs/design/activity/analysis.md 3.11 (D-4): audit tokens and
## task_name_for_pid, nettop and netstat under that signing. make install's
## re-sign has no hardened runtime and make app signs ad hoc, so neither
## tests it. No entitlements file: the release has none. No timestamp: no
## network.
ifeq ($(strip $(SIGN_IDENTITY)),)
signed-spike:
	@echo "signed-spike: set SIGN_IDENTITY (environment or local.mk) to a signing identity" >&2
	@exit 1
else
signed-spike: app
	rm -rf dist/signed-spike
	mkdir -p dist/signed-spike
	cp -R $(APP) dist/signed-spike/
	codesign --force --deep --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" dist/signed-spike/$(APP)
	codesign --verify --deep --strict dist/signed-spike/$(APP)
	@echo "==> dist/signed-spike/$(APP): its splits and suspend scenarios check it (docs/testing.md, Activity)"
endif

## hooks: use the repository's git hooks (once per clone): pre-commit refuses an
## app change unless VERSION is past the last release, with a CHANGELOG entry
hooks:
	git config core.hooksPath .githooks

## clean: remove build products and the assembled app (keeps GhosttyKit)
clean:
	swift package clean
	rm -rf .build $(APP) dist

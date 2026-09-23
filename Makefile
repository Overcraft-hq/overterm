APP := Terminus.app

.PHONY: ghosttykit icon build test e2e app run install clean

## ghosttykit: build Frameworks/GhosttyKit.xcframework from the pinned Ghostty
ghosttykit:
	./Scripts/build-ghosttykit.sh

## icon: regenerate Resources/AppIcon.icns from Resources/AppIcon.svg
icon:
	./Scripts/make-icon.sh

## build: compile the release binary via SPM
build:
	swift build -c release

## test: run the unit tests (E2E scenarios are skipped)
test:
	swift test --skip TerminusE2ETests

## e2e: build the app, then run every end-to-end scenario in it (opens windows briefly)
e2e: app
	TERMINUS_E2E_TESTS=1 swift test --filter TerminusE2ETests

## app: assemble and ad-hoc sign $(APP)
app:
	./Scripts/make-app.sh

## run: build the .app and launch it
run: app
	open $(APP)

## install: build and copy $(APP) into /Applications (Launchpad, Spotlight)
install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "==> installed /Applications/$(APP)"

## clean: remove build products and the assembled app (keeps GhosttyKit)
clean:
	swift package clean
	rm -rf .build $(APP) dist

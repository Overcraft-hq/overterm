APP := Terminus.app

.PHONY: ghosttykit icon build app run clean

## ghosttykit: build Frameworks/GhosttyKit.xcframework from the pinned Ghostty
ghosttykit:
	./Scripts/build-ghosttykit.sh

## icon: regenerate Resources/AppIcon.icns from Resources/AppIcon.svg
icon:
	./Scripts/make-icon.sh

## build: compile the release binary via SPM
build:
	swift build -c release

## app: assemble and ad-hoc sign $(APP)
app:
	./Scripts/make-app.sh

## run: build the .app and launch it
run: app
	open $(APP)

## clean: remove build products and the assembled app (keeps GhosttyKit)
clean:
	swift package clean
	rm -rf .build $(APP) dist

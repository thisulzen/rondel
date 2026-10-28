# Builds Rondel.app from source and installs it for the current user.
# Nothing here needs sudo or Xcode, only the Command Line Tools.

APP := build/Rondel.app
PREFIX ?= $(HOME)/Applications
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PBS := /System/Library/CoreServices/pbs

.PHONY: app install uninstall icon clean

# An ad-hoc signature is enough for an app built on the Mac it runs on.
app:
	swift build -c release --product Rondel
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/Rondel" $(APP)/Contents/MacOS/Rondel
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/Rondel.icns $(APP)/Contents/Resources/Rondel.icns
	codesign --force --sign - $(APP)

# Registering the app and refreshing the services cache makes Convert Audio…
# show up in Finder straight away, instead of after the next log-in.
install: app
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/Rondel.app"
	ditto $(APP) "$(PREFIX)/Rondel.app"
	$(LSREGISTER) -f "$(PREFIX)/Rondel.app"
	$(PBS) -update
	@echo "Installed to $(PREFIX)/Rondel.app. Right-click an audio file in Finder and choose Convert Audio…"

uninstall:
	-$(LSREGISTER) -u "$(PREFIX)/Rondel.app"
	rm -rf "$(PREFIX)/Rondel.app"
	$(PBS) -update
	@echo "Removed $(PREFIX)/Rondel.app"

icon:
	rm -rf build/Rondel.iconset
	swift scripts/icon.swift build/Rondel.iconset
	iconutil -c icns build/Rondel.iconset -o Resources/Rondel.icns

clean:
	rm -rf .build build

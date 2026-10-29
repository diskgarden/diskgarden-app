DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/DiskGarden.app
ENGINE := Packages/ScanEngine
# Signed with the Apple team in project.yml (automatic provisioning; the Xcode account must be signed in).
# XCB_EXTRA passes extra build settings through, e.g. to build without a signing identity:
#   make build XCB_EXTRA='CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='
XCB_EXTRA ?=
XCB := xcodebuild -project DiskGarden.xcodeproj -scheme DiskGarden -configuration Debug -derivedDataPath $(DERIVED) \
	-allowProvisioningUpdates $(XCB_EXTRA)

.PHONY: gen build run test bench clean third-party-licenses

gen:            ## Regenerate DiskGarden.xcodeproj from project.yml
	xcodegen generate

build: gen      ## Build the app (Debug)
	$(XCB) build -quiet

run: build      ## Build and launch the app (relaunches if running)
	-pkill -x DiskGarden; sleep 0.3
	open $(APP)

test:           ## Run scan engine tests
	cd $(ENGINE) && swift test

bench:          ## Scan a path with the release CLI and compare with du: make bench P=~/Downloads
	cd $(ENGINE) && swift build -c release && ./.build/release/dgscan $(or $(P),$(HOME)) --du

third-party-licenses: ## Regenerate docs/THIRD-PARTY-LICENSES.md from the resolved SwiftPM checkouts
	./scripts/gen-third-party-licenses.sh

clean:
	rm -rf build $(ENGINE)/.build DiskGarden.xcodeproj

SCHEME          := MollieComponents-Package
DEMO_SCHEME     := MollieCheckoutDemo
SIMULATOR       := generic/platform=iOS Simulator

.PHONY: ci ci-fast lint test build build-xcode docs docs-html xcframework example-build-public mint-demo-token

# ── Full pipeline (mirrors GitLab CI stages) ─────────────────────────────────

ci: lint test build build-xcode xcframework

# Skips xcframework (slow, ~5–10 min) — use for quick iteration
ci-fast: lint test build build-xcode

# ── Individual stages ────────────────────────────────────────────────────────

lint:
	swiftlint --strict
	swiftformat --lint Sources/ Tests/

test:
	swift test --enable-code-coverage

build:
	swift build -c release

build-xcode:
	xcodebuild build \
		-scheme "$(SCHEME)" \
		-destination "$(SIMULATOR)" \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO

docs:
	set -o pipefail; \
	xcodebuild docbuild \
		-scheme "$(SCHEME)" \
		-destination "$(SIMULATOR)" \
		-derivedDataPath build/DerivedData-docs \
		CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/docc-build.log
	@echo "Checking DocC log for unresolved references…"
	@if grep -qE "\.docc/.*warning: .*(doesn't exist|is ambiguous|could ?n.t be resolved|could not be resolved|has no member)" build/docc-build.log; then \
		echo "DocC: unresolved/ambiguous references found:"; \
		grep -nE "\.docc/.*warning: .*(doesn't exist|is ambiguous|could ?n.t be resolved|could not be resolved|has no member)" build/docc-build.log | grep -v '(in target' || true; \
		exit 1; \
	fi
	@echo "DocC: no unresolved references."

# Render the umbrella MollieComponents.doccarchive into a browsable static site
# under build/docs-html for local preview. Delegates to render-docs-html.sh — the
# single source of truth shared with the docc-build + publish-docs-site CI jobs
# (it runs its own docbuild + reference gate + transform, so no dependency on the
# `docs` target here).
docs-html:
	bash scripts/publish/render-docs-html.sh
	@echo "Open build/docs-html/index.html to preview"

xcframework:
	bash scripts/build-xcframework.sh

# Prove a fresh-clone merchant can build the shipped example app. Assembles the
# public tree into a temp dir (so the package ref `../..` in the demo's xcodeproj
# resolves exactly as on a GitHub clone), then xcodebuilds the clean app FROM
# that tree. Mirrors the example-build-public CI job. NOT in the `ci` chain: it
# needs committed state (assemble runs `git archive HEAD`) plus a simulator.
example-build-public:
	tmp=$$(mktemp -d); \
	bash scripts/publish/assemble-public-tree.sh 0.0.0 "$$tmp"; \
	xcodebuild build \
		-project "$$tmp/Examples/MollieCheckoutDemo/MollieCheckoutDemo.xcodeproj" \
		-scheme "$(DEMO_SCHEME)" \
		-destination "$(SIMULATOR)" \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO; \
	rm -rf "$$tmp"

# Mint a clientAccessToken for the demo app, standing in for your server.
# The API key stays on this machine — it is never embedded in the app.
#   make mint-demo-token API_KEY=test_xxxxxxxx
mint-demo-token:
	@API_KEY="$(API_KEY)" bash Examples/MollieCheckoutDemo/Tools/mint-demo-token.sh

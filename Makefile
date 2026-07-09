.PHONY: setup generate build-debug build-release clean tag release notary-setup

setup:
	@chmod +x setup.sh && ./setup.sh

generate:
	xcodegen generate

build-debug:
	xcodebuild -scheme ClaudeAgentMonitor -configuration Debug build | xcbeautify || true

build-release:
	xcodebuild -scheme ClaudeAgentMonitor -configuration Release build | xcbeautify || true

clean:
	rm -rf build/ ClaudeAgentMonitor.xcodeproj/

# Usage: make tag BUILD=042
tag:
	@[ -n "$(BUILD)" ] || (echo "Usage: make tag BUILD=042" && exit 1)
	@BUILD_PADDED=$$(printf "%03d" $(BUILD)); \
	git tag "v0.1.$$BUILD_PADDED" && \
	git push origin "v0.1.$$BUILD_PADDED" && \
	echo "✅ Tagged v0.1.$$BUILD_PADDED and pushed"

# 공증 자격증명을 keychain 프로파일로 저장 (최초 1회, 대화형 — 앱 암호 입력 필요)
# Apple ID 앱 암호: https://appleid.apple.com → 로그인 및 보안 → 앱 암호
notary-setup:
	xcrun notarytool store-credentials "DaemonHunterNotary" \
		--apple-id "$${APPLE_ID:?set APPLE_ID env}" \
		--team-id "DT9JQA4X82"

# 로컬 서명·공증·Sparkle 서명 배포. Usage: make release BUILD=007
release:
	@[ -n "$(BUILD)" ] || (echo "Usage: make release BUILD=007" && exit 1)
	@chmod +x scripts/release.sh && BUILD=$(BUILD) ./scripts/release.sh

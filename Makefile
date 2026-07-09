.PHONY: setup generate build-debug build-release clean tag

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

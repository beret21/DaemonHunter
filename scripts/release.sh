#!/usr/bin/env bash
# 로컬 서명 배포 스크립트 — keychain의 Developer ID로 직접 서명/공증/Sparkle 서명 후 GitHub 릴리스 발행
#
# 사용법:
#   make release BUILD=007            # → v0.1.007 배포
#   또는  BUILD=007 ./scripts/release.sh
#
# 사전 준비 (최초 1회):
#   1) Developer ID Application 인증서가 keychain에 있어야 함 (확인: security find-identity -v -p codesigning)
#   2) Sparkle EdDSA 개인키가 keychain에 있어야 함 (없으면: .sparkle/bin/generate_keys)
#   3) 공증 자격증명을 keychain 프로파일로 저장: make notary-setup
set -euo pipefail

# ─── 입력 ────────────────────────────────────────────────────────────────────
BUILD="${BUILD:-}"
[ -n "$BUILD" ] || { echo "❌ Usage: make release BUILD=007"; exit 1; }

BUILD_PADDED=$(printf "%03d" "$BUILD")           # 7   → 007
BUILD_INT=$((10#$BUILD))                          # 007 → 7   (Xcode용, leading-zero 제거)
VERSION="0.1.${BUILD_PADDED}"                     # 0.1.007
TAG="v${VERSION}"                                 # v0.1.007
REPO="beret21/DaemonHunter"
ASSET="DaemonHunter-${VERSION}.zip"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
NOTARY_PROFILE="${NOTARY_PROFILE:-DaemonHunterNotary}"

SCHEME="ClaudeAgentMonitor"
ARCHIVE="build/${SCHEME}.xcarchive"
EXPORT_DIR="build/export"
SIGN_UPDATE=".sparkle/bin/sign_update"

echo "╔══════════════════════════════════════════════╗"
echo "║  Daemon Hunter 로컬 서명 배포  →  ${TAG}"
echo "╚══════════════════════════════════════════════╝"

# ─── 사전 검증 ───────────────────────────────────────────────────────────────
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "❌ keychain에 'Developer ID Application' 인증서가 없습니다."; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "❌ $SIGN_UPDATE 없음. setup.sh 실행 또는 Sparkle 도구 다운로드 필요."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "❌ 공증 프로파일 '$NOTARY_PROFILE' 없음. 먼저 실행: make notary-setup"; exit 1; }

# ─── 1. 프로젝트 생성 (공개키 임베드) ────────────────────────────────────────
echo "▶ [1/8] xcodegen generate"
xcodegen generate

# ─── 2. 아카이브 (Developer ID + Hardened Runtime) ───────────────────────────
echo "▶ [2/8] archive"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_INT" \
  MARKETING_VERSION="$VERSION" \
  archive

# ─── 3. export (Developer ID) ────────────────────────────────────────────────
echo "▶ [3/8] export (Developer ID)"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions.plist

APP=$(/usr/bin/find "$EXPORT_DIR" -maxdepth 1 -name '*.app' | head -1)
[ -n "$APP" ] || { echo "❌ export된 .app을 찾지 못함"; exit 1; }
echo "   → $APP"

# ─── 4. 공증용 zip 생성 ──────────────────────────────────────────────────────
echo "▶ [4/8] zip 생성 (공증 제출용)"
ZIP="build/${ASSET}"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# ─── 5. 공증 ─────────────────────────────────────────────────────────────────
echo "▶ [5/8] notarize (--wait)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# ─── 6. staple + 재압축 ──────────────────────────────────────────────────────
echo "▶ [6/8] staple + 재압축"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"     # stapled 앱으로 재압축

# ─── 7. Sparkle 서명 ─────────────────────────────────────────────────────────
echo "▶ [7/8] Sparkle EdDSA 서명"
SIG_LINE=$("$SIGN_UPDATE" "$ZIP")                    # 예: sparkle:edSignature="...." length="...."
SIGNATURE=$(echo "$SIG_LINE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
SIZE=$(/usr/bin/stat -f%z "$ZIP")
[ -n "$SIGNATURE" ] || { echo "❌ Sparkle 서명 실패: $SIG_LINE"; exit 1; }
echo "   signature=$SIGNATURE  size=$SIZE"

# ─── 8. GitHub 릴리스 + appcast 갱신 ─────────────────────────────────────────
echo "▶ [8/8] GitHub 릴리스 발행 + appcast 갱신"
git tag "$TAG" 2>/dev/null || true
git push origin "$TAG" 2>/dev/null || true
gh release create "$TAG" "$ZIP" \
  --repo "$REPO" \
  --title "Daemon Hunter ${VERSION}" \
  --notes "자동 서명·공증·Sparkle 서명 배포 (${VERSION})" \
  || gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber

python3 scripts/update_appcast.py \
  --url "$URL" --version "$VERSION" --build "$BUILD_INT" \
  --size "$SIZE" --signature "$SIGNATURE"

git add appcast.xml
git commit -m "chore: release ${VERSION} (signed + notarized)" || true
git push origin HEAD:main

echo ""
echo "✅ 배포 완료: ${TAG}"
echo "   릴리스:  https://github.com/${REPO}/releases/tag/${TAG}"
echo "   appcast: 자동 업데이트 피드 갱신됨"

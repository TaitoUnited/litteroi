#!/bin/zsh
# Publishes Litteroi as the GitHub release litteroi-<build> of ai-library, where the build is the
# number of commits that touched the litteroi folder. The app, with litteroi-cli inside it, is
# signed with Developer ID and notarized as Litteroi.zip, which scripts/update.sh installs and
# which a Mac without the skill gets by hand. Needs App/Signing.local.xcconfig with the team, Xcode
# signed in to that team's account and a notarytool profile named litteroi.
set -euo pipefail
cd "${0:A:h}/.."

if [[ "$(git branch --show-current)" != main || -n "$(git status --porcelain -- .)" ]] ||
  ! git pull --ff-only --quiet || [[ -n "$(git log --oneline origin/main..HEAD)" ]]; then
  echo "Julkaistaan vain pushattu main, jonka litteroi-kansiossa ei ole omia muutoksia."
  exit 1
fi
build=$(git rev-list --count HEAD -- .)
tag="litteroi-$build"
if gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag on jo julkaistu, eikä litteroi-kansio ole muuttunut sen jälkeen."
  exit 0
fi
previous=$(gh release list --exclude-drafts --limit 100 --json tagName \
  --jq '[.[].tagName | select(startswith("litteroi-"))][0] // empty')
git fetch --quiet --tags origin
notes=$(git log --format='- %s' "${previous:+$previous..}HEAD" -- .)

team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' App/Signing.local.xcconfig)
version=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' App/project.yml | head -1)
out=.build/dist
app="$out/export/Litteroi.app"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --spec App/project.yml --quiet
xcodebuild -project App/Litteroi.xcodeproj -scheme Litteroi -configuration Release \
  -derivedDataPath .build/xcode -archivePath "$out/Litteroi.xcarchive" -quiet \
  CURRENT_PROJECT_VERSION="$build" archive

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$team</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Litteroi.xcarchive" \
  -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" \
  -allowProvisioningUpdates -quiet

ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" --keychain-profile litteroi --wait
xcrun stapler staple "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$out/Litteroi.zip"

gh release create "$tag" "$out/Litteroi.zip" --target "$(git rev-parse HEAD)" \
  --title "Litteroi $version ($build)" --notes "$notes"
echo "Julkaistu $tag: $(gh release view "$tag" --json url --jq .url)"

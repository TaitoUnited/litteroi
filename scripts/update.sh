#!/bin/zsh
# Brings Litteroi up to date: pulls main for the skill, then installs the newest litteroi-<build>
# release of the app, with litteroi-cli inside it, when it is newer than the installed one. A
# checkout on another branch, or with changes of its own, is left alone, and so is the app a
# developer built from it.
set -uo pipefail
repo="${0:A:h:h}"
app=~/Applications/Litteroi.app
team=VXSNWDR5MY
cd "$repo" || exit 1

branch=$(git -C "$repo" branch --show-current)
if [[ "$branch" != main ]]; then
  echo "Ei päivitetty: Litteroin repo on haarassa $branch eikä mainissa."
  exit 0
fi
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
  echo "Ei päivitetty: Litteroin repossa on omia muutoksia."
  exit 0
fi
if ! GIT_TERMINAL_PROMPT=0 git -C "$repo" pull --ff-only --quiet; then
  echo "Ei päivitetty: git pull ei onnistunut, joten käytössä on asennettu versio."
  exit 0
fi

if ! tag=$(gh release list --exclude-drafts --exclude-pre-releases --limit 100 --json tagName \
  --jq '[.[].tagName | select(startswith("litteroi-"))][0] // empty' 2>/dev/null); then
  echo "Ei päivitetty: julkaisuja ei saatu GitHubista. Onko gh asennettu ja kirjautunut?"
  exit 0
fi
if [[ -z "$tag" ]]; then
  echo "Ei päivitetty: Litteroista ei ole vielä julkaisua."
  exit 0
fi
installed=$(defaults read "$app/Contents/Info" CFBundleVersion 2>/dev/null)
if (( ${installed:-0} >= ${tag#litteroi-} )); then
  echo "Litteroi on ajan tasalla ($tag)."
  exit 0
fi
if pgrep -x Litteroi >/dev/null; then
  echo "Litteroi nauhoittaa, joten se päivitetään vasta seuraavalla kerralla."
  exit 0
fi

download=$(mktemp -d)
trap 'rm -rf "$download"' EXIT
if ! gh release download "$tag" --pattern Litteroi.zip --dir "$download" ||
  ! ditto -x -k "$download/Litteroi.zip" "$download"; then
  echo "Ei päivitetty: $tag ei latautunut."
  exit 0
fi
if ! spctl --assess --type execute "$download/Litteroi.app" 2>/dev/null ||
  ! codesign -dv "$download/Litteroi.app" 2>&1 | grep -x "TeamIdentifier=$team" >/dev/null; then
  echo "Ei asennettu: $tag ei ole Litteroin tiimin allekirjoittama ja Applen notarisoima."
  exit 1
fi

[[ -d "$app" ]] && mv "$app" "$download/vanha.app"
ditto "$download/Litteroi.app" "$app"
# launchd starts the new watcher once the old one exits; --register-watcher registers it on a Mac
# where it never ran, and again when the new app is signed another way than the old one.
pkill -x LitteroiWatcher
"$app/Contents/MacOS/Litteroi" --register-watcher
echo "Litteroi päivitetty: $(gh release view "$tag" --json name --jq .name)"

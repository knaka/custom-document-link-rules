#!/usr/bin/env bash
set -- _88bd54d "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

pushd "${BASH_SOURCE[0]%[/\\]*}" &>/dev/null || pushd . >/dev/null
. ../.lib/utils.sh
popd >/dev/null || exit

task_build() {
  npm run compile  
}

task_install() {
  mkdir -p "$PROJECT_DIR"/.build
  vsce package --out="$PROJECT_DIR"/.build/temp.vsix
  code --uninstall-extension ayutaya.custom-document-link-rules || :
  rm -fr "$HOME"/.vscode/extensions/ayutaya.custom-document-link-rules-*
  code --install-extension "$PROJECT_DIR"/.build/temp.vsix
}

task_init() {
  # Your First Extension | Visual Studio Code Extension API https://code.visualstudio.com/api/get-started/your-first-extension
  npx --package=yo --package=generator-code -- yo code .
}

task_login() {
  vsce login ayutaya
}

task_whoami() {
  vsce ls-publishers
}

task_publish() {
  vsce publish
}

# Bump the patch version (x.y.Z) in package.json and package-lock.json, without committing or tagging.
task_patchver__bump() {
  npm version patch --no-git-tag-version
}

# Prepend the changes since the latest tag to CHANGELOG.md as the release of the version in package.json. Run it after bumping the version and before tagging, then edit the entries by hand.
task_changelog__update() {
  local changelog="$PROJECT_DIR"/CHANGELOG.md
  local version
  version="$(jq -r .version "$PROJECT_DIR"/package.json)"
  if grep -q "^## $version " "$changelog"
  then
    echo "CHANGELOG.md already has an entry for $version" >&2
    return 1
  fi
  # Without this, a release with no user-facing commits would get an empty heading.
  if ! git-cliff --unreleased --context | jq -e 'any(.[]; .commits | length > 0)' >/dev/null
  then
    echo "No unreleased user-facing changes to add" >&2
    return 1
  fi
  git-cliff --unreleased --tag "v$version" --prepend "$changelog"
}

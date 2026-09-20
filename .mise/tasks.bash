#!/usr/bin/env bash
set -- _88bd54d "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

pushd "${BASH_SOURCE[0]%[/\\]*}" &>/dev/null || pushd . >/dev/null
. ../.lib/utils.sh
popd >/dev/null || exit

task_install() {
  mkdir -p "$PROJECT_DIR"/.build
  vsce package --out="$PROJECT_DIR"/.build/temp.vsix
  code --uninstall-extension knaka.custom-document-link-rules || :
  rm -fr "$HOME"/.vscode/extensions/knaka.custom-document-link-rules-*
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

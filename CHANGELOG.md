# Changelog

All notable changes to the "Custom Document Link Rules" extension are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## 0.0.7 - 2026-11-24

### Added

- This changelog, covering all releases so far.

## 0.0.6 - 2026-11-24

### Fixed

- Capture group references (`$1`, `$<name>`, …) were left unexpanded when a rule's `pattern` used lookarounds or anchors (e.g. a trailing `(?=\s)`), so the link opened the whole matched text instead of the captured path.

### Removed

- The "Open File on Line and Char position" command (`customDocumentLinkRules.openFile`), which appeared in the Command Palette but was never implemented.

## 0.0.5 - 2026-09-24

### Changed

- **Breaking:** The `rangeGroup` rule property is renamed to `linkRange`. Rules using `rangeGroup` must be updated.

## 0.0.4 - 2026-09-24

### Changed

- **Breaking:** `filePath`, `lineNum`, `charPos` and `searchText` are now expanded in two steps: capture groups (`$1`, …) are substituted first, then the result is interpolated as a JavaScript template literal. `match`, `position`, the file and workspace variables, `env` and `workspaceFolderOf()` are available inside `${...}`.
  - `lineNum`/`charPos` are no longer evaluated as bare expressions: write `"${Number($2) + 1}"` instead of `"$2 + 1"`.
  - `${env:NAME}` becomes `${env.NAME}`, and `${workspaceFolder:NAME}` becomes `${workspaceFolderOf("NAME")}`.
- **Breaking:** The `lineNr` rule property is renamed to `lineNum`. Rules using `lineNr` must be updated.
- Interpolation is skipped in untrusted workspaces.

### Added

- `disableInterpolation` rule option, to substitute capture groups only.

### Removed

- **Breaking:** The `searchTextIsExpression` rule option. Write expressions inside `${...}` instead.

## 0.0.3 - 2026-09-23

### Removed

- **Breaking:** The `${var:find=...:replace=...}` transform syntax for variables.
- **Breaking:** `${command:...}` variables.
- **Breaking:** `documentLink: false` no longer has any effect.

## 0.0.2 - 2026-09-20

### Changed

- The publisher is changed to `ayutaya`.

## 0.0.1 - 2026-09-20

### Added

- Initial release: turn text matched by user-configured regular expressions (`custom-document-link-rules.rules`) into clickable Document Links, with per-rule `filePath`, line/character position, `searchText`, link range and `languageIds`, plus the `fileroot` and `enableLogging` settings.

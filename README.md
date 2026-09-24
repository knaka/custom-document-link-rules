# Custom Document Link Rules

Turn any text in any file into a clickable [Document Link](https://code.visualstudio.com/api/references/vscode-api#DocumentLink) (Cmd/Ctrl+Click to follow), using regular expressions you configure yourself.

There is no built-in rule for any language. Everything the extension does is driven by the [`custom-document-link-rules.rules`](#custom-document-link-rulesrules) setting.

Inspired by [HTML Related Links](https://marketplace.visualstudio.com/items?itemName=rioj7.html-related-links), but scoped down to just the configurable `DocumentLinkProvider` — no tree view.

## Installation

Install [Custom Document Link Rules](https://marketplace.visualstudio.com/items?itemName=ayutaya.custom-document-link-rules) from the Visual Studio Marketplace, or search for "Custom Document Link Rules" in the Extensions view.

## How it works

The extension reads `custom-document-link-rules.rules` and registers a `DocumentLinkProvider` for whichever `languageId`s the rules actually need (or a single provider for every file, if any rule applies to every language — see [`languageIds`](#languageids)). The provider list is rebuilt whenever the setting changes, so no reload is needed.

For each open document, every rule that applies to its language has its `pattern` regex run against the text. A match becomes a Document Link whose target is the file path built from `filePath` (and, optionally, a line/character position to jump to).

## `custom-document-link-rules.rules`

An **array** of rules. A rule is either a plain string — a shorthand for `{ "pattern": "...", "filePath": '$1' }` — or an object with these properties:

| Property | Type | Default | Description |
|---|---|---|---|
| `pattern` | string (regex, required) | — | Matched against the document text. Must have at least one capture group. |
| `filePath` | [template](#templates) | `"$1"` | The link target. Start it with `/` to make it relative to a [`fileroot`](#custom-document-link-rulesfileroot) folder instead of the current file's folder. |
| `isAbsolutePath` | boolean | `false` | Treat the resolved `filePath` as an absolute path as-is, instead of joining it to the current file's folder or a fileroot folder. |
| `lineNum` | [template](#templates) | — | Line number to jump to. |
| `charPos` | [template](#templates) | — | Character position to jump to. Only used when `lineNum` is set. |
| `searchText` | [template](#templates) | — | Text to search for in the target file, used to jump to it instead of `lineNum`/`charPos`. Takes precedence over `lineNum`/`charPos` when set. |
| `disableInterpolation` | boolean | `false` | Skip step 2 of [template](#templates) expansion for this rule: only capture groups are substituted, and `${...}` is left as literal text. |
| `linkRange` | string | derived from `filePath` | Which part of the match becomes the clickable range, as `$n` (`$0` for the whole match). Defaults to the capture group used in `filePath` (or the whole match if `lineNum` is set). |
| `languageIds` | array of string, or `null` | `null` | Restrict this rule to these [`languageId`](https://code.visualstudio.com/docs/languages/overview#_language-id)s. `null` (or omitting the property) applies the rule to every language. |

Because different regexes can match overlapping text, list the rule that matches the *largest* range first — once a range is claimed, later rules in the same document are skipped for that range.

### `languageIds`

```jsonc
"custom-document-link-rules.rules": [
  { "pattern": "require\\('([^']+)'\\)", "languageIds": ["javascript", "typescript"] },
  { "pattern": "\\[[^\\]]+\\]\\(([^\\s]+)\\)", "languageIds": ["markdown"] },
  { "pattern": "\\bTODO:(\\S+)" } // languageIds omitted: applies to every file
]
```

## `custom-document-link-rules.fileroot`

An array of directories, relative to the workspace folder, used to resolve `filePath` values that start with `/` (for example, a stylesheet reference relative to a site root rather than to the current file).

The first entry (joined with the workspace folder) whose path is a prefix of the current file's folder is used as the root; if none match, the workspace folder itself is used.

## Templates

`filePath`, `lineNum`, `charPos`, and `searchText` are templates, expanded in two steps:

1. `pattern`'s capture groups `$1`, `$2`, ... are substituted as raw text (as in [`String.prototype.replace`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/replace#specifying_a_string_as_the_replacement)).
2. The result is interpolated as a JavaScript [template literal](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Template_literals) (via `String.raw`, so backslashes stay as-is), so `${...}` can hold any JS expression using the [variables](#variables) below.

`lineNum` and `charPos` are converted to numbers after expansion.

```jsonc
{
  "pattern": "(?:^|(?<=[\\s()]))(?<file>\\./[^\\s]+)#:~:text=(?:[a-zA-Z0-9_.!~*'()\\-%]+-,)?(?<text>[^,\\s&]+)",
  "filePath": "${match.groups['file']}",
  "searchText": "${decodeURIComponent(match.groups['text'])}",
  "linkRange": "$0",
},
```

Captured text is inserted before interpolation, so text containing `` ` ``, `\`, or `${` can break (or be evaluated as part of) the template; reference it as `match[n]` inside `${...}` when that matters.

Step 2 is skipped for a rule with `disableInterpolation: true`, and for every rule in an [untrusted workspace](https://code.visualstudio.com/docs/editor/workspace-trust): only capture groups are substituted.

## Variables

Inside `${...}` in a template:

* `match` — the regex match array: `match[0]` is the whole match, `match[1]`, ... the capture groups
* `position` — `position.start.line`, `position.start.character`, `position.end.line`, `position.end.character`: the 1-based line/character of the match's start and end
* `fileDirname`, `fileBasename`, `fileBasenameNoExtension`, `fileExtname` — derived from the current file
* `workspaceFolder`, `workspaceFolderBasename`, `fileWorkspaceFolder`, `relativeFile`, `relativeFileDirname`
* `env` — environment variables, e.g. `${env.HOME}`
* `workspaceFolderOf(name)` — a specific workspace folder in a multi-root workspace, by name, `"[index]"`, or a path suffix, e.g. `${workspaceFolderOf("server")}/src/$1`

## Examples

### Node-style `require`/`import`

```jsonc
"custom-document-link-rules.rules": [
  { "pattern": "require\\('([^']+)'\\)", "languageIds": ["javascript"] },
  { "pattern": "import [^ ]+ from '((?=src/).+?)'", "filePath": "/$1.js", "languageIds": ["javascript"] }
]
```

The second rule's `filePath` starts with `/`, so it resolves against [`fileroot`](#custom-document-link-rulesfileroot) instead of the current file's folder.

### Jump to a specific line: `file.py:42`

```jsonc
"custom-document-link-rules.rules": [
  { "pattern": "([-\\w./]+\\.py):(\\d+)", "filePath": "$1", "lineNum": "$2" }
]
```

No `languageIds`, so this applies no matter which file you write it in.

### Compute the line number: RFC 5147 `file.txt#line=41`

[RFC 5147](https://datatracker.ietf.org/doc/html/rfc5147) fragment identifiers count lines from 0, so add 1 inside `${...}`:

```jsonc
"custom-document-link-rules.rules": [
  {
    "pattern": "(?:^|(?<=[\\s()]))(\\./[^\\s]+\\.txt)#line=(\\d+)",
    "filePath": "$1",
    "lineNum": "${Number($2) + 1}"
  }
]
```

### Jump to matching text instead of a line number

Useful when the target line moves around; the link still resolves as long as the text still exists in the target file.

```jsonc
"custom-document-link-rules.rules": [
  {
    "pattern": "\\[[^\\]]+\\]\\(([^\\s]+)\\s+\"([^\"]+)\"\\)",
    "filePath": "$1",
    "searchText": "$2",
    "languageIds": ["markdown"]
  }
]
```

This repurposes a Markdown link's title as the text to search for after navigating to `$1`.


## Notes

* Settings are read per-document, so multi-root workspaces with different `rules`/`fileroot` per folder work as expected — but which *languageIds* get a provider registered at all is decided from the first workspace folder's configuration, since VS Code providers are registered globally, not per folder.
* If every rule has `languageIds` set, the extension registers one `DocumentLinkProvider` per referenced language, so it competes fairly on priority with other language-specific link providers (including VS Code's own) when ranges overlap. As soon as any rule omits `languageIds` (applies to every language), it registers a single broad `{ scheme: 'file' }` provider instead — adding language-specific selectors on top of that broad one would make VS Code invoke the provider twice for matching documents and duplicate every link.

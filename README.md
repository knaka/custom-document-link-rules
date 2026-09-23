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
| `filePath` | string | `"$1"` | The link target, built from `pattern`'s capture groups (`$1`, `$2`, ...) and [variables](#variables). Start it with `/` to make it relative to a [`fileroot`](#custom-document-link-rulesfileroot) folder instead of the current file's folder. |
| `isAbsolutePath` | boolean | `false` | Treat the resolved `filePath` as an absolute path as-is, instead of joining it to the current file's folder or a fileroot folder. |
| `lineNr` | string | — | Line number to jump to: capture groups and/or a JS expression using [`position`](#the-position-variable). |
| `charPos` | string | — | Character position to jump to. Only used when `lineNr` is set. |
| `searchText` | string | — | Literal text to search for in the target file, used to jump to it instead of `lineNr`/`charPos`. Takes precedence over `lineNr`/`charPos` when set. |
| `searchTextIsExpression` | boolean | `false` | Evaluate `searchText` as a JS expression. See [below](#searchTextIsExpression). |
| `rangeGroup` | string | derived from `filePath` | Which part of the match becomes the clickable range, as `$n`. Defaults to the capture group used in `filePath` (or the whole match if `lineNr` is set). |
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

## Variables

`filePath` (and the `openFile` command's `file` argument) can reference:

* `${fileDirname}`, `${fileBasename}`, `${fileBasenameNoExtension}`, `${fileExtname}` — derived from the current file
* `${workspaceFolder}`, `${workspaceFolderBasename}`, `${fileWorkspaceFolder}`, `${relativeFile}`, `${relativeFileDirname}`
* `${env:NAME}` — an environment variable
* `${workspaceFolder:NAME}` — a specific workspace folder in a multi-root workspace, by name, `[index]`, or a path suffix
* `${command:name}` — the result of running a command (**`openFile` only** — rule matching happens synchronously on every keystroke, so it can't await a command)

### The `position` variable

Inside `lineNr`, `charPos`, and an expression `searchText`, a `position` object is available with `position.start.line`, `position.start.character`, `position.end.line`, `position.end.character` — the 1-based line/character of the match's start and end.

### `searchTextIsExpression`

By default `searchText` is a literal string, built the same way as `filePath` (capture groups substituted as raw text). Set `searchTextIsExpression: true` to evaluate it as a JS expression instead — capture groups are still referenced as `$1`, `$2`, ..., but are spliced in as safe, quoted string values (via `JSON.stringify`) rather than raw text, so they can't break the expression's syntax:

```jsonc
{
  "pattern": "file:///?(\\.[^#]+)#:~:text=([^,\\s]+)",
  "filePath": "$1",
  "searchText": "decodeURIComponent($2)",
  "searchTextIsExpression": true
}
```

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
  { "pattern": "([-\\w./]+\\.py):(\\d+)", "filePath": "$1", "lineNr": "$2" }
]
```

No `languageIds`, so this applies no matter which file you write it in.

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

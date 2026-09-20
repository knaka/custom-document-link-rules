---
name: shell-script-grammar
description: Portability and version-compatibility rules for this project's shell scripts. Use when writing, editing, or reviewing any `.sh` or `.bash` file here.
---
# Shell Script Grammar

Shell script files with the `.bash` extension must be implemented using only features available up through Bash version 3, since they need to run under Bash version 3 on macOS.

Files with the `.sh` extension should generally be implemented using only POSIX shell features, so that they are executable with Bash POSIX mode, Dash, and BusyBox Ash. However, `local` variable declarations are not part of POSIX shell features, but they can be used as they are available in the shells listed above.

Special shell variables like `$IFS` can be overridden with `local` declarations. Shell scoping is dynamic, not lexical, so this override remains in effect for the function itself and for any functions it calls (until they return) — but it still does not affect the outer scope, i.e. the code that called the function where it was declared.

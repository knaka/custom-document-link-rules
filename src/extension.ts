import * as vscode from 'vscode';
import * as path from 'path';

const extensionName = 'Custom Document Link Rules';
const configSection = 'custom-document-link-rules';

// ---------------------------------------------------------------------------
// Configuration types
// ---------------------------------------------------------------------------

// External expression of rule
interface RuleConfig {
  pattern: string;
  filePath?: string;
  isAbsolutePath?: boolean;
  lineNr?: string;
  charPos?: string;
  searchText?: string;
  searchTextIsExpression?: boolean;
  rangeGroup?: string;
  documentLink?: boolean;
  allowCurrentFile?: boolean;
  languageIds?: string[] | null;
}

// External expression of rules. “string” is a shorthand for `{ "pattern": "...", "filePath": '$1' }`
type RulesConfig = Array<string | RuleConfig>;

// Custom link rule
interface Rule {
  pattern: string;
  filePath: string;
  isAbsolutePath: boolean;
  lineNr?: string;
  charPos?: string;
  searchText?: string;
  searchTextIsExpression: boolean;
  rangeGroup?: string;
  documentLink: boolean;
  allowCurrentFile: boolean;
  languageIds: string[] | null;
}

// Found link
interface MatchedLink {
  linkPath: string;
  lineNr?: number;
  charPos?: number;
  searchText?: string;
  pathRange: vscode.Range;
  fullRange: vscode.Range;
  documentLink: boolean;
}

interface PositionInfo {
  start: { line: number; character: number };
  end: { line: number; character: number };
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function log(...args: unknown[]): void {
  if (vscode.workspace.getConfiguration(configSection).get<boolean>('enableLogging')) {
    console.log(extensionName, ...args);
  }
}

function getCaptureGroupNr(text: string): number | undefined {
  const match = text.match(/\$(\d+)/);
  return match ? Number(match[1]) : undefined;
}

function offsetToPosition(document: vscode.TextDocument, offset: number): { line: number; character: number } {
  const position = document.positionAt(offset);
  return { line: position.line + 1, character: position.character + 1 };
}

// A rule's `lineNr`/`charPos`/`searchText` (when `searchTextIsExpression`) are small
// JavaScript expressions evaluated against the match `position`. `Function` is the only
// way to turn user-provided settings text into a callable expression at runtime.
function getExpressionFunction(expr: string): ((position: PositionInfo) => unknown) | undefined {
  try {
    const factory = Function(`"use strict";return (function calcexpr(position) {
      return (${expr});
    });`) as () => (position: PositionInfo) => unknown;
    return factory();
  } catch {
    vscode.window.showErrorMessage(`${extensionName}: incomplete expression: ${expr}`);
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Variable substitution (${fileDirname}, ${workspaceFolder}, ${env:...}, ...)
// ---------------------------------------------------------------------------

function substituteVariable(text: string, value: string, variableName: string): string {
  return text.replace(new RegExp(`\\$\\{${variableName}\\}`, 'g'), value);
}

function getNamedWorkspaceFolder(name: string): vscode.WorkspaceFolder | undefined {
  const folders = vscode.workspace.workspaceFolders ?? [];
  let list: vscode.WorkspaceFolder[];
  if (name[0] === '[') {
    const index = Number(name.substring(1, name.length - 1));
    list = folders.filter((_w, idx) => idx === index);
  } else if (name.includes('/')) {
    list = folders.filter(w => w.uri.path.endsWith(name));
  } else {
    list = folders.filter(w => w.name === name);
  }
  if (list.length === 0) {
    vscode.window.showErrorMessage(`${extensionName}: workspace not found with name: ${name}`);
    return undefined;
  }
  return list[0];
}

// Rule matching runs on every document parse, so only synchronous substitution is
// supported here. `${command:...}` needs an async round-trip and is only available
// to the `openFile` command below.
function variableSubstitution(text: string, document: vscode.TextDocument | undefined): string {
  text = text.replace(/\$\{env:([^}]+)\}/g, (_m, name: string) => process.env[name] ?? 'Unknown');
  text = text.replace(/\$\{workspaceFolder:(.+?)\}/g, (_m, name: string) => {
    const wsf = getNamedWorkspaceFolder(name);
    return wsf ? wsf.uri.fsPath : 'Unknown';
  });

  let documentWorkspace: vscode.WorkspaceFolder | undefined;
  let fileDirname: string | undefined;

  if (document) {
    documentWorkspace = vscode.workspace.getWorkspaceFolder(document.uri);
    const file = document.fileName;
    fileDirname = path.dirname(file);
    const fileBasename = path.basename(file);
    const fileExtname = path.extname(file);
    const fileBasenameNoExtension = fileBasename.slice(0, fileBasename.length - fileExtname.length);
    text = substituteVariable(text, fileDirname, 'fileDirname');
    text = substituteVariable(text, fileBasename, 'fileBasename');
    text = substituteVariable(text, fileBasenameNoExtension, 'fileBasenameNoExtension');
    text = substituteVariable(text, fileExtname, 'fileExtname');
  }

  if (text.includes('${')) {
    const folders = vscode.workspace.workspaceFolders ?? [];
    const workspace = folders.length === 1 ? folders[0] : documentWorkspace;
    if (!workspace) {
      vscode.window.showErrorMessage(`${extensionName}: use a named \${workspaceFolder:name} variable in a multi-root workspace`);
      return text;
    }
    const workspaceFolder = workspace.uri.fsPath;
    text = substituteVariable(text, workspaceFolder, 'workspaceFolder');
    text = substituteVariable(text, path.basename(workspaceFolder), 'workspaceFolderBasename');

    if (documentWorkspace && document) {
      const relativeFile = document.fileName.substring(workspaceFolder.length + 1);
      const relativeFileDirname = (fileDirname ?? '').substring(workspaceFolder.length + 1);
      text = substituteVariable(text, workspaceFolder, 'fileWorkspaceFolder');
      text = substituteVariable(text, relativeFile, 'relativeFile');
      text = substituteVariable(text, relativeFileDirname, 'relativeFileDirname');
    }
  }

  return text;
}

interface CommandArg {
  command: string;
  args?: unknown;
}

async function runCommandVariable(arg: CommandArg): Promise<unknown> {
  return vscode.commands.executeCommand(arg.command, arg.args);
}

async function substituteCommandVariables(text: string, commandArgs: Record<string, CommandArg>): Promise<string> {
  const varRE = /\$\{command:(.+?)\}/g;
  const names: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = varRE.exec(text)) !== null) {names.push(m[1]);}

  const results: unknown[] = [];
  for (const name of names) {
    results.push(await runCommandVariable(commandArgs[name] ?? { command: name }));
  }
  let i = 0;
  return text.replace(varRE, () => String(results[i++]));
}

// ---------------------------------------------------------------------------
// Rule normalization
// ---------------------------------------------------------------------------

function toRule(item: string | RuleConfig): Rule {
  if (typeof item === 'string') {
    return {
      pattern: item,
      filePath: '$1',
      isAbsolutePath: false,
      searchTextIsExpression: false,
      documentLink: true,
      allowCurrentFile: false,
      languageIds: null,
    };
  }
  const filePath = item.filePath ?? '$1';
  let rangeGroup = item.rangeGroup;
  if (!rangeGroup && !item.lineNr) {
    const groupNr = getCaptureGroupNr(filePath);
    if (groupNr !== undefined) {rangeGroup = `$${groupNr}`;}
  }
  return {
    pattern: item.pattern,
    filePath,
    isAbsolutePath: item.isAbsolutePath ?? false,
    lineNr: item.lineNr,
    charPos: item.charPos,
    searchText: item.searchText,
    searchTextIsExpression: item.searchTextIsExpression ?? false,
    rangeGroup,
    documentLink: item.documentLink ?? true,
    allowCurrentFile: item.allowCurrentFile ?? false,
    languageIds: item.languageIds ?? null,
  };
}

function getConfiguredRules(config: vscode.WorkspaceConfiguration): Rule[] {
  return config.get<RulesConfig>('rules', []).map(toRule);
}

// ---------------------------------------------------------------------------
// Finding links in a document
// ---------------------------------------------------------------------------

function findLinks(document: vscode.TextDocument): MatchedLink[] {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
  const config = vscode.workspace.getConfiguration(configSection, workspaceFolder?.uri);
  const fileroot = config.get<string[]>('fileroot', []);

  const rules = getConfiguredRules(config).filter(
    rule => rule.languageIds === null || rule.languageIds.includes(document.languageId)
  );
  if (rules.length === 0) {return [];}

  const ownFilePath = document.uri.fsPath;
  const docFolder = path.dirname(ownFilePath);
  let filerootFolder = workspaceFolder ? workspaceFolder.uri.fsPath : docFolder;
  if (workspaceFolder) {
    for (const root of fileroot) {
      const possibleRoot = path.join(workspaceFolder.uri.fsPath, root);
      if (docFolder.startsWith(possibleRoot)) {
        filerootFolder = possibleRoot;
        break;
      }
    }
  }

  const docText = document.getText();
  const matches: MatchedLink[] = [];

  for (const rule of rules) {
    const patternRE = new RegExp(rule.pattern, 'gmi');
    const replaceRE = new RegExp(rule.pattern, 'mi'); // separate copy: replace() resets lastIndex
    let result: RegExpExecArray | null;
    while ((result = patternRE.exec(docText)) !== null) {
      if (result.length < 2) {continue;} // no capture group defined
      const matchResult = result;

      let filePath = matchResult[0].replace(replaceRE, rule.filePath);
      filePath = variableSubstitution(filePath, document);
      if (filePath.length === 0) {continue;}
      if (filePath === '/') {filePath = '/__root__';}

      let linkPath = filePath;
      if (!rule.isAbsolutePath) {
        const base = filePath.startsWith('/') ? filerootFolder : docFolder;
        linkPath = path.join(base, filePath.startsWith('/') ? filePath.substring(1) : filePath);
      }
      if (!rule.allowCurrentFile && linkPath === ownFilePath) {continue;}

      let filePos = matchResult.index;
      let filePosEnd = patternRE.lastIndex;
      const fullRange = new vscode.Range(document.positionAt(filePos), document.positionAt(filePosEnd));
      // regexes matching the largest text ranges should be listed first in settings
      if (matches.some(m => {
        const overlap = fullRange.intersection(m.fullRange);
        return overlap !== undefined && !overlap.isEmpty;
      })) {continue;}

      if (rule.rangeGroup) {
        const groupNr = getCaptureGroupNr(rule.rangeGroup);
        if (groupNr !== undefined && groupNr < matchResult.length) {
          const text = matchResult[groupNr];
          filePos += matchResult[0].indexOf(text);
          filePosEnd = filePos + text.length;
        }
      }
      const pathRange = new vscode.Range(document.positionAt(filePos), document.positionAt(filePosEnd));

      const position: PositionInfo = {
        start: offsetToPosition(document, matchResult.index),
        end: offsetToPosition(document, patternRE.lastIndex),
      };
      const getNumber = (expr: string | undefined): number | undefined => {
        if (!expr) {return undefined;}
        const fn = getExpressionFunction(matchResult[0].replace(replaceRE, expr));
        return fn ? Number(fn(position)) : undefined;
      };
      const lineNr = getNumber(rule.lineNr);
      const charPos = getNumber(rule.charPos);

      let searchText = rule.searchText;
      if (searchText) {
        if (rule.searchTextIsExpression) {
          // Capture groups are spliced in via JSON.stringify so they always land as safe
          // JS string literals, not raw text that could break the expression's syntax.
          const expr = searchText.replace(/\$(\d+)/g, (_m, n) => JSON.stringify(matchResult[Number(n)] ?? ''));
          const fn = getExpressionFunction(expr);
          searchText = fn ? String(fn(position)) : undefined;
        } else {
          searchText = matchResult[0].replace(replaceRE, searchText);
        }
      }

      matches.push({ linkPath, lineNr, charPos, searchText, pathRange, fullRange, documentLink: rule.documentLink });
    }
  }

  return matches;
}

// ---------------------------------------------------------------------------
// DocumentLinkProvider
// ---------------------------------------------------------------------------

class CustomDocumentLink extends vscode.DocumentLink {
  linkPath: string;
  searchText?: string;
  lineNr?: number;
  charPos?: number;

  constructor(match: MatchedLink) {
    super(match.pathRange);
    this.linkPath = match.linkPath;
    this.searchText = match.searchText;
    this.lineNr = match.lineNr;
    this.charPos = match.charPos;
  }
}

function locateText(document: vscode.TextDocument, text: string): [number, number] {
  let lineNr = 1;
  let charPos = 1;
  const offset = document.getText().indexOf(text);
  if (offset >= 0) {
    const position = document.positionAt(offset);
    lineNr = position.line + 1;
    charPos = position.character + 1;
  }
  return [lineNr, charPos];
}

function findOpenTextDocument(uri: vscode.Uri): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find(
    doc => !doc.isClosed && doc.uri.scheme === 'file' && doc.uri.fsPath === uri.fsPath
  );
}

async function resolveLink(link: CustomDocumentLink): Promise<vscode.DocumentLink> {
  let uri = vscode.Uri.file(link.linkPath);
  let lineNr = link.lineNr;
  let charPos = link.charPos;

  if (link.searchText) {
    let document = findOpenTextDocument(uri);
    if (!document) {
      try {
        const stat = await vscode.workspace.fs.stat(uri);
        if (stat.type === vscode.FileType.File) {
          document = await vscode.workspace.openTextDocument(uri);
        }
      } catch {
        // file doesn't exist or isn't readable; fall through to the notice below
      }
    }
    if (document) {
      [lineNr, charPos] = locateText(document, link.searchText);
    } else {
      vscode.window.showInformationMessage(`${extensionName}: please open the file and try again: ${uri.fsPath}`);
    }
  }

  if (lineNr) {
    let fragment = `L${lineNr}`;
    if (charPos) {fragment += `,${charPos}`;}
    uri = uri.with({ fragment });
  }
  link.target = uri;
  log('Resolved link target:', uri.toString());
  return link;
}

const linkProvider: vscode.DocumentLinkProvider = {
  provideDocumentLinks(document: vscode.TextDocument): vscode.DocumentLink[] {
    return findLinks(document).filter(m => m.documentLink).map(m => new CustomDocumentLink(m));
  },
  resolveDocumentLink(link: vscode.DocumentLink): vscode.ProviderResult<vscode.DocumentLink> {
    return resolveLink(link as CustomDocumentLink);
  },
};

// ---------------------------------------------------------------------------
// Dynamic (re)registration, one selector per configured languageId
// ---------------------------------------------------------------------------

let linkProviderDisposables: vscode.Disposable[] = [];

function registerLinkProviders(): void {
  linkProviderDisposables.forEach(d => d.dispose());
  linkProviderDisposables = [];

  const rules = getConfiguredRules(vscode.workspace.getConfiguration(configSection));
  if (rules.length === 0) {return;}

  // A rule with languageIds: null applies to every language, so a single { scheme: 'file' }
  // selector already covers every other rule too. Registering per-language selectors on top
  // of it would make VS Code call provideDocumentLinks twice for the same document (once per
  // matching selector), duplicating every link it returns.
  if (rules.some(rule => rule.languageIds === null)) {
    linkProviderDisposables.push(vscode.languages.registerDocumentLinkProvider({ scheme: 'file' }, linkProvider));
    return;
  }

  const languageIds = new Set<string>();
  for (const rule of rules) {
    for (const languageId of rule.languageIds ?? []) {languageIds.add(languageId);}
  }
  for (const languageId of languageIds) {
    const selector: vscode.DocumentSelector = { language: languageId, scheme: 'file' };
    linkProviderDisposables.push(vscode.languages.registerDocumentLinkProvider(selector, linkProvider));
  }
}

// ---------------------------------------------------------------------------

export function activate(context: vscode.ExtensionContext): void {
  registerLinkProviders();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(e => {
      if (e.affectsConfiguration(`${configSection}.rules`)) {
        registerLinkProviders();
      }
    })
  );
}

export function deactivate(): void {
  linkProviderDisposables.forEach(d => d.dispose());
  linkProviderDisposables = [];
}

import * as vscode from 'vscode';
import * as path from 'path';

const extensionName = 'Custom Document Link Rules';
const configSection = 'custom-document-link-rules';

// Rule item in the setting
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

// Rules in the setting. Item A plain string item is shorthand for `{ "pattern": "...", "filePath": '$1' }`
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

interface PositionInfo {
  start: { line: number; character: number };
  end: { line: number; character: number };
}

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

// A rule's `lineNr`/`charPos`/`searchText` (when `searchTextIsExpression`) are
// small JavaScript expressions evaluated against the match `position`.
// `Function` is the only way to turn user-provided settings text into a
// callable expression at runtime.
function getExpressionFunction(expr: string): ((position: PositionInfo) => unknown) | undefined {
  try {
    const factory = Function(`"use strict"; return (function calcexpr(position) {
      return (${expr});
    });`) as () => (position: PositionInfo) => unknown;
    return factory();
  } catch {
    vscode.window.showErrorMessage(`${extensionName}: incomplete expression: ${expr}`);
    return undefined;
  }
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

function toRules(config: vscode.WorkspaceConfiguration): Rule[] {
  return config.get<RulesConfig>('rules', []).map(toRule);
}

// Found link
interface MatchedLink {
  linkPath: string;
  lineNr?: number;
  charPos?: number;
  searchText?: string;
  pathRange: vscode.Range;
  fullRange: vscode.Range;
}

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

function substituteVariable(text: string, value: string, variableName: string): string {
  return text.replace(new RegExp(`\\$\\{${variableName}\\}`, 'g'), value);
}

function substituteVariables(text: string, document: vscode.TextDocument): string {
  text = text.replace(/\$\{env:([^}]+)\}/g, (_m, name: string) => process.env[name] ?? 'Unknown');
  text = text.replace(/\$\{workspaceFolder:(.+?)\}/g, (_m, name: string) => {
    const wsf = getNamedWorkspaceFolder(name);
    return wsf ? wsf.uri.fsPath : 'Unknown';
  });
  let documentWorkspace: vscode.WorkspaceFolder | undefined;
  let fileDirname: string | undefined;
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

// Find links in a document.
function findCustomDocumentLinks(document: vscode.TextDocument): CustomDocumentLink[] {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
  const config = vscode.workspace.getConfiguration(configSection, workspaceFolder?.uri);
  const fileroot = config.get<string[]>('fileroot', []);
  const rules = toRules(config).filter(
    rule => rule.languageIds === null || rule.languageIds.includes(document.languageId)
  );
  if (rules.length === 0) {
    return []
  }
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
  const links: MatchedLink[] = [];
  for (const rule of rules) {
    const patternRE = new RegExp(rule.pattern, 'gmi');
    // separate copy: replace() resets lastIndex
    const replaceRE = new RegExp(rule.pattern, 'mi');
    let optMatch: RegExpExecArray | null;
    while ((optMatch = patternRE.exec(docText)) !== null) {
      const match = optMatch;
      // no capture group defined
      if (match.length <= 1) {
        continue;
      }
      let filePath = match[0].replace(replaceRE, rule.filePath);
      filePath = substituteVariables(filePath, document);
      if (filePath.length === 0) { continue; }
      if (filePath === '/') {filePath = '/__root__';}
      let linkPath = filePath;
      if (!rule.isAbsolutePath) {
        const base = filePath.startsWith('/') ? filerootFolder : docFolder;
        linkPath = path.join(base, filePath.startsWith('/') ? filePath.substring(1) : filePath);
      }
      if (!rule.allowCurrentFile && linkPath === ownFilePath) {continue;}
      let filePos = match.index;
      let filePosEnd = patternRE.lastIndex;
      const fullRange = new vscode.Range(document.positionAt(filePos), document.positionAt(filePosEnd));
      // regexes matching the largest text ranges should be listed first in settings
      if (links.some(m => {
        const overlap = fullRange.intersection(m.fullRange);
        return overlap !== undefined && !overlap.isEmpty;
      })) {continue;}
      if (rule.rangeGroup) {
        const groupNr = getCaptureGroupNr(rule.rangeGroup);
        if (groupNr !== undefined && groupNr < match.length) {
          const text = match[groupNr];
          filePos += match[0].indexOf(text);
          filePosEnd = filePos + text.length;
        }
      }
      const pathRange = new vscode.Range(document.positionAt(filePos), document.positionAt(filePosEnd));
      const position: PositionInfo = {
        start: offsetToPosition(document, match.index),
        end: offsetToPosition(document, patternRE.lastIndex),
      };
      const getNumber = (expr: string | undefined): number | undefined => {
        if (!expr) {return undefined;}
        const fn = getExpressionFunction(match[0].replace(replaceRE, expr));
        return fn ? Number(fn(position)) : undefined;
      };
      const lineNr = getNumber(rule.lineNr);
      const charPos = getNumber(rule.charPos);
      let searchText = rule.searchText;
      if (searchText) {
        if (rule.searchTextIsExpression) {
          // Capture groups are spliced in via JSON.stringify so they always land as safe
          // JS string literals, not raw text that could break the expression's syntax.
          const expr = searchText.replace(/\$(\d+)/g, (_m, n) => JSON.stringify(match[Number(n)] ?? ''));
          const fn = getExpressionFunction(expr);
          searchText = fn ? String(fn(position)) : undefined;
        } else {
          searchText = match[0].replace(replaceRE, searchText);
        }
      }
      links.push({ linkPath, lineNr, charPos, searchText, pathRange, fullRange });
    }
  }
  return links.map(m => new CustomDocumentLink(m));
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

async function resolveCustomDocumentLink(link: CustomDocumentLink): Promise<vscode.DocumentLink> {
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
    return findCustomDocumentLinks(document);
  },
  resolveDocumentLink(link: vscode.DocumentLink): vscode.ProviderResult<vscode.DocumentLink> {
    return resolveCustomDocumentLink(link as CustomDocumentLink);
  },
};

let linkProviderDisposables: vscode.Disposable[] = [];

function deregisterLinkProviders() {
  linkProviderDisposables.forEach(d => d.dispose());
  linkProviderDisposables = [];
}

function registerLinkProviders(): void {
  deregisterLinkProviders();
  const rules = toRules(vscode.workspace.getConfiguration(configSection));
  if (rules.length === 0) {
    return
  }
  // A rule with languageIds: null applies to every language, so a single {
  // scheme: 'file' } selector already covers every other rule too. Registering
  // per-language selectors on top of it would make VS Code call
  // provideDocumentLinks twice for the same document (once per matching
  // selector), duplicating every link it returns.
  if (rules.some(rule => rule.languageIds === null)) {
    linkProviderDisposables.push(vscode.languages.registerDocumentLinkProvider({ scheme: 'file' }, linkProvider));
  } else {
    const languageIds = new Set<string>();
    for (const rule of rules) {
      for (const languageId of rule.languageIds ?? []) {
        languageIds.add(languageId)
      }
    }
    for (const languageId of languageIds) {
      const selector: vscode.DocumentSelector = { scheme: 'file', language: languageId };
      linkProviderDisposables.push(vscode.languages.registerDocumentLinkProvider(selector, linkProvider));
    }
  }
}

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
  deregisterLinkProviders();
}

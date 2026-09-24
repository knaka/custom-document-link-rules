import * as vscode from 'vscode';
import * as path from 'path';

const extensionName = 'Custom Document Link Rules';
const configSection = 'custom-document-link-rules';

// Rule item in the setting
interface RuleConfig {
  pattern: string;
  filePath?: string;
  isAbsolutePath?: boolean;
  lineNum?: string;
  charPos?: string;
  searchText?: string;
  linkRange?: string;
  documentLink?: boolean;
  allowCurrentFile?: boolean;
  disableInterpolation?: boolean;
  languageIds?: string[] | null;
}

// Rules in the setting. Item A plain string item is shorthand for `{ "pattern": "...", "filePath": '$1' }`
type RulesConfig = Array<string | RuleConfig>;

// Custom link rule
interface Rule {
  pattern: string;
  filePath: string;
  isAbsolutePath: boolean;
  lineNum?: string;
  charPos?: string;
  searchText?: string;
  linkRange?: string;
  documentLink: boolean;
  allowCurrentFile: boolean;
  disableInterpolation: boolean;
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

function getCaptureGroupNum(text: string): number | undefined {
  const match = text.match(/\$(\d+)/);
  return match ? Number(match[1]) : undefined;
}

function offsetToPosition(document: vscode.TextDocument, offset: number): { line: number; character: number } {
  const position = document.positionAt(offset);
  return { line: position.line + 1, character: position.character + 1 };
}

// A rule's `filePath`/`lineNum`/`charPos`/`searchText` are interpolated as the
// body of a JavaScript template literal, with `variables` in scope. `Function`
// is the only way to evaluate user-provided settings text at runtime, so it is
// skipped in untrusted workspaces. `String.raw` keeps backslashes (e.g. in
// Windows paths) as-is.
function interpolate(template: string, variables: Record<string, unknown>): string | undefined {
  if (!vscode.workspace.isTrusted) {
    return template;
  }
  let fn: (...values: unknown[]) => unknown;
  try {
    fn = Function(...Object.keys(variables), `"use strict"; return String.raw\`${template}\`;`) as typeof fn;
  } catch {
    vscode.window.showErrorMessage(`${extensionName}: incomplete template: ${template}`);
    return undefined;
  }
  try {
    return String(fn(...Object.values(variables)));
  } catch (e) {
    vscode.window.showErrorMessage(`${extensionName}: failed to interpolate template: ${template}: ${e}`);
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
      documentLink: true,
      allowCurrentFile: false,
      disableInterpolation: false,
      languageIds: null,
    };
  }
  const filePath = item.filePath ?? '$1';
  let linkRange = item.linkRange;
  if (!linkRange && !item.lineNum) {
    const groupNum = getCaptureGroupNum(filePath);
    if (groupNum !== undefined) {linkRange = `$${groupNum}`;}
  }
  return {
    pattern: item.pattern,
    filePath,
    isAbsolutePath: item.isAbsolutePath ?? false,
    lineNum: item.lineNum,
    charPos: item.charPos,
    searchText: item.searchText,
    linkRange,
    documentLink: item.documentLink ?? true,
    allowCurrentFile: item.allowCurrentFile ?? false,
    disableInterpolation: item.disableInterpolation ?? false,
    languageIds: item.languageIds ?? null,
  };
}

function toRules(config: vscode.WorkspaceConfiguration): Rule[] {
  return config.get<RulesConfig>('rules', []).map(toRule);
}

// Found link
interface MatchedLink {
  linkPath: string;
  lineNum?: number;
  charPos?: number;
  searchText?: string;
  linkRange: vscode.Range;
  fullRange: vscode.Range;
}

class CustomDocumentLink extends vscode.DocumentLink {
  linkPath: string;
  searchText?: string;
  lineNum?: number;
  charPos?: number;
  constructor(match: MatchedLink) {
    super(match.linkRange);
    this.linkPath = match.linkPath;
    this.searchText = match.searchText;
    this.lineNum = match.lineNum;
    this.charPos = match.charPos;
  }
}

// Variables available to every interpolated template in a document, in
// addition to the per-match `match` and `position`.
function documentVariables(document: vscode.TextDocument): Record<string, unknown> {
  const file = document.fileName;
  const fileDirname = path.dirname(file);
  const fileBasename = path.basename(file);
  const fileExtname = path.extname(file);
  const variables: Record<string, unknown> = {
    fileDirname,
    fileBasename,
    fileBasenameNoExtension: fileBasename.slice(0, fileBasename.length - fileExtname.length),
    fileExtname,
    env: process.env,
    workspaceFolderOf: (name: string) => getNamedWorkspaceFolder(name)?.uri.fsPath,
  };
  const documentWorkspace = vscode.workspace.getWorkspaceFolder(document.uri);
  const folders = vscode.workspace.workspaceFolders ?? [];
  const workspace = folders.length === 1 ? folders[0] : documentWorkspace;
  if (workspace) {
    const workspaceFolder = workspace.uri.fsPath;
    variables.workspaceFolder = workspaceFolder;
    variables.workspaceFolderBasename = path.basename(workspaceFolder);
    if (documentWorkspace) {
      variables.fileWorkspaceFolder = workspaceFolder;
      variables.relativeFile = file.substring(workspaceFolder.length + 1);
      variables.relativeFileDirname = fileDirname.substring(workspaceFolder.length + 1);
    }
  }
  return variables;
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
  const docVariables = documentVariables(document);
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
      const position: PositionInfo = {
        start: offsetToPosition(document, match.index),
        end: offsetToPosition(document, patternRE.lastIndex),
      };
      const variables = { ...docVariables, match, position };
      // Capture groups are substituted as `$n` first, then the result is interpolated.
      const expand = (template: string | undefined): string | undefined => {
        if (!template) {return undefined;}
        const text = match[0].replace(replaceRE, template);
        return rule.disableInterpolation ? text : interpolate(text, variables);
      };
      let filePath = expand(rule.filePath);
      if (!filePath) { continue; }
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
      if (rule.linkRange) {
        const groupNum = getCaptureGroupNum(rule.linkRange);
        if (groupNum !== undefined && groupNum < match.length) {
          const text = match[groupNum];
          filePos += match[0].indexOf(text);
          filePosEnd = filePos + text.length;
        }
      }
      const linkRange = new vscode.Range(document.positionAt(filePos), document.positionAt(filePosEnd));
      const getNumber = (template: string | undefined): number | undefined => {
        const text = expand(template);
        return text ? Number(text) : undefined;
      };
      const lineNum = getNumber(rule.lineNum);
      const charPos = getNumber(rule.charPos);
      const searchText = expand(rule.searchText);
      links.push({ linkPath, lineNum, charPos, searchText, linkRange, fullRange });
    }
  }
  return links.map(m => new CustomDocumentLink(m));
}

function locateText(document: vscode.TextDocument, text: string): [number, number] {
  let lineNum = 1;
  let charPos = 1;
  const offset = document.getText().indexOf(text);
  if (offset >= 0) {
    const position = document.positionAt(offset);
    lineNum = position.line + 1;
    charPos = position.character + 1;
  }
  return [lineNum, charPos];
}

function findOpenTextDocument(uri: vscode.Uri): vscode.TextDocument | undefined {
  return vscode.workspace.textDocuments.find(
    doc => !doc.isClosed && doc.uri.scheme === 'file' && doc.uri.fsPath === uri.fsPath
  );
}

async function resolveCustomDocumentLink(link: CustomDocumentLink): Promise<vscode.DocumentLink> {
  let uri = vscode.Uri.file(link.linkPath);
  let lineNum = link.lineNum;
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
      [lineNum, charPos] = locateText(document, link.searchText);
    } else {
      vscode.window.showInformationMessage(`${extensionName}: please open the file and try again: ${uri.fsPath}`);
    }
  }
  if (lineNum) {
    let fragment = `L${lineNum}`;
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

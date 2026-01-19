// scripts/tree.ts
// npm pkg set scripts.tree="tsx scripts/tree.ts"
// npm run tree
import * as fs from 'fs';
import * as path from 'path';
const ROOT = process.cwd();
const OUT_DIR = path.join(ROOT, 'docs');
const SKIP_DIRS = new Set(['.git', 'node_modules', '.cache', '.upm', '00_admin', 'dump']);
const SKIP_FILES = new Set(['.replit', '.DS_Store', '.gitignore', 'package-lock.json']);
function toRel(p: string, base: string): string {
  return path.relative(base, p).split(path.sep).join('/');
}
function isDir(p: string): boolean {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}
function safeReadDir(dir: string): fs.Dirent[] {
  try { return fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
}

function walk(dir: string, accAbs: string[]) {
  for (const e of safeReadDir(dir)) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      walk(full, accAbs);
      continue;
    }
    if (e.isFile() || e.isSymbolicLink()) {
      if (SKIP_FILES.has(e.name)) continue;
      accAbs.push(full);
    }
  }
}
function writeTree(srcDir: string, outFile: string, relBase: string) {
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  if (!isDir(srcDir)) {
    fs.writeFileSync(outFile, '', 'utf8');
    return;
  }
  const abs: string[] = [];
  walk(srcDir, abs);
  const rel = abs.map(p => toRel(p, relBase));
  const lines = Array.from(new Set(rel))
    .filter(p => !p.split('/').some(seg => SKIP_DIRS.has(seg)))
    .filter(p => !SKIP_FILES.has(p.split('/').pop() || ''))
    .sort();
  fs.writeFileSync(outFile, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}
type PkgJson = {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
};
function readJsonFile<T>(p: string): T | null {
  try {
    const s = fs.readFileSync(p, 'utf8');
    return JSON.parse(s) as T;
  } catch {
    return null;
  }
}
function writeDependencies(outFile: string) {
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  const pkgPath = path.join(ROOT, 'package.json');
  const pkg = readJsonFile<PkgJson>(pkgPath);
  if (!pkg) {
    fs.writeFileSync(outFile, '', 'utf8');
    return;
  }
  const deps: Record<string, string> = {
    ...(pkg.dependencies || {}),
    ...(pkg.devDependencies || {}),
    ...(pkg.peerDependencies || {}),
    ...(pkg.optionalDependencies || {}),
  };
  const lines = Object.keys(deps)
    .sort((a, b) => a.localeCompare(b))
    .map(name => `${name} ${deps[name]}`);
  fs.writeFileSync(outFile, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

// trees
writeTree(ROOT, path.join(OUT_DIR, 'tree.txt'), ROOT);
writeTree(path.join(ROOT, 'src'), path.join(OUT_DIR, 'tree-src.txt'), path.join(ROOT, 'src'));
writeTree(path.join(ROOT, 'scripts'), path.join(OUT_DIR, 'tree-scripts.txt'), path.join(ROOT, 'scripts'));
writeTree(path.join(ROOT, 'contracts'), path.join(OUT_DIR, 'tree-contracts.txt'), path.join(ROOT, 'contracts'));
writeTree(path.join(ROOT, 'artifacts'), path.join(OUT_DIR, 'tree-artifacts.txt'), path.join(ROOT, 'artifacts'));

// deps
writeDependencies(path.join(OUT_DIR, 'dependencies.txt'));

// abi extraction
function extractABIs() {
  const abiDir = path.join(ROOT, 'abi');
  const artifactsDir = path.join(ROOT, 'artifacts', 'contracts');
  fs.mkdirSync(abiDir, { recursive: true });
  
  if (!isDir(artifactsDir)) return;
  
  const artifactFiles: string[] = [];
  walk(artifactsDir, artifactFiles);
  
  for (const filePath of artifactFiles) {
    if (!filePath.endsWith('.json') || filePath.endsWith('.dbg.json')) continue;
    
    const artifact = readJsonFile<{ abi?: any }>(filePath);
    if (!artifact || !artifact.abi) continue;
    
    const contractName = path.basename(filePath, '.json');
    const abiFile = path.join(abiDir, `${contractName}.json`);
    fs.writeFileSync(abiFile, JSON.stringify(artifact.abi, null, 2), 'utf8');
  }
}

extractABIs();
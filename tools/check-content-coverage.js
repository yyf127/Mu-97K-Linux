// Verifica que la tabla de capas resuelva las rutas `Data\...` que pide el
// código, contra el árbol Content/ + System/ que trae el repo.
//
// Reimplementa Platform::ContentLayers::Candidates (alias más largo primero,
// luego entidades con `source = "..."`, luego Content y System) con la misma
// insensibilidad a mayúsculas que usa el backend Win32/SDL3 al abrir archivos.
//
// Un fallo aquí es exactamente lo que produce "file not found" en debug.log.
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const contentDir = path.join(root, 'Content');
const systemDir = path.join(root, 'System');

const lower = (s) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());
const norm = (s) => {
  let out = '';
  for (const ch of s.replace(/\\/g, '/')) {
    if (ch === '/' && (out === '' || out.endsWith('/'))) continue;
    out += ch;
  }
  return out.replace(/\/+$/, '');
};

// Índice en minúsculas de todo lo que existe bajo Content/ y System/,
// más las carpetas (para alias que apuntan a directorios).
const files = new Set();
const dirs = new Set();
(function index(dir, rel) {
  if (!fs.existsSync(dir)) return;
  dirs.add(lower(rel));
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const childRel = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) index(path.join(dir, e.name), childRel);
    else files.add(lower(childRel));
  }
})(root, '');

const exists = (rel) => files.has(lower(norm(rel))) || dirs.has(lower(norm(rel)));

// ── alias.toml ───────────────────────────────────────────────────────────────
const aliases = [];
const aliasFile = path.join(contentDir, 'alias.toml');
if (fs.existsSync(aliasFile)) {
  let section = '';
  for (const raw of fs.readFileSync(aliasFile, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('[')) { section = lower(line.slice(1, line.indexOf(']'))); continue; }
    if (section !== 'alias') continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const unquote = (t) => t.trim().replace(/^["']|["']$/g, '');
    const from = norm(unquote(line.slice(0, eq)));
    const to = norm(unquote(line.slice(eq + 1)));
    if (from && to) aliases.push([lower(from), to]);
  }
}
aliases.sort((a, b) => b[0].length - a[0].length);

// ── entidades: Content/<tipo>/.../<tipo>.toml con source = "..." ─────────────
const entities = new Map();
(function walkEntities(dir) {
  if (!fs.existsSync(dir)) return;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walkEntities(p); continue; }
    if (!e.name.toLowerCase().endsWith('.toml')) continue;
    const head = fs.readFileSync(p, 'utf8').split(/^\s*\[/m)[0];
    const m = /^\s*source\s*=\s*["']([^"']+)["']/mi.exec(head);
    if (!m) continue;
    const source = norm(m[1]);
    const target = norm(path.relative(contentDir, path.dirname(p)));
    for (const f of fs.readdirSync(path.dirname(p))) {
      if (f.toLowerCase().endsWith('.toml')) continue;
      const key = lower(`${source}/${f}`);
      if (!entities.has(key)) entities.set(key, `${target}/${f}`);
    }
  }
})(contentDir);

// ── resolución ───────────────────────────────────────────────────────────────
function candidates(input) {
  const n = norm(input);
  if (n.length < 6 || lower(n.slice(0, 5)) !== 'data/') return [];
  const inner = n.slice(5);
  const l = lower(inner);

  let aliased = entities.get(l) || '';
  if (!aliased) {
    for (const [from, to] of aliases) {
      if (l.slice(0, from.length) !== from) continue;
      if (l.length > from.length && l[from.length] !== '/') continue;
      aliased = to + inner.slice(from.length);
      break;
    }
  }
  const out = [];
  if (aliased) out.push(`Content/${aliased}`);
  out.push(`Content/${inner}`);
  out.push(`System/${inner}`);
  out.push(n);
  return out;
}

// ── rutas literales que el código pide ───────────────────────────────────────
const srcRoot = path.join(root, '..', '..', 'src');
const literals = new Set();
(function scan(dir) {
  if (!fs.existsSync(dir)) return;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { scan(p); continue; }
    if (!/\.(cpp|h)$/i.test(e.name)) continue;
    const text = fs.readFileSync(p, 'utf8')
      .replace(/\/\/[^\n]*/g, '')      // ignora rutas que solo aparecen en comentarios
      .replace(/\/\*[\s\S]*?\*\//g, '');
    for (const m of text.matchAll(/"([^"\n]*Data\\\\[^"\n]{1,46})"/g)) {
      literals.add(m[1].replace(/\\\\/g, '\\'));
    }
  }
})(srcRoot);

const realLiterals = [...literals].filter((p) => !p.includes('%') && !p.startsWith('Data2'));
let ok = 0;
const bad = [];
for (const literal of realLiterals) {
  // LocalizedDataPath("Data\\Local\\Text", ".bmd") arma la ruta en tiempo de
  // ejecución: el literal es un prefijo sin extensión.
  const variants = [literal];
  if (!/\.[A-Za-z0-9]{1,6}$/.test(literal)) variants.push(`${literal}.bmd`);
  const tried = variants.flatMap((v) => candidates(v));
  if (tried.find(exists)) ok++;
  else bad.push({ literal, tried });
}

console.log(`alias declarados         ${aliases.length}`);
console.log(`archivos de entidades    ${entities.size}`);
console.log(`rutas literales Data\\    ${realLiterals.length}`);
console.log(`  resuelven              ${ok}`);
console.log(`  NO resuelven           ${bad.length}`);
for (const b of bad) console.log(`    ${b.literal}\n        ${b.tried.join('\n        ')}`);

let aliasOk = 0;
const aliasBad = [];
for (const [from, to] of aliases) {
  if (exists(`Content/${to}`)) aliasOk++;
  else aliasBad.push(`${from} -> ${to}`);
}
console.log(`destinos de alias válidos ${aliasOk}/${aliases.length}`);
for (const a of aliasBad) console.log(`    falta: ${a}`);

process.exit(bad.length === 0 && aliasBad.length === 0 ? 0 : 1);

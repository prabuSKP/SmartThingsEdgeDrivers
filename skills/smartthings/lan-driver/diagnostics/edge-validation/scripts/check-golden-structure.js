// Golden-reference STRUCTURAL diff (infrastructure-scoped).
//
//   node check-golden-structure.js <golden-ref-driver-dir> <generated-driver-dir>
//
// Catches the "generated infrastructure drifted from the proven reference" class that single-file
// static checks cannot see — e.g. a `utils.labeled_socket_builder` whose arity/return-shape no
// longer matches how `lunchbox/rest.lua` calls it (v41), or a missing `fibaro_finder.lua` (v40).
//
// SCOPE-AWARE so it never punishes the legitimate "generate only requested device kinds" rule:
//   - it compares ONLY `src/**/*.lua` (the infrastructure modules, which are identical across
//     every scoped driver) — NOT `profiles/`, NOT mapper RULE tables, NOT which children exist.
//   - it compares each module's EXPORTED function surface (module-qualified `T.name(...)` /
//     `T.name = function(...)` / `T:name(...)`), NOT local helper functions — so a benign internal
//     refactor does not trip it.
//   - it is one-directional: the generated driver must be a SUPERSET of the reference surface
//     (every reference src file present; every reference export present with matching arity).
//     EXTRA files / exports in the generated driver are allowed.
//
// exit 0 = structurally conformant   |   exit 1 = drift found   |   exit 2 = usage/path error
const fs = require('fs');
const path = require('path');
const strip = require('./lua-strip.js');

const [refDir, genDir] = process.argv.slice(2);
if (!refDir || !genDir) { console.error('usage: check-golden-structure.js <golden-ref-dir> <generated-dir>'); process.exit(2); }
const refSrc = path.join(refDir, 'src');
const genSrc = path.join(genDir, 'src');
for (const [d, n] of [[refSrc, 'reference'], [genSrc, 'generated']]) {
  if (!fs.existsSync(d) || !fs.statSync(d).isDirectory()) { console.error(`VALIDATION ERROR: no src/ in ${n} driver: ${d}`); process.exit(2); }
}

function luaFiles(root) {
  const out = [];
  (function walk(p) {
    for (const e of fs.readdirSync(p)) {
      const fp = path.join(p, e);
      if (fs.statSync(fp).isDirectory()) walk(fp);
      else if (fp.endsWith('.lua')) out.push(path.relative(root, fp));
    }
  })(root);
  return out;
}

// name -> arity for every module-qualified function definition (the public/export surface).
function exportSurface(absPath) {
  const src = strip(fs.readFileSync(absPath, 'utf8'));
  const surface = new Map();
  const arity = (params, sep) => {
    const ps = params.split(',').map(s => s.trim()).filter(Boolean);
    return ps.length + (sep === ':' ? 1 : 0);   // ':' adds implicit self
  };
  const add = (name, n) => { if (!surface.has(name) || n > surface.get(name)) surface.set(name, n); };
  let m;
  const reFn = /function\s+([A-Za-z_]\w*)([.:])([A-Za-z_]\w*)\s*\(([\s\S]*?)\)/g;
  while ((m = reFn.exec(src)) !== null) add(m[3], arity(m[4], m[2]));
  const reAssign = /([A-Za-z_]\w*)([.:])([A-Za-z_]\w*)\s*=\s*function\s*\(([\s\S]*?)\)/g;
  while ((m = reAssign.exec(src)) !== null) add(m[3], arity(m[4], m[2]));
  return surface;
}

let issues = 0;
const refFiles = luaFiles(refSrc);

// Part 1 — every reference src/*.lua must exist in the generated driver.
const missingFiles = refFiles.filter(f => !fs.existsSync(path.join(genSrc, f)));
for (const f of missingFiles) {
  console.log(`GOLDEN: missing infrastructure module  src/${f}  (present in reference, absent in generated)`);
  issues++;
}

// Part 2 — for files present in both, the reference export surface must be covered with matching arity.
for (const f of refFiles) {
  const genPath = path.join(genSrc, f);
  if (!fs.existsSync(genPath)) continue;            // already reported as missing file
  const refSurface = exportSurface(path.join(refSrc, f));
  const genSurface = exportSurface(genPath);
  for (const [name, refArity] of refSurface) {
    if (!genSurface.has(name)) {
      console.log(`GOLDEN: src/${f}  missing export '${name}(...)' (in reference, not in generated)`);
      issues++;
    } else if (genSurface.get(name) !== refArity) {
      console.log(`GOLDEN: src/${f}  export '${name}' arity ${genSurface.get(name)} != reference ${refArity} — contract drift`);
      issues++;
    }
  }
}

console.log(issues ? `\n${issues} structural drift issue(s) vs golden reference` : `\nGolden structure OK (infrastructure matches reference)`);
process.exit(issues ? 1 : 0);

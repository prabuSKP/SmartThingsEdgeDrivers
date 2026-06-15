// Static linter for the "valid syntax, nil at runtime" family of Lua bugs:
//   (1) forward-ref      : local fn called before its declaration
//   (2) undefined-call   : bare NAME(...) where NAME is defined nowhere in the file and is not a builtin
//   (3) pcall-misuse     : `local A,... = pcall(...)` then A used as a table (A. / A: / A[)  -- A is the OK boolean
const fs = require('fs');
// Shared Lua-aware stripper. A naive regex that removes line-comments before strings mis-handles
// `--` inside a string and desyncs the rest of the file (cascade of bogus undefined-call hits).
const stripCommentsStrings = require('./lua-strip.js');

const BUILTINS = new Set(['assert','collectgarbage','dofile','error','getmetatable','ipairs','load',
  'loadstring','next','pairs','pcall','print','rawequal','rawget','rawlen','rawset','require','select',
  'setmetatable','tonumber','tostring','type','unpack','xpcall','gcinfo',
  // libraries that are sometimes called/declared bare; harmless to allow
  'os','io','math','string','table','coroutine','debug','utf8','bit32']);

let total = 0;

// Accept any mix of files and directories. The old version did `readFileSync` on each arg
// directly, so a directory arg crashed with EISDIR; walk dirs and collect .lua instead.
const path = require('path');
function walk(p, acc) {
  const st = fs.statSync(p);
  if (st.isDirectory()) { for (const e of fs.readdirSync(p)) walk(path.join(p, e), acc); }
  else if (p.endsWith('.lua')) acc.push(p);
  return acc;
}
const args = process.argv.slice(2);
if (args.length === 0) { console.error('usage: check-lua-nils.js <driver-dir | file.lua> ...'); process.exit(2); }
const files = [];
for (const a of args) {
  if (!fs.existsSync(a)) { console.error(`VALIDATION ERROR: path not found: ${a}`); process.exit(2); }
  walk(a, files);
}
if (files.length === 0) { console.error(`VALIDATION ERROR: no .lua files found under: ${args.join(', ')}`); process.exit(2); }

for (const file of files) {
  const src = stripCommentsStrings(fs.readFileSync(file, 'utf8'));
  const lines = src.split('\n');

  // ---- collect every name DEFINED in the file (locals, fn names, params, for-vars) ----
  const defined = new Set();
  const declLine = {};        // first line a name becomes a local (for forward-ref)
  const localFns = new Set();  // names declared via `local function` / `local x = function`
  const addDef = (n, i) => { if (n && !(n in declLine)) declLine[n] = i + 1; if (n) defined.add(n); };

  lines.forEach((l, i) => {
    let m;
    // local function NAME  /  local NAME = function
    if ((m = l.match(/^\s*local\s+function\s+([A-Za-z_]\w*)/))) { addDef(m[1], i); localFns.add(m[1]); }
    if ((m = l.match(/^\s*local\s+([A-Za-z_]\w*)\s*=\s*function\b/))) { addDef(m[1], i); localFns.add(m[1]); }
    // function NAME(...) / function T.NAME(...) / function T:NAME(...)
    if ((m = l.match(/\bfunction\s+([A-Za-z_][\w.:]*)\s*\(/))) addDef(m[1].split(/[.:]/).pop(), i);
    // local a, b, c (= ...)
    if ((m = l.match(/^\s*local\s+([A-Za-z_]\w*(\s*,\s*[A-Za-z_]\w*)*)/))) {
      m[1].split(',').forEach(s => addDef(s.trim(), i));
    }
    // function parameters (any function definition on this line)
    let pm = l.match(/\bfunction\b[^(]*\(([^)]*)\)/);
    if (pm) pm[1].split(',').forEach(p => { p = p.trim().replace(/\.\.\./, ''); if (p) addDef(p, i); });
    // for VAR / for V1, V2 in
    if ((m = l.match(/\bfor\s+([A-Za-z_]\w*(\s*,\s*[A-Za-z_]\w*)*)/))) {
      m[1].split(',').forEach(s => addDef(s.trim(), i));
    }
  });

  // collect names of called identifiers, with positions
  const callRe = /(^|[^.:\w])([A-Za-z_]\w*)\s*\(/g;
  lines.forEach((l, i) => {
    let m;
    while ((m = callRe.exec(l)) !== null) {
      const name = m[2];
      // (1) forward-ref: a local fn called before its declaration line
      if (localFns.has(name) && declLine[name] && (i + 1) < declLine[name]) {
        // skip the decl line itself
        if (!(/^\s*local\s+(function\s+)?/.test(l) && l.includes(name + ' '))) {
          console.log(`${file}:${i+1}  FORWARD-REF: '${name}()' called before its declaration at line ${declLine[name]}`);
          total++;
        }
      }
      // (2) undefined-call: bare call, name defined nowhere, not a builtin, not a Lua keyword
      else if (!defined.has(name) && !BUILTINS.has(name) &&
               !['and','or','not','if','then','else','elseif','end','do','while','return','function','local','for','in','repeat','until','break','nil','true','false','goto'].includes(name)) {
        console.log(`${file}:${i+1}  UNDEFINED-CALL: '${name}()' is defined nowhere in this file and is not a builtin (nil at runtime)`);
        total++;
      }
    }
  });

  // (3) pcall-misuse: first var of `local A,.. = pcall(` later indexed
  lines.forEach((l, i) => {
    const m = l.match(/^\s*local\s+([A-Za-z_]\w*)\s*(?:,[^=]*)?=\s*pcall\s*\(/);
    if (m) {
      const a = m[1];
      const useRe = new RegExp('(^|[^.:\\w])' + a + '\\s*[.:\\[]');
      for (let j = i + 1; j < lines.length; j++) {
        if (useRe.test(lines[j])) {
          console.log(`${file}:${j+1}  PCALL-MISUSE: '${a}' holds pcall's OK boolean but is indexed/called as a table (declared at line ${i+1})`);
          total++;
          break;
        }
      }
    }
  });
}
console.log(total ? `\n${total} issue(s) found` : `\nclean`);
process.exit(total ? 1 : 0);

// Lua-aware comment/string stripper shared by the validation scripts.
//
// Replaces every string literal with `""` and removes every comment, while PRESERVING line
// numbers (internal newlines are kept). Correctly handles the cases a naive regex gets wrong:
//   - `--` INSIDE a string  (e.g. " -- mDNS pending")  → NOT treated as a comment
//   - long-bracket strings/comments  [[ ]] / [=[ ]=] / --[[ ]]
//   - escapes inside quoted strings
// A regex stripper that removes line-comments before strings desyncs quote-pairing for the
// rest of the file and produces a cascade of bogus "undefined call" hits — this avoids that.
//
// Usage as a module:  const strip = require('./lua-strip.js');
//                     strip(src)                  → remove comments AND blank out strings ("")
//                     strip(src, {keepStrings:true}) → remove comments only, keep string bodies
// Usage as a CLI:      node lua-strip.js [--keep-strings] file1.lua file2.lua
//
// `keepStrings` matters for the banned-pattern scan: a hardcoded IP is a STRING literal
// ("192.168.1.50"), so blanking strings would hide it (false negative); but comments must
// still be removed so an IP MENTIONED in a comment is not a false positive.

function strip(raw, opts) {
  const keepStrings = !!(opts && opts.keepStrings);
  let out = '';
  let i = 0;
  const n = raw.length;
  const longBracket = (s) => { const m = /^\[(=*)\[/.exec(s); return m ? m[0].length : 0; };
  const skipLong = (start, openLen) => {
    const eq = openLen - 2;            // number of '=' between brackets
    const close = ']' + '='.repeat(eq) + ']';
    const end = raw.indexOf(close, start + openLen);
    return end === -1 ? n : end + close.length;
  };
  while (i < n) {
    const c = raw[i], c2 = raw[i + 1];
    // comment (always removed)
    if (c === '-' && c2 === '-') {
      const ol = longBracket(raw.slice(i + 2));
      if (ol) {                         // --[[ long comment ]]
        const stop = skipLong(i + 2, ol);
        for (let k = i; k < stop; k++) if (raw[k] === '\n') out += '\n';
        i = stop; continue;
      }
      while (i < n && raw[i] !== '\n') i++;   // -- line comment to EOL
      continue;
    }
    // long-bracket string
    if (c === '[') {
      const ol = longBracket(raw.slice(i));
      if (ol) {
        const stop = skipLong(i, ol);
        out += keepStrings ? raw.slice(i, stop) : '""';
        if (!keepStrings) for (let k = i; k < stop; k++) if (raw[k] === '\n') out += '\n';
        i = stop; continue;
      }
    }
    // quoted string
    if (c === '"' || c === "'") {
      const start = i;
      const q = c; i++;
      while (i < n && raw[i] !== q) {
        if (raw[i] === '\\') { i += 2; continue; }
        if (raw[i] === '\n' && !keepStrings) out += '\n';
        i++;
      }
      i++;                              // closing quote
      out += keepStrings ? raw.slice(start, i) : '""';
      continue;
    }
    out += c; i++;
  }
  return out;
}

module.exports = strip;

if (require.main === module) {
  const fs = require('fs');
  const args = process.argv.slice(2);
  const keepStrings = args.includes('--keep-strings');
  for (const f of args) {
    if (f === '--keep-strings') continue;
    process.stdout.write(strip(fs.readFileSync(f, 'utf8'), { keepStrings }));
  }
}

// Validates SmartThings Edge Driver construction in init.lua. Catches the "fabricated
// Driver API" class (valid syntax, fails at load on the hub):
//   - <drv>.open/.new/.init/.create(...) on the require"st.driver" value (no such method)
//   - construction not via the Driver("<name>", { ... }) constructor
//   - `discovery = { ... }` (must be a function)
//   - fabricated top-level option keys
const fs = require('fs');
const FABRICATED = new Set(['driver_init','device_lifecycle','on_install',
  'preference_change_handler','disconnected_handler','init_handler','poll','handler']);

let total = 0;
for (const file of process.argv.slice(2)) {
  if (!/init\.lua$/.test(file)) continue;
  const raw = fs.readFileSync(file, 'utf8');
  const rawLines = raw.split('\n');
  const lines = raw.replace(/--\[\[[\s\S]*?\]\]/g,' ').replace(/--.*$/gm,' ')
                   .replace(/"(\\.|[^"\\])*"/g,'""').replace(/'(\\.|[^'\\])*'/g,"''").split('\n');

  // 1. local bound to require "st.driver"
  let drvName = null;
  rawLines.forEach(l=>{ const m=l.match(/^\s*local\s+([A-Za-z_]\w*)\s*=\s*require\s*\(?\s*["']st\.driver["']/);
    if(m) drvName=m[1]; });
  if(!drvName){ console.log(`${file}  DRIVER-API: no \`local X = require "st.driver"\` — cannot construct a Driver`); total++; continue; }

  // 2. forbidden constructor-ish methods on the module
  const badMethod = new RegExp('\\b'+drvName+'\\.(open|new|init|create)\\s*\\(');
  lines.forEach((l,i)=>{ const m=l.match(badMethod);
    if(m){ console.log(`${file}:${i+1}  DRIVER-API: \`${drvName}.${m[1]}(...)\` does not exist — use \`${drvName}("<name>", { ... })\``); total++; }});

  // 3. require the real constructor form  X("...", {
  const ctor = new RegExp('\\b'+drvName+'\\s*\\(\\s*""\\s*,\\s*\\{');
  if(!lines.some(l=>ctor.test(l))){
    console.log(`${file}  DRIVER-API: no \`${drvName}("<name>", { ... })\` constructor call`); total++; }

  // 4. discovery must be a function, not a table
  lines.forEach((l,i)=>{ if(/^\s*discovery\s*=\s*\{/.test(l)){
    console.log(`${file}:${i+1}  DRIVER-API: \`discovery = { ... }\` — discovery must be a FUNCTION, not a table`); total++; }});

  // 5. fabricated option keys
  lines.forEach((l,i)=>{ const m=l.match(/^\s*([A-Za-z_]\w*)\s*=\s*(function|\{)/);
    const key=m&&m[1];
    if(key && FABRICATED.has(key)){
      console.log(`${file}:${i+1}  DRIVER-API: \`${key} = ...\` is not a supported Driver option (fabricated API)`); total++; }});
}
console.log(total ? `\n${total} Driver-API issue(s)` : `\nDriver construction OK`);
process.exit(total ? 1 : 0);

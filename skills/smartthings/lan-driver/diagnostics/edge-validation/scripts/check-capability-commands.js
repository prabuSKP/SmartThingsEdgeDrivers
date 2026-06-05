// Flags capability COMMAND names that don't exist on the standard SmartThings capability.
// e.g. `capabilities.windowShadeLevel.commands.setLevel.NAME` — the real command is setShadeLevel,
// so `.setLevel` is nil and `.NAME` crashes at MODULE LOAD (valid syntax; luac/compile passes).
// Only KNOWN capabilities (below) are checked; unknown ones are skipped (no false positives).
const fs = require('fs');

// capability -> set of valid command names (standard ST). Conservative: actuators we are sure of.
const CMDS = {
  switch: ['on','off'],
  switchLevel: ['setLevel'],
  windowShade: ['open','close','pause'],
  windowShadeLevel: ['setShadeLevel'],
  windowShadePreset: ['presetPosition'],
  colorControl: ['setColor','setHue','setSaturation'],
  colorTemperature: ['setColorTemperature'],
  lock: ['lock','unlock'],
  valve: ['open','close'],
  doorControl: ['open','close'],
  fanSpeed: ['setFanSpeed'],
  thermostatCoolingSetpoint: ['setCoolingSetpoint'],
  thermostatHeatingSetpoint: ['setHeatingSetpoint'],
  thermostatMode: ['setThermostatMode'],
  thermostatFanMode: ['setThermostatFanMode'],
  airConditionerMode: ['setAirConditionerMode'],
  refresh: ['refresh'],
  momentary: ['push'],
  audioVolume: ['setVolume','volumeUp','volumeDown'],
  audioMute: ['setMute','mute','unmute'],
  mediaPlayback: ['play','pause','stop','fastForward','rewind','setPlaybackStatus'],
  alarm: ['off','siren','strobe','both'],
};

let total = 0;
for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file,'utf8');
  const lines = src.replace(/--\[\[[\s\S]*?\]\]/g,' ').replace(/--.*$/gm,' ').split('\n');
  const re = /\bcapabilities\.([A-Za-z]\w*)\.commands\.([A-Za-z]\w*)/g;
  lines.forEach((l,i)=>{
    let m;
    while ((m = re.exec(l)) !== null) {
      const cap = m[1], cmd = m[2];
      if (CMDS[cap] && !CMDS[cap].includes(cmd)) {
        console.log(`${file}:${i+1}  CAP-CMD: '${cap}' has no command '${cmd}' — valid: ${CMDS[cap].join(', ')} (nil-index crash at load)`);
        total++;
      }
    }
  });
}
console.log(total ? `\n${total} bad capability command(s)` : `\ncapability commands OK`);
process.exit(total ? 1 : 0);

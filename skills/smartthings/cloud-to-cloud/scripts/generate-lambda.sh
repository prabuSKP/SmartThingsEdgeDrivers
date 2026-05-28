#!/usr/bin/env bash
# generate-lambda.sh — Generate SmartThings Schema Lambda boilerplate
# Usage: bash scripts/generate-lambda.sh --type <device-type> [options]

set -euo pipefail

show_help() {
  cat <<EOF
Generate a complete SmartThings Schema Lambda function for any device type.

Usage: bash $0 --type <device-type> [options]

Required:
  --type TYPE        Device type: switch | dimmer | color-bulb | color-temp-bulb
                     | motion-sensor | contact-sensor | lock | thermostat
                     | outlet | fan | window-cover

Options:
  --name NAME        Device display name (default: "Smart Device")
  --manufacturer MFG Manufacturer name (default: "Your Company")
  --model MODEL      Model name (default: "Model X")
  --region REGION    AWS region for Lambda ARN note (default: us-east-1)
  --output DIR       Output directory (default: ./my-schema-lambda)
  --no-install       Skip npm install in output directory
  -h, --help         Show this help

Examples:
  bash $0 --type switch --name "Smart Plug" --manufacturer "Acme"
  bash $0 --type color-temp-bulb --name "Tunable Light" --output ./bulb-lambda
  bash $0 --type thermostat --name "Smart Thermostat"
EOF
  exit 0
}

# Parse args
TYPE=""
DEVICE_NAME="Smart Device"
MANUFACTURER="Your Company"
MODEL="Model X"
REGION="us-east-1"
OUTPUT="./my-schema-lambda"
NO_INSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --name) DEVICE_NAME="$2"; shift 2 ;;
    --manufacturer) MANUFACTURER="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --no-install) NO_INSTALL=true; shift ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
done

if [[ -z "$TYPE" ]]; then
  echo "Error: --type is required"
  show_help
fi

# Determine profile ID and capabilities based on type
# Using $'...' for multi-line strings with real newlines
case "$TYPE" in
  switch)
    PROFILE="c2c-switch"
    CAP_IMPORTS='"st.switch", "on", "off"'
    HANDLE_SWITCH=$'          case "st.switch":\n            main.addState("st.switch", "switch", cmd.command);\n            break;'
    ;;
  dimmer|outlet)
    PROFILE="c2c-dimmable-light"
    CAP_IMPORTS='"st.switch", "on", "off", "st.switchLevel", "setLevel"'
    HANDLE_SWITCH=$'          case "st.switch":\n            main.addState("st.switch", "switch", cmd.command);\n            break;\n          case "st.switchLevel":\n            main.addState("st.switchLevel", "level", cmd.arguments[0]);\n            break;'
    ;;
  color-bulb)
    PROFILE="c2c-color-bulb"
    CAP_IMPORTS='"st.switch", "on", "off", "st.switchLevel", "setLevel", "st.colorControl", "setColor", "st.colorTemperature", "setColorTemperature"'
    HANDLE_SWITCH=$'          case "st.switch":\n            main.addState("st.switch", "switch", cmd.command);\n            break;\n          case "st.switchLevel":\n            main.addState("st.switchLevel", "level", cmd.arguments[0]);\n            break;\n          case "st.colorControl":\n            main.addState("st.colorControl", "hue", cmd.arguments[0].hue);\n            main.addState("st.colorControl", "saturation", cmd.arguments[0].saturation);\n            break;\n          case "st.colorTemperature":\n            main.addState("st.colorTemperature", "colorTemperature", cmd.arguments[0]);\n            break;'
    ;;
  color-temp-bulb)
    PROFILE="c2c-color-temperature-bulb"
    CAP_IMPORTS='"st.switch", "on", "off", "st.switchLevel", "setLevel", "st.colorTemperature", "setColorTemperature"'
    HANDLE_SWITCH=$'          case "st.switch":\n            main.addState("st.switch", "switch", cmd.command);\n            break;\n          case "st.switchLevel":\n            main.addState("st.switchLevel", "level", cmd.arguments[0]);\n            break;\n          case "st.colorTemperature":\n            main.addState("st.colorTemperature", "colorTemperature", cmd.arguments[0]);\n            break;'
    ;;
  motion-sensor)
    PROFILE="c2c-motion-sensor"
    CAP_IMPORTS='"st.motionSensor", "st.battery", "st.temperatureMeasurement"'
    HANDLE_SWITCH='          // Sensor — no commands, just return current state via stateRefresh'
    ;;
  contact-sensor)
    PROFILE="c2c-contact-sensor"
    CAP_IMPORTS='"st.contactSensor", "st.battery", "st.temperatureMeasurement"'
    HANDLE_SWITCH='          // Sensor — no commands, just return current state via stateRefresh'
    ;;
  lock)
    PROFILE="c2c-lock"
    CAP_IMPORTS='"st.lock", "lock", "unlock"'
    HANDLE_SWITCH=$'          case "st.lock":\n            main.addState("st.lock", "lock", cmd.command);\n            break;'
    ;;
  thermostat)
    PROFILE="c2c-thermostat"
    CAP_IMPORTS='"st.thermostat", "setCoolingSetpoint", "setHeatingSetpoint", "st.thermostatMode", "st.thermostatFanMode"'
    HANDLE_SWITCH=$'          case "st.thermostat":\n            if (cmd.command === "setCoolingSetpoint")\n              main.addState("st.thermostat", "coolingSetpoint", cmd.arguments[0]);\n            else if (cmd.command === "setHeatingSetpoint")\n              main.addState("st.thermostat", "heatingSetpoint", cmd.arguments[0]);\n            else if (cmd.command === "setThermostatMode")\n              main.addState("st.thermostat", "thermostatMode", cmd.command);\n            break;\n          case "st.thermostatMode":\n            main.addState("st.thermostatMode", "thermostatMode", cmd.command);\n            break;\n          case "st.thermostatFanMode":\n            main.addState("st.thermostatFanMode", "thermostatFanMode", cmd.command);\n            break;'
    ;;
  fan)
    PROFILE="c2c-dimmable-light"
    CAP_IMPORTS='"st.switch", "on", "off", "st.switchLevel", "setLevel"'
    HANDLE_SWITCH=$'          case "st.switch":\n            main.addState("st.switch", "switch", cmd.command);\n            break;\n          case "st.switchLevel":\n            main.addState("st.switchLevel", "level", cmd.arguments[0]);\n            break;'
    ;;
  window-cover)
    PROFILE="c2c-window-shade"
    CAP_IMPORTS='"st.windowShade", "open", "close", "pause", "st.switchLevel", "setLevel"'
    HANDLE_SWITCH=$'          case "st.windowShade":\n            main.addState("st.windowShade", "windowShade", cmd.command);\n            break;\n          case "st.switchLevel":\n            main.addState("st.switchLevel", "level", cmd.arguments[0]);\n            break;'
    ;;
  *)
    echo "Error: Unknown device type '$TYPE'"
    echo "Supported: switch, dimmer, color-bulb, color-temp-bulb, motion-sensor, contact-sensor, lock, thermostat, outlet, fan, window-cover"
    exit 1
    ;;
esac

mkdir -p "$OUTPUT"

# Write package.json
cat > "$OUTPUT/package.json" <<PKGEOF
{
  "name": "smartthings-schema-${TYPE}",
  "version": "1.0.0",
  "description": "${TYPE} Integration - SmartThings Schema Lambda",
  "main": "index.js",
  "dependencies": {
    "st-schema": "^1.9.0"
  }
}
PKGEOF

# Write index.js
cat > "$OUTPUT/index.js" <<LAMBDA
'use strict';

const { SchemaConnector } = require('st-schema');

// -- Constants (set these from environment variables in production) --
const MFG = process.env.MANUFACTURER || '${MANUFACTURER}';
const MODEL_NAME = process.env.MODEL_NAME || '${MODEL}';

// Device profile ID
const DEVICE_PROFILE = '${PROFILE}';

const connector = new SchemaConnector()
  .enableEventLogging(2)

  /**
   * Discovery Handler
   * Return the list of devices for this user.
   * Query your device cloud API to get actual devices.
   */
  .discoveryHandler(async (accessToken, response) => {
    // TODO: Query your cloud API using accessToken to get user's devices
    response.addDevice(
      'device-id-1',
      '${DEVICE_NAME}',
      DEVICE_PROFILE
    )
      .manufacturerName(MFG)
      .modelName(MODEL_NAME)
      .hwVersion('1.0')
      .swVersion('1.0.0')
      .roomName('Living Room')
      .addGroup('My Devices');
  })

  /**
   * State Refresh Handler
   * Return current state for requested devices.
   */
  .stateRefreshHandler(async (accessToken, response, devices) => {
    // TODO: Query your cloud API for live device states
    for (const device of devices) {
      const d = response.addDevice(device.externalDeviceId);
      const main = d.addComponent('main');
      main.addState('st.healthCheck', 'healthStatus', 'online');
      // TODO: Add actual device states
    }
  })

  /**
   * Command Handler
   * Execute commands and return updated device state.
   */
  .commandHandler(async (accessToken, response, devices) => {
    for (const device of devices) {
      const d = response.addDevice(device.externalDeviceId);
      const main = d.addComponent('main');

      // TODO: Send commands to your device cloud API
      for (const cmd of device.commands) {
        switch (cmd.capability) {
${HANDLE_SWITCH}
          default:
            console.warn('Unknown capability:', cmd.capability);
        }
      }

      // Always include healthCheck
      main.addState('st.healthCheck', 'healthStatus', 'online');
    }
  })

  /**
   * Callback Access Handler
   * Store SmartThings callback tokens for proactive state updates.
   */
  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    // TODO: Store callbackAuthentication and callbackUrls securely
    // Use these to send proactive state updates via callbacks
    console.log('Callback URLs received:', JSON.stringify(callbackUrls));
  })

  /**
   * Integration Deleted Handler
   * Clean up when a user removes your integration.
   */
  .integrationDeletedHandler(async (accessToken) => {
    // TODO: Revoke tokens, clean up user data
    console.log('Integration deleted for token:', accessToken);
  });

/**
 * AWS Lambda entry point
 */
exports.handler = async (event, context) => {
  await connector.handleLambdaCallback(event, context);
};
LAMBDA

# Write .env template
cat > "$OUTPUT/.env.example" <<ENV
MANUFACTURER=${MANUFACTURER}
MODEL_NAME=${MODEL}

# AWS deployment
# LAMBDA_ARN=arn:aws:lambda:${REGION}:your-account:function:your-function
ENV

# Write README
cat > "$OUTPUT/README.md" <<README
# SmartThings Schema — ${TYPE} Integration

Generated by smartthings-c2c-devkit.

## Setup

1. \`\`\`bash
   cd $(basename $OUTPUT)
   npm install
   \`\`\`

2. Deploy to AWS Lambda (${REGION}):
   - Create a new Node.js 20.x Lambda function
   - Upload as ZIP
   - Set timeout ≥ 10 seconds
   - Grant SmartThings invoke permission:
     \`\`\`bash
     aws lambda add-permission \\
       --function-name your-function-name \\
       --statement-id smartthings-schema \\
       --action lambda:InvokeFunction \\
       --principal 904769647579
     \`\`\`

3. Register Schema App:
   \`\`\`bash
   smartthings schema:create
   \`\`\`

4. Device profile: ${PROFILE}

## Next Steps

1. Implement discoveryHandler — query your cloud API
2. Implement stateRefreshHandler — return live states
3. Implement commandHandler — send commands to devices
4. Implement callbackAccessHandler — store tokens for proactive callbacks
5. Test with SmartThings Test Suite before certification
README

# Install npm packages
if [[ "$NO_INSTALL" == "false" ]]; then
  echo "Installing npm dependencies in $OUTPUT..."
  (cd "$OUTPUT" && npm install 2>/dev/null) || echo "Warning: npm install failed. Run 'cd $OUTPUT && npm install' manually."
fi

echo ""
echo "✅ Generated Lambda for device type: $TYPE"
echo "   Profile: $PROFILE"
echo "   Output: $OUTPUT"
echo ""
echo "📋 Next steps:"
echo "   1. cd $OUTPUT"
echo "   2. Edit index.js — implement your cloud API calls"
echo "   3. Deploy to AWS Lambda"
echo "   4. Register Schema App via SmartThings CLI"
echo "   5. Test with SmartThings Test Suite"

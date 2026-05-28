# Schema App — Lambda Implementation

## Overview

A Schema App is your Lambda/webhook endpoint that handles SmartThings Schema interaction types. It receives JSON payloads from SmartThings and responds with device data.

## Deployment (AWS Lambda)

### Supported Regions
Deploy your Lambda in at least one of these regions:
- `us-east-1` (N. Virginia)
- `us-west-2` (Oregon)
- `eu-west-1` (Ireland)
- `ap-northeast-1` (Tokyo)
- `ap-southeast-1` (Singapore)

For better latency, deploy in a region geographically closer to your users.

### Steps

1. **Create Lambda**: Author from scratch, Node.js 18+ or 20.x runtime
2. **Add st-schema dependency**: Bundle `st-schema` npm package with your code
3. **Enable function URL** (optional, for testing) or use API Gateway
4. **Note the ARN**: Format: `arn:aws:lambda:region:account-id:function:function-name`
5. **Grant SmartThings invoke permission**:
   ```bash
   aws lambda add-permission \
     --function-name YOUR_FUNCTION_NAME \
     --statement-id smartthings-schema \
     --action lambda:InvokeFunction \
     --principal 904769647579
   ```
   The principal `904769647579` is the SmartThings AWS account.

## st-schema Library

The `st-schema` Node.js library provides a `SchemaConnector` class that handles request parsing and response formatting.

```bash
npm install st-schema
```

### Connector Handlers

| Handler | Purpose |
|---|---|
| `discoveryHandler` | Return list of devices when SmartThings requests discovery |
| `stateRefreshHandler` | Return current state for requested devices |
| `commandHandler` | Execute commands and return updated state |
| `callbackAccessHandler` | Receive/store SmartThings callback tokens |
| `integrationDeletedHandler` | Cleanup when user deletes integration |

### Lambda Handler Template

```javascript
const { SchemaConnector } = require('st-schema');

const connector = new SchemaConnector()
  .enableEventLogging(2)
  .discoveryHandler(async (accessToken, response) => {
    // accessToken = OAuth token from your auth server
    // Query your device cloud API to list the user's devices
    // For each device:
    response.addDevice(
      'external-device-id',     // unique ID on your cloud
      'Friendly Name',          // display name in SmartThings app
      'c2c-device-profile-id'   // device profile ID from SmartThings
    )
      .manufacturerName('Your Company')
      .modelName('Model XYZ')
      .hwVersion('1.0')
      .swVersion('1.0.0')
      .roomName('Living Room')
      .addGroup('Group Name');
  })
  .stateRefreshHandler(async (accessToken, response, devices) => {
    // devices = array of { externalDeviceId, deviceCookie }
    for (const device of devices) {
      const d = response.addDevice(device.externalDeviceId);
      const main = d.addComponent('main');
      // Add states for each capability:
      main.addState('st.switch', 'switch', 'on');
      main.addState('st.switchLevel', 'level', 80);
      main.addState('st.healthCheck', 'healthStatus', 'online');
    }
  })
  .commandHandler(async (accessToken, response, devices) => {
    for (const device of devices) {
      const d = response.addDevice(device.externalDeviceId);
      const main = d.addComponent('main');
      for (const cmd of device.commands) {
        // Execute command against your device cloud API
        // Then reflect the resulting state:
        switch (cmd.capability) {
          case 'st.switch':
            main.addState('st.switch', 'switch', cmd.command);
            break;
          case 'st.switchLevel':
            main.addState('st.switchLevel', 'level', cmd.arguments[0]);
            break;
        }
      }
      main.addState('st.healthCheck', 'healthStatus', 'online');
    }
  })
  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    // Store callbackUrls.tokenUrl and callbackAuthentication for proactive state updates
  })
  .integrationDeletedHandler(async (accessToken) => {
    // Cleanup: remove user data, revoke tokens, etc.
  });

exports.handler = async (event, context) => {
  await connector.handleLambdaCallback(event, context);
};
```

## Registering the Schema App

Use the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli):

```bash
# Create schema app
smartthings schema:create

# Provide these details:
# - Display name
# - Icon URL (optional)
# - Lambda ARN (one per region)
# - OAuth client ID & scopes
# - Endpoint App URL (if not using Lambda)
```

### Required OAuth Scopes
- `r:devices:*` — Read device info
- `x:devices:*` — Execute device commands

## Testing

1. Use the schema endpoint URL to test with curl/Postman
2. Check Lambda CloudWatch logs for errors
3. SmartThings will log `interactionResult` for any issues found in responses
4. Use the [SmartThings Test Suite](https://developer.smartthings.com/console/test) for comprehensive testing

## Common Issues

| Issue | Fix |
|---|---|
| Lambda timeout | Increase timeout to at least 10s (30s recommended) |
| Access denied | Verify Lambda permission for principal 904769647579 |
| Schema not appearing | May need `--organization [orgUUID]` flag |
| Invalid response format | Use st-schema library to ensure correct JSON structure |

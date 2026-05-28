# Interaction Types Reference

All SmartThings Schema payloads use: `"schema": "st-schema"`, `"version": "1.0"`

## Mandatory Interactions (Required for Certification)

### 1. Discovery

SmartThings requests a list of the user's devices. Automatic polling ~every 24h.

**Request:**
```json
{
  "headers": {
    "schema": "st-schema",
    "version": "1.0",
    "interactionType": "discoveryRequest",
    "requestId": "uuid-here"
  },
  "authentication": {
    "tokenType": "Bearer",
    "token": "oauth-token-from-your-server"
  }
}
```

**Response:**
```json
{
  "headers": {
    "schema": "st-schema",
    "version": "1.0",
    "interactionType": "discoveryResponse",
    "requestId": "uuid-here"
  },
  "authentication": {
    "tokenType": "Bearer",
    "token": "oauth-token-from-your-server"
  },
  "devices": [
    {
      "externalDeviceId": "partner-device-id-1",
      "friendlyName": "Kitchen Light",
      "deviceContext": [
        { "key": "manufacturerName", "value": "Your Company" },
        { "key": "modelName", "value": "Model A" },
        { "key": "hwVersion", "value": "v1.0" },
        { "key": "swVersion", "value": "1.0.0" },
        { "key": "roomName", "value": "Kitchen" },
        { "key": "deviceProfileId", "value": "c2c-device-profile-id" }
      ],
      "deviceCookie": { "key": "value" },
      "groups": ["Kitchen Table Lights"]
    }
  ]
}
```

### 2. State Refresh

SmartThings requests current states for specific devices.

**Request:**
```json
{
  "headers": {
    "schema": "st-schema",
    "version": "1.0",
    "interactionType": "stateRefreshRequest",
    "requestId": "uuid-here"
  },
  "authentication": {
    "tokenType": "Bearer",
    "token": "oauth-token"
  },
  "devices": [
    { "externalDeviceId": "partner-device-id-1" },
    { "externalDeviceId": "partner-device-id-2" }
  ]
}
```

**Response (per device):**
```json
{
  "headers": { "...": "..." },
  "authentication": { "...": "..." },
  "devices": [
    {
      "externalDeviceId": "partner-device-id-1",
      "deviceCookie": {},
      "states": [
        {
          "component": "main",
          "capability": "st.switch",
          "attribute": "switch",
          "value": "on"
        },
        {
          "component": "main",
          "capability": "st.healthCheck",
          "attribute": "healthStatus",
          "value": "online"
        }
      ]
    }
  ]
}
```

**⚠️ Important:** Always include `st.healthCheck` (value: `"online"` or `"offline"`). If device is deleted, respond with `DEVICE-DELETED` error.

### 3. Command

SmartThings sends a command to execute on a device.

**Request:**
```json
{
  "headers": {
    "schema": "st-schema",
    "version": "1.0",
    "interactionType": "commandRequest",
    "requestId": "uuid-here"
  },
  "authentication": { "tokenType": "Bearer", "token": "oauth-token" },
  "devices": [
    {
      "externalDeviceId": "partner-device-id-1",
      "deviceCookie": {},
      "commands": [
        {
          "component": "main",
          "capability": "st.switch",
          "command": "on",
          "arguments": []
        },
        {
          "component": "main",
          "capability": "st.switchLevel",
          "command": "setLevel",
          "arguments": [80]
        },
        {
          "component": "main",
          "capability": "st.colorControl",
          "command": "setColor",
          "arguments": [{ "hue": 0.83, "saturation": 91 }]
        },
        {
          "component": "main",
          "capability": "st.colorTemperature",
          "command": "setColorTemperature",
          "arguments": [3000]
        }
      ]
    }
  ]
}
```

**Response:** Same format as State Refresh — return **all** updated states including `st.healthCheck`.

**Error Response (Device):**
```json
{
  "headers": { "...": "..." },
  "devices": [
    {
      "externalDeviceId": "partner-device-id-1",
      "states": [],
      "deviceError": { "errorType": "DEVICE-DELETED" }
    }
  ]
}
```

**Error Types:**
- `DEVICE-DELETED` — device no longer exists
- `DEVICE-OFFLINE` — device unreachable
- `DEVICE-POWER-OFF` — device powered off
- `DEVICE-PROTECTION` — device in protected state
- `DEVICE-UNKNOWN-ERROR` — generic error
- `RATE-LIMIT-EXCEEDED` — throttling

**Global Error Response:**
```json
{
  "headers": { "...": "..." },
  "devices": [],
  "globalError": { "errorType": "INTERNAL-ERROR" }
}
```

### 4. Callback — Reciprocal Access Token

For proactive state updates from your cloud to SmartThings.

**grantCallbackAccess (from SmartThings):**
```json
{
  "headers": {
    "interactionType": "grantCallbackAccess",
    "requestId": "uuid-here"
  },
  "authentication": {
    "tokenType": "Bearer",
    "token": "oauth-token-from-your-server"
  },
  "callbackAuthentication": {
    "tokenType": "Bearer",
    "token": "smartthings-provided-token"
  },
  "callbackUrls": {
    "tokenUrl": "https://api.smartthings.com/oauth/token",
    "stateCallbackUrl": "https://api.smartthings.com/device/state",
    "discoveryCallbackUrl": "https://api.smartthings.com/device/discovery"
  }
}
```

Your response should store these tokens and URLs for later use.

**accessTokenRequest (from your cloud to SmartThings — to refresh):**
Send a POST to `callbackUrls.tokenUrl` with:
```json
{
  "headers": {
    "interactionType": "accessTokenRequest",
    "requestId": "your-uuid"
  },
  "callbackAuthentication": { "tokenType": "Bearer", "token": "smartthings-callback-token" }
}
```

**Response (accessTokenResponse):**
```json
{
  "headers": {
    "interactionType": "accessTokenResponse",
    "requestId": "your-uuid"
  },
  "callbackAuthentication": {
    "tokenType": "Bearer",
    "token": "new-smartthings-access-token",
    "expiresIn": 3600
  }
}
```

### 5. Device State Callback

Proactively push a state change to SmartThings (e.g., sensor triggered).

```
POST to callbackUrls.stateCallbackUrl
```

```json
{
  "headers": {
    "schema": "st-schema",
    "version": "1.0",
    "interactionType": "stateCallback",
    "requestId": "your-uuid"
  },
  "authentication": { "tokenType": "Bearer", "token": "smartthings-access-token" },
  "devices": [
    {
      "externalDeviceId": "partner-device-id-1",
      "states": [
        {
          "component": "main",
          "capability": "st.motionSensor",
          "attribute": "motion",
          "value": "active"
        }
      ]
    }
  ]
}
```

### 6. Discovery Callback

Trigger an on-demand discovery from your cloud (useful when a new device is added on your end).

```
POST to callbackUrls.discoveryCallbackUrl
```

```json
{
  "headers": {
    "interactionType": "discoveryCallback",
    "requestId": "your-uuid"
  },
  "callbackAuthentication": {
    "tokenType": "Bearer",
    "token": "smartthings-callback-token"
  }
}
```

### 7. Integration Deleted

SmartThings notifies that a user has removed your integration.

```json
{
  "headers": {
    "schema": "st-schema",
    "version": "1.0",
    "interactionType": "integrationDeleted",
    "requestId": "uuid-here"
  },
  "authentication": { "tokenType": "Bearer", "token": "oauth-token" }
}
```

Respond with success status. Clean up user data on your end.

### 8. Interaction Result

SmartThings notifies you of issues found in your responses. Monitor your server logs for these.

```json
{
  "headers": {
    "interactionType": "interactionResult",
    "requestId": "original-request-id"
  },
  "results": [
    {
      "deviceId": "partner-device-id-1",
      "error": "description of the issue"
    }
  ]
}
```

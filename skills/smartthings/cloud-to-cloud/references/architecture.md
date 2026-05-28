# SmartThings Schema C2C Architecture

## How It Works

SmartThings Schema defines JSON interactions between the SmartThings Cloud and your cloud. Your cloud must act as both an OAuth 2.0 provider and a Schema endpoint.

## Architecture Diagram (Text)

```
SmartThings App
      ↕ SmartThings Cloud API
SmartThings Cloud
      ↕ SmartThings Schema (JSON over HTTPS)
         ┌─────────────────────────┐
         │     Your Cloud          │
         │  ┌───────────────────┐  │
         │  │ OAuth 2.0 Server  │  │  ← Account linking
         │  └───────────────────┘  │
         │  ┌───────────────────┐  │
         │  │ Schema Lambda     │  │  ← Device interactions
         │  └───────────────────┘  │
         │  ┌───────────────────┐  │
         │  │ Device Cloud API  │  │  ← Your actual device API
         │  └───────────────────┘  │
         └─────────────────────────┘
```

## Key Components

### 1. OAuth 2.0 Authorization Server
- Handles account linking when a user connects SmartThings to your platform
- Must support: authorization code flow, multiple redirect URIs
- Must show an explicit authorization page (no auto-approve of cached credentials)

### 2. Schema App (Lambda/Webhook)
- Registered in SmartThings via the Schema API or CLI
- Receives interaction requests (discovery, state refresh, command)
- Returns JSON responses with device info and state

### 3. Device Profiles
- Blueprint defining device capabilities and components
- Can be existing SmartThings profiles or custom ones

## Interaction Flows

### Account Linking
1. User taps "Connect" in SmartThings app
2. SmartThings redirects to your OAuth server
3. User authorizes → OAuth code returned
4. SmartThings exchanges code for tokens
5. Discovery request triggers → Schema App returns devices

### Device Command
1. User issues command in SmartThings app (e.g. "turn off kitchen light")
2. SmartThings sends `commandRequest` to your Lambda
3. Lambda calls your device cloud API
4. Lambda responds with updated device state

### State Refresh
- Automatic: ~every 24 hours
- On-demand: when user taps linked service in app
- SmartThings sends `stateRefreshRequest` → Lambda returns current states

### Proactive Callback
- Your cloud detects a state change (e.g., sensor triggered)
- Uses reciprocal OAuth token to push state via `stateCallback`
- Requires `callbackAccessHandler` to be implemented

## Required Schema Fields

Every request/response includes:
- `headers.schema`: always `"st-schema"`
- `headers.version`: always `"1.0"`
- `headers.interactionType`: varies by interaction
- `headers.requestId`: unique UUID for correlation
- `authentication.token`: OAuth token from account linking

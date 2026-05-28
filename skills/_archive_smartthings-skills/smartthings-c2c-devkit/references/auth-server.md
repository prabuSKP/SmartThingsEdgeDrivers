# OAuth 2.0 Authorization Server

Your cloud **must** support OAuth 2.0 including the authorization code flow and multiple redirect URIs.

## Requirements

- **Grant Type**: Authorization Code (`authorization_code`)
- **Redirect URIs**: Must support multiple URIs (SmartThings may use different ones per environment)
- **Token Type**: Bearer tokens
- **Authorization Page**: Must require explicit user tap on an "Allow"/"Authorize" button
- **Credential Caching**: If caching credentials, cache for max 60 minutes paired with an authorization page

## OAuth Flow

1. SmartThings redirects user to your authorization URL:
   ```
   https://your-auth-server.com/authorize?client_id=CLIENT_ID&redirect_uri=SMARTTHINGS_REDIRECT&response_type=code&state=STATE
   ```

2. User authenticates and authorizes (taps "Allow")

3. Your server redirects back with authorization code:
   ```
   https://smartthings-redirect.com/?code=AUTH_CODE&state=STATE
   ```

4. SmartThings exchanges code for tokens:
   ```
   POST https://your-auth-server.com/token
   grant_type=authorization_code
   code=AUTH_CODE
   redirect_uri=SMARTTHINGS_REDIRECT
   client_id=CLIENT_ID
   client_secret=CLIENT_SECRET
   ```

5. Your server responds with:
   ```json
   {
     "access_token": "ACCESS_TOKEN",
     "token_type": "Bearer",
     "expires_in": 3600,
     "refresh_token": "REFRESH_TOKEN"
   }
   ```

## Best Practices

- Use an OAuth 2.0 provider/library — don't implement from scratch
- Support token refresh via `refresh_token` grant
- Set reasonable token expiry (e.g., 1 hour) with refresh
- Store SmartThings redirect URIs in your auth server config
- Log failed auth attempts for debugging
- Ensure your authorization server is publicly accessible over HTTPS

## Common Issues

| Issue | Fix |
|---|---|
| Redirect URI mismatch | Add all SmartThings redirect URIs to your allowlist |
| Authorization page missing | Ensure page has explicit Allow/Authorize button |
| Token expired during use | Implement `refreshAccessTokens` callback handler |
| CORS issues | Ensure your server includes proper CORS headers |

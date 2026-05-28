# WWST Certification Process

Works With SmartThings (WWST) certification is required to publish your device in the public SmartThings catalog.

## Overview

```
Build & Test → Submit (Console) → Review → (Ship Device) → Test → Publish
```

## Step 1: Self-Testing

Before submitting for certification:

- Complete all QA and beta testing
- Ensure your device contains only **standard** (non-custom) capabilities
- Run the [SmartThings Test Suite](https://developer.smartthings.com/console/test)
  - Supports C2C (Schema) devices
  - May qualify for no-cost self-test certification
  - Can eliminate the need to ship devices to the test provider

**Required Capabilities Check:** Verify your device profile includes all required capabilities for its category. See [Required Capabilities](https://developer.smartthings.com/docs/certification/required-capabilities).

## Step 2: Submit Certification Request

Go to [SmartThings Console](https://developer.smartthings.com/console):

### Required Information

- **Product**: Name, model number, description
- **Brand**: Company brand name and logo (must be authorized representative)
- **Integration Details**: Schema App, device profile, distribution locations
- **Device Type**: Select C2C/Schema

### Brand & Organization

- Your Samsung account must be associated with an Organization
- Each device appears under a single brand
- Different brands = different Schema integrations

## Step 3: Review & Quote

- SmartThings reviews your submission for policy compliance
- If approved, passed to an Authorized Test Provider (UL)
- Test provider issues a price quote
- [Pricing Guide](https://nac-portal.com/WWSTPricing.aspx) for estimated costs
- Quotes expire after 90 days

## Step 4: Ship Device (if required)

If not using the Test Suite self-certification path:

- Ship **2 identical units** of each model
- Test provider provides shipping instructions
- May qualify for **Certification by Similarity (CbS)** for variants (different colors/shapes)

## Step 5: Certification Testing

- Test provider runs compliance tests
- Results delivered within **10 working days**
- Failed tests → re-test quote (covers only failed items)
- Re-tests cost money — self-test thoroughly first

### Test Scope

Determined by:
- Device type and connectivity method
- Capabilities your product supports
- Technical specifications
- Target countries for publication

## Step 6: Publish

- Automatically published once certified
- Permitted to use WWST logo and press kit
- Contact `partners@smartthings.com` to schedule custom publishing date

## Certification Best Practices

### Do Before Submitting
- [x] Run the SmartThings Test Suite
- [x] Test with actual SmartThings app (Android + iOS)
- [x] Validate all interaction types return correct responses
- [x] Verify healthCheck is always included
- [x] Check no custom capabilities in profile
- [x] Test OAuth flow end-to-end (link, unlink, relink)
- [x] Verify callback flow (proactive state updates)
- [x] Handle edge cases: device offline, deleted, rate-limited

### Common Certification Failure Reasons
1. Missing `st.healthCheck` in state responses
2. Device doesn't properly report offline state
3. OAuth token refresh not working
4. Commands not reflected accurately in state response
5. Custom capabilities used where standard ones exist
6. PII leaked in device details beyond friendlyName/roomName
7. Lambda timeout during interactions

### Need Help?
- Support: [SmartThings Support Ticket](https://support.smartthings.com/hc/en-us/requests/new?ticket_form_id=18695616976404)
- Get test cases for specific capabilities via support ticket
- Email: `partners@smartthings.com` for publishing date coordination

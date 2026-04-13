# SmartThings Edge Driver Automation Script

This Python script automates common SmartThings Edge Driver operations through an interactive menu-driven interface.

## Features

- Secure collection of Personal Access Token (PAT)
- Profile selection (Production, Acceptance, Staging, Development)
- Menu-driven interface for executing commands
- All SmartThings Edge Driver operations supported:
  - List devices
  - Package drivers
  - Create channels
  - Assign drivers to channels
  - Enroll hubs to channels
  - Install drivers to hubs
- Option to run all operations sequentially
- Error handling and clear output display

## Prerequisites

- Python 3.x installed
- SmartThings CLI installed and available in PATH
- Valid SmartThings Personal Access Token (PAT)
- SmartThings account with appropriate permissions

## Installation

1. Save the `smartthings_edge_automation.py` script to your local machine
2. Ensure the SmartThings CLI is installed and configured
3. Make the script executable (optional):
   ```bash
   chmod +x smartthings_edge_automation.py
   ```

## Usage

Run the script using Python:

```bash
python3 smartthings_edge_automation.py
```

### Step-by-Step Operation

1. **PAT Token Entry**:
   - When prompted, enter your SmartThings Personal Access Token
   - The token will be masked for security

2. **Profile Selection**:
   - Choose from Production (default), Acceptance, Staging, or Development
   - Press Enter to use Production as default

3. **Configuration Confirmation**:
   - Review your settings and confirm to proceed

4. **Main Menu**:
   - Select from the available operations:
     1. List devices
     2. Package drivers
     3. Create channel
     4. Assign driver to channel
     5. Enroll hub to channel
     6. Install driver to hub
     7. Run all operations sequentially
     8. Change configuration
     9. Exit

5. **Operation Execution**:
   - Follow prompts for each operation
   - View command output and results
   - Press Enter to continue to the next operation or menu

## Security

- PAT tokens are collected using secure input (masked)
- Tokens are not stored in files or logs
- Tokens are only used for the duration of the script execution

## Error Handling

- Commands with non-zero exit codes will display error messages
- Option to continue or abort when operations fail
- Exception handling for unexpected errors
- Interactive commands (assign, enroll, install) properly handle user prompts

## Customization

The script can be easily modified to:
- Add additional driver paths
- Include more SmartThings CLI commands
- Modify the menu structure
- Change the default profile
- Add logging functionality

## Troubleshooting

If you encounter issues:

1. Ensure SmartThings CLI is properly installed and in your PATH
2. Verify your PAT token has the necessary permissions
3. Check that you have internet connectivity
4. Confirm you're using the correct profile for your environment

## Example Commands

The script automates these SmartThings CLI commands:

```bash
# List devices
smartthings --token YOUR_PAT_TOKEN --profile acceptance devices

# Package drivers
smartthings --token YOUR_PAT_TOKEN --profile acceptance edge:drivers:package drivers/Unofficial/fibaro-hc2/

# Create channel
smartthings --token YOUR_PAT_TOKEN --profile acceptance edge:channels

# Assign driver to channel
smartthings --token YOUR_PAT_TOKEN --profile acceptance edge:channels:assign

# Enroll hub to channel
smartthings --token YOUR_PAT_TOKEN --profile acceptance edge:channels:enroll

# Install driver to hub
smartthings --token YOUR_PAT_TOKEN --profile acceptance edge:drivers:install
```

Note: The `--profile` parameter is only added for non-production environments.

## Support

For issues with this script, please check that:
- You're using Python 3.x
- The SmartThings CLI is properly installed
- Your PAT token has the correct permissions
- You're connected to the internet
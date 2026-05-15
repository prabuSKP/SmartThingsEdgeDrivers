#!/usr/bin/env python3
"""
SmartThings Edge Driver Automation Script

This script automates common SmartThings Edge Driver operations including:
- Listing devices
- Packaging drivers
- Managing Edge channels
- Assigning drivers to channels
- Enrolling hubs to channels
- Installing drivers to hubs

The script collects user inputs at startup and provides a menu-driven interface
for executing commands with proper parameter substitution.
"""

import subprocess
import sys
import os
import getpass

def clear_screen():
    """Clear the terminal screen"""
    os.system('cls' if os.name == 'nt' else 'clear')

def get_pat_token():
    """Securely collect the Personal Access Token from user"""
    print("=== SmartThings Edge Driver Automation ===\n")
    print("Please enter your SmartThings Personal Access Token (PAT)")
    print("Note: The token will not be displayed for security reasons\n")
    
    while True:
        token = getpass.getpass("Enter your PAT token: ")
        if token.strip():
            return token.strip()
        print("Token cannot be empty. Please try again.\n")

def get_profile_selection():
    """Get profile selection from user with validation"""
    print("\nSelect the SmartThings environment profile:")
    print("1. Production (default)")
    print("2. Acceptance")
    print("3. Staging")
    print("4. Development")
    
    profile_map = {
        "1": "production",
        "2": "acceptance",
        "3": "staging",
        "4": "development"
    }
    
    while True:
        choice = input("\nEnter your choice (1-4) [1]: ").strip()
        
        if not choice:
            # Default to production
            return "production"
        
        if choice in profile_map:
            return profile_map[choice]
        
        print("Invalid choice. Please enter a number between 1 and 4.")

def confirm_inputs(pat_token, profile):
    """Display and confirm user inputs"""
    clear_screen()
    print("=== Configuration Summary ===")
    print(f"Profile: {profile}")
    print("PAT Token: ***" + "*" * (len(pat_token) - 6) + pat_token[-3:] if len(pat_token) > 3 else "***")
    
    confirmation = input("\nContinue with these settings? (y/n) [y]: ").strip().lower()
    return confirmation in ['', 'y', 'yes']

def build_command(base_command, pat_token, profile):
    """Build the complete command with token and profile parameters"""
    command = f"smartthings --token {pat_token}"
    
    # Add profile parameter only if not production
    if profile != "production":
        command += f" --profile {profile}"
    
    command += f" {base_command}"
    return command

def execute_command(command, interactive=False):
    """Execute a command and display the output"""
    print(f"\nExecuting: {command}\n")
    
    try:
        # For all commands, don't capture input/output to preserve formatting
        # This allows the commands to display their formatted output directly
        result = subprocess.run(command, shell=True)
        return result.returncode == 0
            
    except Exception as e:
        print(f"An error occurred while executing the command: {str(e)}")
        return False


def list_devices(pat_token, profile):
    """List SmartThings devices"""
    print("\n=== List Devices ===")
    command = build_command("devices", pat_token, profile)
    return execute_command(command, interactive=False)

def package_drivers(pat_token, profile):
    """Package Edge drivers"""
    print("\n=== Package Drivers ===")
    print("Available driver paths:")
    
    # List some common driver paths
    driver_paths = [
        "drivers/Unofficial/fibaro-hc2/",
        "drivers/SmartThings/matter-switch/",
        "drivers/SmartThings/matter-button/",
        "drivers/SmartThings/matter-sensor/"
    ]
    
    for i, path in enumerate(driver_paths, 1):
        print(f"{i}. {path}")
    
    print(f"{len(driver_paths) + 1}. Enter custom path")
    
    while True:
        try:
            choice = input(f"\nSelect a driver path (1-{len(driver_paths) + 1}): ").strip()
            choice_num = int(choice)
            
            if 1 <= choice_num <= len(driver_paths):
                driver_path = driver_paths[choice_num - 1]
                break
            elif choice_num == len(driver_paths) + 1:
                driver_path = input("Enter the custom driver path: ").strip()
                if not driver_path:
                    print("Path cannot be empty.")
                    continue
                break
            else:
                print(f"Please enter a number between 1 and {len(driver_paths) + 1}")
        except ValueError:
            print("Please enter a valid number.")
    
    command = build_command(f"edge:drivers:package {driver_path}", pat_token, profile)
    return execute_command(command)

def create_channel(pat_token, profile):
    """Create Edge channel"""
    print("\n=== Create Edge Channel ===")
    command = build_command("edge:channels", pat_token, profile)
    return execute_command(command)

def assign_driver_to_channel(pat_token, profile):
    """Assign driver to channel"""
    print("\n=== Assign Driver to Channel ===")
    command = build_command("edge:channels:assign", pat_token, profile)
    return execute_command(command, interactive=True)

def enroll_hub_to_channel(pat_token, profile):
    """Enroll hub to channel"""
    print("\n=== Enroll Hub to Channel ===")
    command = build_command("edge:channels:enroll", pat_token, profile)
    return execute_command(command, interactive=True)

def install_driver_to_hub(pat_token, profile):
    """Install driver to hub"""
    print("\n=== Install Driver to Hub ===")
    command = build_command("edge:drivers:install", pat_token, profile)
    return execute_command(command, interactive=True)

def show_menu():
    """Display the main menu and get user selection"""
    print("\n=== SmartThings Edge Driver Operations ===")
    print("1. List devices")
    print("2. Package drivers")
    print("3. Create channel")
    print("4. Assign driver to channel")
    print("5. Enroll hub to channel")
    print("6. Install driver to hub")
    print("7. Run all operations sequentially")
    print("8. Change configuration")
    print("9. Exit")
    
    return input("\nEnter your choice (1-9): ").strip()

def run_all_operations(pat_token, profile):
    """Run all operations sequentially"""
    print("\n=== Running All Operations ===")
    
    operations = [
        ("List devices", list_devices),
        ("Package drivers", package_drivers),
        ("Create channel", create_channel),
        ("Assign driver to channel", assign_driver_to_channel),
        ("Enroll hub to channel", enroll_hub_to_channel),
        ("Install driver to hub", install_driver_to_hub)
    ]
    
    for operation_name, operation_func in operations:
        print(f"\n--- {operation_name} ---")
        success = operation_func(pat_token, profile)
        
        if not success:
            choice = input(f"\n{operation_name} failed. Continue with remaining operations? (y/n) [y]: ").strip().lower()
            if choice and choice not in ['y', 'yes', '']:
                print("Aborting remaining operations.")
                return False
        
        # Pause between operations to allow user to see results
        input("\nPress Enter to continue to the next operation...")
    
    print("\nAll operations completed!")
    return True

def main():
    """Main function to run the script"""
    # Get initial configuration
    pat_token = get_pat_token()
    profile = get_profile_selection()
    
    # Confirm inputs
    while not confirm_inputs(pat_token, profile):
        print("\nLet's re-enter the configuration.")
        pat_token = get_pat_token()
        profile = get_profile_selection()
    
    # Main loop
    while True:
        clear_screen()
        choice = show_menu()
        
        if choice == "1":
            list_devices(pat_token, profile)
        elif choice == "2":
            package_drivers(pat_token, profile)
        elif choice == "3":
            create_channel(pat_token, profile)
        elif choice == "4":
            assign_driver_to_channel(pat_token, profile)
        elif choice == "5":
            enroll_hub_to_channel(pat_token, profile)
        elif choice == "6":
            install_driver_to_hub(pat_token, profile)
        elif choice == "7":
            run_all_operations(pat_token, profile)
        elif choice == "8":
            # Change configuration
            pat_token = get_pat_token()
            profile = get_profile_selection()
            confirm_inputs(pat_token, profile)
            continue
        elif choice == "9":
            print("\nThank you for using SmartThings Edge Driver Automation!")
            break
        else:
            print("Invalid choice. Please enter a number between 1 and 9.")
            input("\nPress Enter to continue...")
            continue
        
        # Pause to show results before showing menu again
        input("\nPress Enter to continue...")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nScript interrupted by user. Exiting...")
        sys.exit(0)
    except Exception as e:
        print(f"\nAn unexpected error occurred: {str(e)}")
        sys.exit(1)
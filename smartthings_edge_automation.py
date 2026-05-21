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
import urllib.request
import urllib.parse
import base64
import json
import ssl
import tempfile

def clear_screen():
    """Clear the terminal screen"""
    os.system('cls' if os.name == 'nt' else 'clear')

def get_pat_token():
    """Securely collect the Personal Access Token from user"""
    print("=== SmartThings Edge Driver Automation ===\n")
    print("Please enter your SmartThings Personal Access Token (PAT)")
    print("Or press Enter to use your existing logged-in CLI session (Recommended to avoid 24-hr token expiration)\n")
    
    token = getpass.getpass("Enter your PAT token (optional): ").strip()
    return token

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
    command = "smartthings"
    if pat_token:
        command += f" --token {pat_token}"
    
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


def run_cli_json(command):
    """Execute a CLI command and return parsed JSON output"""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout)
        else:
            print(f"Error executing command: {result.stderr}")
            return None
    except Exception as e:
        print(f"Exception executing command: {str(e)}")
        return None

def fetch_fibaro_api(url, username, password):
    """Fetch JSON from Fibaro API using basic auth"""
    req = urllib.request.Request(url)
    auth_str = f"{username}:{password}"
    auth_b64 = base64.b64encode(auth_str.encode('utf-8')).decode('utf-8')
    req.add_header('Authorization', f'Basic {auth_b64}')
    req.add_header('Accept', 'application/json')
    
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as response:
            if response.status == 200:
                return json.loads(response.read().decode('utf-8'))
            else:
                print(f"[-] Fibaro API returned status code {response.status}")
                return None
    except Exception as e:
        print(f"[-] Error connecting to Fibaro API: {str(e)}")
        return None

def sync_fibaro_rooms_and_devices(pat_token, profile):
    """Synchronize rooms and devices from Fibaro controller to SmartThings"""
    print("\n=== Synchronize Fibaro Rooms & Devices to SmartThings ===")
    
    fibaro_ip = input("Enter Fibaro Controller IP [127.0.0.1]: ").strip() or "127.0.0.1"
    fibaro_port = input("Enter Fibaro Controller Port [80]: ").strip() or "80"
    fibaro_user = input("Enter Fibaro Username [admin]: ").strip() or "admin"
    fibaro_pass = getpass.getpass("Enter Fibaro Password [admin]: ") or "admin"
    
    dry_run_input = input("Perform dry-run only (no changes made)? (y/n) [y]: ").strip().lower()
    dry_run = dry_run_input not in ['n', 'no']
    
    print("\n[Fibaro] Fetching rooms and devices...")
    fibaro_rooms_url = f"http://{fibaro_ip}:{fibaro_port}/api/rooms"
    fibaro_devices_url = f"http://{fibaro_ip}:{fibaro_port}/api/devices"
    
    fib_rooms_data = fetch_fibaro_api(fibaro_rooms_url, fibaro_user, fibaro_pass)
    fib_devices_data = fetch_fibaro_api(fibaro_devices_url, fibaro_user, fibaro_pass)
    
    if not fib_rooms_data or not fib_devices_data:
        print("[-] Failed to retrieve data from Fibaro. Aborting sync.")
        return False
        
    print(f"[+] Loaded {len(fib_rooms_data)} rooms and {len(fib_devices_data)} devices from Fibaro.")
    
    fib_rooms = {room['id']: room['name'] for room in fib_rooms_data if 'id' in room and 'name' in room}
    
    print("\n[SmartThings] Listing locations...")
    cmd_locations = build_command("locations -j", pat_token, profile)
    st_locations = run_cli_json(cmd_locations)
    
    if not st_locations:
        print("[-] Failed to retrieve locations from SmartThings. Ensure CLI is logged in or PAT is valid.")
        return False
        
    print("\nAvailable SmartThings Locations:")
    for idx, loc in enumerate(st_locations, 1):
        print(f"{idx}. {loc.get('name', 'Unnamed')} (ID: {loc.get('locationId')})")
        
    while True:
        try:
            choice = input(f"\nSelect a location (1-{len(st_locations)}): ").strip()
            choice_num = int(choice)
            if 1 <= choice_num <= len(st_locations):
                target_location = st_locations[choice_num - 1]
                break
            print(f"[-] Invalid selection. Please enter 1 to {len(st_locations)}.")
        except ValueError:
            print("[-] Please enter a valid number.")
            
    location_id = target_location['locationId']
    location_name = target_location.get('name', 'Unnamed')
    print(f"[+] Selected Location: {location_name} ({location_id})")
    
    print("\n[SmartThings] Fetching existing rooms...")
    cmd_rooms = build_command(f"locations:rooms -l {location_id} -j", pat_token, profile)
    st_rooms_data = run_cli_json(cmd_rooms) or []
    
    st_rooms = {room['name']: room['roomId'] for room in st_rooms_data if 'name' in room and 'roomId' in room}
    print(f"[+] Found {len(st_rooms)} existing rooms in SmartThings.")
    
    for room_id, room_name in fib_rooms.items():
        if room_name not in st_rooms:
            print(f"[*] Room '{room_name}' is missing in SmartThings.")
            if dry_run:
                print(f"    [Dry-Run] Would create room: '{room_name}'")
                st_rooms[room_name] = f"dry-run-room-{room_id}"
            else:
                print(f"    [+] Creating room '{room_name}' in SmartThings...")
                with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
                    json.dump({"name": room_name}, f)
                    temp_path = f.name
                
                try:
                    cmd_create_room = build_command(f"locations:rooms:create -l {location_id} -i {temp_path} -j", pat_token, profile)
                    new_room = run_cli_json(cmd_create_room)
                    if new_room and 'roomId' in new_room:
                        st_rooms[room_name] = new_room['roomId']
                        print(f"    [+] Successfully created room '{room_name}' (ID: {new_room['roomId']})")
                    else:
                        print(f"    [-] Failed to create room '{room_name}'")
                finally:
                    if os.path.exists(temp_path):
                        os.remove(temp_path)
                        
    print("\n[SmartThings] Fetching devices...")
    cmd_devices = build_command("devices -j", pat_token, profile)
    st_devices_data = run_cli_json(cmd_devices) or []
    
    st_child_devices = []
    for dev in st_devices_data:
        if dev.get('locationId') != location_id:
            continue
        edge_child = dev.get('edgeChild')
        if edge_child and edge_child.get('parentAssignedChildKey'):
            key = edge_child.get('parentAssignedChildKey')
            if key.startswith('device:'):
                st_child_devices.append(dev)
                
    print(f"[+] Found {len(st_child_devices)} Fibaro child devices in this location.")
    
    fib_devices = {device['id']: device for device in fib_devices_data if 'id' in device}
    
    move_count = 0
    for dev in st_child_devices:
        dev_id = dev['deviceId']
        dev_label = dev.get('label', 'Unnamed')
        child_key = dev['edgeChild']['parentAssignedChildKey']
        fib_id_str = child_key.split(':')[1]
        try:
            fib_id = int(fib_id_str)
        except ValueError:
            continue
            
        fib_dev = fib_devices.get(fib_id)
        if not fib_dev:
            print(f"[*] SmartThings device '{dev_label}' (ID: {dev_id}) corresponds to Fibaro ID {fib_id}, but that device was not found in Fibaro inventory.")
            continue
            
        fib_room_id = fib_dev.get('roomID') or fib_dev.get('room_id') or 0
        if fib_room_id == 0:
            continue
            
        fib_room_name = fib_rooms.get(fib_room_id)
        if not fib_room_name:
            continue
            
        st_target_room_id = st_rooms.get(fib_room_name)
        if not st_target_room_id:
            print(f"[-] Target room '{fib_room_name}' ID not found in SmartThings mapping.")
            continue
            
        st_current_room_id = dev.get('roomId')
        
        if st_current_room_id != st_target_room_id:
            print(f"[*] Move required: '{dev_label}' -> Room '{fib_room_name}'")
            print(f"    Current Room ID: {st_current_room_id}")
            print(f"    Target Room ID:  {st_target_room_id}")
            
            if dry_run:
                print(f"    [Dry-Run] Would move device '{dev_label}' to room '{fib_room_name}'")
                move_count += 1
            else:
                with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
                    json.dump({"roomId": st_target_room_id}, f)
                    temp_path = f.name
                    
                try:
                    cmd_update_device = build_command(f"devices:update {dev_id} -i {temp_path}", pat_token, profile)
                    success = execute_command(cmd_update_device)
                    if success:
                        print(f"    [+] Successfully moved '{dev_label}' to room '{fib_room_name}'")
                        move_count += 1
                    else:
                        print(f"    [-] Failed to move '{dev_label}'")
                finally:
                    if os.path.exists(temp_path):
                        os.remove(temp_path)
                        
    print(f"\n[+] Synchronization complete. Total devices moved/requiring move: {move_count}")
    return True


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
    print("9. Synchronize Fibaro Rooms & Devices to SmartThings")
    print("10. Exit")
    
    return input("\nEnter your choice (1-10): ").strip()

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
            sync_fibaro_rooms_and_devices(pat_token, profile)
        elif choice == "10":
            print("\nThank you for using SmartThings Edge Driver Automation!")
            break
        else:
            print("Invalid choice. Please enter a number between 1 and 10.")
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
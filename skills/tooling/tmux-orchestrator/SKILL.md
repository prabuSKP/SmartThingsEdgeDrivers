---
name: tmux-orchestrator
description: >
  Manage active Edge driver developer environments using tmux command dashboards.
  Covers configuring tmux layout panes to simultaneously run: (1) logcat tailing,
  (2) source file editors, (3) driver build/package scripts, and (4) local curl/test clients.
  Use when setting up or managing a CLI development workspace.
---

# Tmux Development Dashboard Orchestrator

When developing SmartThings Edge Drivers, you frequently need to edit code, package/upload drivers, tail logs via logcat, and run network curl tests simultaneously.

This skill provides a shell script to automate setting up a multi-pane `tmux` dashboard optimized for Edge driver developers.

---

## 1. Tmux Dashboard Layout

The dashboard is structured into a single window split into four quadrants:

```
┌─────────────────────────────────┬─────────────────────────────────┐
│                                 │                                 │
│  Pane 1: Logcat Output          │  Pane 2: Source File Editor     │
│  (Live hub logs)                │  (e.g., vim, nano)              │
│                                 │                                 │
├─────────────────────────────────┼─────────────────────────────────┤
│                                 │                                 │
│  Pane 3: CLI Control            │  Pane 4: API Debug / Sandbox    │
│  (Package/upload commands)      │  (Curl endpoints, websockets)   │
│                                 │                                 │
└─────────────────────────────────┴─────────────────────────────────┘
```

---

## 2. Orchestration Script: `start_dev_session.sh`

Create a file named `start_dev_session.sh` in your workspace directory:

```bash
#!/bin/bash

# Name of the tmux session
SESSION_NAME="st-edge-dev"
DRIVER_DIR="c/Prabu/Application/SmartThingsEdgeDrivers"

# Check if the session already exists
tmux has-session -t $SESSION_NAME 2>/dev/null

if [ $? -ne 0 ]; then
  # 1. Create a new detached session
  tmux new-session -d -s $SESSION_NAME -n "Driver-Dev"
  
  # Set default directory
  tmux send-keys -t $SESSION_NAME "cd /$DRIVER_DIR" C-m
  tmux send-keys -t $SESSION_NAME "clear" C-m

  # 2. Split window horizontally (creating top and bottom halves)
  tmux split-window -h -t $SESSION_NAME
  
  # 3. Split left pane vertically (left-top and left-bottom)
  tmux split-window -v -t $SESSION_NAME:0.0
  
  # 4. Split right pane vertically (right-top and right-bottom)
  tmux split-window -v -t $SESSION_NAME:0.2

  # 5. Configure Pane 0 (Top-Left): Logcat Stream
  tmux send-keys -t $SESSION_NAME:0.0 "smartthings edge:drivers:logcat" C-m

  # 6. Configure Pane 1 (Bottom-Left): CLI Controls (Package / Upload / Fingerprints)
  tmux send-keys -t $SESSION_NAME:0.1 "cd /$DRIVER_DIR" C-m
  tmux send-keys -t $SESSION_NAME:0.1 "clear" C-m
  tmux send-keys -t $SESSION_NAME:0.1 "# Run package: smartthings edge:drivers:package"

  # 7. Configure Pane 2 (Top-Right): Editor (e.g., Vim / Nano / Git status)
  tmux send-keys -t $SESSION_NAME:0.2 "cd /$DRIVER_DIR" C-m
  tmux send-keys -t $SESSION_NAME:0.2 "git status" C-m

  # 8. Configure Pane 3 (Bottom-Right): Network Sandbox
  tmux send-keys -t $SESSION_NAME:0.3 "cd /$DRIVER_DIR" C-m
  tmux send-keys -t $SESSION_NAME:0.3 "clear" C-m
  tmux send-keys -t $SESSION_NAME:0.3 "# Use curl to inspect vendor APIs"
fi

# Attach to the session
tmux attach-session -t $SESSION_NAME
```

### Running the Orchestrator
Make the script executable and execute:
```bash
chmod +x start_dev_session.sh
./start_dev_session.sh
```

---

## 3. Keyboard Shortcuts Cheat Sheet

Inside the tmux dashboard:

- **Switch Pane**: `Ctrl+B` then Arrow Keys.
- **Toggle Zoom (Maximize) Pane**: `Ctrl+B` then `Z` (useful for reading long logcat traces).
- **Scroll Logcat (Copy Mode)**: `Ctrl+B` then `[` (Page Up/Page Down to scroll; `Q` to exit).
- **Kill Session**: `Ctrl+B` then type `:kill-session`.

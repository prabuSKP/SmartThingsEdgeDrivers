---
name: github-pr-review
description: >
  Code review checklist and guidelines for SmartThings Edge Driver PRs.
  Covers inspecting code for blocking I/O, global namespace pollution, socket leak
  prevention, timer handling, and profile validation. Use when reviewing code changes,
  submitting PRs, or ensuring quality checks before deployment.
---

# GitHub PR Review Checklist for SmartThings Edge Drivers

This skill serves as a code review guide when inspecting pull requests that edit or create SmartThings Edge Drivers. Use this list to prevent memory leaks, hub lockups, and runtime crashes.

---

## Code Review Checklist

### 1. Cooperative Multitasking & Blocking Sockets
The most common cause of driver crashes on the SmartThings Hub is blocking the scheduler.
- [ ] **No standard socket imports**: Verify the code does **not** import raw socket libraries:
  - *Incorrect*: `local socket = require "socket"`
  - *Correct*: `local socket = require "cosock.socket"`
- [ ] **No shell executions**: Ensure there are no instances of `os.execute` or `io.popen`. These block the entire Lua thread.
- [ ] **No busy-loops**: Check that periodic tasks are scheduled via `driver:call_on_schedule` or use `socket.sleep()` inside `cosock.spawn`.

### 2. Namespace Pollution & Scope leaks
Global variables are shared across the driver process, which will cause unexpected side effects in multi-device setups.
- [ ] **Ensure local variables**: Every variable, function declaration, and import must start with `local`.
- [ ] **No variables in file header without `local`**:
  - *Incorrect*: `my_utility = require "utils"`
  - *Correct*: `local my_utility = require "utils"`
- [ ] **Ensure returned module table is local**:
  ```lua
  local mapper = {}
  -- ...
  return mapper
  ```

### 3. Error Handling & Stability
If a driver encounters an unhandled exception inside a callback or coroutine, the process will crash.
- [ ] **Wrap polling loops in `pcall`**: Ensure network poll tasks utilize protected calls:
  ```lua
  local status, err = pcall(client.get_status, client)
  ```
- [ ] **Wrap capability handlers in `pcall`**: If the hub device goes offline, command handlers (like `on`, `off`) should not crash the driver if the HTTP request times out.

### 4. Device Lifecycle & Resource Leak Prevention
Sockets and timers must be cleaned up when a device is deleted, or the hub will experience resource exhaustion.
- [ ] **Clean up in `removed`**: Ensure the `removed` lifecycle handler cancels all timers associated with that device:
  ```lua
  driver:cancel_timer(device:get_field("polling_timer"))
  ```
- [ ] **Close client sockets**: Verify network connection pools or socket objects are explicitly closed during teardown.
- [ ] **No network calls in `added`**: Network operations and timer startups must occur in `init`, not `added`.

### 5. Capabilities and Profiles
Profile and capability mismatches will prevent the SmartThings app from rendering the device UI properly.
- [ ] **Profile file extensions**: Profile files must end in `.yml`, not `.yaml`.
- [ ] **Component names matching handlers**: Command handlers registered in `init.lua` must match the capability IDs and components defined in the profile YML.
- [ ] **State emission format**: Ensure status updates follow the correct capability event signature:
  - *Incorrect*: `device:emit_event(capabilities.switch.switch("on"))`
  - *Correct*: `device:emit_event(capabilities.switch.switch.on())`

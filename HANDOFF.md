# FlashSpace - Finder Window Cycling Handoff Document

## What is FlashSpace?

FlashSpace is a **Swift macOS workspace manager** that lets users organize apps into virtual workspaces, each activated by hotkeys. When you switch workspaces, it hides apps from the old workspace and shows apps in the new one.

**Finder is special**: since `NSRunningApplication.hide()` is app-level (hides ALL Finder windows), FlashSpace has custom per-window Finder management that moves individual windows off-screen to "hide" them and restores them on workspace switch.

## Project Location

`/Users/connorshafran/Desktop/FlashSpace-main/`

## Current State: What Works

### Finder Window Cycling (NEW - implemented in this session)

The `cycleWindows` hotkey now treats each Finder window as a **separate item** in the cycle list, alongside regular apps. Users can cycle through apps AND individual Finder windows with a single hotkey.

**Working features:**
- Cycling through regular apps (as before)
- Each Finder window appears as a separate cycle item
- New Finder windows are auto-discovered when the cycle is invoked
- Closed Finder windows are auto-pruned from the cycle
- Multiple Finder windows cycle correctly (no getting stuck)
- Closing all Finder windows removes Finder from the cycle entirely
- Internal/invisible Finder windows (desktop, utility panels) are filtered out
- File copy/transfer progress windows ARE included in cycling

### Workspace Switching with Per-Window Finder Management (pre-existing)

Finder windows hide/show correctly during workspace switches via off-screen positioning. This was already working before this session.

## Key Files

| File | Purpose |
|------|---------|
| `FlashSpace/Features/Workspaces/FinderWindowManager.swift` | Core Finder per-window management: tracking, hiding, restoring, **and cycling focus** |
| `FlashSpace/Features/Workspaces/WorkspaceHotKeys.swift` | Hotkey actions including `cycleWindows()` / `doCycleWindows()` |
| `FlashSpace/Features/Workspaces/WorkspaceManager.swift` | Orchestrates workspace switching |
| `FlashSpace/Features/FocusManager/FocusedWindowTracker.swift` | Tracks app focus changes via `NSWorkspace.didActivateApplicationNotification` |
| `FlashSpace/Accessibility/AXUIElement+CoreGraphics.swift` | `cgWindowId` property using `_AXUIElementGetWindow` private API |
| `FlashSpace/Accessibility/AXUIElement+Actions.swift` | `focus()` calls `AXUIElementPerformAction(self, kAXRaiseAction)` |
| `FlashSpace/Accessibility/NSRunningApplication+Properties.swift` | `allWindowElements`, `focusedWindow`, `isOnAnyDisplay` |
| `FlashSpace/App/AppDependencies.swift` | Singleton holding `finderWindowManager`, `focusedWindowTracker`, etc. |
| `.swiftlint.yml` | `trailing_whitespace` disabled, line_length=160, file_length warn=550/error=1000 |

## Architecture of the Cycling Feature

### How It Works

1. **Hotkey fires** -> `cycleWindows(next:)` immediately defers to `DispatchQueue.main.async` (critical -- see "Carbon Callback Constraint" below)
2. **`doCycleWindows`** runs in the async block:
   - Calls `refreshTrackedWindows(for:)` to discover new Finder windows and prune closed ones
   - Builds cycle list: regular apps as `.app(bundleId:)` + individual Finder windows as `.finderWindow(windowId:)`
   - Finder is **skipped** in the app loop (before `isOnAnyDisplay` AX calls) to avoid querying Finder's AX tree
   - Determines current position using `lastFocusedWindowId` (in-memory, no AX calls)
   - Activates next item: `.activate()` for apps, `focusFinderWindow(_:elements:)` for Finder windows

### CycleItem Enum

```swift
private enum CycleItem: Equatable {
    case app(bundleId: String)
    case finderWindow(windowId: CGWindowID)
}
```

### Key Methods on FinderWindowManager

| Method | Purpose |
|--------|---------|
| `refreshTrackedWindows(for:)` | Queries Finder's AX tree, discovers new windows (with frame > 50x50 and on-screen), prunes closed windows. Returns fresh `[CGWindowID: AXUIElement]` map. |
| `focusFinderWindow(_:elements:)` | Raises a specific window via `element.focus()` + `finder.activate()`. Updates `lastFocusedWindow` directly (because `didActivateApplicationNotification` is filtered by `.removeDuplicates()` for consecutive Finder activations). |
| `trackedWindowIds(for:)` | Returns CGWindowIDs tracked to a workspace. |
| `lastFocusedWindowId(for:)` | Returns the last focused Finder window in a workspace (used for cycle position). |

## Critical Constraints Discovered

### 1. Carbon Callback Constraint (MOST IMPORTANT)

**Hotkey actions run inside a Carbon event handler callback.** Code that works fine in a normal context (including trivial dictionary access) **crashes or deadlocks** when called from this callback. The exact mechanism is unclear, but it's reproducible.

**Solution**: `cycleWindows()` immediately defers ALL work to `DispatchQueue.main.async`. The callback returns instantly, and the actual cycling logic runs on the next run loop iteration in a normal execution context.

```swift
private func cycleWindows(next: Bool) {
    DispatchQueue.main.async { [weak self] in
        self?.doCycleWindows(next: next)
    }
}
```

**DO NOT** put any non-trivial code in `cycleWindows` itself. Even accessing `AppDependencies.shared.finderWindowManager` crashed from the Carbon callback context.

### 2. Xcode Debugger Interference

**Running FlashSpace with the Xcode debugger attached causes freezes/crashes** in the cycling feature. The debugger interferes with Carbon event handling and/or accessibility API calls.

**Workaround**: Build with Cmd+B, then launch the app directly (from build output or Applications). Do NOT use Cmd+R (Run with debugging). Use `Cmd+Ctrl+R` (Run Without Building) as an alternative after building once.

### 3. Finder AX Calls Must Skip in App Loop

`isOnAnyDisplay()` queries each app's accessibility windows via `allWindowElements` -> `getAttribute(.windows)`. This call can deadlock or crash when made against Finder from certain contexts.

**Solution**: Skip Finder (`bundleId == finderBundleId`) BEFORE the `isOnAnyDisplay` guard, not after. Finder windows are added to the cycle separately from `trackedWindowIds`.

### 4. `.removeDuplicates()` on didActivateApplicationNotification

`FocusedWindowTracker` uses `.removeDuplicates()` on the notification publisher. When cycling from Finder window A to Finder window B, the same app (Finder) activates twice, so the second notification is filtered out. This means `trackFocusedFinderWindow` is NOT called, and `lastFocusedWindow` is NOT updated.

**Solution**: `focusFinderWindow` updates `lastFocusedWindow` directly after raising the window.

### 5. Internal Finder Windows

Finder has AXWindow elements that aren't visible user windows (desktop, utility panels). These must be filtered out when auto-discovering windows.

**Solution**: `refreshTrackedWindows` only tracks new windows with `frame.width > 50 && frame.height > 50 && frame.origin.x < maxX - 10`.

## Known Remaining Issues

### savedFrames Corruption (pre-existing, not addressed in this session)

When a restore fails (stale AXUIElement), `hideWindowsNotIn` on the next workspace switch reads the still-hidden position as the "current frame" and saves it as the original. The current code has a guard (`frame.origin.x < maxX - 10`) to detect this, but the window is stuck at the hidden position with no way to restore it. A more robust solution would be to never overwrite `savedFrames[wid]` if an entry already exists, or to use a separate `hiddenWindows: Set<CGWindowID>` to track hidden state independently.

### System Dialogs Not Cycled

System permission dialogs (e.g., "App would like to control this computer") are owned by system agent processes (`UserNotificationCenter`, `SecurityAgent`) with `activationPolicy != .regular`. They don't appear in the cycling. Adding them would require scanning all on-screen windows via `CGWindowListCopyWindowInfo` regardless of process -- a significant architectural change.

## What Was Tried and Failed (for historical context)

These approaches were tried for raising specific Finder windows from the hotkey handler. All failed:

1. **Re-querying AXUIElements in the Carbon callback** -> Deadlock
2. **Caching AXUIElements** -> EXC_BAD_ACCESS (dangling pointers)
3. **Background thread with semaphore** -> Still crashes (crash happens before timeout)
4. **CGWindowListCopyWindowInfo validation** -> Deadlocks from hotkey handler
5. **CGSOrderWindow private API** -> Returns error 1000 (can't reorder cross-process windows without Dock injection)
6. **Deferred AX via DispatchQueue.main.async** -> WORKS (current solution)

The key insight: the problem was never AXUIElement itself, but the **Carbon hotkey callback context**. Deferring to a normal run loop iteration makes the same AX calls work perfectly.

## Build Notes

- Build with Xcode (Cmd+B), but **test without the debugger** (launch directly or Cmd+Ctrl+R)
- No `xcodebuild` from CLI (Xcode full IDE required for builds)
- SwiftLint: `trailing_whitespace` disabled, line_length=160, file_length warn=550/error=1000

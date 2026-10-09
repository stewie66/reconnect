---
title: Debugging
---

Debug builds use the `uk.co.jbmorley.reconnect.apps.apple.debug` bundle identifier and a separate menu app, launch agent, and XPC service. Release builds retain the production identifiers. Keep the Debug bundle identifiers in `Reconnect.xcodeproj`, the identifiers in `ReconnectCore/Extensions/String.swift`, and the launch-agent property lists in sync.

This separation allows a locally signed build to run alongside an installed release. macOS caches the signing requirements for background services, so reusing a release's identifiers with another development team can prevent `reconnectd` from launching with a `Launch Constraint Violation`, even when service registration succeeds. Debug builds have their own preferences and background-service approval.

Debugging Reconnect is a little more awkward than normal since plptools uses signals internally which are trapped by Xcode and lldb by default, causing the debugger to pause regularly. You can disable this automatic behavior by adding the following line to `~/.lldbinit-Xcode`:

```
process handle SIGUSR1 -n true -p true -s false
```

> [!WARNING]
> Changing `~/.lldbinit-Xcode` will cause Xcode to ignore `SIGUSR1` for all projects.

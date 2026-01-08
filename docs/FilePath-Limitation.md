# File Path Limitation

## Problem

When a file path is provided as text (e.g., dragging from Xcode's file navigator), we cannot create a security-scoped bookmark because the app doesn't have sandbox access to that file.

## Technical Details

macOS sandbox requires explicit user consent to access files. This consent is granted when:
- User drags a file directly from Finder → System grants temporary access
- User selects a file via NSOpenPanel → System grants access

However, when an app (like Xcode) provides only a file path as text (e.g., `file:///path/to/file.swift`), the receiving app does NOT get sandbox access to that file.

### Error Message
```
NSCocoaErrorDomain Code: 256
Description: Could not open() the item
couldn't issue sandbox extension com.apple.app-sandbox.read: Operation not permitted
```

### What We Tried
1. **Full Disk Access** - Does not help. Security-scoped bookmarks require user-initiated file access, not just disk permissions.
2. **Creating bookmark without security scope** - The bookmark can be created but cannot be used for drag operations.
3. **Using NSURL directly as pasteboard writer** - Receiving apps cannot access the file due to sandbox.

## Current Solution

File paths provided as text are stored as plain text items, not file items. Users who want to add files should drag them directly from Finder.

## Future Possibilities

1. **NSOpenPanel confirmation** - When detecting a file path, prompt user to confirm via file picker to gain sandbox access.
2. **Disable sandbox** - Not recommended for App Store distribution.
3. **Helper tool** - Use a non-sandboxed helper process (complex).

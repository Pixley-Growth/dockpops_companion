## DockPops Companion 1.5.1

- Clamps the companion utility window to a sane maximum size on launch so stale restored frames cannot reopen as an extremely tall window.
- Clears all saved companion window-frame keys instead of only the expected `main` key, covering SwiftUI/AppKit restoration variants seen on macOS 15.
- Fills the entire window with the opaque system background so oversized or restored windows never expose desktop content around the main view.

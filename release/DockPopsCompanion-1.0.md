## DockPops Companion 1.0

- Dynamic poplet icons now stay in sync more reliably, both for running poplets and for the on-disk app icons Finder and the Dock pick up later.
- The companion now reacts to shared-container changes automatically, so pop updates do not depend on a dead polling path or a lucky manual refresh.
- Poplet bundle updates are safer: writes are staged, replacements are cleaner, and bundle-signing work is better guarded against race conditions.

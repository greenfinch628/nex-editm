# nex-editm - 0.3

- 2026-10-29T16:35:18Z — Changed: Double-clicking a sidebar folder enters it; disclosure arrows still expand contents. Added a Down arrow beside Up to enter a selected subfolder.

- 2026-10-29T16:30:55Z — Changed: Placed the main sidebar Up arrow before the folder name on the left; Refresh and Close remain on the right.

- 2026-10-29T16:29:45Z — Added: Parent-folder Up arrow beside Refresh in the main editor sidebar, opening the parent folder with its files and expandable subfolders.

- 2026-10-29T16:18:50Z — Added: Up arrow in the Open sidebar to browse the parent directory as a tree containing files and expandable subfolders. Sidebar files can be selected or opened directly.

- 2026-10-29T16:05:41Z — Added: Folders-style Open window with expandable navigation, striped file details, history, parent navigation, clickable path, hidden files, Go to Folder, and folder creation.

- 2026-10-29T15:46:36Z — Fixed: Always offer to save modified tabs before closing, including unnamed tabs; cancelled or failed saves keep the tab open.
- 2026-10-29T15:46:36Z — Added: Folder creation in the Open dialog and a New Folder menu action that opens the created folder in the sidebar.
- 2026-10-29T15:46:36Z — Changed: Removed the redundant arrow beside Open.

- 2026-10-17T13:42:58Z — Changed: Validated the Miller source build and installation; all 157 self-tests passed, including spelling hit boundaries. Standardized GitHub/Gitea remote names and documented continued development from Miller.
- 2026-10-17T13:42:07Z — Fixed: Set the nex-editm product name on the app target instead of overriding dependency product names, allowing fresh Xcode builds to retain the Highlighter resource bundle. Build and validation assisted by OpenAI Codex.
- 2026-10-16T20:52:52Z — Fixed: Show spelling suggestions only when clicking a character inside a misspelled word, including its first and last letters, rather than nearby whitespace. Added boundary and Unicode hit-testing self-tests. Validated on Miller on 2026-10-17: build, all 157 self-tests, signing, and installation succeeded.
- 2026-10-15T22:26:23Z — Changed: Clarified as-is availability, absence of technical support, and discretionary consideration of bug reports and enhancements without implementation commitments.

- 2026-10-15T22:21:55Z — Added: Source build-and-install command with optional tests, signature verification, and previous-app backup; documented clean-Mac testing.

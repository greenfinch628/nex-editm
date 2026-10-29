import AppKit

func runSelfTests() {
    setbuf(stdout, nil)
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1; print("PASS: \(message)")
    }
    let oldGitPreference = UserDefaults.standard.object(forKey: "showGitStatus")
    defer { UserDefaults.standard.set(oldGitPreference, forKey: "showGitStatus") }
    let oldRecent = UserDefaults.standard.object(forKey: "recentItems")
    defer { UserDefaults.standard.set(oldRecent, forKey: "recentItems") }
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("medit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecoveryStore(directory: folder)
        let docs = [EditorDocument(title: "Untitled Document 1", text: "α emoji 🐦\nunsaved", cursor: 3), EditorDocument(title: "code.swift", path: "/tmp/example.swift", text: "let x = 2", savedText: "let x = 1")]
        let session = EditorSession(documents: docs, activeIndex: 1, workspace: "/tmp/workspace")
        try store.save(session)
        let restored = try store.load()!
        check(restored.documents[0].text == docs[0].text, "Unicode untitled recovery")
        check(restored.documents[1].dirty && restored.documents[1].savedText == "let x = 1", "Modified file recovery remains unsaved")
        check(restored.activeIndex == 1 && restored.workspace == "/tmp/workspace", "Active tab and folder restoration")
        try store.archive(docs[0])
        let archives = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Closed Tabs").path)
        check(archives.count == 1, "Closed untitled tab archived")
        var updated = session; updated.documents[0].text = "newer recovery"; try store.save(updated)
        try Data("broken JSON".utf8).write(to: store.sessionURL)
        let fallback = try store.load()!
        check(fallback.documents[0].text == docs[0].text, "Corrupt latest snapshot falls back to previous recovery")
        let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        check(recoveryFiles.contains(where: { $0.hasPrefix("session.corrupt-") }), "Corrupt snapshot preserved for diagnosis")
        var colorDoc = EditorDocument(title: "color", text: "draft")
        colorDoc.tabWidth = 8; colorDoc.insertSpaces = true; colorDoc.tabColor = "#d4edda"
        let colorRoundTrip = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(colorDoc))
        check(colorRoundTrip.tabWidth == 8 && colorRoundTrip.insertSpaces == true && colorRoundTrip.tabColor == "#d4edda", "Tab width, spaces and tab color survive recovery encoding")
        check(NSColor(hexString: "#d4edda") != nil && NSColor(hexString: "broken") == nil, "Tab color parser accepts shared hex colors and rejects invalid colors")
        let spacesView = BlockTextView(); spacesView.string = "a"; spacesView.setSelectedRange(NSRange(location: 1, length: 0)); spacesView.tabWidth = 4; spacesView.insertSpaces = true
        spacesView.insertTab(nil); check(spacesView.string == "a   ", "Insert Spaces uses the next configurable tab stop")
        spacesView.insertSpaces = false; spacesView.insertTab(nil); check(spacesView.string == "a   \t", "Disabling Insert Spaces keeps literal tabs")
        let view = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = false; view.allowsUndo = true; view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.string = "abc\ndef"; view.blockRanges = [NSRange(location: 1, length: 1), NSRange(location: 5, length: 1)]; view.rowPadding = [0,0]
        view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(view.string == "aXc\ndXf", "Rectangular replacement edits every row")
        view.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(view.string == "aXYc\ndXYf", "Repeated column typing retains multiple carets")
        view.blockRanges = [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)]
        view.insertText("1\n2", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(view.string == "a1c\nd2f", "Multiline block paste maps rows")
        view.string = "a\nb"; view.blockRanges = [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)]; view.rowPadding = [2,2]
        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(view.string == "a  z\nb  z", "Short rows padded for column insertion")
        let d = AppDelegate(); d.documents = [EditorDocument(title: "sample.swift", path: "/tmp/sample.swift", text: "let value = 42 // comment")]; d.editor.string = d.documents[0].text; d.highlight()
        var range = NSRange()
        let color = d.editor.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: &range)
        check(color != nil && d.language.stringValue == "Swift", "Syntax colors use temporary attributes and detect file type")
        check(d.editor.string == "let value = 42 // comment", "Highlighting leaves document contents untouched")
        let syntaxDocuments = d.documents
        d.documents = [EditorDocument(title: "Untitled Document 1")]
        d.editor.string = ""
        d.editor.typingAttributes[.foregroundColor] = NSColor.systemPink
        d.highlight()
        check((d.editor.typingAttributes[.foregroundColor] as? NSColor)?.hexString == NSColor.black.hexString, "Empty untitled document resets inherited typing color to black")
        d.editor.insertText("plain text", replacementRange: NSRange(location: 0, length: 0))
        d.highlight()
        check((d.editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.hexString == NSColor.black.hexString, "Typing in untitled document stays black before switching tabs")
        check(d.editor.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil, "Untitled plain text has no syntax color")
        d.documents = syntaxDocuments; d.editor.string = syntaxDocuments[0].text; d.highlight()
        let correctionView = BlockTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)); correctionView.isRichText = false; correctionView.allowsUndo = true; correctionView.string = "hello speling"
        correctionView.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        for prefix in ["hello ", "café 🐦 ", ""] {
            correctionView.string = prefix + "speling tail\n"
            let misspelled = (correctionView.string as NSString).range(of: "speling")
            correctionView.spellingRanges = [misspelled]
            let layout = correctionView.layoutManager!, container = correctionView.textContainer!
            layout.ensureLayout(for: container)
            func glyphBounds(_ character: Int) -> NSRect {
                let glyph = layout.glyphIndexForCharacter(at: character)
                var bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                bounds.origin.x += correctionView.textContainerOrigin.x
                bounds.origin.y += correctionView.textContainerOrigin.y
                return bounds
            }
            let first = glyphBounds(misspelled.location), last = glyphBounds(NSMaxRange(misspelled) - 1)
            for bounds in [first, last] {
                for fraction in [0.1, 0.9] {
                    let point = NSPoint(x: bounds.minX + bounds.width * fraction, y: bounds.midY)
                    check(correctionView.spellingRange(at: point) == misspelled, "Spelling hit-test includes both halves of edge letters with Unicode prefixes")
                }
            }
            check(correctionView.spellingRange(at: NSPoint(x: first.minX - 1, y: first.midY)) == nil, "Click just before word does not offer spelling suggestions")
            check(correctionView.spellingRange(at: NSPoint(x: last.maxX + 1, y: last.midY)) == nil, "Click just after word does not offer spelling suggestions")
            check(correctionView.spellingRange(at: NSPoint(x: last.maxX + 150, y: last.midY)) == nil, "Click in trailing blank space does not offer spelling suggestions")
        }
        correctionView.string = "hello speling"
        let correction = NSMenuItem(title: "spelling", action: nil, keyEquivalent: "")
        correction.representedObject = ["range": NSValue(range: NSRange(location: 6, length: 7)), "original": "speling", "replacement": "spelling"]
        correctionView.correctSpelling(correction); check(correctionView.string == "hello spelling", "Spelling suggestion replaces only the clicked word")
        var ignoredCallback = false; correctionView.spellingDidChange = { ignoredCallback = true }
        let ignore = NSMenuItem(title: "× Ignore", action: nil, keyEquivalent: ""); ignore.representedObject = "speling"
        correctionView.ignoreDocumentSpelling(ignore)
        check(correctionView.ignoredSpellingWords.contains("speling") && ignoredCallback, "Ignore updates this document and requests recovery without learning a dictionary word")
        var ignoredDoc = EditorDocument(title: "notes"); ignoredDoc.ignoredSpellingWords = ["speling"]
        let ignoredRoundTrip = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(ignoredDoc))
        check(ignoredRoundTrip.ignoredSpellingWords == ["speling"], "Document-local ignored words survive recovery encoding")
        let swiftDocuments = d.documents
        let swiftText = d.editor.string
        let bashSample = "# comment\nif true; then\n  echo \"hello\" $value 42\nfi"
        d.documents = [EditorDocument(title: "colors.sh", path: "/tmp/colors.sh", text: bashSample)]; d.editor.string = bashSample; d.highlight()
        for (token, expected) in [("# comment", "#5d6c79"), ("if", "#9b2393"), ("hello", "#c41a16")] {
            let position = (bashSample as NSString).range(of: token).location
            let actual = d.editor.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: position, effectiveRange: nil) as? NSColor
            check(actual?.hexString.lowercased() == expected, "Bash uses Xcode Default Light color for \(token)")
        }
        d.documents = swiftDocuments; d.editor.string = swiftText; d.highlight()
        let oldSyntax = UserDefaults.standard.object(forKey: "syntaxHighlighting")
        UserDefaults.standard.set(false, forKey: "syntaxHighlighting"); d.highlight()
        check(d.editor.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil, "Syntax highlighting can be disabled")
        UserDefaults.standard.set(true, forKey: "syntaxHighlighting"); d.highlight()
        check(d.editor.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil, "Syntax highlighting can be enabled with the shared scheme")
        UserDefaults.standard.set(oldSyntax, forKey: "syntaxHighlighting")
        let oldSpelling = UserDefaults.standard.object(forKey: "spellChecking")
        UserDefaults.standard.set(true, forKey: "spellChecking")
        d.documents = [EditorDocument(title: "notes.txt", path: "/tmp/notes.txt", text: "hello qzxqzx")]; d.editor.string = d.documents[0].text; d.highlight()
        check(d.editor.layoutManager!.temporaryAttribute(.underlineStyle, atCharacterIndex: 6, effectiveRange: nil) != nil, "Enabled spelling underlines misspelled prose")
        UserDefaults.standard.set(false, forKey: "spellChecking"); d.highlight()
        check(d.editor.layoutManager!.temporaryAttribute(.underlineStyle, atCharacterIndex: 6, effectiveRange: nil) == nil, "Disabling spelling removes its underline")
        UserDefaults.standard.set(true, forKey: "spellChecking")
        d.documents = [EditorDocument(title: "check.sh", path: "/tmp/check.sh", text: "echo qzxqzx\n# qzxqzx")]; d.editor.string = d.documents[0].text; d.highlight()
        check(d.editor.layoutManager!.temporaryAttribute(.underlineStyle, atCharacterIndex: 5, effectiveRange: nil) == nil && d.editor.layoutManager!.temporaryAttribute(.underlineStyle, atCharacterIndex: 15, effectiveRange: nil) != nil, "Bash spelling checks comments while leaving commands alone")
        UserDefaults.standard.set(oldSpelling, forKey: "spellChecking")
        let workspaceStore = FolderSessionStore(directory: folder)
        let root = folder.appendingPathComponent("tree").workspaceNormalizedURL
        let subdirectory = root.appendingPathComponent("z-folder")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let originalFile = root.appendingPathComponent("a.txt")
        try "original on disk".write(to: originalFile, atomically: true, encoding: .utf8)
        try "nested".write(to: subdirectory.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let children = try FolderNode(url: root, directory: true).children()
        check(children.first?.url.lastPathComponent == "z-folder", "Folder explorer sorts folders before files")
        check(children.contains(where: { $0.url.lastPathComponent == ".hidden" }), "Explorer includes hidden files")
        check(children.first(where: { $0.url.lastPathComponent == "loop" })?.directory == false, "Directory symlinks do not create recursive tree loops")
        var doc = EditorDocument(title: "a.txt", path: originalFile.path, text: "unsaved workspace text", savedText: "original on disk", cursor: 2)
        doc.selectionLength = 4; doc.scrollX = 15
        var workspaceSession = EditorSession(documents: [doc, docs[0]], activeIndex: 0, workspace: root.path)
        workspaceSession.sidebar = SidebarState(width: 285, hidden: false, expandedPaths: [root.path, subdirectory.path], selectedPath: subdirectory.appendingPathComponent("nested.txt").path, scrollY: 0)
        workspaceSession.windowFrame = "{{40, 50}, {900, 650}}"
        let secondFolder = folder.appendingPathComponent("second-tree")
        try workspaceStore.save(workspaceSession)
        let exact = try workspaceStore.load(root.path)!
        check(exact.documents[0].text == "unsaved workspace text" && exact.documents[1].text == docs[0].text, "Folder session includes modified and untitled recovery contents")
        check(exact.documents[0].selectionLength == 4 && exact.documents[0].scrollX == 15 && exact.windowFrame == workspaceSession.windowFrame, "Folder session preserves selection, scroll and window geometry")
        let originalContents = try String(contentsOf: originalFile, encoding: .utf8)
        check(originalContents == "original on disk", "Workspace saving does not overwrite original files")
        var secondSession = workspaceSession; secondSession.workspace = secondFolder.path; secondSession.documents[0].text = "second independent session"
        try workspaceStore.save(secondSession)
        workspaceSession.documents[0].text = "updated first session"
        try workspaceStore.save(workspaceSession)
        let secondUnchanged = try workspaceStore.load(secondFolder.path)!
        check(secondUnchanged.documents[0].text == "second independent session", "Folder sessions retain independent tab snapshots")
        let sidebar = FolderSidebarController(); sidebar.setFolder(root.path, state: exact.sidebar)
        let restoredTree = sidebar.state(width: 285, hidden: false)
        check(Set(restoredTree.expandedPaths ?? []) == Set([root.path, subdirectory.path]), "Explorer restores expanded folders")
        sidebar.setFolder(root.path, state: exact.sidebar)
        let alias = root.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        if alias != root.path {
            var aliased = exact.sidebar!; aliased.expandedPaths = aliased.expandedPaths?.map { $0.replacingOccurrences(of: "/private/var/", with: "/var/") }; aliased.selectedPath = aliased.selectedPath?.replacingOccurrences(of: "/private/var/", with: "/var/")
            sidebar.setFolder(alias, state: aliased)
            check(sidebar.state(width: 285, hidden: false).selectedPath == exact.sidebar?.selectedPath, "Alias paths restore the same selected file")
        }
        check(restoredTree.selectedPath == exact.sidebar?.selectedPath, "Explorer restores selected file")
        sidebar.setFolder(root.path, state: SidebarState(expandedPaths: []))
        check(sidebar.state(width: 240, hidden: true).expandedPaths == [], "Collapsed root is restored without reopening it")
        let resizeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let split = WorkspaceSplitViewController(); let side = NSSplitViewItem(viewController: sidebar)
        side.minimumThickness = 160; side.maximumThickness = CGFloat.greatestFiniteMagnitude
        side.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        let content = NSViewController(); content.view = NSView()
        split.addSplitViewItem(side); split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        resizeWindow.contentViewController = split
        resizeWindow.contentView?.layoutSubtreeIfNeeded()
        split.splitView.setPosition(300, ofDividerAt: 0)
        resizeWindow.contentView?.layoutSubtreeIfNeeded()
        check(abs(sidebar.view.frame.width - 300) < 1, "Sidebar accepts a user-selected width")
        side.isCollapsed = true; split.applyPaneState(); resizeWindow.contentView?.layoutSubtreeIfNeeded()
        side.isCollapsed = false; split.applyPaneState(); resizeWindow.contentView?.layoutSubtreeIfNeeded(); split.splitView.setPosition(300, ofDividerAt: 0)
        check(abs(sidebar.view.frame.width - 300) < 1, "Sidebar width can be restored after hiding")
        split.setSidebarWidth(550)
        check(abs(sidebar.view.frame.width - 550) < 1, "Sidebar can expand beyond the former width limit")
        let legacy = try JSONDecoder().decode(EditorSession.self, from: JSONEncoder().encode(session))
        check(legacy.sidebar == nil && legacy.workspaceFile == nil && legacy.documents[0].selectionLength == nil, "Existing recovery sessions remain compatible")
        let controller = AppDelegate()
        controller.store = RecoveryStore(directory: folder.appendingPathComponent("controller"))
        controller.folderStore = FolderSessionStore(directory: controller.store.directory)
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let welcomePreference = UserDefaults.standard.object(forKey: "showWelcomeOnStartup")
        controller.showWelcome()
        check(controller.isWelcome(controller.documents[controller.activeIndex]) && controller.documents[controller.activeIndex].pinned == true, "Welcome opens pinned")
        controller.editor.string += "\n// personal Welcome edit"; controller.captureDocument()
        controller.togglePin(at: controller.activeIndex)
        check(!controller.documents.contains(where: controller.isWelcome) && !UserDefaults.standard.bool(forKey: "showWelcomeOnStartup"), "Unpin removes Welcome and disables startup")
        let closedWelcome = try FileManager.default.contentsOfDirectory(at: controller.store.directory.appendingPathComponent("Closed Tabs"), includingPropertiesForKeys: nil)
        let keptWelcomeEdits = try closedWelcome.contains { try String(contentsOf: $0).contains("personal Welcome edit") }
        check(keptWelcomeEdits, "Dismissing Welcome archives unsaved edits")
        controller.setWelcomeEnabled(true)
        check(controller.documents.contains(where: controller.isWelcome), "Enabling Welcome shows it again")
        controller.setWelcomeEnabled(false)
        check(!controller.documents.contains(where: controller.isWelcome), "Disabling Welcome removes its tab")
        UserDefaults.standard.set(welcomePreference, forKey: "showWelcomeOnStartup")
        controller.openFolder(root)
        let renameSource = root.appendingPathComponent("rename-source.txt")
        try "saved rename text".write(to: renameSource, atomically: true, encoding: .utf8)
        controller.openFile(renameSource)
        let renameID = controller.documents[controller.activeIndex].id
        controller.editor.string = "unsaved rename edit"; controller.captureDocument()
        try controller.store.archive(controller.documents[controller.activeIndex])
        try controller.renameDocument(renameID, to: "renamed.md")
        let renameTarget = root.appendingPathComponent("renamed.md")
        let renameDisk = try String(contentsOf: renameTarget)
        check(!FileManager.default.fileExists(atPath: renameSource.path) && renameDisk == "saved rename text", "Tab rename moves file without saving pending edits")
        check(controller.documents[controller.activeIndex].path == renameTarget.path && controller.documents[controller.activeIndex].dirty && controller.editor.string == "unsaved rename edit", "Renaming preserves unsaved document and updates tab path")
        let renameArchives = try FileManager.default.contentsOfDirectory(at: controller.store.directory.appendingPathComponent("Closed Tabs"), includingPropertiesForKeys: nil)
        let renamedArchive = try renameArchives.contains { url in
            let data = try Data(contentsOf: url)
            return (try? JSONDecoder().decode(EditorDocument.self, from: data).path) == renameTarget.path
        }
        check(renamedArchive, "Rename updates archived recovery paths")
        let collisionURL = root.appendingPathComponent("rename-taken.txt")
        try "keep me".write(to: collisionURL, atomically: true, encoding: .utf8)
        var refusedRename = false
        do { try controller.renameDocument(renameID, to: collisionURL.lastPathComponent) } catch { refusedRename = true }
        let collisionText = try String(contentsOf: collisionURL)
        check(refusedRename && collisionText == "keep me", "Rename refuses an existing destination")
        controller.newDocument(); controller.editor.string = "new named draft 🐦"; controller.captureDocument()
        try controller.renameDocument(controller.documents[controller.activeIndex].id, to: "new named draft.txt")
        let namedDraft = root.appendingPathComponent("new named draft.txt")
        let namedDraftText = try String(contentsOf: namedDraft)
        check(namedDraftText == "new named draft 🐦" && !controller.documents[controller.activeIndex].dirty && controller.documents[controller.activeIndex].path == namedDraft.path, "Naming an untitled document saves it in the sidebar folder")
        let sidebarSource = root.appendingPathComponent("sidebar-closed.txt")
        try "sidebar disk".write(to: sidebarSource, atomically: true, encoding: .utf8)
        let sidebarCount = controller.documents.count
        try controller.renameSidebarFile(sidebarSource, to: "sidebar-renamed.txt")
        let sidebarTarget = root.appendingPathComponent("sidebar-renamed.txt")
        check(FileManager.default.fileExists(atPath: sidebarTarget.path) && !FileManager.default.fileExists(atPath: sidebarSource.path) && controller.documents.count == sidebarCount, "Sidebar renames a closed file without opening a tab")
        try controller.deleteSidebarFile(sidebarTarget, confirmed: false)
        check(FileManager.default.fileExists(atPath: sidebarTarget.path), "Cancelling sidebar Delete leaves file intact")
        controller.openFile(sidebarTarget); controller.editor.string = "unsaved sidebar edit"; controller.captureDocument()
        var failedTrash = false
        do { try controller.deleteSidebarFile(sidebarTarget, confirmed: true, trash: { _ in throw CocoaError(.fileWriteNoPermission) }) } catch { failedTrash = true }
        check(failedTrash && FileManager.default.fileExists(atPath: sidebarTarget.path) && controller.documents[controller.activeIndex].path == sidebarTarget.path, "Trash failure preserves file and tab identity")
        let trashFixture = root.appendingPathComponent("trash-fixture.txt")
        try controller.deleteSidebarFile(sidebarTarget, confirmed: true, trash: { try FileManager.default.moveItem(at: $0, to: trashFixture) })
        let trashedText = try String(contentsOf: trashFixture)
        check(!FileManager.default.fileExists(atPath: sidebarTarget.path) && trashedText == "sidebar disk" && controller.documents[controller.activeIndex].path == nil && controller.documents[controller.activeIndex].dirty && controller.editor.string == "unsaved sidebar edit", "Confirmed Delete preserves disk copy in Trash and open edits as unsaved")
        let deletedSnapshot = try controller.store.load()!
        check(deletedSnapshot.documents.contains { $0.path == nil && $0.text == "unsaved sidebar edit" }, "Deleted file edits remain in recovery without recreating the old path")
        controller.closeFolder()
        controller.recoveryTimer?.invalidate()
        defer { controller.window.orderOut(nil) }
        controller.editor.string = "loose unsaved draft"; controller.captureDocument()
        controller.openFolder(root)
        check(controller.workspace == root.path && !controller.sidebarItem.isCollapsed, "Opening a folder selects its session and shows sidebar")
        controller.openFile(originalFile)
        let fileID = controller.documents[controller.activeIndex].id
        controller.openFile(originalFile)
        check(controller.documents.filter { $0.id == fileID }.count == 1, "Opening an existing file selects its tab without duplication")
        controller.editor.string = "unsaved folder edit"; controller.editor.setSelectedRange(NSRange(location: 7, length: 0))
        controller.newDocument(); controller.editor.string = "folder draft 🐦"; controller.captureDocument()
        controller.togglePin(at: controller.documents.firstIndex { $0.id == fileID }!)
        let firstIDs = controller.documents.map(\.id)
        check(controller.documents.first?.id == fileID && controller.editor.string == "folder draft 🐦", "Pinning places tab first and preserves active document and contents")
        controller.sidebarController.hideSidebar()
        check(controller.sidebarItem.isCollapsed && controller.editor.string == "folder draft 🐦", "Hiding sidebar preserves draft contents")
        controller.toggleWorkspaceSidebar()
        check(!controller.sidebarItem.isCollapsed && controller.documents.map(\.id) == firstIDs, "Showing sidebar preserves tabs and order")
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        controller.openFolder(secondFolder)
        controller.editor.string = "second folder draft"; controller.captureDocument()
        controller.openFolder(root)
        check(controller.documents.map(\.id) == firstIDs && controller.editor.string == "folder draft 🐦", "Switching folders restores tab order, active tab and untitled draft")
        check(controller.documents.first { $0.id == fileID }?.cursor == 7, "Folder restoration preserves inactive document cursor")
        check(controller.documents.first { $0.id == fileID }?.text == "unsaved folder edit", "Folder switching preserves unsaved original edits")
        controller.openFolder(root)
        check(controller.documents.map(\.id) == firstIDs, "Reopening active folder does not reset or duplicate tabs")
        check(controller.documents.first { $0.id == fileID }?.pinned == true, "Folder switching restores pinned tabs")
        let folderMenu = controller.sidebarController.makeFolderMenu()!
        check(folderMenu.items.map(\.title) == ["Close Folder"], "Folder title context menu offers Close Folder")
        let folderAction = folderMenu.items[0]
        _ = NSApp.sendAction(folderAction.action!, to: folderAction.target, from: folderAction)
        check(!controller.sidebarItem.isCollapsed && controller.sidebarController.root == nil && controller.sidebarController.outline.numberOfRows == 0, "Folder title Close Folder leaves sidebar visible and empty")
        check(controller.sidebarController.makeFolderMenu() == nil, "Empty sidebar has no folder close menu")
        check(controller.workspace == nil && controller.editor.string == "loose unsaved draft", "Closing folder restores loose draft session")
        let closeItem = NSMenuItem(title: "Close Folder", action: #selector(AppDelegate.closeFolder), keyEquivalent: "")
        check(!controller.validateMenuItem(closeItem), "Close Folder disabled without a folder")
        controller.openFolder(root)
        check(controller.documents.map(\.id) == firstIDs, "Close Folder preserves folder session for reopening")
        check(controller.documents.first { $0.id == fileID }?.pinned == true, "Close Folder and reopening preserve pin state")
        let diskAfterSwitch = try String(contentsOf: originalFile, encoding: .utf8)
        check(diskAfterSwitch == "original on disk", "Switching and closing folders never writes unsaved changes to originals")
        controller.activeIndex = controller.documents.firstIndex { $0.id == fileID }!; controller.loadActiveDocument()
        check(controller.save(index: controller.activeIndex, asNew: false), "Save writes the active named document")
        let saved = try String(contentsOf: originalFile, encoding: .utf8)
        check(saved == "unsaved folder edit" && !controller.documents[controller.activeIndex].dirty, "Save updates disk and clears modified state")
        controller.persistSession()
        let restarted = try controller.store.load()!
        check(restarted.documents.last?.text == "folder draft 🐦" && restarted.activeIndex == controller.activeIndex, "Quit snapshot preserves untitled draft and active document")
        check(restarted.documents.first { $0.id == fileID }?.pinned == true, "Restart recovery preserves pinned tabs")
        controller.togglePin(at: controller.activeIndex)
        check(controller.documents[controller.activeIndex].pinned == false, "Pinned tabs can be unpinned")
        check(legacy.documents.allSatisfy { $0.pinned == nil }, "Existing sessions without pin metadata remain compatible")
        let renamed = folder.appendingPathComponent("renamed.txt")
        controller.chooseSaveLocation = { _ in renamed }
        check(controller.save(index: controller.activeIndex, asNew: true), "Save As accepts a chosen filename and location")
        let renamedText = try String(contentsOf: renamed, encoding: .utf8)
        check(renamedText == "unsaved folder edit" && controller.documents[controller.activeIndex].path == renamed.path, "Save As writes chosen file and updates active tab")
        controller.newDocument(); controller.editor.string = "save all new draft"; controller.captureDocument()
        var requestedNames: [String] = []
        controller.chooseSaveLocation = { document in
            requestedNames.append(document.title)
            return folder.appendingPathComponent(document.title + ".txt")
        }
        controller.saveAllDocuments()
        check(!requestedNames.isEmpty && controller.documents.allSatisfy { !$0.dirty }, "Save All requests filenames for drafts and saves all current-window documents")
        controller.newDocument(); controller.editor.string = "cancelled draft"; controller.captureDocument()
        controller.chooseSaveLocation = { _ in nil }
        controller.saveAllDocuments()
        check(controller.editor.string == "cancelled draft" && controller.documents[controller.activeIndex].path == nil, "Cancelling Save All preserves unsaved draft")
        let beforeCloseTests = controller.sessionSnapshot()
        let oldPrompt = UserDefaults.standard.object(forKey: "promptOnClose")
        defer { UserDefaults.standard.set(oldPrompt, forKey: "promptOnClose") }
        UserDefaults.standard.set(false, forKey: "promptOnClose")
        var closePrompts = 0
        controller.chooseCloseResponse = { _ in closePrompts += 1; return .alertSecondButtonReturn }
        let draftID = controller.documents[controller.activeIndex].id
        controller.closeDocument(controller.activeIndex)
        check(closePrompts == 1 && controller.documents.contains { $0.id == draftID }, "Cancel keeps an unnamed modified tab even with the old prompt preference off")
        controller.chooseCloseResponse = { _ in .alertFirstButtonReturn }
        controller.closeDocument(controller.activeIndex)
        check(controller.documents.contains { $0.id == draftID }, "Cancelling the save dialog keeps a closing draft open")
        let closingURL = folder.appendingPathComponent("saved-on-close.txt")
        controller.chooseSaveLocation = { _ in closingURL }
        controller.closeDocument(controller.activeIndex)
        check(!controller.documents.contains { $0.id == draftID } && (try? String(contentsOf: closingURL)) == "cancelled draft", "Saving on close writes an unnamed draft before removing its tab")
        controller.openFile(closingURL); controller.editor.string = "named edit"; controller.captureDocument()
        controller.chooseCloseResponse = { _ in closePrompts += 1; return .alertSecondButtonReturn }
        controller.closeDocument(controller.activeIndex)
        check(closePrompts == 2 && controller.editor.string == "named edit", "Cancel preserves a named modified tab")
        controller.chooseCloseResponse = { _ in .alertThirdButtonReturn }
        controller.closeDocument(controller.activeIndex)
        check((try? String(contentsOf: closingURL)) == "cancelled draft", "Keep Recovery closes without overwriting the named file")
        controller.chooseCloseResponse = nil
        controller.applySession(beforeCloseTests); controller.persistSession()
        let openTitles = controller.openMenu().items.map(\.title)
        check(openTitles == ["Open…", "Open Recent", "New File", "New Folder…", "New Window", "Close File", "Close Folder"], "Open dropdown has precisely the requested actions")
        let isolatedLoose = FolderSessionStore(directory: controller.store.directory)
        isolatedLoose.looseDirectory = folder.appendingPathComponent("other-window-loose")
        try isolatedLoose.save(EditorSession(documents: [EditorDocument(title: "Other window", text: "independent")], activeIndex: 0))
        let mainLoose = try controller.folderStore.load(nil)!
        check(mainLoose.documents[0].text == "loose unsaved draft", "Independent windows do not overwrite loose draft sessions")
        let activeIDBeforeMove = controller.documents[controller.activeIndex].id
        let firstPinnedID = controller.documents[0].id
        controller.togglePin(at: 0)
        let lastID = controller.documents.last!.id
        controller.togglePin(at: controller.documents.count - 1)
        check(controller.documents[0].id == firstPinnedID && controller.documents[1].id == lastID, "New pin is appended immediately after existing pinned tabs")
        let pinnedOrder = Array(controller.documents.prefix(2).map(\.id))
        controller.moveTab(firstPinnedID, to: controller.documents.count - 1)
        check(Array(controller.documents.prefix(2).map(\.id)) == pinnedOrder, "Pinned tabs cannot be dragged out of their fixed positions")
        let draggedID = controller.documents.last!.id
        controller.moveTab(draggedID, to: 0)
        check(Array(controller.documents.prefix(2).map(\.id)) == pinnedOrder && controller.documents[2].id == draggedID, "Unpinned drag before pinned tabs is clamped after the pinned group")
        check(controller.documents[controller.activeIndex].id == activeIDBeforeMove && controller.editor.string == "cancelled draft", "Reordering preserves active document and unsaved contents")
        let ordered = try controller.folderStore.load(root.path)!
        controller.openFolder(secondFolder); controller.openFolder(root)
        check(controller.documents.map(\.id) == ordered.documents.map(\.id), "Folder restoration preserves pinned group and dragged tab order")
        controller.togglePin(at: 0)
        check(controller.documents.first?.id == lastID && controller.documents[1].id == firstPinnedID && controller.documents[1].pinned == false, "Unpinning moves tab just after remaining pinned tabs")
        var oldOrder = ordered
        oldOrder.documents.reverse()
        let oldActiveID = oldOrder.documents[oldOrder.activeIndex].id
        controller.applySession(oldOrder)
        check(controller.documents.prefix(2).allSatisfy { $0.pinned == true } && controller.documents[controller.activeIndex].id == oldActiveID, "Existing interleaved sessions normalize pinned tabs while preserving active document")
        for _ in 0..<8 { controller.newDocument() }
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let overflowingScroll = controller.tabs.subviews.first as! NSScrollView
        overflowingScroll.tile()
        check(overflowingScroll.horizontalScroller?.isHidden == false, "Overflowing tabs show their horizontal scrollbar")
        check(overflowingScroll.contentView.bounds.height >= 30 && controller.tabItems.arrangedSubviews.allSatisfy { $0.frame.height >= 30 }, "Visible scrollbar does not reduce the requested shorter tab height or clip tab controls")
        let folderFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        check(!folderFiles.contains(where: { $0.hasSuffix("medit-workspace") }), "No workspace file created inside folder")
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .macOSRoman] {
            let sample = "Café — text on macOS and Fedora\r\nSecond line\n"
            let file = folder.appendingPathComponent("encoding-\(encoding.rawValue).txt")
            try sample.write(to: file, atomically: true, encoding: encoding)
            let decoded = try TextFileCodec.read(file)
            check(decoded.text == sample, "Detect text encoding \(encoding.rawValue) without changing newlines")
            try decoded.text.write(to: file, atomically: true, encoding: decoded.encoding)
            let roundTrip = try TextFileCodec.read(file)
            check(roundTrip.text == sample, "Preserve text on encoding-aware save \(encoding.rawValue)")
        }
        let gitFolder = folder.appendingPathComponent("git fixture").workspaceNormalizedURL
        try FileManager.default.createDirectory(at: gitFolder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        func git(_ args: [String]) { check(GitStatusSnapshot.command(args, at: gitFolder.path) != nil, "Git fixture: " + args.prefix(2).joined(separator: " ")) }
        git(["init", "-q"])
        git(["config", "user.name", "medit tests"]); git(["config", "user.email", "tests@example.invalid"])
        git(["config", "core.hooksPath", "/dev/null"])
        for name in ["modified.txt", "staged.txt", "deleted.txt", "old name.txt", "nested/file.txt"] {
            try "baseline".write(to: gitFolder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "ignored.tmp\n".write(to: gitFolder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "--no-gpg-sign", "-m", "fixture"])
        for name in ["modified.txt", "staged.txt", "nested/file.txt"] { try "changed".write(to: gitFolder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        git(["add", "staged.txt"])
        try FileManager.default.removeItem(at: gitFolder.appendingPathComponent("deleted.txt"))
        git(["mv", "old name.txt", "renamed café.txt"])
        try "new".write(to: gitFolder.appendingPathComponent("new file 🐦.txt"), atomically: true, encoding: .utf8)
        try "ignore".write(to: gitFolder.appendingPathComponent("ignored.tmp"), atomically: true, encoding: .utf8)
        let statuses = GitStatusSnapshot.read(folder: gitFolder.path)
        check(statuses.files[gitFolder.appendingPathComponent("modified.txt").path]?.symbol == "M", "Git detects working-tree modifications")
        check(statuses.files[gitFolder.appendingPathComponent("staged.txt").path]?.index == "M", "Git distinguishes staged changes")
        check(statuses.files[gitFolder.appendingPathComponent("deleted.txt").path]?.symbol == "D", "Git detects deletions")
        check(statuses.files[gitFolder.appendingPathComponent("renamed café.txt").path]?.symbol == "R", "Git parses rename destination with spaces and Unicode")
        check(statuses.files[gitFolder.appendingPathComponent("new file 🐦.txt").path]?.symbol == "?", "Git detects Unicode untracked filenames")
        check(statuses.files[gitFolder.appendingPathComponent("ignored.tmp").path] == nil, "Git omits ignored files")
        check(statuses.folders[gitFolder.path] != nil && statuses.folders[gitFolder.appendingPathComponent("nested").path]?.symbol == "M", "Git aggregates changes into folder badges")
        let nestedStatus = GitStatusSnapshot.read(folder: gitFolder.appendingPathComponent("nested").path)
        check(nestedStatus.files[gitFolder.appendingPathComponent("nested/file.txt").path]?.symbol == "M", "Git status works when opening a repository subfolder")
        let conflict = GitStatusSnapshot.parse(Data("UU conflict file.txt\0?? line\nbreak.txt\0".utf8), root: gitFolder)
        check(conflict.files[gitFolder.appendingPathComponent("conflict file.txt").path]?.symbol == "!", "Git shows a distinct conflict badge")
        check(conflict.files[gitFolder.appendingPathComponent("line\nbreak.txt").path]?.symbol == "?", "Git parses filenames containing newlines")
        check(GitStatusSnapshot.read(folder: root.path).files.isEmpty, "Non-Git folders have no badges")
        controller.sidebarController.setFolder(gitFolder.path, state: nil)
        let off = NSButton(); off.state = .off; controller.changeGitStatus(off)
        check(!GitStatusMonitor.preferenceEnabled && !controller.sidebarController.gitStatus.enabled && controller.sidebarController.gitStatus.snapshot.files.isEmpty, "Disabling Git preference immediately hides badges and disables scanning")
        let on = NSButton(); on.state = .on; controller.changeGitStatus(on)
        let gitDeadline = Date().addingTimeInterval(5)
        while controller.sidebarController.gitStatus.snapshot.files.isEmpty && Date() < gitDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        check(GitStatusMonitor.preferenceEnabled && !controller.sidebarController.gitStatus.snapshot.files.isEmpty, "Enabling Git preference asynchronously restores badges")
        let originalGitFile = try String(contentsOf: gitFolder.appendingPathComponent("modified.txt"), encoding: .utf8)
        check(originalGitFile == "changed", "Git scanning leaves original contents unchanged")
        let indexBefore = try Data(contentsOf: gitFolder.appendingPathComponent(".git/index"))
        _ = GitStatusSnapshot.read(folder: gitFolder.path)
        let indexAfter = try Data(contentsOf: gitFolder.appendingPathComponent(".git/index"))
        check(indexBefore == indexAfter, "Git status never writes the repository index")
        UserDefaults.standard.set(oldGitPreference, forKey: "showGitStatus")
        controller.gitTimer?.invalidate()
        let browserRoot = folder.appendingPathComponent("browser-tests").workspaceNormalizedURL
        try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: false)
        let browserChild = browserRoot.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: browserChild, withIntermediateDirectories: false)
        try "file".write(to: browserRoot.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: browserRoot.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        let navigation = OpenBrowserModel(directory: browserRoot)
        try navigation.navigate(browserRoot)
        check(navigation.entries.map(\.lastPathComponent) == ["Child", "sample.txt"], "Open browser sorts folders first and hides dotfiles")
        try navigation.navigate(browserChild); try navigation.step(-1)
        check(navigation.directory.path == browserRoot.path && navigation.historyIndex == 0, "Open browser Back restores previous directory")
        try navigation.step(1)
        check(navigation.directory.path == browserChild.path, "Open browser Forward restores next directory")
        try navigation.step(-1)
        let created = try navigation.createFolder("New Folder")
        check(FileManager.default.fileExists(atPath: created.path) && navigation.entries.contains { $0.path == created.path }, "Open browser creates folders and refreshes the file list")
        do { _ = try navigation.createFolder("New Folder"); check(false, "Duplicate folder rejected") } catch { check(true, "Open browser rejects existing folder names") }
        do { _ = try navigation.createFolder("../escape"); check(false, "Invalid folder rejected") } catch { check(true, "Open browser rejects names outside the current folder") }
        navigation.showsHidden = true; try navigation.navigate(browserRoot)
        check(navigation.entries.contains { $0.lastPathComponent == ".hidden" }, "Open browser can show hidden files")
        try navigation.navigate(created)
        check(navigation.history.last?.path == created.path && navigation.history.count == 2, "New navigation discards stale Forward history")
        do { try navigation.navigate(browserRoot.appendingPathComponent("missing")); check(false, "Missing directory rejected") } catch { check(navigation.directory.path == created.path, "Failed navigation preserves the current directory") }
        let linkedFolder = browserRoot.appendingPathComponent("Linked Child")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: browserChild)
        check(OpenBrowserModel.isFolder(linkedFolder), "Open browser recognizes folder symbolic links")
        try navigation.navigate(linkedFolder)
        check(navigation.directory.path == browserChild.path, "Open browser can navigate into linked folders")
        let browser = OpenBrowserController(directory: FileManager.default.homeDirectoryForCurrentUser)
        browser.window?.makeKeyAndOrderFront(nil)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        check(browser.files.numberOfRows == browser.model.entries.count && browser.tree.numberOfRows > 2, "Open window presents files and expanded Home navigation")
        if let view = browser.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/nex-open-browser-preview.png"))
        }
        browser.window?.orderOut(nil)
        browser.navigate(browserRoot)
        DispatchQueue.main.async { browser.accept() }
        let openedFolder = browser.run()
        check(openedFolder.map(\.path) == [browserRoot.path], "Open with no selection chooses the current folder")
        let selectedFile = browser.model.entries.firstIndex { $0.lastPathComponent == "sample.txt" }!
        browser.files.selectRowIndexes(IndexSet(integer: selectedFile), byExtendingSelection: false)
        DispatchQueue.main.async { browser.accept() }
        check(browser.run().map(\.lastPathComponent) == ["sample.txt"], "Open returns the selected file")
        DispatchQueue.main.async { browser.cancel() }
        check(browser.run().isEmpty, "Cancel returns no files or folders")
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        check(iconURL.flatMap { NSImage(contentsOf: $0) }?.isValid == true, "Packaged application icon decodes correctly")
        print("\(checks) checks passed")
        UserDefaults.standard.set(oldRecent, forKey: "recentItems")
        UserDefaults.standard.set(oldGitPreference, forKey: "showGitStatus")
        exit(0)
    } catch { fatalError("Self-test error: \(error)") }
}

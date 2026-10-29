import AppKit

extension Double { func nonzero(_ fallback: Double) -> Double { self > 0 ? self : fallback } }

enum TextFileCodec {
    static func read(_ url: URL) throws -> (text: String, encoding: String.Encoding) {
        var encoding = String.Encoding.utf8
        let text = try String(contentsOf: url, usedEncoding: &encoding)
        // Keep binary files out of the plain-text editor after Unicode decoding.
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (text, encoding)
    }
}

struct EditorDocument: Codable {
    var id = UUID()
    var title: String
    var path: String?
    var text = ""
    var savedText = ""
    var textEncoding: UInt?
    var cursor = 0
    var scrollY: Double = 0
    var scrollX: Double?
    var selectionLength: Int?
    var diskChanged: Bool?
    var tabWidth: Int?
    var insertSpaces: Bool?
    var tabColor: String?
    var languageOverride: String?
    var ignoredSpellingWords: [String]?
    var pinned: Bool? // Optional for compatibility with existing recovery snapshots.
    var dirty: Bool { text != savedText || diskChanged == true }
}
struct EditorSession: Codable {
    var version = 1
    var documents: [EditorDocument]
    var activeIndex: Int
    var workspace: String?
    var workspaceFile: String?
    var sidebar: SidebarState?
    var windowFrame: String?
}

/// Atomic recovery snapshots are independent of the original documents.
final class RecoveryStore {
    let directory: URL
    var sessionURL: URL { directory.appendingPathComponent("session.json") }
    init(directory override: URL? = nil) {
        directory = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".review") == true ? "medit-next-review" : "medit-", isDirectory: true)
    }
    func load() throws -> EditorSession? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        do { return try JSONDecoder().decode(EditorSession.self, from: Data(contentsOf: sessionURL)) }
        catch {
            try? FileManager.default.copyItem(at: sessionURL, to: directory.appendingPathComponent("session.corrupt-\(UUID().uuidString).json"))
            if let data = try? Data(contentsOf: directory.appendingPathComponent("session.previous.json")), let previous = try? JSONDecoder().decode(EditorSession.self, from: data) { return previous }
            throw error
        }
    }
    func save(_ session: EditorSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        if let previous = try? Data(contentsOf: sessionURL) {
            if previous == data { return }
            try previous.write(to: directory.appendingPathComponent("session.previous.json"), options: .atomic)
        }
        try data.write(to: sessionURL, options: .atomic)
    }
    func archive(_ document: EditorDocument) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Closed Tabs"), withIntermediateDirectories: true)
        let name = "\(document.id.uuidString)-\(Int(Date().timeIntervalSince1970)).json"
        try JSONEncoder().encode(document).write(to: directory.appendingPathComponent("Closed Tabs").appendingPathComponent(name), options: .atomic)
    }
}

extension AppDelegate {
    func report(_ error: Error) { NSAlert(error: error).runModal() }
    func captureDocument() {
        guard !loading, documents.indices.contains(activeIndex) else { return }
        documents[activeIndex].text = editor.string
        documents[activeIndex].ignoredSpellingWords = editor.ignoredSpellingWords.sorted()
        documents[activeIndex].tabWidth = editor.tabWidth
        documents[activeIndex].insertSpaces = editor.insertSpaces
        documents[activeIndex].cursor = editor.selectedRange().location
        documents[activeIndex].selectionLength = editor.selectedRange().length
        documents[activeIndex].scrollX = Double(editor.visibleRect.minX)
        documents[activeIndex].scrollY = Double(editor.visibleRect.minY)
    }
    func persistSession() {
        guard !loading, !documents.isEmpty else { return }
        do {
            let snapshot = sessionSnapshot()
            try folderStore.save(snapshot)
            try store.save(snapshot)
            workspaceSaveError = false
        } catch {
            if !workspaceSaveError { workspaceSaveError = true; report(error) }
        }
    }
    func restoreSession() {
        do {
            if let session = try store.load() { applySession(session) }
        } catch { report(error) }
        if documents.isEmpty { documents = [EditorDocument(title: "Untitled Document 1")]; loadActiveDocument(); applyWorkspaceLayout(nil) }
    }
    func loadActiveDocument() {
        guard documents.indices.contains(activeIndex) else { return }
        loading = true
        editor.blockRanges = []
        editor.breakUndoCoalescing()
        editor.documentUndoManager = undoManagers[documents[activeIndex].id] ?? UndoManager()
        undoManagers[documents[activeIndex].id] = editor.documentUndoManager
        editor.documentUndoManager.disableUndoRegistration()
        editor.textStorage?.setAttributedString(NSAttributedString(string: documents[activeIndex].text, attributes: [.font: editor.font ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)]))
        editor.documentUndoManager.enableUndoRegistration()
        let cursor = min(max(0, documents[activeIndex].cursor), (editor.string as NSString).length)
        editor.setSelectedRange(NSRange(location: cursor, length: min(max(0, documents[activeIndex].selectionLength ?? 0), (editor.string as NSString).length - cursor)))
        editor.scroll(NSPoint(x: max(0, documents[activeIndex].scrollX ?? 0), y: min(documents[activeIndex].scrollY, max(0, editor.bounds.height - (editor.enclosingScrollView?.contentSize.height ?? 0)))))
        editor.enclosingScrollView?.reflectScrolledClipView(editor.enclosingScrollView!.contentView)
        loading = false
        updateWorkspaceTitle()
        let width = documents[activeIndex].tabWidth ?? defaultTabWidth
        editor.tabWidth = [2,4,8].contains(width) ? width : 2
        editor.insertSpaces = documents[activeIndex].insertSpaces ?? UserDefaults.standard.bool(forKey: "insertSpaces")
        editor.ignoredSpellingWords = Set(documents[activeIndex].ignoredSpellingWords ?? [])
        editor.spellingDidChange = { [weak self] in self?.captureDocument(); self?.applySpelling(); self?.persistSession() }
        applyEditorParagraph(); highlight(); rebuildTabs(); refresh(); window.makeFirstResponder(editor)
    }
    func rebuildTabs() {
        for view in tabItems.arrangedSubviews { tabItems.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, doc) in documents.enumerated() {
            let tab = DraggableTabView(); tab.documentID = doc.id; tab.isPinned = doc.pinned == true
            tab.onDrop = { [weak self] id in self?.moveTab(id, to: index) }; tab.wantsLayer = true
            tab.layer?.cornerRadius = 8
            tab.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            tab.layer?.borderWidth = 1; tab.layer?.borderColor = NSColor.separatorColor.cgColor
            tab.layer?.backgroundColor = tabBackground(doc, active: index == activeIndex).cgColor
            tab.menu = tabColorMenu(doc.id)
            let select = DraggableTabButton(title: (doc.dirty ? "*" : "") + doc.title, target: self, action: #selector(selectTab(_:)))
            select.isBordered = false; select.font = tabFont; select.tag = index; select.toolTip = doc.path ?? doc.title
            let tabColor = tabBackground(doc, active: index == activeIndex).usingColorSpace(.sRGB) ?? .white
            let darkness = tabColor.redComponent * 0.299 + tabColor.greenComponent * 0.587 + tabColor.blueComponent * 0.114
            select.attributedTitle = NSAttributedString(string: select.title, attributes: [.font: tabFont, .foregroundColor: darkness < 0.5 ? NSColor.white : NSColor.black])
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(doc.title)")!, target: self, action: #selector(closeTab(_:)))
            close.isBordered = false; close.tag = index; close.isHidden = doc.pinned == true
            let pinTitle = doc.pinned == true ? "Unpin \(doc.title)" : "Pin \(doc.title)"
            let pin = NSButton(image: NSImage(systemSymbolName: doc.pinned == true ? "pin.fill" : "pin", accessibilityDescription: pinTitle)!, target: self, action: #selector(toggleTabPin(_:)))
            pin.isBordered = false; pin.tag = index; pin.toolTip = pinTitle; pin.setAccessibilityLabel(pinTitle)
            select.menu = tab.menu; pin.menu = tab.menu; close.menu = tab.menu
            let foreground = darkness < 0.5 ? NSColor.white : NSColor.black
            let symbolColor = NSImage.SymbolConfiguration(paletteColors: [foreground])
            pin.image = pin.image?.withSymbolConfiguration(symbolColor); close.image = close.image?.withSymbolConfiguration(symbolColor)
            let indicator = NSView(); indicator.wantsLayer = true; indicator.layer?.backgroundColor = (index == activeIndex ? NSColor.systemBlue : NSColor.clear).cgColor
            [select, pin, close, indicator].forEach { tab.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([tab.heightAnchor.constraint(equalToConstant: 30), tab.widthAnchor.constraint(equalToConstant: max(220, min(360, select.intrinsicContentSize.width + 96))), select.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 16), select.centerYAnchor.constraint(equalTo: tab.centerYAnchor), select.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -10), pin.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8), pin.centerYAnchor.constraint(equalTo: tab.centerYAnchor), pin.widthAnchor.constraint(equalToConstant: 18), close.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -14), close.centerYAnchor.constraint(equalTo: tab.centerYAnchor), indicator.leadingAnchor.constraint(equalTo: tab.leadingAnchor), indicator.trailingAnchor.constraint(equalTo: tab.trailingAnchor), indicator.bottomAnchor.constraint(equalTo: tab.bottomAnchor), indicator.heightAnchor.constraint(equalToConstant: 3)])
            tabItems.addArrangedSubview(tab)
        }
        tabItems.layoutSubtreeIfNeeded()
        tabItems.setFrameSize(NSSize(width: tabItems.fittingSize.width, height: 30))
        tabItems.layoutSubtreeIfNeeded()
        if tabItems.arrangedSubviews.indices.contains(activeIndex) { tabItems.scrollToVisible(tabItems.arrangedSubviews[activeIndex].frame) }
    }
    func moveTab(_ id: UUID, to destination: Int) {
        guard let source = documents.firstIndex(where: { $0.id == id }), documents.indices.contains(destination), source != destination, documents[source].pinned != true else { return }
        captureDocument()
        let activeID = documents[activeIndex].id
        let moved = documents.remove(at: source)
        documents.insert(moved, at: max(documents.filter { $0.pinned == true }.count, destination))
        activeIndex = documents.firstIndex { $0.id == activeID } ?? 0
        rebuildTabs(); persistSession()
    }
    @objc func toggleTabPin(_ sender: NSButton) { togglePin(at: sender.tag) }
    func togglePin(at index: Int) {
        guard documents.indices.contains(index) else { return }
        if documents[index].pinned == true && isWelcome(documents[index]) { setWelcomeEnabled(false); return }
        captureDocument()
        let activeID = documents[activeIndex].id
        var document = documents.remove(at: index)
        document.pinned = !(document.pinned ?? false)
        let boundary = documents.filter { $0.pinned == true }.count
        documents.insert(document, at: boundary)
        activeIndex = documents.firstIndex { $0.id == activeID } ?? 0
        rebuildTabs(); persistSession()
    }
    @objc func selectTab(_ sender: NSButton) { captureDocument(); activeIndex = sender.tag; loadActiveDocument(); persistSession() }
    @objc func nextTab() { captureDocument(); activeIndex = (activeIndex + 1) % documents.count; loadActiveDocument() }
    @objc func previousTab() { captureDocument(); activeIndex = (activeIndex + documents.count - 1) % documents.count; loadActiveDocument() }
    @objc func newDocument() {
        captureDocument()
        var number = 1
        while documents.contains(where: { $0.title == "Untitled Document \(number)" }) { number += 1 }
        documents.append(EditorDocument(title: "Untitled Document \(number)")); activeIndex = documents.count - 1
        loadActiveDocument(); persistSession()
    }
    @objc func openDocuments() {
        let browser = OpenBrowserController(directory: workspace.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser)
        for url in browser.run() { openFile(url) }
    }
    @objc func newFolder() {
        let browser = OpenBrowserController(directory: workspace.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser)
        for url in browser.run(createFolder: true) { openFile(url) }
    }
    func openFile(_ suppliedURL: URL) {
        let url = suppliedURL.workspaceNormalizedURL
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { openFolder(url); return }
        captureDocument()
        if let index = documents.firstIndex(where: { $0.path.map { URL(fileURLWithPath: $0).workspaceNormalizedURL.path } == url.path }) { activeIndex = index; loadActiveDocument(); rememberRecent(url, folder: false); persistSession(); return }
        do {
            let decoded = try TextFileCodec.read(url)
            documents.append(EditorDocument(title: url.lastPathComponent, path: url.path, text: decoded.text, savedText: decoded.text, textEncoding: decoded.encoding.rawValue)); activeIndex = documents.count - 1
            loadActiveDocument(); rememberRecent(url, folder: false); persistSession()
        } catch { report(error) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { filenames.forEach { openFile(URL(fileURLWithPath: $0)) }; sender.reply(toOpenOrPrint: .success) }
    @objc func openWorkspace() { openDocuments() }
    @objc func saveAllDocuments() {
        captureDocument()
        for i in documents.indices where documents[i].dirty {
            if !save(index: i, asNew: false) { return }
        }
    }
    @objc func saveDocument() { _ = save(index: activeIndex, asNew: false) }
    @objc func saveAsDocument() { _ = save(index: activeIndex, asNew: true) }
    @discardableResult func save(index: Int, asNew: Bool) -> Bool {
        captureDocument()
        var url = documents[index].path.map { URL(fileURLWithPath: $0) }
        if asNew || url == nil {
            if let chooseSaveLocation {
                guard let chosen = chooseSaveLocation(documents[index]) else { return false }
                url = chosen
            } else {
                let panel = NSSavePanel(); panel.nameFieldStringValue = documents[index].title
                if let workspace { panel.directoryURL = URL(fileURLWithPath: workspace) }
                guard panel.runModal() == .OK else { return false }; url = panel.url
            }
        }
        guard let url else { return false }
        if !asNew, documents[index].path == url.path, let decoded = try? TextFileCodec.read(url), decoded.text != documents[index].savedText {
            let alert = NSAlert(); alert.messageText = "The file has changed on disk."; alert.informativeText = "Replace it with this tab’s recovered contents, or cancel and use Save As to preserve both versions."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        do {
            let encoding = asNew || documents[index].path == nil ? String.Encoding.utf8 : String.Encoding(rawValue: documents[index].textEncoding ?? String.Encoding.utf8.rawValue)
            try documents[index].text.write(to: url, atomically: true, encoding: encoding)
            documents[index].textEncoding = encoding.rawValue
            documents[index].path = url.path; documents[index].title = url.lastPathComponent; documents[index].savedText = documents[index].text; documents[index].diskChanged = false
            rebuildTabs(); highlight(); sidebarController.refreshTree(); persistSession(); return true
        } catch { report(error); return false }
    }
    func approveClose(_ index: Int) -> Bool {
        guard documents.indices.contains(index) else { return false }
        captureDocument()
        guard documents[index].dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to \(documents[index].title)?"
        alert.informativeText = "Keep Recovery closes this tab and retains its contents in the recovery archive."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Keep Recovery")
        let result = chooseCloseResponse?(documents[index]) ?? alert.runModal()
        return result == .alertThirdButtonReturn || (result == .alertFirstButtonReturn && save(index: index, asNew: false))
    }
    @objc func closeActiveTab() { closeDocument(activeIndex) }
    @objc func closeTab(_ sender: NSButton) { closeDocument(sender.tag) }
    func closeDocument(_ index: Int) {
        if documents.indices.contains(index), isWelcome(documents[index]) { setWelcomeEnabled(false); return }
        guard approveClose(index) else { return }
        do { if documents[index].dirty || documents[index].path == nil { try store.archive(documents[index]) } } catch { report(error); return }
        documents.remove(at: index)
        if index < activeIndex { activeIndex -= 1 }
        activeIndex = min(activeIndex, max(0, documents.count - 1))
        if documents.isEmpty { documents = [EditorDocument(title: "Untitled Document 1")] }
        loadActiveDocument(); persistSession()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controllers = [self] + additionalWindows
        for controller in controllers where !controller.windowClosed {
            for i in controller.documents.indices { if !controller.approveClose(i) { return .terminateCancel } }
        }
        do {
            for controller in controllers where !controller.windowClosed { try controller.saveCurrentSessionBeforeSwitch() }
            try saveWindowList()
        } catch { report(error); return .terminateCancel }
        return .terminateNow
    }
    func saveWindowList() throws {
        try FileManager.default.createDirectory(at: delegate.store.directory, withIntermediateDirectories: true)
        let paths = delegate.additionalWindows.filter { !$0.windowClosed }.map { $0.store.directory.path }
        try JSONEncoder().encode(paths).write(to: delegate.store.directory.appendingPathComponent("windows.json"), options: .atomic)
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editor.documentUndoManager }
    @objc func undoEdit() { editor.blockRanges = []; editor.documentUndoManager.undo() }
    @objc func redoEdit() { editor.blockRanges = []; editor.documentUndoManager.redo() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let others = ([delegate] + delegate.additionalWindows).filter { $0 !== self && !$0.windowClosed }
        if others.isEmpty { NSApp.terminate(nil); return false }
        for i in documents.indices { if !approveClose(i) { return false } }
        do {
            try saveCurrentSessionBeforeSwitch(); windowClosed = true
            try saveWindowList(); recoveryTimer?.invalidate(); gitTimer?.invalidate()
            return true
        } catch { windowClosed = false; report(error); return false }
    }
    @objc func showAppMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("Preferences…", #selector(showSettings)), ("Help", #selector(columnHelp)), ("About nex-editm", #selector(showAbout))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc func restoreClosedTab() {
        let panel = NSOpenPanel(); panel.directoryURL = store.directory.appendingPathComponent("Closed Tabs"); panel.message = "Choose a closed-tab recovery copy."
        if panel.runModal() == .OK, let url = panel.url {
            do { var doc = try JSONDecoder().decode(EditorDocument.self, from: Data(contentsOf: url)); doc.id = UUID(); captureDocument(); documents.append(doc); activeIndex = documents.count - 1; loadActiveDocument(); persistSession() } catch { report(error) }
        }
    }
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "nex-editm"]
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    @objc func columnHelp() {
        let alert = NSAlert(); alert.messageText = "Column / block selection"
        alert.informativeText = "Hold Option and drag across the editor to select a rectangle. Type to replace each selected row, or use Copy, Cut, and Paste. Tabs count as two columns; short rows are padded when you type. Press Escape or click normally to leave block mode."
        alert.runModal()
    }
    func applyEditorParagraph() {
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(editor.tabWidth) * ("M" as NSString).size(withAttributes: [.font: editor.font!]).width
        editor.defaultParagraphStyle = paragraph
        editor.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (editor.string as NSString).length))
    }
    func applyFonts() {
        let d = UserDefaults.standard
        editor.font = NSFont(name: d.string(forKey: "editorFont") ?? "Menlo", size: CGFloat(d.double(forKey: "editorSize").nonzero(14.4))) ?? NSFont.monospacedSystemFont(ofSize: 14.4, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(editor.tabWidth) * ("M" as NSString).size(withAttributes: [.font: editor.font!]).width
        editor.defaultParagraphStyle = paragraph
        editor.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (editor.string as NSString).length))
        func visit(_ view: NSView) {
            if let field = view as? NSTextField { field.font = interfaceFont }
            if let button = view as? NSButton { button.font = interfaceFont }
            view.subviews.forEach(visit)
        }
        if let root = window.contentView { visit(root) }; sidebarController.interfaceFont = sidebarFont; rebuildTabs(); highlight(); refresh()
    }
    func isWelcome(_ document: EditorDocument) -> Bool {
        document.path.map { URL(fileURLWithPath: $0).workspaceNormalizedURL.path } == store.directory.appendingPathComponent("Welcome.swift").workspaceNormalizedURL.path
    }
    func dismissWelcome() {
        guard !documents.isEmpty else { return }
        captureDocument()
        let activeID = documents[activeIndex].id
        do {
            for document in documents where isWelcome(document) { try store.archive(document) }
        } catch { report(error); return }
        documents.removeAll(where: isWelcome)
        if documents.isEmpty { documents = [EditorDocument(title: "Untitled Document 1")] }
        activeIndex = documents.firstIndex { $0.id == activeID } ?? 0
        loadActiveDocument(); persistSession()
    }
    func setWelcomeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "showWelcomeOnStartup")
        for controller in [self] + ([delegate] + delegate.additionalWindows).filter({ $0 !== self }) where !controller.windowClosed {
            if !enabled { controller.dismissWelcome() }
            func update(_ view: NSView) {
                if let button = view as? NSButton, button.title == "Show Welcome on startup" { button.state = enabled ? .on : .off }
                view.subviews.forEach(update)
            }
            if let content = controller.settingsWindow?.contentView { update(content) }
        }
        if enabled { showWelcome() }
    }
    @objc func showWelcome() {
        let target = store.directory.appendingPathComponent("Welcome.swift")
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            guard let source = Bundle.main.url(forResource: "Welcome", withExtension: "swift") else { return }
            let supplied = try String(contentsOf: source, encoding: .utf8)
            let previous = supplied.replacingOccurrences(of: "// A familiar place to write, designed to be pleasant to use.\n", with: "")
            if !FileManager.default.fileExists(atPath: target.path) || (try? String(contentsOf: target, encoding: .utf8)) == previous {
                try supplied.write(to: target, atomically: true, encoding: .utf8)
            }
            openFile(target)
            if !documents[activeIndex].dirty && documents[activeIndex].text == previous {
                documents[activeIndex].text = supplied; documents[activeIndex].savedText = supplied; loadActiveDocument()
            }
            if documents[activeIndex].pinned != true { togglePin(at: activeIndex) }
        } catch { report(error) }
    }
    @objc func changeWelcomeStartup(_ sender: NSButton) {
        setWelcomeEnabled(sender.state == .on)
    }
    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "nex-editm Preferences"; w.isReleasedWhenClosed = false
        let tabs = NSTabView(frame: NSRect(x: 16, y: 16, width: 538, height: 408)); tabs.autoresizingMask = [.width, .height]
        let d = UserDefaults.standard
        for title in ["Fonts", "Editing", "Appearance", "Spelling"] {
            let page = NSTabViewItem(identifier: title); page.label = title
            let host = NSView(); page.view = host
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
            host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18), stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 18), stack.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -18)])
            func checkbox(_ label: String, value: Bool, action: Selector) {
                let button = NSButton(checkboxWithTitle: label, target: self, action: action); button.state = value ? .on : .off; stack.addArrangedSubview(button)
            }
            if title == "Fonts" {
                checkbox("Use system interface font", value: d.string(forKey: "interfaceFont") == nil || d.string(forKey: "interfaceFont") == "System" || interfaceFont.fontName.hasPrefix("."), action: #selector(changeSystemFont(_:)))
                for (label, key, fallback) in [("Interface font", "interfaceFont", "System"), ("Interface size", "interfaceSize", "15.3"), ("Tab title size", "tabSize", "15.3"), ("Sidebar size", "sidebarSize", "17.85"), ("Editor font", "editorFont", "Menlo"), ("Editor size", "editorSize", "14.4")] {
                    let caption = NSTextField(labelWithString: label); caption.widthAnchor.constraint(equalToConstant: 150).isActive = true
                    let input = NSTextField(string: d.string(forKey: key) ?? fallback); input.identifier = NSUserInterfaceItemIdentifier(key); input.target = self; input.action = #selector(changeSetting(_:)); input.widthAnchor.constraint(equalToConstant: 290).isActive = true
                    let row = NSStackView(views: [caption, input]); row.spacing = 12; stack.addArrangedSubview(row)
                }
                stack.addArrangedSubview(NSTextField(labelWithString: "Press Return to apply a font or size."))
            } else if title == "Editing" {
                let width = NSPopUpButton(frame: .zero, pullsDown: false); width.addItems(withTitles: ["Default Tab Width: 2", "Default Tab Width: 4", "Default Tab Width: 8"]); width.selectItem(at: [2,4,8].firstIndex(of: defaultTabWidth) ?? 0); width.target = self; width.action = #selector(changeDefaultTabWidth(_:)); stack.addArrangedSubview(width)
                checkbox("Insert spaces by default", value: d.bool(forKey: "insertSpaces"), action: #selector(changeDefaultSpaces(_:)))
                checkbox("Show Git status in sidebar", value: GitStatusMonitor.preferenceEnabled, action: #selector(changeGitStatus(_:)))
                checkbox("Enable syntax highlighting", value: d.object(forKey: "syntaxHighlighting") as? Bool ?? true, action: #selector(changeSyntaxHighlighting(_:)))
                stack.addArrangedSubview(NSTextField(labelWithString: "One fixed scheme; Bash uses Xcode Default Light colors."))
                stack.addArrangedSubview(NSTextField(labelWithString: "Recovery copies are always kept. Bottom controls change this document."))
            } else if title == "Appearance" {
                checkbox("Show Welcome on startup", value: d.object(forKey: "showWelcomeOnStartup") as? Bool ?? true, action: #selector(changeWelcomeStartup(_:)))
                for (label, key) in [("Active Tab Color…", "activeTabColor"), ("Inactive Tab Color…", "inactiveTabColor")] {
                    let color = d.string(forKey: key).flatMap { NSColor(hexString: $0) } ?? (key == "activeTabColor" ? EditorPalette.activeTab : EditorPalette.inactiveTab)
                    let button = NSButton(title: label, target: self, action: #selector(chooseDefaultTabColor(_:))); button.identifier = NSUserInterfaceItemIdentifier(key)
                    let hex = NSTextField(labelWithString: color.hexString); hex.identifier = NSUserInterfaceItemIdentifier(key + "Swatch"); styleColorLabel(hex, color: color)
                    hex.widthAnchor.constraint(equalToConstant: 110).isActive = true; hex.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    let row = NSStackView(views: [button, hex]); row.spacing = 12; stack.addArrangedSubview(row)
                }
                stack.addArrangedSubview(NSTextField(labelWithString: "Right-click a tab to assign its own color."))
            } else {
                checkbox("Enable spell checking", value: d.bool(forKey: "spellChecking"), action: #selector(changeSpelling(_:)))
                stack.addArrangedSubview(NSTextField(labelWithString: "Uses the system English dictionary. Checks prose and Bash comments."))
            }
            tabs.addTabViewItem(page)
        }
        w.contentView?.addSubview(tabs); settingsWindow = w; w.center(); w.makeKeyAndOrderFront(nil)
    }
    @objc func changeSetting(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }
        if key.hasSuffix("Size") {
            guard let size = Double(sender.stringValue), (8...48).contains(size) else { NSSound.beep(); return }; UserDefaults.standard.set(size, forKey: key)
        } else {
            guard sender.stringValue == "System" || NSFont(name: sender.stringValue, size: 16) != nil else { NSSound.beep(); return }; UserDefaults.standard.set(sender.stringValue, forKey: key)
        }
        for controller in [delegate] + delegate.additionalWindows where !controller.windowClosed { controller.applyFonts() }
    }
    @objc func changeGitStatus(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showGitStatus")
        for controller in [delegate] + delegate.additionalWindows + [self] where !controller.windowClosed {
            controller.sidebarController.updateGitPreference()
        }
    }
    /// Apply library colors as temporary display attributes, leaving plain-text storage intact.
    func highlight() {
        guard documents.indices.contains(activeIndex), let layout = editor.layoutManager else { return }
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        // AppKit can carry an insertion color across empty documents and appearances.
        // Keep the stored text and future typing black; syntax colors remain temporary.
        editor.textColor = .black
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        var typing = editor.typingAttributes
        typing[.foregroundColor] = NSColor.black
        editor.typingAttributes = typing
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        let ext = documents[activeIndex].path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let languages = ["swift": "swift", "py": "python", "js": "javascript", "ts": "typescript", "c": "c", "h": "c", "cpp": "cpp", "rs": "rust", "sh": "bash", "bash": "bash", "json": "json", "css": "css", "html": "xml", "xml": "xml", "md": "markdown", "yaml": "yaml", "yml": "yaml", "toml": "ini", "sql": "sql", "rb": "ruby", "go": "go", "java": "java"]
        let override = documents[activeIndex].languageOverride
        let inferred = languages[ext] ?? (editor.string.hasPrefix("#!/bin/bash") || editor.string.hasPrefix("#!/usr/bin/env bash") || editor.string.hasPrefix("#!/bin/sh") ? "bash" : nil)
        guard let name = override == "Plain Text" ? nil : override.map({ $0 == "Bash" ? "bash" : $0.lowercased() }) ?? inferred else { language.stringValue = "Plain Text"; applySpelling(); return }
        language.stringValue = name == "swift" ? "Swift" : name.capitalized
        applySpelling()
        guard UserDefaults.standard.object(forKey: "syntaxHighlighting") as? Bool ?? true else { return }
        guard let highlighter = syntaxHighlighter else { return }
        guard let colored = highlighter.highlight(editor.string, as: name), colored.string == editor.string else { return }
        colored.enumerateAttribute(.foregroundColor, in: full) { color, range, _ in
            if let color = color as? NSColor {
                let palette = ["#a0a1a7": "#57765a", "#a626a4": "#75507b", "#50a14f": "#a35b19", "#986801": "#a40000", "#4078f2": "#204a87", "#e45649": "#204a87", "#c18401": "#204a87"]
                // Xcode Default (Light) Swift token colors applied to Bash categories.
                let xcodeBash = ["#a0a1a7": "#5d6c79", "#a626a4": "#9b2393", "#50a14f": "#c41a16", "#986801": "#1c00cf", "#4078f2": "#326d74", "#e45649": "#326d74", "#c18401": "#6c36a9"]
                let colors = name == "bash" ? xcodeBash : palette
                let shared = NSColor(hexString: colors[color.hexString.lowercased()] ?? (name == "bash" ? "#262626" : "#202020")) ?? .black
                layout.addTemporaryAttribute(.foregroundColor, value: shared, forCharacterRange: range)
            }
        }
    }
}

/// Each tab is a drop target, identified by document ID rather than an index that can change.
final class DraggableTabView: NSView, NSDraggingSource {
    static let tabType = NSPasteboard.PasteboardType("com.greenfinch628.medit.tab")
    var documentID = UUID()
    var isPinned = false
    var onDrop: ((UUID) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.tabType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem(); item.setString(documentID.uuidString, forType: Self.tabType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap); image.addRepresentation(bitmap)
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? DraggableTabView, source.superview === superview else { return [] }
        return .move
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .move,
              let value = sender.draggingPasteboard.string(forType: Self.tabType), let id = UUID(uuidString: value) else { return false }
        onDrop?(id); return true
    }
}

final class DraggableTabButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard let tab = superview as? DraggableTabView, let window else { super.mouseDown(with: event); return }
        if tab.isPinned { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 {
                tab.beginDrag(with: next); return
            }
        }
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

extension AppDelegate {
    var defaultTabWidth: Int { let width = UserDefaults.standard.integer(forKey: "tabWidth"); return [2,4,8].contains(width) ? width : 2 }
    func refreshEditingControls() {
        tabWidthControl.selectItem(at: [2,4,8].firstIndex(of: editor.tabWidth) ?? 0)
        spacesControl.state = editor.insertSpaces ? .on : .off
        spellingControl.state = UserDefaults.standard.bool(forKey: "spellChecking") ? .on : .off
    }
    @objc func changeTabWidth(_ sender: NSPopUpButton) {
        editor.tabWidth = [2,4,8][max(0, sender.indexOfSelectedItem)]
        captureDocument(); applyEditorParagraph(); persistSession(); refresh()
    }
    @objc func changeSpaces(_ sender: NSButton) { editor.insertSpaces = sender.state == .on; captureDocument(); persistSession(); refresh() }
    @objc func changeDefaultTabWidth(_ sender: NSPopUpButton) { UserDefaults.standard.set([2,4,8][max(0, sender.indexOfSelectedItem)], forKey: "tabWidth") }
    @objc func changeDefaultSpaces(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "insertSpaces") }
    @objc func changeSystemFont(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on ? "System" : "Cantarell", forKey: "interfaceFont")
        for controller in [delegate] + delegate.additionalWindows where !controller.windowClosed { controller.applyFonts() }
    }
    func tabBackground(_ doc: EditorDocument, active: Bool) -> NSColor {
        if let hex = doc.tabColor, let color = NSColor(hexString: hex) { return color }
        if let hex = UserDefaults.standard.string(forKey: active ? "activeTabColor" : "inactiveTabColor"), let color = NSColor(hexString: hex) { return color }
        return active ? EditorPalette.activeTab : EditorPalette.inactiveTab
    }
    func tabColorMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "Rename…", action: #selector(renameTab(_:)), keyEquivalent: ""); rename.target = self; rename.representedObject = id.uuidString
        menu.addItem(.separator())
        let color = menu.addItem(withTitle: "Tab Color…", action: #selector(chooseTabColor(_:)), keyEquivalent: ""); color.target = self; color.representedObject = id.uuidString
        let reset = menu.addItem(withTitle: "Use Default Color", action: #selector(resetTabColor(_:)), keyEquivalent: ""); reset.target = self; reset.representedObject = id.uuidString
        return menu
    }
    func renameSidebarFile(_ suppliedURL: URL) {
        let alert = NSAlert(); alert.messageText = "Rename File"
        let field = NSTextField(string: suppliedURL.lastPathComponent); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try renameSidebarFile(suppliedURL, to: field.stringValue) } catch { report(error) }
    }
    func renameSidebarFile(_ suppliedURL: URL, to name: String) throws {
        let source = suppliedURL.workspaceNormalizedURL
        let peers = [self] + ([delegate] + delegate.additionalWindows).filter { $0 !== self && !$0.windowClosed }
        for controller in peers {
            if let document = controller.documents.first(where: { $0.path.map { URL(fileURLWithPath: $0).workspaceNormalizedURL.path } == source.path }) {
                try controller.renameDocument(document.id, to: name); return
            }
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { throw CocoaError(.fileWriteInvalidFileName) }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        if source.path == target.path { return }
        for controller in peers where !controller.documents.isEmpty { try controller.saveCurrentSessionBeforeSwitch() }
        try FileManager.default.moveItem(at: source, to: target)
        for controller in peers {
            try controller.updateRenamedRecovery(in: controller.store.directory, from: source, to: target)
            controller.sidebarController.refreshTree()
        }
        var recent = UserDefaults.standard.array(forKey: "recentItems") as? [[String: String]] ?? []
        recent.removeAll { $0["path"] == source.path }; UserDefaults.standard.set(recent, forKey: "recentItems")
    }
    func deleteSidebarFile(_ suppliedURL: URL) {
        let alert = NSAlert(); alert.messageText = "Delete File?"
        alert.informativeText = "Are you sure you want to move ‘\(suppliedURL.lastPathComponent)’ to Trash? Open copies will be kept as unsaved documents."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try deleteSidebarFile(suppliedURL, confirmed: true) } catch { report(error) }
    }
    func deleteSidebarFile(_ suppliedURL: URL, confirmed: Bool, trash: ((URL) throws -> Void)? = nil) throws {
        guard confirmed else { return }
        let source = suppliedURL.workspaceNormalizedURL
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { throw CocoaError(.fileWriteNoPermission) }
        let peers = ([self] + ([delegate] + delegate.additionalWindows).filter { $0 !== self }).filter { !$0.windowClosed && !$0.documents.isEmpty }
        for controller in peers {
            controller.captureDocument(); try controller.saveCurrentSessionBeforeSwitch()
            for document in controller.documents where document.path.map({ URL(fileURLWithPath: $0).workspaceNormalizedURL.path }) == source.path { try controller.store.archive(document) }
        }
        if let trash { try trash(source) } else { try FileManager.default.trashItem(at: source, resultingItemURL: nil) }
        for controller in peers {
            for index in controller.documents.indices where controller.documents[index].path.map({ URL(fileURLWithPath: $0).workspaceNormalizedURL.path }) == source.path {
                controller.documents[index].path = nil; controller.documents[index].diskChanged = true
            }
            controller.rebuildTabs(); controller.highlight(); controller.sidebarController.refreshTree()
        }
        for controller in peers {
            try controller.saveCurrentSessionBeforeSwitch()
            try controller.detachDeletedRecovery(in: controller.store.directory, deleted: source)
        }
        var recent = UserDefaults.standard.array(forKey: "recentItems") as? [[String: String]] ?? []
        recent.removeAll { $0["path"] == source.path }; UserDefaults.standard.set(recent, forKey: "recentItems")
    }
    func detachDeletedRecovery(in root: URL, deleted: URL) throws {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension == "json" && !file.lastPathComponent.contains(".corrupt-") {
            guard let data = try? Data(contentsOf: file), var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var changed = false
            func update(_ original: [String: Any]) -> [String: Any] {
                var document = original
                if let path = document["path"] as? String, URL(fileURLWithPath: path).workspaceNormalizedURL.path == deleted.path {
                    document["path"] = NSNull(); document["diskChanged"] = true; changed = true
                }
                return document
            }
            if let documents = record["documents"] as? [[String: Any]] { record["documents"] = documents.map(update) } else { record = update(record) }
            if changed { try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: file, options: .atomic) }
        }
    }
    @objc func renameTab(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text), let index = documents.firstIndex(where: { $0.id == id }) else { return }
        if documents[index].path == nil && workspace == nil { _ = save(index: index, asNew: true); return }
        let alert = NSAlert(); alert.messageText = "Rename File"; alert.informativeText = "Enter a file name. Untitled documents are saved in the sidebar folder."
        let field = NSTextField(string: documents[index].path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try renameDocument(id, to: field.stringValue) } catch { report(error) }
    }
    func renameDocument(_ id: UUID, to name: String) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        func invalid(_ message: String) -> NSError { NSError(domain: "medit.rename", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw invalid("Enter a file name without folder separators.") }
        let old = documents[index].path.map { URL(fileURLWithPath: $0).workspaceNormalizedURL }
        guard let directory = old?.deletingLastPathComponent() ?? workspace.map({ URL(fileURLWithPath: $0).workspaceNormalizedURL }) else { throw invalid("Open a folder or use Save As to choose a location.") }
        let target = directory.appendingPathComponent(name)
        if old?.path == target.path { return }
        // Check symlinks too, including dangling links; moveItem also refuses races.
        guard (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil else { throw invalid("A file or folder with that name already exists.") }
        let peers = ([self] + ([delegate] + delegate.additionalWindows).filter { $0 !== self }).filter { !$0.windowClosed && !$0.documents.isEmpty }
        for controller in peers {
            controller.captureDocument()
            if controller.documents.contains(where: { $0.path.map { URL(fileURLWithPath: $0).workspaceNormalizedURL.path } == target.path }) { throw invalid("That file is already open in another tab.") }
            try controller.saveCurrentSessionBeforeSwitch()
        }
        if let old { try FileManager.default.moveItem(at: old, to: target) }
        else {
            let temporary = directory.appendingPathComponent(".medit-new-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try documents[index].text.write(to: temporary, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: temporary, to: target)
            documents[index].savedText = documents[index].text; documents[index].textEncoding = String.Encoding.utf8.rawValue
        }
        for controller in peers {
            for i in controller.documents.indices {
                let path = controller.documents[i].path.map { URL(fileURLWithPath: $0).workspaceNormalizedURL.path }
                if (controller === self && controller.documents[i].id == id) || (old != nil && path == old!.path) {
                    controller.documents[i].path = target.path; controller.documents[i].title = name
                }
            }
            controller.rebuildTabs(); controller.highlight(); controller.sidebarController.refreshTree()
        }
        for controller in peers { try controller.saveCurrentSessionBeforeSwitch() }
        if let old {
            var roots = Set(peers.map { $0.store.directory.path })
            for controller in peers { roots.insert(controller.folderStore.directory.path) }
            for root in roots { try updateRenamedRecovery(in: URL(fileURLWithPath: root), from: old, to: target) }
        }
        if let old {
            var entries = UserDefaults.standard.array(forKey: "recentItems") as? [[String: String]] ?? []
            entries.removeAll { $0["path"].map { URL(fileURLWithPath: $0).workspaceNormalizedURL.path } == old.path }
            UserDefaults.standard.set(entries, forKey: "recentItems")
        }
        rememberRecent(target, folder: false)
    }
    func updateRenamedRecovery(in root: URL, from old: URL, to target: URL) throws {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension == "json" && !file.lastPathComponent.contains(".corrupt-") {
            guard let data = try? Data(contentsOf: file), var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var changed = false
            func update(_ original: [String: Any]) -> [String: Any] {
                var document = original
                if let path = document["path"] as? String, URL(fileURLWithPath: path).workspaceNormalizedURL.path == old.path {
                    document["path"] = target.path; document["title"] = target.lastPathComponent; changed = true
                }
                return document
            }
            if let documents = record["documents"] as? [[String: Any]] { record["documents"] = documents.map(update) }
            else { record = update(record) }
            if var sidebar = record["sidebar"] as? [String: Any], let path = sidebar["selectedPath"] as? String, URL(fileURLWithPath: path).workspaceNormalizedURL.path == old.path {
                sidebar["selectedPath"] = target.path; record["sidebar"] = sidebar; changed = true
            }
            if changed { try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: file, options: .atomic) }
        }
    }
    @objc func chooseTabColor(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text), let doc = documents.first(where: { $0.id == id }) else { return }
        colorDocumentID = id; colorPreferenceKey = nil
        let panel = NSColorPanel.shared; panel.showsAlpha = false; panel.color = tabBackground(doc, active: true); panel.setTarget(self); panel.setAction(#selector(applyTabColor(_:))); panel.makeKeyAndOrderFront(nil)
    }
    @objc func resetTabColor(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text), let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].tabColor = nil; rebuildTabs(); persistSession()
    }
    @objc func chooseDefaultTabColor(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        colorDocumentID = nil; colorPreferenceKey = key
        let panel = NSColorPanel.shared; panel.showsAlpha = false; panel.color = UserDefaults.standard.string(forKey: key).flatMap { NSColor(hexString: $0) } ?? (key == "activeTabColor" ? EditorPalette.activeTab : EditorPalette.inactiveTab)
        panel.setTarget(self); panel.setAction(#selector(applyTabColor(_:))); panel.makeKeyAndOrderFront(nil)
    }
    @objc func applyTabColor(_ sender: NSColorPanel) {
        if let key = colorPreferenceKey {
            UserDefaults.standard.set(sender.color.hexString, forKey: key)
            for controller in [delegate] + delegate.additionalWindows + [self] {
                if let root = controller.settingsWindow?.contentView { controller.updateColorLabel(in: root, key: key, color: sender.color) }
            }
            for controller in [delegate] + delegate.additionalWindows where !controller.windowClosed { controller.rebuildTabs() }
        } else if let id = colorDocumentID, let index = documents.firstIndex(where: { $0.id == id }) {
            documents[index].tabColor = sender.color.hexString; rebuildTabs(); persistSession()
        }
    }
    @objc func showLanguageMenu(_ sender: NSClickGestureRecognizer) {
        let menu = NSMenu()
        for title in ["Automatic", "Plain Text", "Bash", "Markdown"] {
            let item = menu.addItem(withTitle: title, action: #selector(changeLanguage(_:)), keyEquivalent: ""); item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: language.bounds.maxY), in: language)
    }
    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard documents.indices.contains(activeIndex) else { return }
        documents[activeIndex].languageOverride = sender.title == "Automatic" ? nil : sender.title
        highlight(); persistSession()
    }
    @objc func changeSpelling(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "spellChecking")
        for controller in [delegate] + delegate.additionalWindows where !controller.windowClosed { controller.applySpelling(); controller.refresh() }
    }
    func applySpelling() {
        guard let layout = editor.layoutManager else { return }
        let text = editor.string as NSString
        let full = NSRange(location: 0, length: text.length)
        editor.spellingRanges = []
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        editor.isContinuousSpellCheckingEnabled = false
        guard UserDefaults.standard.bool(forKey: "spellChecking") else { return }
        var start = 0
        while start < text.length {
            let range = NSSpellChecker.shared.checkSpelling(of: editor.string, startingAt: start, language: "en_US", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            start = NSMaxRange(range)
            if editor.ignoredSpellingWords.contains(text.substring(with: range).lowercased()) { continue }
            let lineRange = text.lineRange(for: range)
            let prefix = text.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            if language.stringValue == "Bash" {
                var quote: Character?; var escaped = false; var previous: Character?; var comment = false
                for character in prefix {
                    if escaped { escaped = false; previous = character; continue }
                    if character == "\\" && quote != "'" { escaped = true; previous = character; continue }
                    if let open = quote { if character == open { quote = nil } }
                    else if character == "'" || character == "\"" { quote = character }
                    else if character == "#" && (previous == nil || previous!.isWhitespace || previous == ";") { comment = true; break }
                    previous = character
                }
                if !comment { continue }
            }
            if language.stringValue == "Markdown" {
                let before = text.substring(to: range.location)
                if before.components(separatedBy: "```").count % 2 == 0 || before.components(separatedBy: "~~~").count % 2 == 0 || prefix.filter({ $0 == "`" }).count % 2 == 1 { continue }
            }
            editor.spellingRanges.append(range)
            layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, forCharacterRange: range)
            layout.addTemporaryAttribute(.underlineColor, value: NSColor.systemRed, forCharacterRange: range)
        }
    }
}

extension AppDelegate {
    func styleColorLabel(_ label: NSTextField, color: NSColor) {
        label.stringValue = color.hexString; label.drawsBackground = true; label.backgroundColor = color
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        label.textColor = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114 < 0.5 ? .white : .black
        label.alignment = .center; label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    }
    func updateColorLabel(in view: NSView, key: String, color: NSColor) {
        if let label = view as? NSTextField, label.identifier?.rawValue == key + "Swatch" { styleColorLabel(label, color: color) }
        view.subviews.forEach { updateColorLabel(in: $0, key: key, color: color) }
        if let tabs = view as? NSTabView { tabs.tabViewItems.compactMap { $0.view }.forEach { updateColorLabel(in: $0, key: key, color: color) } }
    }
}

extension AppDelegate {
    @objc func changeSyntaxHighlighting(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "syntaxHighlighting")
        for controller in [delegate] + delegate.additionalWindows + [self] where !controller.windowClosed { controller.highlight() }
    }
}

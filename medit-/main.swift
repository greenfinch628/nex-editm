import AppKit
import Highlighter

/// Shared sRGB surface colors for the editor chrome.
enum EditorPalette {
    static func gray(_ value: Int) -> NSColor {
        let component = CGFloat(value) / 255
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }
    static let titleBar = gray(0xD0)
    static let header = gray(0xD8)
    static let sides = gray(0xE0)
    static let activeTab = gray(0xE8)
    static let inactiveTab = gray(0xF8)
    static let workspaceSidebar = gray(0xF8)
}

final class LineGutter: NSView {
    weak var editor: NSTextView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        EditorPalette.sides.setFill(); bounds.fill()
        guard let editor, let layout = editor.layoutManager else { return }
        let font = editor.font ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let lineHeight = layout.defaultLineHeight(for: font)
        let scrollY = editor.visibleRect.minY
        var line = 1; var index = 0
        let text = editor.string as NSString
        repeat {
            let y = CGFloat(line - 1) * lineHeight + editor.textContainerInset.height - scrollY
            if y > bounds.height { break }
            if y + lineHeight >= 0 {
                let label = "\(line)" as NSString
                label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: attrs).width - 12, y: y), withAttributes: attrs)
            }
            if index >= text.length { break }
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            if index == text.length && ![10, 13].contains(Int(text.character(at: text.length - 1))) { break }
            line += 1
        } while index <= text.length
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    var window: NSWindow!
    let editor = BlockTextView()
    let tabs = NSView()
    let tabItems = NSStackView()
    var documents: [EditorDocument] = []
    var activeIndex = 0
    var loading = false
    var undoManagers: [UUID: UndoManager] = [:]
    let language = NSTextField(labelWithString: "Plain Text")
    var recoveryTimer: Timer?
    var gitTimer: Timer?
    var settingsWindow: NSWindow?
    var workspace: String?
    var workspaceSaveError = false
    let sidebarController = FolderSidebarController()
    let workspaceSplit = WorkspaceSplitViewController()
    var sidebarItem: NSSplitViewItem!
    var sidebarWidth: CGFloat = 240
    var store = RecoveryStore()
    var folderStore = FolderSessionStore()
    var windowClosed = false
    var chooseCloseResponse: ((EditorDocument) -> NSApplication.ModalResponse)?
    var chooseSaveLocation: ((EditorDocument) -> URL?)?
    var additionalWindows: [AppDelegate] = []
    let syntaxHighlighter: Highlighter? = {
        let engine = Highlighter(); _ = engine?.setTheme("atom-one-light"); return engine
    }()
    let gutter = LineGutter()
    let position = NSTextField(labelWithString: "Ln 1, Col 1")
    let documentHost = NSView()
    let tabWidthControl = NSPopUpButton(frame: .zero, pullsDown: false)
    let spacesControl = NSButton(checkboxWithTitle: "Spaces", target: nil, action: nil)
    let spellingControl = NSButton(checkboxWithTitle: "Spelling", target: nil, action: nil)
    var colorDocumentID: UUID?
    var colorPreferenceKey: String?
    var tabFont: NSFont { resizedInterfaceFont(UserDefaults.standard.double(forKey: "tabSize").nonzero(15.3)) }
    var sidebarFont: NSFont { resizedInterfaceFont(UserDefaults.standard.double(forKey: "sidebarSize").nonzero(17.85)) }
    func resizedInterfaceFont(_ size: Double) -> NSFont { NSFont(name: interfaceFont.fontName, size: CGFloat(size)) ?? NSFont.systemFont(ofSize: CGFloat(size)) }
    var interfaceFont: NSFont { NSFont(name: UserDefaults.standard.string(forKey: "interfaceFont") ?? "System", size: CGFloat(UserDefaults.standard.double(forKey: "interfaceSize").nonzero(15.3))) ?? NSFont.systemFont(ofSize: CGFloat(UserDefaults.standard.double(forKey: "interfaceSize").nonzero(15.3))) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if self === delegate, let flag = CommandLine.arguments.firstIndex(of: "--session-directory"), CommandLine.arguments.indices.contains(flag + 1) {
            store = RecoveryStore(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            folderStore = FolderSessionStore(directory: store.directory)
        }
        folderStore.looseDirectory = store.directory.appendingPathComponent("Loose Documents")
        NSApp.appearance = NSAppearance(named: .aqua)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self; window.setFrameAutosaveName("MainWindow"); window.title = "nex-editm"; window.titlebarAppearsTransparent = true; window.backgroundColor = EditorPalette.titleBar; window.minSize = NSSize(width: 640, height: 400)
        let rootController = NSViewController(); let root = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 720)); rootController.view = root; window.contentViewController = rootController
        let header = NSView(); header.wantsLayer = true; header.layer?.backgroundColor = EditorPalette.header.cgColor
        let open = button("Open", symbol: "folder"); let new = button("", symbol: "doc.badge.plus"); new.toolTip = "New Tab"; new.setAccessibilityLabel("New Tab")
        let save = button("Save", symbol: "square.and.arrow.down"); let menu = button("", symbol: "line.3.horizontal")
        let sidebarToggle = button("", symbol: "sidebar.left"); sidebarToggle.target = self; sidebarToggle.action = #selector(toggleWorkspaceSidebar); sidebarToggle.toolTip = "Show/Hide Sidebar"
        let left = NSStackView(views: [open, sidebarToggle, new]); left.spacing = 8
        let saveArrow = button("", symbol: "chevron.down"); saveArrow.toolTip = "Save options"; saveArrow.target = self; saveArrow.action = #selector(showSaveMenu(_:))
        let saveGroup = NSStackView(views: [save, saveArrow]); saveGroup.spacing = 0
        let right = NSStackView(views: [saveGroup, menu]); right.spacing = 12
        [left, right].forEach { header.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        tabs.wantsLayer = true; tabs.layer?.backgroundColor = EditorPalette.sides.cgColor
        let tabScroll = NSScrollView(); tabScroll.hasHorizontalScroller = true; tabScroll.scrollerStyle = .legacy; tabScroll.autohidesScrollers = true; tabScroll.drawsBackground = false
        tabItems.orientation = .horizontal; tabItems.spacing = 2; tabItems.alignment = .centerY
        tabScroll.documentView = tabItems; tabs.addSubview(tabScroll); tabScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tabScroll.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), tabScroll.trailingAnchor.constraint(equalTo: tabs.trailingAnchor), tabScroll.topAnchor.constraint(equalTo: tabs.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabs.bottomAnchor)])
        open.target = self; open.action = #selector(showWorkspaceMenu(_:))
        new.target = self; new.action = #selector(newDocument); save.target = self; save.action = #selector(saveDocument)
        menu.target = self; menu.action = #selector(showAppMenu)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = true; scroll.backgroundColor = .white
        editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true; editor.allowsUndo = true; editor.isRichText = false; editor.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular); editor.textColor = .black; editor.backgroundColor = .white
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true; editor.autoresizingMask = []; editor.textContainerInset = NSSize(width: 10, height: 12)
        editor.textContainer?.widthTracksTextView = false; editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 600); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); editor.delegate = self
        scroll.documentView = editor
        gutter.editor = editor
        let gutterScroll = gutter
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self else { return }; self.gutter.needsDisplay = true
        }
        [gutterScroll, scroll].forEach { documentHost.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        let status = NSView(); status.wantsLayer = true; status.layer?.backgroundColor = EditorPalette.sides.cgColor
        tabWidthControl.addItems(withTitles: ["Tab Width: 2", "Tab Width: 4", "Tab Width: 8"])
        tabWidthControl.target = self; tabWidthControl.action = #selector(changeTabWidth(_:))
        spacesControl.target = self; spacesControl.action = #selector(changeSpaces(_:))
        spellingControl.target = self; spellingControl.action = #selector(changeSpelling(_:))
        let languageClick = NSClickGestureRecognizer(target: self, action: #selector(showLanguageMenu(_:))); language.addGestureRecognizer(languageClick)
        let labels: [NSView] = [language, tabWidthControl, spacesControl, spellingControl, position, NSTextField(labelWithString: "INS")]
        labels.forEach { if let field = $0 as? NSTextField { field.font = interfaceFont }; if let button = $0 as? NSButton { button.font = interfaceFont } }
        let statusItems = NSStackView(views: labels); statusItems.spacing = 28; status.addSubview(statusItems); statusItems.translatesAutoresizingMaskIntoConstraints = false
        let editorPane = NSView()
        [tabs, documentHost].forEach { editorPane.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        let editorController = NSViewController(); editorController.view = editorPane
        sidebarController.onCloseFolder = { [weak self] in self?.closeFolder() }
        sidebarController.onHide = { [weak self] in self?.toggleWorkspaceSidebar() }
        sidebarController.onOpenFile = { [weak self] url in self?.openFile(url) }
        sidebarController.onRenameFile = { [weak self] url in self?.renameSidebarFile(url) }
        sidebarController.onDeleteFile = { [weak self] url in self?.deleteSidebarFile(url) }
        sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = 160; sidebarItem.maximumThickness = CGFloat.greatestFiniteMagnitude; sidebarItem.canCollapse = true
        workspaceSplit.splitView.isVertical = true; workspaceSplit.splitView.dividerStyle = .thin
        workspaceSplit.addSplitViewItem(sidebarItem); workspaceSplit.addSplitViewItem(NSSplitViewItem(viewController: editorController))
        sidebarItem.isCollapsed = true
        rootController.addChild(workspaceSplit)
        [header, workspaceSplit.view, status].forEach { root.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 62),
            left.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16), left.centerYAnchor.constraint(equalTo: header.centerYAnchor), right.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16), right.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            workspaceSplit.view.topAnchor.constraint(equalTo: header.bottomAnchor), workspaceSplit.view.leadingAnchor.constraint(equalTo: root.leadingAnchor), workspaceSplit.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), workspaceSplit.view.bottomAnchor.constraint(equalTo: status.topAnchor),
            tabs.topAnchor.constraint(equalTo: editorPane.topAnchor), tabs.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor), tabs.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 34 + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)),
            documentHost.topAnchor.constraint(equalTo: tabs.bottomAnchor), documentHost.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor), documentHost.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor), documentHost.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
            gutterScroll.leadingAnchor.constraint(equalTo: documentHost.leadingAnchor), gutterScroll.topAnchor.constraint(equalTo: documentHost.topAnchor), gutterScroll.bottomAnchor.constraint(equalTo: documentHost.bottomAnchor), gutterScroll.widthAnchor.constraint(equalToConstant: 54),
            scroll.leadingAnchor.constraint(equalTo: gutterScroll.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: documentHost.trailingAnchor), scroll.topAnchor.constraint(equalTo: documentHost.topAnchor), scroll.bottomAnchor.constraint(equalTo: documentHost.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor), status.trailingAnchor.constraint(equalTo: root.trailingAnchor), status.bottomAnchor.constraint(equalTo: root.bottomAnchor), status.heightAnchor.constraint(equalToConstant: 38), statusItems.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -18), statusItems.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        if !window.setFrameUsingName("MainWindow") { window.center() }; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor); NSApp.activate(ignoringOtherApps: true)
        restoreSession()
        if self === delegate, !CommandLine.arguments.contains("--self-test"),
           UserDefaults.standard.object(forKey: "showWelcomeOnStartup") as? Bool ?? true { showWelcome() }
        else if !(UserDefaults.standard.object(forKey: "showWelcomeOnStartup") as? Bool ?? true) { dismissWelcome() }
        applyFonts()
        gitTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.sidebarController.refreshGitStatus() }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.persistSession() }
        refresh()
        if self === delegate, let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.indices.contains(flag + 1) {
            let destination = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let view = self.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: destination, options: .atomic) }
                }
                NSApp.terminate(nil)
            }
        }
        if self === delegate, !CommandLine.arguments.contains("--self-test"),
           let data = try? Data(contentsOf: store.directory.appendingPathComponent("windows.json")),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            for path in paths {
                let child = AppDelegate(); child.store = RecoveryStore(directory: URL(fileURLWithPath: path))
                additionalWindows.append(child)
                child.applicationDidFinishLaunching(notification)
            }
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { buildMenu() }
    func button(_ title: String, symbol: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil); b.font = interfaceFont; b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? symbol : title); b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        b.toolTip = title.isEmpty ? symbol : title; return b
    }
    func textDidChange(_ notification: Notification) { guard !loading else { return }; captureDocument(); highlight(); rebuildTabs(); persistSession(); refresh() }
    func textViewDidChangeSelection(_ notification: Notification) { if !loading { captureDocument() }; refresh() }
    func refresh() {
        let prefix = (editor.string as NSString).substring(to: min(editor.selectedRange().location, (editor.string as NSString).length))
        let lines = prefix.components(separatedBy: "\n")
        position.stringValue = "Ln \(lines.count), Col \((lines.last ?? "").count + 1)"
        gutter.needsDisplay = true
        refreshEditingControls()

    }
    func buildMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit nex-editm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); main.addItem(editItem); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        let undo = edit.insertItem(withTitle: "Undo", action: #selector(undoEdit), keyEquivalent: "z", at: 0); undo.target = self
        let redo = edit.insertItem(withTitle: "Redo", action: #selector(redoEdit), keyEquivalent: "z", at: 1); redo.target = self; redo.keyEquivalentModifierMask = [.command, .shift]
        appMenu.insertItem(withTitle: "About nex-editm", action: #selector(showAbout), keyEquivalent: "", at: 0).target = self
        appMenu.insertItem(withTitle: "Hide nex-editm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h", at: 1)
        let hideOthers = appMenu.insertItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h", at: 2); hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.insertItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "", at: 3)
        appMenu.insertItem(withTitle: "Preferences…", action: #selector(showSettings), keyEquivalent: ",", at: 0).target = self
        appMenu.addItem(withTitle: "Restore Closed Tab…", action: #selector(restoreClosedTab), keyEquivalent: "").target = self
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.insertItem(fileItem, at: 1)
        let file = NSMenu(title: "File"); fileItem.submenu = file
        for (title, action, key) in [("New File", #selector(newDocument), "n"), ("New Folder…", #selector(newFolder), ""), ("New Window", #selector(newWindow), ""), ("Open…", #selector(openDocuments), "o"), ("Save", #selector(saveDocument), "s"), ("Save As…", #selector(saveAsDocument), ""), ("Save All", #selector(saveAllDocuments), ""), ("Close File", #selector(closeActiveTab), "w"), ("Close Folder", #selector(closeFolder), "")] { let item = file.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self }
        let recentItem = file.insertItem(withTitle: "Open Recent", action: nil, keyEquivalent: "", at: 3)
        let recent = NSMenu(); recent.delegate = self; fillRecentMenu(recent); recentItem.submenu = recent
        let find = edit.addItem(withTitle: "Find and Replace…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let next = edit.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g"); next.tag = Int(NSFindPanelAction.next.rawValue)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); main.addItem(viewItem); let view = NSMenu(title: "View"); viewItem.submenu = view
        view.addItem(withTitle: "Show/Hide Sidebar", action: #selector(toggleWorkspaceSidebar), keyEquivalent: "").target = self
        view.addItem(withTitle: "Refresh Folder", action: #selector(refreshWorkspaceSidebar), keyEquivalent: "").target = self
        view.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "").target = self
        view.addItem(withTitle: "Previous Tab", action: #selector(previousTab), keyEquivalent: "").target = self
        view.addItem(withTitle: "Preferences…", action: #selector(showSettings), keyEquivalent: "").target = self
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); main.addItem(windowItem)
        let windows = NSMenu(title: "Window"); windowItem.submenu = windows; NSApp.windowsMenu = windows
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: ""); main.addItem(helpItem); let help = NSMenu(title: "Help"); helpItem.submenu = help
        help.addItem(withTitle: "Column Selection Help", action: #selector(columnHelp), keyEquivalent: "").target = self
        NSApp.mainMenu = main
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else { app.run() }

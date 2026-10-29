import AppKit

extension URL {
    /// Resolve parent aliases (e.g. /var versus /private/var) while retaining a symlink's own filename.
    var workspaceNormalizedURL: URL {
        guard path != "/" else { return self }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let parent = deletingLastPathComponent()
        let resolved = parent.path.withCString { source in buffer.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) != nil } }
        let parentPath = resolved ? String(cString: buffer) : parent.path
        return URL(fileURLWithPath: parentPath).appendingPathComponent(lastPathComponent)
    }
}

struct SidebarState: Codable {
    var width: Double = 240
    var hidden = false
    var expandedPaths: [String]? // nil means expand the root for a newly chosen folder.
    var selectedPath: String?
    var scrollY: Double?
}
/// Folder snapshots live only in application data, with recovery fallback per folder.
final class FolderSessionStore {
    let directory: URL
    var looseDirectory: URL?
    init(directory: URL = RecoveryStore().directory) { self.directory = directory }
    func recovery(for path: String?) -> RecoveryStore {
        if path == nil, let looseDirectory { return RecoveryStore(directory: looseDirectory) }
        let key = path.map { Data(URL(fileURLWithPath: $0).workspaceNormalizedURL.path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") } ?? "loose-documents"
        // A deterministic UUID-sized hash avoids filesystem filename length limits.
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return RecoveryStore(directory: directory.appendingPathComponent("Folder Sessions").appendingPathComponent(String(hash, radix: 16)))
    }
    func load(_ path: String?) throws -> EditorSession? { try recovery(for: path).load() }
    func save(_ session: EditorSession) throws { try recovery(for: session.workspace).save(session) }
}

final class WorkspaceDividerView: NSSplitView {
    override var dividerThickness: CGFloat { 6 }
    override func drawDivider(in rect: NSRect) {
        EditorPalette.sides.setFill(); rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
    }
}

/// Own the native split view directly so pane widths are preserved exactly.
final class WorkspaceSplitViewController: NSViewController, NSSplitViewDelegate {
    let splitView = WorkspaceDividerView()
    var splitViewItems: [NSSplitViewItem] = []
    private var desiredWidth: CGFloat = 240
    private var adjusting = false
    override func loadView() {
        splitView.isVertical = true; splitView.dividerStyle = .thin; splitView.delegate = self
        view = splitView
    }
    func addSplitViewItem(_ item: NSSplitViewItem) {
        _ = view
        splitViewItems.append(item); addChild(item.viewController)
        let pane = item.viewController.view; pane.translatesAutoresizingMaskIntoConstraints = true; pane.autoresizingMask = []
        splitView.addSubview(pane)
        layoutPanes()
    }
    func setSidebarWidth(_ width: CGFloat) { desiredWidth = width; layoutPanes() }
    func applyPaneState() { layoutPanes() }
    private func layoutPanes() {
        guard splitViewItems.count == 2, !adjusting else { return }
        adjusting = true; defer { adjusting = false }
        let first = splitViewItems[0]; let last = splitViewItems[1]
        let total = splitView.bounds.width; let height = splitView.bounds.height
        let hidden = first.isCollapsed
        let width = hidden ? 0 : min(max(first.minimumThickness, desiredWidth), min(first.maximumThickness, max(0, total - 160)))
        let divider = hidden || total <= width ? 0 : min(splitView.dividerThickness, total - width)
        first.viewController.view.isHidden = hidden
        first.viewController.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        last.viewController.view.frame = NSRect(x: width + divider, y: 0, width: max(0, total - width - divider), height: height)
        splitView.needsDisplay = true
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !adjusting, let first = splitViewItems.first, !first.isCollapsed, first.viewController.view.frame.width >= first.minimumThickness else { return }
        desiredWidth = first.viewController.view.frame.width
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitViewItems.first?.minimumThickness ?? 160 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(splitViewItems.first?.maximumThickness ?? 420, max(160, splitView.bounds.width - 160)) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { splitViewItems.first?.isCollapsed ?? true }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard splitViewItems.first?.isCollapsed == false else { return .zero }
        return proposedEffectiveRect.insetBy(dx: -6, dy: 0)
    }
}

final class FolderNode: NSObject {
    let url: URL
    let directory: Bool
    private var cachedChildren: [FolderNode]?
    init(url: URL, directory: Bool) { self.url = url.workspaceNormalizedURL; self.directory = directory }
    func children() throws -> [FolderNode] {
        guard directory else { return [] }
        if let cachedChildren { return cachedChildren }
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [])
        let nodes = try urls.map { child -> FolderNode in
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            return FolderNode(url: child, directory: values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true)
        }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cachedChildren = nodes
        return nodes
    }
}

final class SidebarOutlineView: NSOutlineView {
    var fileContextMenu: ((NSEvent) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { fileContextMenu?(event) }
}

final class FolderTitleField: NSTextField {
    var folderMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { folderMenu?() }
}

final class FolderSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = SidebarOutlineView()
    let parentButton = NSButton()
    let gitStatus = GitStatusMonitor()
    let folderTitle = FolderTitleField(labelWithString: "Folder")
    let message = NSTextField(wrappingLabelWithString: "Choose Open… to open a folder")
    var root: FolderNode?
    var onOpenFile: ((URL) -> Void)?
    var onRenameFile: ((URL) -> Void)?
    var onDeleteFile: ((URL) -> Void)?
    var onHide: (() -> Void)?
    var onCloseFolder: (() -> Void)?
    var onOpenParent: ((URL) -> Void)?
    var interfaceFont = NSFont.systemFont(ofSize: 17) { didSet { if isViewLoaded { let saved = state(width: 240, hidden: false); folderTitle.font = interfaceFont; message.font = interfaceFont; outline.rowHeight = max(26, interfaceFont.pointSize + 10); setFolder(root?.url.path, state: saved) } } }
    private var refreshing = false
    override func loadView() {
        let host = NSView(); host.wantsLayer = true; host.layer?.backgroundColor = EditorPalette.workspaceSidebar.cgColor
        parentButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Open parent folder")
        parentButton.isBordered = false; parentButton.target = self; parentButton.action = #selector(openParentFolder)
        parentButton.toolTip = "Open parent folder"; parentButton.setAccessibilityLabel("Open parent folder")
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh folder")!, target: self, action: #selector(refreshTree))
        refresh.isBordered = false; refresh.toolTip = "Refresh folder"
        let hide = NSButton(title: "×", target: self, action: #selector(hideSidebar))
        hide.isBordered = false; hide.toolTip = "Hide Sidebar"; hide.setAccessibilityLabel("Hide Sidebar")
        folderTitle.font = interfaceFont; folderTitle.lineBreakMode = .byTruncatingMiddle
        folderTitle.folderMenu = { [weak self] in self?.makeFolderMenu() }
        message.font = interfaceFont; message.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files")); column.title = "Files"; outline.addTableColumn(column); outline.outlineTableColumn = column
        column.minWidth = 80; column.resizingMask = .autoresizingMask
        let gitColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("git")); gitColumn.width = 28; gitColumn.minWidth = 28; gitColumn.maxWidth = 28; gitColumn.resizingMask = []; outline.addTableColumn(gitColumn)
        outline.gridStyleMask = []; outline.autoresizesOutlineColumn = false
        outline.fileContextMenu = { [weak self] event in
            guard let self else { return nil }
            let row = self.outline.row(at: self.outline.convert(event.locationInWindow, from: nil))
            guard let node = self.outline.item(atRow: row) as? FolderNode, !node.directory,
                  (try? node.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
            self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let menu = NSMenu()
            for (title, action) in [("Rename…", #selector(self.renameSidebarFile(_:))), ("Delete…", #selector(self.deleteSidebarFile(_:)))] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = node.url
            }
            return menu
        }
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self; outline.target = self; outline.doubleAction = #selector(openDoubleClickedFile)
        outline.rowHeight = 27; outline.indentationPerLevel = 15; outline.backgroundColor = EditorPalette.workspaceSidebar
        outline.selectionHighlightStyle = .regular; outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true; scroll.backgroundColor = EditorPalette.workspaceSidebar
        [folderTitle, parentButton, refresh, hide, scroll, message].forEach { host.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            folderTitle.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12), folderTitle.topAnchor.constraint(equalTo: host.topAnchor, constant: 12), folderTitle.trailingAnchor.constraint(equalTo: parentButton.leadingAnchor, constant: -8),
            parentButton.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -4), parentButton.centerYAnchor.constraint(equalTo: folderTitle.centerYAnchor), parentButton.widthAnchor.constraint(equalToConstant: 24),
            refresh.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -4), hide.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10), hide.centerYAnchor.constraint(equalTo: refresh.centerYAnchor), hide.widthAnchor.constraint(equalToConstant: 24), refresh.centerYAnchor.constraint(equalTo: folderTitle.centerYAnchor), refresh.widthAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: folderTitle.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            message.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12), message.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12), message.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10)
        ])
        let frame = NSView(); frame.wantsLayer = true; frame.layer?.backgroundColor = EditorPalette.sides.cgColor
        frame.addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 16), host.trailingAnchor.constraint(equalTo: frame.trailingAnchor), host.topAnchor.constraint(equalTo: frame.topAnchor), host.bottomAnchor.constraint(equalTo: frame.bottomAnchor)])
        view = frame
        gitStatus.onChange = { [weak self] in self?.reloadGitRows() }
    }
    func makeFolderMenu() -> NSMenu? {
        guard root != nil else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Close Folder", action: #selector(closeSidebarFolder), keyEquivalent: "")
        item.target = self
        return menu
    }
    @objc func openParentFolder() {
        guard let root, root.url.path != "/" else { return }
        onOpenParent?(root.url.deletingLastPathComponent())
    }
    @objc func closeSidebarFolder() { guard root != nil else { return }; onCloseFolder?() }
    func reloadGitRows() {
        let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<2))
    }
    func updateGitPreference() { gitStatus.configure(folder: root?.url.path, enabled: GitStatusMonitor.preferenceEnabled) }
    func refreshGitStatus() { gitStatus.refresh() }
    func setFolder(_ path: String?, state: SidebarState?) {
        _ = view
        refreshing = true
        root = path.map { FolderNode(url: URL(fileURLWithPath: $0).standardizedFileURL, directory: true) }
        folderTitle.stringValue = root?.url.lastPathComponent ?? "Folder"
        folderTitle.toolTip = path
        parentButton.isEnabled = root != nil && root?.url.path != "/"
        message.stringValue = root == nil ? "Choose Open… to open a folder" : ""
        outline.reloadData()
        if let root {
            let paths = state?.expandedPaths ?? [root.url.path]
            for path in paths.sorted(by: { $0.count < $1.count }) { if let node = node(at: path) { outline.expandItem(node) } }
            if let selected = state?.selectedPath, let node = node(at: selected), outline.row(forItem: node) >= 0 {
                outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
            }
        }
        if let y = state?.scrollY { outline.scroll(NSPoint(x: 0, y: max(0, y))) }
        refreshing = false
        updateGitPreference()
    }
    func node(at path: String) -> FolderNode? {
        guard let root else { return nil }
        let target = URL(fileURLWithPath: path).workspaceNormalizedURL.path
        if root.url.path == target { return root }
        let prefix = root.url.path.hasSuffix("/") ? root.url.path : root.url.path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var current = root
        for part in target.dropFirst(prefix.count).split(separator: "/") {
            guard let child = try? current.children().first(where: { $0.url.lastPathComponent == String(part) }) else { return nil }
            current = child
        }
        return current
    }
    func state(width: Double, hidden: Bool) -> SidebarState {
        var expanded: [String] = []
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FolderNode, outline.isItemExpanded(node) { expanded.append(node.url.path) }
        }
        let selected = outline.item(atRow: outline.selectedRow) as? FolderNode
        return SidebarState(width: width, hidden: hidden, expandedPaths: expanded, selectedPath: selected?.url.path, scrollY: Double(outline.visibleRect.minY))
    }
    @objc func hideSidebar() { onHide?() }
    @objc func refreshTree() {
        guard !refreshing else { return }
        let saved = state(width: 240, hidden: false)
        setFolder(root?.url.path, state: saved)
    }
    private func children(_ node: FolderNode) -> [FolderNode] {
        do { return try node.children() }
        catch { message.stringValue = "Cannot read \(node.url.lastPathComponent)."; message.toolTip = error.localizedDescription; return [] }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { if let node = item as? FolderNode { return children(node).count }; return root == nil ? 0 : 1 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let node = item as? FolderNode { return children(node)[index] }; return root! }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FolderNode)?.directory ?? false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = NSTableCellView(); let field = NSTextField(labelWithString: node.url.lastPathComponent)
        field.font = interfaceFont; field.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView(); icon.image = NSImage(systemSymbolName: node.directory ? "folder" : "doc.text", accessibilityDescription: node.directory ? "Folder" : "File")
        cell.textField = field; cell.imageView = icon; cell.toolTip = node.url.path
        if tableColumn?.identifier.rawValue == "git" {
            let badge = NSTextField(labelWithString: "")
            badge.font = NSFont.monospacedSystemFont(ofSize: max(11, interfaceFont.pointSize - 2), weight: .semibold); badge.alignment = .center
            if gitStatus.enabled, let status = gitStatus.snapshot.status(for: node.url.path, directory: node.directory) {
                badge.stringValue = status.symbol; badge.textColor = status.color
                let explanation = node.directory ? "Git: changes inside this folder (\(status.symbol))" : status.explanation
                badge.toolTip = explanation; badge.setAccessibilityLabel(explanation); cell.toolTip = node.url.path + "\n" + explanation
            }
            cell.textField = badge; cell.imageView = nil
            cell.addSubview(badge); badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor), badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        [icon, field].forEach { cell.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18), field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    @objc func renameSidebarFile(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onRenameFile?(url) } }
    @objc func deleteSidebarFile(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onDeleteFile?(url) } }
    @objc func openDoubleClickedFile() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FolderNode else { return }
        if node.directory { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } }
        else { onOpenFile?(node.url) }
    }
}

extension AppDelegate {
    func applicationDidBecomeActive(_ notification: Notification) { if window != nil { sidebarController.updateGitPreference(); if workspace != nil { sidebarController.refreshTree() } } }
    func updateWorkspaceTitle() {
        let name = workspace.map { URL(fileURLWithPath: $0).lastPathComponent }
        window.title = name.map { "nex-editm — \($0)" } ?? "nex-editm"
        window.representedURL = workspace.map { URL(fileURLWithPath: $0) }
    }
    func sessionSnapshot() -> EditorSession {
        captureDocument()
        if let sidebarItem, !sidebarItem.isCollapsed { sidebarWidth = sidebarController.view.frame.width }
        let sidebar = sidebarController.state(width: Double(sidebarWidth), hidden: sidebarItem?.isCollapsed ?? true)
        return EditorSession(documents: documents, activeIndex: activeIndex, workspace: workspace, workspaceFile: nil, sidebar: sidebar, windowFrame: window.map { NSStringFromRect($0.frame) })
    }
    func saveCurrentSessionBeforeSwitch() throws {
        let snapshot = sessionSnapshot()
        try folderStore.save(snapshot); try store.save(snapshot)
    }
    func applySession(_ session: EditorSession) {
        loading = true
        let restoredActiveID = session.documents.indices.contains(session.activeIndex) ? session.documents[session.activeIndex].id : nil
        documents = session.documents.filter { $0.pinned == true } + session.documents.filter { $0.pinned != true }
        activeIndex = documents.firstIndex { $0.id == restoredActiveID } ?? 0
        workspace = session.workspace; workspaceSaveError = false
        undoManagers.removeAll()
        for i in documents.indices {
            if let path = documents[i].path, let decoded = try? TextFileCodec.read(URL(fileURLWithPath: path)) {
                if documents[i].textEncoding == nil { documents[i].textEncoding = decoded.encoding.rawValue }
                if !documents[i].dirty { documents[i].text = decoded.text; documents[i].savedText = decoded.text; documents[i].textEncoding = decoded.encoding.rawValue }
            }
        }
        if documents.isEmpty { documents = [EditorDocument(title: "Untitled Document 1")] }
        if let frame = session.windowFrame {
            var rect = NSRectFromString(frame)
            if rect.width.isFinite, rect.height.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width >= 640, rect.height >= 400, let screen = NSScreen.main?.visibleFrame {
                rect.size.width = min(rect.width, screen.width); rect.size.height = min(rect.height, screen.height)
                rect.origin.x = min(max(rect.minX, screen.minX), screen.maxX - rect.width)
                rect.origin.y = min(max(rect.minY, screen.minY), screen.maxY - rect.height)
                window.setFrame(rect, display: true)
            }
        }
        applyWorkspaceLayout(session.sidebar)
        loading = false; loadActiveDocument()
    }
    func applyWorkspaceLayout(_ state: SidebarState?) {
        sidebarController.interfaceFont = sidebarFont
        sidebarController.setFolder(workspace, state: state)
        sidebarWidth = CGFloat(max(160, state?.width ?? 240))
        sidebarItem.isCollapsed = state?.hidden ?? (workspace == nil)
        workspaceSplit.applyPaneState()
        window.contentView?.layoutSubtreeIfNeeded()
        if !sidebarItem.isCollapsed { workspaceSplit.setSidebarWidth(sidebarWidth) }
    }
    @objc func toggleWorkspaceSidebar() {
        if !sidebarItem.isCollapsed { sidebarWidth = sidebarController.view.frame.width }
        sidebarItem.isCollapsed.toggle()
        workspaceSplit.applyPaneState()
        window.contentView?.layoutSubtreeIfNeeded()
        if !sidebarItem.isCollapsed { workspaceSplit.setSidebarWidth(sidebarWidth) }
        persistSession()
    }
    @objc func refreshWorkspaceSidebar() { sidebarController.refreshTree() }
    func openFolder(_ suppliedURL: URL) {
        let url = suppliedURL.workspaceNormalizedURL
        if let other = ([delegate] + delegate.additionalWindows).first(where: { $0 !== self && !$0.windowClosed && $0.workspace == url.path }) {
            other.window.makeKeyAndOrderFront(nil); return
        }
        if workspace == url.path {
            sidebarItem.isCollapsed = false; workspaceSplit.applyPaneState()
            rememberRecent(url, folder: true); persistSession(); return
        }
        // Read before switching so a corrupt destination cannot replace live documents.
        do {
            let restored = try folderStore.load(url.path)
            try saveCurrentSessionBeforeSwitch()
            var session = restored ?? EditorSession(documents: [], activeIndex: 0, workspace: url.path)
            session.sidebar = session.sidebar ?? SidebarState()
            session.sidebar?.hidden = false
            applySession(session)
            rememberRecent(url, folder: true); persistSession()
        } catch { report(error) }
    }
    @objc func closeFolder() {
        guard workspace != nil else { return }
        do {
            let loose = try folderStore.load(nil) ?? EditorSession(documents: [], activeIndex: 0)
            try saveCurrentSessionBeforeSwitch()
            applySession(loose)
            sidebarItem.isCollapsed = false
            workspaceSplit.applyPaneState()
            window.contentView?.layoutSubtreeIfNeeded()
            workspaceSplit.setSidebarWidth(sidebarWidth)
            persistSession()
        } catch { report(error) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeFolder) { return workspace != nil }
        return true
    }
    func rememberRecent(_ url: URL, folder: Bool) {
        var entries = UserDefaults.standard.array(forKey: "recentItems") as? [[String: String]] ?? []
        entries.removeAll { $0["path"] == url.path }
        entries.insert(["path": url.path, "kind": folder ? "Folder" : "File"], at: 0)
        UserDefaults.standard.set(Array(entries.prefix(20)), forKey: "recentItems")
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFile(URL(fileURLWithPath: path))
    }
    func openMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open…", action: #selector(openDocuments), keyEquivalent: "").target = self
        let recent = NSMenu(); let recentItem = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent
        recent.delegate = self
        fillRecentMenu(recent)
        for (title, action) in [("New File", #selector(newDocument)), ("New Folder…", #selector(newFolder)), ("New Window", #selector(newWindow)), ("Close File", #selector(closeActiveTab)), ("Close Folder", #selector(closeFolder))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) { fillRecentMenu(menu) }
    func fillRecentMenu(_ recent: NSMenu) {
        recent.removeAllItems()
        for entry in UserDefaults.standard.array(forKey: "recentItems") as? [[String: String]] ?? [] {
            guard let path = entry["path"] else { continue }
            let item = recent.addItem(withTitle: "\(entry["kind"] ?? "File"): \(URL(fileURLWithPath: path).lastPathComponent)", action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = path; item.toolTip = path
            item.image = NSImage(systemSymbolName: entry["kind"] == "Folder" ? "folder" : "doc.text", accessibilityDescription: entry["kind"])
        }
    }
    @objc func showWorkspaceMenu(_ sender: NSButton) { openMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
    @objc func showSaveMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("Save", #selector(saveDocument)), ("Save As…", #selector(saveAsDocument)), ("Save All", #selector(saveAllDocuments))] { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc func newWindow() {
        let child = AppDelegate()
        child.store = RecoveryStore(directory: store.directory.appendingPathComponent("Windows").appendingPathComponent(UUID().uuidString))
        child.folderStore.looseDirectory = child.store.directory.appendingPathComponent("Loose Documents")
        delegate.additionalWindows.append(child)
        child.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        child.persistSession()
        do { try saveWindowList() } catch { report(error) }
    }
}

/// Read-only Git status. NUL-delimited porcelain keeps spaces, Unicode and renames intact.
struct GitFileStatus {
    let index: Character
    let worktree: Character
    var conflict: Bool { ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(String([index, worktree])) }
    var symbol: String {
        if conflict { return "!" }
        if index == "?" { return "?" }
        for code: Character in ["D", "R", "C", "A", "T", "M"] {
            if index == code || worktree == code { return String(code) }
        }
        return ""
    }
    var priority: Int { ["!", "D", "R", "C", "A", "T", "M", "?"].firstIndex(of: symbol) ?? 8 }
    var color: NSColor {
        switch symbol {
        case "!", "D": return .systemRed
        case "A": return .systemGreen
        case "?": return .secondaryLabelColor
        default: return .systemOrange
        }
    }
    var explanation: String {
        if conflict { return "Git: merge conflict" }
        if index == "?" { return "Git: untracked" }
        func name(_ code: Character) -> String {
            switch code {
            case "M": return "modified"
            case "A": return "added"
            case "D": return "deleted"
            case "R": return "renamed"
            case "C": return "copied"
            case "T": return "type changed"
            default: return "unchanged"
            }
        }
        return "Git — staged: \(name(index)); working tree: \(name(worktree))"
    }
}
struct GitStatusSnapshot {
    var files: [String: GitFileStatus] = [:]
    var folders: [String: GitFileStatus] = [:]
    func status(for path: String, directory: Bool) -> GitFileStatus? { directory ? folders[path] : files[path] }
    static func command(_ arguments: [String], at directory: String) -> Data? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", directory] + arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
    static func read(folder: String) -> GitStatusSnapshot {
        guard let rootData = command(["rev-parse", "--show-toplevel"], at: folder),
              var rootPath = String(data: rootData, encoding: .utf8),
              let data = command(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: folder) else { return GitStatusSnapshot() }
        // Remove only Git's terminating newline; spaces are legal in folder names.
        if rootPath.hasSuffix("\n") { rootPath.removeLast() }
        return parse(data, root: URL(fileURLWithPath: rootPath).workspaceNormalizedURL)
    }
    static func parse(_ data: Data, root: URL) -> GitStatusSnapshot {
        var result = GitStatusSnapshot()
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var i = 0
        while i < records.count {
            let bytes = Array(records[i]); i += 1
            guard bytes.count >= 4 else { continue }
            let index = Character(UnicodeScalar(bytes[0])); let worktree = Character(UnicodeScalar(bytes[1]))
            let relative = String(decoding: bytes.dropFirst(3), as: UTF8.self)
            let status = GitFileStatus(index: index, worktree: worktree)
            let path = root.appendingPathComponent(relative).workspaceNormalizedURL
            result.files[path.path] = status
            var parent = path.deletingLastPathComponent()
            while parent.path == root.path || parent.path.hasPrefix(root.path + "/") {
                if result.folders[parent.path].map({ status.priority < $0.priority }) ?? true { result.folders[parent.path] = status }
                if parent.path == root.path { break }
                parent.deleteLastPathComponent()
            }
            // In -z mode rename/copy records give the new path, then the old path.
            if index == "R" || index == "C" || worktree == "R" || worktree == "C" { i += 1 }
        }
        return result
    }
}

/// Scan off the main thread. Old results cannot leak into another folder or a disabled sidebar.
final class GitStatusMonitor {
    static var preferenceEnabled: Bool { UserDefaults.standard.object(forKey: "showGitStatus") as? Bool ?? true }
    private(set) var snapshot = GitStatusSnapshot()
    private(set) var enabled = false
    private var folder: String?
    private var revision = 0
    private var busy = false
    var onChange: (() -> Void)?
    func configure(folder: String?, enabled: Bool) {
        if self.folder != folder || self.enabled != enabled {
            revision += 1; self.folder = folder; self.enabled = enabled
            snapshot = GitStatusSnapshot(); onChange?()
        }
        refresh()
    }
    func refresh() {
        guard enabled, let folder, !busy else { return }
        busy = true
        let requestedRevision = revision
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = GitStatusSnapshot.read(folder: folder)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.enabled, self.revision == requestedRevision else { self.refresh(); return }
                self.snapshot = result; self.onChange?()
            }
        }
    }
}

// Folder navigation shared by the custom Open window and its regression tests.
final class OpenBrowserModel {
    private(set) var directory: URL
    private(set) var entries: [URL] = []
    private(set) var history: [URL] = []
    private(set) var historyIndex = -1
    var showsHidden = false
    init(directory: URL) { self.directory = directory }
    func navigate(_ url: URL, record: Bool = true) throws {
        let folder = url.resolvingSymlinksInPath().workspaceNormalizedURL
        let values = try folder.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey], options: showsHidden ? [] : [.skipsHiddenFiles])
        entries = contents.sorted {
            let a = Self.isFolder($0), b = Self.isFolder($1)
            return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        directory = folder
        if record && (historyIndex < 0 || history[historyIndex].path != folder.path) {
            history = Array(history.prefix(historyIndex + 1)); history.append(folder); historyIndex = history.count - 1
        }
    }
    static func isFolder(_ url: URL) -> Bool {
        let v = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }
    func step(_ offset: Int) throws {
        let next = historyIndex + offset
        guard history.indices.contains(next) else { return }
        try navigate(history[next], record: false); historyIndex = next
    }
    @discardableResult func createFolder(_ name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try navigate(directory, record: false)
        return url
    }
}

final class OpenBrowserNode: NSObject {
    let url: URL
    let title: String
    var children: [OpenBrowserNode]?
    init(_ url: URL, title: String? = nil) { self.url = url; self.title = title ?? url.lastPathComponent }
    private var cachedHidden = false
    func contents(showsHidden: Bool = false) -> [OpenBrowserNode] {
        guard OpenBrowserModel.isFolder(url) else { return [] }
        if let children, cachedHidden == showsHidden { return children }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: showsHidden ? [] : [.skipsHiddenFiles])) ?? []
        let result = urls.sorted {
            let a = OpenBrowserModel.isFolder($0), b = OpenBrowserModel.isFolder($1)
            return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.map { OpenBrowserNode($0) }
        cachedHidden = showsHidden; children = result; return result
    }
}

final class OpenBrowserController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let model: OpenBrowserModel
    let tree = NSOutlineView()
    let files = NSTableView()
    let path = NSPathControl()
    let location = NSTextField(labelWithString: "Home")
    let back = NSButton(), forward = NSButton(), up = NSButton(), sidebarUp = NSButton()
    let sidebarHeading = NSTextField(labelWithString: "★  Favorites")
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    var result: [URL] = []
    private var roots: [OpenBrowserNode] = []
    private var syncingTree = false
    private let sidebarColor = NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.97, alpha: 1)
    init(directory: URL) {
        model = OpenBrowserModel(directory: directory)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Open — nex-editm"; panel.minSize = NSSize(width: 760, height: 460); panel.delegate = self
        panel.appearance = NSAppearance(named: .aqua)
        buildUI()
        do { try model.navigate(directory) } catch {
            do { try model.navigate(FileManager.default.homeDirectoryForCurrentUser) } catch { showError(error) }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func run(createFolder: Bool = false) -> [URL] {
        guard let window else { return [] }
        result = []
        window.center(); window.makeKeyAndOrderFront(nil)
        if createFolder { DispatchQueue.main.async { [weak self] in self?.newFolder() } }
        NSApp.runModal(for: window); window.orderOut(nil)
        return result
    }
    private func symbolButton(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded; button.target = self; button.action = action
        button.toolTip = label; button.setAccessibilityLabel(label)
    }
    private func buildUI() {
        guard let host = window?.contentView else { return }
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let sidebar = NSView(); sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = sidebarColor.cgColor
        let main = NSView()
        split.addArrangedSubview(sidebar); split.addArrangedSubview(main)
        let favorites = sidebarHeading; favorites.textColor = .secondaryLabelColor; favorites.font = .systemFont(ofSize: 13, weight: .semibold)
        let column = NSTableColumn(identifier: .init("folder")); tree.addTableColumn(column); tree.outlineTableColumn = column
        tree.headerView = nil; tree.dataSource = self; tree.delegate = self; tree.rowHeight = 26; tree.indentationPerLevel = 15
        tree.backgroundColor = sidebarColor; tree.selectionHighlightStyle = .regular; tree.style = .plain
        tree.setAccessibilityLabel("Folder navigation")
        tree.target = self; tree.doubleAction = #selector(activateSidebarFile)
        symbolButton(sidebarUp, "arrow.up", "Show parent directory in sidebar", #selector(goUp))
        let treeScroll = NSScrollView(); treeScroll.documentView = tree; treeScroll.hasVerticalScroller = true; treeScroll.autohidesScrollers = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [OpenBrowserNode(home, title: "Home"), OpenBrowserNode(URL(fileURLWithPath: "/"), title: "This Mac")]
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: cloud.path) { roots.append(OpenBrowserNode(cloud, title: "iCloud Drive")) }
        let volumes = URL(fileURLWithPath: "/Volumes")
        if let mounted = try? FileManager.default.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            roots += mounted.filter { $0.resolvingSymlinksInPath().path != "/" }.map { OpenBrowserNode($0) }
        }
        tree.reloadData(); tree.expandItem(roots[0])
        symbolButton(back, "chevron.left", "Back", #selector(goBack))
        symbolButton(forward, "chevron.right", "Forward", #selector(goForward))
        symbolButton(up, "arrow.up", "Enclosing Folder", #selector(goUp))
        let create = NSButton(title: "New Folder", target: self, action: #selector(newFolder)); create.bezelStyle = .rounded
        create.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        create.imagePosition = .imageLeading; create.toolTip = "Create a new folder"; create.setAccessibilityLabel("New Folder")
        let go = NSButton(title: "Go to Folder…", target: self, action: #selector(goToFolder)); go.bezelStyle = .rounded
        let hidden = NSButton(checkboxWithTitle: "Hidden files", target: self, action: #selector(toggleHidden(_:)))
        location.font = .systemFont(ofSize: 15, weight: .semibold); location.lineBreakMode = .byTruncatingMiddle
        let toolbar = NSStackView(views: [back, forward, up, location, go, create]); toolbar.spacing = 8
        for (id, title, width) in [("name", "Name", 340.0), ("date", "Date Modified", 165.0), ("size", "Size", 85.0), ("kind", "Kind", 140.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; c.minWidth = 65; files.addTableColumn(c)
        }
        files.dataSource = self; files.delegate = self; files.rowHeight = 25; files.usesAlternatingRowBackgroundColors = true
        files.allowsMultipleSelection = true; files.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        files.target = self; files.doubleAction = #selector(activateFile); files.setAccessibilityLabel("Files and folders")
        let fileScroll = NSScrollView(); fileScroll.documentView = files; fileScroll.hasVerticalScroller = true; fileScroll.hasHorizontalScroller = true; fileScroll.autohidesScrollers = true
        path.pathStyle = .standard; path.target = self; path.doubleAction = #selector(choosePath); path.setAccessibilityLabel("Current folder path")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        openButton.target = self; openButton.action = #selector(accept); openButton.bezelStyle = .rounded; openButton.keyEquivalent = "\r"
        let bottom = NSStackView(views: [hidden, NSView(), cancel, openButton]); bottom.spacing = 12
        func add(_ views: [NSView], to parent: NSView) { for v in views { parent.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false } }
        add([split, bottom], to: host); add([favorites, sidebarUp, treeScroll], to: sidebar); add([toolbar, fileScroll, path], to: main)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: host.leadingAnchor), split.trailingAnchor.constraint(equalTo: host.trailingAnchor), split.topAnchor.constraint(equalTo: host.topAnchor), split.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), bottom.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), bottom.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12), bottom.heightAnchor.constraint(equalToConstant: 32),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 210), main.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            favorites.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 15), favorites.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            sidebarUp.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12), sidebarUp.centerYAnchor.constraint(equalTo: favorites.centerYAnchor), sidebarUp.widthAnchor.constraint(equalToConstant: 28),
            favorites.trailingAnchor.constraint(lessThanOrEqualTo: sidebarUp.leadingAnchor, constant: -8),
            treeScroll.topAnchor.constraint(equalTo: favorites.bottomAnchor, constant: 10), treeScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6), treeScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6), treeScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: main.topAnchor, constant: 10), toolbar.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -12), toolbar.heightAnchor.constraint(equalToConstant: 34),
            fileScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), fileScroll.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 8), fileScroll.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -8), fileScroll.bottomAnchor.constraint(equalTo: path.topAnchor, constant: -6),
            path.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 12), path.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -12), path.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -6), path.heightAnchor.constraint(equalToConstant: 26)
        ])
        host.layoutSubtreeIfNeeded(); split.setPosition(250, ofDividerAt: 0)
    }
    func refresh() {
        files.reloadData(); files.deselectAll(nil)
        location.stringValue = model.directory.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : (model.directory.lastPathComponent.isEmpty ? "This Mac" : model.directory.lastPathComponent)
        path.url = model.directory
        var ancestors: [URL] = []; var ancestor = model.directory
        while true {
            ancestors.insert(ancestor, at: 0)
            if ancestor.path == "/" { break }
            ancestor = ancestor.deletingLastPathComponent()
        }
        path.pathItems = ancestors.map { url in
            let component = NSPathControl(); component.url = url
            let item = component.pathItems.last ?? NSPathControlItem(); item.title = url.path == "/" ? "This Mac" : url.lastPathComponent
            item.image = NSImage(systemSymbolName: url.path == "/" ? "desktopcomputer" : "folder", accessibilityDescription: nil)
            return item
        }
        back.isEnabled = model.historyIndex > 0; forward.isEnabled = model.historyIndex + 1 < model.history.count
        up.isEnabled = model.directory.path != "/"; sidebarUp.isEnabled = up.isEnabled; openButton.title = "Open Folder"
        syncingTree = true
        if let node = findNode(model.directory) { tree.selectRowIndexes(IndexSet(integer: tree.row(forItem: node)), byExtendingSelection: false) }
        else {
            roots = [OpenBrowserNode(model.directory)]
            sidebarHeading.stringValue = "Folder"
            tree.reloadData(); tree.expandItem(roots[0])
            tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        syncingTree = false
    }
    private func findNode(_ url: URL) -> OpenBrowserNode? {
        for root in roots where url.path == root.url.path || url.path.hasPrefix(root.url.path == "/" ? "/" : root.url.path + "/") {
            var node = root
            let relative = url.pathComponents.dropFirst(root.url.pathComponents.count)
            for component in relative {
                tree.expandItem(node)
                guard let next = node.contents(showsHidden: model.showsHidden).first(where: { $0.url.lastPathComponent == component }) else { return nil }
                node = next
            }
            return node
        }
        return nil
    }
    private func showError(_ error: Error) { NSAlert(error: error).runModal() }
    func navigate(_ url: URL) { do { try model.navigate(url); refresh() } catch { showError(error) } }
    @objc func goBack() { do { try model.step(-1); refresh() } catch { showError(error) } }
    @objc func goForward() { do { try model.step(1); refresh() } catch { showError(error) } }
    @objc func goUp() {
        guard model.directory.path != "/" else { return }
        do {
            try model.navigate(model.directory.deletingLastPathComponent())
            syncingTree = true
            roots = [OpenBrowserNode(model.directory, title: model.directory.path == "/" ? "This Mac" : model.directory.lastPathComponent)]
            sidebarHeading.stringValue = "Folder"
            tree.reloadData(); tree.expandItem(roots[0])
            syncingTree = false
            refresh()
        } catch { showError(error) }
    }
    @objc func toggleHidden(_ sender: NSButton) {
        model.showsHidden = sender.state == .on
        syncingTree = true
        tree.reloadData()
        for root in roots { tree.expandItem(root) }
        syncingTree = false
        navigate(model.directory)
    }
    @objc func choosePath() { if let url = path.clickedPathItem?.url { navigate(url) } }
    @objc func goToFolder() {
        let alert = NSAlert(); alert.messageText = "Go to Folder"; alert.addButton(withTitle: "Go"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: model.directory.path); field.frame = NSRect(x: 0, y: 0, width: 440, height: 24); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { navigate(URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath)) }
    }
    @objc func newFolder() {
        let alert = NSAlert(); alert.messageText = "New Folder"; alert.informativeText = "Create a folder in \(model.directory.lastPathComponent)."; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "Untitled Folder"); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field; alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let url = try model.createFolder(field.stringValue)
            roots.forEach { $0.children = nil }; tree.reloadData(); refresh()
            if let index = model.entries.firstIndex(where: { $0.path == url.path }) { files.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); files.scrollRowToVisible(index) }
        } catch { showError(error) }
    }
    @objc func activateFile() {
        let row = files.clickedRow
        guard model.entries.indices.contains(row) else { return }
        let url = model.entries[row]
        if OpenBrowserModel.isFolder(url) { navigate(url) } else { finish([url]) }
    }
    @objc func accept() {
        let selected = files.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0] : nil }
        finish(selected.isEmpty ? [model.directory] : selected)
    }
    private func finish(_ urls: [URL]) { result = urls; NSApp.stopModal(); window?.orderOut(nil) }
    @objc func cancel() { finish([]) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }
    private func folderIcon(_ symbol: String = "folder.fill") -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemCyan]))
    }
    private func cell(_ text: String, icon: NSImage? = nil) -> NSTableCellView {
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false; cell.textField = label
        var leading = cell.leadingAnchor
        if let icon {
            let image = NSImageView(image: icon); image.imageScaling = .scaleProportionallyDown; cell.addSubview(image); image.translatesAutoresizingMaskIntoConstraints = false; cell.imageView = image
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16)])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: 6), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = model.entries[row]; let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey])
        switch tableColumn?.identifier.rawValue {
        case "date": return cell(v?.contentModificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—")
        case "size": return cell(OpenBrowserModel.isFolder(url) ? "—" : ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file))
        case "kind": return cell(v?.localizedTypeDescription ?? "File")
        default: return cell(url.lastPathComponent, icon: OpenBrowserModel.isFolder(url) ? folderIcon() : NSWorkspace.shared.icon(forFile: url.path))
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { openButton.title = files.selectedRowIndexes.isEmpty ? "Open Folder" : "Open" }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? OpenBrowserNode)?.contents(showsHidden: model.showsHidden).count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? OpenBrowserNode)?.contents(showsHidden: model.showsHidden)[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? OpenBrowserNode else { return false }
        return OpenBrowserModel.isFolder(node.url) && (try? node.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && !node.contents(showsHidden: model.showsHidden).isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OpenBrowserNode else { return nil }
        return cell(node.title, icon: OpenBrowserModel.isFolder(node.url) ? folderIcon(node.url.path == FileManager.default.homeDirectoryForCurrentUser.path ? "house.fill" : "folder") : NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingTree, let node = tree.item(atRow: tree.selectedRow) as? OpenBrowserNode else { return }
        selectSidebarNode(node)
    }
    func selectSidebarNode(_ node: OpenBrowserNode) {
        if OpenBrowserModel.isFolder(node.url) { navigate(node.url); return }
        do {
            try model.navigate(node.url.deletingLastPathComponent())
            refresh()
            if let row = model.entries.firstIndex(where: { $0.path == node.url.path }) {
                files.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                files.scrollRowToVisible(row)
            }
            syncingTree = true
            if let current = findNode(node.url), tree.row(forItem: current) >= 0 {
                tree.selectRowIndexes(IndexSet(integer: tree.row(forItem: current)), byExtendingSelection: false)
            }
            syncingTree = false
        } catch { showError(error) }
    }
    @objc func activateSidebarFile() {
        guard let node = tree.item(atRow: tree.clickedRow) as? OpenBrowserNode, !OpenBrowserModel.isFolder(node.url) else { return }
        finish([node.url])
    }
}

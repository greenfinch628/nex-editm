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
    let gitStatus = GitStatusMonitor()
    let folderTitle = FolderTitleField(labelWithString: "Folder")
    let message = NSTextField(wrappingLabelWithString: "Choose Open… to open a folder")
    var root: FolderNode?
    var onOpenFile: ((URL) -> Void)?
    var onRenameFile: ((URL) -> Void)?
    var onDeleteFile: ((URL) -> Void)?
    var onHide: (() -> Void)?
    var onCloseFolder: (() -> Void)?
    var interfaceFont = NSFont.systemFont(ofSize: 17) { didSet { if isViewLoaded { let saved = state(width: 240, hidden: false); folderTitle.font = interfaceFont; message.font = interfaceFont; outline.rowHeight = max(26, interfaceFont.pointSize + 10); setFolder(root?.url.path, state: saved) } } }
    private var refreshing = false
    override func loadView() {
        let host = NSView(); host.wantsLayer = true; host.layer?.backgroundColor = EditorPalette.workspaceSidebar.cgColor
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
        [folderTitle, refresh, hide, scroll, message].forEach { host.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            folderTitle.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12), folderTitle.topAnchor.constraint(equalTo: host.topAnchor, constant: 12), folderTitle.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8),
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

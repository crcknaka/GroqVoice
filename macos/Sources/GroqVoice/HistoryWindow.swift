import Cocoa

/// Searchable list of everything dictated. Double-click (or the Paste button)
/// puts an entry back into the app you came from: the window hides, focus
/// returns to that app, then the text is pasted.
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private unowned let app: AppController
    private let search = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [HistoryEntry] = []
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Dictation History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 280)
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    func reloadIfVisible() {
        if window?.isVisible == true { reload() }
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let timeColumn = NSTableColumn(identifier: .init("time"))
        timeColumn.title = "When"
        timeColumn.width = 110
        timeColumn.minWidth = 90
        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = ""
        kindColumn.width = 24
        kindColumn.minWidth = 24
        kindColumn.maxWidth = 24
        let textColumn = NSTableColumn(identifier: .init("text"))
        textColumn.title = "Text"
        textColumn.width = 520
        table.addTableColumn(timeColumn)
        table.addTableColumn(kindColumn)
        table.addTableColumn(textColumn)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(pasteSelected)
        table.target = self
        table.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let copy = NSButton(title: "Copy", target: self, action: #selector(copySelected))
        let paste = NSButton(title: "Paste into Last App", target: self, action: #selector(pasteSelected))
        paste.keyEquivalent = "\r"
        let clear = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory))
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [countLabel, spacer, clear, copy, paste])
        bottom.orientation = .horizontal
        bottom.spacing = 8

        let stack = NSStackView(views: [search, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = app.history.entries.reversed().filter { query.isEmpty || $0.text.lowercased().contains(query) }
        table.reloadData()
        countLabel.stringValue = query.isEmpty
            ? "\(rows.count) entries"
            : "\(rows.count) of \(app.history.entries.count) match"
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let entry = rows[row]
        let id = column.identifier
        if id.rawValue == "kind" {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(image)
                c.imageView = image
                NSLayoutConstraint.activate([
                    image.centerXAnchor.constraint(equalTo: c.centerXAnchor),
                    image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 14),
                    image.heightAnchor.constraint(equalToConstant: 14),
                ])
                return c
            }()
            let symbol: String? = entry.kind == "task" ? "sparkles" : entry.kind == "translate" ? "globe" : nil
            cell.imageView?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: entry.kind) }
            cell.imageView?.contentTintColor = .secondaryLabelColor
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(field)
            c.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        if id.rawValue == "time" {
            cell.textField?.stringValue = timeFormatter.string(from: entry.time)
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            cell.textField?.stringValue = entry.menuTitle.isEmpty ? entry.text : entry.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            cell.textField?.textColor = .labelColor
            cell.toolTip = entry.text
        }
        return cell
    }

    private var selectedEntry: HistoryEntry? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    // MARK: - Actions

    @objc private func copySelected() {
        guard let entry = selectedEntry else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        app.flashIcon(.copied, for: 1.2)
    }

    @objc private func pasteSelected() {
        guard let entry = selectedEntry else { return }
        let cfg = app.config
        // Give focus back to whatever app the user came from, then paste there.
        window?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Paster.deliver(entry.text, mode: cfg.pasteModeValue, restoreClipboard: cfg.restoreClipboard)
            Log.write("pasted from history (\(entry.text.count) chars)")
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear the dictation history?"
        alert.informativeText = "All \(app.history.entries.count) entries will be deleted."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.history.clear()
        reload()
    }
}

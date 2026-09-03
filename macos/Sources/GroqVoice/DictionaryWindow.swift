import Cocoa

/// One window for the two lists that shape what gets pasted:
///   Vocabulary — how words are spelled (term + what the recognizer says instead)
///   Snippets   — whole phrases that expand into ready text (or LLM instructions)
/// Tables edit the underlying text files in place, comments and order intact.
final class DictionaryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private unowned let app: AppController
    private let tabs = NSTabView()

    private let vocabTable = NSTableView()
    private var vocabRows: [VocabularyEntry] = []

    private let snippetTable = NSTableView()
    private var snippetRows: [SnippetEntry] = []
    private let snippetText = NSTextView()
    private let snippetInstruction = NSButton(checkboxWithTitle: "Instruction for the LLM (task mode), not text to paste", target: nil, action: nil)
    private let snippetHint = NSTextField(wrappingLabelWithString: "")

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Dictionary"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    enum Tab: Int { case vocabulary = 0, snippets = 1 }

    func show(_ tab: Tab? = nil) {
        reload()
        if let tab { tabs.selectTabViewItem(at: tab.rawValue) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func selectTab(_ index: Int) { tabs.selectTabViewItem(at: index) }

    func reloadIfVisible() {
        if window?.isVisible == true { reload() }
    }

    private func reload() {
        vocabRows = app.vocabulary.entries
        vocabTable.reloadData()
        snippetRows = app.snippets.entries
        snippetTable.reloadData()
        showSelectedSnippet()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        let vocabItem = NSTabViewItem(identifier: "vocab")
        vocabItem.label = "Vocabulary"
        vocabItem.view = buildVocabularyTab()
        tabs.addTabViewItem(vocabItem)

        let snippetItem = NSTabViewItem(identifier: "snippets")
        snippetItem.label = "Snippets"
        snippetItem.view = buildSnippetsTab()
        tabs.addTabViewItem(snippetItem)
    }

    private func buildVocabularyTab() -> NSView {
        let term = NSTableColumn(identifier: .init("term"))
        term.title = "Spelled as"
        term.width = 180
        let aliases = NSTableColumn(identifier: .init("aliases"))
        aliases.title = "Recognizer says (comma-separated; replaced by the term)"
        aliases.width = 460
        configure(vocabTable, columns: [term, aliases])

        let hint = hintLabel("Names, products and jargon. Left: how it must be written. Right: what shows up in the transcript instead — see “STT result” in the log. Whole words, any case; Cyrillic aliases also match with a case ending («в телеграмме»).")
        let add = NSButton(title: "+", target: self, action: #selector(addVocab))
        let remove = NSButton(title: "−", target: self, action: #selector(removeVocab))
        let open = NSButton(title: "Open vocabulary.txt", target: self, action: #selector(openVocabFile))
        return assemble(table: vocabTable, hint: hint, buttons: [add, remove, spacer(), open], detail: nil)
    }

    private func buildSnippetsTab() -> NSView {
        let phrase = NSTableColumn(identifier: .init("phrase"))
        phrase.title = "Say"
        phrase.width = 200
        let text = NSTableColumn(identifier: .init("text"))
        text.title = "Get"
        text.width = 440
        configure(snippetTable, columns: [phrase, text])

        snippetText.isRichText = false
        snippetText.font = .systemFont(ofSize: 12)
        snippetText.isAutomaticQuoteSubstitutionEnabled = false
        snippetText.delegate = self
        snippetText.isVerticallyResizable = true
        snippetText.isHorizontallyResizable = false
        snippetText.autoresizingMask = [.width]
        snippetText.textContainer?.widthTracksTextView = true
        snippetText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = snippetText
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        snippetInstruction.target = self
        snippetInstruction.action = #selector(instructionToggled)
        snippetHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        snippetHint.textColor = .secondaryLabelColor
        snippetHint.stringValue = "Text of the selected snippet. Line breaks are kept. Say the phrase on its own and this is pasted — instantly, no LLM."

        let detail = NSStackView(views: [snippetHint, scroll, snippetInstruction])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6

        let hint = hintLabel("Say the left column alone («моя подпись», «реквизиты») and the right column is pasted. Instruction snippets are used by the LLM when you start with «задание …».")
        let add = NSButton(title: "+", target: self, action: #selector(addSnippet))
        let remove = NSButton(title: "−", target: self, action: #selector(removeSnippet))
        let open = NSButton(title: "Open snippets.txt", target: self, action: #selector(openSnippetsFile))
        return assemble(table: snippetTable, hint: hint, buttons: [add, remove, spacer(), open], detail: detail)
    }

    private func configure(_ table: NSTableView, columns: [NSTableColumn]) {
        columns.forEach(table.addTableColumn)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22
    }

    private func assemble(table: NSTableView, hint: NSTextField, buttons: [NSView], detail: NSView?) -> NSView {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let bar = NSStackView(views: buttons)
        bar.orientation = .horizontal
        bar.spacing = 8

        var views: [NSView] = [hint, scroll]
        if let detail { views.append(detail) }
        views.append(bar)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        if let detail { constraints.append(detail.widthAnchor.constraint(equalTo: stack.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === vocabTable ? vocabRows.count : snippetRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let field = NSTextField(string: "")
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.lineBreakMode = .byTruncatingTail
            field.target = self
            field.action = #selector(cellEdited(_:))
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
        guard let field = cell.textField else { return cell }
        switch id.rawValue {
        case "term":
            field.stringValue = vocabRows[row].term
            field.isEditable = true
        case "aliases":
            field.stringValue = vocabRows[row].aliases.joined(separator: ", ")
            field.placeholderString = "e.g. кулифай, кулифи"
            field.isEditable = true
        case "phrase":
            field.stringValue = snippetRows[row].phrase
            field.isEditable = true
        case "text":
            let e = snippetRows[row]
            field.stringValue = (e.isInstruction ? "⚙︎ " : "") + e.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            field.textColor = e.isInstruction ? .secondaryLabelColor : .labelColor
            field.isEditable = false  // edited in the detail view below
        default:
            break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === snippetTable { showSelectedSnippet() }
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        if let row = vocabTable.row(for: sender) as Int?, row >= 0, vocabTable.isDescendant(of: window!.contentView!) && sender.isDescendant(of: vocabTable) {
            guard vocabRows.indices.contains(row) else { return }
            let entry = vocabRows[row]
            let column = vocabTable.column(for: sender)
            if column == 0 {
                app.vocabulary.update(at: row, term: sender.stringValue, aliases: entry.aliases)
            } else {
                let aliases = sender.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                app.vocabulary.update(at: row, term: entry.term, aliases: aliases)
            }
            vocabRows = app.vocabulary.entries
            vocabTable.reloadData()
            return
        }
        let row = snippetTable.row(for: sender)
        guard row >= 0, snippetRows.indices.contains(row) else { return }
        let entry = snippetRows[row]
        app.snippets.update(at: row, phrase: sender.stringValue, text: entry.text, isInstruction: entry.isInstruction)
        snippetRows = app.snippets.entries
        snippetTable.reloadData()
        snippetTable.selectRowIndexes([row], byExtendingSelection: false)
    }

    // MARK: - Snippet detail

    private var selectedSnippet: Int? {
        let row = snippetTable.selectedRow
        return row >= 0 && row < snippetRows.count ? row : nil
    }

    private func showSelectedSnippet() {
        if let row = selectedSnippet {
            let e = snippetRows[row]
            if snippetText.string != e.text { snippetText.string = e.text }
            snippetInstruction.state = e.isInstruction ? .on : .off
            snippetText.isEditable = true
            snippetInstruction.isEnabled = true
        } else {
            snippetText.string = ""
            snippetText.isEditable = false
            snippetInstruction.isEnabled = false
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        saveSnippetText()
    }

    private func saveSnippetText() {
        guard let row = selectedSnippet else { return }
        let e = snippetRows[row]
        let text = snippetText.string
        guard text != e.text else { return }
        app.snippets.update(at: row, phrase: e.phrase, text: text, isInstruction: e.isInstruction)
        snippetRows = app.snippets.entries
        snippetTable.reloadData(forRowIndexes: [row], columnIndexes: [0, 1])
    }

    @objc private func instructionToggled() {
        guard let row = selectedSnippet else { return }
        let e = snippetRows[row]
        app.snippets.update(at: row, phrase: e.phrase, text: snippetText.string, isInstruction: snippetInstruction.state == .on)
        snippetRows = app.snippets.entries
        snippetTable.reloadData(forRowIndexes: [row], columnIndexes: [0, 1])
    }

    // MARK: - Actions

    @objc private func addVocab() {
        app.vocabulary.add(term: "NewTerm", aliases: [])
        vocabRows = app.vocabulary.entries
        vocabTable.reloadData()
        if let row = vocabRows.firstIndex(where: { $0.term == "NewTerm" }) {
            vocabTable.selectRowIndexes([row], byExtendingSelection: false)
            vocabTable.scrollRowToVisible(row)
            vocabTable.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @objc private func removeVocab() {
        let row = vocabTable.selectedRow
        guard row >= 0 else { return }
        app.vocabulary.remove(at: row)
        vocabRows = app.vocabulary.entries
        vocabTable.reloadData()
    }

    @objc private func addSnippet() {
        saveSnippetText()
        app.snippets.add(phrase: "новая фраза", text: "", isInstruction: false)
        snippetRows = app.snippets.entries
        snippetTable.reloadData()
        let row = snippetRows.count - 1
        guard row >= 0 else { return }
        snippetTable.selectRowIndexes([row], byExtendingSelection: false)
        snippetTable.scrollRowToVisible(row)
        snippetTable.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeSnippet() {
        guard let row = selectedSnippet else { return }
        app.snippets.remove(at: row)
        snippetRows = app.snippets.entries
        snippetTable.reloadData()
        showSelectedSnippet()
    }

    @objc private func openVocabFile() { NSWorkspace.shared.open(app.vocabulary.fileURL) }
    @objc private func openSnippetsFile() { NSWorkspace.shared.open(app.snippets.fileURL) }
}

/// Small modal for the common case: one word came out wrong, fix it for good.
enum QuickVocabularyAdd {
    static func run(app: AppController, recognized: String = "") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Vocabulary Term"
        alert.informativeText = "Left: how the word must be written. Right: what the recognizer produced (several variants separated by commas). From now on the variants are replaced by the term."
        let term = NSTextField(frame: NSRect(x: 0, y: 34, width: 380, height: 24))
        term.placeholderString = "Spelled as — e.g. Coolify"
        let aliases = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        aliases.placeholderString = "Recognizer says — e.g. кулифай, кулифи"
        aliases.stringValue = recognized
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 58))
        box.addSubview(term)
        box.addSubview(aliases)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = term
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let t = term.stringValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        app.vocabulary.add(term: t, aliases: aliases.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        Log.write("vocabulary: added \(t)")
        app.dictionaryWindowLoaded ? app.dictionaryWindow.reloadIfVisible() : ()
    }
}

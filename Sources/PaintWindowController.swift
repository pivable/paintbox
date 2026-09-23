import AppKit
import UniformTypeIdentifiers

/// Keeps a small document centred in the scroll view instead of jammed to one corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if rect.height > doc.frame.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}

final class PaintWindowController: NSWindowController, NSWindowDelegate, PaintDocumentObserver,
                                   CanvasViewDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                   NSToolbarItemValidation,
                                   PanelClient {

    let paintDocument: PaintDocument
    let settings = ToolSettings()
    private(set) var canvas: CanvasView!
    private var palette: PaletteView!
    private var scrollView: NSScrollView!
    /// Not private: the floating paste's instruction lives here and nowhere else now,
    /// so the self-test reads what it says and measures whether it fits.
    private(set) var statusLabel: NSTextField!
    private let docUndoManager = UndoManager()
    private var lastQuality: CGFloat = 0.8
    private var lastFormat: SaveFormat = .png

    init(document paintDocument: PaintDocument) {
        self.paintDocument = paintDocument
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = CGSize(width: 640, height: 420)
        super.init(window: window)
        window.delegate = self
        paintDocument.observer = self
        paintDocument.undoManager = docUndoManager
        // Event grouping OFF. Left on — the default — every registration made during one
        // event collapses into a single undo step, and this app routinely registers twice
        // in one event: `finishPendingEdits` commits a floating paste and the operation
        // that asked for it then registers its own step, inside the same mouse-down or
        // menu action. One ⌘Z then threw away the paste along with the dot drawn on top
        // of it, with no second ⌘Z to get it back. `PaintDocument.registerUndo` opens and
        // closes a group of its own instead, so one registration is one step.
        docUndoManager.groupsByEvent = false
        applyUndoBudget()
        buildUI()
        updateTitle()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }
        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        palette = PaletteView(settings: settings)
        let paletteScroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: PaletteView.preferredWidth,
                                                       height: content.bounds.height))
        paletteScroll.hasVerticalScroller = true
        paletteScroll.drawsBackground = false
        paletteScroll.autohidesScrollers = true
        paletteScroll.documentView = palette
        paletteScroll.autoresizingMask = [.height]
        palette.onColorPanelRequest = { [weak self] fg in self?.showColorPanel(foreground: fg) }
        // Using the palette is using the app, exactly as the Tools menu is: whatever is
        // still in mid-air over the bitmap is settled before the click takes effect.
        palette.onInteraction = { [weak self] in self?.canvas?.finishPendingEdits() }
        content.addSubview(paletteScroll)

        canvas = CanvasView(document: paintDocument, settings: settings)
        canvas.delegate = self

        scrollView = NSScrollView(frame: CGRect(x: PaletteView.preferredWidth, y: 22,
                                                width: content.bounds.width - PaletteView.preferredWidth,
                                                height: content.bounds.height - 22))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = false
        scrollView.backgroundColor = NSColor(white: 0.35, alpha: 1)
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = NSColor(white: 0.35, alpha: 1)
        scrollView.contentView = clip
        scrollView.documentView = canvas
        content.addSubview(scrollView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = CGRect(x: PaletteView.preferredWidth + 8, y: 3,
                                   width: content.bounds.width - PaletteView.preferredWidth - 16, height: 16)
        statusLabel.autoresizingMask = [.width]
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        window.contentView = content

        settings.onChange = { [weak self] in
            guard let self else { return }
            self.palette.refresh()
            self.canvas.window?.invalidateCursorRects(for: self.canvas)
            self.updateStatus(nil)
        }

        let toolbar = NSToolbar(identifier: "PaintboxToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        // The title gets its own row, and the toolbar gets the whole window width.
        //
        // The default style puts them on ONE row, where the title and seventeen labelled
        // items fight over about 900pt of a 1100pt window — and both lose. Measured with
        // `NSToolbar.visibleItems` on the real window: unified needs 1280pt to show every
        // item, so at the app's own default size Cut Out, Zoom Out, Fit and Zoom In were
        // all folded into the `»` overflow menu and the title was clipped to
        // "Untitled — Paintb…". The zoom trio is what a new user reaches for first on a
        // photo that opened zoomed-to-fit, and it was the part that disappeared.
        //
        // Expanded needs 1020pt for the same items, so everything fits at the default and
        // stays fitting for the first 80pt of narrowing; the title is never truncated
        // because it no longer shares the row. Icon-only would buy more room still, but
        // the labels are the only thing that tells Crop from Trim without hovering.
        // `SelfTest.checkToolbarFitsTheDefaultWindow` is what keeps this true.
        window.toolbarStyle = .expanded

        DispatchQueue.main.async { [weak self] in
            self?.canvas.zoomToFitIfLarger()
            self?.window?.makeFirstResponder(self?.canvas)
            self?.updateStatus(nil)
        }
    }

    // MARK: - Toolbar

    private enum TB {
        static let crop = NSToolbarItem.Identifier("crop")
        static let resize = NSToolbarItem.Identifier("resize")
        static let canvasSize = NSToolbarItem.Identifier("canvasSize")
        static let flipH = NSToolbarItem.Identifier("flipH")
        static let flipV = NSToolbarItem.Identifier("flipV")
        static let rotCW = NSToolbarItem.Identifier("rotCW")
        static let rotCCW = NSToolbarItem.Identifier("rotCCW")
        static let removeBG = NSToolbarItem.Identifier("removeBG")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let zoomFit = NSToolbarItem.Identifier("zoomFit")
        static let undo = NSToolbarItem.Identifier("undoItem")
        static let redo = NSToolbarItem.Identifier("redoItem")
        static let blur = NSToolbarItem.Identifier("blur")
        static let pixelate = NSToolbarItem.Identifier("pixelate")
        static let adjust = NSToolbarItem.Identifier("adjust")
        static let trim = NSToolbarItem.Identifier("trim")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.undo, TB.redo, .space, TB.crop, TB.trim, TB.resize, TB.canvasSize, .space,
         TB.flipH, TB.flipV, TB.rotCCW, TB.rotCW, .space,
         TB.blur, TB.pixelate, TB.adjust, TB.removeBG,
         .flexibleSpace, TB.zoomOut, TB.zoomFit, TB.zoomIn]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func make(_ label: String, _ tip: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = tip
            item.toolTip = tip
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
                item.image = image
            } else {
                item.title = label   // never leave a blank button if a symbol is missing
            }
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case TB.crop: return make("Crop", "Crop to Selection", Symbols.crop, #selector(cropToSelection(_:)))
        case TB.resize: return make("Resize", "Resize Image… (scales the picture)", Symbols.resize,
                                    #selector(resizeImage(_:)))
        case TB.canvasSize: return make("Canvas", "Canvas Size… (changes the paper, no scaling)",
                                        Symbols.canvasSize, #selector(changeCanvasSize(_:)))
        case TB.flipH: return make("Flip H", "Flip Horizontal", Symbols.flipH, #selector(flipHorizontal(_:)))
        case TB.flipV: return make("Flip V", "Flip Vertical", Symbols.flipV, #selector(flipVertical(_:)))
        case TB.rotCW: return make("Rotate R", "Rotate 90° Clockwise", Symbols.rotateCW, #selector(rotateClockwise(_:)))
        case TB.rotCCW: return make("Rotate L", "Rotate 90° Anticlockwise", Symbols.rotateCCW,
                                    #selector(rotateAnticlockwise(_:)))
        case TB.removeBG: return make("Cut Out", "Remove Background", Symbols.removeBG,
                                      #selector(removeBackground(_:)))
        case TB.zoomIn: return make("Zoom In", "Zoom In", Symbols.zoomIn, #selector(zoomIn(_:)))
        case TB.zoomOut: return make("Zoom Out", "Zoom Out", Symbols.zoomOut, #selector(zoomOut(_:)))
        case TB.zoomFit: return make("Fit", "Zoom to Fit", Symbols.zoomFit, #selector(zoomToFit(_:)))
        case TB.blur: return make("Blur", "Blur… (redact part of a picture)", Symbols.blur,
                                  #selector(blurSelection(_:)))
        case TB.pixelate: return make("Pixelate", "Pixelate…", Symbols.pixelate,
                                      #selector(pixelateSelection(_:)))
        case TB.adjust: return make("Adjust", "Adjustments… (brightness, contrast, saturation)",
                                    Symbols.adjust, #selector(showAdjustments(_:)))
        case TB.trim: return make("Trim", "Trim to Content", Symbols.trim, #selector(trimToContent(_:)))
        case TB.undo: return make("Undo", "Undo", Symbols.undo, #selector(undoAction(_:)))
        case TB.redo: return make("Redo", "Redo", Symbols.redo, #selector(redoAction(_:)))
        default: return nil
        }
    }

    // MARK: - Document observer

    func documentDidChangeImage(_ doc: PaintDocument, sizeChanged: Bool) {
        if sizeChanged {
            canvas.selection = nil
            // Belt and braces for the selection's twin: a floating item's frame is in the
            // OLD canvas's pixels, so after a resize its handles can be off the canvas and
            // out of reach, and committing it would stamp the picture at coordinates that
            // no longer mean anything. Every caller finishes pending edits first, but this
            // is the one place that is true whichever way the canvas changed size.
            canvas.cancelFloating()
            // And the drag in progress, for the same reason: its anchor is a point on
            // the canvas that has just been replaced, so a mouse-up after a crop or a
            // resize — both reachable from the keyboard with the button still down —
            // would commit a shape or a selection measured against a picture that is
            // gone. The preview on screen is already wrong by then.
            canvas.cancelDrag()
            canvas.resizeToImage()
            // A step now costs a different number of bytes, so the stack can afford a
            // different number of steps. Crop a photograph and you get more undo back.
            applyUndoBudget()
        }
        canvas.needsDisplay = true
        updateTitle()
        updateStatus(nil)
    }

    func documentDidChangeMetadata(_ doc: PaintDocument) {
        updateTitle()
        // The frame-count note lives in the status line, and that travels with the file.
        if statusLabel != nil { updateStatus(nil) }
    }

    private func updateTitle() {
        window?.title = "\(paintDocument.displayName) — Paintbox"
        window?.isDocumentEdited = paintDocument.isDirty
        window?.representedURL = paintDocument.fileURL
    }

    private func updateStatus(_ point: CGPoint?) {
        var parts: [String] = ["\(paintDocument.pixelWidth) × \(paintDocument.pixelHeight) px",
                               "\(Int((canvas.zoom * 100).rounded()))%",
                               settings.tool.title]
        if let sel = canvas.selection, !sel.isEmpty {
            let shape = sel.isRectangular ? "" : " (\(sel.setCount) px)"
            parts.append("selection \(Int(sel.bounds.width)) × \(Int(sel.bounds.height))\(shape)")
        }
        if let f = canvas.floatingFrame {
            // The whole of how a floating paste works, said only while one is floating.
            // The Edit menu's Paste item used to carry this in its own title, where it
            // was in front of everyone who had not pasted and nobody who had.
            parts.append("floating \(Int(f.width)) × \(Int(f.height)) — drag to move, "
                         + "drag a corner to scale, Return to place, Esc to cancel")
        }
        if let undoNote = UndoBudget.note(width: paintDocument.pixelWidth,
                                          height: paintDocument.pixelHeight) {
            // A snapshot of a big picture is tens of megabytes, so the stack holds fewer
            // steps. Said here rather than discovered when Cmd-Z stops responding.
            parts.append(undoNote)
        }
        if let gamut = paintDocument.sourceWideGamut {
            // The colours outside sRGB were clipped when the file was opened and cannot
            // be undone back; saying so here is the difference between a trade-off and a
            // surprise. It disappears on the first save, when it stops being true.
            parts.append("\(gamut) → sRGB")
        }
        if paintDocument.sourceFrameCount > 1 {
            // Said plainly and permanently, not only in the alert at save time: this
            // file is an animation and what is on screen is one frame of it.
            parts.append("frame 1 of \(paintDocument.sourceFrameCount)")
        }
        if let p = point {
            parts.append("x \(Int(p.x)), y \(Int(p.y))")
        }
        if let note = canvas.pickNote {
            // Last, so it reads as the answer to the click that was just made, and
            // repeated on every hover until the next click clears it.
            parts.append(note)
        }
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: - CanvasViewDelegate

    func canvasDidChangeSelection(_ view: CanvasView) { updateStatus(nil) }
    func canvasDidChangeZoom(_ view: CanvasView) { updateStatus(nil) }
    func canvas(_ view: CanvasView, hoveringAt point: CGPoint?) { updateStatus(point) }
    func canvasDidPickColor(_ view: CanvasView) { palette.refresh() }

    // MARK: - Undo plumbing

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { docUndoManager }

    /// Undo is whole-image snapshots, so the number of steps the stack may hold has to
    /// follow the size of the canvas. Left unset, `levelsOfUndo` is 0, which means
    /// UNLIMITED: ten blurs on a 24-megapixel photograph held two gigabytes and nothing
    /// ever trimmed it. See UndoBudget.
    private func applyUndoBudget() {
        // Trimming the stack from inside an undo — which is where this lands when the
        // step being undone changed the canvas size — is asking for trouble, so wait
        // until the manager is idle.
        guard !docUndoManager.isUndoing, !docUndoManager.isRedoing else {
            DispatchQueue.main.async { [weak self] in self?.applyUndoBudget() }
            return
        }
        let levels = UndoBudget.levels(width: paintDocument.pixelWidth,
                                       height: paintDocument.pixelHeight)
        if docUndoManager.levelsOfUndo != levels { docUndoManager.levelsOfUndo = levels }
    }

    @IBAction func undoAction(_ sender: Any?) {
        // A floating paste has not touched the bitmap yet, so the thing ⌘Z should take
        // back IS the paste — and taking it back means throwing it away, not stamping it
        // in so that the very next line can lift it out again. Committing first also made
        // ⌘Z dead on a fresh document, where the paste was the only history there was and
        // `canUndo` was false when the menu was validated.
        if canvas.hasFloatingItem, !canvas.isEditingText {
            canvas.cancelFloating()
            return
        }
        canvas.finishPendingEdits()
        if docUndoManager.canUndo { docUndoManager.undo() }
    }
    @IBAction func redoAction(_ sender: Any?) {
        // The same reason undo does it, one step further on: redo can replace the whole
        // bitmap, and a redone crop or resize would leave a floating paste in mid-air
        // measured against a canvas that no longer exists.
        canvas.finishPendingEdits()
        if docUndoManager.canRedo { docUndoManager.redo() }
    }

    // MARK: - File

    /// Where ⌘S can put the pixels: over the document's own file, or only through the
    /// save panel because there is no file yet or its format cannot be written.
    ///
    /// One expression, because two callers now depend on it and they must not disagree:
    /// ⌘S, and the Save button in the close/quit alert. The alert's Save has to know
    /// that an untitled document needs a panel BEFORE it answers whether the window may
    /// close.
    enum SaveRoute: Equatable {
        /// Write straight over this file.
        case write(URL)
        /// Ask, with this line across the top of the panel when there is a reason to give.
        case panel(String?)
    }

    static func saveRoute(for url: URL?) -> SaveRoute {
        // No file yet: Save is Save As, whoever asked for it.
        guard let url else { return .panel(nil) }
        // Paintbox reads far more formats than it can write — the Open panel's `.image`
        // catch-all lets .webp, .psd, .dng and friends in on purpose. Saving one under
        // its own name would leave PNG bytes in a file the rest of the system still
        // believes is a WebP. So ⌘S opens the save panel instead and says why: the
        // format is changing, and the user gets to see it change.
        guard SaveFormat.forExtension(url.pathExtension) != nil else {
            return .panel("Paintbox can open \(PaintDocument.describe(extension: url.pathExtension)) "
                          + "but cannot write them. Choose a format to save as instead — "
                          + "the original file is left alone.")
        }
        return .write(url)
    }

    @IBAction func saveDocument(_ sender: Any?) {
        _ = performSave(panel: { [self] in runSavePanel(message: $0) })
    }

    /// Everything ⌘S does, reporting whether a file was actually written.
    ///
    /// The panel is passed in rather than called directly because the answer means
    /// different things to the two callers: the menu can let a sheet finish whenever it
    /// likes, while the close and quit review has to have the file on disk before it
    /// returns. So ⌘S hands in the sheet (which always reports false — its answer is not
    /// known yet) and `saveBeforeClosing` hands in a modal panel.
    @discardableResult
    func performSave(panel runPanel: (String?) -> Bool) -> Bool {
        canvas.finishPendingEdits()
        let url: URL
        switch Self.saveRoute(for: paintDocument.fileURL) {
        case .panel(let message): return runPanel(message)
        case .write(let u): url = u
        }
        switch confirmFlatteningFrames() {
        case .cancel: return false
        case .saveACopy: return runPanel(nil)
        case .proceed: break
        }
        do {
            try paintDocument.save(to: url, quality: lastQuality, matte: settings.background)
            // A file we have just written is a document someone may well come back to,
            // so it belongs in File ▸ Open Recent alongside the ones that were opened.
            RecentDocumentsMenu.remember(url)
            return true
        } catch {
            Dialogs.error(error.localizedDescription, window: window)
            return false
        }
    }

    private enum FrameChoice { case proceed, saveACopy, cancel }

    /// The file is an animation and only one frame of it is being edited. Saving over it
    /// throws the rest away, so this is the one moment to say so.
    ///
    /// It reports the choice rather than acting on it: it used to call `saveDocumentAs`
    /// itself and then report failure, which the caller could not tell from a cancel —
    /// and the close review reads that answer to decide whether the window may go.
    private func confirmFlatteningFrames() -> FrameChoice {
        let n = paintDocument.sourceFrameCount
        guard n > 1 else { return .proceed }
        let alert = NSAlert()
        alert.messageText = "“\(paintDocument.displayName)” has \(n) frames."
        alert.informativeText = "Paintbox edits one frame at a time. Saving over this file keeps "
            + "the frame you are editing and throws the other \(n - 1) away."
        alert.addButton(withTitle: "Save One Frame")
        alert.addButton(withTitle: "Save a Copy…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .proceed
        case .alertSecondButtonReturn: return .saveACopy
        default: return .cancel
        }
    }

    @IBAction func saveDocumentAs(_ sender: Any?) {
        canvas.finishPendingEdits()
        runSavePanel(message: nil)
    }

    /// What a Save As did. `refused` carries the sentence to show, whether the refusal
    /// was ours or the writer's — the caller shows it and does not have to tell them apart.
    enum SaveAsOutcome: Equatable {
        /// Written, at this path — not always the path that was asked for, because the
        /// format popup wins over a typed extension.
        case wrote(URL)
        case refused(String)
    }

    /// Everything Save As does once a path and a format have been chosen, minus the panel.
    ///
    /// It is a function of its own rather than a closure inside the panel so that the
    /// self-test can drive a real save — and a real refusal — with no panel on screen and
    /// no alert to dismiss, and so the sentence the test reads is the sentence a user is
    /// shown.
    func saveAs(to proposed: URL, format: SaveFormat, quality: CGFloat) -> SaveAsOutcome {
        var url = proposed
        // The popup wins over whatever the user typed in the name field.
        if !format.extensions.contains(url.pathExtension.lowercased()) {
            url = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        }
        // Two windows on one file is the collision `open(url:)` already refuses, arriving
        // from the other direction: Open would not give you a second window on a file, but
        // Save As would aim a second window at one — and that is worse, because the file it
        // lands on is one somebody had already saved. Each save writes the WHOLE picture,
        // so from then on whichever window saves last wins and neither is told. Same
        // lookup as Open, with the same symlink-resolving spelling, and it names the window
        // in the way so the sentence can be acted on.
        if let other = PaintboxApp.shared.existingController(for: url), other !== self {
            return .refused("“\(other.paintDocument.displayName)” is already open in another "
                            + "Paintbox window. Saving this picture over it would throw away "
                            + "whatever that window has done. Close that window first, or save "
                            + "this picture under a different name.")
        }
        do {
            try paintDocument.save(to: url, format: format, quality: quality,
                                   matte: settings.background)
            RecentDocumentsMenu.remember(url)
            return .wrote(url)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// The save panel, run modally, for the close and quit review. See `saveBeforeClosing`.
    private func runModalSavePanel(_ message: String?) -> Bool {
        runSavePanel(message: message, modal: true)
    }

    /// The save panel itself. `message` is the line across the top, used when ⌘S had to
    /// divert here rather than being asked for. Returns whether a file was written —
    /// which as a sheet is not yet known, so false.
    @discardableResult
    private func runSavePanel(message: String?, modal: Bool = false) -> Bool {
        let panel = NSSavePanel()
        if let message { panel.message = message }
        let options = SaveOptionsView()
        options.panel = panel
        let existing = SaveFormat.forExtension(paintDocument.fileURL?.pathExtension ?? "") ?? lastFormat
        options.select(existing)
        panel.accessoryView = options
        if let t = existing.utType { panel.allowedContentTypes = [t] }
        panel.nameFieldStringValue = paintDocument.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Bool = { [self] response in
            guard response == .OK, let url = panel.url else { return false }
            let format = options.format
            lastQuality = options.quality
            lastFormat = format
            switch saveAs(to: url, format: format, quality: options.quality) {
            case .wrote:
                return true
            case .refused(let why):
                Dialogs.error(why, window: window)
                return false
            }
        }
        // Modal rather than a sheet when the caller has to act on the result: a sheet
        // reports back long after the function that put it up has returned.
        guard !modal else { return write(panel.runModal()) }
        guard let window else { return false }
        panel.beginSheetModal(for: window) { response in _ = write(response) }
        return false
    }

    // MARK: - Edit

    /// ⌘C promises the picture rather than encoding it: see `PasteboardImage` for why a
    /// copy of a big photograph used to freeze the window for up to 1.7 seconds and leave
    /// 180 MB on the clipboard.
    @IBAction func copy(_ sender: Any?) {
        copyToPasteboard(.general)
    }

    /// The whole of what ⌘C does, against a pasteboard of the caller's choosing — the
    /// same seam the reading half has, so the self-test can copy without throwing away
    /// whatever the person running it had on their clipboard.
    @discardableResult
    func copyToPasteboard(_ pb: NSPasteboard) -> PasteboardImage? {
        canvas.finishPendingEdits()
        guard let img = paintDocument.copy(mask: canvas.selection) else { return nil }
        return PasteboardImage.place(img, on: pb)
    }

    /// Cut needs a selection. Without one `clear(mask: nil)` means the whole canvas, so
    /// ⌘X on an untouched picture used to copy it and then erase every pixel of it — a
    /// menu item called "Cut" doing a Select All nobody asked for. `validateMenuItem`
    /// greys it out; this guard is what makes that true rather than merely displayed.
    @IBAction func cut(_ sender: Any?) {
        guard canvas.selectionRect != nil else { return }
        copy(sender)
        paintDocument.clear(mask: canvas.selection, to: nil)
    }

    /// Paste no longer stamps: the clipboard becomes a floating item you can drag and
    /// scale, and it lands when you click away, press Return, or start anything else.
    @IBAction func paste(_ sender: Any?) {
        guard let img = PaintboxApp.imageFromPasteboard() else {
            Dialogs.error("There is no picture on the clipboard.", window: window)
            return
        }
        canvas.beginFloating(image: img)
        window?.makeFirstResponder(canvas)
    }

    @IBAction func placeFloating(_ sender: Any?) { canvas.commitFloating() }

    override func selectAll(_ sender: Any?) { canvas.selectAllPixels() }
    @IBAction func deselect(_ sender: Any?) { canvas.selection = nil }
    @objc func delete(_ sender: Any?) { canvas.deleteSelectionOrFloating() }

    /// Same trap as Cut, one key away: ⌘⌫ with nothing selected used to flood the whole
    /// picture with the background colour.
    @IBAction func fillSelection(_ sender: Any?) {
        guard canvas.selectionRect != nil else { return }
        paintDocument.clear(mask: canvas.selection, to: settings.background)
    }

    // MARK: - Image operations

    /// The mask, not `selectionRect`: an irregular selection crops to its bounding box
    /// AND loses the background inside that box, which is the only reading of "crop to
    /// selection" that matches what a wanded subject looks like on screen.
    @IBAction func cropToSelection(_ sender: Any?) {
        canvas.finishPendingEdits()
        guard let sel = canvas.selection, !sel.isEmpty else {
            Dialogs.error("Select an area first with the Selection tool (S), then crop.", window: window)
            return
        }
        paintDocument.crop(to: sel)
    }

    /// Whole pixels for a size someone typed, or nil after telling them why not.
    /// Every dialog that asks for a size goes through here: the numbers are not checked
    /// where they are typed, they are checked where they are about to become memory.
    private func acceptedSize(_ size: CGSize) -> (width: Int, height: Int)? {
        if let why = CanvasLimits.rejection(for: size) {
            Dialogs.error(why, window: window)
            return nil
        }
        return CanvasLimits.pixelSize(size)
    }

    @IBAction func resizeImage(_ sender: Any?) {
        canvas.finishPendingEdits()
        guard let size = Dialogs.resizeImage(current: paintDocument.pixelSize),
              let px = acceptedSize(size) else { return }
        paintDocument.resizeImage(width: px.width, height: px.height)
    }

    @IBAction func changeCanvasSize(_ sender: Any?) {
        canvas.finishPendingEdits()
        guard let result = Dialogs.canvasSize(current: paintDocument.pixelSize),
              let px = acceptedSize(result.size) else { return }
        paintDocument.setCanvasSize(width: px.width, height: px.height,
                                    anchor: result.anchor, fill: settings.background)
    }

    @IBAction func flipHorizontal(_ sender: Any?) {
        canvas.finishPendingEdits(); paintDocument.flip(horizontal: true)
    }
    @IBAction func flipVertical(_ sender: Any?) {
        canvas.finishPendingEdits(); paintDocument.flip(horizontal: false)
    }
    @IBAction func rotateClockwise(_ sender: Any?) {
        canvas.finishPendingEdits(); paintDocument.rotateQuarter(degrees: 90)
    }
    @IBAction func rotateAnticlockwise(_ sender: Any?) {
        canvas.finishPendingEdits(); paintDocument.rotateQuarter(degrees: -90)
    }
    @IBAction func rotate180(_ sender: Any?) {
        canvas.finishPendingEdits(); paintDocument.rotateQuarter(degrees: 180)
    }

    @IBAction func rotateByAngle(_ sender: Any?) {
        canvas.finishPendingEdits()
        // `deg.isFinite` as well as `!= 0`, because NaN passes `!= 0`.
        guard let deg = Dialogs.rotationAngle(), deg.isFinite, deg != 0 else { return }
        paintDocument.rotateArbitrary(degrees: deg)
    }

    @IBAction func removeBackground(_ sender: Any?) {
        canvas.finishPendingEdits()
        do {
            try paintDocument.removeBackground()
        } catch {
            Dialogs.error(error.localizedDescription, window: window)
        }
    }

    // MARK: - Adjustments and filters
    //
    // Each of these runs on the selection if there is one and on the whole picture if
    // there is not, which is the rule people already expect from Crop and Delete.

    private var selectionNote: String {
        canvas.selectionRect == nil ? "Nothing is selected, so this applies to the whole picture."
                                    : "This applies to the selection only."
    }

    @IBAction func blurSelection(_ sender: Any?) {
        canvas.finishPendingEdits()
        let values = FilterDialog.run(
            title: "Blur",
            message: "Softens the picture beyond reading. \(selectionNote)",
            image: paintDocument.image, mask: canvas.selection,
            sliders: [FilterSlider(title: "RADIUS", min: 1, max: 60, value: 12) { "\(Int($0)) px" }],
            transform: { ci, v, ctx in
                CanvasFilter.blur(ci, radius: CGFloat(v[0]) * ctx.scale)
            })
        guard let values else { return }
        paintDocument.blur(radius: CGFloat(values[0]), mask: canvas.selection)
    }

    @IBAction func pixelateSelection(_ sender: Any?) {
        canvas.finishPendingEdits()
        let values = FilterDialog.run(
            title: "Pixelate",
            message: "Replaces the detail with solid blocks. \(selectionNote)",
            image: paintDocument.image, mask: canvas.selection,
            sliders: [FilterSlider(title: "BLOCK SIZE", min: 2, max: 80, value: 16) { "\(Int($0)) px" }],
            transform: { ci, v, ctx in
                CanvasFilter.pixelate(ci, scale: max(1, CGFloat(v[0]) * ctx.scale),
                                      anchor: ctx.canvasOrigin)
            })
        guard let values else { return }
        paintDocument.pixelate(scale: CGFloat(values[0]), mask: canvas.selection)
    }

    @IBAction func showAdjustments(_ sender: Any?) {
        canvas.finishPendingEdits()
        func signed(_ v: Double) -> String { String(format: "%+.2f", v) }
        let values = FilterDialog.run(
            title: "Adjustments",
            message: "Brightness, contrast and saturation. \(selectionNote)",
            image: paintDocument.image, mask: canvas.selection,
            sliders: [
                FilterSlider(title: "BRIGHTNESS", min: -1, max: 1, value: 0, format: signed),
                FilterSlider(title: "CONTRAST", min: 0.25, max: 3, value: 1) { String(format: "%.2f×", $0) },
                FilterSlider(title: "SATURATION", min: 0, max: 2, value: 1) { String(format: "%.2f×", $0) },
            ],
            transform: { ci, v, _ in
                CanvasFilter.colorControls(ci, brightness: CGFloat(v[0]), contrast: CGFloat(v[1]),
                                           saturation: CGFloat(v[2]))
            })
        guard let values else { return }
        paintDocument.adjustColors(brightness: CGFloat(values[0]), contrast: CGFloat(values[1]),
                                   saturation: CGFloat(values[2]), mask: canvas.selection)
    }

    @IBAction func makeGrayscale(_ sender: Any?) {
        canvas.finishPendingEdits()
        paintDocument.grayscale(mask: canvas.selection)
    }

    @IBAction func invertColors(_ sender: Any?) {
        canvas.finishPendingEdits()
        paintDocument.invertColors(mask: canvas.selection)
    }

    @IBAction func trimToContent(_ sender: Any?) {
        canvas.finishPendingEdits()
        if !paintDocument.trimToContent() {
            Dialogs.error("There is nothing to trim: the edges of this picture are not a single "
                          + "flat colour, or the whole picture is one colour.", window: window)
        }
    }

    // MARK: - View

    @IBAction func zoomIn(_ sender: Any?) { canvas.stepZoom(2) }
    @IBAction func zoomOut(_ sender: Any?) { canvas.stepZoom(0.5) }
    @IBAction func actualSize(_ sender: Any?) { canvas.setZoom(1) }
    @IBAction func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }

    // MARK: - Tools

    @IBAction func selectTool(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let tool = Tool(rawValue: item.representedObject as? String ?? "") else { return }
        canvas.finishPendingEdits()
        settings.tool = tool
        palette.refresh()
    }

    @IBAction func swapColors(_ sender: Any?) { settings.swapColors(); palette.refresh() }

    @IBAction func chooseForegroundColor(_ sender: Any?) { showColorPanel(foreground: true) }
    @IBAction func chooseBackgroundColor(_ sender: Any?) { showColorPanel(foreground: false) }

    /// Neither panel is ever given this controller as its target: see PanelClient in
    /// AppDelegate.swift for why that would be a use-after-free waiting to happen.
    private func showColorPanel(foreground: Bool) {
        PaintboxApp.shared.showColorPanel(for: self, foreground: foreground,
                                          initial: foreground ? settings.foreground
                                                              : settings.background)
    }

    @IBAction func chooseFont(_ sender: Any?) {
        PaintboxApp.shared.showFontPanel(for: self, current: settings.font)
    }

    // MARK: - PanelClient

    func panelPicked(color: NSColor, foreground: Bool) {
        if foreground { settings.foreground = color } else { settings.background = color }
        palette.refresh()
    }

    func panelPicked(font manager: NSFontManager) {
        settings.font = manager.convert(settings.font)
    }

    // MARK: - Menu validation

    /// True while a keystroke belongs to a text field rather than to the canvas:
    /// the inline text tool, any dialog, or any field editor.
    private var isTyping: Bool {
        canvas.isEditingText
            || NSApp.modalWindow != nil
            || NSApp.keyWindow?.firstResponder is NSText
    }

    private var hasSelection: Bool { canvas.selectionRect != nil }

    /// What ⌘Z would take back, or nil when there is nothing to take back.
    ///
    /// A floating paste comes first because it is the most recent thing the user did and
    /// `undoAction` cancels it. Without this the Edit menu read "Undo Brush" over a
    /// pending paste — naming the step BEFORE the one it would actually reverse — and on
    /// a document with no history it read "Undo", greyed out, with a paste sitting in
    /// mid-air waiting to be taken back.
    private var undoTargetName: String? {
        if canvas.hasFloatingItem, !canvas.isEditingText { return canvas.floatingActionName }
        return docUndoManager.canUndo ? docUndoManager.undoActionName : nil
    }

    /// Whether a state-dependent command can run right now. One answer for both
    /// validators: the menu asks through `validateMenuItem`, the toolbar through
    /// `validateToolbarItem`, and a command that is live in one and dead in the other is
    /// exactly the bug this exists to prevent.
    private func canPerform(_ action: Selector?) -> Bool {
        switch action {
        case #selector(undoAction(_:)): return undoTargetName != nil
        case #selector(redoAction(_:)): return docUndoManager.canRedo
        case #selector(cropToSelection(_:)): return hasSelection
        case #selector(zoomIn(_:)): return canvas.canZoomIn
        case #selector(zoomOut(_:)): return canvas.canZoomOut
        default: return true
        }
    }

    /// A toolbar item never goes through `validateMenuItem`, and NSToolbarItem's own
    /// default answer is "the target responds to the action, so yes" — which for Undo and
    /// Redo is always true. Both buttons therefore looked available on a brand-new
    /// document and did nothing at all when pressed, and Crop looked available with
    /// nothing selected. Answering here is what greys them out.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { canPerform(item.action) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Unmodified shortcuts (the tool letters, and Backspace) must not steal
        // keystrokes while someone is typing.
        if item.action == #selector(selectTool(_:)) {
            if isTyping { return false }
            if let tool = Tool(rawValue: item.representedObject as? String ?? "") {
                item.state = (settings.tool == tool) ? .on : .off
            }
            return true
        }
        // "Delete Selection" is armed to a bare ⌫. It erases through
        // `PaintDocument.clear(mask:)`, whose nil-mask contract means the WHOLE canvas,
        // so while nothing is selected the item's own title is a lie and one stray
        // keystroke wipes the picture. It stays disabled until there is something to
        // delete — a selection, or a floating paste to throw away.
        if item.action == #selector(delete(_:)) {
            return !isTyping && (canvas.hasFloatingItem || canvas.selectionRect != nil)
        }
        switch item.action {
        case #selector(undoAction(_:)):
            item.title = undoTargetName.map { "Undo \($0)" } ?? "Undo"
            return canPerform(item.action)
        case #selector(redoAction(_:)):
            item.title = docUndoManager.canRedo ? "Redo \(docUndoManager.redoActionName)" : "Redo"
            return canPerform(item.action)
        case #selector(cropToSelection(_:)), #selector(deselect(_:)), #selector(cut(_:)):
            return hasSelection
        case #selector(fillSelection(_:)):
            // ⌘⌫, and the same whole-canvas trap as Delete.
            return !isTyping && canvas.selectionRect != nil
        case #selector(placeFloating(_:)):
            // Plain Return: must never be stolen from a dialog or a text field.
            return !isTyping && canvas.hasFloatingItem
        case #selector(paste(_:)):
            // Text or an empty clipboard leaves Paste enabled and doing nothing at all
            // unless someone asks. See `PaintboxApp.canPasteImage`.
            return PaintboxApp.canPasteImage()
        case #selector(saveDocument(_:)):
            return true
        default:
            // Everything else the menu and the toolbar share an answer for — the zoom
            // ends, today. Falling through to the same function is what keeps a command
            // from being live in one place and dead in the other.
            return canPerform(item.action)
        }
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool { reviewUnsavedChanges(verb: "closing") }

    /// Save / Don't Save / Cancel. True means the caller may go ahead — the work was
    /// saved, or deliberately thrown away.
    ///
    /// Closing a window and quitting the app are completely separate paths in AppKit:
    /// `NSApplication.terminate` never sends `windowShouldClose(_:)`, and this is not an
    /// NSDocument app, so nothing reviewed unsaved work on ⌘Q at all. Both paths come
    /// through here now — see `PaintboxApp.applicationShouldTerminate`.
    func reviewUnsavedChanges(verb: String) -> Bool {
        canvas.finishPendingEdits()
        guard paintDocument.isDirty else { return true }
        // Quitting asks each window in turn, so the one being asked about has to be the
        // one in front, or the alert names a document nobody can see.
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(paintDocument.displayName)” before \(verb)?"
        alert.informativeText = "If you don’t save, your changes will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveBeforeClosing(panel: runModalSavePanel)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// The Save button in that alert. True means the work is on disk and the window may go.
    ///
    /// An untitled document has no file to write, so Save here IS Save As — and the
    /// panel it needs has to be MODAL, because this answer is what decides whether the
    /// window closes and a sheet answers long after it has been given. Put up as a
    /// sheet, ⌘W on a new drawing both opened a save panel and refused the close, so
    /// the picture was written and the window stayed, waiting to be closed a second
    /// time; on ⌘Q the quit was cancelled with a panel on screen and no way to tell
    /// whether the app was going to quit or not.
    ///
    /// `panel` is handed in so the self-test can drive this branch without a panel on
    /// screen — the same seam `performSave` uses.
    func saveBeforeClosing(panel runPanel: (String?) -> Bool) -> Bool {
        // A save that was cancelled or that failed leaves the document dirty, and must
        // not let the window close over it. Both halves are checked: the panel reports
        // what it did, the document reports where it stands.
        performSave(panel: runPanel) && !paintDocument.isDirty
    }

    func windowWillClose(_ notification: Notification) {
        // Each undo step holds a whole canvas, so a closed window must let go of its
        // stack now rather than whenever the last reference to it happens to drain.
        docUndoManager.removeAllActions()
        // Nothing may be left in mid-air over a document whose window has gone. The
        // review path gets here having already committed a pending paste or text box —
        // `reviewUnsavedChanges` calls `finishPendingEdits` first, which is what put it
        // in the alert the user answered. A close that skipped the review did not, and
        // then the only reference to a pasted image was a canvas nobody can see, holding
        // a commit that could still be asked for. Discarded rather than stamped: the
        // save decision has already been made and this is no place to change the picture.
        canvas.cancelFloating()
        canvas.cancelTextIfEditing()
        canvas.cancelDrag()
        canvas.stopAnimating()
        PaintboxApp.shared.forget(self)
    }
}

import AppKit
import UniformTypeIdentifiers

/// Whoever the shared colour and font panels are editing for. A protocol rather than
/// `PaintWindowController` directly so the self-test can watch the reference zero out
/// without building a window.
protocol PanelClient: AnyObject {
    func panelPicked(color: NSColor, foreground: Bool)
    func panelPicked(font manager: NSFontManager)
}

final class PaintboxApp: NSObject, NSApplicationDelegate {
    static let shared = PaintboxApp()

    private var controllers: [PaintWindowController] = []

    /// `NSMenu.delegate` is weak, so the thing that fills Open Recent in has to be owned
    /// by something that outlives the menu bar.
    private let recentDocuments = RecentDocumentsMenu()

    /// The colour panel and the font manager are process-wide singletons, and
    /// `-[NSColorPanel setTarget:]` is a bare setter: the panel neither retains its
    /// target nor zeroes the pointer when the target dies. A window controller is
    /// therefore the one thing it must never be given — it is deallocated the moment its
    /// window closes, and the next drag of a slider messages freed memory, which is a
    /// crash with every other window's unsaved work in it.
    ///
    /// So the target is this object, which lives as long as the process, and the window
    /// it is editing for is held WEAKLY here. When that window closes the reference
    /// zeroes by itself; the panel then falls through to whichever paint window is in
    /// front, which is also the behaviour people expect from a floating palette.
    private weak var colorClient: PanelClient?
    private var colorPanelWantsForeground = true
    private weak var fontClient: PanelClient?

    /// The window a panel should act on now: the one that opened it if it is still
    /// there, otherwise the front one.
    private func client(_ held: PanelClient?) -> PanelClient? {
        held ?? (NSApp.mainWindow?.windowController as? PaintWindowController) ?? controllers.first
    }

    /// Point the shared colour panel at `client` without putting it on screen. Split out
    /// from `showColorPanel` so the self-test can exercise the routing headlessly.
    func routeColorPanel(to client: PanelClient, foreground: Bool) {
        colorClient = client
        colorPanelWantsForeground = foreground
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = true
    }

    func showColorPanel(for client: PanelClient, foreground: Bool, initial: NSColor) {
        routeColorPanel(to: client, foreground: foreground)
        NSColorPanel.shared.color = initial
        NSColorPanel.shared.makeKeyAndOrderFront(nil)
    }

    @objc func colorPanelChanged(_ sender: NSColorPanel) {
        deliver(color: sender.color)
    }

    /// The whole of what a colour change does, with no panel involved, so a test can
    /// send one after the window it came from has gone.
    func deliver(color: NSColor) {
        client(colorClient)?.panelPicked(color: color.usingColorSpace(.sRGB) ?? color,
                                         foreground: colorPanelWantsForeground)
    }

    /// True while a live window is listening. The test asserts this goes false on its
    /// own when the window is released.
    var colorPanelHasLiveClient: Bool { colorClient != nil }

    /// `NSFontManager.target` IS declared weak in the SDK, so this one was never a
    /// dangling pointer — but a weak target that zeroes silently leaves the font panel
    /// doing nothing at all once its window closes. Routing it the same way means it
    /// keeps working on the front window instead.
    func showFontPanel(for client: PanelClient, current: NSFont) {
        fontClient = client
        let fm = NSFontManager.shared
        fm.target = self
        fm.setSelectedFont(current, isMultiple: false)
        fm.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let fm = sender else { return }
        client(fontClient)?.panelPicked(font: fm)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        if controllers.isEmpty {
            // Open straight onto a blank sheet. File ▸ New… is the one that asks for a size.
            present(PaintDocument(width: 1024, height: 768, fill: .white))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A copy that nobody has pasted yet is a promise this process still owes. Quitting
    /// on it would take the picture off the user's clipboard with us, so it is redeemed
    /// here — the one place the deferred encode in `PasteboardImage` has to happen
    /// whether or not anything ever asked for it.
    func applicationWillTerminate(_ notification: Notification) {
        PasteboardImage.redeemOutstandingPromise()
    }

    /// ⌘Q used to throw away unsaved work without a word.
    ///
    /// `NSApplication.terminate(_:)` does NOT send `windowShouldClose(_:)` to open
    /// windows, and Paintbox is not an NSDocument app, so with no
    /// `applicationShouldTerminate` at all the careful Save / Don't Save / Cancel alert
    /// was reachable by ⌘W and by nothing else. Every window with unsaved work is asked
    /// here, in front-to-back order, and any Cancel stops the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllersToReviewOnQuit() where !controller.reviewUnsavedChanges(verb: "quitting") {
            return .terminateCancel
        }
        return .terminateNow
    }

    /// The windows ⌘Q has to ask about, front one first so the alerts arrive in the
    /// order the user sees the windows. Separate from the delegate method so the
    /// self-test can check the set without an alert appearing on screen.
    func controllersToReviewOnQuit() -> [PaintWindowController] {
        let dirty = controllers.filter { $0.paintDocument.isDirty }
        let order = NSApp.orderedWindows
        return dirty.sorted { a, b in
            let ia = a.window.flatMap { order.firstIndex(of: $0) } ?? Int.max
            let ib = b.window.flatMap { order.firstIndex(of: $0) } ?? Int.max
            return ia < ib
        }
    }

    /// How a window controller joins `controllers`. `present` is the only caller in the
    /// app; the self-test uses it to put a document in front of the quit check.
    func adopt(_ controller: PaintWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(url: URL(fileURLWithPath: filename))
    }

    func forget(_ controller: PaintWindowController) {
        controllers.removeAll { $0 === controller }
    }

    private func present(_ doc: PaintDocument) {
        let c = PaintWindowController(document: doc)
        adopt(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - File actions

    @IBAction func newDocument(_ sender: Any?) {
        guard let size = Dialogs.newCanvasSize() else { return }
        if let why = CanvasLimits.rejection(for: size) {
            Dialogs.error(why, window: NSApp.keyWindow)
            return
        }
        let px = CanvasLimits.pixelSize(size)
        present(PaintDocument(width: px.width, height: px.height, fill: .white))
    }

    @IBAction func newFromClipboard(_ sender: Any?) {
        guard let img = PaintboxApp.imageFromPasteboard() else {
            Dialogs.error("There is no picture on the clipboard.", window: NSApp.keyWindow)
            return
        }
        let doc = PaintDocument(image: img)
        // The clipboard is not a file: this picture has never been saved anywhere, and
        // there is no undo step to take it back to, so it is dirty from birth.
        doc.markDirty()
        present(doc)
    }

    @IBAction func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // `.image` at the end is the catch-all that lets WebP and anything else
        // CoreGraphics can read through; the named ones just sort to the top.
        var types: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .image]
        for id in ["public.heic", "public.avif", "org.webmproject.webp"] {
            if let t = UTType(id) { types.insert(t, at: 3) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = open(url: url) }
    }

    /// The window already editing `url`, if there is one.
    ///
    /// Paths are compared with symlinks resolved and standardised, because the same file
    /// reaches `open(url:)` spelled several ways: Open Recent stores what was opened, the
    /// open panel hands back a standardised URL, and on macOS /tmp is a symlink to
    /// /private/tmp, so a plain `==` misses the duplicate that matters most.
    func existingController(for url: URL) -> PaintWindowController? {
        func key(_ u: URL) -> URL { u.resolvingSymlinksInPath().standardizedFileURL }
        let wanted = key(url)
        return controllers.first { $0.paintDocument.fileURL.map(key) == wanted }
    }

    @discardableResult
    func open(url: URL) -> Bool {
        // A file that is already open gets its window raised, not a second document on
        // the same path. Two windows editing one file each write the WHOLE picture on
        // save, so whichever was saved second silently threw the other's work away —
        // and the loser went on showing a clean title, so nothing ever said so. Raising
        // the existing window is also what every other Mac editor does, and it is what
        // makes Open Recent safe to click twice.
        if let existing = existingController(for: url) {
            existing.window?.makeKeyAndOrderFront(nil)
            RecentDocumentsMenu.remember(url)
            return true
        }
        // `PaintDocument.open` also records how many frames the file really had, which
        // is what stops a 40-frame GIF being overwritten with one frame in silence.
        guard let doc = PaintDocument.open(url: url) else {
            Dialogs.error("Paintbox could not read \(url.lastPathComponent).", window: NSApp.keyWindow)
            return false
        }
        present(doc)
        RecentDocumentsMenu.remember(url)
        return true
    }

    /// One item of File ▸ Open Recent. `open(url:)` reports a file that has since been
    /// moved or deleted, which is the only way this can fail.
    @IBAction func openRecentDocument(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        open(url: url)
    }

    @IBAction func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// Whether Paste has anything to paste.
    ///
    /// The Paste item validates against this rather than being permanently enabled, and
    /// it takes the pasteboard rather than reaching for the general one so the self-test
    /// can ask about a pasteboard of its own instead of overwriting the user's clipboard.
    /// It must stay the exact question `imageFromPasteboard` answers — an enabled Paste
    /// that then does nothing is the bug this pair exists to prevent — which is why the
    /// test checks the two together.
    static func canPasteImage(from pb: NSPasteboard = .general) -> Bool {
        pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func imageFromPasteboard(from pb: NSPasteboard = .general) -> CGImage? {
        // Our own copy, still the one on the board: hand back the picture itself rather
        // than asking the promise to encode a PNG so that the very next line can decode
        // it again. Copy-and-paste inside Paintbox then encodes nothing at all.
        if let ours = PasteboardImage.promised(on: pb) { return Bitmap.canonical(ours) }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
            return Bitmap.context(from: cg).makeImage()
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = objs.first,
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return Bitmap.context(from: cg).makeImage()
        }
        return nil
    }

    @IBAction func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Paintbox"
        alert.informativeText = """
        Tools are down the left with single-key shortcuts: \
        P pencil, B brush, E eraser, L line, A arrow, R rectangle, O ellipse, \
        F fill, I eyedropper, T text, S select, W magic wand.

        Magic wand selects pixels by colour; Option-click selects every matching \
        pixel in the picture. Delete then makes exactly that area transparent.

        Cut, Delete and Fill Selection need a selection and are greyed out without \
        one. Select All (Cmd-A) is how you ask for the whole picture.

        Paste floats: drag it, drag a corner to scale it (Shift keeps its shape), \
        Return places it, Escape throws it away.

        Blur and Pixelate work on the selection, or on the whole picture if \
        nothing is selected.

        Right-click (or Control-click) draws with the background colour.
        Hold Shift for straight lines, squares and circles.

        Resize Image scales the picture. Canvas Size changes the paper \
        around it without scaling. They are not the same thing.
        """
        alert.runModal()
    }

    // MARK: - Menus

    /// Not private, because the menu bar is where two of this app's shortcuts were dead
    /// keys that nothing could see: the self-test builds the real menu and fires real
    /// key events at it.
    func buildMenus() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Paintbox", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Paintbox", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Paintbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "New…", #selector(newDocument(_:)), "n", target: self)
        add(fileMenu, "New from Clipboard", #selector(newFromClipboard(_:)), "n", [.command, .shift], target: self)
        add(fileMenu, "Open…", #selector(openDocument(_:)), "o", target: self)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        // Built by hand, every time it opens. See RecentDocumentsMenu: the AppKit
        // shortcut for this needs a private selector and a nib, and what it did here was
        // hand us a submenu that was always empty.
        recentMenu.delegate = recentDocuments
        recentDocuments.target = self
        RecentDocumentsMenu.rebuild(recentMenu, urls: RecentDocumentsMenu.urls, target: self)
        recent.submenu = recentMenu
        fileMenu.addItem(recent)
        fileMenu.addItem(.separator())
        add(fileMenu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(fileMenu, "Save", #selector(PaintWindowController.saveDocument(_:)), "s")
        add(fileMenu, "Save As…", #selector(PaintWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(editMenu, "Undo", #selector(PaintWindowController.undoAction(_:)), "z")
        add(editMenu, "Redo", #selector(PaintWindowController.redoAction(_:)), "z", [.command, .shift])
        editMenu.addItem(.separator())
        add(editMenu, "Cut", #selector(PaintWindowController.cut(_:)), "x")
        add(editMenu, "Copy", #selector(PaintWindowController.copy(_:)), "c")
        // Just "Paste". The title used to carry its own instruction sheet — "Paste (drag
        // it, then press Return)" — because pasting stopped stamping and started
        // floating, and a menu item that reads like documentation was thought better
        // than a silent surprise. The instruction belongs where it is true, though, which
        // is while something is actually floating: see the status line in
        // PaintWindowController.updateStatus.
        add(editMenu, "Paste", #selector(PaintWindowController.paste(_:)), "v")
        add(editMenu, "Place Floating Paste", #selector(PaintWindowController.placeFloating(_:)),
            "\r", [])
        // U+007F (NSDeleteCharacter), not U+0008 (NSBackspaceCharacter): the Mac Delete
        // key sends the former, and a menu item keyed to the latter never matches it. Both
        // of these were therefore dead keys. Plain ⌫ still worked, but only by accident,
        // through CanvasView.keyDown — and that handler ignores modifiers, so ⌘⌫ fell
        // through to it and ERASED the selection where the item next to it promises to
        // fill it with the background colour.
        add(editMenu, "Delete Selection", #selector(PaintWindowController.delete(_:)), "\u{7f}", [])
        add(editMenu, "Fill Selection with Background", #selector(PaintWindowController.fillSelection(_:)), "\u{7f}", [.command])
        editMenu.addItem(.separator())
        add(editMenu, "Select All", #selector(PaintWindowController.selectAll(_:)), "a")
        add(editMenu, "Deselect", #selector(PaintWindowController.deselect(_:)), "d")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Image
        let imageItem = NSMenuItem()
        let imageMenu = NSMenu(title: "Image")
        add(imageMenu, "Crop to Selection", #selector(PaintWindowController.cropToSelection(_:)), "k")
        add(imageMenu, "Trim to Content", #selector(PaintWindowController.trimToContent(_:)), "k",
            [.command, .shift])
        imageMenu.addItem(.separator())
        add(imageMenu, "Resize Image… (scales the picture)", #selector(PaintWindowController.resizeImage(_:)), "r")
        add(imageMenu, "Canvas Size… (changes the paper)", #selector(PaintWindowController.changeCanvasSize(_:)), "r", [.command, .shift])
        imageMenu.addItem(.separator())
        add(imageMenu, "Flip Horizontal", #selector(PaintWindowController.flipHorizontal(_:)), "h", [.command, .control])
        add(imageMenu, "Flip Vertical", #selector(PaintWindowController.flipVertical(_:)), "v", [.command, .control])
        imageMenu.addItem(.separator())
        add(imageMenu, "Rotate 90° Clockwise", #selector(PaintWindowController.rotateClockwise(_:)), "]")
        add(imageMenu, "Rotate 90° Anticlockwise", #selector(PaintWindowController.rotateAnticlockwise(_:)), "[")
        add(imageMenu, "Rotate 180°", #selector(PaintWindowController.rotate180(_:)), "]", [.command, .shift])
        add(imageMenu, "Rotate by Angle…", #selector(PaintWindowController.rotateByAngle(_:)), "r", [.command, .control])
        imageMenu.addItem(.separator())
        add(imageMenu, "Remove Background", #selector(PaintWindowController.removeBackground(_:)), "b", [.command, .shift])
        imageMenu.addItem(.separator())
        add(imageMenu, "Blur…", #selector(PaintWindowController.blurSelection(_:)), "l", [.command, .shift])
        add(imageMenu, "Pixelate…", #selector(PaintWindowController.pixelateSelection(_:)), "p", [.command, .shift])
        add(imageMenu, "Adjustments…", #selector(PaintWindowController.showAdjustments(_:)), "a", [.command, .shift])
        add(imageMenu, "Grayscale", #selector(PaintWindowController.makeGrayscale(_:)), "g", [.command, .control])
        add(imageMenu, "Invert Colours", #selector(PaintWindowController.invertColors(_:)), "i", [.command, .control])
        imageItem.submenu = imageMenu
        mainMenu.addItem(imageItem)

        // Tools
        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        for tool in Tool.allCases {
            let item = NSMenuItem(title: tool.title, action: #selector(PaintWindowController.selectTool(_:)),
                                  keyEquivalent: tool.key)
            item.keyEquivalentModifierMask = []
            item.representedObject = tool.rawValue
            toolsMenu.addItem(item)
        }
        toolsMenu.addItem(.separator())
        add(toolsMenu, "Swap Foreground and Background", #selector(PaintWindowController.swapColors(_:)), "x", [.command, .shift])
        add(toolsMenu, "Foreground Colour…", #selector(PaintWindowController.chooseForegroundColor(_:)), "1", [.command])
        add(toolsMenu, "Background Colour…", #selector(PaintWindowController.chooseBackgroundColor(_:)), "2", [.command])
        add(toolsMenu, "Font…", #selector(PaintWindowController.chooseFont(_:)), "t", [.command])
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(viewMenu, "Zoom In", #selector(PaintWindowController.zoomIn(_:)), "+", [.command])
        // ⌘+ works: the plus is a shifted equals, so the event's
        // `charactersIgnoringModifiers` really is "+" and the item matches. What it
        // cannot match is ⌘= with no Shift, which is the key most people press for Zoom
        // In and what every browser and Preview accept. A hidden twin answers that:
        // hidden items are left out when the menu is drawn and still consulted when a
        // key equivalent is looked up.
        let zoomInEquals = add(viewMenu, "Zoom In", #selector(PaintWindowController.zoomIn(_:)),
                               "=", [.command])
        zoomInEquals.isHidden = true
        add(viewMenu, "Zoom Out", #selector(PaintWindowController.zoomOut(_:)), "-", [.command])
        add(viewMenu, "Actual Size (100%)", #selector(PaintWindowController.actualSize(_:)), "0")
        add(viewMenu, "Zoom to Fit", #selector(PaintWindowController.zoomToFit(_:)), "9")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Window
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        add(windowMenu, "Minimise", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        add(helpMenu, "Paintbox Quick Help", #selector(showHelp(_:)), "?", [.command], target: self)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                     _ mask: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = target
        menu.addItem(item)
        return item
    }
}

/// The app's own menu items say for themselves whether they can do anything.
///
/// Only the items whose target is the app delegate come here; a document's items are
/// validated by `PaintWindowController`. New from Clipboard was the one that lied: it was
/// permanently enabled, and choosing it with text or nothing on the clipboard put up an
/// alert to say what a greyed-out item says without interrupting anybody — which is
/// already how Paste behaves, and how Crop and Deselect behave.
extension PaintboxApp: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newFromClipboard(_:)):
            // The exact question `newFromClipboard` then asks: see `canPasteImage`.
            return PaintboxApp.canPasteImage()
        default:
            return true
        }
    }
}

/// File ▸ Open Recent, built by hand.
///
/// AppKit fills a recent-documents submenu in for you only if the menu carries the name
/// a nib would have given it, and there is no nib here — the previous version asked for
/// that name through a private selector, guarded by a responds-to check, which meant the
/// submenu was empty whenever the guard failed or AppKit wanted the menu registered some
/// other way. Always-empty is how it actually shipped, and a menu that never has anything
/// in it reads as a broken app rather than as a missing feature.
///
/// The list itself is not ours: `NSDocumentController` keeps it, through
/// `noteNewRecentDocumentURL`, in the app's own defaults and across launches. That part
/// is public API and was already being fed. All that was missing was drawing it.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {

    /// Where the list lives. One accessor, so nothing in the app reads the recent
    /// documents from anywhere else.
    static var urls: [URL] { NSDocumentController.shared.recentDocumentURLs }

    static func remember(_ url: URL) { NSDocumentController.shared.noteNewRecentDocumentURL(url) }

    /// The object the items act on. Weak for the usual reason — this is owned by that
    /// same object.
    weak var target: AnyObject?

    /// Fill `menu` from `urls`.
    ///
    /// Takes the list rather than reading it, which is what lets the self-test build the
    /// real menu from a known set of files without writing to the user's own recent
    /// documents.
    static func rebuild(_ menu: NSMenu, urls: [URL], target: AnyObject?) {
        menu.removeAllItems()
        guard !urls.isEmpty else {
            // Greyed out and honest, the way every other Mac app's empty one reads.
            let empty = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(PaintboxApp.openRecentDocument(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = url
            // Two pictures can easily share a file name; the path says which is which.
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(PaintboxApp.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        clear.target = target
        menu.addItem(clear)
    }

    /// Rebuilt on every open rather than kept in step with the list, because the list
    /// also changes from outside this process — a file opened from the Finder, or the
    /// system trimming it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        RecentDocumentsMenu.rebuild(menu, urls: RecentDocumentsMenu.urls, target: target)
    }
}

/// The picture Paintbox last put on a pasteboard, kept until somebody asks for the bytes
/// or another app takes the clipboard over.
///
/// ⌘C used to encode the copy as PNG *and* as TIFF before it returned, on the main
/// thread, whether or not either was ever wanted. On a 6000x4000 photograph that is a
/// window frozen for half a second — nearly two on grainy content, where PNG cannot
/// compress — and then 130 to 180 MB parked on the pasteboard for as long as the
/// clipboard holds it, most of it the uncompressed TIFF.
///
/// A pasteboard promise moves the encode to the paste, where at most one of the two
/// formats is ever asked for, and where the app doing the waiting is the one that asked.
/// The promise is a callback into this process, so the owner has to outlive the copy:
/// `current` is what keeps it alive, and it lets go the moment the pasteboard changes
/// hands. `PaintboxApp.applicationWillTerminate` makes good on an unpasted promise,
/// because a callback into a process that is about to stop existing is not one.
final class PasteboardImage: NSObject, NSPasteboardTypeOwner {

    /// Both formats are promised because both are read: PNG by everything modern, TIFF
    /// by anything old enough to predate it. Promising costs nothing per type; it was
    /// providing both eagerly that did.
    static let types: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// The one outstanding promise. A new copy replaces it; the pasteboard changing
    /// hands drops it, and the picture it was holding with it.
    static var current: PasteboardImage?

    let image: CGImage
    private weak var board: NSPasteboard?
    /// What the pasteboard's change count was when this promise was made. A promise is
    /// only ours while that still matches — the ownership callback needs a run loop, and
    /// a headless self-test does not have one.
    private var changeCount: Int = -1

    /// How many times the bytes have really been encoded. Read by the self-test to prove
    /// that a copy costs nothing until a paste asks for a format.
    private(set) var encodeCount = 0

    init(_ image: CGImage) { self.image = image }

    /// Declare the picture on `pb`, encoding nothing.
    @discardableResult
    static func place(_ image: CGImage, on pb: NSPasteboard) -> PasteboardImage {
        let owner = PasteboardImage(image)
        owner.board = pb
        owner.changeCount = pb.clearContents()
        pb.addTypes(types, owner: owner)
        current = owner
        return owner
    }

    /// The picture we promised on `pb`, if that promise is still the current one.
    static func promised(on pb: NSPasteboard) -> CGImage? {
        guard let owner = current, owner.board === pb, owner.changeCount == pb.changeCount
        else { return nil }
        return owner.image
    }

    /// Encode on demand. Kept separate from the delegate method so the self-test can ask
    /// for a format directly and compare the pixels that come back.
    func data(for type: NSPasteboard.PasteboardType) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: image.width, height: image.height)
        encodeCount += 1
        switch type {
        case .png: return rep.representation(using: .png, properties: [:])
        case .tiff: return rep.representation(using: .tiff, properties: [:])
        default: return nil
        }
    }

    func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = data(for: type) else { return }
        sender.setData(data, forType: type)
    }

    func pasteboardChangedOwner(_ sender: NSPasteboard) {
        if PasteboardImage.current === self { PasteboardImage.current = nil }
    }

    /// Make good on an outstanding promise before the process goes away. Only what is
    /// still promised is encoded: a type somebody already pasted is real data on the
    /// board by then, and asking for it again costs nothing.
    static func redeemOutstandingPromise() {
        guard let owner = current, let pb = owner.board, owner.changeCount == pb.changeCount
        else { return }
        for type in types { _ = pb.data(forType: type) }
    }
}

import AppKit

/// Small modal dialogs. Deliberately plain AppKit: no nibs exist in this build.
enum Dialogs {

    private static func field(_ value: Int, x: CGFloat, y: CGFloat, width: CGFloat = 80) -> NSTextField {
        let f = NSTextField(frame: CGRect(x: x, y: y, width: width, height: 22))
        f.stringValue = "\(value)"
        f.alignment = .right
        return f
    }

    private static func label(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat = 110) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.frame = CGRect(x: x, y: y + 3, width: width, height: 18)
        l.alignment = .right
        return l
    }

    // MARK: - New canvas

    static func newCanvasSize(default def: CGSize = CGSize(width: 1024, height: 768)) -> CGSize? {
        let alert = NSAlert()
        alert.messageText = "New Picture"
        alert.informativeText = "Size of the new canvas, in pixels. It starts filled with white."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 58))
        let wField = field(Int(def.width), x: 120, y: 30)
        let hField = field(Int(def.height), x: 120, y: 2)
        view.addSubview(label("Width:", x: 0, y: 30))
        view.addSubview(wField)
        view.addSubview(label("Height:", x: 0, y: 2))
        view.addSubview(hField)
        alert.accessoryView = view
        alert.window.initialFirstResponder = wField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return typedSize(wField, hField, default: def)
    }

    /// What two size fields are asking for, unclamped on purpose: the caller checks it
    /// against `CanvasLimits` and can then name the size it is refusing. Read as a
    /// Double so "1e400" comes back as infinity — which `CanvasLimits` refuses — rather
    /// than as a silent fall back to the default.
    static func typedSize(_ wField: NSTextField, _ hField: NSTextField, default def: CGSize) -> CGSize {
        let w = Double(wField.stringValue) ?? Double(def.width)
        let h = Double(hField.stringValue) ?? Double(def.height)
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    // MARK: - Resize image (resample)

    enum ResizeMode: Int { case pixels = 0, percent = 1 }

    /// The size the two resize fields are asking for. Pure, so the percent arithmetic —
    /// the one place a typo turns into a terabyte — can be checked by the self-test.
    ///
    /// Unclamped, again deliberately: `CanvasLimits` decides what is too big, and it can
    /// only say "that would make a 51200 × 38400 picture" if it is handed the size that
    /// was actually asked for.
    static func requestedSize(mode: ResizeMode, width: String, height: String,
                              current: CGSize) -> CGSize {
        let wVal = Double(width) ?? Double(current.width)
        let hVal = Double(height) ?? Double(current.height)
        switch mode {
        case .percent:
            return CGSize(width: (current.width * wVal / 100).rounded(),
                          height: (current.height * hVal / 100).rounded())
        case .pixels:
            return CGSize(width: wVal.rounded(), height: hVal.rounded())
        }
    }

    /// What the Resize dialog shows under its fields: the pixel size the numbers in them
    /// are currently asking for.
    ///
    /// It is live because that is when a typo in the Percent field is obvious. The field
    /// starts at "100", one extra zero asks for a picture a hundred times each way, and
    /// until this line existed the only way to find that out was to press Resize and
    /// read the refusal. The refusal still has the full sentence and the limit in it —
    /// this is a readout, not a second error message, so it names the size and says only
    /// that it is too big.
    static func resizePreview(mode: ResizeMode, width: String, height: String,
                              current: CGSize) -> String {
        let size = requestedSize(mode: mode, width: width, height: height, current: current)
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            return "not a size Paintbox can use"
        }
        // Formatted from the Double, not from an Int: this runs on every keystroke,
        // including the ones that ask for 1e30, and Int(1e30) is a trap.
        let asked = String(format: "%.0f × %.0f pixels", Double(size.width), Double(size.height))
        return CanvasLimits.rejection(for: size) == nil ? asked : asked + " — too big"
    }

    /// Returns the new pixel size, or nil if cancelled.
    static func resizeImage(current: CGSize) -> CGSize? {
        let alert = NSAlert()
        alert.messageText = "Resize Image (resample the picture)"
        alert.informativeText = "This scales the picture itself. To add or trim blank space instead, use Image ▸ Canvas Size."
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 152))
        let mode = NSSegmentedControl(labels: ["Pixels", "Percent"], trackingMode: .selectOne,
                                      target: nil, action: nil)
        mode.frame = CGRect(x: 120, y: 124, width: 160, height: 24)
        mode.selectedSegment = 0
        view.addSubview(mode)

        let wField = field(Int(current.width), x: 120, y: 94)
        let hField = field(Int(current.height), x: 120, y: 66)
        view.addSubview(label("Width:", x: 0, y: 94))
        view.addSubview(wField)
        view.addSubview(label("Height:", x: 0, y: 66))
        view.addSubview(hField)

        let lock = NSButton(checkboxWithTitle: "Keep aspect ratio", target: nil, action: nil)
        lock.frame = CGRect(x: 120, y: 38, width: 190, height: 20)
        lock.state = .on
        view.addSubview(lock)

        let preview = NSTextField(labelWithString: "")
        preview.frame = CGRect(x: 0, y: 12, width: 316, height: 18)
        preview.alignment = .right
        preview.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = .secondaryLabelColor
        view.addSubview(preview)

        let helper = ResizeHelper(wField: wField, hField: hField, lock: lock, mode: mode,
                                  preview: preview, current: current)
        wField.delegate = helper
        hField.delegate = helper
        mode.target = helper
        mode.action = #selector(ResizeHelper.modeChanged(_:))
        alert.accessoryView = view
        alert.window.initialFirstResponder = wField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return requestedSize(mode: ResizeMode(rawValue: mode.selectedSegment) ?? .pixels,
                             width: wField.stringValue, height: hField.stringValue,
                             current: current)
    }

    /// Keeps the two fields in step when the aspect lock is on, and the pixel readout in
    /// step with both of them.
    final class ResizeHelper: NSObject, NSTextFieldDelegate {
        let wField: NSTextField, hField: NSTextField, lock: NSButton, mode: NSSegmentedControl
        let preview: NSTextField
        let current: CGSize
        private var updating = false
        init(wField: NSTextField, hField: NSTextField, lock: NSButton, mode: NSSegmentedControl,
             preview: NSTextField, current: CGSize) {
            self.wField = wField; self.hField = hField; self.lock = lock
            self.mode = mode; self.preview = preview; self.current = current
            super.init()
            objc_setAssociatedObject(wField, Unmanaged.passUnretained(self).toOpaque(), self, .OBJC_ASSOCIATION_RETAIN)
            updatePreview()
        }
        @objc func modeChanged(_ sender: NSSegmentedControl) {
            if sender.selectedSegment == 1 {
                wField.stringValue = "100"; hField.stringValue = "100"
            } else {
                wField.stringValue = "\(Int(current.width))"; hField.stringValue = "\(Int(current.height))"
            }
            updatePreview()
        }
        /// The readout. Called from everywhere the numbers can change, including the
        /// mirroring below, so it can never show a size neither field is asking for.
        func updatePreview() {
            preview.stringValue = Dialogs.resizePreview(
                mode: ResizeMode(rawValue: mode.selectedSegment) ?? .pixels,
                width: wField.stringValue, height: hField.stringValue, current: current)
        }
        func controlTextDidChange(_ note: Notification) {
            defer { updatePreview() }
            guard lock.state == .on, !updating, let f = note.object as? NSTextField else { return }
            updating = true
            defer { updating = false }
            if mode.selectedSegment == 1 {
                let v = f.stringValue
                if f === wField { hField.stringValue = v } else { wField.stringValue = v }
            } else {
                let ratio = current.height / max(1, current.width)
                if f === wField, let w = Double(f.stringValue) {
                    hField.stringValue = "\(max(1, Int((w * Double(ratio)).rounded())))"
                } else if f === hField, let h = Double(f.stringValue) {
                    wField.stringValue = "\(max(1, Int((h / Double(ratio)).rounded())))"
                }
            }
        }
    }

    // MARK: - Canvas size (change the paper)

    static func canvasSize(current: CGSize) -> (size: CGSize, anchor: Anchor)? {
        let alert = NSAlert()
        alert.messageText = "Canvas Size (add or trim blank space)"
        alert.informativeText = "This does NOT scale the picture. The picture keeps its pixels; the canvas around it grows or shrinks. New space is filled with the background colour."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 330, height: 132))
        let wField = field(Int(current.width), x: 120, y: 104)
        let hField = field(Int(current.height), x: 120, y: 76)
        view.addSubview(label("Width:", x: 0, y: 104))
        view.addSubview(wField)
        view.addSubview(label("Height:", x: 0, y: 76))
        view.addSubview(hField)
        view.addSubview(label("Anchor:", x: 0, y: 40))

        var anchorButtons: [NSButton] = []
        let holder = AnchorHolder()
        for (i, anchor) in Anchor.allCases.enumerated() {
            let col = i % 3, row = i / 3
            let b = NSButton(frame: CGRect(x: 120 + CGFloat(col) * 26, y: 54 - CGFloat(row) * 26,
                                           width: 26, height: 26))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.title = "·"
            b.toolTip = anchor.label
            b.tag = anchor.rawValue
            b.target = holder
            b.action = #selector(AnchorHolder.pick(_:))
            if anchor == .center { b.state = .on }
            view.addSubview(b)
            anchorButtons.append(b)
        }
        holder.buttons = anchorButtons
        alert.accessoryView = view
        alert.window.initialFirstResponder = wField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (typedSize(wField, hField, default: current), holder.anchor)
    }

    final class AnchorHolder: NSObject {
        var anchor: Anchor = .center
        var buttons: [NSButton] = []
        @objc func pick(_ sender: NSButton) {
            anchor = Anchor(rawValue: sender.tag) ?? .center
            for b in buttons { b.state = (b === sender) ? .on : .off }
        }
    }

    // MARK: - Rotate by angle

    static func rotationAngle() -> CGFloat? {
        let alert = NSAlert()
        alert.messageText = "Rotate by Angle"
        alert.informativeText = "Positive angles turn clockwise. The canvas grows to fit and the new corners are transparent."
        alert.addButton(withTitle: "Rotate")
        alert.addButton(withTitle: "Cancel")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 26))
        let f = NSTextField(frame: CGRect(x: 100, y: 2, width: 80, height: 22))
        f.stringValue = "15"
        f.alignment = .right
        view.addSubview(label("Degrees:", x: 0, y: 0, width: 92))
        view.addSubview(f)
        alert.accessoryView = view
        alert.window.initialFirstResponder = f
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return parseAngle(f.stringValue)
    }

    /// Degrees from what someone typed, or nil for anything that is not an angle.
    ///
    /// `Double("inf")`, `Double("nan")` and `Double("1e400")` all succeed — the last one
    /// overflows to infinity — and a non-finite angle makes a NaN bounding box, which
    /// killed the app outright at `Int(box.width.rounded(.up))`. Whole turns are folded
    /// away too, so "3600" is a no-op rather than ten laps of the same arithmetic.
    static func parseAngle(_ text: String) -> CGFloat? {
        guard let d = Double(text.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
        return CGFloat(d.truncatingRemainder(dividingBy: 360))
    }

    // MARK: - Errors

    static func error(_ message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paintbox"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// Accessory view for the save panel: every format this Mac can write, plus a quality
/// slider that only wakes up for the lossy ones.
final class SaveOptionsView: NSView {
    let formatPopup = NSPopUpButton(frame: CGRect(x: 80, y: 54, width: 230, height: 24))
    let qualitySlider = NSSlider(frame: CGRect(x: 80, y: 26, width: 160, height: 22))
    let qualityLabel = NSTextField(labelWithString: "80%")
    private let note = NSTextField(labelWithString: "")
    weak var panel: NSSavePanel?

    private let formats = SaveFormat.available

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 330, height: 92))
        let l1 = NSTextField(labelWithString: "Format:")
        l1.frame = CGRect(x: 0, y: 58, width: 74, height: 18)
        l1.alignment = .right
        addSubview(l1)
        formatPopup.addItems(withTitles: formats.map { $0.menuTitle })
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        addSubview(formatPopup)

        let l2 = NSTextField(labelWithString: "Quality:")
        l2.frame = CGRect(x: 0, y: 28, width: 74, height: 18)
        l2.alignment = .right
        addSubview(l2)
        qualitySlider.minValue = 10
        qualitySlider.maxValue = 100
        qualitySlider.doubleValue = 80
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        addSubview(qualitySlider)
        qualityLabel.frame = CGRect(x: 250, y: 28, width: 60, height: 18)
        qualityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addSubview(qualityLabel)

        note.frame = CGRect(x: 6, y: 4, width: 318, height: 16)
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        addSubview(note)
        updateEnabled()
    }
    required init?(coder: NSCoder) { fatalError() }

    var format: SaveFormat {
        let i = formatPopup.indexOfSelectedItem
        return (i >= 0 && i < formats.count) ? formats[i] : .png
    }
    var quality: CGFloat { CGFloat(qualitySlider.doubleValue / 100) }

    func select(_ format: SaveFormat) {
        if let i = formats.firstIndex(of: format) { formatPopup.selectItem(at: i) }
        updateEnabled()
    }

    @objc private func formatChanged() {
        updateEnabled()
        if let t = format.utType { panel?.allowedContentTypes = [t] }
    }
    @objc private func qualityChanged() {
        qualityLabel.stringValue = "\(Int(qualitySlider.doubleValue))%"
    }
    private func updateEnabled() {
        let f = format
        qualitySlider.isEnabled = f.isLossy
        qualityLabel.textColor = f.isLossy ? .labelColor : .disabledControlTextColor
        qualityLabel.stringValue = "\(Int(qualitySlider.doubleValue))%"
        switch f {
        case .jpeg: note.stringValue = "JPEG has no transparency: it is flattened onto the background colour."
        case .gif: note.stringValue = "GIF: 256 colours, and soft edges are matted onto the background colour."
        case .bmp: note.stringValue = "BMP is uncompressed, so the file will be large."
        default: note.stringValue = "Transparency is kept. macOS cannot write WebP, so it is not offered."
        }
    }
}

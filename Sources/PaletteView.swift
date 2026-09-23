import AppKit

/// A small square that shows a colour and reports left/right clicks separately.
final class SwatchButton: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var onLeft: ((NSColor) -> Void)?
    var onRight: ((NSColor) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor(white: 0.35, alpha: 1).setStroke()
        color.setFill()
        let p = NSBezierPath(rect: r)
        p.fill()
        p.lineWidth = 1
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) { onLeft?(color) }
    override func rightMouseDown(with event: NSEvent) { onRight?(color) }
}

/// Foreground-over-background colour wells, MS Paint style.
final class ColorWellsView: NSView {
    var foreground: NSColor = .black { didSet { needsDisplay = true } }
    var background: NSColor = .white { didSet { needsDisplay = true } }
    var onPickForeground: (() -> Void)?
    var onPickBackground: (() -> Void)?
    var onSwap: (() -> Void)?

    private var fgRect: CGRect { CGRect(x: 2, y: bounds.height - 30, width: 30, height: 28) }
    private var bgRect: CGRect { CGRect(x: 20, y: bounds.height - 44, width: 30, height: 28) }
    private var swapRect: CGRect { CGRect(x: 56, y: bounds.height - 40, width: 22, height: 22) }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        func well(_ r: CGRect, _ c: NSColor) {
            NSColor.white.setFill(); NSBezierPath(rect: r.insetBy(dx: -2, dy: -2)).fill()
            // A checkerboard under the swatch, so a colour with alpha below 1 — which the
            // system picker offers by default, and which the eyedropper hands you from any
            // soft edge — LOOKS translucent. Painted flat on white it looked like an
            // ordinary pale colour, and the user had no way to tell why their strokes were
            // coming out faint or not at all.
            NSColor(white: 0.84, alpha: 1).setFill()
            let square: CGFloat = 5
            var y = r.minY
            while y < r.maxY {
                var x = r.minX
                while x < r.maxX {
                    if (Int((x - r.minX) / square) + Int((y - r.minY) / square)) % 2 == 1 {
                        CGRect(x: x, y: y, width: min(square, r.maxX - x),
                               height: min(square, r.maxY - y)).fill()
                    }
                    x += square
                }
                y += square
            }
            c.setFill(); NSBezierPath(rect: r).fill()
            NSColor(white: 0.3, alpha: 1).setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 1; p.stroke()
        }
        well(bgRect, background)
        well(fgRect, foreground)
        let arrow = NSAttributedString(string: "⇄", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        arrow.draw(at: CGPoint(x: swapRect.minX + 3, y: swapRect.minY + 2))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if swapRect.contains(p) { onSwap?() }
        else if fgRect.contains(p) { onPickForeground?() }
        else if bgRect.insetBy(dx: -2, dy: -2).contains(p) { onPickBackground?() }
    }
}

/// The left-hand tool palette: tools, colours, and the four settings sliders.
final class PaletteView: NSView {
    static let preferredWidth: CGFloat = 156

    private let settings: ToolSettings
    private var toolButtons: [Tool: NSButton] = [:]
    private let wells = ColorWellsView()
    private let sizeSlider = NSSlider()
    private let strokeSlider = NSSlider()
    private let toleranceSlider = NSSlider()
    private let wandSlider = NSSlider()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let strokeLabel = NSTextField(labelWithString: "")
    private let toleranceLabel = NSTextField(labelWithString: "")
    private let wandLabel = NSTextField(labelWithString: "")
    private let styleControl = NSSegmentedControl(labels: PaletteView.shapeStyleSegments.map(\.label),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    var onColorPanelRequest: ((Bool) -> Void)?

    /// Called the moment any palette control is used, before it changes a thing.
    ///
    /// The palette is the one place a click changes a tool or a setting without going
    /// through the window controller, which commits pending edits first. A swatch and the
    /// colour wells do not even take the keyboard, so the text editor's own end-of-editing
    /// never fires for them: without this, a half-typed text box would still be sitting on
    /// the canvas while the colour it is about to be drawn in changed underneath it.
    var onInteraction: (() -> Void)?

    // MARK: - The shape-style segments
    //
    // "Outline" is the honest word for the first one and it does not fit. The control is
    // 140pt wide inside a 156pt palette, so a segment has about 34pt for its text, and
    // AppKit drew "Out..." — which does not read as a choice, it reads as an interface
    // that was never finished. Widening it is not available (the palette's width is what
    // makes room for the canvas) so the words are short enough to draw and the full
    // meaning is in the tooltip. `shapeStyleFits` is the rule, checked by the self-test,
    // so a future rewording cannot quietly reintroduce the ellipsis.

    /// What each segment says, and what it means on hover.
    static let shapeStyleSegments: [(label: String, help: String)] = [
        ("Line", "Outline only, drawn in the line colour"),
        ("Fill", "Filled, with no outline"),
        ("Both", "Filled, with an outline round it"),
    ]

    /// Small enough that three labels fit across the palette, large enough to read.
    static let shapeStyleFont = NSFont.systemFont(ofSize: 11)

    /// One segment's width: the control's 140pt shared equally, rounded down.
    static let shapeStyleSegmentWidth: CGFloat = 46

    /// Whether a label draws whole in one segment. The 12pt is the padding AppKit puts
    /// either side of a segment's text; a label that needs more than what is left is the
    /// one that comes out with an ellipsis.
    static func shapeStyleFits(_ label: String) -> Bool {
        shapeStyleTextWidth(label) + 12 <= shapeStyleSegmentWidth
    }

    /// How wide `label` draws at the control's own font.
    static func shapeStyleTextWidth(_ label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: shapeStyleFont]).width
    }

    init(settings: ToolSettings) {
        self.settings = settings
        super.init(frame: CGRect(x: 0, y: 0, width: PaletteView.preferredWidth, height: 600))
        wantsLayer = true
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setStroke()
        let p = NSBezierPath()
        p.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0))
        p.line(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        p.stroke()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        var y: CGFloat = 10

        let toolsHeader = label("TOOLS")
        toolsHeader.frame = CGRect(x: 10, y: y, width: 120, height: 14)
        addSubview(toolsHeader)
        y += 18

        let cols = 2
        let bw: CGFloat = 66, bh: CGFloat = 40
        for (i, tool) in Tool.allCases.enumerated() {
            let col = i % cols, row = i / cols
            let b = NSButton(frame: CGRect(x: 8 + CGFloat(col) * (bw + 4),
                                           y: y + CGFloat(row) * (bh + 4), width: bw, height: bh))
            b.bezelStyle = .texturedRounded
            b.setButtonType(.pushOnPushOff)
            b.title = tool.key.uppercased()
            b.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            if let img = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title) {
                b.image = img
                b.imagePosition = .imageLeading
            } else {
                b.imagePosition = .noImage
            }
            b.toolTip = "\(tool.title)  (\(tool.key.uppercased()))"
            b.target = self
            b.action = #selector(toolClicked(_:))
            b.tag = i
            addSubview(b)
            toolButtons[tool] = b
        }
        y += CGFloat((Tool.allCases.count + cols - 1) / cols) * (bh + 4) + 10

        let colorHeader = label("COLOURS")
        colorHeader.frame = CGRect(x: 10, y: y, width: 120, height: 14)
        addSubview(colorHeader)
        y += 18

        wells.frame = CGRect(x: 8, y: y, width: 140, height: 48)
        wells.onPickForeground = { [weak self] in self?.onInteraction?(); self?.onColorPanelRequest?(true) }
        wells.onPickBackground = { [weak self] in self?.onInteraction?(); self?.onColorPanelRequest?(false) }
        wells.onSwap = { [weak self] in self?.onInteraction?(); self?.settings.swapColors(); self?.refresh() }
        addSubview(wells)
        y += 52

        let sw: CGFloat = 20
        for (i, c) in StandardPalette.colors.enumerated() {
            let col = i % 7, row = i / 7
            let s = SwatchButton(color: c)
            s.frame = CGRect(x: 8 + CGFloat(col) * sw, y: y + CGFloat(row) * sw, width: sw, height: sw)
            s.toolTip = "Click: foreground · Right-click: background"
            s.onLeft = { [weak self] c in self?.onInteraction?(); self?.settings.foreground = c; self?.refresh() }
            s.onRight = { [weak self] c in self?.onInteraction?(); self?.settings.background = c; self?.refresh() }
            addSubview(s)
        }
        y += CGFloat((StandardPalette.colors.count + 6) / 7) * sw + 8

        let more = NSButton(title: "Colour Picker…", target: self, action: #selector(moreColors(_:)))
        more.frame = CGRect(x: 8, y: y, width: 140, height: 22)
        more.bezelStyle = .rounded
        more.font = NSFont.systemFont(ofSize: 11)
        addSubview(more)
        y += 30

        let optHeader = label("OPTIONS")
        optHeader.frame = CGRect(x: 10, y: y, width: 120, height: 14)
        addSubview(optHeader)
        y += 18

        func addSlider(_ slider: NSSlider, _ lbl: NSTextField, title: String,
                       min: Double, max: Double, action: Selector) {
            let t = label(title)
            t.frame = CGRect(x: 10, y: y, width: 102, height: 14)
            addSubview(t)
            lbl.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .right
            lbl.frame = CGRect(x: 106, y: y, width: 42, height: 14)
            addSubview(lbl)
            y += 16
            slider.minValue = min
            slider.maxValue = max
            slider.target = self
            slider.action = action
            slider.isContinuous = true
            slider.frame = CGRect(x: 8, y: y, width: 140, height: 20)
            addSubview(slider)
            y += 26
        }

        addSlider(sizeSlider, sizeLabel, title: "BRUSH SIZE", min: 1, max: 96,
                  action: #selector(sizeChanged(_:)))
        addSlider(strokeSlider, strokeLabel, title: "LINE WIDTH", min: 1, max: 48,
                  action: #selector(strokeChanged(_:)))
        addSlider(toleranceSlider, toleranceLabel, title: "FILL TOLERANCE", min: 0, max: 255,
                  action: #selector(toleranceChanged(_:)))
        addSlider(wandSlider, wandLabel, title: "WAND TOLERANCE", min: 0, max: 255,
                  action: #selector(wandChanged(_:)))

        let styleHeader = label("SHAPE STYLE")
        styleHeader.frame = CGRect(x: 10, y: y, width: 120, height: 14)
        addSubview(styleHeader)
        y += 18
        styleControl.frame = CGRect(x: 8, y: y, width: 140, height: 22)
        styleControl.target = self
        styleControl.action = #selector(styleChanged(_:))
        styleControl.font = PaletteView.shapeStyleFont
        styleControl.segmentDistribution = .fillEqually
        for (i, segment) in PaletteView.shapeStyleSegments.enumerated() {
            styleControl.setWidth(PaletteView.shapeStyleSegmentWidth, forSegment: i)
            styleControl.setToolTip(segment.help, forSegment: i)
        }
        addSubview(styleControl)
        y += 30

        setFrameSize(CGSize(width: PaletteView.preferredWidth, height: y + 10))
    }

    var fittingHeight: CGFloat { frame.height }

    @objc private func toolClicked(_ sender: NSButton) {
        onInteraction?()
        settings.tool = Tool.allCases[sender.tag]
        refresh()
    }
    @objc private func sizeChanged(_ s: NSSlider) { onInteraction?(); settings.brushSize = CGFloat(s.doubleValue); refresh() }
    @objc private func strokeChanged(_ s: NSSlider) { onInteraction?(); settings.strokeWidth = CGFloat(s.doubleValue); refresh() }
    @objc private func toleranceChanged(_ s: NSSlider) { onInteraction?(); settings.tolerance = Int(s.doubleValue); refresh() }
    @objc private func wandChanged(_ s: NSSlider) { onInteraction?(); settings.wandTolerance = Int(s.doubleValue); refresh() }
    @objc private func styleChanged(_ s: NSSegmentedControl) {
        onInteraction?()
        settings.shapeStyle = ShapeStyle(rawValue: s.selectedSegment) ?? .outline
    }
    @objc private func moreColors(_ sender: Any?) { onInteraction?(); onColorPanelRequest?(true) }

    func refresh() {
        for (tool, button) in toolButtons {
            button.state = (tool == settings.tool) ? .on : .off
        }
        wells.foreground = settings.foreground
        wells.background = settings.background
        sizeSlider.doubleValue = Double(settings.brushSize)
        strokeSlider.doubleValue = Double(settings.strokeWidth)
        toleranceSlider.doubleValue = Double(settings.tolerance)
        wandSlider.doubleValue = Double(settings.wandTolerance)
        sizeLabel.stringValue = "\(Int(settings.brushSize)) px"
        strokeLabel.stringValue = "\(Int(settings.strokeWidth)) px"
        toleranceLabel.stringValue = "\(settings.tolerance)"
        wandLabel.stringValue = "\(settings.wandTolerance)"
        styleControl.selectedSegment = settings.shapeStyle.rawValue
    }
}

import AppKit
import UniformTypeIdentifiers

protocol CanvasViewDelegate: AnyObject {
    func canvasDidChangeSelection(_ view: CanvasView)
    func canvasDidChangeZoom(_ view: CanvasView)
    func canvas(_ view: CanvasView, hoveringAt point: CGPoint?)
    func canvasDidPickColor(_ view: CanvasView)
}

/// The pixel surface. Draws the document at `zoom` over a checkerboard, and owns
/// the direct-manipulation half of every tool.
final class CanvasView: NSView {
    let document: PaintDocument
    let settings: ToolSettings
    weak var delegate: CanvasViewDelegate?

    var zoom: CGFloat = 1 {
        didSet {
            guard zoom != oldValue else { return }
            resizeToImage()
            commitTextIfEditing()
            delegate?.canvasDidChangeZoom(self)
        }
    }

    /// The selection, as a mask the size of the canvas — not a rectangle. See
    /// SelectionMask.swift for why. Nil means nothing is selected.
    ///
    /// A mask of the wrong size is not a selection of anything: it is one byte per pixel
    /// of a canvas that no longer exists, so its rows are offset and its bounding box
    /// refers to coordinates off the picture. The window controller drops the selection
    /// on every size change, and every operation that walks a mask clamps to the canvas,
    /// but neither of those is a guarantee the selection's OWNER makes — the first is an
    /// observer that has to be wired up, the second is a promise repeated in four files.
    /// So the mask is handed out only while it still fits, and a resize under it reads as
    /// "nothing selected" rather than as a stale region.
    var selection: SelectionMask? {
        get {
            guard let s = storedSelection,
                  s.width == document.pixelWidth, s.height == document.pixelHeight else { return nil }
            return s
        }
        set { storedSelection = newValue }
    }

    private var storedSelection: SelectionMask? {
        didSet {
            ants = nil
            selectionStencil = nil
            needsDisplay = true
            delegate?.canvasDidChangeSelection(self)
            updateAntsTimer()
        }
    }

    /// The traced outline of `selection`, already scaled into view coordinates.
    ///
    /// Everything about this is a cache, because the ants redraw eight times a second
    /// and neither tracing the mask nor scaling the path may happen per frame: tracing a
    /// wand selection on a photograph walks millions of pixels, and `path.copy(using:)`
    /// allocated a fresh multi-hundred-megabyte path every frame, which is what used to
    /// wedge the window.
    private struct Ants {
        /// nil when the outline blew the segment budget: show the tint instead.
        let path: CGPath?
        let zoom: CGFloat
        /// The part of the canvas that was traced. Valid while the visible part of the
        /// selection is inside it.
        let traced: CGRect
    }
    private var ants: Ants?

    /// The mask as an image, built once and only for selections shown as a tint.
    private var selectionStencil: CGImage?

    /// The selection's bounding box, which is what the rectangle-shaped operations —
    /// crop, the paste origin, the status readout — still want.
    var selectionRect: CGRect? {
        guard let s = selection, !s.isEmpty else { return nil }
        return s.bounds
    }

    /// Replace the selection with one rectangle (nil deselects).
    func setSelection(rect: CGRect?) {
        guard let rect else { selection = nil; return }
        let r = rect.integral.intersection(document.bounds)
        guard r.width >= 1, r.height >= 1 else { selection = nil; return }
        selection = SelectionMask(width: document.pixelWidth, height: document.pixelHeight, rect: r)
    }

    func selectAllPixels() {
        selection = SelectionMask.all(width: document.pixelWidth, height: document.pixelHeight)
    }

    /// A pasted or dropped picture that has not landed yet. See FloatingItem.swift.
    private(set) var floating: FloatingItem?
    private enum FloatingDrag {
        case move(grab: CGPoint, origin: CGPoint)
        /// The corner the drag pivots about, taken when it began rather than read back
        /// off the frame the drag is changing. See `FloatingItem.resize`.
        case resize(anchor: CGPoint)
    }
    private var floatingDrag: FloatingDrag?

    // Drag state
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    /// Whether Shift was down at the last drag event. Stored rather than read at draw
    /// time so the PREVIEW can constrain itself exactly the way the commit will, and so
    /// pressing or releasing Shift part-way through a drag is picked up straight away.
    private var dragShift = false
    private var dragging = false
    private var dragUsesBackground = false
    private var lastPoint: CGPoint?
    /// Where the brush's last dab landed. Kept apart from `lastPoint` — which follows
    /// the pointer — because the brush's spacing is a property of the STROKE: the
    /// distance a segment does not spend on a dab has to carry into the next segment,
    /// or the dab count becomes a count of mouse events. See `Painter.brush`.
    private var brushAnchor: CGPoint?
    /// Shown while the selection tool is being dragged. Building a canvas-sized mask on
    /// every mouse-moved event would be pure waste; the mask is made once, on mouse-up.
    /// Readable so the self-test can check that the ants promise exactly the selection
    /// the mouse-up commits — which is the half of the square-selection bug that had no
    /// symptom until you looked at the status bar.
    private(set) var liveSelectionRect: CGRect?
    /// Why the last eyedropper click changed no colour, or nil when it did. Shown in the
    /// status line until the next click anywhere: a tool that quietly does nothing is
    /// indistinguishable from an app that has stopped answering.
    private(set) var pickNote: String?
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?

    // Inline text editing
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero

    init(document: PaintDocument, settings: ToolSettings) {
        self.document = document
        self.settings = settings
        super.init(frame: CGRect(origin: .zero, size: document.pixelSize))
        wantsLayer = true
        clipsToBounds = true
        registerForDraggedTypes([.fileURL])
        resizeToImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resizeToImage() {
        let s = CGSize(width: (document.pixelSize.width * zoom).rounded(),
                       height: (document.pixelSize.height * zoom).rounded())
        setFrameSize(s)
        needsDisplay = true
        if let sv = enclosingScrollView { sv.contentView.needsLayout = true }
    }

    // MARK: - Coordinates

    /// View point -> image pixel, top-left origin.
    func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
    }

    func viewRect(forImageRect r: CGRect) -> CGRect {
        CGRect(x: r.origin.x * zoom, y: r.origin.y * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    private func point(for event: NSEvent) -> CGPoint {
        imagePoint(convert(event.locationInWindow, from: nil))
    }

    /// The selection a drag from `a` to `b` asks for, in whole canvas pixels.
    ///
    /// **Shift really does mean square.** It did not. The old expression squared two
    /// fractional points and then undid its own work twice over:
    ///
    /// * `.integral` rounds the two axes OUTWARD and INDEPENDENTLY, so an exactly square
    ///   float rect became 40 × 41 whenever the fractional parts of its origin happened
    ///   to differ — which is most drags, since a mouse location is a float and
    ///   `imagePoint` then divides it by the zoom.
    /// * `.intersection(bounds)` clipped the square against the canvas edge with no
    ///   attempt to keep it square, so a Shift-drag off the bottom of the picture
    ///   committed as 400 × 100.
    ///
    /// Crop reads this rect, so "Shift for a square, then ⌘K" produced a picture that was
    /// not square. The status bar reported the truth, which was the only clue.
    ///
    /// So: clamp the pointer to the canvas FIRST, snap both corners to the pixel grid,
    /// and only then square — taking the largest side that still fits inside the canvas
    /// on both axes, so the clamp can shorten the square without unsquaring it. The
    /// result is already integral and already inside the canvas; nothing rounds it again.
    func selectionRect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        let w = CGFloat(document.pixelWidth), h = CGFloat(document.pixelHeight)
        func snap(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), w).rounded(), y: min(max(p.y, 0), h).rounded())
        }
        let s = snap(a), e = snap(b)
        var dx = e.x - s.x, dy = e.y - s.y
        if square {
            // Which way the square grows. A zero-length axis takes whichever side of the
            // start point has more room, so a straight-down Shift-drag still makes a box.
            let sx: CGFloat = dx != 0 ? (dx < 0 ? -1 : 1) : (w - s.x >= s.x ? 1 : -1)
            let sy: CGFloat = dy != 0 ? (dy < 0 ? -1 : 1) : (h - s.y >= s.y ? 1 : -1)
            let roomX = sx > 0 ? w - s.x : s.x
            let roomY = sy > 0 ? h - s.y : s.y
            let side = min(max(abs(dx), abs(dy)), roomX, roomY)
            dx = sx * side
            dy = sy * side
        }
        return CGRect(x: min(s.x, s.x + dx), y: min(s.y, s.y + dy),
                      width: abs(dx), height: abs(dy))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        drawCheckerboard(ctx, in: dirtyRect)

        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = zoom >= 1 ? .none : .high
        ctx.draw(document.image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        drawPreview(ctx)
        drawFloating(ctx)
        drawSelection(ctx)
    }

    private func drawCheckerboard(_ ctx: CGContext, in dirty: NSRect) {
        // Never paint outside our own bounds: the grey behind belongs to the scroll view.
        let rect = dirty.intersection(bounds)
        guard !rect.isEmpty else { return }
        let size: CGFloat = 8
        ctx.saveGState()
        ctx.clip(to: rect)
        defer { ctx.restoreGState() }
        ctx.setFillColor(NSColor(white: 1.0, alpha: 1).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        let x0 = (rect.minX / size).rounded(.down) * size
        let y0 = (rect.minY / size).rounded(.down) * size
        var y = y0
        while y < rect.maxY {
            var x = x0
            while x < rect.maxX {
                let ix = Int(x / size), iy = Int(y / size)
                if (ix + iy) % 2 == 1 {
                    ctx.fill(CGRect(x: x, y: y, width: size, height: size))
                }
                x += size
            }
            y += size
        }
    }

    private func drawPreview(_ ctx: CGContext) {
        guard dragging, let a = dragStart, let b = dragCurrent else { return }
        let stroke = dragUsesBackground ? settings.background : settings.foreground
        let fill = dragUsesBackground ? settings.foreground : settings.background
        ctx.saveGState()
        ctx.setLineWidth(max(1, settings.strokeWidth * zoom))
        ctx.setStrokeColor((stroke.usingColorSpace(.sRGB) ?? .black).cgColor)
        ctx.setFillColor((fill.usingColorSpace(.sRGB) ?? .white).cgColor)
        let va = CGPoint(x: a.x * zoom, y: a.y * zoom)
        let vb = CGPoint(x: b.x * zoom, y: b.y * zoom)
        switch settings.tool {
        case .line, .arrow:
            ctx.setLineCap(.round)
            if settings.tool == .arrow {
                previewArrow(ctx, from: va, to: vb, width: max(1, settings.strokeWidth * zoom),
                             color: stroke)
            } else {
                ctx.move(to: va)
                ctx.addLine(to: vb)
                ctx.strokePath()
            }
        case .rectangle, .ellipse:
            // The same geometry `end` commits, Shift included. The preview used to be
            // built straight from the unconstrained drag point, so holding Shift showed
            // you a wide oval and then stamped a circle.
            let r = viewRect(forImageRect: rectBetween(a, b, square: dragShift))
            let path = CGMutablePath()
            if settings.tool == .ellipse { path.addEllipse(in: r) } else { path.addRect(r) }
            if settings.shapeStyle == .filled || settings.shapeStyle == .both {
                ctx.addPath(path); ctx.fillPath()
            }
            if settings.shapeStyle == .outline || settings.shapeStyle == .both {
                ctx.addPath(path); ctx.strokePath()
            }
        default:
            break
        }
        ctx.restoreGState()
    }

    /// An arrow drawn in VIEW coordinates, for the live drag preview. Painter.arrow
    /// cannot be reused here because it flips against a bitmap's height, and the view is
    /// already flipped.
    private func previewArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint,
                              width: CGFloat, color: NSColor) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let head = min(len, max(9 * zoom, width * 4.5))
        let half = max(5 * zoom, width * 2.2)
        let shaftEnd = CGPoint(x: b.x - ux * head * 0.75, y: b.y - uy * head * 0.75)
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        ctx.move(to: a)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.setFillColor((color.usingColorSpace(.sRGB) ?? .black).cgColor)
        ctx.beginPath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawFloating(_ ctx: CGContext) {
        guard let item = floating else { return }
        let r = viewRect(forImageRect: item.frame)

        // A CGImage draws bottom-up, so it needs the same manual flip the document does.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = (zoom >= 1 && item.frame.size == item.naturalSize) ? .none : .high
        ctx.draw(item.image, in: CGRect(x: r.minX, y: bounds.height - r.maxY,
                                        width: r.width, height: r.height))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        for handle in FloatingHandle.allCases {
            let hr = viewRect(forImageRect: item.handleRect(handle, zoom: zoom))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(hr)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.stroke(hr.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
    }

    /// How many boundary segments the ants may cost. Forty thousand short lines is a
    /// path of a few megabytes that strokes in a millisecond or two; a wanded sky is
    /// three and a half million and neither of those is true.
    private static let antsSegmentBudget = 40_000

    /// How far beyond the visible area to trace, in image pixels, so that scrolling a
    /// little does not re-trace the mask.
    private static let antsMargin: CGFloat = 128

    private func drawSelection(_ ctx: CGContext) {
        if let live = liveSelectionRect {
            strokeAnts(ctx, path: CGPath(rect: viewRect(forImageRect: live), transform: nil))
            return
        }
        guard let sel = selection, !sel.isEmpty else { return }

        // A rectangle is four lines however big the canvas is, so it never needs any of
        // the machinery below — and that is every selection made with the Selection tool.
        if sel.isRectangular {
            strokeAnts(ctx, path: CGPath(rect: viewRect(forImageRect: sel.bounds), transform: nil))
            return
        }

        let needed = visibleImageRect.intersection(sel.bounds).integral
        if ants == nil || ants!.zoom != zoom || !ants!.traced.contains(needed) {
            ants = traceAnts(sel, around: needed)
            // A tinted selection has nothing to animate, so this is also where the
            // eight-times-a-second redraw of a huge canvas gets switched off.
            updateAntsTimer()
        }
        if let path = ants?.path {
            strokeAnts(ctx, path: path)
        } else {
            drawSelectionTint(ctx, sel)
        }
    }

    /// The part of the picture on screen, in image pixels. Falls back to the whole canvas
    /// when the view is not in a scroll view yet, which is the case in `--screenshot`.
    ///
    /// Readable so the self-test can check that a zoom step keeps looking at the same
    /// part of the picture.
    var visibleImageRect: CGRect {
        let v = visibleRect.isEmpty ? bounds : visibleRect
        return CGRect(x: v.minX / zoom, y: v.minY / zoom,
                      width: v.width / zoom, height: v.height / zoom)
    }

    private func traceAnts(_ sel: SelectionMask, around needed: CGRect) -> Ants {
        let traced = needed.insetBy(dx: -Self.antsMargin, dy: -Self.antsMargin)
            .intersection(sel.bounds).integral
        guard let path = sel.boundaryPath(in: traced, maxSegments: Self.antsSegmentBudget) else {
            return Ants(path: nil, zoom: zoom, traced: traced)
        }
        var t = CGAffineTransform(scaleX: zoom, y: zoom)
        return Ants(path: path.copy(using: &t) ?? path, zoom: zoom, traced: traced)
    }

    /// What a selection looks like when its outline is too intricate to stroke: the
    /// selected pixels tinted, drawn through the mask itself, plus a plain box round the
    /// whole thing so its extent is unmistakable. One image draw, whatever the shape.
    private func drawSelectionTint(_ ctx: CGContext, _ sel: SelectionMask) {
        if selectionStencil == nil { selectionStencil = sel.stencilImage() }
        guard let stencil = selectionStencil else {
            strokeAnts(ctx, path: CGPath(rect: viewRect(forImageRect: sel.bounds), transform: nil))
            return
        }
        ctx.saveGState()
        // Same manual flip the document image needs: a CGImage draws bottom-up.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(origin: .zero, size: bounds.size), mask: stencil)
        ctx.setFillColor(NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 0.35).cgColor)
        ctx.fill(CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.65).cgColor)
        ctx.stroke(viewRect(forImageRect: sel.bounds))
        ctx.restoreGState()
    }

    /// Two passes, black then dashed white, so the outline reads on any picture.
    private func strokeAnts(_ ctx: CGContext, path: CGPath) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// There are dashes to march when something is floating, or when the selection is
    /// being drawn as an outline. A tinted selection is static, and redrawing a
    /// 24-megapixel canvas eight times a second to animate nothing is exactly the
    /// freeze this avoids.
    private var somethingIsMarching: Bool {
        if floating != nil { return true }
        guard let sel = selection, !sel.isEmpty else { return false }
        if let ants, ants.path == nil { return false }
        return true
    }

    /// The only part of the view a marching-ants frame changes.
    ///
    /// Nothing moves between frames except the dash phase, and the dashes run along a
    /// path that stands still — so `needsDisplay = true` was asking AppKit to repaint the
    /// whole photograph, checkerboard and all, eight times a second in order to shift a
    /// dotted line by one pixel. Invalidating the outline's own box instead means the
    /// clip handed to `draw(_:)` covers a few thousand pixels rather than twenty-four
    /// million, and both the checkerboard and the document draw are already clipped by it.
    ///
    /// `.zero` when there is nothing marching, which is also when the timer is off.
    var antsRefreshRect: CGRect {
        var r = CGRect.null
        if let live = liveSelectionRect {
            r = r.union(viewRect(forImageRect: live))
        } else if let sel = selection, !sel.isEmpty {
            r = r.union(viewRect(forImageRect: sel.bounds))
        }
        if let item = floating {
            // The corner handles hang half outside the item's own frame, and they are
            // measured in view points, so the zoom does not come into it.
            let pad = FloatingItem.handleViewSize
            r = r.union(viewRect(forImageRect: item.frame).insetBy(dx: -pad, dy: -pad))
        }
        guard !r.isNull else { return .zero }
        // A one-point stroke straddles the boundary it is drawn on, so the box the ants
        // dirty is a shade bigger than the box they outline.
        return r.insetBy(dx: -2, dy: -2).intersection(bounds)
    }

    private func updateAntsTimer() {
        antsTimer?.invalidate()
        antsTimer = nil
        // No window, no animation. A view nobody can see must not be running eight
        // frames a second, and stating it here — rather than tidying up afterwards in
        // one teardown path — is what makes a stranded timer impossible rather than
        // merely unlikely.
        guard window != nil, somethingIsMarching else { return }
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.antsPhase = self.antsPhase.truncatingRemainder(dividingBy: 8) + 1
            self.setNeedsDisplay(self.antsRefreshRect)
        }
    }

    /// Whether the ants timer is running. Readable so the self-test can check that a
    /// view which has left its window is not still doing eight frames a second of work
    /// for nobody.
    var isAnimating: Bool { antsTimer != nil }

    /// Called when the window closes. The timer is held by the run loop, not by the
    /// view, so without this it goes on firing for the lifetime of the process.
    func stopAnimating() {
        antsTimer?.invalidate()
        antsTimer = nil
    }

    /// The window can also go away without `windowWillClose` — a view removed from its
    /// superview, a controller torn down in a different order — and a timer that outlives
    /// its window is the same waste whichever route got it there.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() } else { updateAntsTimer() }
    }

    deinit { antsTimer?.invalidate() }

    // MARK: - Mouse

    /// Everything a mouse event means to the tools, with AppKit taken out of it.
    ///
    /// The three handlers below take one of these rather than an NSEvent, because the
    /// drag handlers are exactly where a preview and the thing it previews can drift
    /// apart — and an NSEvent needs a window, a run loop and a screen, none of which the
    /// self-test has.
    struct DragInput {
        /// Image pixels, top-left origin.
        let point: CGPoint
        let shift: Bool
        /// Option: the magic wand's "every matching pixel in the picture" mode.
        let option: Bool
        /// Right-click or Control-click: use the background colour.
        let background: Bool

        init(point: CGPoint, shift: Bool = false, option: Bool = false, background: Bool = false) {
            self.point = point
            self.shift = shift
            self.option = option
            self.background = background
        }
    }

    private func input(_ event: NSEvent, background: Bool) -> DragInput {
        DragInput(point: point(for: event),
                  shift: event.modifierFlags.contains(.shift),
                  option: event.modifierFlags.contains(.option),
                  background: background)
    }

    override func mouseDown(with event: NSEvent) {
        begin(input(event, background: event.modifierFlags.contains(.control)))
    }
    override func mouseDragged(with event: NSEvent) { moveTo(input(event, background: dragUsesBackground)) }
    override func mouseUp(with event: NSEvent) { end(input(event, background: dragUsesBackground)) }
    override func rightMouseDown(with event: NSEvent) { begin(input(event, background: true)) }
    override func rightMouseDragged(with event: NSEvent) { moveTo(input(event, background: true)) }
    override func rightMouseUp(with event: NSEvent) { end(input(event, background: true)) }

    /// The boundary every painting tool draws inside, or nil when nothing is selected.
    ///
    /// Delete, Cut and the filters have always respected the selection; the pencil,
    /// brush, eraser, shapes, text and fill did not, so marching ants drawn round the one part
    /// of the picture you wanted to change protected it from half the app. The ants
    /// promise containment, so the tools honour it. Nothing selected still means the
    /// whole canvas.
    private var drawMask: SelectionMask? {
        guard let s = selection, !s.isEmpty else { return nil }
        return s
    }

    private var primaryColor: NSColor { dragUsesBackground ? settings.background : settings.foreground }
    private var secondaryColor: NSColor { dragUsesBackground ? settings.foreground : settings.background }

    /// The shape the rectangle and ellipse tools would commit if the drag ended now, in
    /// image pixels. `drawPreview` draws exactly this and `end` commits exactly this, so
    /// the two cannot disagree about what Shift did.
    var pendingShapeRect: CGRect? {
        guard dragging, let a = dragStart, let b = dragCurrent, settings.tool.usesShapeStyle else { return nil }
        return rectBetween(a, b, square: dragShift)
    }

    /// Throw away a drag in progress without committing anything it was going to draw.
    ///
    /// A drag that never sees its mouse-up leaves `dragging` true, a shape preview on
    /// screen and — worst of the three — `liveSelectionRect` set, which `drawSelection`
    /// draws IN PLACE OF the real selection. So marching ants stayed round a region that
    /// was never selected, over the top of the selection that actually was, until the
    /// next select-drag ended. The up event is missed whenever something else takes the
    /// mouse mid-drag, and the bitmap can be replaced underneath a live drag from the
    /// keyboard — ⌘K, ⌘Z — after which `dragStart` is a point on a canvas that no longer
    /// exists and the mouse-up would stamp a shape at coordinates that mean nothing.
    func cancelDrag() {
        guard dragging || dragStart != nil || liveSelectionRect != nil || floatingDrag != nil else { return }
        dragging = false
        dragStart = nil
        dragCurrent = nil
        dragShift = false
        lastPoint = nil
        brushAnchor = nil
        liveSelectionRect = nil
        floatingDrag = nil
        needsDisplay = true
    }

    func begin(_ drag: DragInput) {
        let background = drag.background
        window?.makeFirstResponder(self)
        // Whatever the last drag left behind goes now, before this one is set up: a
        // mouse-down is proof that no earlier drag is still running, whether or not its
        // mouse-up ever arrived.
        cancelDrag()
        // The eyedropper's note is about the click that is being replaced, so it goes
        // with it. Set again below if this click has nothing to pick up either.
        pickNote = nil

        // A floating paste owns the mouse until the user clicks somewhere else. Clicking
        // away commits it and then lets that same click do its normal job, which is what
        // every other editor does and what people expect.
        if let item = floating {
            let fp = drag.point
            if let handle = item.hitHandle(fp, zoom: zoom) {
                floatingDrag = .resize(anchor: item.anchor(for: handle))
                dragging = false
                return
            }
            if item.frame.contains(fp) {
                floatingDrag = .move(grab: fp, origin: item.frame.origin)
                dragging = false
                return
            }
            commitFloating()
        }
        commitTextIfEditing()
        dragUsesBackground = background
        let p = drag.point
        dragStart = p
        dragCurrent = p
        dragShift = drag.shift
        lastPoint = p
        // Cleared here as well as in `end`, so a stroke that never saw its mouse-up —
        // the window losing the mouse, say — cannot leak its anchor into the next one.
        brushAnchor = nil
        dragging = true

        switch settings.tool {
        case .pencil:
            document.registerUndo(name: "Pencil")
            Painter.pencil(in: document.context, from: p, to: p, color: primaryColor, mask: drawMask)
            document.touch()
        case .brush:
            document.registerUndo(name: "Brush")
            Painter.brushDab(in: document.context, at: p, size: settings.brushSize,
                             color: primaryColor, mask: drawMask)
            brushAnchor = p
            document.touch()
        case .eraser:
            document.registerUndo(name: "Eraser")
            Painter.erase(in: document.context, from: p, to: p, size: settings.brushSize,
                          color: background ? settings.background : nil, mask: drawMask)
            document.touch()
        case .bucket:
            document.registerUndo(name: "Paint Bucket")
            Painter.floodFill(in: document.context, at: p, color: primaryColor,
                              tolerance: settings.tolerance, mask: drawMask)
            document.touch()
            dragging = false
        case .eyedropper:
            // Clamped and floored the same way the bucket and the wand already do.
            // `resizeToImage` rounds the view's size, so at a fractional zoom the view can
            // be a hair wider than the picture and a click on the last column produced a
            // coordinate past the edge. `sample` answers that with fully transparent black
            // rather than failing, which handed the user an invisible colour with nothing
            // on screen to say so. Bare `Int()` also truncates towards zero rather than
            // flooring, so it mishandled negatives differently from its two neighbours.
            let sx = min(document.pixelWidth - 1, max(0, Int(p.x.rounded(.down))))
            let sy = min(document.pixelHeight - 1, max(0, Int(p.y.rounded(.down))))
            let s = document.context.sample(x: sx, y: sy)
            // A fully transparent pixel is not a colour, it is a hole. Picking it set the
            // drawing colour to transparent black, after which every stroke composited
            // nothing at all: the pencil, the brush, the shapes and the text tool all
            // went dead at once, with the swatch showing the checkerboard and no way to
            // guess why. Nothing is picked instead, and the status line says so — the one
            // thing the old behaviour never did. (Forcing the alpha to 1 would be worse:
            // the RGB under a hole is black, so it would silently hand back a colour that
            // is not in the picture.)
            guard s.a > 0 else {
                pickNote = "nothing to pick up there — that part of the picture is empty"
                delegate?.canvasDidPickColor(self)
                dragging = false
                break
            }
            if background { settings.background = s.color } else { settings.foreground = s.color }
            delegate?.canvasDidPickColor(self)
            dragging = false
        case .wand:
            // Option-click selects every matching pixel in the picture, not just the
            // blob under the pointer: the "make all the white transparent" case.
            selection = MagicWand.select(in: document.context, at: p,
                                         tolerance: settings.wandTolerance, contiguous: !drag.option)
            dragging = false
        case .text:
            dragging = false
            startTextEditing(at: p)
        case .line, .arrow, .rectangle, .ellipse, .select:
            break
        }
        needsDisplay = true
    }

    func moveTo(_ drag: DragInput) {
        if let f = floatingDrag, let item = floating {
            let p = drag.point
            switch f {
            case .move(let grab, let origin):
                // Measured from where the drag started rather than accumulated, so
                // rounding to whole pixels cannot drift.
                item.frame.origin = CGPoint(x: (origin.x + p.x - grab.x).rounded(),
                                            y: (origin.y + p.y - grab.y).rounded())
                keepFloatingReachable(item)
            case .resize(let anchor):
                // The handles stay in the picture. The view clips to the canvas, so a
                // corner dragged outside it is a corner nobody can grab again.
                item.resize(to: clampedToCanvas(p), anchor: anchor, keepAspect: drag.shift)
            }
            needsDisplay = true
            delegate?.canvasDidChangeSelection(self)
            return
        }
        guard dragging, let last = lastPoint else { return }
        var p = drag.point
        let shift = drag.shift
        dragShift = shift
        if shift, let start = dragStart, settings.tool.isLineLike {
            p = p.constrainedLine(from: start)
        }
        dragCurrent = p
        switch settings.tool {
        case .pencil:
            Painter.pencil(in: document.context, from: last, to: p, color: primaryColor, mask: drawMask)
            document.touch()
        case .brush:
            brushAnchor = Painter.brush(in: document.context, from: brushAnchor ?? last, to: p,
                                        size: settings.brushSize, color: primaryColor,
                                        mask: drawMask)
            document.touch()
        case .eraser:
            Painter.erase(in: document.context, from: last, to: p, size: settings.brushSize,
                          color: dragUsesBackground ? settings.background : nil, mask: drawMask)
            document.touch()
        case .select:
            // Exactly the expression `end` commits, so the ants and the selection they
            // promise cannot disagree.
            if let start = dragStart {
                liveSelectionRect = selectionRect(from: start, to: p, square: shift)
            }
        default:
            break
        }
        lastPoint = p
        needsDisplay = true
    }

    func end(_ drag: DragInput) {
        if floatingDrag != nil {
            floatingDrag = nil
            needsDisplay = true
            return
        }
        defer {
            dragging = false
            dragStart = nil
            dragCurrent = nil
            dragShift = false
            lastPoint = nil
            brushAnchor = nil
            liveSelectionRect = nil
            needsDisplay = true
        }
        guard dragging, let start = dragStart else { return }
        var p = drag.point
        let shift = drag.shift
        switch settings.tool {
        case .line, .arrow:
            if shift { p = p.constrainedLine(from: start) }
            let isArrow = settings.tool == .arrow
            // A click with no drag is a zero-length arrow, and an arrow that short has no
            // direction to point in — `Painter.arrow` draws nothing. Registering undo
            // first left the user a dead Undo Arrow step and a document claiming unsaved
            // changes it never had. A zero-length LINE is different: a round cap paints a
            // dot, which is a mark, so it stays undoable.
            guard !isArrow || Painter.arrowWillDraw(from: start, to: p) else { return }
            document.registerUndo(name: isArrow ? "Arrow" : "Line")
            if isArrow {
                Painter.arrow(in: document.context, from: start, to: p,
                              width: settings.strokeWidth, color: primaryColor, mask: drawMask)
            } else {
                Painter.line(in: document.context, from: start, to: p,
                             width: settings.strokeWidth, color: primaryColor, mask: drawMask)
            }
            document.touch()
        case .rectangle, .ellipse:
            let r = rectBetween(start, p, square: shift)
            guard r.width >= 1 || r.height >= 1 else { return }
            document.registerUndo(name: settings.tool == .ellipse ? "Ellipse" : "Rectangle")
            Painter.shape(in: document.context, rect: r, ellipse: settings.tool == .ellipse,
                          style: settings.shapeStyle, width: settings.strokeWidth,
                          stroke: primaryColor, fill: secondaryColor, mask: drawMask)
            document.touch()
        case .select:
            let r = selectionRect(from: start, to: p, square: shift)
            setSelection(rect: (r.width < 1 || r.height < 1) ? nil : r)
        default:
            break
        }
    }

    // MARK: - Hover readout

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.canvas(self, hoveringAt: point(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.canvas(self, hoveringAt: nil)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch settings.tool {
        case .text: cursor = .iBeam
        case .eyedropper: cursor = .crosshair
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Text tool

    /// Where a text field puts its first glyph, measured from its own top-left corner,
    /// in view points.
    ///
    /// The editor used to be positioned by its FRAME while the commit drew from the
    /// click point, so the finished text landed up and to the left of the box it had
    /// been typed in — a constant offset, and so one that can be cancelled exactly. The
    /// offset is the field's own: `titleRect` accounts for the border, and the cell then
    /// pads its text a further two points inside that, which no API reports. The field
    /// is unflipped, so its title rect is measured from the BOTTOM.
    static func textInset(of field: NSTextField) -> CGSize {
        let b = field.bounds
        let title = field.cell?.titleRect(forBounds: b) ?? b
        return CGSize(width: title.minX + 2, height: b.height - title.maxY)
    }

    private func startTextEditing(at p: CGPoint) {
        textOrigin = p
        let field = NSTextField(frame: CGRect(x: 0, y: 0,
                                              width: max(120, bounds.width - p.x * zoom),
                                              height: settings.font.pointSize * zoom * 1.6))
        field.font = NSFont(descriptor: settings.font.fontDescriptor, size: settings.font.pointSize * zoom)
            ?? settings.font
        field.textColor = settings.foreground
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.65)
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        // The action alone is Return and nothing else. An NSTextField does not send it
        // when editing ends because the keyboard went somewhere else — a click on a
        // palette slider, another window coming forward — and the field was then left on
        // the canvas holding text that would never be drawn, swallowing every single-key
        // shortcut for as long as it sat there. The delegate covers that case.
        field.delegate = self
        field.placeholderString = "Type, then press Return"
        // Placed by its text rather than by its frame, now that the border and the
        // cell's padding are known: what is typed sits exactly where the commit draws it.
        let inset = Self.textInset(of: field)
        field.setFrameOrigin(CGPoint(x: p.x * zoom - inset.width, y: p.y * zoom - inset.height))
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    /// The editor, while there is one. Readable so the self-test can hold the box the
    /// user typed in against the pixels the commit draws.
    var editingTextField: NSTextField? { textField }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        commitTextIfEditing()
    }

    var isEditingText: Bool { textField != nil }

    func commitTextIfEditing() { commitTextIfEditing(reclaimingFocus: true) }

    /// `reclaimingFocus` is false on the one path that runs INSIDE the field editor's
    /// resignation: moving the first responder there would fight AppKit for a keyboard
    /// that is already on its way to whatever the user clicked.
    private func commitTextIfEditing(reclaimingFocus: Bool) {
        guard let field = textField else { return }
        let string = field.stringValue
        textField = nil
        field.removeFromSuperview()
        if reclaimingFocus { window?.makeFirstResponder(self) }
        guard !string.isEmpty else { return }
        document.registerUndo(name: "Text")
        Painter.text(in: document.context, string: string, at: textOrigin,
                     font: settings.font, color: settings.foreground, mask: drawMask)
        document.touch()
        needsDisplay = true
    }

    func cancelTextIfEditing() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape unwinds the most recent thing first: a floating paste, then an unfinished
        // text box, then the selection.
        if floating != nil { cancelFloating() }
        else if isEditingText { cancelTextIfEditing() }
        else { selection = nil }
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars == "\r" || chars == "\u{3}" {           // Return or Enter
            if commitFloating() { return }
        }
        // Delete belongs to the canvas only when it is unmodified. ⌘⌫ is Edit ▸ Fill
        // Selection with Background, and `charactersIgnoringModifiers` is U+007F either
        // way, so without this test the canvas shadowed that menu item and erased the
        // selection where the menu promises to fill it.
        if !event.modifierFlags.contains(.command),
           chars == String(UnicodeScalar(NSDeleteCharacter)!)
               || chars == String(UnicodeScalar(NSBackspaceCharacter)!) {
            deleteSelectionOrFloating()
            return
        }
        super.keyDown(with: event)
    }

    /// Delete throws away a floating paste if there is one, otherwise it makes the
    /// selection transparent. With a magic-wand selection that second half is the whole
    /// point of the tool.
    ///
    /// **With nothing selected it does nothing at all.** `PaintDocument.clear(mask:)`
    /// reads a nil mask as "the whole canvas", which is the right contract for the model
    /// but a disaster for a bare Backspace: one stray keystroke on the focused canvas
    /// used to erase the entire picture. Select All is how you ask for everything.
    ///
    /// Returns whether it did anything, so the menu and the self-test can both tell.
    @discardableResult
    func deleteSelectionOrFloating() -> Bool {
        if floating != nil { cancelFloating(); return true }
        guard let sel = selection, !sel.isEmpty else { return false }
        document.clear(mask: sel, to: nil)
        return true
    }

    // MARK: - Floating paste

    /// Put `image` on the canvas as a floating item rather than stamping it down.
    func beginFloating(image: CGImage, at origin: CGPoint? = nil, actionName: String = "Paste") {
        finishPendingEdits()
        let item = FloatingItem(image: image, at: origin ?? defaultFloatingOrigin(for: image),
                                actionName: actionName)
        shrinkToFit(item)
        keepFloatingReachable(item)
        floating = item
        needsDisplay = true
        updateAntsTimer()
        delegate?.canvasDidChangeSelection(self)
    }

    /// The selection's corner if there is one, otherwise centred on whatever part of the
    /// picture is currently on screen — so a paste never lands off in the scrolled-away
    /// corner where you cannot see it.
    private func defaultFloatingOrigin(for image: CGImage) -> CGPoint {
        if let r = selectionRect { return r.origin }
        let v = visibleRect.isEmpty ? bounds : visibleRect
        return CGPoint(x: max(0, (v.midX / zoom - CGFloat(image.width) / 2).rounded()),
                       y: max(0, (v.midY / zoom - CGFloat(image.height) / 2).rounded()))
    }

    /// A picture bigger than the canvas would arrive mostly off the edge with its corner
    /// handles out of reach, so it is scaled down to fit on arrival, about its own centre.
    /// Nothing is lost by this: scaling always resamples from the original pixels, so
    /// dragging a corner back out gets the detail back.
    private func shrinkToFit(_ item: FloatingItem) {
        let cw = CGFloat(document.pixelWidth), ch = CGFloat(document.pixelHeight)
        let f = item.frame
        guard f.width > cw || f.height > ch, f.width > 0, f.height > 0 else { return }
        let s = min(cw / f.width, ch / f.height)
        let w = max(1, (f.width * s).rounded())
        let h = max(1, (f.height * s).rounded())
        item.frame = CGRect(x: (f.midX - w / 2).rounded(), y: (f.midY - h / 2).rounded(),
                            width: w, height: h)
    }

    /// How much of a floating item must stay on the canvas, in image pixels.
    ///
    /// The view clips to the picture, so an item dragged clean past an edge is not
    /// merely off the paper: it is invisible, handles and all, and the only way back was
    /// to throw the paste away and start again. Keeping this much of it inside an edge
    /// keeps two of its four corner handles on the canvas, so there is always something
    /// to grab.
    static let floatingMinVisible: CGFloat = 12

    private func keepFloatingReachable(_ item: FloatingItem) {
        let f = item.frame
        let keepX = min(f.width, Self.floatingMinVisible)
        let keepY = min(f.height, Self.floatingMinVisible)
        let cw = CGFloat(document.pixelWidth), ch = CGFloat(document.pixelHeight)
        item.frame.origin = CGPoint(x: min(max(f.minX, keepX - f.width), cw - keepX),
                                    y: min(max(f.minY, keepY - f.height), ch - keepY))
    }

    private func clampedToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(document.pixelWidth)),
                y: min(max(p.y, 0), CGFloat(document.pixelHeight)))
    }

    /// Land the floating item in the bitmap as one undoable step. Returns false when
    /// there was nothing floating, which is how Return decides whether it was handled.
    @discardableResult
    func commitFloating() -> Bool {
        guard let item = floating else { return false }
        floating = nil
        floatingDrag = nil
        document.commit(item)
        needsDisplay = true
        updateAntsTimer()
        delegate?.canvasDidChangeSelection(self)
        return true
    }

    func cancelFloating() {
        guard floating != nil else { return }
        floating = nil
        floatingDrag = nil
        needsDisplay = true
        updateAntsTimer()
        delegate?.canvasDidChangeSelection(self)
    }

    var hasFloatingItem: Bool { floating != nil }
    var floatingFrame: CGRect? { floating?.frame }

    /// What the pending item would be called in the undo menu ("Paste", "Drop Image"),
    /// so ⌘Z can name the thing it is about to take back.
    var floatingActionName: String? { floating?.actionName }

    /// Everything that is not "carry on fiddling with what is in mid-air" calls this:
    /// an unfinished text box or a floating paste is committed before the next operation
    /// touches the bitmap, so the undo stack stays in the order things happened.
    func finishPendingEdits() {
        commitTextIfEditing()
        commitFloating()
    }

    // MARK: - Dropped files

    private func droppedImageURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: nil) as? [URL],
              let url = urls.first else { return nil }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard type?.conforms(to: .image) == true else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImageURL(sender) != nil ? .copy : []
    }

    /// What a dropped file came to. Reported rather than acted on, because the alert for
    /// the middle case has to be put up by the view and the self-test has to be able to
    /// reach the decision without a sheet on screen.
    enum DropResult: Equatable {
        /// Not a file the drop should ever have been offered for.
        case notAnImageFile
        /// It looked like an image and would not decode; the name to put in the alert.
        case unreadable(String)
        case placed
    }

    /// Decide what a dropped URL amounts to, floating it under the pointer when it decodes.
    ///
    /// `droppedImageURL` accepts anything whose content type conforms to `.image`, so a
    /// zero-byte, truncated or unreadable file still shows the copy cursor and still has
    /// its drop accepted — and this used to be one guard ending in a bare `return false`,
    /// so nothing happened and nothing was said. The same file through File ▸ Open says
    /// "Paintbox could not read X." The two routes now agree.
    @discardableResult
    func acceptDrop(url: URL?, at point: CGPoint) -> DropResult {
        guard let url else { return .notAnImageFile }
        guard let img = Bitmap.load(url: url) else { return .unreadable(url.lastPathComponent) }
        let origin = CGPoint(x: (point.x - CGFloat(img.width) / 2).rounded(),
                             y: (point.y - CGFloat(img.height) / 2).rounded())
        beginFloating(image: img, at: origin, actionName: "Drop Image")
        return .placed
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Drop it where it was dropped, not at the corner.
        let p = imagePoint(convert(sender.draggingLocation, from: nil))
        switch acceptDrop(url: droppedImageURL(sender), at: p) {
        case .notAnImageFile:
            return false
        case .unreadable(let name):
            // The same wording File ▸ Open uses, so one broken file reads the same
            // whichever way it reached the app.
            Dialogs.error("Paintbox could not read \(name).", window: window)
            return false
        case .placed:
            window?.makeFirstResponder(self)
            return true
        }
    }

    // MARK: - Zoom helpers

    /// The ends of the zoom range. `setZoom` clamps to them, and the menu and toolbar ask
    /// about them, so they are stated once rather than repeated as literals.
    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 32

    var canZoomIn: Bool { zoom < Self.maxZoom }
    var canZoomOut: Bool { zoom > Self.minZoom }

    func zoomToFit() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let avail = clip.bounds.insetBy(dx: 12, dy: 12).size
        guard document.pixelSize.width > 0, document.pixelSize.height > 0 else { return }
        let z = min(avail.width / document.pixelSize.width, avail.height / document.pixelSize.height)
        zoom = max(0.02, min(16, z))
    }

    func stepZoom(_ factor: CGFloat) {
        setZoom(zoom * factor)
    }

    /// Change the zoom, keeping one image point where it already is on screen.
    ///
    /// Setting `zoom` on its own only resizes the view: the scroll view keeps its
    /// origin, so the picture grows away from its top-left corner and whatever you were
    /// looking at slides off. On a photograph two steps of ⌘+ lose your place
    /// altogether, which is not zooming in on anything.
    ///
    /// `anchor` is the point to hold still, in image pixels; it defaults to the middle
    /// of what is visible, which is what the menu and the toolbar want. A gesture or a
    /// scroll wheel can pass the pointer instead and zoom about that.
    func setZoom(_ newZoom: CGFloat, keeping anchor: CGPoint? = nil) {
        let target = max(Self.minZoom, min(Self.maxZoom, newZoom))
        guard target != zoom else { return }
        // No scroll view, or no laid-out one: there is no "visible part" to preserve.
        guard let scroll = enclosingScrollView, !visibleRect.isEmpty else {
            zoom = target
            return
        }
        let clip = scroll.contentView
        let visible = visibleRect
        let held = anchor ?? CGPoint(x: visible.midX / zoom, y: visible.midY / zoom)
        // Where the held point sits inside the visible rectangle, in view points. That
        // is what stays the same; everything else follows from it.
        let offset = CGPoint(x: held.x * zoom - visible.minX, y: held.y * zoom - visible.minY)
        zoom = target
        let wanted = CGPoint(x: held.x * target - offset.x, y: held.y * target - offset.y)
        clip.scroll(to: CGPoint(x: min(max(0, wanted.x), max(0, bounds.width - clip.bounds.width)),
                                y: min(max(0, wanted.y), max(0, bounds.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }
}

extension CanvasView {
    /// Open at 100% unless the picture is bigger than the window, then fit it.
    func zoomToFitIfLarger() {
        guard let clip = enclosingScrollView?.contentView else { return }
        if document.pixelSize.width > clip.bounds.width || document.pixelSize.height > clip.bounds.height {
            zoomToFit()
        } else {
            zoom = 1
        }
    }
}

// MARK: - The text editor losing the keyboard

extension CanvasView: NSTextFieldDelegate {
    /// Whether AppKit ended the edit because the user finished it from the keyboard —
    /// Return or Tab — rather than because focus moved away.
    ///
    /// The two cases have to be told apart: a keyboard finish is followed immediately by
    /// the field's action, which commits and takes the keyboard back from a safe place
    /// outside the responder swap, so this notification must leave it alone.
    private static func endedFromKeyboard(_ note: Notification) -> Bool {
        guard let raw = note.userInfo?["NSTextMovement"] as? Int else { return false }
        return [NSTextMovement.return, .tab, .backtab].contains { $0.rawValue == raw }
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard !Self.endedFromKeyboard(note) else { return }
        // An empty box is left standing. AppKit reports an edit as begun and ended
        // straight away when the field cannot actually have the keyboard — a window that
        // is not key, which is the state a freshly built window is in — and taking a box
        // away the instant the user opened it would be a new bug in place of the old one.
        // Nothing is lost by waiting: an empty commit draws no pixels, and the next
        // `finishPendingEdits` clears the box anyway.
        guard textField?.stringValue.isEmpty == false else { return }
        // Focus left the field with text in it: the user clicked a slider, a swatch, or
        // another window. What they typed is drawn now rather than stranded on an editor
        // that will never send its action. Focus is left where it is going — see
        // `commitTextIfEditing(reclaimingFocus:)`.
        commitTextIfEditing(reclaimingFocus: false)
    }
}

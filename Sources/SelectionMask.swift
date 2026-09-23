import AppKit
import CoreGraphics

/// The selection, as a mask rather than a rectangle.
///
/// It began life as a `CGRect`, which quietly made two obvious features impossible: you
/// cannot magic-wand an irregular blob with a rectangle, and you cannot blur one either.
/// So the selection is now one byte per canvas pixel — 0 outside, 255 inside — and the
/// rectangular selection tool is simply "fill a rect in the mask".
///
/// Eight bits rather than one costs 786 KB on a 1024x768 canvas, which is a quarter of
/// what a single undo snapshot already costs, and it leaves room for feathered edges
/// later without another refactor.
///
/// The mask is always exactly the size of the canvas. When the canvas is resized the
/// selection is dropped, which is what the rectangle version did too.
///
/// **There is deliberately no `copy()`.** Every mask is built whole — by the selection
/// tool, by the wand, by Select All — and then handed over; nothing mutates a mask it was
/// given, so nothing ever needs a second one. There was a `copy()` here that no caller had
/// ever had a use for, which is worse than none at all: the next person needing a deep
/// copy of half a dozen private fields would have reached for it believing it correct and
/// tested, and it was neither.
final class SelectionMask {
    let width: Int
    let height: Int
    private(set) var bytes: ContiguousArray<UInt8>

    /// Bounding box of the set pixels, top-left origin, integral. `.zero` when empty.
    private(set) var bounds: CGRect = .zero
    private(set) var setCount: Int = 0

    /// True when the mask is exactly its own bounding box filled in. That is the common
    /// case — every rectangular selection — and it lets the ants and the fills take a
    /// single-rectangle fast path instead of walking pixels.
    private(set) var isRectangular: Bool = true

    var isEmpty: Bool { setCount == 0 }

    /// The extent of the marked pixels, accumulated as they are marked. The bounding box
    /// used to be found by reading every byte in the mask once the marking was done,
    /// which made the cost of a wand click the size of the CANVAS rather than the size of
    /// the selection: nine million reads per click on a nine-megapixel photograph, on top
    /// of the flood fill that had just walked the pixels it actually selected. Widening a
    /// box costs four comparisons per marked pixel, so `recompute` now has nothing left
    /// to look at.
    private var accMinX = 0, accMinY = 0, accMaxX = -1, accMaxY = -1

    /// `stencilImage()`'s answer, kept until a byte changes. Clipping a tool to the
    /// selection asks for the stencil on every mouse-moved event of a stroke, and
    /// rebuilding a canvas-sized buffer per event would cost more than the painting.
    private var cachedStencil: CGImage?

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        bytes = ContiguousArray(repeating: 0, count: self.width * self.height)
    }

    convenience init(width: Int, height: Int, rect: CGRect) {
        self.init(width: width, height: height)
        setOnly(rect: rect)
    }

    /// Everything selected — what Select All produces.
    static func all(width: Int, height: Int) -> SelectionMask {
        let m = SelectionMask(width: width, height: height)
        m.setOnly(rect: CGRect(x: 0, y: 0, width: width, height: height))
        return m
    }

    // MARK: - Reading

    @inline(__always) func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bytes[y * width + x] != 0
    }

    @inline(__always) func coverage(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return bytes[y * width + x]
    }

    /// The whole canvas as a rect, for callers that want "selection or everything".
    var canvasBounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    // MARK: - Writing

    /// Clear everything and select exactly one rectangle. Reuses the buffer, so the
    /// selection tool can call this on every mouse-move without churning memory.
    func setOnly(rect: CGRect) {
        let r = rect.integral.intersection(canvasBounds)
        cachedStencil = nil
        for i in bytes.indices { bytes[i] = 0 }
        guard r.width >= 1, r.height >= 1 else { recomputeEmpty(); return }
        let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 { bytes[row + x] = 255 }
        }
        bounds = r
        setCount = Int(r.width) * Int(r.height)
        isRectangular = true
        // Seeded, not cleared: `mark` may widen this rectangle afterwards.
        accMinX = x0; accMinY = y0; accMaxX = x1 - 1; accMaxY = y1 - 1
    }

    /// Set one pixel. Callers that use this must call `recompute()` when they are done.
    ///
    /// A pixel that is already set is left alone rather than counted twice, so marking
    /// the same pixel from two directions — which the flood fill's span walk does at the
    /// corners of a blob — cannot inflate the count and so cannot make a filled box look
    /// irregular.
    @inline(__always) func mark(x: Int, y: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = y * width + x
        guard bytes[i] == 0 else { return }
        bytes[i] = 255
        cachedStencil = nil
        if setCount == 0 {
            accMinX = x; accMaxX = x; accMinY = y; accMaxY = y
        } else {
            if x < accMinX { accMinX = x }
            if x > accMaxX { accMaxX = x }
            if y < accMinY { accMinY = y }
            if y > accMaxY { accMaxY = y }
        }
        setCount += 1
    }

    private func recomputeEmpty() {
        cachedStencil = nil
        bounds = .zero
        setCount = 0
        isRectangular = true
        accMinX = 0; accMinY = 0; accMaxX = -1; accMaxY = -1
    }

    /// Settle the bounding box and the rectangularity after bulk marking. `mark` has
    /// already done the counting and the box, so this is arithmetic rather than a scan;
    /// it stays a call the bulk-marking callers must make because `isRectangular` is only
    /// knowable once the last pixel is in.
    func recompute() {
        guard setCount > 0 else { recomputeEmpty(); return }
        bounds = CGRect(x: accMinX, y: accMinY,
                        width: accMaxX - accMinX + 1, height: accMaxY - accMinY + 1)
        // Every set pixel is inside `bounds` by construction, so if the count equals the
        // box's area then the box is completely filled: the mask IS a rectangle.
        isRectangular = setCount == Int(bounds.width) * Int(bounds.height)
    }

    /// The bounding box, the count and the rectangularity as a full scan of the bytes
    /// finds them. This is what `recompute` used to do on every wand click; it survives
    /// only so the self-test can hold the incrementally maintained values against ground
    /// truth. Nothing in the app calls it.
    func scannedStats() -> (bounds: CGRect, setCount: Int, isRectangular: Bool) {
        var minX = width, minY = height, maxX = -1, maxY = -1
        var count = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where bytes[row + x] != 0 {
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard count > 0 else { return (.zero, 0, true) }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (box, count, count == Int(box.width) * Int(box.height))
    }

    // MARK: - Marching ants

    /// The outline of the selected region, in image pixels with a top-left origin.
    ///
    /// Rather than chasing the boundary round as a closed loop — which needs hole and
    /// winding bookkeeping the ants do not care about — this emits the unit edges where a
    /// selected pixel meets an unselected one, merging runs of collinear edges so a plain
    /// rectangle comes out as four lines rather than eight hundred.
    ///
    /// - Parameters:
    ///   - region: trace only this part of the canvas. The ants only ever need what is
    ///     on screen, and on a big picture that is a small fraction of the mask.
    ///   - maxSegments: a budget, and the reason this returns an Optional. A magic wand
    ///     over a grainy sky genuinely selects nine million pixels whose boundary is
    ///     millions of unit edges: half a gigabyte of CGPath that takes half a second to
    ///     stroke, redrawn eight times a second by the ants timer, which is a frozen
    ///     window and not a selection. `nil` means "too intricate to draw as a line" and
    ///     the canvas shows the mask as a tint instead.
    func boundaryPath(in region: CGRect? = nil, maxSegments: Int = .max) -> CGPath? {
        let path = CGMutablePath()
        guard !isEmpty else { return path }
        if isRectangular {
            path.addRect(bounds)
            return path
        }
        let area = (region.map { $0.intersection(bounds) } ?? bounds).integral
        guard area.width >= 1, area.height >= 1 else { return path }
        let x0 = Int(area.minX), x1 = Int(area.maxX)
        let y0 = Int(area.minY), y1 = Int(area.maxY)
        var segments = 0

        // Horizontal edges: edge row `y` separates pixel rows y-1 and y.
        for y in y0...y1 + 1 where y <= height {
            var runStart: Int? = nil
            for x in x0...x1 + 1 {
                let edge = x <= x1 && contains(x: x, y: y - 1) != contains(x: x, y: y)
                if edge {
                    if runStart == nil { runStart = x }
                } else if let s = runStart {
                    path.move(to: CGPoint(x: s, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    runStart = nil
                    segments += 1
                }
            }
            // Checked once a row, not once an edge: the point is to give up early on a
            // hopeless mask, not to count precisely.
            if segments > maxSegments { return nil }
        }
        // Vertical edges: edge column `x` separates pixel columns x-1 and x.
        for x in x0...x1 + 1 where x <= width {
            var runStart: Int? = nil
            for y in y0...y1 + 1 {
                let edge = y <= y1 && contains(x: x - 1, y: y) != contains(x: x, y: y)
                if edge {
                    if runStart == nil { runStart = y }
                } else if let s = runStart {
                    path.move(to: CGPoint(x: x, y: s))
                    path.addLine(to: CGPoint(x: x, y: y))
                    runStart = nil
                    segments += 1
                }
            }
            if segments > maxSegments { return nil }
        }
        return path
    }

    // MARK: - Drawing the mask itself

    /// The mask as a CoreGraphics image mask, for the times the outline is too intricate
    /// to stroke. Tinting through this costs one image draw whatever the shape is, where
    /// stroking its boundary costs a segment per pixel edge.
    ///
    /// An image mask's convention is the reverse of ours — a sample of 0 is what paints,
    /// checked against real pixels rather than taken from the documentation — so the
    /// decode array flips it, rather than inverting twenty-four million bytes into a
    /// second buffer. Row 0 lands at the top of the target rect, like any other image.
    func stencilImage() -> CGImage? {
        if let cachedStencil { return cachedStencil }
        let data = bytes.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        cachedStencil = CGImage(maskWidth: width, height: height, bitsPerComponent: 8,
                                bitsPerPixel: 8, bytesPerRow: width, provider: provider,
                                decode: [1, 0], shouldInterpolate: false)
        return cachedStencil
    }
}

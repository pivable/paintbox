import AppKit
import CoreGraphics
import Foundation

/// Stroke and shape primitives. Every point is in image pixels with a TOP-LEFT origin;
/// each function applies the flip itself.
enum Painter {

    // MARK: - Compositing

    /// Lay one premultiplied source pixel over the destination at byte offset `o`.
    ///
    /// `out = src + dst·(255 − src.a)`, which is plain source-over for premultiplied
    /// bytes, and an exact copy when the source is opaque — the common case.
    ///
    /// The two raster tools used to write the four source bytes straight into the
    /// buffer, which is a REPLACE: it throws the destination's alpha away. A colour with
    /// alpha below 1 is easy to reach — the system colour panel shows an opacity slider
    /// by default, and the eyedropper carries the sampled pixel's alpha — so the pencil
    /// and the paint bucket punched half-transparent holes in the picture where every
    /// other tool (all of which go through CGContext) tinted it, and with alpha 0 they
    /// became silent erasers. They now composite like everything else.
    @inline(__always)
    static func blend(_ p: UnsafeMutablePointer<UInt8>, _ o: Int, _ src: RGBA) {
        if src.a == 255 {
            p[o] = src.r; p[o + 1] = src.g; p[o + 2] = src.b; p[o + 3] = src.a
            return
        }
        let inv = 255 - Int(src.a)
        p[o] = UInt8(min(255, Int(src.r) + (Int(p[o]) * inv + 127) / 255))
        p[o + 1] = UInt8(min(255, Int(src.g) + (Int(p[o + 1]) * inv + 127) / 255))
        p[o + 2] = UInt8(min(255, Int(src.b) + (Int(p[o + 2]) * inv + 127) / 255))
        p[o + 3] = UInt8(min(255, Int(src.a) + (Int(p[o + 3]) * inv + 127) / 255))
    }

    // MARK: - Confinement

    /// The mask a tool should honour, or nil for "paint anywhere".
    ///
    /// A mask that does not match the bitmap is one byte per pixel of a canvas that no
    /// longer exists, so it is no boundary at all; an empty one means nothing is
    /// selected, which means the whole picture. Both read as no clip, and the two raster
    /// tools test it per pixel where the CoreGraphics ones clip the context.
    static func confined(_ mask: SelectionMask?, to ctx: CGContext) -> SelectionMask? {
        guard let mask, !mask.isEmpty, mask.width == ctx.width, mask.height == ctx.height else {
            return nil
        }
        return mask
    }

    // MARK: - Pencil: one hard pixel wide

    static func pencil(in ctx: CGContext, from a: CGPoint, to b: CGPoint, color: NSColor,
                       mask: SelectionMask? = nil) {
        let rgba = RGBA.premultiplied(color)
        guard let p = ctx.pixels else { return }
        // The pencil writes bytes rather than drawing through CoreGraphics, so the
        // selection cannot be a clip on the context: it is a test per pixel instead.
        let sel = confined(mask, to: ctx)
        let bpr = ctx.bytesPerRow
        let w = ctx.width
        let h = ctx.height
        // Integer Bresenham so a 1px pencil is exactly 1px, never antialiased.
        var x0 = Int(a.x.rounded(.down)), y0 = Int(a.y.rounded(.down))
        let x1 = Int(b.x.rounded(.down)), y1 = Int(b.y.rounded(.down))
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            if x0 >= 0, y0 >= 0, x0 < w, y0 < h, sel?.contains(x: x0, y: y0) != false {
                blend(p, y0 * bpr + x0 * 4, rgba)
            }
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    // MARK: - Brush: soft round stamp, dabbed along the stroke

    private static var stampCache: (size: CGFloat, color: NSColor, image: CGImage)?

    static func softStamp(size: CGFloat, color: NSColor) -> CGImage {
        if let c = stampCache, c.size == size, c.color == color { return c.image }
        let d = max(2, Int(size.rounded()))
        let ctx = Bitmap.makeContext(width: d, height: d)
        let base = (color.usingColorSpace(.sRGB) ?? .black)
        let r = base.redComponent, g = base.greenComponent, b = base.blueComponent
        let a = base.alphaComponent
        let colors = [CGColor(srgbRed: r, green: g, blue: b, alpha: a),
                      CGColor(srgbRed: r, green: g, blue: b, alpha: a * 0.85),
                      CGColor(srgbRed: r, green: g, blue: b, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: paintboxColorSpace, colors: colors,
                                     locations: [0, 0.62, 1]) {
            let c = CGPoint(x: CGFloat(d) / 2, y: CGFloat(d) / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: CGFloat(d) / 2, options: [])
        }
        let img = ctx.makeImage()!
        stampCache = (size, color, img)
        return img
    }

    /// How far apart the dabs of a stroke sit, for a brush of this size.
    static func brushSpacing(size: CGFloat) -> CGFloat { max(1, size / 6) }

    /// One dab, centred on `at`. This is what mouse-DOWN lays, and it is the stroke's
    /// first and only unconditional dab; everything after it goes through `brush`.
    static func brushDab(in ctx: CGContext, at p: CGPoint, size: CGFloat, color: NSColor,
                         mask: SelectionMask? = nil) {
        let dab = softStamp(size: size, color: color)
        ctx.withTopLeftOrigin(clippedTo: mask) { c in
            c.setBlendMode(.normal)
            c.draw(dab, in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        }
    }

    /// Dab the stamp along `(a, b]` and return where the LAST dab landed — the anchor the
    /// next segment must be measured from.
    ///
    /// Spacing belongs to the stroke, not to the mouse event. Each segment used to lay
    /// `max(1, …)` dabs, so it put one down however short it was, and the anchor then
    /// jumped to the pointer: the dab count became a count of mouse-dragged events. Drag
    /// slowly, or drag at all at 8x zoom where one screen point is an eighth of a pixel,
    /// and the design's spacing of `size/6` collapsed to a dab per event — compositing a
    /// soft stamp over itself squares its transparency, so the same 20px drag arriving as
    /// twenty events instead of one came out 138 alpha levels harder at its edge and
    /// effectively opaque down the middle. The soft brush was soft only when you moved fast.
    ///
    /// So the step count is a FLOOR: a segment shorter than one spacing lays nothing, the
    /// returned anchor keeps the unspent remainder, and the dabs fall on exact multiples
    /// of the spacing however the pointer's movement was chopped up.
    @discardableResult
    static func brush(in ctx: CGContext, from a: CGPoint, to b: CGPoint,
                      size: CGFloat, color: NSColor, mask: SelectionMask? = nil) -> CGPoint {
        let spacing = brushSpacing(size: size)
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = sqrt(dx * dx + dy * dy)
        let steps = Int(dist / spacing)
        guard steps >= 1 else { return a }
        let dab = softStamp(size: size, color: color)
        let ux = dx / dist, uy = dy / dist
        ctx.withTopLeftOrigin(clippedTo: mask) { c in
            c.setBlendMode(.normal)
            for i in 1...steps {
                let d = spacing * CGFloat(i)
                c.draw(dab, in: CGRect(x: a.x + ux * d - size / 2, y: a.y + uy * d - size / 2,
                                       width: size, height: size))
            }
        }
        let d = spacing * CGFloat(steps)
        return CGPoint(x: a.x + ux * d, y: a.y + uy * d)
    }

    // MARK: - Eraser

    /// `color == nil` erases to transparent; otherwise it paints the background colour.
    static func erase(in ctx: CGContext, from a: CGPoint, to b: CGPoint, size: CGFloat,
                      color: NSColor?, mask: SelectionMask? = nil) {
        ctx.withTopLeftOrigin(clippedTo: mask) { c in
            c.setLineWidth(size)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            if let color {
                c.setBlendMode(.normal)
                c.setStrokeColor((color.usingColorSpace(.sRGB) ?? .white).cgColor)
            } else {
                c.setBlendMode(.copy)
                c.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
            }
            c.beginPath()
            c.move(to: a)
            c.addLine(to: b)
            c.strokePath()
            c.setBlendMode(.normal)
        }
    }

    // MARK: - Shapes

    static func line(in ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat,
                     color: NSColor, mask: SelectionMask? = nil) {
        ctx.withTopLeftOrigin(clippedTo: mask) { c in
            c.setLineWidth(width)
            c.setLineCap(.round)
            c.setStrokeColor((color.usingColorSpace(.sRGB) ?? .black).cgColor)
            c.beginPath()
            c.move(to: a)
            c.addLine(to: b)
            c.strokePath()
        }
    }

    /// Shorter than this and an arrow has no direction to point in, so there is nothing
    /// to draw. Stated once because the caller has to know the answer BEFORE it commits
    /// to an undo step: see `CanvasView.end`.
    static let minArrowLength: CGFloat = 0.5

    /// Whether an arrow between these two points would put any ink down.
    static func arrowWillDraw(from a: CGPoint, to b: CGPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > minArrowLength
    }

    /// A line with a solid head at the `b` end.
    ///
    /// Annotating a screenshot is the other half of redacting one, and "point at this"
    /// is the annotation people actually want. It shares the line tool's drag, its width
    /// slider and its Shift-to-45° behaviour; the only difference is the triangle.
    static func arrow(in ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat,
                      color: NSColor, mask: SelectionMask? = nil) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard arrowWillDraw(from: a, to: b) else { return }
        let ux = dx / len, uy = dy / len
        let head = min(len, max(9, width * 4.5))      // never longer than the arrow itself
        let half = max(5, width * 2.2)
        // The shaft stops inside the head so the joint does not poke through the tip.
        let shaftEnd = CGPoint(x: b.x - ux * head * 0.75, y: b.y - uy * head * 0.75)
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)

        ctx.withTopLeftOrigin(clippedTo: mask) { c in
            let cg = (color.usingColorSpace(.sRGB) ?? .black).cgColor
            c.setLineWidth(width)
            c.setLineCap(.round)
            c.setStrokeColor(cg)
            c.beginPath()
            c.move(to: a)
            c.addLine(to: shaftEnd)
            c.strokePath()

            c.setFillColor(cg)
            c.beginPath()
            c.move(to: b)
            c.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            c.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            c.closePath()
            c.fillPath()
        }
    }

    static func shape(in ctx: CGContext, rect: CGRect, ellipse: Bool, style: ShapeStyle,
                      width: CGFloat, stroke: NSColor, fill: NSColor,
                      mask: SelectionMask? = nil) {
        ctx.withTopLeftOrigin(clippedTo: mask) { c in
            let path = CGMutablePath()
            if ellipse { path.addEllipse(in: rect) } else { path.addRect(rect) }
            if style == .filled || style == .both {
                c.setFillColor((fill.usingColorSpace(.sRGB) ?? .white).cgColor)
                c.addPath(path)
                c.fillPath()
            }
            if style == .outline || style == .both {
                c.setLineWidth(width)
                c.setLineJoin(.miter)
                c.setStrokeColor((stroke.usingColorSpace(.sRGB) ?? .black).cgColor)
                c.addPath(path)
                c.strokePath()
            }
        }
    }

    // MARK: - Text

    /// Text is a painting tool like any other, so it honours the marching ants too.
    ///
    /// Every other tool here was given `mask:` when the ants stopped being decorative;
    /// text was the one left out, so a selection that contained the brush, the pencil,
    /// the shapes and the bucket let a typed line walk straight out of it. The clip is
    /// set on the unflipped context by `clipping`, and this function's own flip happens
    /// inside it — the same order `withTopLeftOrigin(clippedTo:)` uses.
    static func text(in ctx: CGContext, string: String, at point: CGPoint, font: NSFont,
                     color: NSColor, mask: SelectionMask? = nil) {
        guard !string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = NSAttributedString(string: string, attributes: attrs)
        ctx.clipping(to: mask) { c in
            NSGraphicsContext.saveGraphicsState()
            c.saveGState()
            c.translateBy(x: 0, y: CGFloat(c.height))
            c.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            s.draw(at: point)
            c.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Flood fill

    /// Scanline flood fill on the raw buffer. `tolerance` is 0...255 per channel.
    ///
    /// A selection is a wall the flood cannot cross, not a filter applied afterwards:
    /// colour continues past the edge of the selection, so a fill allowed to walk over
    /// the boundary and then be clipped would still be the whole region's worth of work,
    /// and a click OUTSIDE the selection has nowhere to spread at all.
    static func floodFill(in ctx: CGContext, at point: CGPoint, color: NSColor, tolerance: Int,
                          mask: SelectionMask? = nil) {
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        guard let p = ctx.pixels else { return }
        let sx = Int(point.x.rounded(.down)), sy = Int(point.y.rounded(.down))
        guard sx >= 0, sy >= 0, sx < w, sy < h else { return }
        let sel = confined(mask, to: ctx)
        guard sel?.contains(x: sx, y: sy) != false else { return }

        let target = ctx.sample(x: sx, y: sy)
        let replacement = RGBA.premultiplied(color)
        if target == replacement && tolerance == 0 && replacement.a == 255 { return }

        @inline(__always) func matches(_ o: Int) -> Bool {
            let dr = abs(Int(p[o]) - Int(target.r))
            let dg = abs(Int(p[o + 1]) - Int(target.g))
            let db = abs(Int(p[o + 2]) - Int(target.b))
            let da = abs(Int(p[o + 3]) - Int(target.a))
            return dr <= tolerance && dg <= tolerance && db <= tolerance && da <= tolerance
        }

        /// Matches the seed colour AND is inside the selection.
        @inline(__always) func open(_ x: Int, _ y: Int, _ o: Int) -> Bool {
            matches(o) && sel?.contains(x: x, y: y) != false
        }

        // What stops the walk looping is a visited map, not "is this pixel already the
        // replacement colour". It used to be the latter, which only worked because the
        // fill REPLACED the four bytes; now that it composites (see `blend`), a
        // translucent colour leaves a pixel that still matches the target, and a fully
        // transparent one changes nothing at all — either of which would have spun
        // forever. One byte per pixel, the same cost the magic wand's mask already pays.
        var seen = ContiguousArray<Bool>(repeating: false, count: w * h)

        var stack: [(Int, Int)] = [(sx, sy)]
        stack.reserveCapacity(1024)
        while let (x0, y) = stack.popLast() {
            var x = x0
            let row = y * bpr
            let seenRow = y * w
            // Walk left to the start of the run.
            while x >= 0 && open(x, y, row + x * 4) && !seen[seenRow + x] { x -= 1 }
            x += 1
            var spanUp = false, spanDown = false
            while x < w, open(x, y, row + x * 4), !seen[seenRow + x] {
                blend(p, row + x * 4, replacement)
                seen[seenRow + x] = true
                if y > 0 {
                    let ok = open(x, y - 1, (y - 1) * bpr + x * 4) && !seen[seenRow - w + x]
                    if ok && !spanUp { stack.append((x, y - 1)); spanUp = true }
                    else if !ok { spanUp = false }
                }
                if y < h - 1 {
                    let ok = open(x, y + 1, (y + 1) * bpr + x * 4) && !seen[seenRow + w + x]
                    if ok && !spanDown { stack.append((x, y + 1)); spanDown = true }
                    else if !ok { spanDown = false }
                }
                x += 1
            }
        }
    }
}

// MARK: - Geometry helpers

extension CGPoint {
    /// Snap a line to the nearest 45 degrees.
    func constrainedLine(from origin: CGPoint) -> CGPoint {
        let dx = x - origin.x, dy = y - origin.y
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        let len = sqrt(dx * dx + dy * dy)
        return CGPoint(x: origin.x + cos(snapped) * len, y: origin.y + sin(snapped) * len)
    }
}

func rectBetween(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
    var dx = b.x - a.x
    var dy = b.y - a.y
    if square {
        let s = max(abs(dx), abs(dy))
        dx = dx < 0 ? -s : s
        dy = dy < 0 ? -s : s
    }
    return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
}

import AppKit
import CoreGraphics

/// Select pixels by colour instead of by dragging a box.
///
/// This is the manual fallback for every time the Vision background remover guesses
/// wrong, and it is how you make the white box behind a logo transparent: wand the
/// white, press Delete.
///
/// The contiguous walk is deliberately the same scanline algorithm the paint bucket
/// uses — same neighbour rules, same per-channel tolerance — so "what the bucket would
/// have filled" and "what the wand selects" are the same set of pixels. The only
/// difference is that the bucket writes colour into the bitmap and the wand writes
/// 255 into a mask.
enum MagicWand {

    /// - Parameters:
    ///   - point: where the user clicked, image pixels, top-left origin.
    ///   - tolerance: 0...255 per channel, alpha included, so a wand on a transparent
    ///     area selects transparency rather than whatever colour hides underneath it.
    ///   - contiguous: false selects every matching pixel in the picture, however far
    ///     apart — the global mode, on Option-click.
    static func select(in ctx: CGContext, at point: CGPoint, tolerance: Int,
                       contiguous: Bool) -> SelectionMask? {
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        guard let p = ctx.pixels else { return nil }
        let sx = Int(point.x.rounded(.down)), sy = Int(point.y.rounded(.down))
        guard sx >= 0, sy >= 0, sx < w, sy < h else { return nil }

        let target = ctx.sample(x: sx, y: sy)
        let mask = SelectionMask(width: w, height: h)

        @inline(__always) func matches(_ o: Int) -> Bool {
            abs(Int(p[o]) - Int(target.r)) <= tolerance
                && abs(Int(p[o + 1]) - Int(target.g)) <= tolerance
                && abs(Int(p[o + 2]) - Int(target.b)) <= tolerance
                && abs(Int(p[o + 3]) - Int(target.a)) <= tolerance
        }

        if !contiguous {
            for y in 0..<h {
                let row = y * bpr
                for x in 0..<w where matches(row + x * 4) { mask.mark(x: x, y: y) }
            }
            mask.recompute()
            return mask.isEmpty ? nil : mask
        }

        // Scanline flood, lifted from Painter.floodFill. `mask.contains` plays the part
        // the "already this colour" test plays there: it is what stops the walk looping.
        var stack: [(Int, Int)] = [(sx, sy)]
        stack.reserveCapacity(1024)
        while let (x0, y) = stack.popLast() {
            var x = x0
            let row = y * bpr
            while x >= 0 && matches(row + x * 4) && !mask.contains(x: x, y: y) { x -= 1 }
            x += 1
            var spanUp = false, spanDown = false
            while x < w, matches(row + x * 4), !mask.contains(x: x, y: y) {
                mask.mark(x: x, y: y)
                if y > 0 {
                    let ok = matches((y - 1) * bpr + x * 4) && !mask.contains(x: x, y: y - 1)
                    if ok && !spanUp { stack.append((x, y - 1)); spanUp = true }
                    else if !ok { spanUp = false }
                }
                if y < h - 1 {
                    let ok = matches((y + 1) * bpr + x * 4) && !mask.contains(x: x, y: y + 1)
                    if ok && !spanDown { stack.append((x, y + 1)); spanDown = true }
                    else if !ok { spanDown = false }
                }
                x += 1
            }
        }
        mask.recompute()
        return mask.isEmpty ? nil : mask
    }
}

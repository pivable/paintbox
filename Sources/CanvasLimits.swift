import CoreGraphics
import Foundation

/// How big a picture Paintbox will actually attempt to make.
///
/// This exists because CoreGraphics does not say no. `CGContext(data: nil, …)` maps its
/// backing store lazily, so a 1,024,000 x 768,000 request — one extra zero typed into the
/// Resize dialog's Percent field, which defaults to "100" — allocates happily and
/// `Bitmap.makeContext`'s fatalError never fires. The machine only falls over later,
/// inside `ctx.draw`, when every one of those three terabytes of pages has to be touched
/// on the main thread, and by then the user's unsaved picture is inside a process that is
/// about to be killed. The refusal therefore has to happen here, before the memory is
/// asked for.
///
/// Two limits, because one is not enough. A side limit keeps any single dimension sane,
/// and a total-pixel limit stops 20000 x 20000: that passes the side limit and is still
/// 1.6 GB per copy, and every operation holds three of them — the old bitmap, the undo
/// snapshot and the new one.
enum CanvasLimits {
    /// The longest either side may be.
    static let maxSide = 20000

    /// The most pixels a canvas may hold: 100 megapixels, 400 MB of RGBA.
    static let maxPixels = 100_000_000

    /// nil when the size is usable, otherwise the sentence to show the user.
    ///
    /// Note what is NOT done here: no clamping. A silently clamped resize is its own
    /// small betrayal — you ask for 5000% and get a picture that is not 5000% of
    /// anything — so the caller reports what was asked for and does nothing.
    static func rejection(for size: CGSize) -> String? {
        let w = size.width, h = size.height
        guard w.isFinite, h.isFinite, w >= 1, h >= 1 else {
            return "That is not a size Paintbox can use. Type a whole number of pixels, "
                 + "or a percentage of the current size."
        }
        if w.rounded() > CGFloat(maxSide) || h.rounded() > CGFloat(maxSide) {
            return "That would make \(describe(size)). The longest side Paintbox will make "
                 + "is \(maxSide) pixels."
        }
        if w.rounded() * h.rounded() > CGFloat(maxPixels) {
            return "That would make \(describe(size)). Paintbox will make pictures up to "
                 + "\(maxPixels / 1_000_000) megapixels — 10000 × 10000, for example."
        }
        return nil
    }

    /// "51200 × 38400 pixels (7.9 GB)". Written with a formatter rather than `Int(_:)`
    /// because this is called precisely when the numbers are absurd, and `Int(1e30)`
    /// traps.
    static func describe(_ size: CGSize) -> String {
        let w = Double(size.width), h = Double(size.height)
        guard w.isFinite, h.isFinite else { return "a picture of no describable size" }
        let pixels = String(format: "a %.0f × %.0f picture", w, h)
        let gb = w * h * 4 / 1_073_741_824
        return gb >= 0.05 ? pixels + String(format: " (%.1f GB)", gb) : pixels
    }

    /// Whole pixels for a size, never out of range and never a trap. Anything the dialogs
    /// let through has already passed `rejection(for:)`; this is what makes the
    /// conversion safe for everything else.
    static func pixelSize(_ size: CGSize) -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite else { return (1, 1) }
        let w = Int(max(1, min(Double(maxSide), Double(size.width).rounded())))
        let h = Int(max(1, min(Double(maxSide), Double(size.height).rounded())))
        return clamp(width: w, height: h)
    }

    /// The model layer's own last stop, so an operation that nobody asked a dialog about
    /// — a rotation that grows the canvas, say — still cannot allocate the world.
    /// Over the pixel budget both sides come down together, so the picture keeps its
    /// shape instead of being squashed.
    static func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = max(1, min(maxSide, width))
        var h = max(1, min(maxSide, height))
        if w * h > maxPixels {
            let scale = (Double(maxPixels) / (Double(w) * Double(h))).squareRoot()
            w = max(1, Int((Double(w) * scale).rounded(.down)))
            h = max(1, Int((Double(h) * scale).rounded(.down)))
        }
        return (w, h)
    }
}

/// How many undo steps a canvas of a given size can afford.
///
/// Undo here is whole-image snapshots (see PaintDocument), so one step costs one canvas:
/// 3 MB at 1024x768, but 91 MB on a 24-megapixel photograph. A fixed *number* of steps
/// therefore means an unbounded *size* — ten blurs on a phone photo held 2 GB, and
/// nothing trimmed the stack, ever — so the budget is in bytes and the number of steps
/// falls out of it.
enum UndoBudget {
    /// What the undo stack may hold, in bytes.
    static let bytes = 512 * 1024 * 1024

    /// Never fewer than this, however large the picture: an editor with two undo steps
    /// is not an editor. At the floor a 24-megapixel canvas holds about 550 MB.
    static let fewest = 6

    /// Never more than this, however small: past a few dozen steps nobody is undoing
    /// their way back, and the stack is only costing memory.
    static let most = 60

    static func levels(width: Int, height: Int) -> Int {
        let step = max(1, width * height * 4)
        return max(fewest, min(most, bytes / step))
    }

    /// What the status line says about a stack that cannot hold its full depth, or nil
    /// when it can and there is nothing to explain.
    ///
    /// A ceiling that is never mentioned is indistinguishable from a bug: six operations
    /// into editing a photograph, Cmd-Z stops working and the app has said nothing about
    /// why. The number and the reason both belong on screen.
    static func note(width: Int, height: Int) -> String? {
        let n = levels(width: width, height: height)
        guard n < most else { return nil }
        let mb = max(1, width * height * 4 / (1024 * 1024))
        return "undo \(n) steps (\(mb) MB each)"
    }
}

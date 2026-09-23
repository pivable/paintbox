import AppKit
import CoreGraphics

/// Which corner of a floating item is being dragged.
enum FloatingHandle: Int, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// A pasted picture that has not landed yet.
///
/// Paste used to stamp the clipboard straight into the bitmap at a fixed corner, which
/// made the cut-out tools half a feature: lifting a subject out is pointless if you
/// cannot then put it somewhere. A floating item hovers above the document — drag it,
/// drag a corner to scale it, hold Shift to keep its shape — and only becomes pixels
/// when it is committed, as ONE undo step.
///
/// It is deliberately not a layer. There is exactly one of them, it cannot be restyled,
/// and anything else the user does commits it first.
final class FloatingItem {
    /// The pasted pixels at their original size. Scaling always resamples from this, so
    /// dragging a corner in and back out again does not accumulate blur.
    let image: CGImage

    /// Where it sits, in image pixels with a top-left origin. May hang off the canvas.
    var frame: CGRect

    /// What it was called, for the undo menu ("Paste", "Drop Image").
    let actionName: String

    var naturalSize: CGSize { CGSize(width: image.width, height: image.height) }
    private var aspect: CGFloat { max(0.0001, CGFloat(image.width) / CGFloat(max(1, image.height))) }

    /// How big a corner grab-handle is, in VIEW points. Converted through the zoom on
    /// use, so it stays the same size on screen however far in you are.
    static let handleViewSize: CGFloat = 10

    init(image: CGImage, at origin: CGPoint, actionName: String = "Paste") {
        self.image = image
        self.actionName = actionName
        frame = CGRect(origin: origin, size: CGSize(width: image.width, height: image.height))
    }

    // MARK: - Handles

    func handleRect(_ handle: FloatingHandle, zoom: CGFloat) -> CGRect {
        let s = FloatingItem.handleViewSize / max(0.05, zoom)
        let p: CGPoint
        switch handle {
        case .topLeft: p = CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: p = CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: p = CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: p = CGPoint(x: frame.maxX, y: frame.maxY)
        }
        return CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
    }

    func hitHandle(_ point: CGPoint, zoom: CGFloat) -> FloatingHandle? {
        FloatingHandle.allCases.first { handleRect($0, zoom: zoom).contains(point) }
    }

    // MARK: - Manipulation

    func move(by delta: CGPoint) {
        frame = frame.offsetBy(dx: delta.x, dy: delta.y)
    }

    /// The corner that must stay put while `handle` is dragged.
    func anchor(for handle: FloatingHandle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .topRight: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomRight: return CGPoint(x: frame.minX, y: frame.minY)
        }
    }

    /// Drag one corner to `point`; `anchor` — the opposite corner, as it was when the
    /// drag STARTED — stays put. With `keepAspect` the item keeps its original
    /// proportions, sized by whichever axis the pointer moved further on.
    ///
    /// The anchor is a parameter rather than something this reads off the frame, because
    /// the frame is what the drag is changing. Drag a handle past the opposite corner and
    /// the frame flips, which is right and is what `abs` and the `max(1, …)` below are
    /// for — but a recomputed anchor flipped with it, so the fixed corner jumped to
    /// wherever the pointer had just been. The item then shrank and slid after the
    /// pointer instead of growing back out, and there was no way to undo the crossing
    /// short of cancelling the paste.
    func resize(to point: CGPoint, anchor: CGPoint, keepAspect: Bool) {
        var w = abs(point.x - anchor.x)
        var h = abs(point.y - anchor.y)
        if keepAspect {
            // Use the axis that moved further so the item follows the pointer rather
            // than snapping back when the drag is mostly sideways.
            if w / aspect >= h { h = w / aspect } else { w = h * aspect }
        }
        w = max(1, w.rounded())
        h = max(1, h.rounded())
        let x = point.x < anchor.x ? anchor.x - w : anchor.x
        let y = point.y < anchor.y ? anchor.y - h : anchor.y
        frame = CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }
}

extension PaintDocument {
    /// Stamp a floating item into the bitmap. One undo step covers the whole thing —
    /// the move, the scale and the paste — because nothing was written until now.
    func commit(_ item: FloatingItem) {
        let f = item.frame
        guard f.width >= 1, f.height >= 1 else { return }
        registerUndo(name: item.actionName)
        // A CGImage is placed with bottom-left maths; drawing one into a flipped context
        // would land it upside down, which is why this converts by hand.
        let cgY = CGFloat(pixelHeight) - f.origin.y - f.height
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(item.image, in: CGRect(x: f.origin.x, y: cgY, width: f.width, height: f.height))
        context.restoreGState()
        touch()
    }
}

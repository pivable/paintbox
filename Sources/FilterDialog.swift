import AppKit
import CoreImage
import Foundation

/// What a filter dialog tells its closure about the image it has just been handed.
///
/// The closure runs twice over: once on a downscaled TILE of the canvas for the preview,
/// once at full size on the whole canvas when the user clicks Apply. Everything that
/// differs between those two runs is here, so the closure itself stays one definition.
struct FilterContext {
    /// How much smaller this image is than the real canvas. 1 for the real run.
    let scale: CGFloat

    /// Where the CANVAS's top-left corner sits in this image, in CoreImage's bottom-up
    /// coordinates. Pixelate anchors its block grid there, so the preview's blocks land
    /// on the same grid lines the applied ones will.
    let canvasOrigin: CGPoint

    /// The real run: the image IS the canvas, at full size.
    static func fullSize(_ image: CIImage) -> FilterContext {
        FilterContext(scale: 1, canvasOrigin: CGPoint(x: image.extent.minX, y: image.extent.maxY))
    }
}

/// How a filter dialog computes the picture in its thumbnail.
///
/// Pulled out of the dialog and given no AppKit of its own so that it can be checked
/// against the real thing: "does the preview show what Apply will do" is a question
/// about pixels, and the self-test answers it by running this and `PaintDocument`'s
/// filter over the same picture and comparing them.
///
/// What it does NOT do — and what the dialog used to do — is hand the filter a cut-out
/// of the selection. Filtering a cut-out is the crop-blur-paste mistake the top of
/// Filters.swift exists to explain: the Gaussian samples the transparent nothing around
/// the cut-out, so the preview grew a dark semi-transparent halo the applied result never
/// had, and Pixelate's block grid started at the selection's corner rather than the
/// canvas's. Instead this takes a TILE — the selection's box plus a generous margin —
/// filters all of it, composites back through the mask exactly as Apply will, and shows
/// only the box.
struct FilterPreview {

    /// How much of the canvas around the selection to pull in, so a filter samples real
    /// neighbours at the selection's edge rather than the tile's. Comfortably more than
    /// three times the largest radius these dialogs offer, which is past where a Gaussian
    /// contributes anything.
    static let margin: CGFloat = 200

    /// The longest side of the shown region, in preview pixels.
    static let longSide: CGFloat = 320

    /// The downscaled tile everything is computed on.
    let tile: CGImage
    /// One coverage byte per tile pixel, or nil when nothing is selected.
    let coverage: [UInt8]?
    /// The part of the tile that is shown: the selection's own box.
    let shown: CGRect
    let context: FilterContext

    init?(image: CGImage?, mask: SelectionMask?) {
        guard let image else { return nil }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let selected = mask.flatMap { $0.isEmpty ? nil : $0 }
        let box = (selected?.bounds ?? full).integral.intersection(full)
        guard box.width >= 1, box.height >= 1 else { return nil }
        let t = box.insetBy(dx: -Self.margin, dy: -Self.margin).integral.intersection(full)
        let scale = min(1, Self.longSide / max(1, max(box.width, box.height)))
        let tw = max(1, Int((t.width * scale).rounded()))
        let th = max(1, Int((t.height * scale).rounded()))
        guard let cropped = Bitmap.crop(image, to: t, width: tw, height: th) else { return nil }
        tile = cropped

        // Nearest neighbour: the mask is a yes/no per canvas pixel, and a preview pixel is
        // either mostly in or mostly out. Interpolating would invent coverage values the
        // real composite never sees.
        if let selected {
            var cov = [UInt8](repeating: 0, count: tw * th)
            for py in 0..<th {
                let cy = Int(t.minY + (CGFloat(py) + 0.5) * t.height / CGFloat(th))
                for px in 0..<tw {
                    let cx = Int(t.minX + (CGFloat(px) + 0.5) * t.width / CGFloat(tw))
                    cov[py * tw + px] = selected.coverage(x: cx, y: cy)
                }
            }
            coverage = cov
        } else {
            coverage = nil
        }

        let inTile = CGRect(x: (box.minX - t.minX) * scale, y: (box.minY - t.minY) * scale,
                            width: max(1, box.width * scale), height: max(1, box.height * scale))
            .integral.intersection(CGRect(x: 0, y: 0, width: tw, height: th))
        shown = (inTile.width >= 1 && inTile.height >= 1)
            ? inTile : CGRect(x: 0, y: 0, width: tw, height: th)
        context = FilterContext(scale: scale,
                                canvasOrigin: CGPoint(x: -t.minX * scale,
                                                      y: CGFloat(th) + t.minY * scale))
    }

    /// The thumbnail for these slider values: filter the whole tile, composite it back
    /// through the mask, then crop to the selection's box — the same order, and the same
    /// mask arithmetic, that Apply uses.
    func render(values: [Double],
                _ transform: (CIImage, [Double], FilterContext) -> CIImage) -> CGImage? {
        guard let filtered = CanvasFilter.render(tile, { transform($0, values, context) }) else { return nil }
        let composed = coverage.flatMap { CanvasFilter.compose(filtered, over: tile, coverage: $0) }
            ?? filtered
        return Bitmap.crop(composed, to: shown)
    }
}

/// One slider in a filter dialog.
struct FilterSlider {
    let title: String
    let min: Double
    let max: Double
    let value: Double
    /// How the number is spelled next to the title: "12 px", "+0.20", and so on.
    let format: (Double) -> String
}

/// A small transparent-aware image well, so the preview of a blur on a cut-out does not
/// read as "black" when it is really "nothing".
private final class CheckerImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let size: CGFloat = 8
        NSColor(white: 1.0, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.84, alpha: 1).setFill()
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = 0
            while x < bounds.width {
                if (Int(x / size) + Int(y / size)) % 2 == 1 {
                    CGRect(x: x, y: y, width: size, height: size).fill()
                }
                x += size
            }
            y += size
        }
        guard let image else { return }
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(bounds.width / s.width, bounds.height / s.height, 1)
        let r = CGRect(x: (bounds.width - s.width * scale) / 2,
                       y: (bounds.height - s.height * scale) / 2,
                       width: s.width * scale, height: s.height * scale)
        image.draw(in: r)
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// A modal with N sliders and a live preview, used by Blur, Pixelate and Adjustments.
///
/// The preview and the real thing run the SAME closure over the same kind of image and in
/// the same order — see FilterPreview, which is where the thumbnail is actually computed.
/// Two separate code paths here would mean a preview you cannot trust, which is worse
/// than no preview at all.
final class FilterDialog: NSObject {

    private let sliders: [NSSlider]
    private let valueLabels: [NSTextField]
    private let specs: [FilterSlider]
    private let preview = CheckerImageView()
    private let source: FilterPreview?
    private let transform: (CIImage, [Double], FilterContext) -> CIImage

    private init(specs: [FilterSlider], image: CGImage?, mask: SelectionMask?,
                 transform: @escaping (CIImage, [Double], FilterContext) -> CIImage) {
        self.specs = specs
        self.transform = transform
        self.source = FilterPreview(image: image, mask: mask)
        var sl: [NSSlider] = []
        var lb: [NSTextField] = []
        for spec in specs {
            let s = NSSlider()
            s.minValue = spec.min
            s.maxValue = spec.max
            s.doubleValue = spec.value
            s.isContinuous = true
            sl.append(s)
            let l = NSTextField(labelWithString: spec.format(spec.value))
            l.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            lb.append(l)
        }
        sliders = sl
        valueLabels = lb
        super.init()
        for s in sliders {
            s.target = self
            s.action = #selector(sliderChanged(_:))
        }
    }

    private var values: [Double] { sliders.map { $0.doubleValue } }

    @objc private func sliderChanged(_ sender: NSSlider) {
        for (i, spec) in specs.enumerated() {
            valueLabels[i].stringValue = spec.format(sliders[i].doubleValue)
        }
        updatePreview()
    }

    private func updatePreview() {
        guard let source, let shown = source.render(values: values, transform) else { return }
        let rep = NSBitmapImageRep(cgImage: shown)
        let img = NSImage(size: CGSize(width: shown.width, height: shown.height))
        img.addRepresentation(rep)
        preview.image = img
    }

    /// Returns the slider values, or nil if the user cancelled.
    ///
    /// `image` is the WHOLE picture and `mask` the selection: see the note on the class
    /// for why the dialog is never given a cut-out.
    static func run(title: String, message: String, okTitle: String = "Apply",
                    image: CGImage?, mask: SelectionMask?, sliders specs: [FilterSlider],
                    transform: @escaping (CIImage, [Double], FilterContext) -> CIImage) -> [Double]? {
        let dialog = FilterDialog(specs: specs, image: image, mask: mask, transform: transform)

        let width: CGFloat = 340
        let previewHeight: CGFloat = 200
        let rowHeight: CGFloat = 42
        let height = previewHeight + 10 + CGFloat(specs.count) * rowHeight
        let view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))

        var y = height - previewHeight
        dialog.preview.frame = CGRect(x: 0, y: y, width: width, height: previewHeight)
        view.addSubview(dialog.preview)

        for (i, spec) in specs.enumerated() {
            y -= rowHeight
            let t = NSTextField(labelWithString: spec.title)
            t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            t.textColor = .secondaryLabelColor
            t.frame = CGRect(x: 2, y: y + 22, width: width - 80, height: 14)
            view.addSubview(t)
            dialog.valueLabels[i].frame = CGRect(x: width - 78, y: y + 22, width: 76, height: 14)
            view.addSubview(dialog.valueLabels[i])
            dialog.sliders[i].frame = CGRect(x: 0, y: y, width: width, height: 20)
            view.addSubview(dialog.sliders[i])
        }

        dialog.updatePreview()

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = view
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return dialog.values
    }
}

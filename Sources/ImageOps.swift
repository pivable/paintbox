import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Where a smaller image sits inside a larger canvas (or which part survives a smaller one).
enum Anchor: Int, CaseIterable {
    case topLeft = 0, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Top-left origin offset for placing a `old` sized image inside a `new` sized canvas.
    ///
    /// The centred offsets round TOWARDS ZERO, which is the only rounding that makes
    /// growing and shrinking by the same amount inverses of each other. `.rounded(.down)`
    /// is not symmetric across zero — an odd difference of +5 gave floor(2.5) = +2 while
    /// −5 gave floor(−2.5) = −3 — so Canvas Size to 1029 and straight back to 1024 slid
    /// the picture one pixel and replaced a row and a column of it with background fill.
    func offset(old: CGSize, new: CGSize) -> CGPoint {
        let dx = new.width - old.width
        let dy = new.height - old.height
        let x: CGFloat
        switch self {
        case .topLeft, .left, .bottomLeft: x = 0
        case .top, .center, .bottom: x = (dx / 2).rounded(.towardZero)
        case .topRight, .right, .bottomRight: x = dx
        }
        let y: CGFloat
        switch self {
        case .topLeft, .top, .topRight: y = 0
        case .left, .center, .right: y = (dy / 2).rounded(.towardZero)
        case .bottomLeft, .bottom, .bottomRight: y = dy
        }
        return CGPoint(x: x, y: y)
    }
}

extension PaintDocument {

    // MARK: - Crop

    /// `rect` is in image pixels, top-left origin.
    func crop(to rect: CGRect, actionName: String = "Crop to Selection") {
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        // Cropping to the whole canvas keeps every pixel and every dimension, so there is
        // nothing to undo and nothing new to save. Select All then Crop to Selection used
        // to leave the document edited, and Paintbox then offered to save a file
        // byte-identical to the one already on disk. `resizeImage` and `setCanvasSize`
        // have always refused their own no-op; this is the same guard, one operation over.
        guard r != bounds else { return }
        let w = Int(r.width)
        let h = Int(r.height)
        let src = image
        let ctx = Bitmap.makeContext(width: w, height: h)
        // Convert top-left rect origin into the bottom-left CG placement of the source.
        let drawY = -(CGFloat(pixelHeight) - r.origin.y - r.height)
        ctx.draw(src, in: CGRect(x: -r.origin.x, y: drawY,
                                 width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        registerUndo(name: actionName)
        install(image: ctx.makeImage(), width: w, height: h)
    }

    /// Crop to a selection of any shape.
    ///
    /// A bitmap is a rectangle, so the canvas can only ever become the mask's bounding
    /// box — but "Crop to Selection" after wanding a subject means the background AROUND
    /// that subject goes too, and cropping to the box alone silently left it there: the
    /// user asked for the shape and got the box, with nothing on screen to say why. So
    /// the box becomes the canvas and the pixels inside it that the mask does not cover
    /// are knocked out to transparent, which is what cropping to a shape means.
    ///
    /// It is `copy(mask:)` that does the knocking out, deliberately: Copy already cut
    /// out exactly this shape, and a second implementation of the same arithmetic is a
    /// second chance to disagree with it.
    func crop(to mask: SelectionMask?, actionName: String = "Crop to Selection") {
        guard let mask, !mask.isEmpty else { return }
        // A rectangular selection has no outside to clear, and the rect path carries the
        // no-op guard that keeps Select All then Crop from costing an undo step.
        guard !mask.isRectangular else { crop(to: mask.bounds, actionName: actionName); return }
        guard let cut = copy(mask: mask) else { return }
        registerUndo(name: actionName)
        install(image: cut, width: cut.width, height: cut.height)
    }

    // MARK: - Resize (resample the picture)

    func resizeImage(width: Int, height: Int) {
        // The dialog refuses anything over the limit and says so; this is the model's own
        // guard, because nothing that reaches a bitmap allocation should depend on a
        // dialog having validated it first.
        let (w, h) = CanvasLimits.clamp(width: width, height: height)
        guard w != pixelWidth || h != pixelHeight else { return }
        let ctx = Bitmap.context(from: image, width: w, height: h)
        registerUndo(name: "Resize Image")
        install(image: ctx.makeImage(), width: w, height: h)
    }

    // MARK: - Canvas size (change the paper, do not scale the picture)

    func setCanvasSize(width: Int, height: Int, anchor: Anchor, fill: NSColor?) {
        let (w, h) = CanvasLimits.clamp(width: width, height: height)
        guard w != pixelWidth || h != pixelHeight else { return }
        let ctx = Bitmap.makeContext(width: w, height: h)
        if let fill {
            ctx.setFillColor((fill.usingColorSpace(.sRGB) ?? .white).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let off = anchor.offset(old: pixelSize, new: CGSize(width: w, height: h))
        let src = image
        // Bottom-left origin placement equivalent to the top-left offset above.
        let cgY = CGFloat(h) - off.y - CGFloat(pixelHeight)
        ctx.draw(src, in: CGRect(x: off.x, y: cgY,
                                 width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        registerUndo(name: "Canvas Size")
        install(image: ctx.makeImage(), width: w, height: h)
    }

    // MARK: - Flip

    func flip(horizontal: Bool) {
        let w = pixelWidth
        let h = pixelHeight
        let src = image
        let ctx = Bitmap.makeContext(width: w, height: h)
        ctx.translateBy(x: horizontal ? CGFloat(w) : 0, y: horizontal ? 0 : CGFloat(h))
        ctx.scaleBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        registerUndo(name: horizontal ? "Flip Horizontal" : "Flip Vertical")
        install(image: ctx.makeImage(), width: w, height: h)
    }

    // MARK: - Rotate

    /// Quarter turns, lossless. `degrees` is 90, -90 or 180.
    func rotateQuarter(degrees: Int) {
        let src = image
        let w = pixelWidth
        let h = pixelHeight
        let name: String
        let newW: Int
        let newH: Int
        switch degrees {
        case 90, -270: newW = h; newH = w; name = "Rotate 90° Clockwise"
        case -90, 270: newW = h; newH = w; name = "Rotate 90° Anticlockwise"
        default: newW = w; newH = h; name = "Rotate 180°"
        }
        let ctx = Bitmap.makeContext(width: newW, height: newH)
        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        // CG rotates anticlockwise for positive angles; clockwise on screen means negative.
        let radians: CGFloat
        switch degrees {
        case 90, -270: radians = -.pi / 2
        case -90, 270: radians = .pi / 2
        default: radians = .pi
        }
        ctx.rotate(by: radians)
        ctx.draw(src, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        registerUndo(name: name)
        install(image: ctx.makeImage(), width: newW, height: newH)
    }

    /// Arbitrary angle, clockwise degrees, canvas grows to fit. New area is transparent.
    func rotateArbitrary(degrees: CGFloat) {
        // An infinite or NaN angle rotates the corners to NaN, and `Int(NaN)` is not an
        // error in Swift, it is a trap: the whole app dies, unsaved picture included.
        // Cheaper to refuse the angle than to catch that.
        guard degrees.isFinite else { return }

        // A right angle typed into the box must be the same operation as the menu item
        // next to it. Left to the general path it is not: cos(±π/2) is 6.1e-17 rather
        // than 0, so a 64x40 picture's rotated bounding box comes back 40.000000000000007
        // wide, `.rounded(.up)` turns that into 41, and — because the draw is centred —
        // every source pixel then lands on a half-pixel boundary and is resampled. A
        // one-pixel black/white checkerboard came out 41x64 with 1248 of its 2624 pixels
        // turned to intermediate grey, plus a transparent sliver down one edge.
        let turns = (degrees / 90).rounded()
        if abs(degrees - turns * 90) < 1e-6 {
            switch ((Int(turns) % 4) + 4) % 4 {
            case 0: return                            // a whole turn changes nothing
            case 1: rotateQuarter(degrees: 90)
            case 2: rotateQuarter(degrees: 180)
            default: rotateQuarter(degrees: -90)
            }
            return
        }

        let radians = -degrees * .pi / 180
        let w = CGFloat(pixelWidth)
        let h = CGFloat(pixelHeight)
        let t = CGAffineTransform(rotationAngle: radians)
        let box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h).applying(t)
        guard box.width.isFinite, box.height.isFinite, box.width >= 1, box.height >= 1 else { return }
        // The same floating-point fuzz, one step smaller: a box that is integral to
        // within an epsilon must not gain a whole pixel of transparent margin.
        let (newW, newH) = CanvasLimits.clamp(width: Int((box.width - 1e-6).rounded(.up)),
                                              height: Int((box.height - 1e-6).rounded(.up)))
        let src = image
        let ctx = Bitmap.makeContext(width: newW, height: newH)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: radians)
        ctx.draw(src, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        registerUndo(name: "Rotate by Angle")
        install(image: ctx.makeImage(), width: newW, height: newH)
    }

    // MARK: - Remove background (Vision, on device)

    func removeBackground() throws {
        let src = image
        let cut = try BackgroundRemover.cutout(from: src)
        registerUndo(name: "Remove Background")
        install(image: cut, width: pixelWidth, height: pixelHeight)
    }

    // MARK: - Clipboard helpers

    /// `rect` is top-left origin image pixels; nil means the whole image.
    func copy(rect: CGRect?) -> CGImage? {
        guard let rect else { return image }
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let ctx = Bitmap.makeContext(width: Int(r.width), height: Int(r.height))
        let drawY = -(CGFloat(pixelHeight) - r.origin.y - r.height)
        ctx.draw(image, in: CGRect(x: -r.origin.x, y: drawY,
                                   width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        return ctx.makeImage()
    }

    /// Copy through the selection mask: the result is the mask's bounding box, with
    /// everything the mask does not cover knocked out to transparent. An irregular
    /// wand selection therefore copies as a cut-out rather than as its bounding box,
    /// which is what makes wand → copy → paste useful.
    func copy(mask: SelectionMask?) -> CGImage? {
        guard let mask, !mask.isEmpty else { return image }
        guard let cropped = copy(rect: mask.bounds) else { return nil }
        if mask.isRectangular { return cropped }
        let ctx = Bitmap.context(from: cropped)
        guard let p = ctx.pixels else { return cropped }
        let ox = Int(mask.bounds.minX), oy = Int(mask.bounds.minY)
        for y in 0..<ctx.height {
            let row = y * ctx.bytesPerRow
            for x in 0..<ctx.width {
                let m = mask.coverage(x: ox + x, y: oy + y)
                if m == 255 { continue }
                let o = row + x * 4
                if m == 0 {
                    p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0
                } else {
                    // Premultiplied, so scaling all four channels is the correct fade.
                    for k in 0..<4 { p[o + k] = UInt8(Int(p[o + k]) * Int(m) / 255) }
                }
            }
        }
        return ctx.makeImage()
    }

    func clear(rect: CGRect?, to color: NSColor?) {
        let r = (rect ?? bounds).integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        edit(color == nil ? "Erase Selection" : "Fill Selection") { c in
            if let color {
                c.setFillColor((color.usingColorSpace(.sRGB) ?? .white).cgColor)
                c.fill(r)
            } else {
                c.clear(r)
            }
        }
    }

    /// Erase (`color == nil`) or fill the selection. This is what Delete does, and with a
    /// magic-wand selection it is the whole point: wand the white box behind a logo,
    /// press Delete, and exactly those pixels become transparent.
    ///
    /// A nil or empty mask means the whole canvas, which is what the rectangle version
    /// did with a nil rect.
    /// Filling with a colour COMPOSITES it; erasing (`color == nil`) replaces with
    /// transparency. Those are the two different things the two verbs mean, and both
    /// paths below now agree on them.
    ///
    /// They did not. The rectangular shortcut fills through CGContext, which composites;
    /// the loop wrote the four source bytes in, which replaces and so carries the
    /// destination's alpha away. One menu command, one colour, two answers — and which
    /// one you got depended on whether your selection happened to be a box, which is
    /// exactly the case the mask refactor exists for. With an opaque colour the two
    /// always agreed, which is why nothing caught it.
    func clear(mask: SelectionMask?, to color: NSColor?) {
        guard let mask, !mask.isEmpty else { clear(rect: nil, to: color); return }
        let replacement = color.map { RGBA.premultiplied($0) } ?? .clear
        // The shortcut is a pure optimisation only while the two paths cannot disagree:
        // CGContext composites in floating point and the loop composites in bytes, which
        // for a translucent colour could differ by a level. Opaque fills and erases are
        // the same write either way, and they are the overwhelmingly common case.
        if mask.isRectangular, color == nil || replacement.a == 255 {
            clear(rect: mask.bounds, to: color); return
        }

        let name = color == nil ? "Erase Selection" : "Fill Selection"
        registerUndo(name: name)
        guard let p = context.pixels else { return }
        let bpr = context.bytesPerRow
        // Clamped to the canvas, in case the mask outlived a resize.
        let x0 = max(0, Int(mask.bounds.minX)), x1 = min(pixelWidth, Int(mask.bounds.maxX))
        let y0 = max(0, Int(mask.bounds.minY)), y1 = min(pixelHeight, Int(mask.bounds.maxY))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            let row = y * bpr
            for x in x0..<x1 {
                let m = Int(mask.coverage(x: x, y: y))
                guard m > 0 else { continue }
                let o = row + x * 4
                if color == nil {
                    // Erase: fade the destination out by the mask's coverage. Nothing is
                    // laid over the top, so this one really is a replace.
                    let inv = 255 - m
                    for k in 0..<4 { p[o + k] = UInt8((Int(p[o + k]) * inv + 127) / 255) }
                } else {
                    // Fill: source-over, with the source's own alpha scaled by coverage.
                    // Premultiplied, so scaling all four channels is the right fade.
                    let src = RGBA(r: UInt8(Int(replacement.r) * m / 255),
                                   g: UInt8(Int(replacement.g) * m / 255),
                                   b: UInt8(Int(replacement.b) * m / 255),
                                   a: UInt8(Int(replacement.a) * m / 255))
                    Painter.blend(p, o, src)
                }
            }
        }
        touch()
    }
}

/// Vision's subject lifting, run entirely on device.
enum BackgroundRemover {
    static func cutout(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw PaintboxError.message("Vision could not find a subject in this picture, so there is no background to remove.")
        }
        let maskBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let input = CIImage(cgImage: image)

        // Line the mask up with the picture: origin to zero, then scale to the same extent.
        mask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.origin.x,
                                                      y: -mask.extent.origin.y))
        if mask.extent.width > 0, mask.extent.height > 0 {
            let sx = input.extent.width / mask.extent.width
            let sy = input.extent.height / mask.extent.height
            if abs(sx - 1) > 0.0001 || abs(sy - 1) > 0.0001 {
                mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
        }
        // No background image: everything the mask does not select becomes transparent.
        let out = input.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: mask])
        let ciContext = CIContext(options: [.workingColorSpace: paintboxColorSpace,
                                            .outputColorSpace: paintboxColorSpace])
        guard let cg = ciContext.createCGImage(out, from: input.extent, format: .RGBA8,
                                               colorSpace: paintboxColorSpace) else {
            throw PaintboxError.message("Could not render the cut-out image.")
        }
        // Normalise back into our canonical bitmap format.
        return Bitmap.context(from: cg).makeImage() ?? cg
    }
}

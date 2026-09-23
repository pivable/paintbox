import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one colour space the whole app works in. Every bitmap, every export.
let paintboxColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Straight (non-premultiplied conceptually, stored premultiplied) RGBA sample.
struct RGBA: Equatable, CustomStringConvertible {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    var description: String { "rgba(\(r),\(g),\(b),\(a))" }

    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// Premultiplied bytes for an NSColor.
    static func premultiplied(_ color: NSColor) -> RGBA {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.black
        let a = c.alphaComponent
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * a * 255).rounded()))) }
        return RGBA(r: b(c.redComponent), g: b(c.greenComponent), b: b(c.blueComponent),
                    a: UInt8(max(0, min(255, (a * 255).rounded()))))
    }

    /// Unpremultiplied NSColor for a stored sample.
    var color: NSColor {
        if a == 0 { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
        let af = CGFloat(a) / 255.0
        return NSColor(srgbRed: min(1, CGFloat(r) / 255.0 / af),
                       green: min(1, CGFloat(g) / 255.0 / af),
                       blue: min(1, CGFloat(b) / 255.0 / af),
                       alpha: af)
    }
}

enum Bitmap {
    /// Canonical context: 8-bit RGBA, premultiplied-last, byte order big, sRGB.
    /// Memory layout is R,G,B,A per pixel with row 0 at the TOP of the image.
    static func makeContext(width: Int, height: Int) -> CGContext {
        let w = max(1, width)
        let h = max(1, height)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: paintboxColorSpace,
                                  bitmapInfo: info) else {
            fatalError("Paintbox: could not allocate a \(w)x\(h) bitmap")
        }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// New context containing `image`, optionally resampled to a new size.
    static func context(from image: CGImage, width: Int? = nil, height: Int? = nil) -> CGContext {
        let w = width ?? image.width
        let h = height ?? image.height
        let ctx = makeContext(width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// Whether an image is ALREADY laid out the way `makeContext` lays one out: 8-bit
    /// RGBA, premultiplied last, sRGB. Byte order is not compared as a number, because
    /// the components are single bytes and so `.order32Big` and the unspecified
    /// `.orderDefault` describe the identical R,G,B,A sequence — CoreImage hands back the
    /// latter for the same layout CoreGraphics reports as the former.
    ///
    /// Row padding is deliberately not part of the question. Every reader here goes
    /// through `bytesPerRow`, so a padded row is canonical too; only the sample format
    /// and the colour space decide what the bytes MEAN.
    static func isCanonical(_ image: CGImage) -> Bool {
        let order = image.byteOrderInfo
        return image.bitsPerComponent == 8 && image.bitsPerPixel == 32
            && image.alphaInfo == .premultipliedLast
            && (order == .order32Big || order == .orderDefault)
            && image.colorSpace?.name == paintboxColorSpace.name
    }

    /// The same question about a CONTEXT: is this buffer laid out the way every pixel
    /// reader in the app assumes — 8-bit RGBA, premultiplied last, sRGB? Asked by
    /// `PaintDocument.init(adopting:)`, which takes a context at its word and would
    /// otherwise hand the whole app a canvas whose bytes mean something else.
    static func isCanonical(_ ctx: CGContext) -> Bool {
        // A context reports its byte order only inside `bitmapInfo`, unlike an image.
        let order = CGImageByteOrderInfo(
            rawValue: ctx.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        return ctx.bitsPerComponent == 8 && ctx.bitsPerPixel == 32
            && ctx.alphaInfo == .premultipliedLast
            && (order == .order32Big || order == .orderDefault)
            && ctx.colorSpace?.name == paintboxColorSpace.name
    }

    /// The image in canonical format, redrawing it ONLY if it is not already there.
    ///
    /// The redraw is not free: on a 6000x4000 picture it is ~65 ms and a transient 96 MB,
    /// which is as much as the Gaussian blur whose output it used to normalise. Anything
    /// that comes back from a CoreImage render asked for `.RGBA8` in `paintboxColorSpace`
    /// is canonical already, so that was a copy of the bytes onto themselves.
    static func canonical(_ image: CGImage) -> CGImage {
        isCanonical(image) ? image : (context(from: image).makeImage() ?? image)
    }

    /// How many frames the file holds. 0 when it cannot be read at all, 1 for an
    /// ordinary picture, more for an animated GIF and the like.
    ///
    /// `load` takes frame 0 and always has. This is the number that lets the rest of the
    /// app admit it, instead of overwriting a 40-frame animation with one frame and
    /// calling it a save.
    static func frameCount(url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    /// The name of the file's colour space when it is WIDER than sRGB — "Display P3",
    /// "Adobe RGB" and so on — and nil for the ordinary sRGB or grey file.
    ///
    /// Every bitmap in Paintbox is 8-bit sRGB (`paintboxColorSpace`), and `load`
    /// normalises into that, so a Display P3 photograph is hard-clipped on the way in:
    /// P3 red is (1.093, -0.227, -0.150) in extended sRGB, and the parts outside the cube
    /// are gone for good — undo cannot reach them, and ⌘S then writes the duller pixels
    /// back over the original. Converting is the right trade for a screenshot annotator;
    /// doing it in silence is not. So the window owns up to it for as long as the picture
    /// is open, exactly as it owns up to editing one frame of an animated GIF.
    static func wideGamutName(url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let space = raw.colorSpace, space.isWideGamutRGB
        else { return nil }
        // `name` is a reverse-DNS constant; the few spaces a camera or a screenshot
        // actually produces are spelled the way a person says them, and anything else
        // falls back to the constant with its prefix taken off.
        switch space.name {
        case CGColorSpace.displayP3, CGColorSpace.extendedDisplayP3: return "Display P3"
        case CGColorSpace.adobeRGB1998: return "Adobe RGB"
        case CGColorSpace.itur_2020: return "Rec. 2020"
        case let other?: return (other as String).replacingOccurrences(of: "kCGColorSpace", with: "")
        default: return "a wide-gamut profile"
        }
    }

    /// Load the first frame of any image file CoreGraphics understands, the right way up.
    ///
    /// `CGImageSourceCreateImageAtIndex` hands back the STORED pixel buffer and ignores
    /// the EXIF/TIFF Orientation tag. Every other part of macOS — Finder, Preview, Quick
    /// Look, NSImage — applies it, and an iPhone shooting in portrait stores the frame
    /// landscape with Orientation 6, so a portrait photo opened here arrived on its side
    /// and then Save wrote the sideways pixels with no tag at all, making the rotation
    /// permanent everywhere else too.
    static func load(url: URL) -> CGImage? {
        loadContext(url: url)?.makeImage()
    }

    /// The same load, handed over as the CONTEXT it was normalised into rather than as an
    /// image of it, for the one caller that is about to want a mutable canvas anyway.
    ///
    /// Opening a file used to cost two full-size copies: `load` normalised the decoded
    /// frame into a canonical context and made an image of it, and `PaintDocument` then
    /// allocated a second canonical context and drew that image into it. On a 6000x4000
    /// JPEG that is 84 ms and 91 MB, then another 13 ms and another 91 MB — peak 200 MB
    /// for a 91 MB picture, at the exact moment a machine short of memory can least
    /// afford it. The second copy was pure duplication: the first context is already the
    /// canvas, so `PaintDocument.init(adopting:)` takes it.
    ///
    /// The context is freshly made here and handed to exactly one owner. Nobody else may
    /// keep a reference to it, or two documents would be drawing on one buffer.
    static func loadContext(url: URL) -> CGContext? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        // Normalise into our canonical format so alpha and colour space are predictable.
        return orientedContext(raw, orientation: orientation)
    }

    /// Bake an EXIF orientation (1...8) into the pixels, returning a canonical bitmap.
    /// Orientation 1 is the no-op every ordinary file has, and takes the plain path.
    static func oriented(_ image: CGImage, orientation: Int) -> CGImage? {
        orientedContext(image, orientation: orientation)?.makeImage()
    }

    /// The rotation itself, as the context it was drawn into. See `loadContext` for why
    /// the context rather than an image of it.
    static func orientedContext(_ image: CGImage, orientation: Int) -> CGContext? {
        guard (2...8).contains(orientation) else { return context(from: image) }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // 5...8 are the transposed ones: the picture's own width and height swap over.
        let swaps = orientation >= 5
        let outW = Int(swaps ? h : w), outH = Int(swaps ? w : h)
        let ctx = makeContext(width: outW, height: outH)
        ctx.interpolationQuality = .none

        // Written out as the matrix each tag means rather than as a pile of translates
        // and rotates, because eight cases of "which way round is this one" is exactly
        // where a sign gets lost. Coordinates are CoreGraphics' own, bottom-left origin,
        // and each row says where a source point lands in the output.
        let t: CGAffineTransform
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)    // mirrored
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)   // 180°
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)    // flipped
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)   // transposed
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)    // 90° clockwise
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)     // transverse
        default: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)   // 8: 90° anticlockwise
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// The part of `image` inside `rect` — top-left origin image pixels — optionally
    /// resampled to `width` x `height`. Used by the filter dialogs, which preview a
    /// padded tile of the canvas rather than a cut-out of the selection.
    static func crop(_ image: CGImage, to rect: CGRect, width: Int? = nil, height: Int? = nil) -> CGImage? {
        let r = rect.integral
        guard r.width >= 1, r.height >= 1 else { return nil }
        let w = max(1, width ?? Int(r.width))
        let h = max(1, height ?? Int(r.height))
        let ctx = makeContext(width: w, height: h)
        ctx.interpolationQuality = .high
        let sx = CGFloat(w) / r.width, sy = CGFloat(h) / r.height
        // Place the whole source so that `r` lands on the whole context. The y term
        // converts the top-left rect into CoreGraphics' bottom-left placement.
        ctx.draw(image, in: CGRect(x: -r.minX * sx,
                                   y: -(CGFloat(image.height) - r.maxY) * sy,
                                   width: CGFloat(image.width) * sx,
                                   height: CGFloat(image.height) * sy))
        return ctx.makeImage()
    }
}

enum PaintboxError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// A read-only view of an image's canonical pixel bytes, borrowed rather than copied
/// whenever the image already has them.
///
/// `PaintDocument.composite` used to reach a replacement's bytes by drawing the whole
/// image into a second full-size context: 11 ms and a transient 91 MB on a 6000x4000
/// canvas, spent copying bytes that were already laid out exactly the way the loop below
/// wanted them. Everything `CanvasFilter.render` returns is canonical by construction,
/// so that was the bytes copied onto themselves.
///
/// Borrowing is only safe when the provider's data really IS the pixels. A CGImage that
/// an image source decoded keeps the ENCODED file as its data provider — a PNG's bytes,
/// not the picture's — and `utType` is non-nil for exactly those, which is why it is
/// asked as well as the layout and the length. Anything that fails a check falls back to
/// the copy that always worked, so the worst case is what today's cost already is.
struct PixelReader {
    /// Premultiplied R,G,B,A, row 0 at the top.
    let bytes: UnsafePointer<UInt8>
    let bytesPerRow: Int
    /// Whether the image's own buffer is being read. False means a copy was needed; the
    /// self-test reads it to prove the fast path is reached at all.
    let borrowed: Bool
    /// Whatever owns `bytes` — the image's data or the context copied into. Held so the
    /// buffer outlives this reader.
    private let owner: AnyObject

    init?(_ image: CGImage) {
        if Bitmap.isCanonical(image), image.utType == nil,
           let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * image.height,
           let p = CFDataGetBytePtr(data) {
            bytes = p
            bytesPerRow = image.bytesPerRow
            borrowed = true
            owner = data
            return
        }
        let ctx = Bitmap.context(from: image)
        guard let p = ctx.pixels else { return nil }
        bytes = UnsafePointer(p)
        bytesPerRow = ctx.bytesPerRow
        borrowed = false
        owner = ctx
    }
}

extension CGContext {
    /// Raw pixels, top-left origin. Only valid for contexts made by `Bitmap.makeContext`.
    var pixels: UnsafeMutablePointer<UInt8>? {
        data?.assumingMemoryBound(to: UInt8.self)
    }

    /// Read one pixel using top-left origin coordinates.
    func sample(x: Int, y: Int) -> RGBA {
        guard x >= 0, y >= 0, x < width, y < height, let p = pixels else { return .clear }
        let o = y * bytesPerRow + x * 4
        return RGBA(r: p[o], g: p[o + 1], b: p[o + 2], a: p[o + 3])
    }

    /// Run `body` with the coordinate system flipped so (0,0) is the TOP-left pixel,
    /// which is how the rest of Paintbox talks about image coordinates.
    func withTopLeftOrigin(_ body: (CGContext) -> Void) {
        saveGState()
        translateBy(x: 0, y: CGFloat(height))
        scaleBy(x: 1, y: -1)
        body(self)
        restoreGState()
    }

    /// `withTopLeftOrigin`, with everything `body` draws confined to `mask` — which is
    /// what a painting tool wants: image coordinates, and the selection honoured.
    func withTopLeftOrigin(clippedTo mask: SelectionMask?, _ body: (CGContext) -> Void) {
        clipping(to: mask) { $0.withTopLeftOrigin(body) }
    }

    /// Run `body` with everything it draws confined to `mask`. A nil or empty mask, or
    /// one that does not fit this bitmap, means no clip at all.
    ///
    /// The filters, Cut and Delete have always respected the selection and the painting
    /// tools did not, so marching ants drawn to protect the rest of the picture only
    /// protected it from half the app. The ants promise containment; this is how the
    /// promise is kept.
    ///
    /// The clip is set here, on the bitmap's own bottom-left-origin context, because a
    /// CoreGraphics image mask lands its row 0 at the TOP of the rect it is given only
    /// while the context is unflipped — and row 0 of a `SelectionMask` is the canvas's
    /// top row. `Painter`'s own `withTopLeftOrigin` flip happens inside `body`, under
    /// this clip, which is unaffected by it.
    func clipping(to mask: SelectionMask?, _ body: (CGContext) -> Void) {
        guard let mask = Painter.confined(mask, to: self) else {
            body(self)
            return
        }
        saveGState()
        defer { restoreGState() }
        if mask.isRectangular {
            // Four numbers rather than a megabyte of stencil, which is every selection
            // the rectangle tool makes.
            let b = mask.bounds
            clip(to: CGRect(x: b.minX, y: CGFloat(height) - b.maxY,
                            width: b.width, height: b.height))
        } else if let stencil = mask.stencilImage() {
            clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: stencil)
        } else {
            // No stencil means no honest clip, and painting everywhere is the bug this
            // exists to stop: paint nothing instead.
            return
        }
        body(self)
    }
}

extension CGImage {
    func sampleGrid() -> CGContext {
        Bitmap.context(from: self)
    }
}

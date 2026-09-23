import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything Paintbox can write.
///
/// The list is not a guess: `CGImageDestinationCopyTypeIdentifiers()` on this machine
/// reports writers for all seven, and `SaveFormat.available` re-checks at run time so a
/// format that disappears in some future macOS drops out of the menu instead of failing
/// at the save panel.
///
/// **WebP is deliberately absent.** Apple's imaging layer reads WebP perfectly well — a
/// .webp opens in Paintbox like anything else — but it ships no WebP *writer*, so there
/// is no honest way to offer it as an export. Offering it and silently writing a PNG
/// would be worse than not offering it.
enum SaveFormat: String, CaseIterable {
    case png, jpeg, heic, avif, tiff, gif, bmp

    var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        }
    }

    var utType: UTType? { UTType(typeIdentifier) }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        case .tiff: return "tiff"
        case .gif: return "gif"
        case .bmp: return "bmp"
        }
    }

    /// Spellings that should select this format when an existing file is re-saved.
    var extensions: [String] {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tiff", "tif"]
        case .heic: return ["heic", "heif"]
        default: return [fileExtension]
        }
    }

    /// How much of an alpha channel a format really has.
    enum Transparency {
        /// Every level of alpha survives: png, tiff, heic, avif, bmp.
        case graded
        /// On or off and nothing in between: gif.
        case binary
        /// None at all: jpeg.
        case none
    }

    /// GIF is the interesting one. It was grouped with the alpha-keeping formats, which
    /// meant a premultiplied image went straight to the writer; CoreGraphics resolves
    /// one-bit alpha by unpremultiplying and calling every non-zero alpha opaque, so a
    /// Vision cut-out's soft edge came back at FULL saturation and full opacity — a
    /// bright fringe one or two pixels wide all the way round the subject. Matting it
    /// first is what the save panel's note already promises.
    var transparency: Transparency {
        switch self {
        case .jpeg: return .none
        case .gif: return .binary
        default: return .graded
        }
    }

    /// True when the picture may be handed to the writer with its alpha intact.
    var keepsAlpha: Bool { transparency != .none }

    /// Whether the quality slider does anything.
    var isLossy: Bool { self == .jpeg || self == .heic || self == .avif }

    var menuTitle: String {
        switch self {
        case .png: return "PNG (keeps transparency)"
        case .jpeg: return "JPEG (no transparency)"
        case .heic: return "HEIC (small, keeps transparency)"
        case .avif: return "AVIF (small, keeps transparency)"
        case .tiff: return "TIFF (lossless, keeps transparency)"
        case .gif: return "GIF (256 colours, on/off transparency)"
        case .bmp: return "BMP (uncompressed)"
        }
    }

    static func forExtension(_ ext: String) -> SaveFormat? {
        let e = ext.lowercased()
        return allCases.first { $0.extensions.contains(e) }
    }

    /// The formats this copy of macOS actually has a writer for.
    static let available: [SaveFormat] = {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { ids.contains($0.typeIdentifier) }
    }()
}

extension Bitmap {
    /// Write `image` in any supported format. Formats without an alpha channel are
    /// composited onto `matte` — the background swatch — first, exactly as JPEG always was.
    ///
    /// **Every file Paintbox writes comes through here**, the `--cutout` command line
    /// included. There used to be a second pair of writers on `Bitmap` — one PNG, one
    /// JPEG — left over from before this one existed. Nothing in the app could reach the
    /// JPEG one any more, but the self-test still called it, so the test that read "save
    /// JPEG" was testing code no user could run while the writer that ships went
    /// unexercised. One writer is one thing to test.
    static func write(_ image: CGImage, to url: URL, format: SaveFormat,
                      quality: CGFloat = 0.8, matte: NSColor = .white) throws {
        var out = image
        switch format.transparency {
        case .graded:
            break
        case .none:
            let ctx = makeContext(width: image.width, height: image.height)
            ctx.setFillColor((matte.usingColorSpace(.sRGB) ?? .white).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flat = ctx.makeImage() else {
                throw PaintboxError.message("Could not flatten the picture for \(format.rawValue.uppercased()).")
            }
            out = flat
        case .binary:
            guard let matted = matteToBinaryAlpha(image, matte: matte) else {
                throw PaintboxError.message("Could not prepare the picture for \(format.rawValue.uppercased()).")
            }
            out = matted
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                        format.typeIdentifier as CFString, 1, nil) else {
            throw PaintboxError.message("This Mac has no \(format.rawValue.uppercased()) writer.")
        }
        var options: [CFString: Any] = [:]
        // macOS's AVIF writer refuses a quality of exactly 1.0: `CGImageDestinationFinalize`
        // returns false and no file is created, so the one slider position that reads as
        // "best" was the one position that could not be saved. JPEG and HEIC are fine at
        // 1.0, so only AVIF gives up the last hundredth.
        if format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = format == .avif ? min(quality, 0.99)
                                                                                  : quality
        }
        CGImageDestinationAddImage(dest, out, options as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw PaintboxError.message("Writing \(url.lastPathComponent) failed.")
        }
    }

    /// Prepare a picture for a format whose transparency is on or off: every partially
    /// transparent pixel is composited onto `matte` and then made either fully opaque or
    /// fully clear, at the half-way line. Pixels that are already fully opaque or fully
    /// clear are left exactly as they are, so a flat-coloured drawing round-trips
    /// unchanged and only the antialiased edges are resolved.
    static func matteToBinaryAlpha(_ image: CGImage, matte: NSColor) -> CGImage? {
        let ctx = context(from: image)
        guard let p = ctx.pixels else { return image }
        let m = RGBA.premultiplied((matte.usingColorSpace(.sRGB) ?? .white).withAlphaComponent(1))
        let bpr = ctx.bytesPerRow
        for y in 0..<ctx.height {
            let row = y * bpr
            for x in 0..<ctx.width {
                let o = row + x * 4
                let a = Int(p[o + 3])
                if a == 255 || a == 0 { continue }
                if a >= 128 {
                    // Source-over onto the opaque matte, then declare it opaque.
                    let inv = 255 - a
                    p[o] = UInt8(min(255, Int(p[o]) + (Int(m.r) * inv + 127) / 255))
                    p[o + 1] = UInt8(min(255, Int(p[o + 1]) + (Int(m.g) * inv + 127) / 255))
                    p[o + 2] = UInt8(min(255, Int(p[o + 2]) + (Int(m.b) * inv + 127) / 255))
                    p[o + 3] = 255
                } else {
                    p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0
                }
            }
        }
        return ctx.makeImage()
    }
}

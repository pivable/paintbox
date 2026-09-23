import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// The CoreImage half of the editor: blur, pixelate, brightness/contrast/saturation,
/// grayscale, invert — each of which can be confined to the selection.
///
/// The one interesting problem here is the classic masked-blur bug. The naive way is to
/// crop the selection out, blur the crop and paste it back. That looks wrong at every
/// edge, because a Gaussian run over a cropped tile has nothing to sample beyond the
/// tile, so it mixes in transparent black and you get a dark, soft halo exactly where
/// you wanted a clean boundary.
///
/// So nothing here is ever cropped before filtering. The filter graph is always built on
/// the WHOLE canvas — clamped at the canvas edge, so the picture's own border does not
/// bleed either — and only then are the filtered pixels copied back through the mask.
/// Inside the selection the blur has sampled real neighbouring pixels, including ones
/// outside the selection, which is what every other image editor does. Outside the
/// selection the bytes are not touched at all: not "recomputed and found to be the same",
/// literally never written.
///
/// What is *rendered* is a different question from what the graph is built on, and that is
/// the difference between blurring a 40x40 box and blurring a 12-megapixel photograph in
/// order to keep 1600 pixels of it — measured here as 0.017s against 0.113s, and worse the
/// bigger the picture and the wider the radius.
/// CoreImage is lazy: asking `createCGImage` for a sub-rectangle makes it work backwards
/// through the graph and pull only the source pixels that sub-rectangle needs — which for
/// a Gaussian is the region plus its own radius, fetched from the full-extent input. So
/// rendering only the selection's bounding box samples exactly the same neighbours as
/// rendering everything, and costs what the selection costs rather than what the photo
/// costs. No manual padding is needed: the filter states its own region of interest, and
/// it knows the radius better than the caller does.
enum CanvasFilter {

    /// One context for the app. Building a CIContext is expensive and it is thread-safe.
    static let ciContext = CIContext(options: [
        .workingColorSpace: paintboxColorSpace,
        .outputColorSpace: paintboxColorSpace,
    ])

    /// Run a CoreImage transform over a whole image and return it in our canonical bitmap
    /// format. `nil` if CoreImage could not render, in which case callers do nothing.
    static func render(_ image: CGImage, _ transform: (CIImage) -> CIImage) -> CGImage? {
        render(image, region: CGRect(x: 0, y: 0, width: image.width, height: image.height),
               transform)
    }

    /// The same transform, rendered over `region` only — image pixels, top-left origin,
    /// as everything else in this app counts them. The returned image is `region`-sized,
    /// so the caller has to know where it came from; `PaintDocument.composite` takes the
    /// origin for exactly that reason.
    static func render(_ image: CGImage, region: CGRect,
                       _ transform: (CIImage) -> CIImage) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = region.integral.intersection(full)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let input = CIImage(cgImage: image)
        let out = transform(input).cropped(to: input.extent)
        // CoreImage counts from the bottom left, and our regions count from the top left.
        let ciRect = CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY,
                            width: r.width, height: r.height)
        guard let cg = ciContext.createCGImage(out, from: ciRect, format: .RGBA8,
                                               colorSpace: paintboxColorSpace) else { return nil }
        // `.RGBA8` in our own colour space IS the canonical bitmap format, so the
        // normalising redraw that used to end this function copied the bytes onto
        // themselves — measured at ~65 ms and 96 MB of transient memory on a 6000x4000
        // canvas, about what the Gaussian it was normalising cost. The check stays,
        // because "CoreImage honoured the format it was asked for" is an assumption and
        // not a guarantee; only the copy is gone.
        return Bitmap.canonical(cg)
    }

    // MARK: - The transforms themselves
    //
    // Each of these is used twice: once at preview scale inside the dialog, and once at
    // full size when the user clicks OK. Keeping one definition is the only way the
    // preview can be trusted.

    /// `clampedToExtent` is what stops the canvas edge going soft and transparent.
    static func blur(_ ci: CIImage, radius: CGFloat) -> CIImage {
        guard radius > 0 else { return ci }
        return ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
    }

    /// Blocks are anchored to the TOP-left of the picture, so the grid lines fall on
    /// 0, scale, 2·scale … counting down from the top edge and a redaction block lines
    /// up with the thing it is covering.
    ///
    /// Despite the name, CIPixellate's `inputCenter` behaves as a block CORNER: measured
    /// empirically, the block edges land on `inputCenter + k·scale`, not on
    /// `inputCenter ± scale/2`. Hence the image's own top edge (maxY in CoreImage's
    /// bottom-up coordinates) rather than half a block in from it.
    ///
    /// `anchor` exists for the preview, which filters a TILE of the canvas rather than
    /// the canvas: without it the tile's own corner would start the grid and the blocks
    /// would sit a few pixels off the ones the user is about to get — which for a
    /// redaction is precisely the thing being judged.
    static func pixelate(_ ci: CIImage, scale: CGFloat, anchor: CGPoint? = nil) -> CIImage {
        let s = max(1, scale)
        let e = ci.extent
        let corner = anchor ?? CGPoint(x: e.minX, y: e.maxY)
        return ci.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: s,
            kCIInputCenterKey: CIVector(x: corner.x, y: corner.y),
        ])
    }

    static func colorControls(_ ci: CIImage, brightness: CGFloat, contrast: CGFloat,
                              saturation: CGFloat) -> CIImage {
        ci.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: saturation,
        ])
    }

    /// Saturation zero rather than CIPhotoEffectMono: it is the same filter the
    /// adjustments panel uses, so grayscale is exactly "pull the saturation slider to 0"
    /// and nothing else changes.
    static func grayscale(_ ci: CIImage) -> CIImage {
        colorControls(ci, brightness: 0, contrast: 1, saturation: 0)
    }

    static func invert(_ ci: CIImage) -> CIImage {
        ci.applyingFilter("CIColorInvert", parameters: [:])
    }

    /// Lay `filtered` over `base` wherever `coverage` allows — both the same size, one
    /// coverage byte per pixel — and return the result.
    ///
    /// This is `PaintDocument.composite` with no document attached, and it exists so the
    /// filter dialogs can preview in the same ORDER the real thing works in: filter
    /// everything, then let the mask decide what is kept. Previewing a cut-out instead
    /// reintroduces the halo this file's opening comment is about, and the preview then
    /// shows a picture the Apply button will never produce.
    static func compose(_ filtered: CGImage, over base: CGImage, coverage: [UInt8]) -> CGImage? {
        guard filtered.width == base.width, filtered.height == base.height,
              coverage.count == base.width * base.height else { return filtered }
        let dstCtx = Bitmap.context(from: base)
        let srcCtx = Bitmap.context(from: filtered)
        guard let dst = dstCtx.pixels, let src = srcCtx.pixels else { return filtered }
        let dRow = dstCtx.bytesPerRow, sRow = srcCtx.bytesPerRow
        for y in 0..<dstCtx.height {
            let d = y * dRow, s = y * sRow, m = y * dstCtx.width
            for x in 0..<dstCtx.width {
                let cov = Int(coverage[m + x])
                if cov == 0 { continue }
                let o = x * 4
                if cov == 255 {
                    for k in 0..<4 { dst[d + o + k] = src[s + o + k] }
                } else {
                    let inv = 255 - cov
                    for k in 0..<4 {
                        dst[d + o + k] = UInt8((Int(dst[d + o + k]) * inv + Int(src[s + o + k]) * cov + 127) / 255)
                    }
                }
            }
        }
        return dstCtx.makeImage()
    }
}

extension PaintDocument {

    // MARK: - Masked composite

    /// Copy `replacement` over the bitmap, but only where the mask allows, as one
    /// undoable step. A nil or empty mask means the whole canvas.
    ///
    /// `origin` says where `replacement`'s top-left pixel belongs, in canvas pixels, so
    /// a caller that only computed the selection's bounding box can hand that box over
    /// as it is. Anything outside `replacement` is left alone whatever the mask says:
    /// a partial replacement is not licence to read past the end of it.
    ///
    /// The blend is `out = old·(255-m) + new·m`, which for the hard 0/255 masks the app
    /// makes today is an exact copy or an exact no-op — no rounding drift on either side
    /// of the boundary — and which will already do the right thing if the mask ever
    /// grows feathered edges.
    func composite(_ replacement: CGImage, at origin: CGPoint = .zero,
                   through mask: SelectionMask?, name: String) {
        let ox = Int(origin.x.rounded()), oy = Int(origin.y.rounded())
        // Where the replacement lands on the canvas, clamped to it. A stale mask or a
        // mis-placed region must not become an out-of-bounds write.
        let patch = CGRect(x: ox, y: oy, width: replacement.width, height: replacement.height)
            .intersection(bounds)
        guard patch.width >= 1, patch.height >= 1 else { return }
        // Read where they lie: `replacement` comes out of `CanvasFilter.render` already
        // in the canonical layout, so re-rasterising it to get at the bytes was a
        // full-size copy for nothing. See `PixelReader`.
        guard let source = PixelReader(replacement) else { return }

        // An empty mask means the whole canvas, so it is the same thing as no mask. Said
        // once, here, rather than asked again inside the loops below.
        let mask = (mask?.isEmpty == false) ? mask : nil

        // Which canvas pixels this composite could write at all: the patch, narrowed to
        // the mask's own box when there is one.
        var area = patch
        if let mask {
            area = patch.intersection(mask.bounds.integral)
            guard area.width >= 1, area.height >= 1 else { return }
        }

        // A filter cannot know whether it changed anything until it has rendered, and
        // every filter lands here, so this is the one place a no-op can be recognised
        // before it costs the user something. Adjustments opened and OK'd without moving
        // a slider is the case that bit: CIColorControls at its neutral values hands back
        // its own input, and registering undo first left a dead Undo Adjustments step on
        // a document that then claimed unsaved changes it did not have. Grayscale over an
        // already-grey picture is the same story.
        //
        // Comparing the source bytes rather than the blended result is exact wherever
        // coverage is 0 or 255 — the only masks this app makes — and errs towards
        // registering, never towards losing a real change.
        guard compositeWouldChange(source, area: area, ox: ox, oy: oy, mask: mask) else { return }
        registerUndo(name: name)
        // Fetched on THIS side of the registration, as it always was: the undo snapshot is
        // a CGImage taken off this very buffer, and the writes below have to be aimed at
        // whatever the context's bytes are once that snapshot exists.
        guard let dst = context.pixels else { return }
        let src = source.bytes
        let dstRow = context.bytesPerRow, srcRow = source.bytesPerRow

        // Nothing selected: whole rows of the patch, copied as rows.
        guard let mask else {
            let x0 = Int(patch.minX) * 4, span = Int(patch.width) * 4
            for y in Int(patch.minY)..<Int(patch.maxY) {
                let d = y * dstRow + x0, s = (y - oy) * srcRow + (Int(patch.minX) - ox) * 4
                for i in 0..<span { dst[d + i] = src[s + i] }
            }
            touch()
            return
        }

        // The mask decides which pixels of the patch are kept.
        let x0 = Int(area.minX), x1 = Int(area.maxX)
        let y0 = Int(area.minY), y1 = Int(area.maxY)
        for y in y0..<y1 {
            let d = y * dstRow, s = (y - oy) * srcRow
            for x in x0..<x1 {
                let m = Int(mask.coverage(x: x, y: y))
                if m == 0 { continue }
                let o = x * 4, so = (x - ox) * 4
                if m == 255 {
                    dst[d + o] = src[s + so]
                    dst[d + o + 1] = src[s + so + 1]
                    dst[d + o + 2] = src[s + so + 2]
                    dst[d + o + 3] = src[s + so + 3]
                } else {
                    let inv = 255 - m
                    for k in 0..<4 {
                        dst[d + o + k] = UInt8((Int(dst[d + o + k]) * inv + Int(src[s + so + k]) * m + 127) / 255)
                    }
                }
            }
        }
        touch()
    }

    /// Whether any pixel `composite` is allowed to write differs from what it would
    /// write. Walks exactly the pixels the write loops walk, so the answer cannot
    /// disagree with them, and stops at the first difference.
    private func compositeWouldChange(_ source: PixelReader, area: CGRect,
                                      ox: Int, oy: Int, mask: SelectionMask?) -> Bool {
        // No pixels to read means no answer, and "it might change" is the safe one.
        guard let dst = context.pixels else { return true }
        let src = source.bytes
        let dstRow = context.bytesPerRow, srcRow = source.bytesPerRow
        let x0 = Int(area.minX), x1 = Int(area.maxX)
        let y0 = Int(area.minY), y1 = Int(area.maxY)
        for y in y0..<y1 {
            let d = y * dstRow, s = (y - oy) * srcRow
            for x in x0..<x1 {
                if let mask, mask.coverage(x: x, y: y) == 0 { continue }
                let o = x * 4, so = (x - ox) * 4
                if dst[d + o] != src[s + so] || dst[d + o + 1] != src[s + so + 1]
                    || dst[d + o + 2] != src[s + so + 2] || dst[d + o + 3] != src[s + so + 3] {
                    return true
                }
            }
        }
        return false
    }

    /// Render a CoreImage transform and composite it back through the mask. See the note
    /// at the top of this file for why it is done in that order, and why only the
    /// selection's bounding box is rendered even though the graph spans the whole canvas.
    ///
    /// `grid` is for the one filter whose output depends on where the render starts: see
    /// `filterRegion`. Everything else leaves it at 1.
    func applyFilter(name: String, mask: SelectionMask?, grid: CGFloat = 1,
                     _ transform: (CIImage) -> CIImage) {
        let region = filterRegion(mask: mask, grid: grid)
        guard region.width >= 1, region.height >= 1 else { return }
        guard let filtered = CanvasFilter.render(image, region: region, transform) else { return }
        composite(filtered, at: region.origin, through: mask, name: name)
    }

    /// Which pixels a filter actually has to produce: the selection's bounding box, or
    /// the whole canvas when nothing is selected.
    ///
    /// The `grid` argument is CIPixellate's doing. Its blocks are anchored to the canvas
    /// corner through `inputCenter`, but measured against real pixels the renderer also
    /// lays them out from the corner of the rectangle it was ASKED for: request a box
    /// that is not a whole number of blocks and the applied grid shifts by the remainder.
    /// For a redaction that is the difference between covering a face and covering most
    /// of one, so the region is grown outward to whole blocks — at most `grid - 1` extra
    /// pixels a side. A fractional block size has no integral alignment at all, so that
    /// falls back to the whole canvas: slow beats wrong.
    private func filterRegion(mask: SelectionMask?, grid: CGFloat) -> CGRect {
        guard let mask, !mask.isEmpty else { return bounds }
        let r = mask.bounds.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return .zero }
        guard grid > 1 else { return r }
        guard grid == grid.rounded() else { return bounds }
        let minX = (r.minX / grid).rounded(.down) * grid
        let minY = (r.minY / grid).rounded(.down) * grid
        let maxX = (r.maxX / grid).rounded(.up) * grid
        let maxY = (r.maxY / grid).rounded(.up) * grid
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(bounds)
    }

    // MARK: - The menu items

    func blur(radius: CGFloat, mask: SelectionMask?) {
        guard radius > 0 else { return }
        applyFilter(name: "Blur", mask: mask) { CanvasFilter.blur($0, radius: radius) }
    }

    func pixelate(scale: CGFloat, mask: SelectionMask?) {
        guard scale > 1 else { return }
        applyFilter(name: "Pixelate", mask: mask, grid: scale) {
            CanvasFilter.pixelate($0, scale: scale)
        }
    }

    func adjustColors(brightness: CGFloat, contrast: CGFloat, saturation: CGFloat,
                      mask: SelectionMask?) {
        // The values the dialog opens on, which is where OK without touching a slider
        // lands. `composite` would notice afterwards that nothing changed and register no
        // undo, but only after CoreImage had rendered the whole region to prove it —
        // 160-210 ms on a 6000x4000 photograph for a picture that is already the answer.
        // Blur and Pixelate below guard their own identity the same way.
        guard brightness != 0 || contrast != 1 || saturation != 1 else { return }
        applyFilter(name: "Adjustments", mask: mask) {
            CanvasFilter.colorControls($0, brightness: brightness, contrast: contrast,
                                       saturation: saturation)
        }
    }

    func grayscale(mask: SelectionMask?) {
        applyFilter(name: "Grayscale", mask: mask) { CanvasFilter.grayscale($0) }
    }

    func invertColors(mask: SelectionMask?) {
        applyFilter(name: "Invert Colours", mask: mask) { CanvasFilter.invert($0) }
    }

    // MARK: - Trim to content

    /// The box outside which every pixel matches the top-left corner pixel.
    ///
    /// If that corner is transparent the test is on alpha alone, so a cut-out keeps its
    /// soft edges instead of being judged on whatever colour hides under zero alpha.
    /// `tolerance` is per channel, and defaults to a few levels so a JPEG's noisy "white"
    /// background still counts as one colour.
    func contentBounds(tolerance: Int = 8) -> CGRect? {
        guard let p = context.pixels else { return nil }
        let bpr = context.bytesPerRow
        let reference = context.sample(x: 0, y: 0)
        let transparentBackground = reference.a == 0

        @inline(__always) func isBackground(_ o: Int) -> Bool {
            if transparentBackground { return Int(p[o + 3]) <= tolerance }
            return abs(Int(p[o]) - Int(reference.r)) <= tolerance
                && abs(Int(p[o + 1]) - Int(reference.g)) <= tolerance
                && abs(Int(p[o + 2]) - Int(reference.b)) <= tolerance
                && abs(Int(p[o + 3]) - Int(reference.a)) <= tolerance
        }

        var minX = pixelWidth, minY = pixelHeight, maxX = -1, maxY = -1
        for y in 0..<pixelHeight {
            let row = y * bpr
            for x in 0..<pixelWidth where !isBackground(row + x * 4) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }   // the whole picture is background
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Crop away uniform or transparent edges. Returns false when there is nothing to
    /// trim, so the caller can say so rather than silently doing nothing.
    @discardableResult
    func trimToContent(tolerance: Int = 8) -> Bool {
        guard let r = contentBounds(tolerance: tolerance), r != bounds else { return false }
        crop(to: r, actionName: "Trim to Content")
        return true
    }
}

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// `Paintbox.app/Contents/MacOS/Paintbox --selftest`
///
/// Runs every image operation the app offers against a synthetic picture, checks the
/// resulting pixel dimensions, alpha and corner colours, then unwinds the whole thing
/// with undo and checks the bytes come back identical. No window is ever created.
enum SelfTest {

    // MARK: - Reporting

    private static var failures = 0
    private static var passes = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: String) {
        if condition {
            passes += 1
            print("PASS  \(name.padding(toLength: 34, withPad: " ", startingAt: 0))  \(detail)")
        } else {
            failures += 1
            print("FAIL  \(name.padding(toLength: 34, withPad: " ", startingAt: 0))  \(detail)")
        }
    }

    // MARK: - Fixtures

    private static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private static let green = NSColor(srgbRed: 0, green: 0.7, blue: 0, alpha: 1)
    private static let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private static let cyan = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)

    /// 240x160. Opaque blocks in three corners, the fourth corner left transparent,
    /// so orientation and alpha are both observable.
    private static func makeTestImage() -> CGImage {
        let ctx = Bitmap.makeContext(width: 240, height: 160)
        ctx.withTopLeftOrigin { c in
            c.setFillColor(red.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
            c.setFillColor(green.cgColor)
            c.fill(CGRect(x: 180, y: 0, width: 60, height: 40))
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 0, y: 120, width: 60, height: 40))
            // bottom-right quadrant stays transparent
        }
        return ctx.makeImage()!
    }

    /// A crude figure on a plain background, for the Vision subject lifter.
    private static func makeSubjectImage() -> CGImage {
        let ctx = Bitmap.makeContext(width: 512, height: 512)
        ctx.setFillColor(NSColor(srgbRed: 0.85, green: 0.88, blue: 0.92, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        ctx.withTopLeftOrigin { c in
            c.setFillColor(NSColor(srgbRed: 0.85, green: 0.35, blue: 0.2, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 176, y: 200, width: 160, height: 260))   // body
            c.setFillColor(NSColor(srgbRed: 0.95, green: 0.78, blue: 0.62, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 206, y: 90, width: 100, height: 120))    // head
            c.setFillColor(NSColor(srgbRed: 0.2, green: 0.15, blue: 0.12, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: 200, y: 78, width: 112, height: 70))     // hair
            c.fillEllipse(in: CGRect(x: 230, y: 130, width: 14, height: 16))     // eyes
            c.fillEllipse(in: CGRect(x: 268, y: 130, width: 14, height: 16))
        }
        return ctx.makeImage()!
    }

    private static func checksum(_ ctx: CGContext) -> UInt64 {
        guard let p = ctx.pixels else { return 0 }
        var h: UInt64 = 0xcbf29ce484222325
        let count = ctx.bytesPerRow * ctx.height
        for i in 0..<count {
            h = (h ^ UInt64(p[i])) &* 0x100000001b3
        }
        return h
    }

    private static func corners(_ doc: PaintDocument) -> (tl: RGBA, tr: RGBA, bl: RGBA, br: RGBA) {
        let w = doc.pixelWidth, h = doc.pixelHeight
        return (doc.context.sample(x: 5, y: 5),
                doc.context.sample(x: w - 6, y: 5),
                doc.context.sample(x: 5, y: h - 6),
                doc.context.sample(x: w - 6, y: h - 6))
    }

    private static func isRed(_ p: RGBA) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 && p.a == 255 }
    private static func isGreen(_ p: RGBA) -> Bool { p.g > 120 && p.r < 60 && p.b < 60 && p.a == 255 }
    private static func isBlue(_ p: RGBA) -> Bool { p.b > 200 && p.r < 60 && p.g < 60 && p.a == 255 }
    private static func isClear(_ p: RGBA) -> Bool { p.a == 0 }

    // MARK: - Runner

    static func run() -> Int {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("paintbox-selftest-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        print("Paintbox self-test")
        print("------------------")

        // ---- 1. Round trip a PNG with transparency -------------------------------
        let source = makeTestImage()
        let pngURL = tmp.appendingPathComponent("fixture.png")
        do {
            try Bitmap.write(source, to: pngURL, format: .png)
        } catch {
            check("write fixture PNG", false, "\(error)")
            return 1
        }
        guard let loaded = Bitmap.load(url: pngURL) else {
            check("open PNG", false, "could not read the file back")
            return 1
        }
        let doc = PaintDocument(image: loaded, url: pngURL)
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo

        let original = checksum(doc.context)
        var c = corners(doc)
        check("open PNG (alpha kept)",
              doc.pixelWidth == 240 && doc.pixelHeight == 160 && isRed(c.tl) && isGreen(c.tr)
                  && isBlue(c.bl) && isClear(c.br),
              "240x160 expected, got \(doc.pixelWidth)x\(doc.pixelHeight); corners TL \(c.tl) TR \(c.tr) BL \(c.bl) BR \(c.br)")

        // Each operation is its own undo group so the stack unwinds one step at a time.
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        // ---- 2. Flip horizontal ---------------------------------------------------
        step { doc.flip(horizontal: true) }
        c = corners(doc)
        check("flip horizontal",
              doc.pixelWidth == 240 && doc.pixelHeight == 160 && isGreen(c.tl) && isRed(c.tr)
                  && isClear(c.bl) && isBlue(c.br),
              "\(doc.pixelWidth)x\(doc.pixelHeight); TL \(c.tl) TR \(c.tr) BL \(c.bl) BR \(c.br)")

        // ---- 3. Flip vertical (back-to-back, so the picture is now 180 turned) ----
        step { doc.flip(horizontal: false) }
        c = corners(doc)
        check("flip vertical",
              doc.pixelWidth == 240 && doc.pixelHeight == 160 && isClear(c.tl) && isBlue(c.tr)
                  && isGreen(c.bl) && isRed(c.br),
              "\(doc.pixelWidth)x\(doc.pixelHeight); TL \(c.tl) TR \(c.tr) BL \(c.bl) BR \(c.br)")

        // Put it back the right way up for the rotation checks.
        step { doc.flip(horizontal: true) }
        step { doc.flip(horizontal: false) }
        c = corners(doc)
        check("flips are reversible", isRed(c.tl) && isClear(c.br),
              "back to the original orientation; TL \(c.tl) BR \(c.br)")

        // ---- 4. Rotate 90 clockwise ----------------------------------------------
        step { doc.rotateQuarter(degrees: 90) }
        c = corners(doc)
        check("rotate 90° clockwise",
              doc.pixelWidth == 160 && doc.pixelHeight == 240 && isRed(c.tr) && isBlue(c.tl)
                  && isGreen(c.br) && isClear(c.bl),
              "160x240 expected, got \(doc.pixelWidth)x\(doc.pixelHeight); TL \(c.tl) TR \(c.tr) BL \(c.bl) BR \(c.br)")

        // ---- 5. Rotate 90 anticlockwise (undoes the previous turn) ----------------
        step { doc.rotateQuarter(degrees: -90) }
        c = corners(doc)
        check("rotate 90° anticlockwise",
              doc.pixelWidth == 240 && doc.pixelHeight == 160 && isRed(c.tl) && isClear(c.br),
              "\(doc.pixelWidth)x\(doc.pixelHeight); TL \(c.tl) BR \(c.br)")

        // ---- 6. Rotate 180 --------------------------------------------------------
        step { doc.rotateQuarter(degrees: 180) }
        c = corners(doc)
        check("rotate 180°",
              doc.pixelWidth == 240 && doc.pixelHeight == 160 && isClear(c.tl) && isRed(c.br)
                  && isBlue(c.tr) && isGreen(c.bl),
              "\(doc.pixelWidth)x\(doc.pixelHeight); TL \(c.tl) TR \(c.tr) BL \(c.bl) BR \(c.br)")
        step { doc.rotateQuarter(degrees: 180) }

        // ---- 7. Rotate by an arbitrary angle -------------------------------------
        step { doc.rotateArbitrary(degrees: 30) }
        let grew = doc.pixelWidth > 240 && doc.pixelHeight > 160
        let cornerClear = isClear(doc.context.sample(x: 2, y: 2))
        check("rotate by angle (30°)", grew && cornerClear,
              "canvas grew to \(doc.pixelWidth)x\(doc.pixelHeight), new corner \(doc.context.sample(x: 2, y: 2))")
        step { doc.rotateArbitrary(degrees: -30) }
        step { doc.crop(to: CGRect(x: (CGFloat(doc.pixelWidth) - 240) / 2,
                                   y: (CGFloat(doc.pixelHeight) - 160) / 2,
                                   width: 240, height: 160), actionName: "Trim") }

        // ---- 8. Crop to selection -------------------------------------------------
        step { doc.crop(to: CGRect(x: 0, y: 0, width: 60, height: 40)) }
        let cropCorner = doc.context.sample(x: 30, y: 20)
        check("crop to selection",
              doc.pixelWidth == 60 && doc.pixelHeight == 40 && isRed(cropCorner),
              "60x40 expected, got \(doc.pixelWidth)x\(doc.pixelHeight); centre \(cropCorner)")
        undo.undo()   // step back out of the crop before the next check

        // ---- 9. Resize image ------------------------------------------------------
        step { doc.resizeImage(width: 120, height: 80) }
        let rBR = doc.context.sample(x: 115, y: 75)
        check("resize image (50%)",
              doc.pixelWidth == 120 && doc.pixelHeight == 80 && isClear(rBR),
              "120x80 expected, got \(doc.pixelWidth)x\(doc.pixelHeight); transparent corner still \(rBR)")

        // ---- 10. Canvas size ------------------------------------------------------
        step { doc.setCanvasSize(width: 200, height: 160, anchor: .center, fill: cyan) }
        let padLeft = doc.context.sample(x: 4, y: 80)
        let keptTL = doc.context.sample(x: 45, y: 45)
        check("canvas size (grow, centred, filled)",
              doc.pixelWidth == 200 && doc.pixelHeight == 160
                  && padLeft.b > 200 && padLeft.g > 200 && padLeft.a == 255 && isRed(keptTL),
              "200x160 expected, got \(doc.pixelWidth)x\(doc.pixelHeight); new area \(padLeft), picture still there \(keptTL)")

        step { doc.setCanvasSize(width: 90, height: 60, anchor: .topLeft, fill: cyan) }
        check("canvas size (shrink, top-left)",
              doc.pixelWidth == 90 && doc.pixelHeight == 60,
              "90x60 expected, got \(doc.pixelWidth)x\(doc.pixelHeight)")

        // ---- 11. Undo everything --------------------------------------------------
        var undone = 0
        while undo.canUndo {
            undo.undo()
            undone += 1
            if undone > 200 { break }
        }
        let restored = checksum(doc.context)
        c = corners(doc)
        check("undo restores exactly",
              restored == original && doc.pixelWidth == 240 && doc.pixelHeight == 160,
              "\(undone) steps undone; \(doc.pixelWidth)x\(doc.pixelHeight); checksum \(restored == original ? "identical" : "DIFFERENT")")

        // ---- 12. Redo -------------------------------------------------------------
        undo.redo()
        let afterRedo = corners(doc)
        check("redo replays the first step",
              isGreen(afterRedo.tl) && isRed(afterRedo.tr),
              "first step was flip horizontal; TL \(afterRedo.tl) TR \(afterRedo.tr)")
        undo.undo()

        // ---- 13. Remove background (Vision, on device) ----------------------------
        let subjectDoc = PaintDocument(image: makeSubjectImage())
        let subjectUndo = UndoManager()
        subjectUndo.groupsByEvent = false
        subjectDoc.undoManager = subjectUndo
        let subjectBefore = checksum(subjectDoc.context)
        let beforeCorner = subjectDoc.context.sample(x: 4, y: 4)
        do {
            subjectUndo.beginUndoGrouping()
            try subjectDoc.removeBackground()
            subjectUndo.endUndoGrouping()
            let after = subjectDoc.context.sample(x: 4, y: 4)
            let subject = subjectDoc.context.sample(x: 256, y: 300)
            check("remove background (Vision)",
                  subjectDoc.pixelWidth == 512 && subjectDoc.pixelHeight == 512
                      && after.a == 0 && subject.a > 200,
                  "512x512 kept; corner \(beforeCorner) -> \(after); subject \(subject)")
            subjectUndo.undo()
            check("undo remove background",
                  checksum(subjectDoc.context) == subjectBefore,
                  "checksum \(checksum(subjectDoc.context) == subjectBefore ? "identical" : "DIFFERENT")")
        } catch {
            check("remove background (Vision)", false, "\(error.localizedDescription)")
            check("undo remove background", false, "skipped, the operation did not run")
        }

        // ---- 14. Save PNG keeps alpha, save JPEG works ---------------------------
        let outPNG = tmp.appendingPathComponent("out.png")
        let outJPG = tmp.appendingPathComponent("out.jpg")
        undo.beginUndoGrouping()
        doc.rotateQuarter(degrees: 90)
        undo.endUndoGrouping()
        do {
            try doc.save(to: outPNG, quality: 0.8, matte: .white)
            let reread = Bitmap.load(url: outPNG)
            let rc = reread.map { Bitmap.context(from: $0) }
            let clearPixel = rc?.sample(x: 5, y: (rc?.height ?? 10) - 6) ?? RGBA(r: 1, g: 1, b: 1, a: 255)
            check("save PNG after rotate (alpha kept)",
                  reread?.width == 160 && reread?.height == 240 && clearPixel.a == 0,
                  "wrote \(reread?.width ?? 0)x\(reread?.height ?? 0); transparent corner reads \(clearPixel)")
        } catch {
            check("save PNG after rotate (alpha kept)", false, "\(error.localizedDescription)")
        }
        // Through `PaintDocument.save`, which is what ⌘S runs: the extension picks the
        // format and `Bitmap.write` does the matting. This used to call a second JPEG
        // writer on `Bitmap` that no menu item could reach, so the shipping path was
        // never tested and the dead one always passed.
        do {
            try doc.save(to: outJPG, quality: 0.8, matte: .white)
            let reread = Bitmap.load(url: outJPG)
            let rc = reread.map { Bitmap.context(from: $0) }
            let flat = rc?.sample(x: 5, y: (rc?.height ?? 10) - 6) ?? RGBA.clear
            check("save JPEG (flattened onto matte)",
                  reread?.width == 160 && reread?.height == 240 && flat.a == 255 && flat.r > 240,
                  "wrote \(reread?.width ?? 0)x\(reread?.height ?? 0); matte corner reads \(flat)")
            let writtenType = CGImageSourceCreateWithURL(outJPG as CFURL, nil)
                .flatMap { CGImageSourceGetType($0) as String? }
            check("⌘S on a .jpg picks the JPEG writer",
                  writtenType == SaveFormat.jpeg.typeIdentifier && doc.fileURL == outJPG,
                  "the file on disk is \(writtenType ?? "unreadable") and the document points at "
                      + "\(doc.fileURL?.lastPathComponent ?? "nothing")")
        } catch {
            check("save JPEG (flattened onto matte)", false, "\(error.localizedDescription)")
            check("⌘S on a .jpg picks the JPEG writer", false, "skipped, the save failed")
        }

        // A matted JPEG keeps every pixel the PNG had where the PNG was opaque: the
        // flattening must only touch what was transparent. The old dead writer was never
        // held to this because nothing compared the two files.
        if let jpegBack = Bitmap.load(url: outJPG), let pngBack = Bitmap.load(url: outPNG) {
            let jc = Bitmap.context(from: jpegBack), pc = Bitmap.context(from: pngBack)
            var worst = 0
            var opaqueSamples = 0
            for y in stride(from: 2, to: min(jc.height, pc.height) - 2, by: 7) {
                for x in stride(from: 2, to: min(jc.width, pc.width) - 2, by: 7) {
                    let p = pc.sample(x: x, y: y)
                    guard p.a == 255 else { continue }
                    opaqueSamples += 1
                    let j = jc.sample(x: x, y: y)
                    worst = max(worst, max(abs(Int(j.r) - Int(p.r)),
                                           max(abs(Int(j.g) - Int(p.g)), abs(Int(j.b) - Int(p.b)))))
                }
            }
            check("JPEG leaves the opaque pixels alone",
                  opaqueSamples > 20 && worst <= 24,
                  "\(opaqueSamples) opaque samples, worst channel difference \(worst)")
        } else {
            check("JPEG leaves the opaque pixels alone", false, "could not read one of the two files back")
        }

        // ---- 15. Drawing tools touch the pixels they should ----------------------
        let drawDoc = PaintDocument(width: 64, height: 64, fill: .white)
        let drawUndo = UndoManager()
        drawUndo.groupsByEvent = false
        drawDoc.undoManager = drawUndo
        let blank = checksum(drawDoc.context)

        drawUndo.beginUndoGrouping()
        drawDoc.registerUndo(name: "Pencil")
        Painter.pencil(in: drawDoc.context, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 63, y: 2), color: red)
        drawDoc.touch()
        drawUndo.endUndoGrouping()
        let onLine = drawDoc.context.sample(x: 30, y: 2)
        let offLine = drawDoc.context.sample(x: 30, y: 3)
        check("pencil is exactly one pixel",
              isRed(onLine) && offLine.r == 255 && offLine.g == 255,
              "row 2 \(onLine), row 3 \(offLine)")

        drawUndo.beginUndoGrouping()
        drawDoc.registerUndo(name: "Paint Bucket")
        Painter.floodFill(in: drawDoc.context, at: CGPoint(x: 30, y: 40), color: blue, tolerance: 16)
        drawDoc.touch()
        drawUndo.endUndoGrouping()
        let filled = drawDoc.context.sample(x: 30, y: 40)
        let aboveLine = drawDoc.context.sample(x: 30, y: 1)
        check("paint bucket respects a boundary",
              isBlue(filled) && aboveLine.r == 255 && aboveLine.b == 255,
              "below the pencil line \(filled), above it \(aboveLine)")

        drawUndo.beginUndoGrouping()
        drawDoc.registerUndo(name: "Eraser")
        Painter.erase(in: drawDoc.context, from: CGPoint(x: 32, y: 50), to: CGPoint(x: 32, y: 50),
                      size: 20, color: nil)
        drawDoc.touch()
        drawUndo.endUndoGrouping()
        let erased = drawDoc.context.sample(x: 32, y: 50)
        check("eraser erases to transparent", erased.a == 0, "centre of the eraser stroke \(erased)")

        drawUndo.beginUndoGrouping()
        drawDoc.registerUndo(name: "Text")
        Painter.text(in: drawDoc.context, string: "Hi", at: CGPoint(x: 4, y: 8),
                     font: NSFont.boldSystemFont(ofSize: 24), color: red)
        drawDoc.touch()
        drawUndo.endUndoGrouping()
        var textPixels = 0
        for y in 8..<40 { for x in 4..<40 where isRed(drawDoc.context.sample(x: x, y: y)) { textPixels += 1 } }
        check("text renders the right way up", textPixels > 20, "\(textPixels) red pixels in the text box")

        var drawUndone = 0
        while drawUndo.canUndo { drawUndo.undo(); drawUndone += 1; if drawUndone > 50 { break } }
        check("undo unwinds drawing tools",
              checksum(drawDoc.context) == blank,
              "\(drawUndone) steps undone; canvas \(checksum(drawDoc.context) == blank ? "blank again" : "NOT blank")")

        // ---- 16. A paste lands the right way up ----------------------------------
        // Paste goes through the floating item now — there is no other way in — so this
        // checks the un-moved, un-scaled case: the orientation maths, on its own.
        let stripe = Bitmap.makeContext(width: 20, height: 20)
        stripe.withTopLeftOrigin { c in
            c.setFillColor(red.cgColor); c.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            c.setFillColor(blue.cgColor); c.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        }
        let pasteDoc = PaintDocument(width: 40, height: 40, fill: .white)
        let pasteUndo = UndoManager()
        pasteUndo.groupsByEvent = false
        pasteDoc.undoManager = pasteUndo
        let pasteBlank = checksum(pasteDoc.context)
        pasteUndo.beginUndoGrouping()
        pasteDoc.commit(FloatingItem(image: stripe.makeImage()!, at: CGPoint(x: 10, y: 10)))
        pasteUndo.endUndoGrouping()
        let pTop = pasteDoc.context.sample(x: 20, y: 14)
        let pBottom = pasteDoc.context.sample(x: 20, y: 25)
        let pOutside = pasteDoc.context.sample(x: 2, y: 2)
        pasteUndo.undo()
        check("paste lands the right way up and undoes",
              isRed(pTop) && isBlue(pBottom) && pOutside.r == 255
                  && checksum(pasteDoc.context) == pasteBlank,
              "red half \(pTop), blue half \(pBottom), outside \(pOutside)")

        // ---- 17. Every interface symbol resolves on this system -------------------
        let missing = Symbols.all.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        check("all interface icons resolve", missing.isEmpty,
              missing.isEmpty ? "\(Symbols.all.count) SF Symbols found"
                              : "missing: \(missing.joined(separator: ", "))")

        // ---- 18. Everything the editing half added ------------------------------
        editingChecks(tmp: tmp)

        // ---- 19. The ways it used to fall over -----------------------------------
        robustnessChecks()

        // ---- 20. The ways it used to destroy work quietly ------------------------
        safetyChecks(tmp: tmp)

        // ---- 21. The ways it used to be quietly wrong ----------------------------
        polishChecks(tmp: tmp)

        // ---- 22. The ways it used to be slow enough to look broken ---------------
        costChecks()

        // ---- 23. The ways it used to promise one thing and do another -----------
        uxChecks(tmp: tmp)

        print("------------------")
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Helpers for the editing checks

    /// How many pixels OUTSIDE the mask changed. For every masked operation this must be
    /// exactly zero: the filters are composited through the mask, not recomputed
    /// everywhere and hoped to come out the same.
    private static func differencesOutside(_ mask: SelectionMask, before: CGImage,
                                           after: CGContext) -> Int {
        let b = Bitmap.context(from: before)
        var diff = 0
        for y in 0..<after.height {
            for x in 0..<after.width where !mask.contains(x: x, y: y) {
                if b.sample(x: x, y: y) != after.sample(x: x, y: y) { diff += 1 }
            }
        }
        return diff
    }

    private static func count(in doc: PaintDocument, where test: (RGBA) -> Bool) -> Int {
        var n = 0
        for y in 0..<doc.pixelHeight {
            for x in 0..<doc.pixelWidth where test(doc.context.sample(x: x, y: y)) { n += 1 }
        }
        return n
    }

    private static func luminance(_ p: RGBA) -> Double {
        0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
    }

    /// White canvas with an opaque red square at `rect`.
    private static func squareDoc(size: Int, rects: [CGRect]) -> PaintDocument {
        let doc = PaintDocument(width: size, height: size, fill: .white)
        doc.context.withTopLeftOrigin { c in
            c.setFillColor(red.cgColor)
            for r in rects { c.fill(r) }
        }
        doc.touch()
        return doc
    }

    private static func freshUndo(_ doc: PaintDocument) -> UndoManager {
        let u = UndoManager()
        u.groupsByEvent = false
        doc.undoManager = u
        return u
    }

    /// `groupsByEvent = false` means every operation has to be bracketed by hand: there
    /// is no run loop out here to close a group for us.
    private static func group(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    private static func thirdTrim(_ doc: PaintDocument, _ undo: UndoManager) -> Bool {
        var result = false
        group(undo) { result = doc.trimToContent() }
        return result
    }

    // MARK: - The editing half

    private static func editingChecks(tmp: URL) {

        // ---- The selection is a mask -----------------------------------------
        let rectMask = SelectionMask(width: 240, height: 160,
                                     rect: CGRect(x: 20, y: 30, width: 60, height: 40))
        check("selection mask from a rectangle",
              rectMask.setCount == 2400 && rectMask.isRectangular
                  && rectMask.bounds == CGRect(x: 20, y: 30, width: 60, height: 40)
                  && rectMask.contains(x: 21, y: 31) && !rectMask.contains(x: 19, y: 31),
              "\(rectMask.setCount) px, box \(rectMask.bounds), rectangular \(rectMask.isRectangular)")

        // A rectangle traces as four lines; an L shape cannot possibly be rectangular.
        let lMask = SelectionMask(width: 60, height: 60)
        for y in 0..<40 { for x in 0..<20 { lMask.mark(x: x, y: y) } }
        for y in 20..<40 { for x in 20..<50 { lMask.mark(x: x, y: y) } }
        lMask.recompute()
        let lBox = lMask.boundaryPath()?.boundingBox ?? .null
        check("selection mask traces an outline",
              !lMask.isRectangular && lMask.setCount == 800 + 600
                  && lBox == CGRect(x: 0, y: 0, width: 50, height: 40)
                  && rectMask.boundaryPath()?.boundingBox == rectMask.bounds,
              "L shape \(lMask.setCount) px, outline box \(lBox), rectangular \(lMask.isRectangular)")

        // ---- Blur must not suck transparency in from outside the selection ----
        // The classic bug: crop the selection out, blur the crop, paste it back, and the
        // Gaussian mixes in the nothing beyond the crop. Here the selection sits WHOLLY
        // inside a solid red block, so if a single pixel comes back less than opaque the
        // filter sampled something it should not have.
        // The picture is opaque from edge to edge — red with a blue square in it — so
        // every pixel inside the selection MUST come back fully opaque. A crop-blur-paste
        // implementation fails this on the selection's own border, and a blur that forgot
        // to clamp at the canvas edge fails it near the canvas border.
        let blurDoc = PaintDocument(width: 120, height: 120, fill: red)
        blurDoc.context.withTopLeftOrigin { c in
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 40, y: 40, width: 40, height: 40))
        }
        blurDoc.touch()
        let blurUndo = freshUndo(blurDoc)
        let inner = SelectionMask(width: 120, height: 120,
                                  rect: CGRect(x: 20, y: 20, width: 80, height: 80))
        let boundaryBefore = blurDoc.context.sample(x: 42, y: 42)
        group(blurUndo) { blurDoc.blur(radius: 10, mask: inner) }
        var bled = 0
        for y in 20..<100 { for x in 20..<100 where blurDoc.context.sample(x: x, y: y).a != 255 {
            bled += 1
        } }
        let boundaryAfter = blurDoc.context.sample(x: 42, y: 42)
        check("blur does not bleed in the outside",
              bled == 0 && boundaryAfter != boundaryBefore,
              "\(bled) of 6400 pixels inside the selection came back less than opaque; "
                  + "the red/blue boundary did blur, \(boundaryBefore) -> \(boundaryAfter)")

        // Now a selection that straddles the red/transparent edge at x = 60.
        let blurDoc2 = PaintDocument(image: makeTestImage())
        let blurUndo2 = freshUndo(blurDoc2)
        let edgeMask = SelectionMask(width: 240, height: 160,
                                     rect: CGRect(x: 40, y: 5, width: 40, height: 30))
        let beforeBlur = blurDoc2.image
        let beforeEdge = blurDoc2.context.sample(x: 58, y: 20)
        group(blurUndo2) { blurDoc2.blur(radius: 8, mask: edgeMask) }
        let afterEdge = blurDoc2.context.sample(x: 58, y: 20)
        let outsideDiff = differencesOutside(edgeMask, before: beforeBlur, after: blurDoc2.context)
        check("blur changes only the selection",
              afterEdge != beforeEdge && afterEdge.a > 0 && afterEdge.a < 255 && outsideDiff == 0,
              "edge pixel \(beforeEdge) -> \(afterEdge) (alpha blurred, not lost); "
                  + "\(outsideDiff) pixels changed outside the selection")

        // ---- Pixelate ---------------------------------------------------------
        let pixDoc = PaintDocument(image: makeTestImage())
        let pixUndo = freshUndo(pixDoc)
        let pixBefore = checksum(pixDoc.context)
        group(pixUndo) { pixDoc.pixelate(scale: 20, mask: nil) }
        var uniform = true
        let blockColor = pixDoc.context.sample(x: 20, y: 20)
        for y in 20..<40 { for x in 20..<40 where pixDoc.context.sample(x: x, y: y) != blockColor {
            uniform = false
        } }
        // Every colour change along a row must land on a 20 px grid line, or the blocks
        // are not aligned to the picture and a redaction box would sit half a block off.
        var edges: [Int] = []
        for x in 1..<240 where pixDoc.context.sample(x: x, y: 30) != pixDoc.context.sample(x: x - 1, y: 30) {
            edges.append(x)
        }
        let aligned = !edges.isEmpty && edges.allSatisfy { $0 % 20 == 0 }
        check("pixelate makes uniform blocks",
              uniform && aligned,
              "the 20x20 block at (20,20) is \(uniform ? "one colour" : "NOT uniform") \(blockColor); "
                  + "colour changes along row 30 at x = \(edges.map(String.init).joined(separator: ", ")) "
                  + "\(aligned ? "- all on the 20 px grid" : "- OFF the grid")")
        pixUndo.undo()
        check("undo pixelate", checksum(pixDoc.context) == pixBefore,
              "checksum \(checksum(pixDoc.context) == pixBefore ? "identical" : "DIFFERENT")")

        // ---- Floating paste: move, scale, commit, undo ------------------------
        let stripe = Bitmap.makeContext(width: 20, height: 20)
        stripe.withTopLeftOrigin { c in
            c.setFillColor(red.cgColor); c.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            c.setFillColor(blue.cgColor); c.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        }
        let floatDoc = PaintDocument(width: 60, height: 60, fill: .white)
        let floatUndo = freshUndo(floatDoc)
        let floatBlank = checksum(floatDoc.context)

        let item = FloatingItem(image: stripe.makeImage()!, at: CGPoint(x: 5, y: 5))
        item.move(by: CGPoint(x: 10, y: 15))                       // -> origin 15,20
        item.resize(to: CGPoint(x: 55, y: 60), anchor: item.anchor(for: .bottomRight), keepAspect: true)
        let placed = item.frame
        group(floatUndo) { floatDoc.commit(item) }

        // 20x20 scaled to 40x40 at (15,20): the red half is rows 20..39, the blue 40..59.
        let fRed = floatDoc.context.sample(x: 35, y: 28)
        let fBlue = floatDoc.context.sample(x: 35, y: 52)
        let fOutside = floatDoc.context.sample(x: 5, y: 5)
        let fBeyond = floatDoc.context.sample(x: 58, y: 30)
        check("floating paste moves and scales",
              placed == CGRect(x: 15, y: 20, width: 40, height: 40)
                  && isRed(fRed) && isBlue(fBlue) && fOutside.r == 255 && fOutside.g == 255
                  && fBeyond.r == 255,
              "frame \(placed); red half \(fRed), blue half \(fBlue), outside \(fOutside)")

        floatUndo.undo()
        check("undo a floating paste in one step",
              !floatUndo.canUndo && checksum(floatDoc.context) == floatBlank,
              "one undo left the canvas \(checksum(floatDoc.context) == floatBlank ? "blank again" : "DIRTY")"
                  + "; \(floatUndo.canUndo ? "more steps remain" : "stack empty")")

        // Shift-scaling keeps the shape: a 20x20 stamp dragged to a 50x10 box stays square.
        let squareItem = FloatingItem(image: stripe.makeImage()!, at: CGPoint(x: 0, y: 0))
        squareItem.resize(to: CGPoint(x: 50, y: 10), anchor: squareItem.anchor(for: .bottomRight),
                          keepAspect: true)
        check("floating paste keeps its aspect with Shift",
              squareItem.frame.width == squareItem.frame.height && squareItem.frame.width == 50,
              "20x20 dragged to a 50x10 box became \(Int(squareItem.frame.width))x\(Int(squareItem.frame.height))")

        // ---- Magic wand, then Delete -----------------------------------------
        let wandDoc = squareDoc(size: 64, rects: [CGRect(x: 16, y: 16, width: 20, height: 20),
                                                  CGRect(x: 44, y: 44, width: 10, height: 10)])
        let wandUndo = freshUndo(wandDoc)
        let wandBlank = checksum(wandDoc.context)

        let blob = MagicWand.select(in: wandDoc.context, at: CGPoint(x: 20, y: 20),
                                    tolerance: 16, contiguous: true)
        let global = MagicWand.select(in: wandDoc.context, at: CGPoint(x: 20, y: 20),
                                      tolerance: 16, contiguous: false)
        let surround = MagicWand.select(in: wandDoc.context, at: CGPoint(x: 1, y: 1),
                                        tolerance: 16, contiguous: true)
        check("magic wand selects one colour",
              blob?.setCount == 400 && blob?.isRectangular == true
                  && blob?.bounds == CGRect(x: 16, y: 16, width: 20, height: 20)
                  && global?.setCount == 500
                  && surround?.setCount == 64 * 64 - 500 && surround?.isRectangular == false,
              "contiguous \(blob?.setCount ?? -1) px, global \(global?.setCount ?? -1) px "
                  + "(two squares), the white around them \(surround?.setCount ?? -1) px")

        group(wandUndo) { wandDoc.clear(mask: blob, to: nil) }
        let transparentCount = count(in: wandDoc) { $0.a == 0 }
        let stillRed = count(in: wandDoc) { isRed($0) }
        check("Delete makes exactly the wand selection transparent",
              transparentCount == 400 && stillRed == 100
                  && wandDoc.context.sample(x: 20, y: 20).a == 0
                  && isRed(wandDoc.context.sample(x: 48, y: 48)),
              "\(transparentCount) transparent pixels (400 expected), \(stillRed) red left "
                  + "(the other square, 100 expected)")
        wandUndo.undo()
        check("undo a wand delete", checksum(wandDoc.context) == wandBlank,
              "checksum \(checksum(wandDoc.context) == wandBlank ? "identical" : "DIFFERENT")")

        // An irregular selection copies as a cut-out, not as its bounding box.
        if let surround {
            let cut = wandDoc.copy(mask: surround)
            let cutCtx = cut.map { Bitmap.context(from: $0) }
            let insideSquare = cutCtx?.sample(x: 20, y: 20) ?? RGBA(r: 9, g: 9, b: 9, a: 9)
            let outsideSquare = cutCtx?.sample(x: 1, y: 1) ?? RGBA.clear
            check("copy through an irregular mask",
                  cut?.width == 64 && cut?.height == 64 && insideSquare.a == 0
                      && outsideSquare.a == 255,
                  "the hole where the red square was reads \(insideSquare), "
                      + "the kept area reads \(outsideSquare)")
        }

        // ---- Adjustments ------------------------------------------------------
        let adjDoc = PaintDocument(image: makeTestImage())
        let adjUndo = freshUndo(adjDoc)
        let adjBefore = adjDoc.context.sample(x: 5, y: 20)   // inside the red block
        let adjClearBefore = adjDoc.context.sample(x: 200, y: 120)
        group(adjUndo) { adjDoc.adjustColors(brightness: 0.3, contrast: 1, saturation: 1, mask: nil) }
        let brighter = adjDoc.context.sample(x: 5, y: 20)
        let stillClear = adjDoc.context.sample(x: 200, y: 120)
        check("adjustments: brightness raises luminance",
              luminance(brighter) > luminance(adjBefore) + 5 && stillClear.a == 0
                  && adjClearBefore.a == 0,
              "\(adjBefore) -> \(brighter), luminance "
                  + "\(Int(luminance(adjBefore))) -> \(Int(luminance(brighter))); "
                  + "transparent area still \(stillClear)")
        adjUndo.undo()

        group(adjUndo) { adjDoc.adjustColors(brightness: -0.3, contrast: 1, saturation: 1, mask: nil) }
        let darker = adjDoc.context.sample(x: 5, y: 20)
        adjUndo.undo()
        group(adjUndo) { adjDoc.adjustColors(brightness: 0, contrast: 1, saturation: 0, mask: nil) }
        let desaturated = adjDoc.context.sample(x: 5, y: 20)
        check("adjustments: darker, and saturation 0 is grey",
              luminance(darker) < luminance(adjBefore) - 5
                  && abs(Int(desaturated.r) - Int(desaturated.g)) <= 1
                  && abs(Int(desaturated.g) - Int(desaturated.b)) <= 1,
              "brightness -0.3 gives \(darker); saturation 0 gives \(desaturated)")
        adjUndo.undo()

        // Confined to the selection, with the rest of the picture untouched.
        let halfMask = SelectionMask(width: 240, height: 160,
                                     rect: CGRect(x: 0, y: 0, width: 120, height: 160))
        let adjImageBefore = adjDoc.image
        group(adjUndo) { adjDoc.adjustColors(brightness: 0, contrast: 1, saturation: 0, mask: halfMask) }
        let leftGrey = adjDoc.context.sample(x: 5, y: 5)
        let rightUntouched = differencesOutside(halfMask, before: adjImageBefore, after: adjDoc.context)
        check("adjustments honour the selection",
              abs(Int(leftGrey.r) - Int(leftGrey.g)) <= 1 && rightUntouched == 0,
              "left half went grey \(leftGrey); \(rightUntouched) pixels changed in the right half")

        // ---- Grayscale and invert --------------------------------------------
        let fxDoc = PaintDocument(image: makeTestImage())
        let fxUndo = freshUndo(fxDoc)
        group(fxUndo) { fxDoc.grayscale(mask: nil) }
        let grey = fxDoc.context.sample(x: 5, y: 5)
        let greyClear = fxDoc.context.sample(x: 200, y: 120)
        fxUndo.undo()
        group(fxUndo) { fxDoc.invertColors(mask: nil) }
        let inverted = fxDoc.context.sample(x: 5, y: 5)          // red -> cyan
        let invertedClear = fxDoc.context.sample(x: 200, y: 120)
        check("grayscale and invert keep alpha",
              abs(Int(grey.r) - Int(grey.g)) <= 1 && grey.a == 255 && greyClear.a == 0
                  && inverted.r < 60 && inverted.g > 195 && inverted.b > 195
                  && inverted.a == 255 && invertedClear.a == 0,
              "grayscale red -> \(grey); invert red -> \(inverted); "
                  + "transparent corner \(greyClear) / \(invertedClear)")

        // ---- Trim to content ---------------------------------------------------
        let trimDoc = squareDoc(size: 100, rects: [CGRect(x: 20, y: 30, width: 30, height: 20)])
        let trimUndo = freshUndo(trimDoc)
        var trimmed = false
        group(trimUndo) { trimmed = trimDoc.trimToContent() }
        check("trim to content (flat border)",
              trimmed && trimDoc.pixelWidth == 30 && trimDoc.pixelHeight == 20
                  && isRed(trimDoc.context.sample(x: 15, y: 10)),
              "100x100 trimmed to \(trimDoc.pixelWidth)x\(trimDoc.pixelHeight), "
                  + "centre \(trimDoc.context.sample(x: 15, y: 10))")
        trimUndo.undo()
        let widthAfterUndo = trimDoc.pixelWidth
        var trimAgain = false
        group(trimUndo) { trimAgain = trimDoc.trimToContent() }
        let widthAfterRetrim = trimDoc.pixelWidth
        let thirdDidNothing = !thirdTrim(trimDoc, trimUndo)
        check("trim to content undoes, and a trimmed picture cannot be trimmed twice",
              widthAfterUndo == 100 && trimAgain && widthAfterRetrim == 30 && thirdDidNothing,
              "after undo it was \(widthAfterUndo) wide again, re-trimmed to \(widthAfterRetrim), "
                  + "and a third trim \(thirdDidNothing ? "did nothing" : "TRIMMED AGAIN")")

        // Transparent edges count as blank too - the step after a cut-out.
        let cutDoc = PaintDocument(width: 80, height: 80, fill: nil)
        cutDoc.context.withTopLeftOrigin { c in
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 25, y: 10, width: 15, height: 40))
        }
        cutDoc.touch()
        let cutUndo = freshUndo(cutDoc)
        var cutTrimmed = false
        group(cutUndo) { cutTrimmed = cutDoc.trimToContent() }
        check("trim to content (transparent border)",
              cutTrimmed && cutDoc.pixelWidth == 15 && cutDoc.pixelHeight == 40,
              "80x80 with a transparent border trimmed to \(cutDoc.pixelWidth)x\(cutDoc.pixelHeight)")

        // ---- Arrow tool --------------------------------------------------------
        let arrowDoc = PaintDocument(width: 64, height: 64, fill: .white)
        let arrowUndo = freshUndo(arrowDoc)
        group(arrowUndo) {
            arrowDoc.registerUndo(name: "Arrow")
            Painter.arrow(in: arrowDoc.context, from: CGPoint(x: 6, y: 32), to: CGPoint(x: 58, y: 32),
                          width: 3, color: red)
            arrowDoc.touch()
        }
        let shaft = arrowDoc.context.sample(x: 20, y: 32)
        let shaftThickness = (20..<45).filter { isRed(arrowDoc.context.sample(x: 15, y: $0)) }.count
        let headThickness = (20..<45).filter { isRed(arrowDoc.context.sample(x: 46, y: $0)) }.count
        check("arrow is a line with a head on it",
              isRed(shaft) && shaftThickness >= 2 && headThickness > shaftThickness + 2,
              "shaft \(shaft), \(shaftThickness) px thick at x=15 against "
                  + "\(headThickness) px at the head, x=46")

        // ---- Every save format round-trips ------------------------------------
        let formats = SaveFormat.available
        check("every advertised save format has a writer",
              formats.count == SaveFormat.allCases.count,
              "\(formats.count) of \(SaveFormat.allCases.count): "
                  + formats.map { $0.rawValue }.joined(separator: ", ")
                  + "  (WebP is absent on purpose: macOS reads it but cannot write it)")

        // The README says macOS reads WebP but cannot write it, and that is why WebP is
        // missing from the save panel. That is a claim about this machine, so check it.
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let webp = "org.webmproject.webp"
        check("WebP reads but cannot be written",
              readable.contains(webp) && !writable.contains(webp),
              "reader \(readable.contains(webp) ? "present" : "MISSING"), "
                  + "writer \(writable.contains(webp) ? "PRESENT - the README is now wrong" : "absent")")

        let fixtureForFormats = makeTestImage()
        roundTripFormats(formats, fixture: fixtureForFormats, tmp: tmp)
    }

    // MARK: - The ways it used to fall over
    //
    // Every check below stands for a way the app could be made to hang, eat the machine
    // or die outright. They are all "what happens when the number is absurd, the picture
    // is huge, or the window has gone" — none of which a picture-drawing test can reach.

    private static func robustnessChecks() {

        // ---- A typed size can ask for terabytes, so the size is checked -------
        //
        // The Percent field defaults to "100". One extra zero on a 1024x768 canvas asks
        // for 1,024,000 x 768,000 — 3 TB — and CoreGraphics does not refuse it: the
        // backing store is mapped lazily, so the allocation "succeeds" and the machine
        // only dies later, inside ctx.draw, with the unsaved picture still in it.
        let current = CGSize(width: 1024, height: 768)
        let absurd = Dialogs.requestedSize(mode: .percent, width: "100000", height: "100000",
                                           current: current)
        let modest = Dialogs.requestedSize(mode: .percent, width: "200", height: "200",
                                           current: current)
        let pixels = Dialogs.requestedSize(mode: .pixels, width: "640", height: "480",
                                           current: current)
        let overflow = Dialogs.requestedSize(mode: .percent, width: "1e400", height: "1e400",
                                             current: current)
        check("resize percent is measured, not trusted",
              absurd == CGSize(width: 1_024_000, height: 768_000)
                  && CanvasLimits.rejection(for: absurd) != nil
                  && modest == CGSize(width: 2048, height: 1536)
                  && CanvasLimits.rejection(for: modest) == nil
                  && pixels == CGSize(width: 640, height: 480)
                  && !overflow.width.isFinite && CanvasLimits.rejection(for: overflow) != nil,
              "100000% of 1024x768 asks for \(Int(absurd.width))x\(Int(absurd.height)) and is "
                  + "refused; 200% gives \(Int(modest.width))x\(Int(modest.height)) and is allowed; "
                  + "\"1e400\" overflows to infinity and is refused")

        // Nothing that reaches an allocation may trap on the way, however silly the
        // number: pixelSize is the only route from a typed CGSize to Ints.
        let fromInfinity = CanvasLimits.pixelSize(overflow)
        let fromNaN = CanvasLimits.pixelSize(CGSize(width: CGFloat.nan, height: CGFloat.nan))
        let squashed = CanvasLimits.clamp(width: 20000, height: 20000)
        check("no size becomes an Int trap",
              fromInfinity.width <= CanvasLimits.maxSide && fromNaN.width == 1
                  && squashed.width * squashed.height <= CanvasLimits.maxPixels
                  && squashed.width == squashed.height,
              "infinity clamps to \(fromInfinity.width)x\(fromInfinity.height), NaN to "
                  + "\(fromNaN.width)x\(fromNaN.height), and 20000x20000 comes down to "
                  + "\(squashed.width)x\(squashed.height) (both sides together, so the shape "
                  + "survives)")

        // And the model has its own guard, because it is the last thing before the
        // memory: real pixels, really resized, really clamped.
        let bigDoc = squareDoc(size: 40, rects: [CGRect(x: 0, y: 0, width: 20, height: 40)])
        let bigUndo = freshUndo(bigDoc)
        group(bigUndo) { bigDoc.resizeImage(width: 1_000_000, height: 3) }
        check("the model clamps a size the dialog never saw",
              bigDoc.pixelWidth == CanvasLimits.maxSide && bigDoc.pixelHeight == 3
                  && isRed(bigDoc.context.sample(x: 100, y: 1)),
              "asked for 1000000x3, got \(bigDoc.pixelWidth)x\(bigDoc.pixelHeight), and the "
                  + "left half is still red \(bigDoc.context.sample(x: 100, y: 1))")
        bigUndo.undo()

        // ---- "inf" in the rotate box used to kill the app --------------------
        //
        // Double("inf"), Double("nan") and Double("1e400") all parse. A non-finite angle
        // makes a NaN bounding box and Int(NaN) is a trap, not an error: instant death,
        // no dialog, unsaved picture gone.
        let angles: [(String, CGFloat?)] = [("inf", nil), ("-inf", nil), ("nan", nil),
                                            ("1e400", nil), ("fifteen", nil),
                                            ("15", 15), ("390", 30), (" -45 ", -45)]
        let anglesOK = angles.allSatisfy { Dialogs.parseAngle($0.0) == $0.1 }
        let rotDoc = PaintDocument(image: makeTestImage())
        let rotUndo = freshUndo(rotDoc)
        let rotBefore = checksum(rotDoc.context)
        group(rotUndo) { rotDoc.rotateArbitrary(degrees: .infinity) }
        group(rotUndo) { rotDoc.rotateArbitrary(degrees: .nan) }
        group(rotUndo) { rotDoc.rotateArbitrary(degrees: -.infinity) }
        check("a non-finite angle is refused twice over",
              anglesOK && rotDoc.pixelWidth == 240 && rotDoc.pixelHeight == 160
                  && checksum(rotDoc.context) == rotBefore,
              "the dialog reads \(angles.map { "\($0.0)→\($0.1.map { "\(Int($0))" } ?? "nil")" }.joined(separator: ", ")); "
                  + "rotating by ±infinity and NaN left the picture "
                  + "\(rotDoc.pixelWidth)x\(rotDoc.pixelHeight) and "
                  + "\(checksum(rotDoc.context) == rotBefore ? "byte for byte identical" : "CHANGED")")

        // ---- Undo has a ceiling, and it is measured in bytes ------------------
        //
        // levelsOfUndo was never set, which means unlimited, and every step here is a
        // whole-canvas snapshot: ten blurs on a 6000x4000 photograph held two gigabytes.
        let smallLevels = UndoBudget.levels(width: 1024, height: 768)
        let photoLevels = UndoBudget.levels(width: 6000, height: 4000)
        let photoBytes = photoLevels * 6000 * 4000 * 4
        check("undo levels follow the size of the canvas",
              smallLevels == UndoBudget.most && photoLevels == UndoBudget.fewest
                  && photoLevels < smallLevels
                  && photoBytes < UndoBudget.bytes + 6000 * 4000 * 4,
              "1024x768 gets \(smallLevels) steps (3 MB each), 6000x4000 gets \(photoLevels) "
                  + "(91 MB each, \(photoBytes / (1024 * 1024)) MB in all)")

        // The ceiling really does throw the oldest step away, and what is left still
        // restores the right pixels rather than some torn mixture.
        let capDoc = PaintDocument(width: 32, height: 32, fill: .white)
        let capUndo = freshUndo(capDoc)
        capUndo.levelsOfUndo = 3
        let shades: [NSColor] = [red, green, blue, cyan,
                                 NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)]
        for shade in shades {
            group(capUndo) {
                capDoc.edit("Fill") { c in
                    c.setFillColor(shade.cgColor)
                    c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                }
            }
        }
        var steps = 0
        while capUndo.canUndo { capUndo.undo(); steps += 1; if steps > 20 { break } }
        let afterCap = capDoc.context.sample(x: 16, y: 16)
        check("the undo ceiling drops the oldest step",
              steps == 3 && isGreen(afterCap),
              "five edits with a ceiling of three left \(steps) undo steps, and unwinding "
                  + "them all landed on the second colour \(afterCap) (green expected, not white)")

        // ---- The colour panel outlives the window it was opened from ----------
        //
        // -[NSColorPanel setTarget:] neither retains its target nor zeroes the pointer,
        // and a window controller dies with its window. Open the panel from window A,
        // close A, drag a slider: the message went to freed memory. The target is now
        // the app object, which lives as long as the process, and the window it edits
        // for is held weakly.
        var client: StubPanelClient? = StubPanelClient()
        PaintboxApp.shared.routeColorPanel(to: client!, foreground: false)
        PaintboxApp.shared.deliver(color: red)
        let gotBackground = client?.background
        PaintboxApp.shared.routeColorPanel(to: client!, foreground: true)
        PaintboxApp.shared.deliver(color: blue)
        let gotForeground = client?.foreground
        let liveBefore = PaintboxApp.shared.colorPanelHasLiveClient
        client = nil                                   // the window closes here
        let liveAfter = PaintboxApp.shared.colorPanelHasLiveClient
        PaintboxApp.shared.deliver(color: green)       // the drag that used to crash
        check("a closed window cannot be messaged by the colour panel",
              gotBackground == red && gotForeground == blue && liveBefore && !liveAfter,
              "the panel set the background \(gotBackground?.description ?? "nothing") then the "
                  + "foreground \(gotForeground?.description ?? "nothing"); after the window went "
                  + "the reference read \(liveAfter ? "STILL LIVE" : "nil") and one more colour "
                  + "change did nothing at all")

        antsChecks()
    }

    /// Only the app delegate's weak reference is under test, so the stand-in is as small
    /// as the protocol: building a real window controller here would drag a window, a
    /// toolbar and a timer into a test that is about a pointer.
    private final class StubPanelClient: PanelClient {
        var foreground: NSColor?
        var background: NSColor?
        func panelPicked(color: NSColor, foreground: Bool) {
            if foreground { self.foreground = color } else { self.background = color }
        }
        func panelPicked(font manager: NSFontManager) {}
    }


    private static func segmentCount(_ path: CGPath?) -> Int {
        guard let path else { return -1 }
        var n = 0
        path.applyWithBlock { element in
            if element.pointee.type == .addLineToPoint { n += 1 }
            if element.pointee.type == .addQuadCurveToPoint { n += 1 }
            if element.pointee.type == .addCurveToPoint { n += 1 }
        }
        return n
    }

    /// The marching ants, which is where a magic-wand selection used to freeze the app.
    private static func antsChecks() {

        // The real case, in miniature: a grainy photograph, wanded. The outline of such a
        // selection is thousands of short runs — a 300x300 patch of grain stands in for
        // the three and a half million segments a 12-megapixel sky produces, which is
        // half a gigabyte of CGPath restroked eight times a second.
        //
        // A chequerboard will not do as a fixture, by the way: every edge in it is
        // collinear with the next, so it merges into one segment a row and traces as
        // cheaply as a rectangle. Grain is what is expensive.
        let noisy = Bitmap.makeContext(width: 300, height: 300)
        var seed: UInt64 = 0x9e3779b97f4a7c15
        noisy.withTopLeftOrigin { c in
            for y in 0..<300 {
                for x in 0..<300 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = CGFloat((seed >> 33) % 64) / 255
                    c.setFillColor(NSColor(srgbRed: 0.72 + n, green: 0.75 + n, blue: 0.85 + n,
                                           alpha: 1).cgColor)
                    c.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        guard let grain = MagicWand.select(in: noisy, at: CGPoint(x: 150, y: 150),
                                           tolerance: 18, contiguous: false) else {
            check("an intricate outline gives up instead of hanging", false,
                  "the wand selected nothing on the grain fixture")
            return
        }
        let full = grain.boundaryPath()
        let budgeted = grain.boundaryPath(in: grain.bounds, maxSegments: 5_000)
        check("an intricate outline gives up instead of hanging",
              !grain.isRectangular && segmentCount(full) > 20_000 && budgeted == nil,
              "a wanded grain mask of \(grain.setCount) px traces \(segmentCount(full)) segments "
                  + "unbudgeted; with a budget of 5000 it returns "
                  + "\(budgeted == nil ? "nil, so the canvas tints it instead" : "A PATH ANYWAY")")

        // Tracing only what is on screen is the other half: the ants never need the
        // part of the mask that is scrolled away.
        let window = CGRect(x: 0, y: 0, width: 20, height: 20)
        let clipped = grain.boundaryPath(in: window, maxSegments: 40_000)
        let clipBox = clipped?.boundingBox ?? .null
        check("the ants trace only what is on screen",
              clipped != nil && segmentCount(clipped) > 0
                  && segmentCount(clipped) < segmentCount(full) / 20
                  && window.insetBy(dx: -2, dy: -2).contains(clipBox),
              "a 20x20 window of the same mask is \(segmentCount(clipped)) segments against "
                  + "\(segmentCount(full)) for the whole thing, all inside \(clipBox)")

        // A rectangle stays on the cheap path however big the canvas is.
        let rect = SelectionMask(width: 4000, height: 4000,
                                 rect: CGRect(x: 10, y: 10, width: 3000, height: 3000))
        check("a rectangular selection is still four lines",
              rect.isRectangular && segmentCount(rect.boundaryPath()) <= 4,
              "a 3000x3000 rectangular selection traces "
                  + "\(segmentCount(rect.boundaryPath())) segments")

        // The tint the canvas falls back to is drawn through the mask itself, so it has
        // to land on exactly the selected pixels and nowhere else.
        let tintMask = SelectionMask(width: 40, height: 40)
        for y in 8..<20 { for x in 5..<15 { tintMask.mark(x: x, y: y) } }
        tintMask.mark(x: 30, y: 30)
        tintMask.recompute()
        let ctx = Bitmap.makeContext(width: 40, height: 40)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        var tinted = 0
        if let stencil = tintMask.stencilImage() {
            // No flip here, unlike CanvasView: a bitmap context already has its row 0 at
            // the top of the rect, where a flipped NSView does not.
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: 40, height: 40), mask: stencil)
            ctx.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            ctx.restoreGState()
            // Blue AND not white: the canvas under the tint is white, and white is blue
            // enough to fool a one-channel test.
            for y in 0..<40 {
                for x in 0..<40 {
                    let p = ctx.sample(x: x, y: y)
                    if p.b > 200 && p.r < 60 { tinted += 1 }
                }
            }
        }
        let insideTinted = ctx.sample(x: 10, y: 12)
        let outsideTinted = ctx.sample(x: 10, y: 25)
        let lonelyPixel = ctx.sample(x: 30, y: 30)
        check("the tint lands on exactly the selected pixels",
              tinted == tintMask.setCount && insideTinted.b > 200 && insideTinted.r < 60
                  && outsideTinted.r == 255 && outsideTinted.g == 255 && lonelyPixel.b > 200,
              "\(tinted) pixels tinted for a \(tintMask.setCount) pixel mask; inside "
                  + "\(insideTinted), outside \(outsideTinted), and the one stray pixel at "
                  + "(30,30) reads \(lonelyPixel)")
    }

    // MARK: - Safety: the four ways Paintbox used to lose work without saying so

    /// Every check here is a regression guard for something that silently destroyed the
    /// user's picture or their file. They are grouped because they share a theme rather
    /// than a mechanism: a destructive default, a silent format substitution, a quit
    /// with no review, and an animation flattened in place.
    private static func safetyChecks(tmp: URL) {

        // --- A stray Backspace must not erase the picture ------------------------
        //
        // `PaintDocument.clear(mask:)` reads a nil mask as "the whole canvas", which is
        // the right contract for the model. Delete used to hand it the selection
        // straight through, so ⌫ with nothing selected turned every pixel transparent.
        let settings = ToolSettings()
        let delDoc = PaintDocument(width: 40, height: 30, fill: red)
        let delUndo = UndoManager()
        delUndo.groupsByEvent = false
        delDoc.undoManager = delUndo
        let canvas = CanvasView(document: delDoc, settings: settings)
        let untouched = checksum(delDoc.context)
        canvas.selection = nil
        let deletedNothing = canvas.deleteSelectionOrFloating()
        let afterStrayDelete = corners(delDoc)
        check("Delete with no selection is a no-op",
              !deletedNothing && checksum(delDoc.context) == untouched
                  && isRed(afterStrayDelete.tl) && isRed(afterStrayDelete.br),
              "returned \(deletedNothing); corners \(afterStrayDelete.tl) / \(afterStrayDelete.br); "
                  + "canvas \(checksum(delDoc.context) == untouched ? "byte for byte identical" : "CHANGED")")

        // ...but a real selection must still erase exactly itself, and undo back.
        canvas.setSelection(rect: CGRect(x: 10, y: 5, width: 12, height: 10))
        var deletedSomething = false
        group(delUndo) { deletedSomething = canvas.deleteSelectionOrFloating() }
        let inside = delDoc.context.sample(x: 15, y: 9)
        let outside = delDoc.context.sample(x: 2, y: 2)
        delUndo.undo()
        check("Delete with a selection erases it",
              deletedSomething && isClear(inside) && isRed(outside)
                  && checksum(delDoc.context) == untouched,
              "returned \(deletedSomething); inside the selection \(inside), outside \(outside); "
                  + "undo \(checksum(delDoc.context) == untouched ? "restored it" : "DID NOT restore it")")

        // --- ...and the menu must not offer it either -----------------------------
        //
        // Three items whose titles all say "Selection" used to stay enabled with nothing
        // selected and act on everything. Crop, one item away, already refused.
        let menuDoc = PaintDocument(width: 32, height: 24, fill: green)
        let controller = PaintWindowController(document: menuDoc)
        func enabled(_ action: Selector) -> Bool {
            let item = NSMenuItem(title: "x", action: action, keyEquivalent: "")
            return controller.validateMenuItem(item)
        }
        let dangerous: [(String, Selector)] = [
            ("Delete Selection", #selector(PaintWindowController.delete(_:))),
            ("Cut", #selector(PaintWindowController.cut(_:))),
            ("Fill Selection with Background", #selector(PaintWindowController.fillSelection(_:))),
            ("Crop to Selection", #selector(PaintWindowController.cropToSelection(_:))),
        ]
        let liveWithNothing = dangerous.filter { enabled($0.1) }.map(\.0)
        check("selection-only menu items grey out",
              liveWithNothing.isEmpty,
              liveWithNothing.isEmpty ? "all four disabled with nothing selected"
                                      : "still enabled: \(liveWithNothing.joined(separator: ", "))")
        controller.canvas.setSelection(rect: CGRect(x: 4, y: 4, width: 8, height: 8))
        let deadWithSelection = dangerous.filter { !enabled($0.1) }.map(\.0)
        check("...and come back with a selection",
              deadWithSelection.isEmpty,
              deadWithSelection.isEmpty ? "all four enabled once 8x8 is selected"
                                        : "still disabled: \(deadWithSelection.joined(separator: ", "))")

        // Cut and Fill are guarded in the action too, not only in the validator: a
        // keystroke that reaches them another way must still not touch the canvas.
        controller.canvas.selection = nil
        let beforeGuards = checksum(menuDoc.context)
        controller.cut(nil)
        controller.fillSelection(nil)
        check("Cut and Fill do nothing with no selection",
              checksum(menuDoc.context) == beforeGuards,
              "canvas checksum \(checksum(menuDoc.context) == beforeGuards ? "unchanged" : "CHANGED")")

        // ...and with a selection it must FILL, not erase. ⌘⌫ once fell through to the
        // canvas, which ignores modifiers, so the item labelled "Fill Selection with
        // Background" made the area transparent instead. The menu wiring is checked
        // elsewhere; this is the other half — that the action itself reaches the
        // fill-with-background path and leaves opaque paint behind. Its own controller,
        // because a real fill dirties the document and the quit check below needs a
        // clean one.
        let fillDoc = PaintDocument(width: 32, height: 24, fill: green)
        let fillController = PaintWindowController(document: fillDoc)
        fillController.settings.background = blue
        fillController.canvas.setSelection(rect: CGRect(x: 8, y: 6, width: 10, height: 8))
        fillController.fillSelection(nil)
        let fillInside = fillDoc.context.sample(x: 12, y: 9)
        let fillOutside = fillDoc.context.sample(x: 2, y: 2)
        let fillEdge = fillDoc.context.sample(x: 8, y: 6)
        check("Fill Selection paints the background colour, it does not erase",
              isBlue(fillInside) && isBlue(fillEdge) && isGreen(fillOutside),
              "inside the selection \(fillInside) and at its top-left corner \(fillEdge) "
                  + "(background is blue); outside \(fillOutside)")
        PaintboxApp.shared.forget(fillController)

        // --- Quitting must review unsaved work ------------------------------------
        //
        // NSApplication.terminate never sends windowShouldClose(_:), and this is not an
        // NSDocument app, so ⌘Q used to exit over the top of an edited canvas.
        let app = PaintboxApp.shared
        app.adopt(controller)
        let quietWhenClean = app.controllersToReviewOnQuit().isEmpty
        menuDoc.edit("Pencil") { c in
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let asksWhenDirty = app.controllersToReviewOnQuit().contains { $0 === controller }
        let hasHook = app.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:)))
        check("quitting reviews unsaved work",
              hasHook && quietWhenClean && asksWhenDirty,
              "applicationShouldTerminate \(hasHook ? "implemented" : "MISSING"); "
                  + "clean document \(quietWhenClean ? "not asked about" : "ASKED ABOUT"); "
                  + "edited document \(asksWhenDirty ? "asked about" : "NOT ASKED ABOUT")")
        app.forget(controller)

        // --- A format Paintbox cannot write must not be written anyway -------------
        //
        // The open panel admits everything ImageIO reads, which is more than it writes.
        // `save` used to fall back to PNG, so ⌘S stamped PNG bytes into `logo.webp` and
        // marked the document clean.
        check("no writer is claimed for read-only formats",
              SaveFormat.forExtension("webp") == nil && SaveFormat.forExtension("psd") == nil
                  && SaveFormat.forExtension("dng") == nil && SaveFormat.forExtension("") == nil,
              "webp/psd/dng/none all map to no SaveFormat")

        for ext in ["webp", ""] {
            let name = ext.isEmpty ? "sketch" : "sketch.\(ext)"
            let url = tmp.appendingPathComponent(name)
            let fmtDoc = PaintDocument(width: 16, height: 16, fill: blue)
            fmtDoc.fileURL = url
            fmtDoc.markDirty()
            var threw = false
            do { try fmtDoc.save(to: url) } catch { threw = true }
            let wrote = FileManager.default.fileExists(atPath: url.path)
            check("saving \(ext.isEmpty ? "an extensionless file" : ".\(ext)") refuses",
                  threw && !wrote && fmtDoc.isDirty,
                  "\(threw ? "threw" : "DID NOT THROW"); file \(wrote ? "WAS WRITTEN" : "not written"); "
                      + "document still \(fmtDoc.isDirty ? "dirty" : "MARKED CLEAN")")
        }

        // --- An animated GIF must not be flattened in silence ----------------------
        let gifURL = tmp.appendingPathComponent("anim.gif")
        let frameColors = [red, green, blue]
        if writeAnimatedGIF(to: gifURL, colors: frameColors) {
            let counted = Bitmap.frameCount(url: gifURL)
            let gifDoc = PaintDocument.open(url: gifURL)
            let firstFrame = gifDoc.map { $0.context.sample(x: 8, y: 8) } ?? RGBA.clear
            check("an animated GIF is opened as frame 1 of N",
                  counted == 3 && gifDoc?.sourceFrameCount == 3 && isRed(firstFrame),
                  "\(counted) frames on disk, document says \(gifDoc?.sourceFrameCount ?? -1), "
                      + "and the pixels are the first frame (\(firstFrame))")
            // Saving writes one frame, so the count the warning depends on has to drop
            // to 1 — otherwise the app would keep asking about an animation it no
            // longer has.
            let outURL = tmp.appendingPathComponent("anim-flat.png")
            var savedCount = -1
            if let gifDoc {
                do {
                    try gifDoc.save(to: outURL)
                    savedCount = gifDoc.sourceFrameCount
                } catch {
                    savedCount = -2
                }
            }
            check("saving a GIF frame resets the frame count",
                  savedCount == 1 && Bitmap.frameCount(url: outURL) == 1,
                  "document says \(savedCount) after saving; the file it now points at has "
                      + "\(Bitmap.frameCount(url: outURL)) frame")
        } else {
            check("an animated GIF is opened as frame 1 of N", false, "could not build the fixture")
            check("saving a GIF frame resets the frame count", false, "could not build the fixture")
        }

        // --- One file, one window --------------------------------------------------
        //
        // `open(url:)` used to build a fresh document every time, so double-clicking a
        // picture that was already open — or clicking it twice in Open Recent — gave two
        // windows editing one path. Each save writes the WHOLE picture, so whichever was
        // saved second discarded the other's work in silence, and the window that lost it
        // went on showing a clean title. The second open must raise the first window.
        //
        // The second call deliberately uses the /private-prefixed spelling of the same
        // file: FileManager's temporary directory lives under /var, which is a symlink to
        // /private/var, so a plain `==` on the URLs would miss this — and this is exactly
        // how the Finder and the open panel disagree about a path in real use.
        let dupURL = tmp.appendingPathComponent("already-open.png")
        let dupSource = PaintDocument(width: 24, height: 18, fill: green)
        var dupReady = true
        do { try Bitmap.write(dupSource.image, to: dupURL, format: .png) } catch { dupReady = false }
        if dupReady {
            let app2 = PaintboxApp.shared
            let firstOpen = app2.open(url: dupURL)
            let opened = app2.existingController(for: dupURL)
            // Unsaved work in the first window: what a forked second document would lose.
            opened?.paintDocument.edit("Pencil") { c in
                c.setFillColor(blue.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
            }
            let windowsBefore = NSApp.windows.count
            let secondOpen = app2.open(url: dupURL.resolvingSymlinksInPath())
            let windowsAfter = NSApp.windows.count
            let same = opened != nil && app2.existingController(for: dupURL) === opened
            let stillDirty = opened?.paintDocument.isDirty == true
            let strayNil = app2.existingController(for: tmp.appendingPathComponent("never-opened.png")) == nil
            check("opening an open file raises its window",
                  firstOpen && secondOpen && same && stillDirty && strayNil
                      && windowsAfter == windowsBefore,
                  "second open returned \(secondOpen) and made "
                      + "\(windowsAfter - windowsBefore) new window(s); it is "
                      + "\(same ? "the same controller" : "A DIFFERENT CONTROLLER") and its unsaved "
                      + "work is \(stillDirty ? "still there" : "GONE"); an unopened path matches "
                      + "\(strayNil ? "nothing" : "SOMETHING")")
            if let opened {
                opened.window?.close()
                app2.forget(opened)
            }
        } else {
            check("opening an open file raises its window", false, "could not build the fixture")
        }

        // --- A picture wider than sRGB must not be clipped in silence ---------------
        //
        // The canvas is 8-bit sRGB, so a Display P3 photograph is hard-clipped on the way
        // in and ⌘S writes the clipped pixels back over the original. Undo cannot reach
        // that. Converting is the right trade for this app; doing it without a word is
        // not, so the window says so until the save that makes it untrue.
        let p3URL = tmp.appendingPathComponent("wide.png")
        let sRGBURL = tmp.appendingPathComponent("narrow.png")
        let sRGBWritten = (try? Bitmap.write(dupSource.image, to: sRGBURL, format: .png)) != nil
        if writeDisplayP3PNG(to: p3URL), sRGBWritten {
            let name = Bitmap.wideGamutName(url: p3URL)
            let plain = Bitmap.wideGamutName(url: sRGBURL)
            let p3Doc = PaintDocument.open(url: p3URL)
            // P3 red is (1.093, -0.227, -0.150) in extended sRGB: what survives is the
            // corner of the cube, pure sRGB red. This asserts the loss is real, which is
            // what the note is for.
            let clipped = p3Doc?.context.sample(x: 4, y: 4) ?? RGBA.clear
            check("a wide-gamut file is named, an sRGB one is not",
                  name == "Display P3" && plain == nil && p3Doc?.sourceWideGamut == "Display P3"
                      && isRed(clipped),
                  "the P3 file reads as \(name ?? "nothing") and the sRGB one as "
                      + "\(plain ?? "nothing"); the document says "
                      + "\(p3Doc?.sourceWideGamut ?? "nothing") and its P3 red clipped to \(clipped)")

            if let p3Doc {
                let p3Controller = PaintWindowController(document: p3Doc)
                // The real window fills its status line from a main-queue block after
                // `buildUI`, and the self-test never runs a run loop — so the note is
                // asked for the way every later change asks for it, through the observer
                // callback the document itself calls.
                p3Controller.documentDidChangeMetadata(p3Doc)
                let said = p3Controller.statusLabel.stringValue
                var afterSave = "did not save"
                let flatURL = tmp.appendingPathComponent("wide-saved.png")
                if (try? p3Doc.save(to: flatURL)) != nil {
                    afterSave = p3Controller.statusLabel.stringValue
                }
                check("the window says colour was converted, until it is saved",
                      said.contains("Display P3 → sRGB") && !afterSave.contains("Display P3")
                          && p3Doc.sourceWideGamut == nil,
                      "status while open: \(said.isEmpty ? "empty" : said); after saving: \(afterSave)")
                p3Controller.window?.close()
                PaintboxApp.shared.forget(p3Controller)
            } else {
                check("the window says colour was converted, until it is saved", false,
                      "the P3 file would not open")
            }
        } else {
            check("a wide-gamut file is named, an sRGB one is not", false, "could not build the fixture")
            check("the window says colour was converted, until it is saved", false,
                  "could not build the fixture")
        }

        saveAsCollisionChecks(tmp: tmp)
        cutoutFormatChecks(tmp: tmp)
    }

    // ---- Save As must not aim a second window at an open file ----------------

    /// The other half of "one file, one window". Open refuses to give a second window a
    /// file that is already open; Save As could hand one a file another window was
    /// editing, which is the same silent overwrite arriving from the other side and on a
    /// file somebody had already saved. It has to refuse, name the window in the way, and
    /// leave the bytes on disk untouched — while still saving anywhere nobody is holding.
    private static func saveAsCollisionChecks(tmp: URL) {
        let taken = tmp.appendingPathComponent("held-by-another-window.png")
        let free = tmp.appendingPathComponent("nobody-holds-this.png")
        let holderDoc = PaintDocument(width: 24, height: 18, fill: green)
        guard (try? Bitmap.write(holderDoc.image, to: taken, format: .png)) != nil,
              let bytesBefore = try? Data(contentsOf: taken) else {
            check("Save As refuses a file another window holds", false, "could not build the fixture")
            return
        }
        holderDoc.fileURL = taken
        let holder = PaintWindowController(document: holderDoc)
        PaintboxApp.shared.adopt(holder)

        // A second window, with different pixels in it, aimed at the first one's file.
        let doc = PaintDocument(width: 24, height: 18, fill: red)
        let controller = PaintWindowController(document: doc)
        PaintboxApp.shared.adopt(controller)
        var said = ""
        if case .refused(let why) = controller.saveAs(to: taken, format: .png, quality: 0.8) {
            said = why
        }
        let bytesAfter = try? Data(contentsOf: taken)
        // Being refused must not have quietly moved this window onto the file either.
        let stillUntitled = doc.fileURL == nil
        // A path nobody holds still saves, and the picture that lands is this window's.
        let wroteFree = controller.saveAs(to: free, format: .png, quality: 0.8) == .wrote(free)
        let landed = Bitmap.load(url: free).map { Bitmap.context(from: $0).sample(x: 4, y: 4) } ?? .clear
        // And saving over its OWN file again is not a collision with itself: the lookup
        // now finds this very controller, which is the one it must not refuse.
        let holdsItNow = PaintboxApp.shared.existingController(for: free) === controller
        let again = controller.saveAs(to: free, format: .png, quality: 0.8) == .wrote(free)

        check("Save As refuses a file another window holds",
              said.contains("held-by-another-window.png") && bytesAfter == bytesBefore
                  && stillUntitled && wroteFree && isRed(landed) && holdsItNow && again,
              "aiming at a file another window holds said \"\(said.isEmpty ? "NOTHING" : said)\"; "
                  + "that file is \(bytesAfter == bytesBefore ? "byte for byte what it was" : "OVERWRITTEN") "
                  + "and this window is \(stillUntitled ? "still untitled" : "NOW POINTING AT IT"); a free "
                  + "path \(wroteFree ? "saved" : "DID NOT SAVE") and reads back \(landed); saving over "
                  + "its own file again \(again ? "is allowed" : "WAS REFUSED")")

        controller.window?.close()
        PaintboxApp.shared.forget(controller)
        holder.window?.close()
        PaintboxApp.shared.forget(holder)
    }

    // ---- --cutout must write the format its output is named ------------------

    /// `--cutout in.jpg out.jpg` used to put PNG bytes in a file called .jpg, whatever
    /// the output was named — and the README's own batch loop names the output after the
    /// input, so following the instructions produced a folder of mislabelled files. The
    /// format now comes from the output's extension through the save panel's own table,
    /// a format with no alpha channel is matted exactly as ⌘S mattes it, and an extension
    /// the table does not know is refused rather than guessed at.
    ///
    /// Checked on the real bytes: a file's first bytes are the one thing that cannot be
    /// talked round by its name.
    private static func cutoutFormatChecks(tmp: URL) {
        let inURL = tmp.appendingPathComponent("cutout-in.png")
        guard (try? Bitmap.write(makeSubjectImage(), to: inURL, format: .png)) != nil else {
            check("--cutout writes the format it was asked for", false, "could not build the fixture")
            check("--cutout refuses an extension it cannot write", false, "could not build the fixture")
            return
        }
        func magic(_ url: URL, _ n: Int) -> [UInt8] {
            Array((try? Data(contentsOf: url))?.prefix(n) ?? Data())
        }

        let pngOut = tmp.appendingPathComponent("cutout-out.png")
        let pngRun = CutoutCommand.run(input: inURL, output: pngOut)
        let pngMagic = magic(pngOut, 4) == [0x89, 0x50, 0x4E, 0x47]
        let pngCorner = Bitmap.load(url: pngOut).map { Bitmap.context(from: $0).sample(x: 5, y: 5) } ?? .clear

        // JPEG cannot hold transparency, so the cut-out has to be composited onto the
        // matte the same way ⌘S composites it. The corner that came out transparent in
        // the PNG must therefore come back opaque and white here — not black, which is
        // what an uncomposited premultiplied cut-out flattens to.
        let jpgOut = tmp.appendingPathComponent("cutout-out.jpg")
        let jpgRun = CutoutCommand.run(input: inURL, output: jpgOut)
        let jpgMagic = magic(jpgOut, 3) == [0xFF, 0xD8, 0xFF]
        let jpgCorner = Bitmap.load(url: jpgOut).map { Bitmap.context(from: $0).sample(x: 5, y: 5) } ?? .clear
        let matted = jpgCorner.a == 255 && jpgCorner.r > 240 && jpgCorner.g > 240 && jpgCorner.b > 240

        check("--cutout writes the format it was asked for",
              pngRun.code == 0 && pngMagic && pngCorner.a == 0
                  && jpgRun.code == 0 && jpgMagic && matted,
              "a .png output exited \(pngRun.code) with \(pngMagic ? "PNG" : "NON-PNG") bytes and a "
                  + "corner of \(pngCorner); a .jpg output exited \(jpgRun.code) with "
                  + "\(jpgMagic ? "JPEG" : "NON-JPEG") bytes and a corner of \(jpgCorner), "
                  + "\(matted ? "matted onto white" : "NOT MATTED")")

        // An extension nothing in the table claims: refuse and say so, rather than
        // writing PNG under a name that promises something else.
        let oddOut = tmp.appendingPathComponent("cutout-out.xyz")
        let oddRun = CutoutCommand.run(input: inURL, output: oddOut)
        let oddWrote = FileManager.default.fileExists(atPath: oddOut.path)
        let bareOut = tmp.appendingPathComponent("cutout-out-no-extension")
        let bareRun = CutoutCommand.run(input: inURL, output: bareOut)
        let bareWrote = FileManager.default.fileExists(atPath: bareOut.path)
        let oddSaid = oddRun.err ?? ""

        check("--cutout refuses an extension it cannot write",
              oddRun.code != 0 && !oddWrote && oddSaid.contains(".xyz") && oddSaid.contains(".png")
                  && bareRun.code != 0 && !bareWrote,
              "a .xyz output exited \(oddRun.code) saying \"\(oddSaid.isEmpty ? "NOTHING" : oddSaid)\" "
                  + "and left \(oddWrote ? "A FILE BEHIND" : "no file"); a name with no extension at all "
                  + "exited \(bareRun.code) and left \(bareWrote ? "A FILE BEHIND" : "no file")")
    }

    /// An 8x8 Display P3 PNG with the profile really in the file, for the wide-gamut
    /// check above. Built through a P3 context rather than by tagging sRGB bytes, so the
    /// pixels are outside the sRGB gamut the way a phone photograph's are.
    private static func writeDisplayP3PNG(to url: URL) -> Bool {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                  bytesPerRow: 32, space: p3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue),
              let fill = CGColor(colorSpace: p3, components: [1, 0, 0, 1])
        else { return false }
        ctx.setFillColor(fill)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }


    // MARK: - Safety: the ways Paintbox used to be quietly WRONG
    //
    // Not "lost your work" like the section above, but "gave you something other than
    // what it said it was giving you": a square that was not square, a preview of a
    // picture the Apply button would never produce, a right angle that resampled the
    // whole image, a colour that punched a hole. Each of these had no symptom worth
    // noticing until you measured it, which is why they all get a measurement.

    private static func polishChecks(tmp: URL) {
        squareSelectionChecks()
        shapePreviewChecks()
        toolColourChecks()
        filterPreviewChecks()
        geometryChecks()
        undoOrderChecks()
        staleSelectionChecks()
        keyAndFormatChecks(tmp: tmp)
        adoptedCanvasChecks(tmp: tmp)
        pixelReaderChecks(tmp: tmp)
        identityAdjustmentChecks()
    }

    // ---- Adjustments with the sliders untouched is not an edit ---------------

    /// The Adjustments dialog opens on brightness 0, contrast 1, saturation 1, and OK
    /// without moving a slider used to render the whole canvas through CoreImage,
    /// composite the result back, and leave an undo step — on a 6000x4000 photograph
    /// 160-210 ms of work, ~183 MB held on the undo stack, an edited dot in the title
    /// bar and a ⌘Z that visibly does nothing.
    ///
    /// Two independent guarantees, because either alone is a single point of failure:
    /// `adjustColors` recognises its own identity and never starts, and `composite`
    /// registers nothing when the pixels it would write are the pixels already there.
    /// The second is what catches grayscale on an already-grey picture too, so it is
    /// checked with a filter that really does run.
    private static func identityAdjustmentChecks() {
        let doc = detailedDoc(size: 120)
        let undo = freshUndo(doc)
        let before = checksum(doc.context)
        // No `group` around these: `registerUndo` brackets its own, and an EMPTY group
        // closed by hand is itself an undo step — which would answer the question this
        // test is asking before the code got a chance to.
        doc.adjustColors(brightness: 0, contrast: 1, saturation: 1, mask: nil)
        let identityChanged = checksum(doc.context) != before
        let identityUndo = undo.canUndo
        let identityDirty = doc.isDirty

        // Grayscale twice: the second one has nothing left to do, and must say so.
        doc.grayscale(mask: nil)
        let greyWorked = checksum(doc.context) != before && undo.canUndo
        let afterGrey = checksum(doc.context)
        let stepsAfterGrey = undo.canUndo
        doc.grayscale(mask: nil)
        let greyAgainChanged = checksum(doc.context) != afterGrey
        // One undo has to put the colour back, which it cannot do if a second dead step
        // was pushed on top of it.
        undo.undo()
        let backToColour = checksum(doc.context) == before

        check("Adjustments that change nothing are not an edit",
              !identityChanged && !identityUndo && !identityDirty
                  && greyWorked && stepsAfterGrey && !greyAgainChanged && backToColour,
              "identity sliders: pixels \(identityChanged ? "CHANGED" : "untouched"), undo "
                  + "\(identityUndo ? "OFFERED" : "empty"), document "
                  + "\(identityDirty ? "DIRTY" : "clean"); grayscale "
                  + "\(greyWorked ? "ran once" : "DID NOT RUN") and a second pass "
                  + "\(greyAgainChanged ? "CHANGED PIXELS" : "changed nothing"); one undo "
                  + "\(backToColour ? "restored the colour" : "DID NOT restore the colour")")
    }

    // ---- Reading a filter's output must not mean copying it ------------------

    /// `composite` used to get at its replacement's bytes by drawing the whole image into
    /// a second full-size context — 11 ms and 91 MB on a 6000x4000 canvas to reach bytes
    /// that were already in the canonical layout. `PixelReader` borrows them instead.
    ///
    /// The borrow is the dangerous half, so it is what is checked: that it is really
    /// taken (or the fix is doing nothing), that the bytes it hands back are the picture,
    /// and that an image whose data provider holds an ENCODED file — every image an
    /// image source decodes — is not borrowed from, because those bytes are a PNG rather
    /// than pixels and would come through as noise.
    private static func pixelReaderChecks(tmp: URL) {
        let made = squareDoc(size: 40, rects: [CGRect(x: 0, y: 0, width: 20, height: 40)]).image
        let borrowed = PixelReader(made)
        var mismatches = 0
        if let r = borrowed {
            let truth = Bitmap.context(from: made)
            for y in 0..<made.height {
                for x in 0..<made.width {
                    let o = y * r.bytesPerRow + x * 4
                    let t = truth.sample(x: x, y: y)
                    if r.bytes[o] != t.r || r.bytes[o + 1] != t.g || r.bytes[o + 2] != t.b
                        || r.bytes[o + 3] != t.a { mismatches += 1 }
                }
            }
        }

        // A filter's own output is the case that matters: it is what `composite` reads.
        let filtered = CanvasFilter.render(made) { CanvasFilter.invert($0) }
        let filteredBorrowed = filtered.flatMap { PixelReader($0) }?.borrowed ?? false

        // An image straight out of an image source: canonical or not, its provider holds
        // the file, and `utType` is how that is told apart.
        let url = tmp.appendingPathComponent("reader.png")
        try? Bitmap.write(made, to: url, format: .png)
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        let decoded = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let decodedReader = decoded.flatMap { PixelReader($0) }
        let decodedBorrowed = decodedReader?.borrowed ?? true
        let decodedIsFile = decoded?.utType != nil
        // Whatever route it took, the bytes have to be the picture.
        let decodedLeft = decodedReader.map { r -> RGBA in
            RGBA(r: r.bytes[4 * 4], g: r.bytes[4 * 4 + 1], b: r.bytes[4 * 4 + 2], a: r.bytes[4 * 4 + 3])
        }

        // End to end: the borrowed path really is what a masked filter writes through.
        let doc = squareDoc(size: 40, rects: [])
        let mask = SelectionMask(width: 40, height: 40, rect: CGRect(x: 0, y: 0, width: 10, height: 40))
        doc.invertColors(mask: mask)
        let inside = doc.context.sample(x: 5, y: 5)
        let outside = doc.context.sample(x: 30, y: 5)

        check("a filter's output is read, not copied",
              borrowed?.borrowed == true && mismatches == 0 && filteredBorrowed
                  && decodedIsFile && !decodedBorrowed
                  && decodedLeft == RGBA(r: 255, g: 0, b: 0, a: 255)
                  && inside == RGBA(r: 0, g: 0, b: 0, a: 255)
                  && outside == RGBA(r: 255, g: 255, b: 255, a: 255),
              "a canvas image is \(borrowed?.borrowed == true ? "borrowed" : "COPIED") with "
                  + "\(mismatches) wrong pixels; a filter's output is "
                  + "\(filteredBorrowed ? "borrowed" : "COPIED"); a decoded file "
                  + "\(decodedIsFile ? "declares its type" : "DECLARES NOTHING") and is "
                  + "\(decodedBorrowed ? "BORROWED FROM" : "copied") reading "
                  + "\(decodedLeft?.description ?? "nothing"); inverting the left strip gives "
                  + "\(inside) inside and \(outside) outside")
    }

    // ---- Opening a file may copy the pixels once, not twice -------------------

    /// `Bitmap.load` normalises a decoded frame into a canonical context and used to hand
    /// back an image of it, which `PaintDocument` then drew into a second canonical
    /// context: two full-canvas copies for one file, 84 ms and 91 MB followed by 13 ms
    /// and another 91 MB on a 6000x4000 JPEG, peaking at 200 MB for a 91 MB picture.
    /// `PaintDocument.open` now adopts the context the loader built.
    ///
    /// Adoption is checked by IDENTITY, because "the pixels are right" is equally true of
    /// the copy this test exists to prove is gone. What the identity must never cost is
    /// correctness, so the pixels are checked too — from the file, through the adopted
    /// canvas, and on past a stroke, which is where a stale cached image would show.
    private static func adoptedCanvasChecks(tmp: URL) {
        let url = tmp.appendingPathComponent("adopted.png")
        let fixture = squareDoc(size: 48, rects: [CGRect(x: 0, y: 0, width: 24, height: 48)])
        guard (try? Bitmap.write(fixture.image, to: url, format: .png)) != nil else {
            check("opening a file copies the pixels once", false, "could not write the fixture")
            return
        }
        // The loader's context, taken twice: one to hand over, one to compare against.
        let handedOver = Bitmap.loadContext(url: url)
        let doc = handedOver.map { PaintDocument(adopting: $0, url: url) }
        let adopted = (doc?.context === handedOver) && handedOver != nil
        let opened = PaintDocument.open(url: url)
        let openedLeft = opened?.context.sample(x: 4, y: 4)
        let openedRight = opened?.context.sample(x: 40, y: 4)
        let openedCanonical = opened.map { Bitmap.isCanonical($0.context) } ?? false

        // A stroke on the adopted canvas has to reach `image`, not a cached copy of the
        // file, and the file's own pixels have to be underneath it.
        opened?.edit("Test Stroke") { c in
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 40, y: 40, width: 8, height: 8))
        }
        let strokeReaches = opened.map { Bitmap.context(from: $0.image).sample(x: 44, y: 44) }
        let untouched = opened?.context.sample(x: 4, y: 4)

        // A context laid out some other way is copied instead: wrong bytes would be worse
        // than a slow open. 32-bit premultiplied FIRST is the layout AppKit hands out.
        let alien = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                              bytesPerRow: 64, space: paintboxColorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)
        alien?.setFillColor(green.cgColor)
        alien?.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let alienDoc = alien.map { PaintDocument(adopting: $0) }
        let alienCopied = alienDoc.map { $0.context !== alien! && Bitmap.isCanonical($0.context) } ?? false
        let alienPixel = alienDoc?.context.sample(x: 8, y: 8)

        let red255 = RGBA(r: 255, g: 0, b: 0, a: 255)
        let white = RGBA(r: 255, g: 255, b: 255, a: 255)
        check("opening a file copies the pixels once",
              adopted && openedCanonical && openedLeft == red255 && openedRight == white
                  && strokeReaches == RGBA(r: 0, g: 0, b: 255, a: 255) && untouched == red255
                  && alienCopied && alienPixel?.g ?? 0 > 150 && alienPixel?.r ?? 255 < 100,
              "the loader's context is \(adopted ? "adopted as the canvas" : "COPIED AGAIN"); "
                  + "the opened picture reads \(openedLeft?.description ?? "nothing")/"
                  + "\(openedRight?.description ?? "nothing") and is "
                  + "\(openedCanonical ? "canonical" : "NOT CANONICAL"); after a stroke it reads "
                  + "\(strokeReaches?.description ?? "nothing") beside \(untouched?.description ?? "nothing"); "
                  + "a premultiplied-first context is \(alienCopied ? "copied" : "ADOPTED AS IS") "
                  + "and reads \(alienPixel?.description ?? "nothing")")
    }

    // ---- A selection cannot outlive the canvas it was made on ----------------

    /// The selection is one byte per canvas pixel, so a resize under it leaves a mask
    /// whose rows are the wrong length and whose bounding box points off the picture.
    /// Two independent guarantees, checked separately here because either one alone is
    /// a single point of failure: the canvas refuses to hand out a mask that no longer
    /// fits, and every operation that walks a mask clamps to the current canvas.
    private static func staleSelectionChecks() {
        // 1. The owner's guarantee. This canvas has no window controller — so nothing is
        // observing the document and nothing clears the selection for it — which is
        // exactly the case where a stale mask used to be handed straight to a filter.
        let bare = PaintDocument(width: 60, height: 40, fill: .white)
        let bareCanvas = CanvasView(document: bare, settings: ToolSettings())
        bareCanvas.selectAllPixels()
        let selectedBefore = bareCanvas.selection?.setCount ?? 0
        bare.setCanvasSize(width: 24, height: 24, anchor: .topLeft, fill: .white)
        let staleAfterShrink = bareCanvas.selection
        bareCanvas.selectAllPixels()
        bare.setCanvasSize(width: 90, height: 70, anchor: .topLeft, fill: .white)
        let staleAfterGrow = bareCanvas.selection
        bareCanvas.setSelection(rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        let freshFits = bareCanvas.selection.map { $0.width == 90 && $0.height == 70 } ?? false
        check("a resize under a selection ends it",
              selectedBefore == 60 * 40 && staleAfterShrink == nil && staleAfterGrow == nil
                  && freshFits,
              "\(selectedBefore) px selected on 60x40; after shrinking to 24x24 the canvas "
                  + "offered \(staleAfterShrink.map { "a \($0.width)x\($0.height) MASK" } ?? "nothing")"
                  + ", after growing to 90x70 \(staleAfterGrow.map { "a \($0.width)x\($0.height) MASK" } ?? "nothing")"
                  + "; a new selection is \(freshFits ? "canvas-sized" : "THE WRONG SIZE")")

        // 2. The model's guarantee, for a mask that reaches an operation anyway: a fill
        // and a filter through a mask twice the size of the canvas must write inside the
        // bitmap and nowhere else, and must still respect the shape where the two overlap.
        // Selected: a 12-wide band down the left, plus rows 40 and below — an L, so no
        // walk can escape into the single-rectangle fast path, and its bounding box
        // (60x60) is far outside the 24x24 canvas the ops actually see.
        let stale = SelectionMask(width: 60, height: 60)
        for y in 0..<60 {
            for x in 0..<60 where x < 12 || y >= 40 { stale.mark(x: x, y: y) }
        }
        stale.recompute()

        let filled = PaintDocument(width: 60, height: 60, fill: .white)
        filled.setCanvasSize(width: 24, height: 24, anchor: .topLeft, fill: .white)
        filled.clear(mask: stale, to: red)
        let fillIn = filled.context.sample(x: 5, y: 5)
        let fillOut = filled.context.sample(x: 20, y: 5)

        let inverted = PaintDocument(width: 60, height: 60, fill: .white)
        inverted.setCanvasSize(width: 24, height: 24, anchor: .topLeft, fill: .white)
        inverted.invertColors(mask: stale)
        let invIn = inverted.context.sample(x: 5, y: 5)
        let invOut = inverted.context.sample(x: 20, y: 5)

        check("a mask bigger than the canvas stays inside it",
              filled.pixelWidth == 24 && filled.pixelHeight == 24 && isRed(fillIn)
                  && fillOut.r == 255 && fillOut.g == 255 && fillOut.b == 255
                  && invIn.r < 40 && invIn.g < 40 && invIn.b < 40 && invIn.a == 255
                  && invOut.r == 255 && invOut.g == 255 && invOut.b == 255,
              "through a 60x60 mask on a 24x24 canvas: fill gave \(fillIn) inside the mask "
                  + "and \(fillOut) outside it, invert gave \(invIn) and \(invOut); "
                  + "the canvas is \(filled.pixelWidth)x\(filled.pixelHeight)")
    }

    /// A deterministic stream of fractional points, standing in for a mouse.
    private struct Scatter {
        private var seed: UInt64 = 0x243f6a8885a308d3
        mutating func next(_ limit: CGFloat) -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 11) % 100_000) / 100_000 * limit
        }
    }

    // ---- Shift means square, and the ants say so ----------------------------

    private static func squareSelectionChecks() {
        let doc = PaintDocument(width: 600, height: 400, fill: .white)
        let settings = ToolSettings()
        settings.tool = .select
        let canvas = CanvasView(document: doc, settings: settings)

        /// One whole Shift-drag through the real mouse handlers. Returns what the ants
        /// showed mid-drag and what the mouse-up committed, which must be the same rect.
        func shiftDrag(_ a: CGPoint, _ b: CGPoint) -> (live: CGRect?, committed: CGRect?) {
            canvas.selection = nil
            canvas.begin(.init(point: a, shift: true))
            canvas.moveTo(.init(point: b, shift: true))
            let live = canvas.liveSelectionRect
            canvas.end(.init(point: b, shift: true))
            return (live, canvas.selectionRect)
        }

        // Three hundred drags with fractional endpoints — the normal case, because a
        // mouse location is a float and `imagePoint` divides it by the zoom. The old
        // code's `.integral` rounded the two axes outward independently, so roughly half
        // of these came back one pixel off square.
        var scatter = Scatter()
        var notSquare: [String] = []
        var disagreed = 0
        for _ in 0..<300 {
            let a = CGPoint(x: scatter.next(600), y: scatter.next(400))
            let b = CGPoint(x: scatter.next(600), y: scatter.next(400))
            let r = shiftDrag(a, b)
            guard let c = r.committed else { continue }
            if c.width != c.height && notSquare.count < 3 {
                notSquare.append("\(Int(c.width))x\(Int(c.height))")
            }
            if r.live != c { disagreed += 1 }
        }
        check("Shift-drag selects a square",
              notSquare.isEmpty && disagreed == 0,
              notSquare.isEmpty ? "300 fractional Shift-drags, every one square, and the "
                                  + "marching ants matched the committed selection every time"
                                : "not square: \(notSquare.joined(separator: ", "))")

        // Dragged off the edge of the picture. The square used to be clipped against the
        // canvas afterwards, which turned a 400x400 drag into a 400x100 selection — and
        // Crop to Selection then cropped exactly that.
        let offBottom = shiftDrag(CGPoint(x: 100, y: 300), CGPoint(x: 500, y: 700))
        let offRight = shiftDrag(CGPoint(x: 500, y: 100), CGPoint(x: 900, y: 500))
        let upLeft = shiftDrag(CGPoint(x: 120, y: 90), CGPoint(x: -300, y: 40))
        let squares = [offBottom.committed, offRight.committed, upLeft.committed]
        check("a Shift-drag past the edge stays square",
              squares.allSatisfy { $0 != nil && $0!.width == $0!.height && $0!.width >= 1 }
                  && offBottom.committed == CGRect(x: 100, y: 300, width: 100, height: 100)
                  && offRight.committed == CGRect(x: 500, y: 100, width: 100, height: 100),
              "off the bottom \(offBottom.committed.map(describe) ?? "nil"), off the right "
                  + "\(offRight.committed.map(describe) ?? "nil"), up and left "
                  + "\(upLeft.committed.map(describe) ?? "nil")")

        // ...and Crop to Selection inherits it, which is the thing anyone would notice.
        let cropDoc = PaintDocument(width: 600, height: 400, fill: .white)
        let cropSettings = ToolSettings()
        cropSettings.tool = .select
        let cropCanvas = CanvasView(document: cropDoc, settings: cropSettings)
        cropCanvas.begin(.init(point: CGPoint(x: 100.37, y: 300.82), shift: true))
        cropCanvas.moveTo(.init(point: CGPoint(x: 500.11, y: 699.4), shift: true))
        cropCanvas.end(.init(point: CGPoint(x: 500.11, y: 699.4), shift: true))
        if let sel = cropCanvas.selectionRect { cropDoc.crop(to: sel) }
        check("Crop to Selection after a Shift-drag is square",
              cropDoc.pixelWidth == cropDoc.pixelHeight,
              "cropped to \(cropDoc.pixelWidth)x\(cropDoc.pixelHeight)")

        // An ordinary drag must still land on the pixel grid it was dragged to, with no
        // outward inflation: `.integral` used to add up to a pixel on each axis.
        canvas.selection = nil
        canvas.begin(.init(point: CGPoint(x: 10.4, y: 20.6)))
        canvas.moveTo(.init(point: CGPoint(x: 50.6, y: 60.4)))
        canvas.end(.init(point: CGPoint(x: 50.6, y: 60.4)))
        check("a plain drag selects the box it was dragged to",
              canvas.selectionRect == CGRect(x: 10, y: 21, width: 41, height: 39),
              "(10.4, 20.6) to (50.6, 60.4) selected "
                  + "\(canvas.selectionRect.map(describe) ?? "nothing")")
    }

    private static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))x\(Int(r.height)))"
    }

    // ---- The shape preview draws the shape that gets stamped ----------------

    private static func shapePreviewChecks() {
        let doc = PaintDocument(width: 120, height: 120, fill: .white)
        let settings = ToolSettings()
        settings.tool = .rectangle
        settings.shapeStyle = .filled
        // A filled shape uses the BACKGROUND swatch for its inside (the foreground
        // outlines it), so that is the one that has to be visible here.
        settings.foreground = red
        settings.background = red
        let canvas = CanvasView(document: doc, settings: settings)

        canvas.begin(.init(point: CGPoint(x: 10, y: 10), shift: true))
        canvas.moveTo(.init(point: CGPoint(x: 90, y: 30), shift: true))
        let shiftPreview = canvas.pendingShapeRect
        canvas.end(.init(point: CGPoint(x: 90, y: 30), shift: true))
        let painted = doc.contentBounds(tolerance: 8)

        // The same drag with Shift up, for contrast: the preview must follow the pointer.
        let doc2 = PaintDocument(width: 120, height: 120, fill: .white)
        let canvas2 = CanvasView(document: doc2, settings: settings)
        canvas2.begin(.init(point: CGPoint(x: 10, y: 10)))
        canvas2.moveTo(.init(point: CGPoint(x: 90, y: 30)))
        let freePreview = canvas2.pendingShapeRect
        canvas2.end(.init(point: CGPoint(x: 90, y: 30)))

        check("a Shift-dragged shape previews as the shape it stamps",
              shiftPreview?.width == 80 && shiftPreview?.height == 80
                  && painted == CGRect(x: 10, y: 10, width: 80, height: 80)
                  && freePreview?.width == 80 && freePreview?.height == 20,
              "with Shift the preview is "
                  + "\(shiftPreview.map(describe) ?? "nil") and the stamped pixels are "
                  + "\(painted.map(describe) ?? "nothing"); without Shift the preview is "
                  + "\(freePreview.map(describe) ?? "nil")")
    }

    // ---- Colours with alpha, and the tools that used to ignore it -----------

    private static func toolColourChecks() {
        let half = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        let invisible = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0)

        func drawn(_ body: (PaintDocument) -> Void) -> RGBA {
            let d = PaintDocument(width: 20, height: 20, fill: .white)
            body(d)
            return d.context.sample(x: 10, y: 10)
        }
        let pencil = drawn { Painter.pencil(in: $0.context, from: CGPoint(x: 10, y: 10),
                                            to: CGPoint(x: 10, y: 10), color: half) }
        let bucket = drawn { Painter.floodFill(in: $0.context, at: CGPoint(x: 10, y: 10),
                                               color: half, tolerance: 0) }
        let line = drawn { Painter.line(in: $0.context, from: CGPoint(x: 0, y: 10),
                                        to: CGPoint(x: 19, y: 10), width: 3, color: half) }
        // Half-transparent blue over white composites to a pale blue that is still OPAQUE.
        // Replacing instead — which is what these two used to do — leaves rgba(0,0,128,128):
        // a hole in the picture where the white went.
        func opaquePaleBlue(_ p: RGBA) -> Bool { p.a == 255 && p.b > 240 && p.r > 100 && p.r < 155 }
        check("a translucent colour tints rather than punching a hole",
              opaquePaleBlue(pencil) && opaquePaleBlue(bucket) && opaquePaleBlue(line),
              "pencil \(pencil), bucket \(bucket), line \(line) — all source-over onto white")

        // And a fully transparent colour paints nothing at all, rather than erasing.
        let blankDoc = PaintDocument(width: 20, height: 20, fill: .white)
        let blank = checksum(blankDoc.context)
        Painter.pencil(in: blankDoc.context, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 15, y: 15),
                       color: invisible)
        let afterPencil = checksum(blankDoc.context)
        Painter.floodFill(in: blankDoc.context, at: CGPoint(x: 10, y: 10), color: invisible, tolerance: 8)
        let afterBucket = checksum(blankDoc.context)
        check("an invisible colour is not a secret eraser",
              afterPencil == blank && afterBucket == blank,
              "pencil \(afterPencil == blank ? "changed nothing" : "CHANGED THE CANVAS"); "
                  + "bucket \(afterBucket == blank ? "changed nothing, and terminated" : "CHANGED THE CANVAS")")

        // The bucket must still fill, and still stop at a boundary, now that what stops
        // it looping is a visited map rather than "this pixel is already the new colour".
        let fillDoc = PaintDocument(width: 40, height: 40, fill: .white)
        Painter.pencil(in: fillDoc.context, from: CGPoint(x: 0, y: 20), to: CGPoint(x: 39, y: 20), color: red)
        Painter.floodFill(in: fillDoc.context, at: CGPoint(x: 20, y: 30), color: half, tolerance: 8)
        let below = fillDoc.context.sample(x: 20, y: 30)
        let above = fillDoc.context.sample(x: 20, y: 10)
        check("a translucent bucket still fills, and still stops",
              opaquePaleBlue(below) && above.r == 255 && above.b == 255,
              "below the line \(below), above it \(above)")

        // ---- Fill Selection cannot depend on the SHAPE of the selection -------
        //
        // The rectangular fast path fills through CGContext, which composites; the loop
        // used to write the source bytes in, which replaces. One command, one colour, two
        // answers, chosen by whether your selection happened to be a box.
        func filled(stray: Bool) -> RGBA {
            let d = PaintDocument(width: 20, height: 20, fill: .white)
            let m = SelectionMask(width: 20, height: 20, rect: CGRect(x: 2, y: 2, width: 10, height: 10))
            if stray { m.mark(x: 18, y: 18); m.recompute() }
            d.clear(mask: m, to: half)
            return d.context.sample(x: 5, y: 5)
        }
        let asBox = filled(stray: false)
        let asBlob = filled(stray: true)
        check("Fill Selection gives one answer whatever the shape",
              asBox == asBlob && opaquePaleBlue(asBox),
              "rectangular mask \(asBox), irregular mask \(asBlob)")

        // An opaque fill has to agree across the same two paths too, since that is the
        // one the fast path still takes.
        func filledOpaque(stray: Bool) -> RGBA {
            let d = PaintDocument(width: 20, height: 20, fill: .white)
            let m = SelectionMask(width: 20, height: 20, rect: CGRect(x: 2, y: 2, width: 10, height: 10))
            if stray { m.mark(x: 18, y: 18); m.recompute() }
            d.clear(mask: m, to: green)
            return d.context.sample(x: 5, y: 5)
        }
        check("...and so does an opaque one",
              filledOpaque(stray: false) == filledOpaque(stray: true)
                  && isGreen(filledOpaque(stray: false)),
              "rectangular \(filledOpaque(stray: false)), irregular \(filledOpaque(stray: true))")

        // ---- One click of the brush is one dab --------------------------------
        //
        // The dab loop ran 0...steps, so t = 0 and t = 1 both landed on the same point:
        // the soft stamp was composited twice, which squares its transparency and hardens
        // the very edge the stamp exists to soften. Driven through the canvas, because
        // mouse-down and the drag that follows are what have to agree between them.
        func brushStroke(_ colour: NSColor, _ points: [CGPoint]) -> CGContext {
            let d = PaintDocument(width: 60, height: 40, fill: .clear)
            let s = ToolSettings()
            s.tool = .brush
            s.brushSize = 20
            s.foreground = colour
            let v = CanvasView(document: d, settings: s)
            v.begin(.init(point: points[0]))
            for p in points.dropFirst() { v.moveTo(.init(point: p)) }
            v.end(.init(point: points.last!))
            return d.context
        }
        let clickCtx = brushStroke(red, [CGPoint(x: 20, y: 20)])
        let onceCtx = Bitmap.makeContext(width: 60, height: 40)
        let stamp = Painter.softStamp(size: 20, color: red)
        onceCtx.withTopLeftOrigin { c in
            c.draw(stamp, in: CGRect(x: 10, y: 10, width: 20, height: 20))
        }
        var worstEdge = 0
        for x in 10..<30 {
            worstEdge = max(worstEdge, abs(Int(clickCtx.sample(x: x, y: 20).a)
                                           - Int(onceCtx.sample(x: x, y: 20).a)))
        }
        let halfCentre = brushStroke(half, [CGPoint(x: 20, y: 20)]).sample(x: 20, y: 20)
        check("one brush click is one dab",
              worstEdge <= 1 && abs(Int(halfCentre.a) - 128) <= 3,
              "the click's alpha profile differs from a single stamp by at most \(worstEdge); "
                  + "a 50% brush leaves alpha \(halfCentre.a) at the centre (128 wanted, "
                  + "191 if it is stamped twice)")

        // A drag must not re-stamp the point the previous segment finished on either.
        // The second segment starts from the anchor the first one RETURNED — the point
        // its last dab landed on, which is what the canvas carries between events.
        let segA = Bitmap.makeContext(width: 60, height: 40)
        let anchor = Painter.brush(in: segA, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 30, y: 20),
                                   size: 14, color: half)
        Painter.brush(in: segA, from: anchor, to: CGPoint(x: 50, y: 20), size: 14, color: half)
        let segB = Bitmap.makeContext(width: 60, height: 40)
        Painter.brush(in: segB, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20), size: 14, color: half)
        var worstJoin = 0
        for x in 0..<60 {
            worstJoin = max(worstJoin, abs(Int(segA.sample(x: x, y: 20).a)
                                           - Int(segB.sample(x: x, y: 20).a)))
        }
        check("a drag does not paint its joins twice",
              worstJoin <= 1,
              "a stroke split at x=30 differs from one continuous stroke by at most "
                  + "\(worstJoin) levels of alpha")

        // ---- A stroke is the same picture however the pointer was sampled ------
        //
        // Spacing is a property of the stroke, not of the mouse. Each segment used to lay
        // at least one dab and then move the anchor to the pointer, so the dab count was
        // really a count of mouse-dragged events: the same 25px drag delivered a pixel at
        // a time — an ordinary slow drag, or any drag at all at 8x zoom — came out 138
        // levels harder at its edge and effectively opaque down the middle.
        let fastDrag = brushStroke(half, [CGPoint(x: 10, y: 20), CGPoint(x: 35, y: 20)])
        let slowDrag = brushStroke(half, (0...25).map { CGPoint(x: 10 + CGFloat($0), y: 20) })
        var worstRate = 0
        for y in 0..<40 {
            for x in 0..<60 {
                worstRate = max(worstRate, abs(Int(fastDrag.sample(x: x, y: y).a)
                                               - Int(slowDrag.sample(x: x, y: y).a)))
            }
        }
        check("a brush stroke ignores the mouse's frame rate",
              worstRate <= 1,
              "25px in one event vs 25 events of 1px differ by at most \(worstRate) levels "
                  + "of alpha; centre \(fastDrag.sample(x: 22, y: 20)) vs "
                  + "\(slowDrag.sample(x: 22, y: 20))")

        // ---- The eyedropper cannot pick a colour that is not in the picture ----
        let eyeDoc = PaintDocument(width: 64, height: 64, fill: red)
        let eyeSettings = ToolSettings()
        eyeSettings.tool = .eyedropper
        let eyeCanvas = CanvasView(document: eyeDoc, settings: eyeSettings)
        // A fractional zoom rounds the view a hair wider than the picture, so the last
        // column of pixels maps past `pixelWidth - 1`. `sample` answers that with fully
        // transparent black, which used to become the foreground colour in silence.
        eyeCanvas.begin(.init(point: CGPoint(x: 64.4, y: 63.8)))
        let picked = RGBA.premultiplied(eyeSettings.foreground)
        eyeCanvas.begin(.init(point: CGPoint(x: -0.4, y: -2)))
        let pickedBefore = RGBA.premultiplied(eyeSettings.foreground)
        check("the eyedropper clamps to the picture",
              isRed(picked) && isRed(pickedBefore),
              "a click just past the right edge picked \(picked); one just before the "
                  + "top-left picked \(pickedBefore) (red is the only colour in the picture)")
    }

    // ---- The preview shows what Apply will do -------------------------------

    private static func filterPreviewChecks() {
        /// A white canvas with an opaque red disc, and the wand selection of that disc —
        /// an irregular mask, which is the case the preview used to get most wrong.
        func discDoc() -> (PaintDocument, SelectionMask) {
            let d = PaintDocument(width: 200, height: 200, fill: .white)
            d.context.withTopLeftOrigin { c in
                c.setFillColor(red.cgColor)
                c.fillEllipse(in: CGRect(x: 50, y: 50, width: 100, height: 100))
            }
            d.touch()
            let m = MagicWand.select(in: d.context, at: CGPoint(x: 100, y: 100),
                                     tolerance: 24, contiguous: true)!
            return (d, m)
        }

        /// The worst per-channel disagreement between a preview thumbnail and the region
        /// of the applied result it claims to be showing. -1 when they are not even the
        /// same size.
        func worstDifference(preview: CGImage?, applied: PaintDocument, box: CGRect) -> Int {
            guard let preview, preview.width == Int(box.width), preview.height == Int(box.height) else {
                return -1
            }
            let p = Bitmap.context(from: preview)
            var worst = 0
            for y in 0..<p.height {
                for x in 0..<p.width {
                    let a = p.sample(x: x, y: y)
                    let b = applied.context.sample(x: Int(box.minX) + x, y: Int(box.minY) + y)
                    worst = max(worst, abs(Int(a.r) - Int(b.r)))
                    worst = max(worst, abs(Int(a.g) - Int(b.g)))
                    worst = max(worst, abs(Int(a.b) - Int(b.b)))
                    worst = max(worst, abs(Int(a.a) - Int(b.a)))
                }
            }
            return worst
        }

        // ---- Blur through an irregular selection -------------------------------
        let (blurDoc, blurMask) = discDoc()
        let blurPreview = FilterPreview(image: blurDoc.image, mask: blurMask)
        let shownBlur = blurPreview?.render(values: [12]) { ci, v, ctx in
            CanvasFilter.blur(ci, radius: CGFloat(v[0]) * ctx.scale)
        }
        // What the old preview did: filter a CUT-OUT of the selection. Kept here so the
        // test fails if anyone puts it back — the cut-out's Gaussian samples the
        // transparent nothing around the blob and drags its alpha down.
        let cutOut = blurDoc.copy(mask: blurMask)
        let cutOutBlur = cutOut.flatMap { CanvasFilter.render($0) { CanvasFilter.blur($0, radius: 12) } }
        blurDoc.blur(radius: 12, mask: blurMask)
        let blurWorst = worstDifference(preview: shownBlur, applied: blurDoc, box: blurMask.bounds)

        // Sample a few pixels just inside the blob's left edge, where the two used to be
        // furthest apart: 35% transparent dark red against opaque pink.
        var haloAlpha = 255
        if let cutOutBlur {
            let c = Bitmap.context(from: cutOutBlur)
            for dx in [4, 8, 16] { haloAlpha = min(haloAlpha, Int(c.sample(x: dx, y: c.height / 2).a)) }
        }
        check("the blur preview is the blur you get",
              blurWorst >= 0 && blurWorst <= 1 && haloAlpha < 220,
              "preview and applied result differ by at most \(blurWorst) per channel over "
                  + "\(Int(blurMask.bounds.width))x\(Int(blurMask.bounds.height)) px; the "
                  + "old cut-out preview reached alpha \(haloAlpha) at the blob's edge "
                  + "where the result is opaque")

        // ---- Pixelate's block grid ---------------------------------------------
        //
        // CIPixellate anchors its blocks to the image it is given. The preview's image is
        // a tile of the canvas, so without an explicit anchor its grid started at the
        // tile's corner and the blocks landed somewhere other than where Apply puts them.
        // The canvas has to be big enough that the preview's tile is NOT the whole
        // picture — otherwise the tile's corner is the canvas's corner and the anchor
        // could be missing without anything showing it.
        let pixDoc = PaintDocument(width: 700, height: 700, fill: .white)
        pixDoc.context.withTopLeftOrigin { c in
            var seed: UInt64 = 0x12345
            for y in stride(from: 0, to: 700, by: 4) {
                for x in stride(from: 0, to: 700, by: 4) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = CGFloat((seed >> 33) % 255) / 255
                    c.setFillColor(NSColor(srgbRed: n, green: 1 - n, blue: 0.4, alpha: 1).cgColor)
                    c.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        pixDoc.touch()
        // An origin deliberately NOT on a multiple of the block size, which is where the
        // two grids came apart.
        let pixMask = SelectionMask(width: 700, height: 700,
                                    rect: CGRect(x: 237, y: 237, width: 96, height: 96))
        let pixPreview = FilterPreview(image: pixDoc.image, mask: pixMask)
        let shownPix = pixPreview?.render(values: [16]) { ci, v, ctx in
            CanvasFilter.pixelate(ci, scale: max(1, CGFloat(v[0]) * ctx.scale), anchor: ctx.canvasOrigin)
        }
        // The same preview with the anchor left off: the fault, kept as a control.
        let unanchored = pixPreview?.render(values: [16]) { ci, v, ctx in
            CanvasFilter.pixelate(ci, scale: max(1, CGFloat(v[0]) * ctx.scale))
        }
        pixDoc.pixelate(scale: 16, mask: pixMask)
        let pixWorst = worstDifference(preview: shownPix, applied: pixDoc, box: pixMask.bounds)
        let unanchoredWorst = worstDifference(preview: unanchored, applied: pixDoc, box: pixMask.bounds)
        check("the pixelate preview lands on the grid Apply uses",
              pixWorst >= 0 && pixWorst <= 1 && unanchoredWorst > 20,
              "anchored to the canvas the preview differs by at most \(pixWorst) per "
                  + "channel; anchored to the preview's own tile it differs by "
                  + "\(unanchoredWorst), which is a block grid several pixels out")

        // ---- Nothing selected: the preview is the whole picture -----------------
        let allDoc = PaintDocument(image: makeTestImage())
        let allPreview = FilterPreview(image: allDoc.image, mask: nil)
        let shownAll = allPreview?.render(values: [0, 1, 0]) { ci, v, _ in
            CanvasFilter.colorControls(ci, brightness: CGFloat(v[0]), contrast: CGFloat(v[1]),
                                       saturation: CGFloat(v[2]))
        }
        allDoc.adjustColors(brightness: 0, contrast: 1, saturation: 0, mask: nil)
        let allWorst = worstDifference(preview: shownAll, applied: allDoc,
                                       box: CGRect(x: 0, y: 0, width: 240, height: 160))
        check("with nothing selected the preview is the whole picture",
              allWorst >= 0 && allWorst <= 1,
              "240x160 previewed at scale \(allPreview?.context.scale ?? -1); worst "
                  + "channel difference from the applied result \(allWorst)")
    }

    // ---- Geometry that used to drift ----------------------------------------

    private static func geometryChecks() {
        /// A one-pixel checkerboard: the harshest possible test for resampling, because
        /// every neighbour disagrees with every neighbour.
        func checkerDoc(width: Int, height: Int) -> PaintDocument {
            let d = PaintDocument(width: width, height: height, fill: .white)
            d.context.withTopLeftOrigin { c in
                c.setFillColor(NSColor.black.cgColor)
                for y in 0..<height {
                    for x in 0..<width where (x + y) % 2 == 0 {
                        c.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            d.touch()
            return d
        }
        func greys(_ d: PaintDocument) -> Int {
            var n = 0
            for y in 0..<d.pixelHeight {
                for x in 0..<d.pixelWidth {
                    let p = d.context.sample(x: x, y: y)
                    if p.a != 255 || (p.r != 0 && p.r != 255) { n += 1 }
                }
            }
            return n
        }

        var sizes: [String] = []
        var softened = 0
        for angle in [CGFloat(90), 180, 270, -90] {
            let d = checkerDoc(width: 64, height: 40)
            d.rotateArbitrary(degrees: angle)
            sizes.append("\(Int(angle))°→\(d.pixelWidth)x\(d.pixelHeight)")
            softened += greys(d)
            let wanted = (Int(angle) % 180 == 0) ? (64, 40) : (40, 64)
            if (d.pixelWidth, d.pixelHeight) != wanted { softened += 1_000_000 }
        }
        check("a right angle typed into Rotate by Angle is the lossless one",
              softened == 0,
              "\(sizes.joined(separator: ", ")) with \(softened) resampled pixels "
                  + "(the general path adds a pixel of canvas and softens every edge)")

        // A genuinely arbitrary angle still grows the canvas and still resamples — this
        // is a shortcut for right angles, not a change of behaviour for everything else.
        let odd = checkerDoc(width: 64, height: 40)
        odd.rotateArbitrary(degrees: 30)
        check("an arbitrary angle still rotates",
              odd.pixelWidth > 64 && odd.pixelHeight > 40 && isClear(odd.context.sample(x: 1, y: 1)),
              "30° grew a 64x40 picture to \(odd.pixelWidth)x\(odd.pixelHeight) with a "
                  + "transparent new corner \(odd.context.sample(x: 1, y: 1))")

        // ---- Canvas Size out and back ------------------------------------------
        //
        // The centred offsets rounded DOWN, which is not symmetric across zero: growing
        // by 5 moved the picture +2 and shrinking by 5 moved it −3, so the two were not
        // inverses and a row and a column came back as background fill.
        let canvasDoc = squareDoc(size: 100, rects: [CGRect(x: 0, y: 0, width: 3, height: 3),
                                                     CGRect(x: 97, y: 97, width: 3, height: 3)])
        let before = checksum(canvasDoc.context)
        canvasDoc.setCanvasSize(width: 105, height: 105, anchor: .center, fill: cyan)
        let grownCorner = canvasDoc.context.sample(x: 3, y: 3)
        canvasDoc.setCanvasSize(width: 100, height: 100, anchor: .center, fill: cyan)
        let cyanLeft = count(in: canvasDoc) { $0.b > 200 && $0.g > 200 && $0.r < 100 }
        check("Canvas Size out and back leaves the picture where it was",
              checksum(canvasDoc.context) == before && cyanLeft == 0
                  && isRed(canvasDoc.context.sample(x: 1, y: 1)),
              "grown by 5 the corner mark sat at (3,3) \(grownCorner); shrunk back the "
                  + "canvas is \(checksum(canvasDoc.context) == before ? "byte for byte identical" : "DIFFERENT")"
                  + " with \(cyanLeft) pixels of fill left in it")

        // The other way round, with an odd difference. Shrinking throws pixels away, so
        // the bytes cannot come back — but what survived has to land where it started,
        // and with the old asymmetric rounding it did not.
        let oddDoc = squareDoc(size: 41, rects: [CGRect(x: 19, y: 19, width: 3, height: 3)])
        oddDoc.setCanvasSize(width: 34, height: 34, anchor: .center, fill: cyan)
        let midMark = oddDoc.context.sample(x: 17, y: 17)
        oddDoc.setCanvasSize(width: 41, height: 41, anchor: .center, fill: cyan)
        let backMark = oddDoc.context.sample(x: 20, y: 20)
        let slipped = isRed(oddDoc.context.sample(x: 21, y: 21)) != isRed(oddDoc.context.sample(x: 19, y: 19))
        check("...and shrinking first puts the picture back where it was",
              isRed(midMark) && isRed(backMark) && !slipped,
              "the centre mark read \(midMark) at 34x34 and \(backMark) back at 41x41, "
                  + "with its two corners \(slipped ? "NO LONGER" : "still") level")
    }

    // ---- Undo is one step per thing you did ---------------------------------

    private static func undoOrderChecks() {
        // Two registrations, no grouping of our own: with event grouping on they used to
        // collapse into one step, so committing a floating paste and then drawing in the
        // same mouse-down gave a single ⌘Z that threw both away.
        let doc = PaintDocument(width: 16, height: 16, fill: .white)
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        doc.registerUndo(name: "Paste")
        doc.context.withTopLeftOrigin { c in
            c.setFillColor(green.cgColor); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        doc.touch()
        let afterPaste = checksum(doc.context)
        doc.registerUndo(name: "Pencil")
        Painter.pencil(in: doc.context, from: CGPoint(x: 12, y: 12), to: CGPoint(x: 12, y: 12), color: red)
        doc.touch()

        let topName = undo.undoActionName
        undo.undo()
        let afterOne = checksum(doc.context)
        let secondName = undo.undoActionName
        let stillMore = undo.canUndo
        undo.undo()
        check("one registration is one undo step",
              topName == "Pencil" && afterOne == afterPaste && stillMore && secondName == "Paste"
                  && !undo.canUndo,
              "the menu offered “Undo \(topName)”; one ⌘Z left the paste in place and "
                  + "offered “Undo \(secondName)”")

        // The window controller's manager has to have event grouping off, or the two
        // groups above are re-merged by the run loop and nothing above is true in the app.
        let liveDoc = PaintDocument(width: 32, height: 32, fill: .white)
        let controller = PaintWindowController(document: liveDoc)
        let manager = controller.window.flatMap { controller.windowWillReturnUndoManager($0) }
        check("the window's undo manager does not group by event",
              manager?.groupsByEvent == false,
              "groupsByEvent is \(manager.map { "\($0.groupsByEvent)" } ?? "unreadable")")

        // ---- A floating paste cannot be stranded over a resized canvas ---------
        let badge = Bitmap.makeContext(width: 8, height: 8)
        badge.setFillColor(blue.cgColor)
        badge.fill(CGRect(x: 0, y: 0, width: 8, height: 8))

        // The observer's own guard: change the canvas size under a floating item by any
        // route at all and the item goes, rather than hanging in mid-air at coordinates
        // measured against a canvas that no longer exists.
        controller.canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 20, y: 20))
        let wasFloating = controller.canvas.hasFloatingItem
        liveDoc.crop(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let strandedAfterCrop = controller.canvas.hasFloatingItem

        // And redo finishes pending edits first, exactly as undo already did.
        let redoDoc = PaintDocument(width: 60, height: 60, fill: .white)
        let redoController = PaintWindowController(document: redoDoc)
        redoController.canvas.setSelection(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        redoController.cropToSelection(nil)
        redoController.undoAction(nil)
        redoController.canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 40, y: 40))
        redoController.redoAction(nil)
        check("a floating paste is never left over a canvas it does not fit",
              wasFloating && !strandedAfterCrop && !redoController.canvas.hasFloatingItem,
              "an item floating over a 32x32 canvas \(strandedAfterCrop ? "SURVIVED" : "was cancelled") "
                  + "a crop to 10x10; after Redo the canvas is "
                  + "\(redoDoc.pixelWidth)x\(redoDoc.pixelHeight) with "
                  + "\(redoController.canvas.hasFloatingItem ? "SOMETHING STILL FLOATING" : "nothing floating")")
        PaintboxApp.shared.forget(controller)
        PaintboxApp.shared.forget(redoController)
    }

    // ---- Shortcuts that were dead keys, and formats that were wrong ---------

    private static func keyAndFormatChecks(tmp: URL) {
        // The Mac Delete key sends U+007F. Both Edit-menu items were armed to U+0008,
        // which no keypress ever produces, so ⌘⌫ fell through to the canvas — which
        // ignores modifiers — and ERASED the selection where the menu says it fills it.
        PaintboxApp.shared.buildMenus()
        let editMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        let deleteItem = editMenu?.items.first { $0.action == #selector(PaintWindowController.delete(_:)) }
        let fillItem = editMenu?.items.first { $0.action == #selector(PaintWindowController.fillSelection(_:)) }

        // Re-armed on a throwaway menu with a target we can watch, because the real items
        // go through the responder chain and there is no key window out here.
        final class Hit: NSObject {
            var fired: [String] = []
            @objc func hit(_ sender: NSMenuItem?) { fired.append(sender?.title ?? "?") }
        }
        let watcher = Hit()
        let probe = NSMenu()
        for item in [deleteItem, fillItem].compactMap({ $0 }) {
            let copy = NSMenuItem(title: item.title, action: #selector(Hit.hit(_:)),
                                  keyEquivalent: item.keyEquivalent)
            copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
            copy.target = watcher
            probe.addItem(copy)
        }
        func press(_ mods: NSEvent.ModifierFlags) -> Bool {
            let del = String(UnicodeScalar(NSDeleteCharacter)!)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: del, charactersIgnoringModifiers: del,
                                           isARepeat: false, keyCode: 51) else { return false }
            return probe.performKeyEquivalent(with: e)
        }
        let plainHit = press([])
        let commandHit = press([.command])
        check("the two Delete shortcuts are live keys",
              plainHit && commandHit && watcher.fired.count == 2
                  && watcher.fired[0].contains("Delete") && watcher.fired[1].contains("Fill"),
              "⌫ and ⌘⌫ fired \(watcher.fired.isEmpty ? "NOTHING" : watcher.fired.joined(separator: " then "))"
                  + "; key equivalents U+\(String(format: "%04X", deleteItem?.keyEquivalent.unicodeScalars.first?.value ?? 0))"
                  + " and U+\(String(format: "%04X", fillItem?.keyEquivalent.unicodeScalars.first?.value ?? 0))")

        // ...and the canvas must stand back from ⌘⌫ so the menu item is the one that runs.
        let keyDoc = PaintDocument(width: 20, height: 20, fill: red)
        let keySettings = ToolSettings()
        let keyCanvas = CanvasView(document: keyDoc, settings: keySettings)
        keyCanvas.setSelection(rect: CGRect(x: 4, y: 4, width: 8, height: 8))
        func send(_ mods: NSEvent.ModifierFlags) {
            let del = String(UnicodeScalar(NSDeleteCharacter)!)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: del, charactersIgnoringModifiers: del,
                                        isARepeat: false, keyCode: 51) {
                keyCanvas.keyDown(with: e)
            }
        }
        let intact = checksum(keyDoc.context)
        send([.command])
        let afterCommand = checksum(keyDoc.context)
        send([])
        let afterPlain = keyDoc.context.sample(x: 8, y: 8)
        check("the canvas leaves ⌘⌫ to the menu",
              afterCommand == intact && isClear(afterPlain),
              "⌘⌫ on the canvas \(afterCommand == intact ? "changed nothing" : "ERASED THE SELECTION"); "
                  + "plain ⌫ still erases it \(afterPlain)")

        // ---- GIF has on/off transparency, so soft edges are matted -------------
        //
        // Handed a premultiplied image, the GIF writer unpremultiplies and calls every
        // non-zero alpha opaque: a cut-out's soft edge came back at full saturation, a
        // bright fringe one to two pixels wide all the way round the subject.
        let fade = Bitmap.makeContext(width: 4, height: 1)
        if let p = fade.pixels {
            let rows: [[UInt8]] = [[255, 0, 0, 255], [128, 0, 0, 128], [64, 0, 0, 64], [0, 0, 0, 0]]
            for i in 0..<4 { for k in 0..<4 { p[i * 4 + k] = rows[i][k] } }
        }
        let gifURL = tmp.appendingPathComponent("fade.gif")
        let pngURL = tmp.appendingPathComponent("fade.png")
        var gifBack: [RGBA] = []
        var pngBack: [RGBA] = []
        do {
            try Bitmap.write(fade.makeImage()!, to: gifURL, format: .gif, matte: .white)
            try Bitmap.write(fade.makeImage()!, to: pngURL, format: .png, matte: .white)
            if let g = Bitmap.load(url: gifURL) {
                let c = Bitmap.context(from: g)
                gifBack = (0..<4).map { c.sample(x: $0, y: 0) }
            }
            if let n = Bitmap.load(url: pngURL) {
                let c = Bitmap.context(from: n)
                pngBack = (0..<4).map { c.sample(x: $0, y: 0) }
            }
        } catch {
            check("GIF mattes soft edges instead of fringing them", false, "\(error.localizedDescription)")
        }
        if gifBack.count == 4, pngBack.count == 4 {
            // 50% red over white is a pale pink, not full-strength red; 25% falls below the
            // half-way line and goes clear. PNG keeps all four levels, untouched.
            let matted = gifBack[1]
            check("GIF mattes soft edges instead of fringing them",
                  gifBack[0].a == 255 && matted.a == 255 && matted.g > 100 && matted.g < 160
                      && gifBack[2].a == 0 && gifBack[3].a == 0
                      && pngBack[1].a == 128 && pngBack[2].a == 64,
                  "gif \(gifBack.map(\.description).joined(separator: " ")); "
                      + "png \(pngBack.map(\.description).joined(separator: " "))")
        }

        // ---- Both ends of the quality slider have to work ----------------------
        //
        // macOS's AVIF writer refuses a quality of exactly 1.0 — finalize returns false
        // and no file appears — so the one slider position that reads as "best" was the
        // one position that could not be saved.
        var refused: [String] = []
        for format in SaveFormat.available where format.isLossy {
            for quality in [CGFloat(1.0), 0.1] {
                let url = tmp.appendingPathComponent("q\(Int(quality * 100)).\(format.fileExtension)")
                try? FileManager.default.removeItem(at: url)
                do {
                    try Bitmap.write(makeTestImage(), to: url, format: format,
                                     quality: quality, matte: .white)
                    if Bitmap.load(url: url) == nil {
                        refused.append("\(format.rawValue)@\(Int(quality * 100))% unreadable")
                    }
                } catch {
                    refused.append("\(format.rawValue)@\(Int(quality * 100))%")
                }
            }
        }
        check("every lossy format saves at both ends of the slider",
              refused.isEmpty,
              refused.isEmpty ? SaveFormat.available.filter(\.isLossy).map(\.rawValue)
                                    .joined(separator: ", ") + " all wrote at 100% and at 10%"
                              : "refused: \(refused.joined(separator: ", "))")

        // ---- An iPhone photo opens the right way up ----------------------------
        //
        // The decoder hands back the STORED buffer and ignores the Orientation tag, which
        // every other part of macOS applies. A portrait photo is stored landscape with
        // Orientation 6, so it opened on its side — and Save then wrote the sideways
        // pixels with no tag, making the rotation permanent everywhere else too.
        let sideways = Bitmap.makeContext(width: 200, height: 100)
        sideways.setFillColor(red.cgColor)
        sideways.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        sideways.setFillColor(blue.cgColor)
        sideways.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        var results: [String] = []
        var wrong: [String] = []
        for orientation in [1, 6, 8] {
            let url = tmp.appendingPathComponent("orient\(orientation).jpg")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(dest, sideways.makeImage()!,
                                       [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(dest), let loaded = Bitmap.load(url: url) else { continue }
            let c = Bitmap.context(from: loaded)
            let system = NSImage(contentsOf: url)?.size ?? .zero
            results.append("\(orientation): \(loaded.width)x\(loaded.height)")
            // The system's own idea of the size is the reference: match it, or the picture
            // is on its side relative to every other app on the machine.
            if CGFloat(loaded.width) != system.width || CGFloat(loaded.height) != system.height {
                wrong.append("\(orientation) is \(loaded.width)x\(loaded.height), Preview says \(system)")
            }
            // Orientation 6 rotates the stored picture 90° clockwise, so the left-hand red
            // half becomes the TOP half.
            let topLeft = c.sample(x: 5, y: 5)
            let expectRed = orientation != 8
            if isRed(topLeft) != expectRed {
                wrong.append("\(orientation)'s top-left corner is \(topLeft)")
            }
        }
        check("a photo with an orientation tag opens the right way up",
              wrong.isEmpty && results.count == 3,
              wrong.isEmpty ? results.joined(separator: ", ") + " — the same sizes macOS reports"
                            : wrong.joined(separator: "; "))
    }

    /// A tiny looping GIF, one flat colour per frame, so the frame count and which frame
    /// was loaded are both readable from a single pixel.
    private static func writeAnimatedGIF(to url: URL, colors: [NSColor]) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString,
                                                         colors.count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in colors {
            let ctx = Bitmap.makeContext(width: 32, height: 32)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            guard let img = ctx.makeImage() else { return false }
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    private static func roundTripFormats(_ formats: [SaveFormat], fixture: CGImage, tmp: URL) {
        for format in formats {
            let url = tmp.appendingPathComponent("roundtrip.\(format.fileExtension)")
            do {
                try Bitmap.write(fixture, to: url, format: format, quality: 0.9, matte: .white)
                guard let back = Bitmap.load(url: url) else {
                    check("save \(format.rawValue) round-trips", false, "could not read the file back")
                    continue
                }
                let ctx = Bitmap.context(from: back)
                let corner = ctx.sample(x: 5, y: 5)                       // was red
                let clear = ctx.sample(x: 235, y: 155)                    // was transparent
                let alphaOK = format.keepsAlpha ? clear.a == 0 : clear.a == 255
                let size = back.width == 240 && back.height == 160
                // HEIC and AVIF are lossy, so "red" is 253,1,0 rather than 255,0,0.
                let colourOK = corner.r > 200 && corner.g < 60 && corner.b < 60
                check("save \(format.rawValue) round-trips",
                      size && alphaOK && colourOK,
                      "\(back.width)x\(back.height); red corner \(corner); "
                          + "the transparent corner reads \(clear) "
                          + "(\(format.keepsAlpha ? "alpha kept" : "flattened onto the matte"))")
            } catch {
                check("save \(format.rawValue) round-trips", false, "\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cost: the ways Paintbox used to be slow enough to look broken

    /// Nothing in here is a stopwatch — a machine under load would fail a timing test for
    /// no reason at all — so each check is stated as the thing that made the app slow:
    /// how many pixels a filter has to produce, how much of the window one animation
    /// frame repaints, and whether a timer is still running for a window that has gone.
    private static func costChecks() {
        filterRegionChecks()
        filterFormatChecks()
        antsRedrawChecks()
        maskStatsChecks()
        selectionDragCostChecks()
        undoNoteChecks()
    }

    /// The mask's bounding box, its count and its rectangularity used to be found by
    /// reading every byte in the canvas once the marking was over: a nine-million-read
    /// pass after a wand click that may have selected forty pixels, and one more pass
    /// than the flood fill which had just walked exactly the pixels it selected. They are
    /// accumulated as the pixels are marked now, which means the only thing that can go
    /// wrong is disagreement with the scan — so that scan is kept, unused by the app, and
    /// every case below is checked against it.
    private static func maskStatsChecks() {
        var wrong: [String] = []

        func agrees(_ what: String, _ m: SelectionMask) {
            let s = m.scannedStats()
            if m.bounds != s.bounds || m.setCount != s.setCount || m.isRectangular != s.isRectangular {
                wrong.append("\(what): kept \(describe(m.bounds))/\(m.setCount)/"
                             + "\(m.isRectangular) vs scanned \(describe(s.bounds))/"
                             + "\(s.setCount)/\(s.isRectangular)")
            }
        }

        // The real wand, on a picture whose every 3x3 block is a different colour, so the
        // selected blobs are genuinely ragged rather than boxes in disguise.
        let doc = detailedDoc(size: 300)
        var wandShapes = 0, wandRagged = 0
        for (point, tolerance, contiguous) in [(CGPoint(x: 10, y: 10), 40, true),
                                               (CGPoint(x: 150, y: 150), 90, true),
                                               (CGPoint(x: 299, y: 299), 60, true),
                                               (CGPoint(x: 150, y: 150), 90, false),
                                               (CGPoint(x: 0, y: 299), 200, false)] {
            guard let m = MagicWand.select(in: doc.context, at: point, tolerance: tolerance,
                                           contiguous: contiguous) else { continue }
            wandShapes += 1
            if !m.isRectangular { wandRagged += 1 }
            agrees("wand at \(Int(point.x)),\(Int(point.y)) tol \(tolerance)"
                   + (contiguous ? "" : " global"), m)
        }

        // A flat colour is the case where the wand takes the whole canvas: the count is
        // every pixel and the mask has to come out rectangular, or the ants would trace
        // four million pixel edges instead of drawing one box.
        let flat = PaintDocument(width: 200, height: 120, fill: .white)
        let whole = MagicWand.select(in: flat.context, at: CGPoint(x: 5, y: 5),
                                     tolerance: 0, contiguous: true)
        if let whole { agrees("wand over a flat canvas", whole) }

        // Marking on top of a rectangle: the box has to grow, and the mask must stop
        // calling itself rectangular the moment one pixel sits outside the box it filled.
        let widened = SelectionMask(width: 60, height: 40, rect: CGRect(x: 4, y: 4, width: 10, height: 8))
        widened.mark(x: 50, y: 30)
        widened.mark(x: 50, y: 30)   // twice: a second mark must not count twice
        widened.mark(x: -3, y: 12)   // outside the canvas: ignored, as `contains` says
        widened.mark(x: 6, y: 6)     // already set: already counted
        widened.recompute()
        agrees("a rectangle widened by mark", widened)

        // Two touching rectangles marked pixel by pixel, which is what a wand on a hard-
        // edged logo produces: a filled L, ragged by one corner.
        let ell = SelectionMask(width: 80, height: 80)
        for y in 0..<40 { for x in 0..<20 { ell.mark(x: x, y: y) } }
        for y in 20..<40 { for x in 20..<50 { ell.mark(x: x, y: y) } }
        ell.recompute()
        agrees("an L marked pixel by pixel", ell)

        // One pixel, and nothing at all: the two ends of the range, where an accumulated
        // box is easiest to get wrong by an off-by-one.
        let dot = SelectionMask(width: 30, height: 30)
        dot.mark(x: 7, y: 21)
        dot.recompute()
        let none = SelectionMask(width: 30, height: 30)
        none.recompute()
        agrees("a single marked pixel", dot)
        agrees("a mask with nothing in it", none)

        check("a mask's box and count match a full scan",
              wrong.isEmpty && wandShapes == 5 && wandRagged >= 3
                  && whole?.isRectangular == true
                  && whole?.setCount == 200 * 120
                  && dot.bounds == CGRect(x: 7, y: 21, width: 1, height: 1)
                  && widened.setCount == 81 && !widened.isRectangular
                  && none.isEmpty && none.bounds == .zero,
              wrong.isEmpty ? "\(wandShapes) wand selections (\(wandRagged) of them ragged), "
                              + "a flat canvas wanded whole at \(whole?.setCount ?? -1) "
                              + "pixels, a widened rectangle at \(widened.setCount), an L, "
                              + "a single pixel and an empty mask all agree with a scan of "
                              + "the bytes"
                            : wrong.joined(separator: "; "))

        // `SelectionMask` has no `copy()`, and this is the invariant that means it needs
        // none: a mask is built whole and handed over, and whoever receives it never
        // writes into it. The canvas is the only receiver, so it is the one asked. If a
        // future selection tool starts editing the mask it was given, this fails — and
        // that is the day a copy would genuinely be needed.
        let handoverDoc = detailedDoc(size: 120)
        let handoverCanvas = CanvasView(document: handoverDoc, settings: ToolSettings())
        guard let handed = MagicWand.select(in: handoverDoc.context, at: CGPoint(x: 8, y: 8),
                                            tolerance: 60, contiguous: true) else {
            check("a mask handed to the canvas is never written into", false,
                  "the wand selected nothing to hand over")
            return
        }
        let handedCount = handed.setCount, handedBounds = handed.bounds
        let handedBytes = handed.bytes
        handoverCanvas.selection = handed
        // Everything the canvas does with a selection, short of drawing it.
        _ = handoverCanvas.selectionRect
        _ = handed.stencilImage()
        _ = handed.boundaryPath(in: CGRect(x: 0, y: 0, width: 60, height: 60))
        handoverDoc.blur(radius: 3, mask: handed)
        handoverDoc.clear(mask: handed, to: nil)
        handoverCanvas.setSelection(rect: CGRect(x: 2, y: 2, width: 20, height: 20))
        handoverCanvas.selectAllPixels()
        check("a mask handed to the canvas is never written into",
              handed.setCount == handedCount && handed.bounds == handedBounds
                  && handed.bytes == handedBytes && handedCount > 0,
              "\(handedCount) px at \(describe(handedBounds)) before; "
                  + "\(handed.setCount) px at \(describe(handed.bounds)) after the canvas "
                  + "clipped, filtered, replaced and then selected all")
    }

    /// A mask is one byte per canvas pixel, so building one per mouse-moved event means
    /// allocating and clearing megabytes a few hundred times across one drag. The drag
    /// carries a rectangle instead and the mask is made once, on mouse-up — this is the
    /// check that says so in terms of state rather than of speed: no mask exists at any
    /// point between the mouse going down and coming up.
    private static func selectionDragCostChecks() {
        let doc = PaintDocument(width: 1800, height: 1400, fill: .white)
        let settings = ToolSettings()
        settings.tool = .select
        let canvas = CanvasView(document: doc, settings: settings)
        canvas.selection = nil

        let start = CGPoint(x: 12, y: 9)
        canvas.begin(.init(point: start))
        var maskDuringDrag = 0, liveMissing = 0
        var lastLive: CGRect?
        for i in 1...240 {
            let p = CGPoint(x: 12 + CGFloat(i) * 7.3, y: 9 + CGFloat(i) * 5.7)
            canvas.moveTo(.init(point: p))
            if canvas.selection != nil { maskDuringDrag += 1 }
            guard let live = canvas.liveSelectionRect else { liveMissing += 1; continue }
            lastLive = live
        }
        let endPoint = CGPoint(x: 12 + 240 * 7.3, y: 9 + 240 * 5.7)
        canvas.end(.init(point: endPoint))
        let committed = canvas.selection

        check("dragging a selection builds no mask until mouse-up",
              maskDuringDrag == 0 && liveMissing == 0 && lastLive != nil
                  && committed != nil && committed?.bounds == lastLive
                  && committed?.isRectangular == true && canvas.liveSelectionRect == nil,
              maskDuringDrag == 0
                  ? "240 mouse-moved events over a 1800x1400 canvas made no mask at all; "
                    + "the ants followed \(describe(lastLive ?? .zero)) and mouse-up "
                    + "committed \(describe(committed?.bounds ?? .zero))"
                  : "a mask existed on \(maskDuringDrag) of 240 mouse-moved events")
    }

    /// A picture with detail at every scale, so a misalignment of even one pixel shows
    /// up as a colour difference rather than as more of the same flat colour.
    private static func detailedDoc(size: Int) -> PaintDocument {
        let doc = PaintDocument(width: size, height: size, fill: .white)
        var seed: UInt64 = 0x12345
        doc.context.withTopLeftOrigin { c in
            for y in stride(from: 0, to: size, by: 3) {
                for x in stride(from: 0, to: size, by: 3) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = CGFloat((seed >> 33) % 255) / 255
                    c.setFillColor(NSColor(srgbRed: n, green: 1 - n, blue: 0.4, alpha: 1).cgColor)
                    c.fill(CGRect(x: x, y: y, width: 3, height: 3))
                }
            }
        }
        doc.touch()
        return doc
    }

    private static func worstChannel(_ a: CGContext, _ b: CGContext) -> Int {
        guard a.width == b.width, a.height == b.height else { return 999 }
        var worst = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let p = a.sample(x: x, y: y), q = b.sample(x: x, y: y)
                worst = max(worst, max(abs(Int(p.r) - Int(q.r)),
                             max(abs(Int(p.g) - Int(q.g)),
                             max(abs(Int(p.b) - Int(q.b)), abs(Int(p.a) - Int(q.a))))))
            }
        }
        return worst
    }

    /// The app's way — render the selection's box — against the way it used to work:
    /// render the whole canvas and composite all of it back through the mask. Returns
    /// the worst per-channel difference over the entire canvas, so a pixel written in
    /// the wrong place counts even if the right place is also right.
    private static func sameAsWholeCanvas(_ source: CGImage, _ mask: SelectionMask,
                                          apply: (PaintDocument, SelectionMask) -> Void,
                                          whole: (CIImage) -> CIImage) -> Int {
        let region = PaintDocument(image: source)
        let full = PaintDocument(image: source)
        apply(region, mask)
        guard let filtered = CanvasFilter.render(source, whole) else { return 999 }
        full.composite(filtered, through: mask, name: "whole canvas")
        return worstChannel(region.context, full.context)
    }

    /// Blurring a 40x40 box on a 12-megapixel photograph used to cost what blurring the
    /// photograph costs: the filter ran over every pixel and the result was then thrown
    /// away everywhere the mask said no. It now renders the selection's box only, and
    /// CoreImage pulls the neighbours the Gaussian needs backwards through the graph, so
    /// the selection's edge still samples real pixels from outside it. The whole point of
    /// these checks is that the picture did not change.
    private static func filterRegionChecks() {
        let source = detailedDoc(size: 700).image

        // Deliberately awkward boxes: an origin that is a multiple of nothing, one
        // selection hard against the left edge and one in the far corner, where a region
        // render could run out of source pixels to sample.
        let boxes = [CGRect(x: 237, y: 141, width: 96, height: 63),
                     CGRect(x: 0, y: 603, width: 41, height: 97),
                     CGRect(x: 655, y: 655, width: 45, height: 45)]
        var worstBlur = 0, worstPixelate = 0, worstGray = 0
        for box in boxes {
            func mask() -> SelectionMask {
                SelectionMask(width: 700, height: 700, rect: box)
            }
            worstBlur = max(worstBlur, sameAsWholeCanvas(source, mask(),
                apply: { $0.blur(radius: 24, mask: $1) },
                whole: { CanvasFilter.blur($0, radius: 24) }))
            worstPixelate = max(worstPixelate, sameAsWholeCanvas(source, mask(),
                apply: { $0.pixelate(scale: 16, mask: $1) },
                whole: { CanvasFilter.pixelate($0, scale: 16) }))
            worstGray = max(worstGray, sameAsWholeCanvas(source, mask(),
                apply: { $0.grayscale(mask: $1) },
                whole: { CanvasFilter.grayscale($0) }))
        }
        // Pixelate and the colour filters come back byte for byte. A Gaussian does not
        // quite: CoreImage computes it in floating point and rounds at the edge of
        // whatever it was asked to produce, so a handful of pixels land one level away.
        // One level of 255 is not a difference anyone can see, and it is the same
        // tolerance the preview checks above already accept between preview and Apply.
        check("a filter on a selection is the picture it always was",
              worstPixelate == 0 && worstGray == 0 && worstBlur <= 1,
              "over three awkward selections on a 700x700 picture, the box-rendered result "
                  + "differs from the whole-canvas one by \(worstPixelate) (pixelate), "
                  + "\(worstGray) (grayscale) and \(worstBlur) (blur, floating-point rounding) "
                  + "per channel")

        // And it really is the box that gets rendered, not the canvas with the rest
        // thrown away — which is the whole reason for the exercise.
        let box = CGRect(x: 237, y: 141, width: 96, height: 63)
        let rendered = CanvasFilter.render(source, region: box) { CanvasFilter.blur($0, radius: 24) }
        let renderedPixels = (rendered?.width ?? 0) * (rendered?.height ?? 0)
        check("a filter renders the selection, not the canvas",
              rendered?.width == 96 && rendered?.height == 63,
              "a 96x63 selection on a 700x700 canvas renders \(renderedPixels) pixels "
                  + "rather than 490000")

        // Pixelate's blocks belong to the canvas, not to the region being rendered:
        // measured against real pixels, CoreImage lays its grid out from the corner of
        // the rectangle it was asked for, so a box that is not a whole number of blocks
        // used to shift the grid by the remainder — a redaction sliding off the face it
        // was covering. The region is grown to whole blocks to stop that.
        let gridDoc = detailedDoc(size: 700)
        let gridMask = SelectionMask(width: 700, height: 700,
                                     rect: CGRect(x: 237, y: 237, width: 96, height: 96))
        gridDoc.pixelate(scale: 16, mask: gridMask)
        var changes: [Int] = []
        for x in 239..<332 where gridDoc.context.sample(x: x, y: 250)
                                  != gridDoc.context.sample(x: x - 1, y: 250) {
            changes.append(x)
        }
        let onGrid = changes.allSatisfy { $0 % 16 == 0 }
        check("pixelate's blocks stay on the canvas grid",
              changes.count >= 3 && onGrid,
              "inside a selection starting at x = 237 the block edges fall at x = "
                  + changes.map(String.init).joined(separator: ", ")
                  + (onGrid ? " — all on the canvas's 16 px grid" : " — OFF the grid"))

        // The composite now takes a patch and an origin rather than a whole canvas, and
        // that arithmetic has two ways to go wrong: reading the wrong source pixel, and
        // writing past the end of the bitmap when the patch hangs over the edge.
        let offDoc = PaintDocument(width: 20, height: 20, fill: .white)
        let ramp = Bitmap.makeContext(width: 10, height: 10)
        ramp.withTopLeftOrigin { c in
            for y in 0..<10 {
                for x in 0..<10 {
                    c.setFillColor(NSColor(srgbRed: CGFloat(x) / 10, green: CGFloat(y) / 10,
                                           blue: 0.5, alpha: 1).cgColor)
                    c.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let offMask = SelectionMask(width: 20, height: 20,
                                    rect: CGRect(x: 7, y: 5, width: 3, height: 3))
        offDoc.composite(ramp.makeImage()!, at: CGPoint(x: 5, y: 3), through: offMask,
                         name: "Patch")
        // Canvas (8, 6) is patch (3, 3), because the patch's corner is at (5, 3).
        let landed = offDoc.context.sample(x: 8, y: 6)
        let expected = ramp.sample(x: 3, y: 3)
        let justOutside = offDoc.context.sample(x: 6, y: 6)
        check("a patch lands where its origin says it does",
              landed == expected && justOutside == RGBA(r: 255, g: 255, b: 255, a: 255),
              "canvas (8,6) reads \(landed) and patch (3,3) is \(expected); the pixel one "
                  + "step outside the mask is still \(justOutside)")

        // Half off the canvas: the overlap is written and nothing else is, which on a
        // stale mask is the difference between a clamp and a heap overwrite.
        let edgeDoc = PaintDocument(width: 20, height: 20, fill: .white)
        let solid = Bitmap.makeContext(width: 10, height: 10)
        solid.setFillColor(red.cgColor)
        solid.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        edgeDoc.composite(solid.makeImage()!, at: CGPoint(x: 15, y: 15), through: nil,
                          name: "Patch")
        let reds = count(in: edgeDoc) { isRed($0) }
        check("a patch hanging off the canvas is clamped",
              reds == 25 && isRed(edgeDoc.context.sample(x: 19, y: 19))
                  && !isRed(edgeDoc.context.sample(x: 14, y: 14)),
              "a 10x10 patch placed at (15,15) on a 20x20 canvas painted \(reds) pixels, "
                  + "which is the 5x5 that overlaps")
    }

    /// `CanvasFilter.render` used to end by redrawing CoreImage's output into a fresh
    /// canonical context. CoreImage had already been asked for `.RGBA8` in
    /// `paintboxColorSpace`, which IS that format, so it was a copy of the bytes onto
    /// themselves: ~65 ms and a transient 96 MB on a 6000x4000 canvas, about what the
    /// Gaussian it was normalising cost, on the one path a photograph goes through.
    ///
    /// The skip rests on an assumption — that CoreImage honours the format it is asked
    /// for — so these checks hold that assumption against real pixels rather than trust
    /// it, and prove the conversion still happens for an image that genuinely needs one.
    private static func filterFormatChecks() {
        let source = detailedDoc(size: 64).image
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)

        // Exactly what the real path produces, before anything normalises it.
        let input = CIImage(cgImage: source)
        let out = CanvasFilter.invert(input).cropped(to: input.extent)
        let raw = CanvasFilter.ciContext.createCGImage(out, from: extent, format: .RGBA8,
                                                       colorSpace: paintboxColorSpace)
        let rawIsCanonical = raw.map { Bitmap.isCanonical($0) } ?? false
        // Object identity, not equality: this is the copy being absent, not merely cheap.
        let skipped = raw.map { Bitmap.canonical($0) === $0 } ?? false
        check("a filter result is not copied onto itself",
              rawIsCanonical && skipped,
              "CoreImage's own output is "
                  + "\(raw?.bitsPerComponent ?? 0)-bit, alpha \(raw.map { "\($0.alphaInfo.rawValue)" } ?? "none"), "
                  + "\(raw?.colorSpace?.name.map { $0 as String } ?? "no colour space") — "
                  + (rawIsCanonical ? "canonical already" : "NOT canonical")
                  + ", and canonical() "
                  + (skipped ? "hands it straight back" : "redrew it"))

        // The pixels the app actually gets are still right: invert is exact, so every
        // channel must be 255 minus the source, alpha untouched.
        let rendered = CanvasFilter.render(source) { CanvasFilter.invert($0) }
        let src = Bitmap.context(from: source)
        var worst = 0
        if let rendered {
            let got = Bitmap.context(from: rendered)
            for y in stride(from: 0, to: 64, by: 3) {
                for x in stride(from: 0, to: 64, by: 3) {
                    let a = src.sample(x: x, y: y), b = got.sample(x: x, y: y)
                    worst = max(worst, abs(255 - Int(a.r) - Int(b.r)))
                    worst = max(worst, abs(255 - Int(a.g) - Int(b.g)))
                    worst = max(worst, abs(255 - Int(a.b) - Int(b.b)))
                    worst = max(worst, abs(Int(a.a) - Int(b.a)))
                }
            }
        }
        check("the uncopied filter result is still right",
              rendered != nil && Bitmap.isCanonical(rendered!) && worst <= 1,
              "inverting a 64x64 picture without the normalising copy gives pixels "
                  + "\(worst) level(s) from 255 minus the source, in canonical format")

        // An image that is NOT canonical — 8-bit grey, no alpha at all — still gets
        // converted, because `canonical` asks rather than assumes.
        let greyCtx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        greyCtx?.setFillColor(CGColor(gray: 0.5, alpha: 1))
        greyCtx?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let grey = greyCtx?.makeImage()
        let converted = grey.map { Bitmap.canonical($0) }
        let sample = converted.map { Bitmap.context(from: $0).sample(x: 4, y: 4) } ?? .clear
        check("an odd format is still converted",
              grey != nil && !Bitmap.isCanonical(grey!) && converted.map { Bitmap.isCanonical($0) } == true
                  && sample.a == 255 && sample.r == sample.g && sample.g == sample.b
                  && sample.r > 100 && sample.r < 160,
              "an 8-bit grey image with no alpha is not canonical, and canonical() turns "
                  + "it into RGBA \(sample)")
    }

    /// The marching ants used to repaint the whole window eight times a second — the
    /// photograph, the checkerboard, everything — in order to move a dotted line by one
    /// pixel, and to go on firing after the window had closed. Both are state rather than
    /// timing: how much of the view a frame dirties, and whether the timer exists.
    private static func antsRedrawChecks() {
        let doc = PaintDocument(width: 2000, height: 1500, fill: .white)
        let controller = PaintWindowController(document: doc)
        let canvas = controller.canvas!
        let selected = CGRect(x: 100, y: 100, width: 80, height: 60)
        canvas.setSelection(rect: selected)
        let refresh = canvas.antsRefreshRect
        let outline = canvas.viewRect(forImageRect: selected)
        let viewArea = canvas.bounds.width * canvas.bounds.height
        let share = viewArea > 0 ? (refresh.width * refresh.height) / viewArea : 1
        check("an ants frame repaints the outline, not the picture",
              canvas.isAnimating && refresh.contains(outline) && share < 0.01,
              "an 80x60 selection on a 2000x1500 canvas dirties \(describe(refresh)) — "
                  + String(format: "%.2f%%", share * 100) + " of the view — and it does "
                  + "contain the outline at \(describe(outline))")

        // A floating item's grab handles hang outside its own frame, so the box that is
        // repainted has to be bigger than the box that is drawn.
        let badge = Bitmap.makeContext(width: 40, height: 30)
        badge.setFillColor(blue.cgColor)
        badge.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 500, y: 500))
        let withFloat = canvas.antsRefreshRect
        let floatBox = canvas.viewRect(forImageRect: canvas.floatingFrame ?? .zero)
        let pad = FloatingItem.handleViewSize / 2
        check("the floating handles are inside the repainted box",
              withFloat.contains(floatBox.insetBy(dx: -pad, dy: -pad))
                  && withFloat.contains(outline),
              "the repainted box \(describe(withFloat)) covers the item at "
                  + "\(describe(floatBox)) with its \(Int(FloatingItem.handleViewSize)) pt "
                  + "handles, and the selection outline too")

        // Closing the window has to stop the clock. The timer is owned by the run loop,
        // not by the view, so nothing else will ever let go of it.
        let animatingBefore = canvas.isAnimating
        controller.window?.close()
        check("a closed window stops the ants",
              animatingBefore && !canvas.isAnimating,
              "the timer was \(animatingBefore ? "running" : "ALREADY OFF") with a selection "
                  + "on screen and is \(canvas.isAnimating ? "STILL RUNNING" : "gone") after "
                  + "the window closed")

        // And the other way out of a window, which no teardown path covers: the view is
        // simply removed. This is why the rule lives in the view rather than in the
        // controller that happens to close first.
        let doc2 = PaintDocument(width: 400, height: 300, fill: .white)
        let controller2 = PaintWindowController(document: doc2)
        let canvas2 = controller2.canvas!
        canvas2.selectAllPixels()
        let running2 = canvas2.isAnimating
        canvas2.removeFromSuperview()
        check("a canvas taken out of its window stops the ants",
              running2 && !canvas2.isAnimating,
              "with a selection the timer was \(running2 ? "running" : "ALREADY OFF"); once "
                  + "the view left the window it was "
                  + "\(canvas2.isAnimating ? "STILL RUNNING" : "gone")")
        controller2.window?.close()
    }

    /// Undo is whole-canvas snapshots, so the stack's depth has to shrink as the picture
    /// grows — and a depth of six on a photograph is something to say out loud rather
    /// than something the user discovers when the seventh press of Cmd-Z does nothing.
    private static func undoNoteChecks() {
        let small = UndoBudget.note(width: 1024, height: 768)
        let photo = UndoBudget.note(width: 6000, height: 4000)
        check("a shortened undo stack says so",
              small == nil && (photo?.contains("\(UndoBudget.fewest) steps") ?? false),
              "a 1024x768 canvas is at full depth so it says \(small ?? "nothing"); "
                  + "6000x4000 says \"\(photo ?? "NOTHING")\"")
    }

    // MARK: - The interface promising one thing and doing another

    private static func uxChecks(tmp: URL) {
        selectionContainsPaintChecks()
        floatingHandleChecks()
        floatingReachChecks()
        textPlacementChecks()
        textEditorFocusLossChecks()
        zoomAnchorChecks()
        zoomShortcutChecks()
        deadUndoChecks(tmp: tmp)
        commandValidationChecks()
        toolbarFitChecks()
        cropToShapeChecks()
        interfaceLabelChecks()
        recentDocumentsChecks()
        pasteValidationChecks()
        lazyCopyChecks()
        pasteGuidanceChecks()
        orphanedDragChecks()
        eyedropperHoleChecks()
        droppedFileChecks(tmp: tmp)
        screenshotWriteChecks(tmp: tmp)
        closeFlowChecks(tmp: tmp)
    }

    // ---- A dropped file that will not decode --------------------------------

    /// The drop route accepts anything whose content type conforms to `.image`, so a
    /// zero-byte or garbage file shows the copy cursor and has its drop accepted — and
    /// then used to end in a bare `return false`: nothing happened and nothing was said,
    /// while the very same file through File ▸ Open said "Paintbox could not read X."
    private static func droppedFileChecks(tmp: URL) {
        let doc = PaintDocument(width: 60, height: 40, fill: .white)
        let canvas = CanvasView(document: doc, settings: ToolSettings())

        // Two files that really do defeat `Bitmap.load`, written here rather than assumed.
        let zero = tmp.appendingPathComponent("zero.png")
        FileManager.default.createFile(atPath: zero.path, contents: Data())
        let garbage = tmp.appendingPathComponent("garbage.png")
        try? Data("this is text, not a picture".utf8).write(to: garbage)

        let zeroSaid = canvas.acceptDrop(url: zero, at: CGPoint(x: 30, y: 20))
        let garbageSaid = canvas.acceptDrop(url: garbage, at: CGPoint(x: 30, y: 20))
        let nothingSaid = canvas.acceptDrop(url: nil, at: CGPoint(x: 30, y: 20))
        let floatedAfterFailure = canvas.hasFloatingItem

        // A picture that does decode still lands, under the pointer, with its own pixels.
        let good = tmp.appendingPathComponent("dropped.png")
        let stripe = squareDoc(size: 20, rects: [CGRect(x: 0, y: 0, width: 20, height: 10)])
        try? Bitmap.write(stripe.image, to: good, format: .png)
        let goodSaid = canvas.acceptDrop(url: good, at: CGPoint(x: 30, y: 20))
        let frame = canvas.floatingFrame
        canvas.commitFloating()
        // Centred on (30,20), so the 20x20 stripe covers 20...40 across and 10...30 down:
        // its red top half lands at y 15, its white bottom half at y 25.
        let top = doc.context.sample(x: 30, y: 15)
        let bottom = doc.context.sample(x: 30, y: 25)
        let outside = doc.context.sample(x: 2, y: 2)

        check("an undecodable drop says so instead of nothing",
              zeroSaid == .unreadable("zero.png") && garbageSaid == .unreadable("garbage.png")
                  && nothingSaid == .notAnImageFile && !floatedAfterFailure
                  && goodSaid == .placed && frame == CGRect(x: 20, y: 10, width: 20, height: 20)
                  && isRed(top) && bottom.r == 255 && bottom.g == 255 && outside.r == 255,
              "zero bytes -> \(zeroSaid), garbage -> \(garbageSaid), no file -> \(nothingSaid), "
                  + "and nothing floated; a real PNG -> \(goodSaid) at "
                  + "\(frame.map(describe) ?? "NOWHERE"), red half \(top), white half \(bottom)")
    }

    // ---- --screenshot must not claim a file it failed to write ---------------

    /// `--screenshot` is the only way to see the interface on a machine where
    /// `screencapture` returns black, so a swallowed write error is worse than useless:
    /// the caller reads "wrote <path>" and goes on inspecting a stale PNG from an earlier
    /// run at the same path, believing it is looking at today's build.
    private static func screenshotWriteChecks(tmp: URL) {
        let rep = NSBitmapImageRep(cgImage: squareDoc(size: 16,
                                                      rects: [CGRect(x: 0, y: 0, width: 8, height: 16)]).image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            check("--screenshot admits a write it could not do", false, "could not make a PNG to write")
            return
        }
        let bad = "/no/such/dir/paintbox-shot.png"
        let badSaid = WindowShot.writePNG(png, to: bad)
        let badExists = FileManager.default.fileExists(atPath: bad)

        let goodURL = tmp.appendingPathComponent("shot.png")
        let goodSaid = WindowShot.writePNG(png, to: goodURL.path)
        let back = Bitmap.load(url: goodURL).map { Bitmap.context(from: $0) }
        let left = back?.sample(x: 2, y: 8) ?? .clear
        let right = back?.sample(x: 13, y: 8) ?? .clear

        check("--screenshot admits a write it could not do",
              badSaid?.contains(bad) == true && !badExists && goodSaid == nil
                  && back?.width == 16 && isRed(left) && right.r == 255 && right.a == 255,
              "an unwritable path reports \"\(badSaid ?? "NOTHING")\" and leaves no file; "
                  + "a good path reports \(goodSaid ?? "success") and reads back "
                  + "\(back.map { "\($0.width)x\($0.height)" } ?? "NOTHING") with halves \(left) / \(right)")
    }

    /// How many pixels INSIDE the mask changed. The other half of
    /// `differencesOutside`: a tool clipped to the selection has to have painted
    /// something, or the check would pass on a tool that does nothing at all.
    private static func differencesInside(_ mask: SelectionMask, before: CGImage,
                                          after: CGContext) -> Int {
        let b = Bitmap.context(from: before)
        var diff = 0
        for y in 0..<after.height {
            for x in 0..<after.width where mask.contains(x: x, y: y) {
                if b.sample(x: x, y: y) != after.sample(x: x, y: y) { diff += 1 }
            }
        }
        return diff
    }

    /// The bounding box of every pixel `isInk` accepts, in top-left coordinates.
    private static func inkBox(_ ctx: CGContext, _ isInk: (RGBA) -> Bool) -> CGRect {
        var minX = ctx.width, minY = ctx.height, maxX = -1, maxY = -1
        for y in 0..<ctx.height {
            for x in 0..<ctx.width where isInk(ctx.sample(x: x, y: y)) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // ---- The painting tools stay inside the marching ants -------------------

    /// Filters and Delete have always respected the selection and the painting tools did
    /// not, so a selection made to protect the rest of the picture protected it from
    /// half the app. These drive the REAL mouse path — `begin`, `moveTo`, `end` — so the
    /// wiring is checked along with the clip.
    private static func selectionContainsPaintChecks() {
        let box = CGRect(x: 20, y: 20, width: 20, height: 20)

        /// A white canvas with `box` selected, and a tool set up ready to drag.
        func staged(_ tool: Tool) -> (PaintDocument, CanvasView, SelectionMask, CGImage) {
            let doc = PaintDocument(width: 80, height: 60, fill: .white)
            let settings = ToolSettings()
            settings.tool = tool
            settings.foreground = red
            // The shape tools fill with the BACKGROUND colour, so it has to differ from
            // the paper or a filled rectangle would be invisible rather than clipped.
            settings.background = blue
            settings.shapeStyle = .filled
            let canvas = CanvasView(document: doc, settings: settings)
            canvas.setSelection(rect: box)
            return (doc, canvas, canvas.selection!, doc.image)
        }

        // A brush dragged clean across the picture.
        let (brushDoc, brushCanvas, brushMask, brushBefore) = staged(.brush)
        brushCanvas.begin(.init(point: CGPoint(x: 2, y: 30)))
        for x in stride(from: 6, through: 78, by: 4) {
            brushCanvas.moveTo(.init(point: CGPoint(x: CGFloat(x), y: 30)))
        }
        brushCanvas.end(.init(point: CGPoint(x: 78, y: 30)))
        let brushOut = differencesOutside(brushMask, before: brushBefore, after: brushDoc.context)
        let brushIn = differencesInside(brushMask, before: brushBefore, after: brushDoc.context)
        check("a brush stroke stays in the selection",
              brushOut == 0 && brushIn > 100,
              "a stroke across the whole 80x60 canvas changed \(brushIn) px inside the "
                  + "20x20 selection and \(brushOut) px outside it")

        // The pencil writes bytes rather than drawing through CoreGraphics, so it is
        // confined by a test per pixel and has to be checked separately.
        let (pencilDoc, pencilCanvas, pencilMask, pencilBefore) = staged(.pencil)
        pencilCanvas.begin(.init(point: CGPoint(x: 0, y: 0)))
        pencilCanvas.moveTo(.init(point: CGPoint(x: 79, y: 59)))
        pencilCanvas.end(.init(point: CGPoint(x: 79, y: 59)))
        let pencilOut = differencesOutside(pencilMask, before: pencilBefore, after: pencilDoc.context)
        let pencilIn = differencesInside(pencilMask, before: pencilBefore, after: pencilDoc.context)
        check("the pencil stays in the selection",
              pencilOut == 0 && pencilIn > 10,
              "a corner-to-corner line changed \(pencilIn) px inside the selection "
                  + "and \(pencilOut) px outside it")

        // A filled rectangle bigger than the selection.
        let (rectDoc, rectCanvas, rectMask, rectBefore) = staged(.rectangle)
        rectCanvas.begin(.init(point: CGPoint(x: 4, y: 4)))
        rectCanvas.moveTo(.init(point: CGPoint(x: 76, y: 56)))
        rectCanvas.end(.init(point: CGPoint(x: 76, y: 56)))
        let rectOut = differencesOutside(rectMask, before: rectBefore, after: rectDoc.context)
        let rectIn = differencesInside(rectMask, before: rectBefore, after: rectDoc.context)
        check("a filled shape stays in the selection",
              rectOut == 0 && rectIn == 400,
              "a 72x52 filled rectangle changed \(rectIn) of the selection's 400 px "
                  + "and \(rectOut) px outside it")

        // The fill is a flood, so the selection has to be a wall it cannot cross —
        // colour carries on past the ants, and a click outside has nowhere to spread.
        let (fillDoc, fillCanvas, fillMask, fillBefore) = staged(.bucket)
        fillCanvas.begin(.init(point: CGPoint(x: 25, y: 25)))
        let fillOut = differencesOutside(fillMask, before: fillBefore, after: fillDoc.context)
        let fillIn = differencesInside(fillMask, before: fillBefore, after: fillDoc.context)
        let filled = checksum(fillDoc.context)
        fillCanvas.begin(.init(point: CGPoint(x: 70, y: 50)))
        check("a fill cannot leak out of the selection",
              fillOut == 0 && fillIn == 400 && checksum(fillDoc.context) == filled,
              "a click inside filled \(fillIn) of the selection's 400 px and changed "
                  + "\(fillOut) px outside it; a second click outside the selection "
                  + "\(checksum(fillDoc.context) == filled ? "changed nothing" : "PAINTED")")

        // Text was the last tool still painting wherever it liked. It goes through its
        // own commit rather than a drag, so the wiring is checked from the editor down:
        // a line long enough to cross the whole canvas, typed from outside the ants.
        func typed(selection: CGRect?) -> (inside: Int, outside: Int, mask: SelectionMask) {
            let doc = PaintDocument(width: 80, height: 60, fill: .white)
            let settings = ToolSettings()
            settings.tool = .text
            settings.foreground = red
            settings.font = NSFont.systemFont(ofSize: 22)
            let canvas = CanvasView(document: doc, settings: settings)
            // The mask the pixels are judged against is always `box`, so the unselected
            // run and the selected one are measured on exactly the same region.
            let judge = SelectionMask(width: 80, height: 60, rect: box)
            if let selection { canvas.setSelection(rect: selection) }
            let before = doc.image
            canvas.begin(.init(point: CGPoint(x: 6, y: 18)))
            canvas.editingTextField?.stringValue = "MMMMMMMM"
            canvas.commitTextIfEditing()
            return (differencesInside(judge, before: before, after: doc.context),
                    differencesOutside(judge, before: before, after: doc.context),
                    judge)
        }

        // Unselected first, so the check below is known to be measuring a clip and not a
        // string that happened to miss the box.
        let looseText = typed(selection: nil)
        let clippedText = typed(selection: box)
        check("typed text stays in the selection",
              looseText.outside > 50 && looseText.inside > 10
                  && clippedText.outside == 0 && clippedText.inside == looseText.inside,
              "the same line typed across the canvas marked \(looseText.inside) px inside "
                  + "the 20x20 selection and \(looseText.outside) px outside it with nothing "
                  + "selected; with the selection made it marked \(clippedText.inside) inside "
                  + "and \(clippedText.outside) outside")

        // And with nothing selected a tool still reaches the whole canvas.
        let freeDoc = PaintDocument(width: 40, height: 40, fill: .white)
        let freeSettings = ToolSettings()
        freeSettings.tool = .bucket
        freeSettings.foreground = blue
        let freeCanvas = CanvasView(document: freeDoc, settings: freeSettings)
        freeCanvas.begin(.init(point: CGPoint(x: 20, y: 20)))
        check("nothing selected still means everywhere",
              count(in: freeDoc, where: isBlue) == 1600,
              "a fill with no selection covered \(count(in: freeDoc, where: isBlue)) of 1600 px")
    }

    // ---- A resize handle dragged past the opposite corner ------------------

    private static func floatingHandleChecks() {
        let stamp = Bitmap.makeContext(width: 40, height: 30)
        stamp.setFillColor(green.cgColor)
        stamp.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let img = stamp.makeImage()!

        // Crossing in both axes at once: the anchor is the top-left corner throughout,
        // so the item grows back out mirrored rather than collapsing and then sliding
        // after the pointer.
        let item = FloatingItem(image: img, at: CGPoint(x: 100, y: 100))
        let anchor = item.anchor(for: .bottomRight)
        item.resize(to: CGPoint(x: 100, y: 100), anchor: anchor, keepAspect: false)
        let collapsed = item.frame
        item.resize(to: CGPoint(x: 60, y: 70), anchor: anchor, keepAspect: false)
        let crossed = item.frame
        item.resize(to: CGPoint(x: 20, y: 50), anchor: anchor, keepAspect: false)
        let further = item.frame
        check("a handle dragged past the far corner",
              collapsed == CGRect(x: 100, y: 100, width: 1, height: 1)
                  && crossed == CGRect(x: 60, y: 70, width: 40, height: 30)
                  && further == CGRect(x: 20, y: 50, width: 80, height: 50),
              "dragged onto the anchor at (\(Int(anchor.x)), \(Int(anchor.y))) it is "
                  + "\(describe(collapsed)); 40x30 past it \(describe(crossed)); dragged "
                  + "on to (20,50) \(describe(further))")

        // One axis at a time, which is the easier drag to do by accident.
        let acrossX = FloatingItem(image: img, at: CGPoint(x: 0, y: 0))
        acrossX.resize(to: CGPoint(x: -25, y: 30), anchor: acrossX.anchor(for: .bottomRight),
                       keepAspect: false)
        let acrossY = FloatingItem(image: img, at: CGPoint(x: 0, y: 0))
        acrossY.resize(to: CGPoint(x: 40, y: -20), anchor: acrossY.anchor(for: .bottomRight),
                       keepAspect: false)
        check("crossing one axis flips rather than collapses",
              acrossX.frame == CGRect(x: -25, y: 0, width: 25, height: 30)
                  && acrossY.frame == CGRect(x: 0, y: -20, width: 40, height: 20),
              "left past the anchor gives \(describe(acrossX.frame)); up past it gives "
                  + "\(describe(acrossY.frame))")
    }

    // ---- A floating paste dragged off the canvas ---------------------------

    private static func floatingReachChecks() {
        let doc = PaintDocument(width: 120, height: 90, fill: .white)
        let settings = ToolSettings()
        let canvas = CanvasView(document: doc, settings: settings)
        let badge = Bitmap.makeContext(width: 40, height: 30)
        badge.setFillColor(blue.cgColor)
        badge.fill(CGRect(x: 0, y: 0, width: 40, height: 30))

        /// Grab the middle of the item and drag it to `to`, then report what is left on
        /// the canvas and whether a corner handle came with it.
        func drag(to p: CGPoint) -> (overlap: CGRect, handleOnCanvas: Bool, frame: CGRect) {
            canvas.cancelFloating()
            canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 40, y: 30))
            let grab = canvas.floatingFrame!
            canvas.begin(.init(point: CGPoint(x: grab.midX, y: grab.midY)))
            canvas.moveTo(.init(point: p))
            canvas.end(.init(point: p))
            let f = canvas.floatingFrame ?? .null
            let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                           CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
            return (f.intersection(doc.bounds), corners.contains { doc.bounds.contains($0) }, f)
        }

        let keep = CanvasView.floatingMinVisible
        let offTopLeft = drag(to: CGPoint(x: -400, y: -300))
        let offBottomRight = drag(to: CGPoint(x: 900, y: 700))
        check("a paste dragged off the canvas stays reachable",
              offTopLeft.overlap.width >= keep && offTopLeft.overlap.height >= keep
                  && offTopLeft.handleOnCanvas
                  && offBottomRight.overlap.width >= keep && offBottomRight.overlap.height >= keep
                  && offBottomRight.handleOnCanvas,
              "dragged to (-400,-300) it sits at \(describe(offTopLeft.frame)) with "
                  + "\(describe(offTopLeft.overlap)) on the canvas; dragged to (900,700) "
                  + "at \(describe(offBottomRight.frame)) with "
                  + "\(describe(offBottomRight.overlap))")
        canvas.cancelFloating()
    }

    // ---- Text lands where it was typed ------------------------------------

    private static func textPlacementChecks() {
        let doc = PaintDocument(width: 220, height: 120, fill: .white)
        let settings = ToolSettings()
        settings.tool = .text
        settings.foreground = red
        settings.font = NSFont.systemFont(ofSize: 28)
        let canvas = CanvasView(document: doc, settings: settings)
        let click = CGPoint(x: 30, y: 24)
        canvas.begin(.init(point: click))
        guard let field = canvas.editingTextField else {
            check("text lands where it was typed", false, "the text tool opened no editor")
            return
        }
        field.stringValue = "Hg"

        // Where the editor SHOWS the text, in image pixels: the field's cell rendered
        // into a bitmap of its own size, plus the field's position in the view. The view
        // is at 100%, so view points and image pixels are the same thing here.
        let fw = Int(field.bounds.width.rounded(.up)), fh = Int(field.bounds.height.rounded(.up))
        let fieldCtx = Bitmap.makeContext(width: fw, height: fh)
        fieldCtx.setFillColor(NSColor.white.cgColor)
        fieldCtx.fill(CGRect(x: 0, y: 0, width: fw, height: fh))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: fieldCtx, flipped: false)
        field.cell?.draw(withFrame: field.bounds, in: field)
        NSGraphicsContext.restoreGraphicsState()
        // The border is grey, so "mostly red" finds the glyphs and not the box.
        let shownInField = inkBox(fieldCtx) { $0.r > 120 && $0.g < 90 && $0.b < 90 }
        let shown = shownInField.offsetBy(dx: field.frame.minX, dy: field.frame.minY)

        canvas.commitTextIfEditing()
        let drawn = inkBox(doc.context) { $0.r > 120 && $0.g < 90 && $0.b < 90 }
        let dx = abs(shown.minX - drawn.minX), dy = abs(shown.minY - drawn.minY)
        check("text lands where it was typed",
              !shown.isNull && !drawn.isNull && dx <= 1 && dy <= 1
                  && abs(shown.width - drawn.width) <= 2 && abs(shown.height - drawn.height) <= 2,
              "the editor showed \"Hg\" at \(describe(shown)) and the commit drew it at "
                  + "\(describe(drawn)) — off by \(Int(dx)), \(Int(dy))")
    }

    // ---- A text box the keyboard walked away from ---------------------------

    /// An NSTextField sends its action on Return and on nothing else. Every other way an
    /// edit ends — clicking a slider in the palette, another window coming forward — used
    /// to leave the editor sitting on the canvas holding text that would never be drawn,
    /// and swallowing every single-key shortcut for as long as it sat there. Two routes
    /// are checked, because they are fixed by two different things: focus moving to a
    /// control that takes the keyboard, and a palette swatch, which does not.
    private static func textEditorFocusLossChecks() {
        // 1. The keyboard goes somewhere else with text in the box. AppKit reports that
        //    as end-of-editing with a movement of "other"; the window in a self-test can
        //    never be key, so the notification is delivered here the way AppKit delivers
        //    it, and the wiring that makes AppKit deliver it is checked alongside.
        let doc = PaintDocument(width: 200, height: 80, fill: .white)
        let controller = PaintWindowController(document: doc)
        controller.settings.tool = .text
        controller.settings.foreground = red
        controller.settings.font = NSFont.systemFont(ofSize: 24)
        let canvas = controller.canvas!
        canvas.begin(.init(point: CGPoint(x: 10, y: 20)))
        let opened = canvas.isEditingText
        let field = canvas.editingTextField
        let wired = field?.delegate === canvas
        field?.stringValue = "Hg"
        if let field {
            canvas.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field,
                             userInfo: ["NSTextMovement": NSTextMovement.other.rawValue]))
        }
        let drawn = inkBox(doc.context) { $0.r > 120 && $0.g < 90 && $0.b < 90 }
        check("a text box commits when the keyboard leaves it",
              opened && wired && !canvas.isEditingText && field?.superview == nil && !drawn.isNull,
              "the editor \(opened ? "opened" : "NEVER OPENED") \(wired ? "as the canvas's own delegate" : "WITH NO DELEGATE"); "
                  + "it is \(canvas.isEditingText ? "STILL OPEN" : "gone") and the field is "
                  + "\(field?.superview == nil ? "off the canvas" : "STILL A SUBVIEW"); the typed "
                  + "text was drawn at \(drawn.isNull ? "NOWHERE" : describe(drawn))")

        // Return is the field's own action, which commits and takes the keyboard back
        // from outside the responder swap. This notification must leave that alone rather
        // than commit from inside it.
        canvas.begin(.init(point: CGPoint(x: 10, y: 20)))
        canvas.editingTextField?.stringValue = "Hg"
        if let second = canvas.editingTextField {
            canvas.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: second,
                             userInfo: ["NSTextMovement": NSTextMovement.return.rawValue]))
        }
        check("Return leaves the commit to the field's own action",
              canvas.isEditingText,
              "after a Return notification the editor is "
                  + "\(canvas.isEditingText ? "still there for the action to commit" : "ALREADY GONE")")
        canvas.cancelTextIfEditing()
        controller.window?.close()
        PaintboxApp.shared.forget(controller)

        // 2. A palette swatch, which never takes the keyboard, so nothing about the field
        //    can notice it on its own. The palette has to say so.
        let doc2 = PaintDocument(width: 200, height: 80, fill: .white)
        let controller2 = PaintWindowController(document: doc2)
        controller2.settings.tool = .text
        controller2.settings.foreground = red
        controller2.settings.font = NSFont.systemFont(ofSize: 24)
        let canvas2 = controller2.canvas!
        canvas2.begin(.init(point: CGPoint(x: 10, y: 20)))
        canvas2.editingTextField?.stringValue = "Hg"
        let openedBefore = canvas2.isEditingText
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        var swatchFound = false
        if let content = controller2.window?.contentView, let swatch = firstSwatch(in: content) {
            swatchFound = true
            swatch.onLeft?(blue)
        }
        // Red, not blue: the commit happens BEFORE the new colour lands, so what was typed
        // is drawn in the colour it was typed in.
        let drawn2 = inkBox(doc2.context) { $0.r > 120 && $0.g < 90 && $0.b < 90 }
        let fg = controller2.settings.foreground.usingColorSpace(.sRGB)
        let colourTook = (fg?.blueComponent ?? 0) > 0.9 && (fg?.redComponent ?? 1) < 0.1
        check("a palette swatch settles a text box before it changes the colour",
              swatchFound && openedBefore && !canvas2.isEditingText && !drawn2.isNull && colourTook,
              "the palette \(swatchFound ? "offered a swatch" : "HAS NO SWATCH"); the editor was "
                  + "\(openedBefore ? "open" : "MISSING") and "
                  + "\(canvas2.isEditingText ? "IS STILL OPEN" : "is gone"); the text was drawn in "
                  + "the old colour at \(drawn2.isNull ? "NOWHERE" : describe(drawn2)); the new "
                  + "colour \(colourTook ? "took" : "DID NOT TAKE")")
        controller2.window?.close()
        PaintboxApp.shared.forget(controller2)
    }

    /// The first colour swatch anywhere under `view`, however the palette is nested.
    private static func firstSwatch(in view: NSView) -> SwatchButton? {
        if let s = view as? SwatchButton { return s }
        for sub in view.subviews {
            if let s = firstSwatch(in: sub) { return s }
        }
        return nil
    }

    // ---- Zooming keeps its place -------------------------------------------

    private static func zoomAnchorChecks() {
        let doc = PaintDocument(width: 2000, height: 1500, fill: .white)
        let controller = PaintWindowController(document: doc)
        let canvas = controller.canvas!
        guard let scroll = canvas.enclosingScrollView else {
            check("a zoom step keeps the visible centre", false, "the canvas has no scroll view")
            return
        }
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 600, y: 500))
        scroll.reflectScrolledClipView(clip)
        let before = canvas.visibleImageRect
        canvas.stepZoom(2)
        let after = canvas.visibleImageRect
        let dx = abs(before.midX - after.midX), dy = abs(before.midY - after.midY)
        check("a zoom step keeps the visible centre",
              canvas.zoom == 2 && before.width > 100 && after.width < before.width
                  && dx <= 1 && dy <= 1,
              "scrolled to the middle of a 2000x1500 picture the view showed "
                  + "\(describe(before)); at \(Int(canvas.zoom * 100))% it shows "
                  + "\(describe(after)) — the centre moved \(Int(dx)), \(Int(dy)) px")

        // Zooming about the pointer holds THAT point still instead.
        let pointer = CGPoint(x: after.minX + 40, y: after.minY + 30)
        let atPointerBefore = pointer
        canvas.setZoom(4, keeping: pointer)
        let shown = canvas.visibleImageRect
        let heldStill = shown.contains(atPointerBefore)
        check("zooming about a point holds that point",
              canvas.zoom == 4 && heldStill,
              "at 400% the view shows \(describe(shown)), which "
                  + "\(heldStill ? "still contains" : "HAS LOST") the point it was told to hold")
        controller.window?.close()
        PaintboxApp.shared.forget(controller)
    }

    // ---- Zoom In has to answer the key people press ------------------------

    private static func zoomShortcutChecks() {
        PaintboxApp.shared.buildMenus()
        let viewMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
        let items = viewMenu?.items.filter { $0.action == #selector(PaintWindowController.zoomIn(_:)) } ?? []

        // Re-armed on a throwaway menu with a target we can watch: the real items go
        // through the responder chain and there is no key window out here.
        final class Hit: NSObject {
            var fired: [String] = []
            @objc func hit(_ sender: NSMenuItem?) { fired.append(sender?.keyEquivalent ?? "?") }
        }
        let watcher = Hit()
        let probe = NSMenu()
        for item in items {
            let copy = NSMenuItem(title: item.title, action: #selector(Hit.hit(_:)),
                                  keyEquivalent: item.keyEquivalent)
            copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
            // Copied as it is: a hidden item still has to answer its key equivalent,
            // which is the whole point of the twin.
            copy.isHidden = item.isHidden
            copy.target = watcher
            probe.addItem(copy)
        }
        func press(_ chars: String, _ mods: NSEvent.ModifierFlags) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: 24) else { return false }
            return probe.performKeyEquivalent(with: e)
        }
        // Shift-equals is what a plus IS on a Mac keyboard, so that event carries "+";
        // ⌘= carries "=" and nothing was listening for it.
        let plus = press("+", [.command, .shift])
        let equals = press("=", [.command])
        check("Zoom In answers both keys for it",
              plus && equals && watcher.fired.count == 2,
              "⌘+ \(plus ? "fired" : "DID NOTHING") and ⌘= \(equals ? "fired" : "DID NOTHING"); "
                  + "the View menu offers \(items.count) Zoom In item(s) keyed "
                  + "\(items.map { $0.keyEquivalent }.joined(separator: " and "))")
    }

    // ---- An operation that changes nothing must cost nothing ----------------
    //
    // Every check below is an operation that did all its bookkeeping before finding out
    // it had nothing to do: an undo step that restores what is already there, and a
    // document that then offers to save a file identical to the one on disk. "Nothing
    // happened" has to include the undo stack and the dirty flag, or the app is lying
    // about the user's work in the two places they look for it.

    private static func deadUndoChecks(tmp: URL) {

        // --- A click with the arrow tool -------------------------------------
        //
        // A zero-length arrow has no direction to point in, so Painter.arrow draws
        // nothing — but undo was registered and the document dirtied first.
        let arrowDoc = PaintDocument(width: 64, height: 64, fill: .white)
        let arrowUndo = freshUndo(arrowDoc)
        let arrowSettings = ToolSettings()
        arrowSettings.tool = .arrow
        arrowSettings.foreground = red
        arrowSettings.strokeWidth = 3
        let arrowCanvas = CanvasView(document: arrowDoc, settings: arrowSettings)
        let blank = checksum(arrowDoc.context)
        arrowCanvas.begin(.init(point: CGPoint(x: 32, y: 32)))
        arrowCanvas.end(.init(point: CGPoint(x: 32, y: 32)))
        check("clicking the arrow tool costs nothing",
              !arrowUndo.canUndo && !arrowDoc.isDirty && checksum(arrowDoc.context) == blank,
              "after a click with no drag: undo stack \(arrowUndo.canUndo ? "OFFERS \(arrowUndo.undoActionName)" : "empty"), "
                  + "document \(arrowDoc.isDirty ? "DIRTY" : "clean"), pixels "
                  + "\(checksum(arrowDoc.context) == blank ? "untouched" : "CHANGED")")

        // ...and a real drag still registers one, or the guard above has gone too far.
        arrowCanvas.begin(.init(point: CGPoint(x: 8, y: 32)))
        arrowCanvas.moveTo(.init(point: CGPoint(x: 56, y: 32)))
        arrowCanvas.end(.init(point: CGPoint(x: 56, y: 32)))
        let drewArrow = checksum(arrowDoc.context) != blank
        check("...but dragging one is undoable",
              drewArrow && arrowUndo.canUndo && arrowUndo.undoActionName == "Arrow" && arrowDoc.isDirty,
              "a 48 px drag \(drewArrow ? "drew" : "DREW NOTHING") and offers "
                  + "\"\(arrowUndo.undoActionName)\"; document \(arrowDoc.isDirty ? "dirty" : "CLEAN")")

        // --- Adjustments, opened and OK'd without moving a slider ------------
        //
        // CIColorControls at brightness 0, contrast 1, saturation 1 hands back its own
        // input. The filter could not know that until it had rendered, and it registered
        // undo before it looked.
        let adjDoc = squareDoc(size: 48, rects: [CGRect(x: 4, y: 4, width: 20, height: 20)])
        let adjUndo = freshUndo(adjDoc)
        let adjBefore = checksum(adjDoc.context)
        adjDoc.adjustColors(brightness: 0, contrast: 1, saturation: 1, mask: nil)
        check("a neutral Adjustments costs nothing",
              !adjUndo.canUndo && !adjDoc.isDirty && checksum(adjDoc.context) == adjBefore,
              "undo stack \(adjUndo.canUndo ? "OFFERS \(adjUndo.undoActionName)" : "empty"), "
                  + "document \(adjDoc.isDirty ? "DIRTY" : "clean"), pixels "
                  + "\(checksum(adjDoc.context) == adjBefore ? "untouched" : "CHANGED")")

        // Grayscale twice: the second pass has nothing left to take the colour out of,
        // which is the same defect wearing a different filter.
        adjDoc.grayscale(mask: nil)
        let greyOnce = checksum(adjDoc.context)
        adjDoc.grayscale(mask: nil)
        adjUndo.undo()
        check("running Grayscale twice is one undo step",
              checksum(adjDoc.context) == adjBefore && !adjUndo.canUndo,
              "one ⌘Z after two Grayscales \(checksum(adjDoc.context) == adjBefore ? "restored the colour" : "DID NOT restore the colour")"
                  + "; the stack is \(adjUndo.canUndo ? "STILL NOT EMPTY" : "empty")"
                  + " (grey checksum \(greyOnce))")

        // ...and a slider that was actually moved still registers.
        let realDoc = squareDoc(size: 48, rects: [CGRect(x: 4, y: 4, width: 20, height: 20)])
        let realUndo = freshUndo(realDoc)
        realDoc.adjustColors(brightness: 0.3, contrast: 1, saturation: 1, mask: nil)
        check("...but a moved slider is undoable",
              realUndo.canUndo && realUndo.undoActionName == "Adjustments" && realDoc.isDirty,
              "brightness +0.3 offers \(realUndo.canUndo ? "\"\(realUndo.undoActionName)\"" : "NOTHING")"
                  + "; document \(realDoc.isDirty ? "dirty" : "CLEAN")")

        // --- Select All, then Crop to Selection ------------------------------
        let cropDoc = squareDoc(size: 40, rects: [CGRect(x: 2, y: 2, width: 10, height: 10)])
        let cropUndo = freshUndo(cropDoc)
        let cropBefore = checksum(cropDoc.context)
        cropDoc.crop(to: cropDoc.bounds)
        check("cropping to the whole canvas costs nothing",
              !cropUndo.canUndo && !cropDoc.isDirty && cropDoc.pixelWidth == 40
                  && checksum(cropDoc.context) == cropBefore,
              "the canvas is still \(cropDoc.pixelWidth)x\(cropDoc.pixelHeight); "
                  + "undo stack \(cropUndo.canUndo ? "OFFERS \(cropUndo.undoActionName)" : "empty"), "
                  + "document \(cropDoc.isDirty ? "DIRTY" : "clean")")

        cropDoc.crop(to: CGRect(x: 0, y: 0, width: 20, height: 40))
        check("...but a real crop is undoable",
              cropDoc.pixelWidth == 20 && cropUndo.canUndo && cropDoc.isDirty,
              "cropped to \(cropDoc.pixelWidth)x\(cropDoc.pixelHeight); offers "
                  + "\(cropUndo.canUndo ? "\"\(cropUndo.undoActionName)\"" : "NOTHING")")

        // --- Undoing back to the last save -----------------------------------
        //
        // The dirty flag used to be one-way, so draw / save / draw / ⌘Z left Paintbox
        // asking to save a picture byte-identical to the file it had just written.
        let saveURL = tmp.appendingPathComponent("dirty-flag.png")
        let saveDoc = PaintDocument(width: 32, height: 24, fill: .white)
        let saveUndo = freshUndo(saveDoc)
        saveDoc.edit("Pencil") { c in
            c.setFillColor(red.cgColor)
            c.fill(CGRect(x: 2, y: 2, width: 6, height: 6))
        }
        let dirtyBeforeSave = saveDoc.isDirty
        do { try saveDoc.save(to: saveURL) } catch {
            check("undoing back to the last save clears the dirty flag", false, "\(error)")
            return
        }
        let cleanAfterSave = !saveDoc.isDirty
        let onDisk = checksum(saveDoc.context)
        saveDoc.edit("Brush") { c in
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 16, y: 10, width: 8, height: 8))
        }
        let dirtyAfterEdit = saveDoc.isDirty
        saveUndo.undo()
        let backAtTheFile = checksum(saveDoc.context) == onDisk
        check("undoing back to the last save clears the dirty flag",
              dirtyBeforeSave && cleanAfterSave && dirtyAfterEdit && backAtTheFile
                  && !saveDoc.isDirty,
              "draw → \(dirtyBeforeSave ? "dirty" : "CLEAN"), save → "
                  + "\(cleanAfterSave ? "clean" : "STILL DIRTY"), draw → "
                  + "\(dirtyAfterEdit ? "dirty" : "CLEAN"), undo → "
                  + "\(saveDoc.isDirty ? "STILL DIRTY" : "clean") with the pixels "
                  + "\(backAtTheFile ? "back at the saved bytes" : "NOT back at the saved bytes")")

        // One more ⌘Z goes PAST the save point, and a document behind its own file has
        // unsaved work in it just as surely as one ahead of it.
        saveUndo.undo()
        check("...and undoing past it makes it dirty again",
              saveDoc.isDirty && checksum(saveDoc.context) != onDisk,
              "wound back before the save the document is \(saveDoc.isDirty ? "dirty" : "STILL CLEAN") "
                  + "and the pixels \(checksum(saveDoc.context) != onDisk ? "differ from the file" : "MATCH THE FILE")")

        // Redoing forward to the save point is clean again, in the other direction.
        saveUndo.redo()
        check("...and redoing back to it is clean",
              !saveDoc.isDirty && checksum(saveDoc.context) == onDisk,
              "document \(saveDoc.isDirty ? "DIRTY" : "clean") with the pixels "
                  + "\(checksum(saveDoc.context) == onDisk ? "back at the saved bytes" : "NOT at the saved bytes")")
    }

    // ---- A button that cannot work must not look as if it can ---------------

    private static func commandValidationChecks() {
        let doc = PaintDocument(width: 60, height: 40, fill: .white)
        let controller = PaintWindowController(document: doc)
        let canvas = controller.canvas!
        guard let toolbar = controller.window?.toolbar else {
            check("the toolbar greys out what it cannot do", false, "the window has no toolbar")
            return
        }

        // The real items, built by the real delegate method, and validated through the
        // real protocol — which is the part that was missing.
        var items: [Selector: NSToolbarItem] = [:]
        for id in controller.toolbarDefaultItemIdentifiers(toolbar) {
            guard let item = controller.toolbar(toolbar, itemForItemIdentifier: id,
                                                willBeInsertedIntoToolbar: false),
                  let action = item.action else { continue }
            items[action] = item
        }
        /// Through AppKit's own path: `validate()` is what the toolbar calls on each pass
        /// round the event loop, and its default implementation is the thing that was
        /// answering "enabled, obviously" because nobody had implemented the protocol.
        func enabled(_ action: Selector) -> Bool {
            guard let item = items[action] else { return false }
            item.validate()
            return item.isEnabled
        }
        let undoSel = #selector(PaintWindowController.undoAction(_:))
        let redoSel = #selector(PaintWindowController.redoAction(_:))
        let cropSel = #selector(PaintWindowController.cropToSelection(_:))

        let live = [("Undo", undoSel), ("Redo", redoSel), ("Crop", cropSel)]
            .filter { enabled($0.1) }.map(\.0)
        check("the toolbar greys out what it cannot do",
              items[undoSel] != nil && items[redoSel] != nil && items[cropSel] != nil
                  && live.isEmpty && items[undoSel]?.autovalidates == true,
              live.isEmpty ? "Undo, Redo and Crop are all disabled on a fresh document "
                             + "(\(items.count) toolbar items, autovalidating)"
                           : "still enabled with an empty undo stack and no selection: "
                             + "\(live.joined(separator: ", "))")

        doc.edit("Pencil") { c in
            c.setFillColor(red.cgColor)
            c.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
        canvas.setSelection(rect: CGRect(x: 10, y: 10, width: 10, height: 10))
        check("...and lights them up when it can",
              enabled(undoSel) && enabled(cropSel) && !enabled(redoSel),
              "after one stroke and a selection: Undo \(enabled(undoSel) ? "live" : "STILL DEAD"), "
                  + "Crop \(enabled(cropSel) ? "live" : "STILL DEAD"), Redo "
                  + "\(enabled(redoSel) ? "LIVE WITH NOTHING TO REDO" : "dead")")

        // Zoom has ends, and a button that cannot move the zoom any further is in the
        // same position as Undo with an empty stack.
        // The menu has to give the same answer as the button beside it, so both are asked.
        let zoomInMenu = NSMenuItem(title: "Zoom In",
                                    action: #selector(PaintWindowController.zoomIn(_:)),
                                    keyEquivalent: "+")
        canvas.setZoom(CanvasView.maxZoom)
        let atMax = enabled(#selector(PaintWindowController.zoomIn(_:)))
        let atMaxInMenu = controller.validateMenuItem(zoomInMenu)
        canvas.setZoom(CanvasView.minZoom)
        let atMin = enabled(#selector(PaintWindowController.zoomOut(_:)))
        canvas.setZoom(1)
        check("the zoom buttons stop at the ends of the range",
              !atMax && !atMaxInMenu && !atMin
                  && enabled(#selector(PaintWindowController.zoomIn(_:)))
                  && controller.validateMenuItem(zoomInMenu),
              "at \(Int(CanvasView.maxZoom * 100))% Zoom In is \(atMax ? "STILL LIVE" : "dead") on the "
                  + "toolbar and \(atMaxInMenu ? "STILL LIVE" : "dead") in the menu; "
                  + "at \(Int(CanvasView.minZoom * 100))% Zoom Out is \(atMin ? "STILL LIVE" : "dead"); "
                  + "at 100% both are live again")
        controller.window?.close()
        PaintboxApp.shared.forget(controller)

        // --- ⌘Z with a paste still in mid-air --------------------------------
        //
        // A floating paste has not touched the bitmap, so the undo stack knows nothing
        // about it: on a fresh document ⌘Z was greyed out with the paste hanging there,
        // and on a document with history the menu named the step BEFORE the paste.
        let freshDoc = PaintDocument(width: 60, height: 40, fill: .white)
        let fresh = PaintWindowController(document: freshDoc)
        let badge = Bitmap.makeContext(width: 10, height: 10)
        badge.setFillColor(blue.cgColor)
        badge.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let clean = checksum(freshDoc.context)
        fresh.canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 20, y: 10))
        let undoItem = NSMenuItem(title: "Undo", action: #selector(PaintWindowController.undoAction(_:)),
                                  keyEquivalent: "z")
        let offeredOnFresh = fresh.validateMenuItem(undoItem)
        let titleOnFresh = undoItem.title
        fresh.undoAction(nil)
        check("⌘Z takes back a floating paste on a fresh document",
              offeredOnFresh && titleOnFresh == "Undo Paste" && !fresh.canvas.hasFloatingItem
                  && checksum(freshDoc.context) == clean && !freshDoc.isDirty,
              "the Edit menu offered \"\(titleOnFresh)\" \(offeredOnFresh ? "enabled" : "GREYED OUT"); "
                  + "afterwards the paste is \(fresh.canvas.hasFloatingItem ? "STILL FLOATING" : "gone"), "
                  + "the pixels are \(checksum(freshDoc.context) == clean ? "untouched" : "STAMPED") "
                  + "and the document is \(freshDoc.isDirty ? "DIRTY" : "clean")")
        fresh.window?.close()
        PaintboxApp.shared.forget(fresh)

        // The same paste over a document with history: the label has to name the paste,
        // and taking it back must leave the earlier work alone.
        let histDoc = PaintDocument(width: 60, height: 40, fill: .white)
        let hist = PaintWindowController(document: histDoc)
        histDoc.edit("Pencil") { c in
            c.setFillColor(red.cgColor)
            c.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
        let drawn = checksum(histDoc.context)
        hist.canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 20, y: 10))
        let histItem = NSMenuItem(title: "Undo", action: #selector(PaintWindowController.undoAction(_:)),
                                  keyEquivalent: "z")
        _ = hist.validateMenuItem(histItem)
        let titleWithHistory = histItem.title
        hist.undoAction(nil)
        _ = hist.validateMenuItem(histItem)
        check("...and names the paste, not the step before it",
              titleWithHistory == "Undo Paste" && !hist.canvas.hasFloatingItem
                  && checksum(histDoc.context) == drawn && histItem.title == "Undo Pencil",
              "with a stroke in the history the menu said \"\(titleWithHistory)\"; after ⌘Z the "
                  + "stroke is \(checksum(histDoc.context) == drawn ? "still there" : "GONE") and the "
                  + "menu now says \"\(histItem.title)\"")
        hist.window?.close()
        PaintboxApp.shared.forget(hist)
    }

    // ---- Every toolbar button has to be ON the toolbar ----------------------

    /// A button folded into the `»` overflow menu is a button nobody finds.
    ///
    /// The window opens at 1100x760 and the toolbar carries seventeen labelled items. On
    /// the default (unified) style the title shares that row, and there was not room for
    /// both: Cut Out and all three zoom buttons went into the overflow menu and the title
    /// was clipped to "Untitled — Paintb…" — at the size the app chooses for itself,
    /// before anyone touched a window edge. The zoom trio is the worst possible thing to
    /// lose, because a photo opens zoomed-to-fit and zoom is the first thing reached for.
    ///
    /// This asks AppKit, not arithmetic: `NSToolbar.visibleItems` is the list of items
    /// that actually got a slot, so anything missing from it is in the overflow menu.
    /// Layout is asynchronous, hence the pump — it settles in about 20ms.
    private static func toolbarFitChecks() {
        let doc = PaintDocument(width: 64, height: 64, fill: .white)
        let controller = PaintWindowController(document: doc)
        guard let window = controller.window, let toolbar = window.toolbar else {
            check("every toolbar button fits at the default size", false, "the window has no toolbar")
            return
        }
        // The real window at the size the app gives it. Ordering it front is what makes
        // AppKit lay the toolbar out; under `.prohibited` nothing reaches a screen.
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(2)
        var settled = 0, last = -1
        while Date() < deadline && settled < 3 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            let n = toolbar.visibleItems?.count ?? 0
            settled = (n > 0 && n == last) ? settled + 1 : 0
            last = n
        }
        let wanted = controller.toolbarDefaultItemIdentifiers(toolbar)
            .filter { $0 != .space && $0 != .flexibleSpace }
        let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        let overflowed = wanted.filter { !visible.contains($0) }
        check("every toolbar button fits at the default size",
              !wanted.isEmpty && overflowed.isEmpty && window.toolbarStyle == .expanded,
              overflowed.isEmpty
                  ? "all \(wanted.count) items have a slot at \(Int(window.frame.width))pt wide, "
                      + "title on its own row"
                  : "\(overflowed.count) of \(wanted.count) items are in the » overflow menu at "
                      + "\(Int(window.frame.width))pt: "
                      + overflowed.map(\.rawValue).joined(separator: ", "))
        window.close()
        PaintboxApp.shared.forget(controller)
    }

    // ---- Crop to Selection means the SHAPE, not the box --------------------

    /// A bitmap is a rectangle, so cropping to a wand selection can only produce the
    /// mask's bounding box — and it used to produce exactly that and nothing else, so
    /// the background the user had just selected around, inside that box, survived the
    /// crop with nothing on screen to explain it. The box is still the box; what has to
    /// be true as well is that everything in it the mask did not cover is gone.
    private static func cropToShapeChecks() {
        // A triangle of red on white: the smallest shape whose bounding box contains a
        // lot of pixels the shape does not.
        let doc = PaintDocument(width: 64, height: 64, fill: .white)
        doc.context.withTopLeftOrigin { c in
            c.setFillColor(red.cgColor)
            c.beginPath()
            c.move(to: CGPoint(x: 32, y: 12))
            c.addLine(to: CGPoint(x: 52, y: 52))
            c.addLine(to: CGPoint(x: 12, y: 52))
            c.closePath()
            c.fillPath()
        }
        doc.touch()
        let undo = freshUndo(doc)
        let before = checksum(doc.context)

        guard let shape = MagicWand.select(in: doc.context, at: CGPoint(x: 32, y: 40),
                                           tolerance: 20, contiguous: true),
              !shape.isRectangular else {
            check("Crop to Selection keeps the shape, not the box", false,
                  "the wand did not produce an irregular selection to crop to")
            return
        }
        let box = shape.bounds
        let boxArea = Int(box.width) * Int(box.height)
        let selected = shape.setCount

        group(undo) { doc.crop(to: shape) }
        // The top corners of the bounding box are the pixels the old crop left behind:
        // inside the box, outside the triangle. (The bottom row of the box IS the
        // triangle's base, so it is red on purpose.)
        let left = doc.context.sample(x: 0, y: 0)
        let right = doc.context.sample(x: doc.pixelWidth - 1, y: 0)
        let inside = doc.context.sample(x: Int(box.width) / 2, y: Int(box.height) * 3 / 4)
        let transparent = count(in: doc) { $0.a == 0 }
        check("Crop to Selection keeps the shape, not the box",
              doc.pixelWidth == Int(box.width) && doc.pixelHeight == Int(box.height)
                  && left.a == 0 && right.a == 0 && isRed(inside)
                  && transparent == boxArea - selected,
              "cropped to \(doc.pixelWidth)x\(doc.pixelHeight) (the mask's box); the box's top "
                  + "corners read \(left) and \(right), the middle of the triangle \(inside); "
                  + "\(transparent) transparent pixels, \(boxArea - selected) outside the mask")

        undo.undo()
        check("...and one ⌘Z puts the whole picture back",
              doc.pixelWidth == 64 && doc.pixelHeight == 64 && checksum(doc.context) == before,
              "back to \(doc.pixelWidth)x\(doc.pixelHeight) with the pixels "
                  + "\(checksum(doc.context) == before ? "identical" : "DIFFERENT")")

        // The other half of the promise: a plain rectangular selection has no outside to
        // clear, and must not come back with transparency it never had.
        let rectDoc = PaintDocument(width: 64, height: 64, fill: .white)
        let rectUndo = freshUndo(rectDoc)
        let rectMask = SelectionMask(width: 64, height: 64,
                                     rect: CGRect(x: 8, y: 8, width: 20, height: 12))
        group(rectUndo) { rectDoc.crop(to: rectMask) }
        check("a rectangular crop stays opaque",
              rectDoc.pixelWidth == 20 && rectDoc.pixelHeight == 12
                  && count(in: rectDoc) { $0.a == 0 } == 0,
              "\(rectDoc.pixelWidth)x\(rectDoc.pixelHeight) with "
                  + "\(count(in: rectDoc) { $0.a == 0 }) transparent pixels")
    }

    // ---- A label that does not fit reads as an unfinished interface ---------

    /// The palette's SHAPE STYLE control drew "Out..." because "Outline" is wider than a
    /// third of a 140pt control. Two things are checked: that every label it ships with
    /// fits, and that the measurement has teeth — the word that did not fit still does
    /// not, so this cannot pass by measuring nothing.
    ///
    /// The palette's own height is here too. It is hand-laid at a fixed height inside a
    /// scroll view, and the scroll view is what makes a palette taller than the window
    /// reachable rather than clipped; the default window also has to be tall enough that
    /// nobody needs it on day one.
    private static func interfaceLabelChecks() {
        let shipped = PaletteView.shapeStyleSegments.map(\.label)
        let tooWide = shipped.filter { !PaletteView.shapeStyleFits($0) }
        let widths = shipped.map { "\($0) \(Int(PaletteView.shapeStyleTextWidth($0).rounded()))pt" }
        check("every shape-style label fits its segment",
              tooWide.isEmpty && !PaletteView.shapeStyleFits("Outline")
                  && shipped.count == 3,
              "\(widths.joined(separator: ", ")) in \(Int(PaletteView.shapeStyleSegmentWidth))pt "
                  + "segments; \"Outline\" would need "
                  + "\(Int(PaletteView.shapeStyleTextWidth("Outline").rounded()))pt and is the "
                  + "label that used to be truncated"
                  + (tooWide.isEmpty ? "" : "; STILL TOO WIDE: \(tooWide.joined(separator: ", "))"))

        let doc = PaintDocument(width: 64, height: 64, fill: .white)
        let controller = PaintWindowController(document: doc)
        func findPalette(_ view: NSView) -> (palette: PaletteView, scroll: NSScrollView)? {
            if let scroll = view as? NSScrollView, let palette = scroll.documentView as? PaletteView {
                return (palette, scroll)
            }
            for sub in view.subviews {
                if let found = findPalette(sub) { return found }
            }
            return nil
        }
        guard let content = controller.window?.contentView, let found = findPalette(content) else {
            check("the palette fits the window it ships with", false,
                  "no palette inside a scroll view in the window")
            controller.window?.close()
            PaintboxApp.shared.forget(controller)
            return
        }
        let available = content.frame.height
        check("the palette fits the window it ships with",
              found.palette.fittingHeight <= available && found.scroll.hasVerticalScroller,
              "the palette is \(Int(found.palette.fittingHeight))pt tall in \(Int(available))pt "
                  + "of window, and scrolls "
                  + "\(found.scroll.hasVerticalScroller ? "if it ever stops fitting" : "NOT AT ALL")")
        controller.window?.close()
        PaintboxApp.shared.forget(controller)
    }

    // ---- A menu that is always empty reads as a broken app ------------------

    /// File ▸ Open Recent was built by asking a private AppKit selector to name the
    /// submenu, and when that did not take — which is how it shipped — the submenu was
    /// simply always empty. It is built by hand now, from the list
    /// `NSDocumentController` already keeps. The builder takes the list as an argument,
    /// so this drives the real one without touching the user's own recent documents.
    private static func recentDocumentsChecks() {
        let urls = [URL(fileURLWithPath: "/tmp/paintbox-one.png"),
                    URL(fileURLWithPath: "/tmp/elsewhere/paintbox-two.jpg")]
        let menu = NSMenu(title: "Open Recent")
        RecentDocumentsMenu.rebuild(menu, urls: urls, target: PaintboxApp.shared)
        let titles = menu.items.map(\.title)
        let named = titles.prefix(2) == ["paintbox-one.png", "paintbox-two.jpg"]
        let carriesURLs = menu.items.prefix(2).map { $0.representedObject as? URL } == urls
        let wired = menu.items.prefix(2).allSatisfy {
            $0.target === PaintboxApp.shared
                && $0.action == #selector(PaintboxApp.openRecentDocument(_:))
                && PaintboxApp.shared.responds(to: $0.action)
        }
        let clears = menu.items.last?.action == #selector(PaintboxApp.clearRecentDocuments(_:))
        check("Open Recent lists the files it was given",
              named && carriesURLs && wired && clears && menu.items.count == 4,
              "\(menu.items.count) items: \(titles.joined(separator: " / ")); each one "
                  + "\(wired ? "opens its own URL" : "IS NOT WIRED TO ANYTHING")")

        RecentDocumentsMenu.rebuild(menu, urls: [], target: PaintboxApp.shared)
        check("...and says so when there are none",
              menu.items.count == 1 && menu.items[0].title == "No Recent Items"
                  && !menu.items[0].isEnabled,
              "empty list gives \(menu.items.count) item, \"\(menu.items[0].title)\", "
                  + "\(menu.items[0].isEnabled ? "ENABLED" : "greyed out")")

        // And the real menu bar's submenu really is the one that gets filled in: the
        // wiring, not just the builder.
        PaintboxApp.shared.buildMenus()
        let fileMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
        let recent = fileMenu?.items.first { $0.title == "Open Recent" }?.submenu
        recent?.delegate?.menuNeedsUpdate?(recent!)
        check("the File menu's Open Recent is the one being filled in",
              recent?.delegate != nil && (recent?.items.count ?? 0) >= 1,
              "the submenu has a delegate: \(recent?.delegate != nil), and after an update it "
                  + "holds \(recent?.items.count ?? 0) item(s) — never the zero it used to")
    }

    // ---- The instruction belongs where the thing is happening ---------------

    /// Paste stopped stamping and started floating, and the Edit menu item was renamed
    /// "Paste (drag it, then press Return)" so the change would not be silent. That put
    /// an instruction sheet in the menu bar, permanently, in front of everyone who had
    /// not pasted and nobody who had. The item is called Paste again and the instruction
    /// is in the status line, which only says it while something really is floating.
    ///
    /// Both halves are checked, because either alone is a regression: a bare menu item
    /// with no guidance anywhere is the silent change the title was guarding against.
    private static func pasteGuidanceChecks() {
        PaintboxApp.shared.buildMenus()
        let editMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        let pasteItem = editMenu?.items.first { $0.action == #selector(PaintWindowController.paste(_:)) }
        check("the Edit menu's Paste is called Paste",
              pasteItem?.title == "Paste" && pasteItem?.keyEquivalent == "v",
              "the item reads \(pasteItem.map { "“\($0.title)”" } ?? "NOT THERE") on "
                  + "\(pasteItem.map { "⌘\($0.keyEquivalent.uppercased())" } ?? "no key")")

        let doc = PaintDocument(width: 120, height: 90, fill: .white)
        let controller = PaintWindowController(document: doc)
        let quiet = controller.statusLabel.stringValue
        let badge = Bitmap.makeContext(width: 40, height: 30)
        badge.setFillColor(blue.cgColor)
        badge.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        controller.canvas.beginFloating(image: badge.makeImage()!, at: CGPoint(x: 10, y: 10))
        let floating = controller.statusLabel.stringValue
        controller.canvas.commitFloating()
        let after = controller.statusLabel.stringValue

        let tells = ["drag to move", "drag a corner to scale", "Return to place", "Esc to cancel"]
        let missing = tells.filter { !floating.contains($0) }
        // An instruction elided to "…" is not one. The label is the width of the window
        // it ships with, less the palette, so this is the real space it has.
        let label = controller.statusLabel!
        let inked = (floating as NSString)
            .size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 10)]).width
        check("the floating paste explains itself in the status line",
              missing.isEmpty && floating.contains("40 × 30") && inked <= label.frame.width
                  && !quiet.contains("Return to place") && !after.contains("Return to place"),
              missing.isEmpty ? "while floating the status line reads “\(floating)” — "
                                + "\(Int(inked.rounded()))pt in \(Int(label.frame.width.rounded()))pt "
                                + "of label; before and after the paste it says nothing about Return"
                              : "the status line reads “\(floating)” and never mentions "
                                + missing.joined(separator: ", "))
        controller.window?.close()
        PaintboxApp.shared.forget(controller)
    }

    // ---- A copy must not encode anything until somebody pastes -------------

    /// ⌘C used to encode the copy as PNG and again as TIFF before it returned: on a
    /// 6000x4000 photograph half a second of frozen window, 1.7 s on grainy content, and
    /// 130-180 MB left sitting on the pasteboard. Both formats are still OFFERED — the
    /// promise is what is cheap — and the bytes are made when a paste asks for one.
    ///
    /// The counter is the point of this test: a copy that declares the types and encodes
    /// them anyway would pass every "can this be pasted" check and still freeze the app.
    ///
    /// On its own pasteboard, like the paste checks above: a self-test may not throw away
    /// whatever the person running it had on their clipboard.
    private static func lazyCopyChecks() {
        let pb = NSPasteboard(name: NSPasteboard.Name("PaintboxSelfTestCopyPasteboard"))
        pb.clearContents()
        let doc = squareDoc(size: 32, rects: [CGRect(x: 0, y: 0, width: 16, height: 32)])
        let controller = PaintWindowController(document: doc)
        guard let promise = controller.copyToPasteboard(pb) else {
            check("a copy encodes nothing until it is pasted", false, "the copy produced no picture at all")
            controller.window?.close()
            PaintboxApp.shared.forget(controller)
            return
        }
        let offered = Set(pb.types ?? [])
        let encodedOnCopy = promise.encodeCount
        let pasteEnabled = PaintboxApp.canPasteImage(from: pb)

        // Paste inside Paintbox takes the picture straight off the promise: no encode,
        // no decode, and the pixels have to be the ones that were copied.
        let pasted = PaintboxApp.imageFromPasteboard(from: pb)
        let encodedOnInternalPaste = promise.encodeCount
        let pastedLeft = pasted.map { Bitmap.context(from: $0).sample(x: 2, y: 2) }
        let pastedRight = pasted.map { Bitmap.context(from: $0).sample(x: 30, y: 2) }

        // Another app asking for PNG is what really makes the bytes, and exactly once.
        let png = pb.data(forType: .png)
        let encodedAfterPNG = promise.encodeCount
        let decoded = png.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
        let decodedLeft = decoded.map { Bitmap.context(from: $0).sample(x: 2, y: 2) }
        let decodedRight = decoded.map { Bitmap.context(from: $0).sample(x: 30, y: 2) }
        // Nobody asked for TIFF, so nobody paid for it.
        let encodedAfterAll = promise.encodeCount
        pb.clearContents()
        controller.window?.close()
        PaintboxApp.shared.forget(controller)

        let copied = RGBA(r: 255, g: 0, b: 0, a: 255)
        let white = RGBA(r: 255, g: 255, b: 255, a: 255)
        check("a copy encodes nothing until it is pasted",
              offered.contains(.png) && offered.contains(.tiff) && encodedOnCopy == 0
                  && pasteEnabled && encodedOnInternalPaste == 0
                  && pastedLeft == copied && pastedRight == white
                  && decodedLeft == copied && decodedRight == white
                  && encodedAfterPNG == 1 && encodedAfterAll == 1,
              "the copy offers \(offered.contains(.png) ? "png" : "NO png"), "
                  + "\(offered.contains(.tiff) ? "tiff" : "NO tiff") and encoded "
                  + "\(encodedOnCopy) of them; Paste is "
                  + "\(pasteEnabled ? "enabled" : "DISABLED") and gives back "
                  + "\(pastedLeft.map(\.description) ?? "nothing")/"
                  + "\(pastedRight.map(\.description) ?? "nothing") after \(encodedOnInternalPaste) "
                  + "encodes; the PNG another app asks for decodes to "
                  + "\(decodedLeft.map(\.description) ?? "NOTHING")/"
                  + "\(decodedRight.map(\.description) ?? "NOTHING") and cost \(encodedAfterPNG) "
                  + "encode(s), \(encodedAfterAll) in total")
    }

    // ---- Paste must not be enabled with nothing to paste -------------------

    /// Paste used to be permanently enabled: with text or nothing on the clipboard it
    /// looked available and did nothing when chosen. The validator asks
    /// `PaintboxApp.canPasteImage`, and that question has to give the same answer as
    /// `imageFromPasteboard`, which is what Paste then calls — an enabled Paste that
    /// finds no picture is the same bug wearing a different coat.
    ///
    /// On its own pasteboard, not the general one: a self-test may not throw away
    /// whatever the person running it had on their clipboard.
    private static func pasteValidationChecks() {
        let pb = NSPasteboard(name: NSPasteboard.Name("PaintboxSelfTestPasteboard"))
        pb.clearContents()
        pb.setString("a line of text, which is not a picture", forType: .string)
        let textEnables = PaintboxApp.canPasteImage(from: pb)
        let textGives = PaintboxApp.imageFromPasteboard(from: pb)

        pb.clearContents()
        let emptyEnables = PaintboxApp.canPasteImage(from: pb)

        let rep = NSBitmapImageRep(cgImage: squareDoc(size: 24, rects: [CGRect(x: 0, y: 0, width: 12, height: 24)]).image)
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        let imageEnables = PaintboxApp.canPasteImage(from: pb)
        let imageGives = PaintboxApp.imageFromPasteboard(from: pb)
        pb.clearContents()
        check("Paste is dead unless there is a picture to paste",
              !textEnables && textGives == nil && !emptyEnables
                  && imageEnables && imageGives?.width == 24,
              "text: \(textEnables ? "ENABLED" : "disabled") and gives "
                  + "\(textGives == nil ? "nothing" : "AN IMAGE"); empty clipboard: "
                  + "\(emptyEnables ? "ENABLED" : "disabled"); a 24x24 PNG: "
                  + "\(imageEnables ? "enabled" : "DISABLED") and gives "
                  + "\(imageGives.map { "\($0.width)x\($0.height)" } ?? "NOTHING")")

        // The menu item really does ask that question, whatever is on the clipboard while
        // this runs — which is why it is compared against the predicate rather than
        // against a fixed answer.
        let doc = PaintDocument(width: 32, height: 24, fill: .white)
        let controller = PaintWindowController(document: doc)
        let item = NSMenuItem(title: "Paste", action: #selector(PaintWindowController.paste(_:)),
                              keyEquivalent: "")
        let menuSays = controller.validateMenuItem(item)
        check("...and the menu item asks that same question",
              menuSays == PaintboxApp.canPasteImage(),
              "with the real clipboard holding \(PaintboxApp.canPasteImage() ? "a picture" : "no picture") "
                  + "the item is \(menuSays ? "enabled" : "disabled")")
        controller.window?.close()
        PaintboxApp.shared.forget(controller)

        // File ▸ New from Clipboard put up the same alert for the same reason, and had no
        // validator at all: the app delegate is the target of those items and answered
        // nothing, so AppKit left them all enabled. Asked through the REAL menu — built
        // the way the app builds it, and updated the way AppKit updates it — so that the
        // wiring is checked and not just the predicate.
        PaintboxApp.shared.buildMenus()
        let fileMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
        let fromClipboard = fileMenu?.items.first {
            $0.action == #selector(PaintboxApp.newFromClipboard(_:))
        }
        fileMenu?.update()
        let validated = PaintboxApp.shared as NSMenuItemValidation
        let asks = fromClipboard.map { validated.validateMenuItem($0) }
        let enabled = fromClipboard?.isEnabled
        check("New from Clipboard is dead with no picture on the clipboard either",
              fromClipboard != nil && fromClipboard?.target === PaintboxApp.shared
                  && asks == PaintboxApp.canPasteImage()
                  && enabled == PaintboxApp.canPasteImage(),
              "with the real clipboard holding "
                  + "\(PaintboxApp.canPasteImage() ? "a picture" : "no picture") the item "
                  + "\(fromClipboard == nil ? "IS NOT IN THE FILE MENU" : (enabled == true ? "is enabled" : "is disabled"))"
                  + " and its validator says \(asks.map(String.init(describing:)) ?? "nothing")")

        // The Resize dialog's live readout: the other half of refusing an absurd size is
        // saying what the size IS while it is being typed.
        let current = CGSize(width: 1024, height: 768)
        let typo = Dialogs.resizePreview(mode: .percent, width: "10000", height: "10000",
                                         current: current)
        let fine = Dialogs.resizePreview(mode: .percent, width: "200", height: "200",
                                         current: current)
        let pixels = Dialogs.resizePreview(mode: .pixels, width: "640", height: "480",
                                           current: current)
        let nonsense = Dialogs.resizePreview(mode: .percent, width: "1e400", height: "1e400",
                                             current: current)
        check("the Resize dialog says what it is about to make",
              typo.contains("102400") && typo.contains("too big")
                  && fine == "2048 × 1536 pixels" && pixels == "640 × 480 pixels"
                  && nonsense == "not a size Paintbox can use",
              "10000% reads \"\(typo)\"; 200% reads \"\(fine)\"; 1e400 reads \"\(nonsense)\"")
    }

    // ---- A drag whose mouse-up never arrived --------------------------------

    private static func orphanedDragChecks() {
        // The up event goes elsewhere whenever something else takes the mouse mid-drag.
        // `liveSelectionRect` is the one that showed: `drawSelection` draws it INSTEAD of
        // the real selection, so the phantom ants outlived the drag that made them.
        let doc = PaintDocument(width: 80, height: 60, fill: .white)
        let settings = ToolSettings()
        settings.tool = .select
        let canvas = CanvasView(document: doc, settings: settings)
        canvas.begin(.init(point: CGPoint(x: 5, y: 5)))
        canvas.moveTo(.init(point: CGPoint(x: 45, y: 35)))
        let midDrag = canvas.liveSelectionRect
        // No end(). The next thing the canvas sees is a fresh click.
        canvas.begin(.init(point: CGPoint(x: 60, y: 50)))
        let leaked = canvas.liveSelectionRect
        canvas.moveTo(.init(point: CGPoint(x: 70, y: 56)))
        canvas.end(.init(point: CGPoint(x: 70, y: 56)))
        let committed = canvas.selectionRect
        check("a drag with no mouse-up does not leak",
              midDrag != nil && leaked == nil
                  && committed == CGRect(x: 60, y: 50, width: 10, height: 6),
              "mid-drag the ants read \(midDrag.map(describe) ?? "NOTHING"); after the next "
                  + "mouse-down \(leaked.map { "STILL \(describe($0))" } ?? "gone"); the second "
                  + "drag selected \(committed.map(describe) ?? "nothing")")

        settings.tool = .rectangle
        canvas.begin(.init(point: CGPoint(x: 4, y: 4)))
        canvas.moveTo(.init(point: CGPoint(x: 40, y: 30)))
        canvas.begin(.init(point: CGPoint(x: 50, y: 40)))
        canvas.moveTo(.init(point: CGPoint(x: 58, y: 46)))
        let pending = canvas.pendingShapeRect
        canvas.end(.init(point: CGPoint(x: 58, y: 46)))
        check("...and the next shape starts where it was clicked",
              pending == CGRect(x: 50, y: 40, width: 8, height: 6),
              "after the orphaned drag the preview reads \(pending.map(describe) ?? "nothing"), "
                  + "not a box stretched back to the old start point")

        // The bitmap replaced underneath a live drag: ⌘K, ⌘Z and the resize dialog are all
        // reachable with the button still down, and the mouse-up after one of them used to
        // stamp a shape at coordinates measured on a picture that no longer exists.
        let cropDoc = PaintDocument(width: 80, height: 60, fill: .white)
        let controller = PaintWindowController(document: cropDoc)
        let cropCanvas = controller.canvas!
        controller.settings.tool = .rectangle
        controller.settings.foreground = red
        cropCanvas.begin(.init(point: CGPoint(x: 6, y: 6)))
        cropCanvas.moveTo(.init(point: CGPoint(x: 70, y: 50)))
        let live = cropCanvas.pendingShapeRect
        cropDoc.crop(to: SelectionMask(width: 80, height: 60,
                                       rect: CGRect(x: 0, y: 0, width: 40, height: 30)))
        let afterCrop = checksum(cropDoc.context)
        cropCanvas.end(.init(point: CGPoint(x: 38, y: 28)))
        check("a crop mid-drag cancels the drag, not the canvas",
              live != nil && cropCanvas.pendingShapeRect == nil
                  && checksum(cropDoc.context) == afterCrop
                  && count(in: cropDoc, where: isRed) == 0,
              "the drag was live at \(live.map(describe) ?? "NOWHERE") before the crop; after "
                  + "it the mouse-up left \(count(in: cropDoc, where: isRed)) red pixels in the "
                  + "40x30 picture and the preview reads "
                  + "\(cropCanvas.pendingShapeRect.map(describe) ?? "nothing")")
        controller.window?.close()
        PaintboxApp.shared.forget(controller)
    }

    // ---- The eyedropper on a hole ------------------------------------------

    private static func eyedropperHoleChecks() {
        // Background removal leaves whole regions transparent, and the eyedropper picked
        // them: the foreground colour became transparent black, after which the pencil,
        // the brush, the shapes and the text tool all composited nothing and the app
        // looked broken with nothing on screen to say why.
        let doc = PaintDocument(width: 40, height: 40, fill: nil)
        doc.context.withTopLeftOrigin { c in
            c.setFillColor(blue.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
        let settings = ToolSettings()
        settings.tool = .eyedropper
        settings.foreground = red
        let canvas = CanvasView(document: doc, settings: settings)

        canvas.begin(.init(point: CGPoint(x: 30, y: 20)))       // the empty half
        let afterHole = RGBA.premultiplied(settings.foreground)
        let note = canvas.pickNote

        // The colour it declined to replace still draws — which is the whole point.
        settings.tool = .pencil
        canvas.begin(.init(point: CGPoint(x: 30, y: 30)))
        canvas.end(.init(point: CGPoint(x: 30, y: 30)))
        let drew = doc.context.sample(x: 30, y: 30)

        settings.tool = .eyedropper
        canvas.begin(.init(point: CGPoint(x: 10, y: 20)))       // the blue half
        let afterBlue = RGBA.premultiplied(settings.foreground)
        check("the eyedropper never picks a hole",
              afterHole.a == 255 && isRed(afterHole) && note != nil
                  && isRed(drew) && isBlue(afterBlue) && canvas.pickNote == nil,
              "a click on transparency left the colour \(afterHole) and said "
                  + "\"\(note ?? "NOTHING")\"; the pencil then drew \(drew); a click on the "
                  + "blue half picked \(afterBlue) and said "
                  + "\"\(canvas.pickNote ?? "nothing")\"")
    }

    // ---- Closing a document that has never been saved ----------------------

    private static func closeFlowChecks(tmp: URL) {
        let pngURL = tmp.appendingPathComponent("close-flow.png")
        let untitledRoute = PaintWindowController.saveRoute(for: nil)
        let pngRoute = PaintWindowController.saveRoute(for: pngURL)
        var webpMessage: String?
        if case .panel(let m) = PaintWindowController.saveRoute(for: URL(fileURLWithPath: "/x/logo.webp")) {
            webpMessage = m
        }
        check("Save on an untitled document means Save As",
              untitledRoute == .panel(nil) && pngRoute == .write(pngURL)
                  && webpMessage?.contains(".webp") == true,
              "with no file yet ⌘S reads \(untitledRoute); a .png reads \(pngRoute); a .webp "
                  + "reads \(webpMessage.map { "the panel, saying \"\($0)\"" } ?? "WRITE IT IN PLACE")")

        // Save in the close alert, on a document that has never been saved. There is no
        // file to write, so it becomes Save As — and the panel has to have answered
        // before the close does, or the window goes and takes the picture with it.
        let doc = PaintDocument(width: 40, height: 30, fill: .white)
        let controller = PaintWindowController(document: doc)
        doc.edit("Pencil") { c in
            c.setFillColor(red.cgColor)
            c.fill(CGRect(x: 2, y: 2, width: 6, height: 6))
        }
        var panelsShown = 0
        let cancelled = controller.saveBeforeClosing(panel: { _ in
            panelsShown += 1
            return false                      // the user cancelled the save panel
        })
        let dirtyAfterCancel = doc.isDirty
        let saved = controller.saveBeforeClosing(panel: { _ in
            panelsShown += 1
            do { try doc.save(to: pngURL) } catch { return false }
            return true
        })
        let onDisk = FileManager.default.fileExists(atPath: pngURL.path)
        check("the window only closes once the file is written",
              !cancelled && dirtyAfterCancel && saved && panelsShown == 2 && onDisk
                  && !doc.isDirty,
              "a cancelled panel \(cancelled ? "LET THE WINDOW CLOSE" : "held the window") with "
                  + "the work \(dirtyAfterCancel ? "still unsaved" : "CLAIMED SAVED"); writing the "
                  + "file \(saved ? "released it" : "STILL HELD IT"); \(panelsShown) panels asked "
                  + "for, file on disk: \(onDisk)")

        // A paste still in mid-air when the window goes. Nothing may be left pending on a
        // document nobody can see — and nothing may be stamped into it either, now that
        // the save decision has been made and answered.
        let stripe = squareDoc(size: 16, rects: [CGRect(x: 0, y: 0, width: 8, height: 16)])
        controller.canvas.beginFloating(image: stripe.image)
        let floatedBefore = controller.canvas.hasFloatingItem
        let pixelsBefore = checksum(doc.context)
        controller.window?.close()
        PaintboxApp.shared.forget(controller)

        // A text box still being typed into is the same promise: a paste and an unfinished
        // text box are the two things that live above the bitmap rather than in it.
        let typingDoc = PaintDocument(width: 30, height: 20, fill: .white)
        let typingController = PaintWindowController(document: typingDoc)
        typingController.settings.tool = .text
        typingController.canvas.begin(.init(point: CGPoint(x: 4, y: 4)))
        let typingBefore = typingController.canvas.isEditingText
        typingController.window?.close()
        PaintboxApp.shared.forget(typingController)

        check("closing a window leaves nothing in mid-air",
              floatedBefore && !controller.canvas.hasFloatingItem
                  && checksum(doc.context) == pixelsBefore && !doc.isDirty
                  && typingBefore && !typingController.canvas.isEditingText,
              "a paste was \(floatedBefore ? "pending" : "MISSING") before the close and "
                  + "\(controller.canvas.hasFloatingItem ? "IS STILL PENDING" : "is gone") after "
                  + "it; the picture was \(checksum(doc.context) == pixelsBefore ? "left alone" : "STAMPED ON"); "
                  + "a text box was \(typingBefore ? "open" : "MISSING") and "
                  + "\(typingController.canvas.isEditingText ? "IS STILL OPEN" : "is gone")")
    }
}

// MARK: - Window render check

/// `Paintbox.app/Contents/MacOS/Paintbox --screenshot out.png`
///
/// Builds the real window, draws a few strokes into the document, lets AppKit lay out,
/// then caches the window's contents to a PNG. It proves the UI renders - palette,
/// toolbar, canvas, checkerboard - without anyone looking at a screen.
enum WindowShot {
    /// Write the rendered PNG, reporting a failure instead of swallowing it. Returns nil
    /// on success, or the line to print on failure.
    ///
    /// The write used to be a `try?` followed unconditionally by the "wrote <path>" line
    /// and `exit(0)`, so a caller was told the file existed when it did not — and since
    /// this entry point is the only way to see the interface on a machine where
    /// `screencapture` returns black, that caller would then go on inspecting a stale PNG
    /// from an earlier run at the same path and believe it was looking at today's build.
    static func writePNG(_ data: Data, to path: String) -> String? {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return nil
        } catch {
            return "could not write \(path): \(error.localizedDescription)"
        }
    }

    static func capture(to path: String) {
        let doc = PaintDocument(width: 420, height: 300, fill: .white)
        let controller = PaintWindowController(document: doc)
        let settings = controller.settings
        settings.foreground = NSColor(srgbRed: 0.1, green: 0.35, blue: 0.85, alpha: 1)
        settings.tool = .brush

        doc.edit("Demo") { c in
            c.setFillColor(NSColor(srgbRed: 0.95, green: 0.8, blue: 0.2, alpha: 1).cgColor)
            c.fill(CGRect(x: 40, y: 40, width: 140, height: 90))
            c.clear(CGRect(x: 220, y: 40, width: 140, height: 90))
        }
        Painter.brush(in: doc.context, from: CGPoint(x: 60, y: 200), to: CGPoint(x: 360, y: 240),
                      size: 26, color: NSColor(srgbRed: 0.85, green: 0.15, blue: 0.3, alpha: 1))
        Painter.text(in: doc.context, string: "Paintbox", at: CGPoint(x: 44, y: 150),
                     font: NSFont.boldSystemFont(ofSize: 40), color: .black)
        doc.touch()

        // Two things that only exist in the editing half and that the pixel checks
        // cannot show: marching ants tracing an IRREGULAR mask (the brush stroke, wanded
        // by colour) and a floating paste with its corner handles.
        controller.canvas.selection = MagicWand.select(in: doc.context,
                                                       at: CGPoint(x: 200, y: 220),
                                                       tolerance: 40, contiguous: true)
        let badge = Bitmap.makeContext(width: 90, height: 60)
        badge.withTopLeftOrigin { c in
            c.setFillColor(NSColor(srgbRed: 0.2, green: 0.6, blue: 0.35, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
            c.setFillColor(NSColor.white.cgColor)
            c.fill(CGRect(x: 8, y: 8, width: 74, height: 44))
        }
        controller.canvas.beginFloating(image: badge.makeImage()!,
                                        at: CGPoint(x: 250, y: 40))

        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()

        // Let the async layout in buildUI run, then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = controller.window, let content = window.contentView else { exit(1) }
            // The content view's superview is the window frame, so the toolbar is included.
            let view = content.superview ?? content
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
            view.cacheDisplay(in: bounds, to: rep)
            let scale = rep.pixelsWide > Int(bounds.width) ? 2 : 1
            if let data = rep.representation(using: .png, properties: [:]) {
                if let failure = writePNG(data, to: path) {
                    FileHandle.standardError.write(Data((failure + "\n").utf8))
                    exit(1)
                }
                print("wrote \(path): \(rep.pixelsWide)x\(rep.pixelsHigh) pixels "
                      + "for a \(Int(bounds.width))x\(Int(bounds.height)) point view (backing scale \(scale)x)")
                exit(0)
            }
            print("could not render the window")
            exit(1)
        }
    }
}

import AppKit
import CoreGraphics
import Foundation

protocol PaintDocumentObserver: AnyObject {
    func documentDidChangeImage(_ doc: PaintDocument, sizeChanged: Bool)
    func documentDidChangeMetadata(_ doc: PaintDocument)
}

/// The model: one mutable RGBA bitmap plus undo bookkeeping.
///
/// Undo is done with whole-image snapshots. A 1024x768 canvas is 3 MB a step, which is
/// cheap enough that every operation - strokes, crops, canvas resizes, remove-background -
/// restores byte for byte with no per-operation inverse to get wrong.
final class PaintDocument {
    private(set) var context: CGContext
    private var cachedImage: CGImage?

    weak var observer: PaintDocumentObserver?
    var undoManager: UndoManager?

    var fileURL: URL? { didSet { observer?.documentDidChangeMetadata(self) } }

    /// Whether there is work in here that the file on disk does not have. Derived, never
    /// set from outside: see `changesSinceSave` and `markDirty()`.
    private(set) var isDirty: Bool = false {
        didSet { if isDirty != oldValue { observer?.documentDidChangeMetadata(self) } }
    }

    /// How many undoable operations the bitmap stands ahead of the file on disk —
    /// negative when it has been wound back past it.
    ///
    /// The dirty flag used to be one-way: anything that changed a pixel set it, and only
    /// saving cleared it. So draw, save, draw again, ⌘Z and Paintbox still offered to
    /// save a picture identical to the one in the file, on close and on quit. Counting
    /// instead — forward on a change, BACK when that change is undone — is what lets the
    /// document notice it has returned to where the file is. `registerUndo` is the single
    /// place every undoable operation passes through, which is why the count lives there.
    private var changesSinceSave = 0

    /// Set when the picture was changed outside the undo system, so no amount of undoing
    /// can talk the document back into being clean. New From Clipboard is the case: its
    /// pixels came from nowhere on disk and there is no step to take back.
    private var changedOutsideUndo = false

    var pixelWidth: Int { context.width }
    var pixelHeight: Int { context.height }
    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight) }

    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }

    /// How many frames the file this document was opened from contained.
    ///
    /// Paintbox edits ONE frame — `Bitmap.load` has always taken index 0 — which is a
    /// reasonable limit for an editor but not one to keep quiet about: open a 40-frame
    /// animated GIF, crop it, press ⌘S and the other 39 frames were gone, in place, with
    /// no dialog anywhere in the path. Anything above 1 makes the window say so and
    /// makes the first save over that file ask first.
    var sourceFrameCount: Int = 1 { didSet { observer?.documentDidChangeMetadata(self) } }

    /// The colour space the file was stored in when it was wider than sRGB, e.g.
    /// "Display P3" — nil for the sRGB and grey files that are nearly everything.
    ///
    /// The same admission `sourceFrameCount` makes about frames, made about colour: the
    /// canvas is 8-bit sRGB, so those colours were clipped on the way in and saving
    /// writes the clipped version back. See `Bitmap.wideGamutName`.
    var sourceWideGamut: String? = nil { didSet { observer?.documentDidChangeMetadata(self) } }

    /// Open a file as a document: the first frame's pixels, plus how many frames were
    /// really in there, plus whether colour was lost getting them here. One place, so no
    /// caller can load a file and forget to ask.
    static func open(url: URL) -> PaintDocument? {
        // The context, not an image of it: the file has already been normalised into a
        // canvas-shaped buffer, and drawing that into a second one doubled both the time
        // and the peak memory of every Open. See `Bitmap.loadContext`.
        guard let ctx = Bitmap.loadContext(url: url) else { return nil }
        let doc = PaintDocument(adopting: ctx, url: url)
        // `load` succeeded, so there is at least one frame whatever the count says.
        doc.sourceFrameCount = max(1, Bitmap.frameCount(url: url))
        doc.sourceWideGamut = Bitmap.wideGamutName(url: url)
        return doc
    }

    init(width: Int, height: Int, fill: NSColor?) {
        context = Bitmap.makeContext(width: width, height: height)
        if let fill {
            context.setFillColor((fill.usingColorSpace(.sRGB) ?? .white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Take ownership of a context somebody else built, instead of copying it in.
    ///
    /// The caller must hand over the only reference: two documents sharing one buffer
    /// would each see the other's strokes and neither could undo them. `Bitmap.loadContext`
    /// makes a fresh one per call for exactly that reason.
    ///
    /// A context that is not laid out the way the rest of the app reads pixels is copied
    /// rather than adopted — wrong bytes are worse than a slow open.
    init(adopting ctx: CGContext, url: URL? = nil) {
        if Bitmap.isCanonical(ctx) {
            context = ctx
        } else {
            context = Bitmap.makeContext(width: ctx.width, height: ctx.height)
            if let image = ctx.makeImage() {
                context.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            }
        }
        fileURL = url
    }

    convenience init(image: CGImage, url: URL? = nil) {
        self.init(width: image.width, height: image.height, fill: nil)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        fileURL = url
    }

    /// An immutable copy of the current pixels.
    var image: CGImage {
        if let cachedImage { return cachedImage }
        let img = context.makeImage()!
        cachedImage = img
        return img
    }

    func snapshot() -> CGImage { image }

    // MARK: - Mutation

    /// Call BEFORE mutating. Captures the current state as the undo point and, when
    /// replayed, captures the then-current state as the redo point.
    /// One call, one undo step.
    ///
    /// The group is opened and closed around the registration rather than left to the
    /// run loop, because event grouping made every registration in one event a single
    /// step (see PaintWindowController.init). Closing it immediately is safe precisely
    /// because the snapshot is taken HERE, before the mutation the caller is about to
    /// make: nothing that follows needs to be inside the group.
    func registerUndo(name: String) {
        // Counted before the early return, because a document with no undo manager still
        // has to know it was changed. Undoing steps BACK towards the file on disk; a
        // fresh change, redo included, steps away from it.
        if undoManager?.isUndoing == true {
            changesSinceSave -= 1
        } else {
            changesSinceSave += 1
        }
        refreshDirty()
        guard let undoManager else { return }
        let img = image
        let w = pixelWidth
        let h = pixelHeight
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { doc in
            doc.registerUndo(name: name)
            doc.install(image: img, width: w, height: h)
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    /// Replace the whole bitmap. `image == nil` means a transparent canvas.
    func install(image newImage: CGImage?, width: Int, height: Int) {
        let sizeChanged = (width != pixelWidth || height != pixelHeight)
        let ctx = Bitmap.makeContext(width: width, height: height)
        if let newImage {
            ctx.draw(newImage, in: CGRect(x: 0, y: 0, width: newImage.width, height: newImage.height))
        }
        context = ctx
        cachedImage = nil
        refreshDirty()
        observer?.documentDidChangeImage(self, sizeChanged: sizeChanged)
    }

    /// Call after drawing straight into `context`.
    func touch() {
        cachedImage = nil
        refreshDirty()
        observer?.documentDidChangeImage(self, sizeChanged: false)
    }

    /// Mark the picture as changed by something the undo stack knows nothing about, so
    /// that no amount of undoing can make the document look saved. New From Clipboard.
    func markDirty() {
        changedOutsideUndo = true
        refreshDirty()
    }

    private func refreshDirty() {
        isDirty = changedOutsideUndo || changesSinceSave != 0
    }

    /// Draw into the bitmap with top-left origin coordinates, as one undoable step.
    func edit(_ name: String, _ body: (CGContext) -> Void) {
        registerUndo(name: name)
        context.withTopLeftOrigin(body)
        touch()
    }

    // MARK: - Saving

    /// `format` defaults to whatever the file extension says. Lossy formats use
    /// `quality`; formats with no alpha channel are flattened onto `matte`.
    ///
    /// It used to fall back to PNG when the extension meant nothing, and that was the
    /// quietest way this app could destroy a file. Paintbox opens everything ImageIO can
    /// read — .webp, .psd, .dng, .tga — which is a longer list than it can write, so
    /// ⌘S on one of those wrote a PNG stream into a file still named `logo.webp`, marked
    /// the document clean, and said nothing. The file was gone and mislabelled at once.
    /// ImageFormats.swift already says why WebP is not offered as an export: "writing a
    /// PNG while calling it a WebP would be worse than saying no". This is that rule
    /// applied to the one path that was breaking it.
    func save(to url: URL, format: SaveFormat? = nil, quality: CGFloat = 0.8,
              matte: NSColor = .white) throws {
        guard let fmt = format ?? SaveFormat.forExtension(url.pathExtension) else {
            throw PaintboxError.message("Paintbox cannot write \(Self.describe(extension: url.pathExtension)). "
                                        + "Use Save As… to pick a format it can write.")
        }
        try Bitmap.write(image, to: url, format: fmt, quality: quality, matte: matte)
        fileURL = url
        // This is now where the file is, so it is where the count is measured from and
        // whatever happened before it is on disk. Undoing back to here makes the document
        // clean again rather than merely earlier.
        changesSinceSave = 0
        changedOutsideUndo = false
        refreshDirty()
        // Whatever this document was opened from, the file it now points at is the one
        // frame we just wrote. See `sourceFrameCount`.
        sourceFrameCount = 1
        // And it is sRGB, because that is all `Bitmap.write` writes. The clipping has
        // happened; there is nothing left to warn about.
        sourceWideGamut = nil
        observer?.documentDidChangeMetadata(self)
    }

    /// "a file with no extension" / ".webp files", for the message above.
    static func describe(extension ext: String) -> String {
        ext.isEmpty ? "a file with no extension" : ".\(ext.lowercased()) files"
    }
}

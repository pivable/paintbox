import AppKit

enum Tool: String, CaseIterable {
    case pencil, brush, eraser, line, arrow, rectangle, ellipse, bucket, eyedropper, text, select, wand

    var title: String {
        switch self {
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .bucket: return "Paint Bucket"
        case .eyedropper: return "Eyedropper"
        case .text: return "Text"
        case .select: return "Rectangular Selection"
        case .wand: return "Magic Wand"
        }
    }

    /// Single-key shortcut, shown in the Tools menu and on the palette buttons.
    var key: String {
        switch self {
        case .pencil: return "p"
        case .brush: return "b"
        case .eraser: return "e"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .bucket: return "f"
        case .eyedropper: return "i"
        case .text: return "t"
        case .select: return "s"
        case .wand: return "w"
        }
    }

    var symbolName: String {
        switch self {
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .line: return "line.diagonal"
        case .arrow: return "line.diagonal.arrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .bucket: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .text: return "textformat"
        case .select: return "dot.squareshape.split.2x2"
        case .wand: return "wand.and.stars"
        }
    }

    var usesShapeStyle: Bool { self == .rectangle || self == .ellipse }

    /// The two tools that drag out a shape from a start point, share the line width,
    /// and preview the same way.
    var isLineLike: Bool { self == .line || self == .arrow }
}

enum ShapeStyle: Int {
    case outline = 0, filled = 1, both = 2
}

/// Shared, observable-by-callback bag of everything the tools need.
final class ToolSettings {
    var tool: Tool = .pencil { didSet { if tool != oldValue { notify() } } }
    var foreground: NSColor = .black { didSet { notify() } }
    var background: NSColor = .white { didSet { notify() } }
    var brushSize: CGFloat = 16 { didSet { notify() } }
    var strokeWidth: CGFloat = 2 { didSet { notify() } }
    var tolerance: Int = 32 { didSet { notify() } }
    /// Kept separate from the bucket's tolerance on purpose: people want a tight fill
    /// and a loose selection at the same time, and sharing one slider makes them fight.
    var wandTolerance: Int = 32 { didSet { notify() } }
    var shapeStyle: ShapeStyle = .outline { didSet { notify() } }
    var font: NSFont = NSFont.systemFont(ofSize: 36) { didSet { notify() } }

    var onChange: (() -> Void)?
    private func notify() { onChange?() }

    func swapColors() {
        let f = foreground
        foreground = background
        background = f
    }
}

/// The standard palette: twenty colours in MS Paint's own order, laid out seven to a
/// row by `PaletteView` so they fit a 156 pt column.
enum StandardPalette {
    static let colors: [NSColor] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        return [
            c(0, 0, 0), c(127, 127, 127), c(136, 0, 21), c(237, 28, 36),
            c(255, 127, 39), c(255, 242, 0), c(34, 177, 76), c(0, 162, 232),
            c(63, 72, 204), c(163, 73, 164), c(255, 255, 255), c(195, 195, 195),
            c(185, 122, 87), c(255, 174, 201), c(255, 201, 14), c(239, 228, 176),
            c(181, 230, 29), c(153, 217, 234), c(112, 146, 190), c(200, 191, 231),
        ]
    }()
}

/// Every SF Symbol the interface asks for, in one place so the self-test can check
/// they all resolve on this system. A missing symbol shows up as a blank button.
enum Symbols {
    static let crop = "crop"
    static let resize = "arrow.up.left.and.down.right.magnifyingglass"
    static let canvasSize = "squareshape.dashed.squareshape"
    static let flipH = "arrow.left.and.right.righttriangle.left.righttriangle.right"
    static let flipV = "arrow.up.and.down.righttriangle.up.righttriangle.down"
    static let rotateCW = "rotate.right"
    static let rotateCCW = "rotate.left"
    static let removeBG = "person.and.background.dotted"
    static let zoomIn = "plus.magnifyingglass"
    static let zoomOut = "minus.magnifyingglass"
    static let zoomFit = "arrow.up.left.and.arrow.down.right"
    static let undo = "arrow.uturn.backward"
    static let redo = "arrow.uturn.forward"
    static let blur = "wind"
    static let pixelate = "squareshape.split.3x3"
    static let adjust = "slider.horizontal.3"
    static let grayscale = "circle.lefthalf.filled"
    static let invert = "circle.righthalf.filled"
    static let trim = "scissors"

    static let all: [String] = [crop, resize, canvasSize, flipH, flipV, rotateCW, rotateCCW,
                                removeBG, zoomIn, zoomOut, zoomFit, undo, redo,
                                blur, pixelate, adjust, grayscale, invert, trim]
        + Tool.allCases.map { $0.symbolName }
}

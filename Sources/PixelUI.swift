import AppKit

enum Palette {
    static let paper = NSColor(calibratedWhite: 0.965, alpha: 1)
    static let ink = NSColor.black
    static let secondary = NSColor(calibratedWhite: 0.43, alpha: 1)
    static let line = NSColor(calibratedWhite: 0.83, alpha: 1)
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
           color: NSColor = Palette.ink, mono: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = 1
    field.lineBreakMode = .byTruncatingTail
    return field
}

final class PaperView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Palette.paper.setFill(); bounds.fill() }
}

// Every pixel is a vector rectangle: crisp at any display scale, no image assets.
enum Crocodile {
    static let resting = [
        "..........####.................",
        ".........######................",
        ".........##.###................",
        "........########.#############.",
        ".......########################",
        "......#########################",
        ".....########################..",
        "#...################...........",
        "##.##########################..",
        "#############################..",
        ".###########################...",
        "..#########################....",
        "....#####################......",
        "......#####.......#####........",
        "......###.........###..........",
        "......####........####........."
    ]
    static let biting = [
        "..........####.................",
        ".........######................",
        ".........##.###................",
        "........########.#############.",
        ".......########################",
        "......#########################",
        ".....#############.#..#..#.....",
        "#...############...............",
        "##.#############...............",
        "################...............",
        ".###############...............",
        "..##############...............",
        "##################.#..#..#......",
        ".############################..",
        "..###########################..",
        "....#####################......",
        "......#####.......#####........",
        ".......###.........###.........",
        ".......####........####........"
    ]
    static func draw(at origin: NSPoint, pixel: CGFloat, open: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false
        Palette.ink.setFill()
        for (y, row) in (open ? biting : resting).enumerated() {
            for (x, value) in row.enumerated() where value == "#" {
                NSRect(x: origin.x.rounded() + CGFloat(x) * pixel, y: origin.y.rounded() + CGFloat(y) * pixel, width: pixel, height: pixel).fill()
            }
        }
    }
    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 31, height: 18), flipped: true) { _ in
            draw(at: NSPoint(x: 0, y: 1), pixel: 1, open: false)
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class PixelScene: NSView {
    override var isFlipped: Bool { true }
    var shownProgress: Double = 0
    var targetProgress: Double = 0
    var working = false
    var completed = false
    var hasData = false
    var tick = 0
    var timer: Timer?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("小さな黒いドット絵のワニと、口に収まる4段の容量バー")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func update(progress: Double, working: Bool, completed: Bool, hasData: Bool) {
        self.targetProgress = progress; self.working = working; self.completed = completed; self.hasData = hasData
        if !working && !completed { shownProgress = 0 }
        if working || (completed && shownProgress < targetProgress) {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.tick += 1
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.shownProgress = self.targetProgress }
                    else { self.shownProgress = min(self.targetProgress, self.shownProgress + 0.055) }
                    self.needsDisplay = true
                    if !self.working && self.shownProgress >= self.targetProgress { self.timer?.invalidate(); self.timer = nil }
                }
            }
        } else { timer?.invalidate(); timer = nil }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        // 3pt sprite pixels; open mouth has 5 empty rows = 15pt. Four 3pt rows + three 1pt gaps = 15pt.
        let pixel: CGFloat = 3
        let mouthX: CGFloat = 20 + 31 * pixel
        let barY: CGFloat = 58
        let step: CGFloat = 5, dot: CGFloat = 3
        let columns = max(1, Int((bounds.width - mouthX - 16) / step))
        let distance = CGFloat(columns - 1) * step
        let chewing = (working || shownProgress < targetProgress) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let crocX = 20 + (distance * shownProgress).rounded()
        for col in 0..<columns {
            let gone = Double(col + 1) / Double(columns) <= shownProgress
            guard !gone else { continue }
            (hasData ? Palette.ink : Palette.line).setFill()
            for row in 0..<4 {
                NSRect(x: mouthX + CGFloat(col) * step, y: barY + CGFloat(row) * 4, width: dot, height: dot).fill()
            }
        }
        Crocodile.draw(at: NSPoint(x: crocX, y: barY - 7 * pixel), pixel: pixel, open: chewing ? tick % 6 < 3 : hasData && !completed)
        if chewing && tick % 6 < 3 {
            Palette.ink.setFill()
            NSRect(x: crocX + 94, y: barY-9, width: 3, height: 3).fill()
        }
        if completed && shownProgress >= targetProgress && targetProgress > 0 {
            Palette.ink.setFill()
            let sparkles: [(CGFloat, CGFloat)] = [(0,0),(-5,5),(5,5),(0,10)]
            for (x,y) in sparkles { NSRect(x: crocX + 24 + x, y: CGFloat(15) + y, width: 3, height: 3).fill() }
        }
        Palette.line.setFill(); NSRect(x: 20, y: 94, width: bounds.width-40, height: 1).fill()
    }
}

final class PixelButton: NSButton {
    var primary = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        (primary ? Palette.ink : Palette.paper).setFill(); border.fill()
        Palette.ink.setStroke(); border.lineWidth = 1; border.stroke()
        // Cut-out corners on a 3-point grid.
        Palette.paper.setFill()
        for rect in [NSRect(x: 0, y: 0, width: 3, height: 3), NSRect(x: bounds.width-3, y: 0, width: 3, height: 3), NSRect(x: 0, y: bounds.height-3, width: 3, height: 3), NSRect(x: bounds.width-3, y: bounds.height-3, width: 3, height: 3)] { rect.fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: isEnabled ? (primary ? NSColor.white : Palette.ink) : Palette.secondary]
        let str = NSAttributedString(string: title, attributes: attributes)
        str.draw(at: NSPoint(x: (bounds.width-str.size().width)/2, y: (bounds.height-str.size().height)/2))
        if isHighlighted { NSColor.white.withAlphaComponent(0.16).setFill(); bounds.fill() }
        if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)).stroke() }
    }
}

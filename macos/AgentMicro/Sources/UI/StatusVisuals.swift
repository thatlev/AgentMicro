import AppKit
import SwiftUI

enum StatusTone: Equatable {
    case healthy
    case connecting
    case actionRequired
    case failed
    case idle

    var color: Color {
        switch self {
        case .healthy:
            return Color(nsColor: .systemGreen)
        case .connecting:
            return Color(nsColor: .systemYellow)
        case .actionRequired:
            return Color(nsColor: .systemOrange)
        case .failed:
            return Color(nsColor: .systemRed)
        case .idle:
            return Color(nsColor: .systemGray)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .healthy:
            return .systemGreen
        case .connecting:
            return .systemYellow
        case .actionRequired:
            return .systemOrange
        case .failed:
            return .systemRed
        case .idle:
            return .systemGray
        }
    }

    var systemImage: String {
        switch self {
        case .healthy:
            return "checkmark.circle.fill"
        case .connecting:
            return "clock.fill"
        case .actionRequired:
            return "exclamationmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .idle:
            return "minus.circle.fill"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .healthy:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .actionRequired:
            return "Action required"
        case .failed:
            return "Connection failed"
        case .idle:
            return "Inactive"
        }
    }

    static func inferred(from text: String, fallback: StatusTone) -> StatusTone {
        let value = text.lowercased()

        if value.contains("fail")
            || value.contains("error")
            || value.contains("disconnected")
            || value.contains("unavailable")
            || value.contains("timed out") {
            return .failed
        }

        if value.contains("required")
            || value.contains("unpatched")
            || value.contains("permission")
            || value.contains("attention")
            || value.contains("update") {
            return .actionRequired
        }

        if value.contains("checking")
            || value.contains("connecting")
            || value.contains("starting")
            || value.contains("retry")
            || value.contains("waiting") {
            return .connecting
        }

        if value.contains("paused")
            || value.contains("not found")
            || value.contains("not running")
            || value.contains("offline")
            || value.contains("idle") {
            return .idle
        }

        if value.contains("verified")
            || value.contains("connected")
            || value.contains("ready")
            || value.contains("running")
            || value.contains("operational")
            || value.contains("patched") {
            return .healthy
        }

        return fallback
    }
}

enum AgentMicroGlyph {
    /// Width is what costs menu bar room: the status item's window is the
    /// image width plus a fixed 16pt of system padding. 16pt of mark gives a
    /// 32pt item, against the 36pt a system icon beside it takes.
    static let canvasSize: CGFloat = 16

    /// Height is free, and it decides where the mark sits relative to the
    /// popover's arrow.
    ///
    /// The button is always the full height of the menu bar and the arrow
    /// points at its bottom edge, so a square image leaves the mark floating
    /// with dead space beneath it and the arrow reads as detached. Drawing on
    /// a canvas as tall as the button, with the mark at its base, closes that
    /// to roughly a point without changing the width at all.
    static let canvasHeight: CGFloat = 22

    /// Keeps the mark optically centred in the bar rather than sitting on the
    /// floor of its canvas.
    static let baselineInset: CGFloat = 3
    /// Just enough to keep the stroke off the edge. The stroke is centred on
    /// its path, so half the line width sits outside the rect.
    static let clearMargin: CGFloat = 0.6
    static let outlineWidth: CGFloat = 1.1

    /// Draws the mark inside `markRect`: a rounded outline with a 3x3 grid of
    /// keys, matching the pad the phone stands in for.
    private static func drawMark(in markRect: NSRect) {
        let rect = markRect.insetBy(dx: clearMargin, dy: clearMargin)
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let outline = NSBezierPath(roundedRect: rect, xRadius: 2.6, yRadius: 2.6)
        outline.lineWidth = outlineWidth
        outline.stroke()

        let keySize: CGFloat = 1.7
        let spacing: CGFloat = 1.3
        let gridSize = (keySize * 3) + (spacing * 2)
        let originX = rect.midX - (gridSize / 2)
        let originY = rect.midY - (gridSize / 2)

        for row in 0..<3 {
            for column in 0..<3 {
                let keyRect = NSRect(
                    x: originX + CGFloat(column) * (keySize + spacing),
                    y: originY + CGFloat(row) * (keySize + spacing),
                    width: keySize,
                    height: keySize
                )
                NSBezierPath(roundedRect: keyRect, xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
    }

    /// The menu bar image: mark-width, button-height, mark at the base.
    ///
    /// This must be a cached representation, not an `NSImage` drawing-handler
    /// closure. AppKit can ask every status item to draw whenever *any* menu-bar
    /// app changes. A lazy provider therefore reran all of this Bezier drawing
    /// even though AgentMicro's glyph was static.
    static let image = renderedImage(
        size: NSSize(width: canvasSize, height: canvasHeight),
        markRect: NSRect(
            x: 0,
            y: baselineInset,
            width: canvasSize,
            height: canvasSize
        )
    )

    /// The same mark on a square canvas, for use inside normal layout.
    static let squareImage = renderedImage(
        size: NSSize(width: canvasSize, height: canvasSize),
        markRect: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    )

    private static func renderedImage(size: NSSize, markRect: NSRect) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        drawMark(in: markRect)
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "AgentMicro"
        return image
    }
}

struct MicroGlyphView: View {
    var size: CGFloat = 18

    var body: some View {
        // The menu bar image is deliberately taller than it is wide, so
        // squeezing it into a square frame here would distort the mark.
        Image(nsImage: AgentMicroGlyph.squareImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

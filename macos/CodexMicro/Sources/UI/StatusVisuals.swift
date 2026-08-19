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

enum CodexMicroGlyph {
    /// The menu bar reserves a square the height of the bar, so a glyph drawn
    /// edge to edge reads wider than every system icon beside it. AppKit's own
    /// templates keep roughly a sixth of the square as clear margin; matching
    /// that is what makes an icon look like it belongs in the bar.
    static let canvasSize: CGFloat = 18
    static let clearMargin: CGFloat = 2.4

    static let image: NSImage = {
        let image = NSImage(
            size: NSSize(width: canvasSize, height: canvasSize),
            flipped: false
        ) { fullRect in
            let rect = fullRect.insetBy(dx: clearMargin, dy: clearMargin)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let outline = NSBezierPath(
                roundedRect: rect,
                xRadius: 2.6,
                yRadius: 2.6
            )
            outline.lineWidth = 1.2
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
                    NSBezierPath(
                        roundedRect: keyRect,
                        xRadius: 0.55,
                        yRadius: 0.55
                    ).fill()
                }
            }

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AgentMicro"
        return image
    }()
}

struct MicroGlyphView: View {
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: CodexMicroGlyph.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

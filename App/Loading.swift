import SwiftUI

/// The app's mark, the ink V with the orange pulse, the pulse drawn again every 1.6 s: a wait with no count, as a
/// connect, the mechanic thinking or a read starting. The beat runs from the clock, so it goes on across a tab switch,
/// a push and pop or a recycled row. Under reduced motion it holds still, drawn in full. `size` is its width; the
/// pulse's line is never thinner than a point.
struct PulseMark: View {
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            V().fill(Color.vynInk)
            TimelineView(.animation(paused: reduceMotion)) { context in
                // How far into its beat the pulse is, 0 to 1; 1 under reduced motion.
                let phase = reduceMotion
                    ? 1 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Pulse()
                    // Eased in and out, back to empty at the end of each beat.
                    .trim(from: 0, to: 0.5 - cos(.pi * phase) / 2)
                    .stroke(
                        Color.vynOrange,
                        style: StrokeStyle(lineWidth: max(1, 3.5 * size / 128), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size * 104 / 128)
        .accessibilityElement()
        .accessibilityLabel("Working")
    }
}

extension PulseMark {
    /// The V, from the mark's drawing.
    private nonisolated struct V: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: 4, y: 8))
                path.addLine(to: CGPoint(x: 28, y: 8))
                path.addQuadCurve(to: CGPoint(x: 39, y: 15), control: CGPoint(x: 35, y: 8))
                path.addLine(to: CGPoint(x: 64, y: 58))
                path.addLine(to: CGPoint(x: 89, y: 15))
                path.addQuadCurve(to: CGPoint(x: 100, y: 8), control: CGPoint(x: 93, y: 8))
                path.addLine(to: CGPoint(x: 124, y: 8))
                path.addLine(to: CGPoint(x: 75, y: 88))
                path.addQuadCurve(to: CGPoint(x: 53, y: 88), control: CGPoint(x: 64, y: 106))
                path.closeSubpath()
            }
            .applying(PulseMark.box(rect))
        }
    }

    /// The pulse, from the mark's drawing: the line along the V, then the beat inside it.
    private nonisolated struct Pulse: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: 13, y: 19))
                path.addLine(to: CGPoint(x: 26, y: 24))
                path.addQuadCurve(to: CGPoint(x: 34, y: 31), control: CGPoint(x: 31, y: 26))
                path.addLine(to: CGPoint(x: 64, y: 82))
                path.addLine(to: CGPoint(x: 94, y: 31))
                path.addQuadCurve(to: CGPoint(x: 102, y: 24), control: CGPoint(x: 97, y: 26))
                path.addLine(to: CGPoint(x: 115, y: 19))
                path.addLines([
                    CGPoint(x: 49, y: 49), CGPoint(x: 55, y: 34), CGPoint(x: 60, y: 56), CGPoint(x: 64, y: 20),
                    CGPoint(x: 68, y: 56), CGPoint(x: 73, y: 34), CGPoint(x: 79, y: 49),
                ])
            }
            .applying(PulseMark.box(rect))
        }
    }

    /// Scales the drawing's 128×104 box into `rect`, centred, keeping its proportions.
    private nonisolated static func box(_ rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / 128, rect.height / 104)
        return CGAffineTransform(translationX: rect.midX - 64 * scale, y: rect.midY - 52 * scale)
            .scaledBy(x: scale, y: scale)
    }
}

/// A wait with a count: what runs and how far, in words, over a bar in the accent.
struct ProgressLine: View {
    let value: Double
    let total: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.vyn(.footnote))
                .foregroundStyle(Color.vynMuted)
            ProgressView(value: value, total: total)
                .tint(Color.vynOrange)
        }
    }
}

/// The scan's progress line: the address it is at, of FF, and the modules that answered so far; Reconnecting to the
/// adapter… while the link comes back.
struct ScanProgress: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        ProgressLine(
            value: Double(flow.scanned), total: 255,
            label: flow.reconnecting
                ? "Reconnecting to the adapter…"
                : "Scanning \(String(format: "%02X", flow.scanned)) of FF · \(flow.modules.count) answered so far")
    }
}

/// Placeholder rows where a list's first rows will be, two bars each in the line color, a highlight sweeping across
/// them every 1.4 s; under reduced motion the bars hold still. Hidden from VoiceOver.
struct SkeletonRows: View {
    var count = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            GeometryReader { proxy in
                let width = proxy.size.width
                let bars = VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Color.vynLine).frame(width: width * 0.6, height: 14)
                    Capsule().fill(Color.vynLine).frame(width: width * 0.35, height: 10)
                }
                bars
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        // On the clock, not a state, so the highlight crosses every row together, however late a row
                        // comes. Under reduced motion it stops, left of the bars, where the mask hides it.
                        TimelineView(.animation(paused: reduceMotion)) { context in
                            let elapsed = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 1.4)
                            LinearGradient(
                                colors: [.clear, Color.vynPaper.opacity(0.7), .clear], startPoint: .leading,
                                endPoint: .trailing)
                            .offset(x: reduceMotion ? -width : (2 * elapsed / 1.4 - 1) * width)
                        }
                    }
                    // The highlight shows on the bars alone.
                    .mask(alignment: .leading) { bars }
            }
            .frame(height: 30)
        }
        .accessibilityHidden(true)
    }
}

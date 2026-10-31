import SwiftUI

/// The app's mark, the ink V with the orange pulse, the pulse drawn again every 1.6 s: a wait with no count, as a
/// connect, the mechanic thinking or a read starting. Under reduced motion it holds still, drawn in full. `size` is
/// its width.
struct PulseMark: View {
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            V().fill(Color.vynInk)
            Pulse()
                .trim(from: 0, to: (reduceMotion || drawn) ? 1 : 0)
                .stroke(
                    Color.vynOrange, style: StrokeStyle(lineWidth: 3.5 * size / 128, lineCap: .round, lineJoin: .round))
                // Scoped to the pulse: `withAnimation` in `onAppear` would also repeat a layout change of that update.
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: drawn)
                .onAppear { drawn = !reduceMotion }
                // A change of reduced motion makes a new pulse: still while it is on, beating again once it is off.
                .id(reduceMotion)
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

/// The scan's progress line: the address it is at, of FF, and the modules that answered so far.
struct ScanProgress: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        ProgressLine(
            value: Double(flow.scanned), total: 255,
            label: "Scanning \(String(format: "%02X", flow.scanned)) of FF · \(flow.modules.count) answered so far")
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

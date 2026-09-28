import SwiftUI

struct KnobView: View {
    let label: String
    let sublabel: String
    @Binding var value: Double          // 0–100
    let display: (Double) -> String

    @State private var startValue: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#d9d1bf"))
                Text(sublabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "#8f8778"))
            }
            .frame(width: 70, alignment: .leading)

            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(hex: "#55504a"), Color(hex: "#1e1b17")],
                            center: .init(x: 0.34, y: 0.28),
                            startRadius: 0, endRadius: 22))
                        .frame(width: 40, height: 40)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))

                    // indicator dot
                    Circle()
                        .fill(Color(hex: "#ff7a3d"))
                        .frame(width: 3, height: 3)
                        .shadow(color: Color(hex: "#ff7a3d"), radius: 4)
                        .offset(y: -13)
                        .rotationEffect(.degrees(-135 + value / 100 * 270))
                }
                // Without this, only the inscribed circle registers drags —
                // the corners of its own 40x40 bounding box (still visually
                // "on the knob" to a user) are dead space by SwiftUI's default
                // hit-testing for a Circle shape.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let delta = Double(-drag.translation.height) * 0.55
                            value = max(0, min(100, startValue + delta))
                        }
                        .onEnded { _ in startValue = value }
                )
                .onAppear { startValue = value }

                Text(display(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "#8f8778"))
                    .frame(width: 44)
            }
        }
    }
}

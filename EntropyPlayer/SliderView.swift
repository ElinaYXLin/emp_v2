import SwiftUI

// Vertical slider used for both Pre-Amp and Macro.
// pct: 0 = bottom of travel, 100 = top of travel.
// label and value display are caller-supplied.
struct VerticalSliderView: View {
    let title: String
    @Binding var pct: Double            // 0–100
    let displayText: String
    let accentColor: Color

    @State private var startPct: Double = 0
    @State private var isDragging = false

    private let trackH: CGFloat = 220
    private let trackW: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#8f8778"))
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 30)
                .padding(.bottom, 8)

            GeometryReader { geo in
                ZStack(alignment: .top) {
                    // track background
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [accentColor, Color(hex: "#6e6a62"), Color(hex: "#423f3a")],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: trackW, height: trackH)
                        .cornerRadius(2)
                        .overlay(Rectangle()
                            .stroke(Color.black.opacity(0.7), lineWidth: 1)
                            .cornerRadius(2))

                    // fill (above handle = active region)
                    let fillFrac = CGFloat(1 - pct / 100)
                    Rectangle()
                        .fill(Color(hex: "#423f3a"))
                        .frame(width: trackW, height: trackH * fillFrac)
                        .cornerRadius(2)

                    // handle
                    let handleY = trackH * CGFloat(1 - pct / 100) - 7
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#7a746a"), Color(hex: "#56514a"), Color(hex: "#1c1a16")],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 14)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .overlay(
                            Circle()
                                .fill(RadialGradient(
                                    colors: [Color(hex: "#8a8072"), Color(hex: "#2a2620")],
                                    center: .init(x: 0.35, y: 0.3),
                                    startRadius: 0, endRadius: 4))
                                .frame(width: 5, height: 5)
                        )
                        .offset(x: (trackW - 26) / 2, y: handleY)
                }
                .frame(width: trackW)
                // Widen the hit-test area to comfortably cover the 26pt-wide
                // handle (previously an offset invisible rectangle that didn't
                // actually line up with where the handle renders — the offset
                // centered on the track's own center, not accounting for the
                // handle's additional centering offset, so clicks on the
                // visible handle often landed outside the real hit area).
                // Centering the narrow visual within a wider frame keeps the
                // math simple and guaranteed-aligned.
                .frame(width: geo.size.width, height: trackH, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDragging { startPct = pct; isDragging = true }
                            let dy    = drag.translation.height
                            let delta = Double(-dy / trackH) * 100
                            pct = max(0, min(100, startPct + delta))
                        }
                        .onEnded { _ in isDragging = false; startPct = pct }
                )
            }
            .frame(width: 40, height: trackH)

            Text(displayText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "#8f8778"))
                .padding(.top, 8)
        }
        .frame(width: 50)
    }
}

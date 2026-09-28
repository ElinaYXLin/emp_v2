import SwiftUI

struct WaveformView: View {
    let peaks: [Float]                  // static decoded peaks (0–1)
    let liveSamples: [Float]            // real-time analyser (0–1 abs)
    let isPlaying: Bool
    let macro: Double                   // waterline: 0 = top, 100 = bottom
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let waterlineY = size.height * (1 - macro / 100)

            // waterline glow
            var wl = Path()
            wl.move(to:    .init(x: 0,          y: waterlineY))
            wl.addLine(to: .init(x: size.width, y: waterlineY))
            ctx.stroke(wl, with: .color(.init(hex: "#ff7a3d").opacity(0.45)), lineWidth: 1)

            let bars   = isPlaying ? liveSamples : peaks
            guard !bars.isEmpty else { return }

            let barW   = size.width / CGFloat(bars.count)
            let bx0    = barW * 0.15
            let bw     = barW * 0.7
            let halfH  = size.height / 2

            for (i, v) in bars.enumerated() {
                let amp   = CGFloat(v) * halfH * 0.86
                let x     = CGFloat(i) * barW
                let topY  = halfH - amp
                let botY  = halfH + amp

                // upper half
                drawBar(ctx: ctx, x: x, bx: bx0, bw: bw,
                        segTop: topY, segBot: halfH,
                        waterY: waterlineY, color: color,
                        seed: Float(i) * 0.37)

                // lower half (mirror)
                drawBar(ctx: ctx, x: x, bx: bx0, bw: bw,
                        segTop: halfH, segBot: botY,
                        waterY: waterlineY, color: color,
                        seed: Float(i) * 0.37 + 0.5)
            }
        }
        .background(Color(hex: "#1b1814"))
        .border(Color.black.opacity(0.6), width: 1)
    }

    private func drawBar(ctx: GraphicsContext, x: CGFloat, bx: CGFloat, bw: CGFloat,
                         segTop: CGFloat, segBot: CGFloat,
                         waterY: CGFloat, color: Color, seed: Float) {
        guard segBot > segTop else { return }
        let cleanBot = min(segBot, waterY)
        // Clean region (above waterline)
        if cleanBot > segTop {
            var p = Path()
            p.addRect(.init(x: x + bx, y: segTop, width: bw, height: cleanBot - segTop))
            ctx.fill(p, with: .color(color))
        }
        // Degraded region (below waterline)
        let degTop = max(segTop, waterY)
        if segBot > degTop {
            let segH = segBot - degTop
            for c in 0..<4 {
                let cy  = degTop + (segH / 4) * CGFloat(c)
                let ch  = (segH / 4) * CGFloat(0.45 + 0.4 * abs(sin(seed * 10 + Float(c))))
                let jit = sin(seed * 20 + Float(c) * 3) * Float(bw) * 0.18
                let grey = Double(0.5 + 0.3 * abs(cos(seed * 7 + Float(c))))
                var p = Path()
                p.addRect(.init(x: x + bx + CGFloat(jit), y: cy, width: bw - 2, height: ch))
                ctx.fill(p, with: .color(.init(white: 0.35 + grey * 0.25, opacity: 0.85)))
            }
        }
    }
}

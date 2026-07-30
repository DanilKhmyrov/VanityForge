import SwiftUI

/// Лёгкая частичная "вспышка" при появлении новой находки — чисто
/// декоративная фишка, ничего не считает и не блокирует.
struct ParticleBurst: View {
    let color: Color
    let seed: Int

    private struct Particle {
        let angle: Double
        let speed: Double
        let size: Double
        let delay: Double
    }

    private let particles: [Particle]
    private let start = Date()

    init(color: Color, seed: Int) {
        self.color = color
        self.seed = seed
        var generator = SeededGenerator(seed: seed)
        self.particles = (0..<12).map { _ in
            Particle(
                angle: Double.random(in: 0..<360, using: &generator),
                speed: Double.random(in: 30...70, using: &generator),
                size: Double.random(in: 2.5...5, using: &generator),
                delay: Double.random(in: 0...0.06, using: &generator)
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for p in particles {
                    let t = elapsed - p.delay
                    guard t > 0, t < 0.55 else { continue }
                    let progress = t / 0.55
                    let distance = p.speed * progress
                    let rad = p.angle * .pi / 180
                    let x = center.x + cos(rad) * distance
                    let y = center.y + sin(rad) * distance
                    let opacity = 1 - progress
                    let particleSize = p.size * (1 - progress * 0.5)
                    let rect = CGRect(x: x - particleSize / 2, y: y - particleSize / 2, width: particleSize, height: particleSize)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

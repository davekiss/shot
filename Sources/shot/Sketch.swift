import CoreGraphics
import Foundation

/// The hand-drawn mark style: shapes a person would draw with a pen. Circles
/// overshoot where they started, box sides run past their corners, lines bow,
/// and arrows end in two quick strokes. The wobble is seeded from the shape
/// itself, so the same call always draws the same picture.
enum Sketch {
    /// SplitMix64: tiny, fast and deterministic.
    struct Wobble {
        var state: UInt64
        init(_ seeds: CGFloat...) {
            state = seeds.reduce(0x9E37_79B9_7F4A_7C15) { $0 &* 31 &+ UInt64(bitPattern: Int64(($1 * 10).rounded())) }
        }
        mutating func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return CGFloat(Double(z ^ (z >> 31)) / Double(UInt64.max))
        }
        /// Uniform in -1...1.
        mutating func signed() -> CGFloat { next() * 2 - 1 }
    }

    /// A stroke from p0 to p1 that bows slightly, as a hand drags a pen.
    /// `outward` forces the bow to one side (-1 or 1); box sides use it so they never bow into the text.
    static func line(_ p0: CGPoint, _ p1: CGPoint, width w: CGFloat, _ rng: inout Wobble, outward: CGFloat? = nil) -> (path: CGPath, control: CGPoint) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y, len = max(hypot(dx, dy), 1)
        let n = CGPoint(x: -dy / len, y: dx / len)
        let amount = rng.signed() * min(len * 0.03, w * 3)
        let bow = outward.map { abs(amount) * $0 } ?? amount
        let along = 0.45 + rng.next() * 0.1
        let c = CGPoint(x: p0.x + dx * along + n.x * bow, y: p0.y + dy * along + n.y * bow)
        let path = CGMutablePath()
        path.move(to: p0)
        path.addQuadCurve(to: p1, control: c)
        return (path, c)
    }

    /// Four sides, each starting a little before its corner and running a
    /// little past the next, drawn twice like a quick double pass.
    static func rect(_ r: CGRect, width w: CGFloat, pass: Int) -> CGPath {
        var rng = Wobble(r.minX, r.minY, r.width, r.height, CGFloat(pass))
        let path = CGMutablePath()
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1)
            let u = CGPoint(x: dx / len, y: dy / len)
            let over = w * (0.6 + rng.next() * 1.2), under = w * rng.next() * 0.8
            // Corners wander only outward (sides run clockwise, so outward is -normal).
            let out = CGPoint(x: u.y, y: -u.x)
            let jitter = { (p: CGPoint, rng: inout Wobble) -> CGPoint in
                let o: CGFloat = rng.next() * w * 0.6
                let along: CGFloat = rng.signed() * w * 0.4
                return CGPoint(x: p.x + out.x * o + u.x * along, y: p.y + out.y * o + u.y * along)
            }
            let start = jitter(CGPoint(x: a.x - u.x * under, y: a.y - u.y * under), &rng)
            let end = jitter(CGPoint(x: b.x + u.x * over, y: b.y + u.y * over), &rng)
            path.addPath(line(start, end, width: w, &rng, outward: -1).path)
        }
        return path
    }

    /// One loop that starts somewhere on the ellipse, wanders a little in
    /// radius, and overshoots its start rather than closing neatly.
    static func ellipse(_ r: CGRect, width w: CGFloat, exponent n: CGFloat = 2) -> CGPath {
        var rng = Wobble(r.midX, r.midY, r.width, r.height)
        let start = -CGFloat.pi * (0.55 + rng.next() * 0.3)
        let sweep = CGFloat.pi * 2 + 0.45 + rng.next() * 0.4
        let phase = rng.next() * .pi * 2, wander = 0.04 + rng.next() * 0.03
        let steps = 96
        let path = CGMutablePath()
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps), angle = start + sweep * t
            // Wobble and drift only ever push outward, so the loop can pass
            // its start without ever cutting into what it circles.
            let wobble = wander * (1 + 0.6 * sin(angle * 2 + phase) + 0.4 * sin(angle * 3 + phase * 2)) / 2
            let k = 1 + wobble + 0.07 * t
            let p = Shapes.point(CGPoint(x: r.midX, y: r.midY), a: r.width / 2, b: r.height / 2, n: n, t: angle, scale: k)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }

    /// A bowed shaft and a head of two quick strokes.
    static func arrow(from p0: CGPoint, to p1: CGPoint, width w: CGFloat) -> CGPath {
        var rng = Wobble(p0.x, p0.y, p1.x, p1.y)
        let (shaft, c) = line(p0, p1, width: w, &rng)
        let path = CGMutablePath()
        path.addPath(shaft)
        // The head follows the curve's direction where it lands, not the straight line.
        let tx = p1.x - c.x, ty = p1.y - c.y, tl = max(hypot(tx, ty), 1)
        let back = atan2(-ty / tl, -tx / tl)
        for side in [-1.0, 1.0] as [CGFloat] {
            let spread = (0.42 + rng.next() * 0.12) * side
            let len = w * (4.2 + rng.next() * 1.4)
            path.move(to: p1)
            path.addLine(to: CGPoint(x: p1.x + cos(back + spread) * len, y: p1.y + sin(back + spread) * len))
        }
        return path
    }

    /// A highlighter swipe through the middle of `r`, slightly tilted.
    static func highlight(_ r: CGRect) -> CGPath {
        var rng = Wobble(r.minX, r.minY, r.width)
        let tilt = rng.signed() * r.height * 0.12
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX + r.height * 0.2, y: r.midY + tilt))
        path.addQuadCurve(to: CGPoint(x: r.maxX - r.height * 0.2, y: r.midY - tilt),
                          control: CGPoint(x: r.midX, y: r.midY + rng.signed() * r.height * 0.08))
        return path
    }
}

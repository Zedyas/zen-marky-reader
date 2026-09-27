import Foundation

// Generates assets/logo.svg and assets/logo-wordmark.svg.
// The mark is an enso (an open, brush-drawn circle) framing a rendered document:
// one heading rule and two body rules. Run: swift scripts/make-logo.swift

let ink = "#2b3a35"
let center = 512.0
let radius = 372.0
let gapCenterDegrees = 38.0   // upper right, SVG angles (clockwise, 0 = right)
let gapDegrees = 30.0
let maxWidth = 96.0
let minWidth = 26.0
let samples = 56

func point(angle: Double, offset: Double) -> (Double, Double) {
    let r = radius + offset
    return (center + r * cos(angle), center + r * sin(angle))
}

// Brush width: heavy where the brush lands, thinning to a tail where it lifts.
func width(at t: Double) -> Double {
    let profile = pow(1 - t, 1.5) * (0.82 + 0.18 * sin(.pi * t))
    return minWidth + (maxWidth - minWidth) * profile
}

// Slight radial wobble so the ring reads as hand drawn instead of geometric.
func wobble(at t: Double) -> Double {
    5 * sin(2 * .pi * t + 0.9) + 2.5 * sin(4 * .pi * t + 2.1)
}

let start = (gapCenterDegrees + gapDegrees / 2) * .pi / 180
let sweep = (360 - gapDegrees) * .pi / 180

var outer: [(Double, Double)] = []
var inner: [(Double, Double)] = []
for i in 0...samples {
    let t = Double(i) / Double(samples)
    let angle = start + sweep * t
    let w = width(at: t) / 2
    outer.append(point(angle: angle, offset: wobble(at: t) + w))
    inner.append(point(angle: angle, offset: wobble(at: t) - w))
}

// Round caps at both ends.
func cap(from a: (Double, Double), to b: (Double, Double), bulge: Double) -> [(Double, Double)] {
    let dx = b.0 - a.0, dy = b.1 - a.1
    let length = (dx * dx + dy * dy).squareRoot()
    let nx = -dy / length * bulge, ny = dx / length * bulge
    return (1...5).map { i in
        let s = Double(i) / 6 * .pi
        let along = (1 - cos(s)) / 2
        let out = sin(s)
        return (a.0 + dx * along + nx * out * length / 2, a.1 + dy * along + ny * out * length / 2)
    }
}

let endCap = cap(from: outer[samples], to: inner[samples], bulge: -1)
let startCap = cap(from: inner[0], to: outer[0], bulge: -1)
let ring = outer + endCap + inner.reversed() + startCap

// Catmull-Rom through the ring, emitted as cubic Beziers for a smooth closed outline.
func f(_ v: Double) -> String { String(format: "%.1f", v) }
var d = "M\(f(ring[0].0)) \(f(ring[0].1))"
let n = ring.count
for i in 0..<n {
    let p0 = ring[(i - 1 + n) % n], p1 = ring[i], p2 = ring[(i + 1) % n], p3 = ring[(i + 2) % n]
    let c1 = (p1.0 + (p2.0 - p0.0) / 6, p1.1 + (p2.1 - p0.1) / 6)
    let c2 = (p2.0 - (p3.0 - p1.0) / 6, p2.1 - (p3.1 - p1.1) / 6)
    d += "C\(f(c1.0)) \(f(c1.1)) \(f(c2.0)) \(f(c2.1)) \(f(p2.0)) \(f(p2.1))"
}
d += "Z"

let document = """
<rect x="382" y="412" width="260" height="42" rx="21"/>
<rect x="382" y="500" width="260" height="22" rx="11"/>
<rect x="382" y="566" width="172" height="22" rx="11"/>
"""

let mark = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" fill="\(ink)" role="img" aria-label="Zen Marky">
<path d="\(d)"/>
\(document)</svg>

"""

let wordmark = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2170 1024" fill="\(ink)" role="img" aria-label="Zen Marky">
<path d="\(d)"/>
\(document)<text x="1020" y="600" font-family="Iowan Old Style, Palatino, Georgia, serif" font-size="250" letter-spacing="-4">Zen Marky</text>
</svg>

"""

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try mark.write(to: assets.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
try wordmark.write(to: assets.appendingPathComponent("logo-wordmark.svg"), atomically: true, encoding: .utf8)
print("Wrote assets/logo.svg and assets/logo-wordmark.svg")

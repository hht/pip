import CoreGraphics
import Foundation
import Testing
@testable import MascotCore

private func area(_ p: EyeOutline) -> CGFloat {
    p.indices.reduce(0) { s, i in let a = p[i], b = p[(i + 1) % p.count]; return s + a.x * b.y - b.x * a.y } / 2
}

private func cost(_ p: EyeOutline, _ q: EyeOutline) -> CGFloat {
    zip(p, q).reduce(0) { $0 + pow($1.0.x - $1.1.x, 2) + pow($1.0.y - $1.1.y, 2) }
}

private func rotated(_ p: EyeOutline, by k: Int) -> EyeOutline { Array(p[k...] + p[..<k]) }

private func bounds(_ p: EyeOutline) -> CGRect {
    let xs = p.map(\.x), ys = p.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

@Suite struct EyesTests {
    /// docs/mascot.md §3: All eye shapes are 120-point closed polygons with consistent winding for point-by-point tweening
    @Test func everyLookHasComparableRings() {
        for l in Look.allCases {
            let e = l.eyes
            for p in [e.left, e.right] {
                #expect(p.count == Eyes.pointCount, "\(l)")
                #expect(area(p) > 0, "\(l) winding")
            }
        }
    }

    /// Equidistant by arc length: adjacent points have nearly equal distance
    @Test func ringIsEvenlySpaced() {
        let p = Look.mismatch.eyes.left
        let d = p.indices.map { i in hypot(p[i].x - p[(i + 1) % p.count].x, p[i].y - p[(i + 1) % p.count].y) }
        #expect(d.max()! - d.min()! < 1e-3)
    }

    /// Right eye mirrors left eye; thinking, working, dizzy have both eyes facing the same direction
    @Test func mirroring() {
        for l in Look.allCases {
            let e = l.eyes
            let same = [Look.thinking, .working, .dizzy].contains(l)
            let b = bounds(e.right), a = bounds(e.left)
            let expectedMidX = same ? a.midX : -a.midX
            #expect(abs(b.midX - expectedMidX) < 1e-6 && abs(b.width - a.width) < 1e-6, "\(l)")
        }
    }

    /// O-eye is a true circle r 1.45; tall oval eye 1.25 x 1.9; thinking offset to (0.35, -0.5)
    @Test func sizes() {
        let o = bounds(Look.mismatch.eyes.left)
        #expect(abs(o.width - 2.9) < 0.01 && abs(o.height - 2.9) < 0.01)
        let q = bounds(Look.question.eyes.left)
        #expect(abs(q.width - 2.5) < 0.01 && abs(q.height - 3.8) < 0.01)
        let t = bounds(Look.thinking.eyes.left)
        #expect(abs(t.midX - 0.35) < 0.01 && abs(t.midY + 0.5) < 0.01)
    }

    /// Clipped eyes: droopy eye top edge at -0.25, calm eye top edge at -0.75
    @Test func clipped() {
        #expect(abs(bounds(Look.stale.eyes.left).minY + 0.25) < 1e-6)
        #expect(abs(bounds(Look.shielded.eyes.left).minY + 0.75) < 1e-6)
    }

    /// Stroked eye shape converted to outline: smiling eye width is centerline width 3.4 plus line width 0.9
    @Test func strokeOutline() {
        let b = bounds(Look.finished.eyes.left)
        #expect(abs(b.width - 4.3) < 0.02)
    }

    /// After scaling by 1.35x, eyes remain within body circle (docs/mascot.md §1)
    @Test func insideBody() {
        for l in Look.allCases {
            let e = l.eyes
            for (poly, rest) in [(e.left, Anatomy.leftEye), (e.right, Anatomy.rightEye)] {
                for p in poly {
                    let x = rest.x + p.x * Eyes.scale, y = rest.y + p.y * Eyes.scale
                    #expect(hypot(x - Anatomy.bodyCenter.x, y - Anatomy.bodyCenter.y) < Anatomy.bodyRadius, "\(l)")
                }
            }
        }
    }

    /// Align start point: shifting start point of previous shape and aligning back yields itself; resulting squared distance is minimum among all start points
    @Test func alignment() {
        let q = Look.idle.eyes.left
        #expect(Eyes.aligned(rotated(q, by: 37), to: q) == q)
        let p = Look.danger.eyes.left
        let a = Eyes.aligned(p, to: q)
        for k in 0..<p.count { #expect(cost(a, q) <= cost(rotated(p, by: k), q) + 1e-9) }
    }

    /// Blink: compress along vertical center to 0.1x height, width unchanged
    @Test func shut() {
        let open = Look.idle.eyes.left
        let s = Eyes.shut(open)
        let a = bounds(open), b = bounds(s)
        #expect(abs(b.height - a.height * 0.1) < 1e-9 && abs(b.width - a.width) < 1e-9 && abs(b.midY - a.midY) < 1e-9)
    }
}

/// Project following Core Animation conventions in flipped view (docs/mascot.md §1 measured: positive rotation.x = look up, positive rotation.y = face right):
/// Sphere center as origin, +z towards viewer, +y downwards. Eye at front (0, 0, r) rotates pitch around x axis, yaw around y axis, and headYaw for whole head
private func project(_ rest: CGPoint, headYaw: Double = 0) -> (x: Double, y: Double, facing: Bool) {
    let (pitch, yaw) = Sphere.place(rest)
    let r = Double(Anatomy.bodyRadius)
    // Looking up: front point moves upward (-y)
    let y = -r * sin(pitch), z1 = r * cos(pitch)
    let x = z1 * sin(yaw), z = z1 * cos(yaw)
    let x2 = x * cos(headYaw) + z * sin(headYaw), z2 = -x * sin(headYaw) + z * cos(headYaw)
    return (x2, y, z2 > 0)
}

@Suite struct SphereTests {
    /// docs/mascot.md §1: Left eye offset from center by ~20 deg; slightly below equator, so pitch looks downward
    @Test func placement() {
        let (pitch, yaw) = Sphere.place(Anatomy.leftEye)
        #expect(abs(pitch + asin(0.05)) < 1e-12)
        #expect(abs(yaw * 180 / .pi + 20.5) < 0.1)
    }

    /// Round-trip matches rest center: x and y match, no offset above center
    @Test func roundTrip() {
        for rest in [Anatomy.leftEye, Anatomy.rightEye] {
            let p = project(rest)
            #expect(abs(p.x - Double(rest.x - Anatomy.bodyCenter.x)) < 1e-9)
            #expect(abs(p.y - Double(rest.y - Anatomy.bodyCenter.y)) < 1e-9)
        }
    }

    /// Turn face 90 deg right: left eye moves near right edge (still visible), right eye turns to back; at 180 deg neither is visible
    @Test func turning() {
        let side = project(Anatomy.leftEye, headYaw: 90 * .pi / 180)
        #expect(side.facing && side.x > 9)
        #expect(!project(Anatomy.rightEye, headYaw: 90 * .pi / 180).facing)
        #expect(!project(Anatomy.leftEye, headYaw: .pi).facing && !project(Anatomy.rightEye, headYaw: .pi).facing)
    }
}

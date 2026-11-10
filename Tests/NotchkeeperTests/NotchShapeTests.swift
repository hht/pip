import SwiftUI
import Testing
@testable import Notchkeeper

/// Shooting stars along the card edge travel along `leftHalf` and its mirror; must align with outline from `path(in:)`.
@Suite struct NotchShapeHalves {
    private let shape = NotchShape(topRadius: 14, bottomRadius: 28, closed: false)
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 90)

    @Test func leftHalfRunsFromTopLeftToBottomCenter() {
        let half = shape.leftHalf(in: rect)
        #expect(half.cgPath.currentPoint == CGPoint(x: rect.midX, y: rect.maxY))
        var first: CGPoint?
        half.forEach { if first == nil, case .move(let p) = $0 { first = p } }
        #expect(first == CGPoint(x: rect.minX, y: rect.minY))
    }

    /// Left half plus its mirror covers the complete bounding box outline.
    @Test func halvesCoverTheOutline() {
        let half = shape.leftHalf(in: rect).cgPath
        var mirror = CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1)
        let both = half.boundingBoxOfPath.union(half.copy(using: &mirror)!.boundingBoxOfPath)
        #expect(both == shape.path(in: rect).cgPath.boundingBoxOfPath)
    }
}

import SwiftUI
import Testing
@testable import Notchkeeper

@Suite struct ClaudeMarkPath {
    /// Lowercase is relative to the previous point, uppercase is absolute; additional coordinate pairs following m are implicit l.
    @Test func relativeAndAbsoluteCommands() {
        var expected = Path()
        expected.move(to: CGPoint(x: 1, y: 2))
        expected.addLine(to: CGPoint(x: 4, y: 6))
        expected.addLine(to: CGPoint(x: 9, y: 6))
        expected.addLine(to: CGPoint(x: 9, y: 0.5))
        expected.addCurve(to: CGPoint(x: 10, y: 3.5), control1: CGPoint(x: 9.5, y: 0.5), control2: CGPoint(x: 10, y: 1.5))
        expected.addLine(to: CGPoint(x: 0, y: 0))
        expected.closeSubpath()
        #expect(ClaudeMark.path("m1 2 3 4h5v-5.5c.5 0 1 1 1 3L0 0Z") == expected)
    }

    /// Extracted path heavily omits command letters (repeated l / h / c commands), packing numbers together (`1.5.5` is 1.5 and .5, `.25-1` is .25 and -1).
    @Test func implicitRepeatsAndPackedNumbers() {
        var expected = Path()
        expected.move(to: .zero)
        expected.addLine(to: CGPoint(x: 1.5, y: 0.5))
        expected.addLine(to: CGPoint(x: 1.75, y: -0.5))
        expected.addLine(to: CGPoint(x: 2.75, y: -0.5))
        expected.addLine(to: CGPoint(x: 3.75, y: -0.5))
        expected.addCurve(to: CGPoint(x: 4.75, y: -0.5), control1: CGPoint(x: 3.75, y: 0.5), control2: CGPoint(x: 4.75, y: 0.5))
        expected.addCurve(to: CGPoint(x: 5.75, y: -0.5), control1: CGPoint(x: 4.75, y: -1.5), control2: CGPoint(x: 5.75, y: -1.5))
        #expect(ClaudeMark.path("M0 0l1.5.5.25-1h1 1c0 1 1 1 1 0 0-1 1-1 1 0") == expected)
    }

    /// Full extracted path parses completely and fills the 100 x 100 canvas.
    @Test func markFillsItsCanvas() {
        let box = ClaudeMark.unit.boundingRect
        #expect(box.minX >= 0 && box.minY >= 0 && box.maxX <= 100 && box.maxY <= 100)
        #expect(box.width > 95 && box.height > 95)
    }
}

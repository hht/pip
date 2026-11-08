import Foundation
import Testing
@testable import Notchkeeper

/// Temporary directory with installed `bin/pipctl` and PATH link `.local/bin/pipctl`.
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pipctl-link-\(UUID().uuidString)")
    var target: URL { root.appendingPathComponent("bin/pipctl") }
    var link: URL { root.appendingPathComponent(".local/bin/pipctl") }

    init() throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: target)
    }
}

@Suite struct CommandLineToolLink {
    /// Creates `.local/bin` if it does not yet exist.
    @Test func linkThenUnlink() throws {
        let s = try Sandbox()
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .absent)
        try CommandLineTool.createLink(s.link, target: s.target)
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .linked)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.link.path) == s.target.path)
        try CommandLineTool.removeLink(s.link, target: s.target)
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .absent)
        // If link was deleted in terminal while settings pane was open, clicking remove again won't error.
        try CommandLineTool.removeLink(s.link, target: s.target)
    }

    /// Pre-existing file or external symlink is left untouched.
    @Test(arguments: [false, true])
    func occupiedIsLeftAlone(_ symlink: Bool) throws {
        let s = try Sandbox()
        try FileManager.default.createDirectory(at: s.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if symlink {
            try FileManager.default.createSymbolicLink(atPath: s.link.path, withDestinationPath: "/usr/bin/true")
        } else {
            try Data("someone-elses".utf8).write(to: s.link)
        }
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .occupied)
        #expect(throws: (any Error).self) { try CommandLineTool.createLink(s.link, target: s.target) }
        #expect(throws: (any Error).self) { try CommandLineTool.removeLink(s.link, target: s.target) }
        if symlink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.link.path) == "/usr/bin/true")
        } else {
            #expect(try String(contentsOf: s.link, encoding: .utf8) == "someone-elses")
        }
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .occupied)
    }
}

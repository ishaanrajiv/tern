import Foundation
import XCTest
@testable import Tern

final class SecurityTests: XCTestCase {
    /// What /bin/sh makes of a command line: each argument on its own line.
    private func shellWords(_ line: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -- " + line + "; printf '%s\\n' \"$@\""]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testResumeCommandsTypeTheSessionIDAsData() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tern-resume-\(UUID().uuidString)")
        let hostile = "x; touch \(marker.path) $(touch \(marker.path)) 'quoted'"
        let claude = try XCTUnwrap(Workspace.resumeCommand(agent: "claude", session: hostile))
        XCTAssertEqual(try shellWords(claude), ["claude", "--resume", hostile])
        let codex = try XCTUnwrap(Workspace.resumeCommand(agent: "codex", session: hostile))
        XCTAssertEqual(try shellWords(codex), ["codex", "resume", hostile])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try shellWords(XCTUnwrap(Workspace.resumeCommand(agent: "claude", session: "abc-123"))),
                       ["claude", "--resume", "abc-123"])
        XCTAssertNil(Workspace.resumeCommand(agent: "vim", session: "x"))
    }

    func testAnEndlessLineFromTheDaemonIsDropped() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let conn = LineConnection(fd: fds[0])
        let writer = fds[1]
        let done = expectation(description: "reader gave up")
        DispatchQueue.global().async {
            XCTAssertNil(conn.readLine())
            done.fulfill()
        }
        // No newline, ever; the reader stops past its limit rather than buffering forever.
        let chunk = [UInt8](repeating: 0x78, count: 64 * 1024)
        DispatchQueue.global().async {
            var sent = 0
            while sent <= LineConnection.maxLine + chunk.count {
                let n = chunk.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                sent += n
            }
        }
        wait(for: [done], timeout: 10)
        close(writer)
    }

    func testAShortLineStillReads() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let conn = LineConnection(fd: fds[0])
        let line = Array("[]\n".utf8)
        _ = line.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(conn.readLine().map { String(decoding: $0, as: UTF8.self) }, "[]")
        close(fds[1])
    }
}

import Foundation
import Testing

@testable import SDImportCore

@Suite("CopyEngine")
struct CopyEngineTests {
    @Test("copies large files with bounded chunks")
    func copiesLargeFileWithBoundedChunks() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("large-source.bin")
        let destination = directory.appendingPathComponent("large-destination.bin")
        let size = 64 * 1024 * 1024

        try createPatternFile(at: source, byteCount: size)

        var chunkCount = 0
        var largestChunk = 0
        try CopyEngine(chunkSize: 16 * 1024 * 1024).copyFile(
            from: source,
            to: destination,
            expectedSize: Int64(size),
            modificationDate: nil
        ) { chunkSize in
            chunkCount += 1
            largestChunk = max(largestChunk, chunkSize)
        }

        let copiedSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
        #expect(copiedSize?.intValue == size)
        #expect(chunkCount > 1)
        #expect(largestChunk <= 1024 * 1024)
    }

    private func createPatternFile(at url: URL, byteCount: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }

        let block = Data((0..<4096).map { UInt8($0 % 251) })
        var remaining = byteCount
        while remaining > 0 {
            let count = min(remaining, block.count)
            try handle.write(contentsOf: block.prefix(count))
            remaining -= count
        }
    }
}

import Foundation
import Testing
@testable import GroqVoice

@Suite struct RecorderTests {
    @Test func wavHeaderRoundTrips() throws {
        var pcm = Data()
        for i in 0..<1600 {  // 0.1 s of a ramp
            let v = Int16(truncatingIfNeeded: (i % 200) * 100)
            pcm.append(UInt8(truncatingIfNeeded: v))
            pcm.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        let wav = Recorder.wav(pcm16: pcm)
        #expect(wav.count == 44 + pcm.count)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let range = try #require(Recorder.dataChunkRange(in: wav))
        #expect(range == 44..<(44 + pcm.count))
        #expect(wav.subdata(in: range) == pcm)
    }

    @Test func dataChunkRangeSkipsExtraChunks() {
        // RIFF + a 5-byte "LIST" chunk (padded to 6) before "data".
        var d = Data()
        d.append(contentsOf: "RIFF".utf8); d.append(contentsOf: [0, 0, 0, 0]); d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "LIST".utf8); d.append(contentsOf: [5, 0, 0, 0]); d.append(contentsOf: [1, 2, 3, 4, 5, 0])
        d.append(contentsOf: "data".utf8); d.append(contentsOf: [2, 0, 0, 0]); d.append(contentsOf: [9, 9])
        #expect(Recorder.dataChunkRange(in: d) == (d.count - 2)..<d.count)
    }
}

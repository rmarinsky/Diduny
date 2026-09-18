@testable import Diduny
import XCTest

final class WAVHeaderTests: XCTestCase {
    func test_headerIsExactly44Bytes() {
        let header = WAVBuilder.headerData(sampleRate: 24_000, dataLength: 4800, channels: 1, bitsPerSample: 16)
        XCTAssertEqual(header.count, 44)
    }

    func test_containsCanonicalRiffChunks() {
        let header = WAVBuilder.headerData(sampleRate: 24_000, dataLength: 100, channels: 1, bitsPerSample: 16)
        let magic = { (offset: Int, length: Int) in
            String(data: header.subdata(in: offset ..< (offset + length)), encoding: .ascii)
        }
        XCTAssertEqual(magic(0, 4), "RIFF")
        XCTAssertEqual(magic(8, 4), "WAVE")
        XCTAssertEqual(magic(12, 4), "fmt ")
        XCTAssertEqual(magic(36, 4), "data")
    }

    func test_headerFieldsFor24kHzMono16Bit() {
        let header = WAVBuilder.headerData(sampleRate: 24_000, dataLength: 4800, channels: 1, bitsPerSample: 16)

        func u32(_ offset: Int) -> Int {
            Int(header.subdata(in: offset ..< offset + 4).reduce(0) { ($0 << 8) | Int($1) }) // little-endian
        }
        func u16(_ offset: Int) -> Int {
            Int(header.subdata(in: offset ..< offset + 2).reduce(0) { ($0 << 8) | Int($1) })
        }

        XCTAssertEqual(u16(20), 1, "audioFormat must be PCM")
        XCTAssertEqual(u16(22), 1, "channels")
        XCTAssertEqual(u32(24), 24_000, "sample rate")
        XCTAssertEqual(u32(28), 48_000, "byte rate = sampleRate * channels * bits/8")
        XCTAssertEqual(u16(32), 2, "block align")
        XCTAssertEqual(u16(34), 16, "bits per sample")
        XCTAssertEqual(u32(4), 36 + 4800, "RIFF chunk size = 36 + data length")
        XCTAssertEqual(u32(40), 4800, "data chunk size")
    }

    func test_wavDataPrependsHeaderToPCM() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let wav = WAVBuilder.wavData(fromPCM: pcm, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(Data(wav.suffix(pcm.count)), pcm)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
    }

    func test_stereoHeaderMath() {
        let header = WAVBuilder.headerData(sampleRate: 48_000, dataLength: 9600, channels: 2, bitsPerSample: 16)
        func u32(_ offset: Int) -> Int {
            Int(header.subdata(in: offset ..< offset + 4).reduce(0) { ($0 << 8) | Int($1) })
        }
        XCTAssertEqual(u32(28), 48_000 * 2 * 16 / 8, "byte rate accounts for both channels")
    }
}

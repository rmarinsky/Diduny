@testable import Diduny
import XCTest

final class TTSResponseDecodingTests: XCTestCase {
    func test_decodesVoicesResponseWithSnakeCaseLabels() throws {
        let json = """
        {
          "success": true,
          "message": "Voices fetched successfully",
          "data": [
            {
              "voice_id": "fbb75ed2-975a-40c7-9e06-38e30524a9a1",
              "name": "Zara",
              "model": "60db Fast",
              "labels": {
                "language": "hi",
                "language_name": "Hindi",
                "gender": "female",
                "accent": "Indian"
              },
              "description": null,
              "categories": ["IVR/Call Center", "Audiobook"]
            },
            {
              "voice_id": "038cf0d1-eef8-45a6-81b0-99c5e57a33d2",
              "name": "Atlas",
              "labels": {
                "language": "en",
                "language_name": "English",
                "gender": "male",
                "accent": "American"
              }
            }
          ],
          "meta": { "model": "fast" }
        }
        """

        let response = try JSONDecoder().decode(TTSVoicesResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.data.count, 2)

        let zara = response.data[0]
        XCTAssertEqual(zara.voiceId.uuidString.lowercased(), "fbb75ed2-975a-40c7-9e06-38e30524a9a1")
        XCTAssertEqual(zara.name, "Zara")
        XCTAssertEqual(zara.labels?.languageName, "Hindi")
        XCTAssertEqual(zara.labels?.gender, "female")
        XCTAssertNil(zara.descriptionText)
        XCTAssertEqual(zara.categories, ["IVR/Call Center", "Audiobook"])
        XCTAssertEqual(zara.subtitle, "Hindi · female")

        let atlas = response.data[1]
        XCTAssertEqual(atlas.subtitle, "English · male")
        XCTAssertNil(atlas.categories)
    }

    func test_decodesSynthesisResponse() throws {
        let pcm = Data([0xAB, 0xCD, 0xEF, 0x01])
        let json = """
        {
          "success": true,
          "message": "Synthesis complete",
          "audio_base64": "\(pcm.base64EncodedString())",
          "sample_rate": 24000,
          "duration_seconds": 2.5,
          "encoding": "LINEAR16",
          "output_format": "wav"
        }
        """

        let response = try JSONDecoder().decode(TTSSynthesisResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.sampleRate, 24_000)
        XCTAssertEqual(response.durationSeconds, 2.5)
        XCTAssertEqual(response.encoding, "LINEAR16")
        XCTAssertEqual(response.outputFormat, "wav")
        XCTAssertEqual(Data(base64Encoded: response.audioBase64), pcm)
    }

    func test_ttsErrorDescriptionsAreUserFacing() {
        XCTAssertTrue(TTSError.noAPIKey.errorDescription?.contains("API key") == true)
        XCTAssertTrue(TTSError.apiError(status: 400, message: "bad voice").errorDescription?.contains("bad voice") == true)
        XCTAssertNotNil(TTSError.invalidResponse.errorDescription)
        XCTAssertNotNil(TTSError.noAudioData.errorDescription)
        XCTAssertNotNil(TTSError.playbackFailed("boom").errorDescription)
    }
}

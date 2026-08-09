import XCTest
import MediaServerKit

final class RemoteModelsTests: XCTestCase {

    func testAlbumRoundTrip() throws {
        let a = RemoteAlbumInfo(id: "abc", name: "Trip", videoCount: 3, type: "video")
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(RemoteAlbumInfo.self, from: data)
        XCTAssertEqual(a, decoded)
    }

    func testAlbumDecodesMissingType() throws {
        let json = Data(#"{"id":"x","name":"N","videoCount":0}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteAlbumInfo.self, from: json)
        XCTAssertNil(decoded.type)
    }

    /// サーバーは .iso8601 でエンコードし、クライアントは .iso8601 でデコードする取り決め。
    func testVideoISO8601Contract() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let v = RemoteVideoInfo(id: "1", filename: "a.mp4", duration: 12.5,
                                importDate: Date(timeIntervalSince1970: 1_700_000_000),
                                creationDate: nil, mediaType: "video")
        let data = try enc.encode(v)
        let decoded = try dec.decode(RemoteVideoInfo.self, from: data)
        XCTAssertEqual(v, decoded)
        XCTAssertFalse(decoded.isPhoto)
    }

    func testIsPhoto() {
        let photo = RemoteVideoInfo(id: "1", filename: "a.heic", duration: 0,
                                    importDate: Date(), creationDate: nil, mediaType: "photo")
        let video = RemoteVideoInfo(id: "2", filename: "b.mp4", duration: 1,
                                    importDate: Date(), creationDate: nil, mediaType: "video")
        XCTAssertTrue(photo.isPhoto)
        XCTAssertFalse(video.isPhoto)
    }

    func testVideoDecodesMissingOptionalFields() throws {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let json = Data(#"{"id":"1","filename":"a.mp4","duration":3.0,"importDate":"2024-01-01T00:00:00Z"}"#.utf8)
        let decoded = try dec.decode(RemoteVideoInfo.self, from: json)
        XCTAssertNil(decoded.creationDate)
        XCTAssertNil(decoded.mediaType)
        XCTAssertFalse(decoded.isPhoto)
    }
}

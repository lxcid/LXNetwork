import XCTest
@testable import LXNetwork

class TCPSessionTests: XCTestCase {
    
    func testUseCase() {
        do {
            let session = try TCPSession(host: "google.com", port: 80, secure: false)
            session.delegate = self
            session.open()
            let requestData = "GET / HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            try session.asyncSend(data: requestData)
            let _ = self.expectation(description: "Some wait for TCP")
            self.waitForExpectations(timeout: 5.0)
//            if case TCPSession.State.Closed(let error) = session.state {
//                XCTAssertNil(error)
//            } else {
//                XCTFail()
//            }
        } catch {
            XCTFail()
        }
        print("HAHA")
    }
    
    static var allTests : [(String, (TCPSessionTests) -> () throws -> Void)] {
        return [
            ("testUseCase", testUseCase),
        ]
    }
}

extension TCPSessionTests : TCPSessionDelegate {
    func session(session: TCPSession, didReceiveData data: Data) -> DataBuffer.OutResult {
        print(String(data: data, encoding: .utf8))
        return .NoOperation
    }
}

import XCTest
@testable import LXNetwork

class TCPSessionTests: XCTestCase {
    
    func testUseCase() {
        do {
            let session = try TCPSession(host: "google.com", port: 80, secure: false)
            let expectation = self.expectation(description: "Successfully make a HTTP request to Google.")
            let testCase = TCPSessionTestCase(expectation: expectation)
            session.delegate = testCase
            session.open()
            let requestData = "GET / HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            try session.asyncSend(data: requestData)
            self.waitForExpectations(timeout: 10.0)
            testCase.dummy()
        } catch {
            XCTFail()
        }
    }
    
    static var allTests : [(String, (TCPSessionTests) -> () throws -> Void)] {
        return [
            ("testUseCase", testUseCase),
        ]
    }
}

class TCPSessionTestCase : TCPSessionDelegate {
    let expectation: XCTestExpectation
    
    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }
    
    func session(_ session: TCPSession, didReceiveData data: Data) -> DataBuffer.OutResult {
        print(String(data: data, encoding: .utf8))
        return .Consume(bytes: data.count)
    }
    
    func sessionDidOpen(_ session: TCPSession) {
    }
    
    func session(_ session: TCPSession, didCloseWithError error: Swift.Error?) {
        if case TCPSession.State.closed(let error) = session.state {
            XCTAssertNil(error)
        } else {
            XCTFail()
        }
        self.expectation.fulfill()
    }
    
    func dummy() {}
}

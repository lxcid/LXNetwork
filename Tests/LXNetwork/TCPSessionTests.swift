import XCTest
@testable import LXNetwork

class TCPSessionTests: XCTestCase {
    
    func testUseCase() {
        do {
            let tcpSession = try TCPSession(host: "google.com", port: 80, secure: false)
            tcpSession.delegate = self
            try tcpSession.connect()
            let requestData = "GET / HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            tcpSession.asyncSend(data: requestData)
            let e1 = self.expectation(description: "Some wait for TCP")
            self.waitForExpectations(timeout: 10.0)
            print(tcpSession)
        } catch _ {
            XCTFail()
        }
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

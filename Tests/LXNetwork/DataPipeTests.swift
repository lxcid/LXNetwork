import XCTest
@testable import LXNetwork

class DataPipeTests: XCTestCase {
    func testUseCase() {
        let dataPipe = DataPipe()
        
        let e1 = self.expectation(description: "Expect a HTTP request-line.")
        let httpRequestData = "GET /index.html HTTP/1.1\r\nHost: www.example.com\r\n\r\n".data(using: .utf8)!
        dataPipe.outHandler = { (data: Data) -> DataBuffer.OutResult in
            if data == httpRequestData {
                e1.fulfill()
            }
            return .NoOperation
        }
        dataPipe.asyncIn(data: httpRequestData)
        self.waitForExpectations(timeout: 1.0)
    }
    
    static var allTests : [(String, (DataPipeTests) -> () throws -> Void)] {
        return [
            ("testUseCase", testUseCase),
        ]
    }
}

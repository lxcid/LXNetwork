import XCTest
@testable import LXNetwork

class DataPipeTests: XCTestCase {
    func testUseCase() {
        let dataPipe = DataPipe()
        
        let e1 = self.expectation(description: "Expect a HTTP request-line.")
        let requestLineData = "GET /index.html HTTP/1.1\r\n".data(using: .utf8)!
        dataPipe.outHandler = { (data: Data) -> DataBuffer.OutResult in
            if data == requestLineData {
                e1.fulfill()
            }
            return .NoOperation
        }
        dataPipe.asyncIn(data: requestLineData)
        self.waitForExpectations(timeout: 1.0)
    }
    
    static var allTests : [(String, (DataPipeTests) -> () throws -> Void)] {
        return [
            ("testUseCase", testUseCase),
        ]
    }
}

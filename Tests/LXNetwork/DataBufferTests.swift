import XCTest
@testable import LXNetwork

class DataBufferTests: XCTestCase {
    func testUseCase() {
        let dataBuffer = DataBuffer()
        dataBuffer.asyncIn(data: "Hello, ".data(using: .utf8)!)
        dataBuffer.asyncIn(data: "World!".data(using: .utf8)!)
        
        let expectation = self.expectation(description: "Async IO operations is deterministic…")
        dataBuffer.asyncOut(handler: { (data) -> DataBuffer.OutResult in
            XCTAssertEqual(String(data: data, encoding: .utf8)!, "Hello, World!")
            return .Consume(bytes: data.count)
        }, completionHandler: {
            expectation.fulfill()
        })
        self.waitForExpectations(timeout: 1.0)
        XCTAssertEqual(dataBuffer.data.count, 0)
    }

    static var allTests : [(String, (DataBufferTests) -> () throws -> Void)] {
        return [
            ("testUseCase", testUseCase),
        ]
    }
}

import XCTest
@testable import LXNetwork

class DataBufferTests: XCTestCase {
    func testExample() {
        let dataBuffer = DataBuffer()
        dataBuffer.asyncIn(data: "Hello, ".data(using: .utf8)!)
        dataBuffer.asyncIn(data: "World!".data(using: .utf8)!)
        
        let expectation = self.expectation(description: "Async IO operations is deterministic…")
        dataBuffer.asyncOut(handler: { (data) -> DataBuffer.OutResult in
            defer {
                expectation.fulfill()
            }
            XCTAssertEqual(String(data: data, encoding: .utf8)!, "Hello, World!")
            return .Consume(bytes: data.count)
        })
        self.waitForExpectations(timeout: 5.0)
    }

    static var allTests : [(String, (DataBufferTests) -> () throws -> Void)] {
        return [
            ("testExample", testExample),
        ]
    }
}


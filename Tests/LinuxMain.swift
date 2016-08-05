import XCTest
@testable import LXNetworkTestSuite

XCTMain([
     testCase(DataBufferTests.allTests),
     testCase(DataPipeTests.allTests)
])

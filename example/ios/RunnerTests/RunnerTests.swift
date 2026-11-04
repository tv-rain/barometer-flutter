import XCTest

@testable import barometer_flutter

class RunnerTests: XCTestCase {
  func testBindingLinks() {
    XCTAssertNotNil(BarometerBinding.clientType)
  }
}

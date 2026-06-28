import Foundation
import Testing

@testable import Fenestra

@Suite("Provider timeline validation")
struct ProviderDateParserTests {
  @Test
  func onlyAcceptsAWindowThatContainsTheSnapshotTime() {
    let now = Date(timeIntervalSince1970: 10_000)
    let active = ProviderDateParser.activeWindow(
      start: now.addingTimeInterval(-60),
      end: now.addingTimeInterval(60),
      at: now
    )
    #expect(active.start != nil)
    #expect(active.end != nil)

    let expired = ProviderDateParser.activeWindow(
      start: now.addingTimeInterval(-120),
      end: now.addingTimeInterval(-60),
      at: now
    )
    #expect(expired.start == nil)
    #expect(expired.end == nil)

    let future = ProviderDateParser.activeWindow(
      start: now.addingTimeInterval(60),
      end: now.addingTimeInterval(120),
      at: now
    )
    #expect(future.start == nil)
    #expect(future.end == nil)
  }
}

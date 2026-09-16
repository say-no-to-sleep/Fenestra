import Foundation

struct CursorUsageSummary: Decodable {
  let billingCycleStart: String?
  let billingCycleEnd: String?
  let membershipType: String?
  let individualUsage: CursorIndividualUsage?
}

struct CursorIndividualUsage: Decodable {
  let plan: CursorPlanUsage?
  let overall: CursorOverallUsage?
}

struct CursorPlanUsage: Decodable {
  let used: Double?
  let limit: Double?
  let totalPercentUsed: Double?
  let autoPercentUsed: Double?
  let apiPercentUsed: Double?

  init(
    used: Double? = nil,
    limit: Double? = nil,
    totalPercentUsed: Double? = nil,
    autoPercentUsed: Double? = nil,
    apiPercentUsed: Double? = nil
  ) {
    self.used = used
    self.limit = limit
    self.totalPercentUsed = totalPercentUsed
    self.autoPercentUsed = autoPercentUsed
    self.apiPercentUsed = apiPercentUsed
  }
}

struct CursorOverallUsage: Decodable {
  let used: Double?
  let limit: Double?
}

struct CursorUserInfo: Decodable {
  let email: String?
  let sub: String?
}

struct CursorLegacyUsage: Decodable {
  let gpt4: CursorLegacyModelUsage?

  enum CodingKeys: String, CodingKey {
    case gpt4 = "gpt-4"
  }
}

struct CursorLegacyModelUsage: Decodable {
  let numRequests: Int?
  let numRequestsTotal: Int?
  let maxRequestUsage: Int?
}

struct CursorAuthSession: Sendable {
  let cookieHeader: String
  let source: String
  let userID: String?
}

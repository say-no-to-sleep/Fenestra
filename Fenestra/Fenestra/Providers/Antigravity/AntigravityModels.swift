import Foundation

struct AntigravityEndpoint: Sendable {
  let scheme: String
  let port: Int
  let csrfToken: String
}

struct AntigravityModelQuota: Sendable {
  let label: String
  let modelID: String
  let remainingFraction: Double
  let resetTime: Date?
}

struct AntigravityIdentity: Sendable {
  let email: String?
  let plan: String?
}

struct AntigravityKeychainToken: Sendable {
  let accessToken: String?
  let expiry: Date?
}

struct AntigravityQuotaSummaryResponse: Decodable {
  let response: AntigravityQuotaSummaryPayload?
  let summary: AntigravityQuotaSummaryPayload?
  let groups: [AntigravityQuotaGroup]?
}

struct AntigravityQuotaSummaryPayload: Decodable {
  let groups: [AntigravityQuotaGroup]
}

struct AntigravityQuotaGroup: Decodable {
  let displayName: String?
  let buckets: [AntigravityQuotaBucket]?
}

struct AntigravityQuotaBucket: Decodable {
  let bucketID: String?
  let displayName: String?
  let disabled: Bool?
  let remainingFraction: Double?
  let remaining: AntigravityRemainingValue?
  let resetTime: String?

  enum CodingKeys: String, CodingKey {
    case bucketID = "bucketId"
    case displayName
    case disabled
    case remainingFraction
    case remaining
    case resetTime
  }
}

struct AntigravityRemainingValue: Decodable {
  let remainingFraction: Double?
  let value: Double?
}

struct AntigravityUserStatusEnvelope: Decodable {
  let userStatus: AntigravityUserStatus?
}

struct AntigravityUserStatus: Decodable {
  let email: String?
  let userTier: AntigravityTier?
  let planStatus: AntigravityPlanStatus?
  let cascadeModelConfigData: AntigravityModelConfigData?
}

struct AntigravityTier: Decodable {
  let name: String?
}

struct AntigravityPlanStatus: Decodable {
  let planInfo: AntigravityPlanInfo?
}

struct AntigravityPlanInfo: Decodable {
  let planName: String?
  let planDisplayName: String?
}

struct AntigravityModelConfigData: Decodable {
  let clientModelConfigs: [AntigravityModelConfig]?
}

struct AntigravityCommandConfigEnvelope: Decodable {
  let clientModelConfigs: [AntigravityModelConfig]?
}

struct AntigravityModelConfig: Decodable {
  let label: String?
  let modelOrAlias: AntigravityModelAlias?
  let quotaInfo: AntigravityQuotaInfo?
}

struct AntigravityModelAlias: Decodable {
  let model: String?
}

struct AntigravityQuotaInfo: Decodable {
  let remainingFraction: Double?
  let resetTime: String?
}

struct AntigravityCloudModelsEnvelope: Decodable {
  let models: [String: AntigravityCloudModel]?
}

struct AntigravityCloudModel: Decodable {
  let model: String?
  let displayName: String?
  let label: String?
  let isInternal: Bool?
  let quotaInfo: AntigravityQuotaInfo?
}

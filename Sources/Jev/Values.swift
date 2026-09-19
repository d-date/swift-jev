import Foundation

// MARK: - Probability

/// The value a Noul question returns: the probability that the statement is true.
///
/// Noul carries no separate confidence. The probability *is* the confidence, which
/// is why this type has no `confidence` property. A value near 0.5 means the model
/// is genuinely unsure rather than "medium true".
public struct Probability: Sendable, Hashable, Comparable {
  public let value: Double

  /// Clamps into 0...1.
  ///
  /// Traps on NaN: a NaN here is a programmer error, and letting it through would
  /// break both `Comparable` and the equality `Hashable` relies on.
  public init(clamping value: Double) {
    precondition(!value.isNaN, "Probability cannot be NaN")
    self.value = min(max(value, 0), 1)
  }

  /// `nil` when the value is NaN or outside 0...1.
  public init?(exactly value: Double) {
    guard !value.isNaN, (0...1).contains(value) else { return nil }
    self.value = value
  }

  public static func < (lhs: Probability, rhs: Probability) -> Bool {
    lhs.value < rhs.value
  }

  /// How far the probability is from "don't know".
  ///
  /// 0.5 maps to 0.5 and both extremes map to 1. Used to gate Noul answers, where
  /// a confident "no" is as actionable as a confident "yes".
  public var decisiveness: Double { max(value, 1 - value) }
}

extension Probability: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(Double.self)
    guard let probability = Probability(exactly: raw) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "probability must be a number within 0...1, got \(raw)"
      )
    }
    self = probability
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

// MARK: - ScoreValue

/// The value a Score question returns.
///
/// `value` is probability-weighted, so it lands between rubric levels: 0.70 on
/// level 1 and 0.30 on level 2 gives 1.30.
public struct ScoreValue: Sendable, Hashable {
  public let value: Double
  public let legend: [Int: String]
  public let probabilities: [Int: Double]
  public let confidence: Double

  public init(
    value: Double,
    legend: [Int: String],
    probabilities: [Int: Double],
    confidence: Double
  ) {
    self.value = value
    self.legend = legend
    self.probabilities = probabilities
    self.confidence = confidence
  }

  /// The nearest whole level. Does not consult `legend`, which may be sparse.
  public var rounded: Int { Int(value.rounded()) }

  /// `value` mapped onto 0...1. `nil` when there are fewer than two levels, which
  /// would divide by zero.
  public var normalized: Double? {
    let levels = max(legend.count, probabilities.count)
    guard levels >= 2 else { return nil }
    return value / Double(levels - 1)
  }
}

extension ScoreValue: Codable {
  private enum CodingKeys: String, CodingKey {
    case score, legend, probabilities, confidence
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value = try container.decode(Double.self, forKey: .score)
    let rawLegend = try container.decodeIfPresent([String: String].self, forKey: .legend) ?? [:]
    let rawProbabilities = try container.decode([String: Double].self, forKey: .probabilities)
    let confidence = try container.decode(Double.self, forKey: .confidence)
    guard !confidence.isNaN, (0...1).contains(confidence) else {
      throw DecodingError.dataCorruptedError(
        forKey: .confidence, in: container,
        debugDescription: "confidence must be within 0...1, got \(confidence)"
      )
    }

    // Levels arrive as stringified integers. Convert first, then validate: "0" and
    // "00" are two string keys but one level, and counting before converting would
    // let a single-level score through.
    func indexed<T>(_ source: [String: T], _ key: CodingKeys) throws -> [Int: T] {
      var result: [Int: T] = [:]
      for (rawKey, value) in source {
        guard let index = Int(rawKey) else {
          throw DecodingError.dataCorruptedError(
            forKey: key, in: container,
            debugDescription: "level key '\(rawKey)' is not an integer"
          )
        }
        guard result.updateValue(value, forKey: index) == nil else {
          throw DecodingError.dataCorruptedError(
            forKey: key, in: container,
            debugDescription: "level \(index) appears more than once"
          )
        }
      }
      return result
    }

    let legend = try indexed(rawLegend, .legend)
    let probabilities = try indexed(rawProbabilities, .probabilities)

    guard !value.isNaN else {
      throw DecodingError.dataCorruptedError(
        forKey: .score, in: container, debugDescription: "score must not be NaN"
      )
    }
    guard probabilities.count >= 2 else {
      throw DecodingError.dataCorruptedError(
        forKey: .probabilities, in: container,
        debugDescription: "a score needs at least two levels, got \(probabilities.count)"
      )
    }
    let highest = probabilities.count - 1
    guard (0...Double(highest)).contains(value) else {
      throw DecodingError.dataCorruptedError(
        forKey: .score, in: container,
        debugDescription: "score \(value) is outside 0...\(highest)"
      )
    }

    self.init(
      value: value, legend: legend, probabilities: probabilities, confidence: confidence
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(value, forKey: .score)
    try container.encode(
      Dictionary(uniqueKeysWithValues: legend.map { (String($0.key), $0.value) }),
      forKey: .legend
    )
    try container.encode(
      Dictionary(uniqueKeysWithValues: probabilities.map { (String($0.key), $0.value) }),
      forKey: .probabilities
    )
    try container.encode(confidence, forKey: .confidence)
  }
}

// MARK: - JevChoiceOptions

/// A type whose cases are the options of a Choice question.
public protocol JevChoiceOptions: RawRepresentable<String>, CaseIterable, Hashable, Sendable {
  /// Rubric per option. An option absent from this map is sent with a null
  /// description, which Jev reads as "the name alone specifies the choice".
  static var optionDescriptions: [Self: String] { get }
}

extension JevChoiceOptions {
  public static var optionDescriptions: [Self: String] { [:] }

  /// Options in `allCases` order, which is declaration order for an enum.
  ///
  /// The order survives into the request body only as far as `JSONEncoder` allows:
  /// keyed containers are not order-preserving, so the JSON key order is undefined.
  public static var jevChoiceOptions: [ChoiceOption] {
    allCases.map { ChoiceOption($0.rawValue, optionDescriptions[$0]) }
  }
}

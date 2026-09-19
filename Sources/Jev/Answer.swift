import Foundation

/// Token counts for one request.
public struct Usage: Sendable, Hashable, Decodable {
  public let inputTokens: Int
  /// Reported by the server but never billed; Jev charges for input only.
  public let outputTokens: Int

  public init(inputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
  }

  /// Cost in USD at the published rate of $0.042 per million input tokens.
  ///
  /// A convenience for logging, not a billing source of truth.
  public var estimatedCostUSD: Double {
    Double(inputTokens) * 0.042 / 1_000_000
  }
}

/// One evaluated answer.
public enum Answer: Sendable, Hashable {
  case noul(Probability)
  case choice(Choice)
  case score(ScoreValue)

  public struct Choice: Sendable, Hashable {
    /// The raw string the API returned, before it is matched to an options type.
    public let value: String
    public let probabilities: [String: Double]
    public let confidence: Double

    public init(value: String, probabilities: [String: Double], confidence: Double) {
      self.value = value
      self.probabilities = probabilities
      self.confidence = confidence
    }
  }

  var typeName: String {
    switch self {
    case .noul: "noul"
    case .choice: "choice"
    case .score: "score"
    }
  }

  /// Present for choice and score. Noul has none: its probability is its confidence.
  public var confidence: Double? {
    switch self {
    case .noul: nil
    case .choice(let choice): choice.confidence
    case .score(let score): score.confidence
    }
  }
}

/// Decoding needs the question name to report which answer was malformed, and
/// `Decodable` has no way to pass it in, so answers are decoded through this
/// wrapper and the name is attached by `JevResponse`.
struct NamedAnswerDecoder {
  static func decode(
    from container: KeyedDecodingContainer<DynamicKey>,
    forKey key: DynamicKey
  ) throws -> Answer {
    let nested = try container.nestedContainer(keyedBy: Answer.CodingKeys.self, forKey: key)
    let type = try nested.decode(String.self, forKey: .type)
    switch type {
    case "noul":
      return .noul(try nested.decode(Probability.self, forKey: .noul))
    case "choice":
      return .choice(
        Answer.Choice(
          value: try nested.decode(String.self, forKey: .choice),
          probabilities: try nested.decode([String: Double].self, forKey: .probabilities),
          confidence: try Answer.decodeConfidence(from: nested)
        )
      )
    case "score":
      // ScoreValue reads score/legend/probabilities/confidence and ignores
      // the extra "type" key, so the answer object decodes straight into it.
      return .score(try container.decode(ScoreValue.self, forKey: key))
    default:
      throw JevError.unknownAnswerType(question: key.stringValue, type: type)
    }
  }
}

extension Answer {
  enum CodingKeys: String, CodingKey {
    case type, noul, choice, score, legend, probabilities, confidence
  }

  /// A confidence is a probability, so it is bounded like one.
  ///
  /// Without this, a confidence of 2.0 would sail past every threshold a routing
  /// policy can set and read as "act without asking".
  static func decodeConfidence(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> Double {
    let value = try container.decode(Double.self, forKey: .confidence)
    guard !value.isNaN, (0...1).contains(value) else {
      throw DecodingError.dataCorruptedError(
        forKey: .confidence, in: container,
        debugDescription: "confidence must be within 0...1, got \(value)"
      )
    }
    return value
  }
}

/// The answers for one evaluation, keyed by question name.
public struct JevAnswers: Sendable, Hashable {
  private let storage: [String: Answer]

  public init(_ answers: [String: Answer]) {
    self.storage = answers
  }

  public var names: Set<String> { Set(storage.keys) }
  public subscript(name: String) -> Answer? { storage[name] }

  // MARK: Typed accessors
  //
  // These are what the macro generates calls to. Keeping the generic constraint
  // here rather than in the macro means the compiler diagnoses a non-conforming
  // options type, which a macro cannot do: it has no semantic analysis.

  public func noul(named name: String) throws -> Probability {
    switch try require(name) {
    case .noul(let probability): probability
    case let other:
      throw JevError.answerTypeMismatch(
        question: name, expected: "noul", actual: other.typeName
      )
    }
  }

  public func score(named name: String) throws -> ScoreValue {
    switch try require(name) {
    case .score(let score): score
    case let other:
      throw JevError.answerTypeMismatch(
        question: name, expected: "score", actual: other.typeName
      )
    }
  }

  public func choice<T: JevChoiceOptions>(named name: String, as type: T.Type) throws -> T {
    guard case .choice(let choice) = try require(name) else {
      throw JevError.answerTypeMismatch(
        question: name, expected: "choice",
        actual: try require(name).typeName
      )
    }
    // Exact rawValue match only. Accepting near-misses would hide a rubric that
    // no longer lines up with the options type.
    guard let value = T(rawValue: choice.value) else {
      throw JevError.unrecognizedChoice(
        question: name, value: choice.value,
        expected: T.allCases.map(\.rawValue)
      )
    }
    return value
  }

  /// Probabilities remapped onto the options type.
  ///
  /// Keys that do not resolve are dropped rather than raising: the model may
  /// normalise an option name, and losing the distribution should not fail a
  /// request whose actual answer decoded fine.
  public func probabilities<T: JevChoiceOptions>(
    named name: String, as type: T.Type
  ) -> [T: Double]? {
    guard case .choice(let choice) = storage[name] else { return nil }
    return choice.probabilities.reduce(into: [T: Double]()) { result, pair in
      if let key = T(rawValue: pair.key) { result[key] = pair.value }
    }
  }

  private func require(_ name: String) throws -> Answer {
    guard let answer = storage[name] else {
      throw JevError.missingAnswer(question: name)
    }
    return answer
  }
}

/// The low-level shape of one response.
public struct JevResponse: Sendable, Hashable {
  public let model: String
  public let answers: JevAnswers
  public let usage: Usage

  public init(model: String, answers: JevAnswers, usage: Usage) {
    self.model = model
    self.answers = answers
    self.usage = usage
  }
}

extension JevResponse: Decodable {
  private enum CodingKeys: String, CodingKey { case model, answers, usage }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let answersContainer = try container.nestedContainer(
      keyedBy: DynamicKey.self, forKey: .answers
    )
    var answers: [String: Answer] = [:]
    for key in answersContainer.allKeys {
      answers[key.stringValue] = try NamedAnswerDecoder.decode(
        from: answersContainer, forKey: key
      )
    }
    self.init(
      model: try container.decode(String.self, forKey: .model),
      answers: JevAnswers(answers),
      usage: try container.decode(Usage.self, forKey: .usage)
    )
  }
}

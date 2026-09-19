import Foundation

/// One option of a Choice question.
public struct ChoiceOption: Sendable, Hashable {
  public var name: String
  /// `nil` keeps the request compact: Jev reads a null description as
  /// "the name alone specifies the choice".
  public var description: String?

  public init(_ name: String, _ description: String? = nil) {
    self.name = name
    self.description = description
  }
}

/// A question to evaluate the state against.
public struct Question: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case noul(whenTrue: String?, whenFalse: String?)
    /// Options stay in an array so the rubric reads in the order it was written.
    case choice([ChoiceOption])
    /// Levels are index-addressed, low to high. Jev accepts 2 through 10.
    case score(levels: [String])
  }

  public let instructions: String
  public let kind: Kind

  /// Validates eagerly.
  ///
  /// The macro path is checked at compile time, but this initializer is also the
  /// low-level API, where nothing else would catch a bad rubric before the server
  /// rejects it.
  public init(instructions: String, kind: Kind) throws {
    guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JevError.invalidQuestion(name: "", reason: .emptyInstructions)
    }
    switch kind {
    case .noul:
      break
    case .choice(let options):
      guard !options.isEmpty else {
        throw JevError.invalidQuestion(name: "", reason: .emptyChoiceOptions)
      }
      var seen = Set<String>()
      for option in options where !seen.insert(option.name).inserted {
        throw JevError.invalidQuestion(
          name: "", reason: .duplicateChoiceOption(option.name)
        )
      }
    case .score(let levels):
      guard (2...10).contains(levels.count) else {
        throw JevError.invalidQuestion(
          name: "", reason: .scoreLevelCountOutOfRange(levels.count)
        )
      }
    }
    self.instructions = instructions
    self.kind = kind
  }

  /// The wire name of this question's type, used when reporting a mismatch.
  var typeName: String {
    switch kind {
    case .noul: "noul"
    case .choice: "choice"
    case .score: "score"
    }
  }
}

extension Question: Encodable {
  private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(typeName, forKey: .type)
    try container.encode(instructions, forKey: .instructions)

    switch kind {
    case let .noul(whenTrue, whenFalse):
      // Omit `criteria` entirely when neither side is described, rather than
      // sending an empty object.
      if whenTrue != nil || whenFalse != nil {
        var criteria = container.nestedContainer(keyedBy: DynamicKey.self, forKey: .criteria)
        if let whenTrue { try criteria.encode(whenTrue, forKey: DynamicKey("true")) }
        if let whenFalse { try criteria.encode(whenFalse, forKey: DynamicKey("false")) }
      }

    case .choice(let options):
      var criteria = container.nestedContainer(keyedBy: DynamicKey.self, forKey: .criteria)
      for option in options {
        let key = DynamicKey(option.name)
        if let description = option.description {
          try criteria.encode(description, forKey: key)
        } else {
          try criteria.encodeNil(forKey: key)
        }
      }

    case .score(let levels):
      try container.encode(levels, forKey: .criteria)
    }
  }
}

/// The questions sent in one request.
public struct JevQuestionSet: Sendable, Hashable {
  public let questions: [String: Question]

  public init(_ questions: [String: Question]) throws {
    guard !questions.isEmpty else { throw JevError.emptyQuestionSet }
    for (name, _) in questions where name.isEmpty {
      throw JevError.invalidQuestion(name: name, reason: .emptyInstructions)
    }
    self.questions = questions
  }

  public subscript(name: String) -> Question? { questions[name] }
}

extension JevQuestionSet: Encodable {
  public func encode(to encoder: any Encoder) throws {
    try questions.encode(to: encoder)
  }
}

/// A `CodingKey` built from a runtime string, for the dynamic `criteria` object.
struct DynamicKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

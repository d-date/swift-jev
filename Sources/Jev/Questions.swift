import Foundation

/// A question you can send and later read the answer of.
///
/// Questions are values rather than generated declarations. The type parameter on
/// `ChoiceQuestion` is what makes the answer typed, so the compiler does the work
/// a macro would otherwise have to do — without the plugin, the dependency, or the
/// restriction that everything be a literal.
public protocol AnyQuestion: Sendable {
  var name: String { get }
  /// Validated here rather than at the call site, so an invalid rubric fails
  /// before the request is sent.
  func makeQuestion() throws -> Question
}

/// Asks which of an options type's cases applies.
public struct ChoiceQuestion<Options: JevChoiceOptions>: AnyQuestion {
  public let name: String
  public let instructions: String

  public init(_ name: String, _ instructions: String) {
    self.name = name
    self.instructions = instructions
  }

  public func makeQuestion() throws -> Question {
    try Question(instructions: instructions, kind: .choice(Options.jevChoiceOptions))
  }
}

/// Asks for the probability that a statement is true.
public struct NoulQuestion: AnyQuestion {
  public let name: String
  public let instructions: String
  /// Sharpen the boundary when yes and no are close. Both sides are optional; when
  /// neither is given, `criteria` is left out of the request entirely.
  public let whenTrue: String?
  public let whenFalse: String?

  public init(
    _ name: String,
    _ instructions: String,
    whenTrue: String? = nil,
    whenFalse: String? = nil
  ) {
    self.name = name
    self.instructions = instructions
    self.whenTrue = whenTrue
    self.whenFalse = whenFalse
  }

  public func makeQuestion() throws -> Question {
    try Question(
      instructions: instructions,
      kind: .noul(whenTrue: whenTrue, whenFalse: whenFalse)
    )
  }
}

/// Asks for a position on an ordered rubric, low to high.
public struct ScoreQuestion: AnyQuestion {
  public let name: String
  public let instructions: String
  public let levels: [String]

  public init(_ name: String, _ instructions: String, levels: [String]) {
    self.name = name
    self.instructions = instructions
    self.levels = levels
  }

  public func makeQuestion() throws -> Question {
    try Question(instructions: instructions, kind: .score(levels: levels))
  }
}

@resultBuilder
public enum QuestionBuilder {
  public static func buildBlock(_ questions: any AnyQuestion...) -> [any AnyQuestion] {
    questions
  }

  public static func buildArray(_ questions: [[any AnyQuestion]]) -> [any AnyQuestion] {
    questions.flatMap(\.self)
  }

  public static func buildOptional(_ questions: [any AnyQuestion]?) -> [any AnyQuestion] {
    questions ?? []
  }

  public static func buildEither(first questions: [any AnyQuestion]) -> [any AnyQuestion] {
    questions
  }

  public static func buildEither(second questions: [any AnyQuestion]) -> [any AnyQuestion] {
    questions
  }

  public static func buildExpression(_ question: any AnyQuestion) -> [any AnyQuestion] {
    [question]
  }

  public static func buildExpression(_ questions: [any AnyQuestion]) -> [any AnyQuestion] {
    questions
  }

  public static func buildBlock(_ groups: [any AnyQuestion]...) -> [any AnyQuestion] {
    groups.flatMap(\.self)
  }
}

extension JevQuestionSet {
  /// Builds a set from question values, rejecting a repeated name.
  public init(_ questions: [any AnyQuestion]) throws {
    var map: [String: Question] = [:]
    for question in questions {
      guard map[question.name] == nil else {
        throw JevError.duplicateQuestionName(question.name)
      }
      map[question.name] = try question.makeQuestion()
    }
    try self.init(map)
  }
}

// MARK: - Typed reads

extension JevAnswers {
  /// The answer, or `nil` when it is absent or of another type.
  ///
  /// Swift has no throwing subscript, so this is the forgiving form and
  /// `require(_:)` is the one that explains what went wrong.
  public subscript<Options: JevChoiceOptions>(question: ChoiceQuestion<Options>) -> Options? {
    try? choice(named: question.name, as: Options.self)
  }

  public subscript(question: NoulQuestion) -> Probability? {
    try? noul(named: question.name)
  }

  public subscript(question: ScoreQuestion) -> ScoreValue? {
    try? score(named: question.name)
  }

  public func require<Options: JevChoiceOptions>(
    _ question: ChoiceQuestion<Options>
  ) throws -> Options {
    try choice(named: question.name, as: Options.self)
  }

  public func require(_ question: NoulQuestion) throws -> Probability {
    try noul(named: question.name)
  }

  public func require(_ question: ScoreQuestion) throws -> ScoreValue {
    try score(named: question.name)
  }

  /// `nil` when the question was not answered.
  public func confidence<Options: JevChoiceOptions>(
    of question: ChoiceQuestion<Options>
  ) -> Double? {
    self[question.name]?.confidence
  }

  public func confidence(of question: ScoreQuestion) -> Double? {
    self[question.name]?.confidence
  }

  // There is deliberately no `confidence(of:)` taking a NoulQuestion.
  // Noul carries no confidence: the probability is the confidence, and asking for
  // one separately is a misunderstanding worth catching at compile time.

  public func probabilities<Options: JevChoiceOptions>(
    of question: ChoiceQuestion<Options>
  ) -> [Options: Double]? {
    probabilities(named: question.name, as: Options.self)
  }
}

/// Forwards the typed reads so a caller can work from the response directly.
extension JevResponse {
  public subscript<Options: JevChoiceOptions>(question: ChoiceQuestion<Options>) -> Options? {
    answers[question]
  }

  public subscript(question: NoulQuestion) -> Probability? { answers[question] }
  public subscript(question: ScoreQuestion) -> ScoreValue? { answers[question] }

  public func require<Options: JevChoiceOptions>(
    _ question: ChoiceQuestion<Options>
  ) throws -> Options {
    try answers.require(question)
  }

  public func require(_ question: NoulQuestion) throws -> Probability {
    try answers.require(question)
  }

  public func require(_ question: ScoreQuestion) throws -> ScoreValue {
    try answers.require(question)
  }

  public func confidence<Options: JevChoiceOptions>(
    of question: ChoiceQuestion<Options>
  ) -> Double? {
    answers.confidence(of: question)
  }

  public func confidence(of question: ScoreQuestion) -> Double? {
    answers.confidence(of: question)
  }

  public func probabilities<Options: JevChoiceOptions>(
    of question: ChoiceQuestion<Options>
  ) -> [Options: Double]? {
    answers.probabilities(of: question)
  }
}

import Foundation
import Testing

@testable import Jev

// MARK: - Macro output

@Suite("Question values")
struct QuestionValueTests {
  @Test("a question set is built from the question values")
  func questionSet() throws {
    let set = try JevQuestionSet(triageQuestions)
    #expect(Set(set.questions.keys) == ["department", "urgency", "frustration"])
  }

  @Test("choice options come from the type parameter, in declaration order")
  func choiceOptions() throws {
    guard case .choice(let options) = try department.makeQuestion().kind else {
      Issue.record("department is not a choice question")
      return
    }
    #expect(options.map(\.name) == ["billing", "technical", "sales", "account"])
    #expect(options[0].description == "Invoices, charges, refunds")
    // An option with no rubric is sent with a null description.
    #expect(options[2].description == nil)
  }

  @Test("score levels are carried through verbatim")
  func scoreLevels() throws {
    guard case .score(let levels) = try frustration.makeQuestion().kind else {
      Issue.record("frustration is not a score question")
      return
    }
    #expect(levels == ["Calm and factual", "Visibly annoyed", "Angry, threatening to leave"])
  }

  @Test("noul criteria are carried through")
  func noulCriteria() throws {
    guard case .noul(let whenTrue, let whenFalse) = try urgency.makeQuestion().kind else {
      Issue.record("urgency is not a noul question")
      return
    }
    #expect(whenTrue == "States a deadline within a day, or an active outage.")
    #expect(whenFalse == "Can wait for the normal support queue.")
  }

  @Test("a repeated question name is rejected")
  func duplicateNames() {
    let twice: [any AnyQuestion] = [urgency, NoulQuestion("urgency", "Something else?")]
    #expect(throws: JevError.duplicateQuestionName("urgency")) {
      try JevQuestionSet(twice)
    }
  }

  // Unlike a macro, a question value can be assembled at run time.
  @Test("a question built at runtime is as valid as a literal one")
  func runtimeQuestion() throws {
    let levels = (0..<3).map { "level \($0)" }
    let question = ScoreQuestion("dynamic", "How much?", levels: levels)
    guard case .score(let carried) = try question.makeQuestion().kind else {
      Issue.record("not a score question")
      return
    }
    #expect(carried == ["level 0", "level 1", "level 2"])
  }

  @Test("an invalid rubric fails when the question is made, not at the server")
  func invalidRubric() {
    let tooFew = ScoreQuestion("bad", "How much?", levels: ["only one"])
    #expect(throws: JevError.self) { try tooFew.makeQuestion() }
  }
}

// MARK: - Encoding

@Suite("Request encoding")
struct EncodingTests {
  private func encode(_ question: Question) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(question), as: UTF8.self)
  }

  @Test("noul without criteria omits the key entirely")
  func noulWithoutCriteria() throws {
    let question = try Question(instructions: "Is it urgent?", kind: .noul(whenTrue: nil, whenFalse: nil))
    #expect(try encode(question) == #"{"instructions":"Is it urgent?","type":"noul"}"#)
  }

  @Test("noul criteria use the true and false keys")
  func noulCriteria() throws {
    let question = try Question(
      instructions: "Is it urgent?", kind: .noul(whenTrue: "yes side", whenFalse: "no side")
    )
    #expect(
      try encode(question)
        == #"{"criteria":{"false":"no side","true":"yes side"},"instructions":"Is it urgent?","type":"noul"}"#
    )
  }

  @Test("a choice option without a rubric encodes as null")
  func choiceNullDescription() throws {
    let question = try Question(
      instructions: "Which?",
      kind: .choice([ChoiceOption("a", "first"), ChoiceOption("b")])
    )
    #expect(
      try encode(question)
        == #"{"criteria":{"a":"first","b":null},"instructions":"Which?","type":"choice"}"#
    )
  }

  @Test("score criteria encode as an ordered array")
  func scoreArray() throws {
    let question = try Question(instructions: "How bad?", kind: .score(levels: ["low", "high"]))
    #expect(
      try encode(question)
        == #"{"criteria":["low","high"],"instructions":"How bad?","type":"score"}"#
    )
  }
}

// MARK: - Low-level validation

@Suite("Question validation")
struct QuestionValidationTests {
  @Test("blank instructions are rejected")
  func blankInstructions() {
    #expect(throws: JevError.self) {
      try Question(instructions: "   ", kind: .noul(whenTrue: nil, whenFalse: nil))
    }
  }

  @Test("a choice needs at least one option")
  func emptyOptions() {
    #expect(throws: JevError.invalidQuestion(name: "", reason: .emptyChoiceOptions)) {
      try Question(instructions: "Which?", kind: .choice([]))
    }
  }

  @Test("duplicate options are rejected")
  func duplicateOptions() {
    #expect(throws: JevError.invalidQuestion(name: "", reason: .duplicateChoiceOption("a"))) {
      try Question(instructions: "Which?", kind: .choice([ChoiceOption("a"), ChoiceOption("a")]))
    }
  }

  @Test("score levels outside 2...10 are rejected", arguments: [0, 1, 11])
  func levelCount(_ count: Int) {
    #expect(throws: JevError.invalidQuestion(name: "", reason: .scoreLevelCountOutOfRange(count))) {
      try Question(
        instructions: "How bad?",
        kind: .score(levels: Array(repeating: "level", count: count).enumerated().map { "\($0.offset)" })
      )
    }
  }

  @Test("an empty question set is rejected")
  func emptySet() {
    #expect(throws: JevError.emptyQuestionSet) { try JevQuestionSet([:]) }
  }
}

// MARK: - Values

@Suite("Probability")
struct ProbabilityTests {
  @Test("clamping keeps the value inside 0...1", arguments: [(-1.0, 0.0), (0.4, 0.4), (2.0, 1.0)])
  func clamping(_ pair: (Double, Double)) {
    #expect(Probability(clamping: pair.0).value == pair.1)
  }

  @Test("exact initialization rejects out-of-range and NaN")
  func exact() {
    #expect(Probability(exactly: 0.5) != nil)
    #expect(Probability(exactly: 1.5) == nil)
    #expect(Probability(exactly: .nan) == nil)
  }

  @Test("decoding rejects values the invariant forbids", arguments: ["1.5", "-0.1"])
  func decodingRejects(_ json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Probability.self, from: Data(json.utf8))
    }
  }

  @Test("decisiveness measures distance from 'don't know'")
  func decisiveness() {
    #expect(Probability(clamping: 0.5).decisiveness == 0.5)
    #expect(Probability(clamping: 0.02).decisiveness == 0.98)
    #expect(Probability(clamping: 0.98).decisiveness == 0.98)
  }
}

@Suite("ScoreValue")
struct ScoreValueTests {
  @Test("a fractional score sits between levels")
  func fractional() throws {
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(realTriageJSON.utf8))
    guard case .score(let score) = response.answers["frustration"] else {
      Issue.record("frustration is not a score answer")
      return
    }
    #expect(score.value == 1.6)
    #expect(score.rounded == 2)
    #expect(score.normalized == 0.8)
    #expect(score.legend[1] == "Visibly annoyed")
  }

  @Test("a score outside its level range is rejected")
  func outOfRange() {
    let json = """
      {"type":"score","score":5.0,"probabilities":{"0":0.5,"1":0.5},"confidence":0.9}
      """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ScoreValue.self, from: Data(json.utf8))
    }
  }
}

// MARK: - Answer mapping

@Suite("Answer mapping")
struct AnswerMappingTests {
  private var answers: JevAnswers {
    get throws {
      try JSONDecoder()
        .decode(JevResponse.self, from: Data(realTriageJSON.utf8))
        .answers
    }
  }

  @Test("a real response reads back through the question values")
  func decodesIntoQuery() throws {
    let answers = try answers
    #expect(try answers.require(department) == .billing)
    #expect(try answers.require(urgency).value == 0.81)
    #expect(try answers.require(frustration).value == 1.6)
  }

  @Test("the forgiving subscript mirrors the throwing form")
  func subscripts() throws {
    let answers = try answers
    #expect(answers[department] == .billing)
    #expect(answers[urgency]?.value == 0.81)
  }

  @Test("a missing answer names the question")
  func missingAnswer() throws {
    let partial = JevAnswers(["department": try answers["department"]!])
    #expect(throws: JevError.missingAnswer(question: "urgency")) {
      try partial.require(urgency)
    }
    // The subscript reports the same absence without an error.
    #expect(partial[urgency] == nil)
  }

  @Test("a type mismatch names both types")
  func typeMismatch() throws {
    let swapped = JevAnswers([
      "department": .noul(Probability(clamping: 0.5)),
      "urgency": try answers["urgency"]!,
      "frustration": try answers["frustration"]!,
    ])
    #expect(
      throws: JevError.answerTypeMismatch(
        question: "department", expected: "choice", actual: "noul"
      )
    ) {
      try swapped.require(department)
    }
  }

  @Test("an unrecognised choice lists what was expected")
  func unrecognizedChoice() throws {
    let bogus = JevAnswers([
      "department": .choice(
        Answer.Choice(value: "legal", probabilities: [:], confidence: 0.9)
      ),
      "urgency": try answers["urgency"]!,
      "frustration": try answers["frustration"]!,
    ])
    #expect(
      throws: JevError.unrecognizedChoice(
        question: "department", value: "legal",
        expected: ["billing", "technical", "sales", "account"]
      )
    ) {
      try bogus.require(department)
    }
  }

  @Test("probabilities for keys outside the options type are dropped")
  func unmappedProbabilities() throws {
    let extra = JevAnswers([
      "department": .choice(
        Answer.Choice(
          value: "billing",
          probabilities: ["billing": 0.8, "legal": 0.2],
          confidence: 0.9
        )
      )
    ])
    #expect(extra.probabilities(of: department) == [.billing: 0.8])
  }

  @Test("an unknown answer type is reported rather than ignored")
  func unknownType() {
    let json = """
      {"model":"m","answers":{"x":{"type":"quantum","value":1}},
       "usage":{"input_tokens":1,"output_tokens":0}}
      """
    #expect(throws: JevError.unknownAnswerType(question: "x", type: "quantum")) {
      try JSONDecoder().decode(JevResponse.self, from: Data(json.utf8))
    }
  }
}

// MARK: - Usage

@Suite("Usage")
struct UsageTests {
  @Test("cost follows the published input rate")
  func cost() throws {
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(realTriageJSON.utf8))
    #expect(response.usage.inputTokens == 394)
    // Output tokens are reported but never billed.
    #expect(response.usage.outputTokens == 57)
    #expect(abs(response.usage.estimatedCostUSD - 394 * 0.042 / 1_000_000) < 1e-12)
  }
}

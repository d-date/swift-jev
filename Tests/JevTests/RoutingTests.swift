import Foundation
import Testing

@testable import Jev

private func answers(
  departmentConfidence: Double = 0.9,
  urgencyValue: Double = 0.81
) -> JevAnswers {
  JevAnswers([
    "department": .choice(
      Answer.Choice(
        value: "billing",
        probabilities: ["billing": 0.89, "technical": 0.11],
        confidence: departmentConfidence
      )
    ),
    "urgency": .noul(Probability(clamping: urgencyValue)),
    "frustration": .score(
      ScoreValue(
        value: 1.6, legend: [0: "calm", 1: "annoyed", 2: "angry"],
        probabilities: [0: 0.05, 1: 0.3, 2: 0.65], confidence: 0.78
      )
    ),
  ])
}

/// A question that is never sent. Reading it compiles — the cost of questions
/// being values rather than a generated declaration — and resolves to nil.
let neverAsked = ChoiceQuestion<Department>("never_asked", "Was this asked?")

@Suite("Typed reads")
struct TypedReadTests {
  @Test("confidence is reachable without naming the question as a string")
  func confidence() {
    let answers = answers(departmentConfidence: 0.83)
    #expect(answers.confidence(of: department) == 0.83)
    #expect(answers.confidence(of: frustration) == 0.78)
  }

  @Test("probabilities map onto the options type")
  func probabilities() {
    #expect(answers().probabilities(of: department) == [.billing: 0.89, .technical: 0.11])
  }

  @Test("a question that was never sent resolves to nil, not to zero")
  func unsentQuestion() {
    #expect(answers().confidence(of: neverAsked) == nil)
    #expect(answers().probabilities(of: neverAsked) == nil)
    #expect(answers()[neverAsked] == nil)
  }
}

@Suite("Routing: choice and score")
struct ChoiceRoutingTests {
  private let policy = RoutingPolicy.default

  @Test(
    "confidence maps onto a decision at the documented thresholds",
    arguments: [
      (0.0, Decision.escalate),
      (0.59, .escalate),
      (0.6, .confirm),     // the lower bound is inclusive for confirm
      (0.84, .confirm),
      (0.85, .auto),       // and the upper bound is inclusive for auto
      (1.0, .auto),
    ]
  )
  func thresholds(_ pair: (Double, Decision)) {
    #expect(policy.decide(answers(departmentConfidence: pair.0), of: department) == pair.1)
  }

  @Test("an unanswered question escalates rather than guessing")
  func unanswered() {
    #expect(policy.decide(answers(), of: neverAsked) == .escalate)
  }

  @Test("a stricter policy raises the bar")
  func strictPolicy() {
    let strict = RoutingPolicy(escalateBelow: 0.9, autoAtOrAbove: 0.99)
    let a = answers(departmentConfidence: 0.95)
    #expect(strict.decide(a, of: department) == .confirm)
    #expect(RoutingPolicy.default.decide(a, of: department) == .auto)
  }
}

@Suite("Routing: noul")
struct NoulRoutingTests {
  private let policy = RoutingPolicy.default

  @Test("inside the band the model is saying it does not know")
  func undecided() {
    for probability in [0.35, 0.5, 0.65] {
      let judgement = policy.decide(Probability(clamping: probability))
      #expect(judgement.answer == nil)
      #expect(judgement.decision == .escalate)
    }
  }

  @Test("a confident yes is adopted")
  func confidentYes() {
    let judgement = policy.decide(Probability(clamping: 0.97))
    #expect(judgement.answer == true)
    #expect(judgement.decision == .auto)
  }

  // A low probability is a confident *no*, and `.auto` there means adopting that
  // negative answer, not approving whatever action the question asked about.
  @Test("a confident no is adopted just as readily")
  func confidentNo() {
    let judgement = policy.decide(Probability(clamping: 0.03))
    #expect(judgement.answer == false)
    #expect(judgement.decisiveness == 0.97)
    #expect(judgement.decision == .auto)
  }

  @Test("just outside the band, decisiveness is still too low to act")
  func justOutsideBand() {
    let judgement = policy.decide(Probability(clamping: 0.34))
    #expect(judgement.answer == false)
    // decisiveness is 0.66, which clears the band but not escalateBelow... it does,
    // so this lands on confirm rather than auto.
    #expect(judgement.decision == .confirm)
  }

  @Test("a leaning answer needs confirmation")
  func leaning() {
    let judgement = policy.decide(Probability(clamping: 0.8))
    #expect(judgement.answer == true)
    #expect(judgement.decision == .confirm)
  }

  @Test("widening the band escalates more")
  func widerBand() {
    let cautious = RoutingPolicy(undecidedBand: 0.2...0.8)
    #expect(cautious.decide(Probability(clamping: 0.75)).decision == .escalate)
    #expect(RoutingPolicy.default.decide(Probability(clamping: 0.75)).decision == .confirm)
  }
}

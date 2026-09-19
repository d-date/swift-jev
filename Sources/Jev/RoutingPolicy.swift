import Foundation

/// What to do with an answer, given how sure the model is.
public enum Decision: Sendable, Hashable {
  case auto
  case confirm
  case escalate
}

/// A Noul answer turned into a decision.
public struct NoulJudgement: Sendable, Hashable {
  /// `nil` inside the undecided band: the model is saying it does not know,
  /// which is not the same as leaning slightly one way.
  public var answer: Bool?
  /// `max(p, 1 - p)`. A confident "no" scores as high as a confident "yes".
  public var decisiveness: Double
  public var decision: Decision

  public init(answer: Bool?, decisiveness: Double, decision: Decision) {
    self.answer = answer
    self.decisiveness = decisiveness
    self.decision = decision
  }
}

/// Thresholds for turning confidence into a decision.
///
/// Hold one of these per action rather than one per client: the same confidence
/// that is plenty for reading a balance is not enough to approve a transfer.
/// The defaults mirror the figures in TypeSafe's confidence-routing guidance and
/// are a starting point to validate, not a recommendation to adopt.
public struct RoutingPolicy: Sendable, Hashable {
  public var escalateBelow: Double
  public var autoAtOrAbove: Double
  /// Noul only: the band where the probability means "genuinely unsure".
  public var undecidedBand: ClosedRange<Double>

  public init(
    escalateBelow: Double = 0.6,
    autoAtOrAbove: Double = 0.85,
    undecidedBand: ClosedRange<Double> = 0.35...0.65
  ) {
    self.escalateBelow = escalateBelow
    self.autoAtOrAbove = autoAtOrAbove
    self.undecidedBand = undecidedBand
  }

  public static let `default` = RoutingPolicy()

  // MARK: Choice and Score

  public func decide<Options: JevChoiceOptions>(
    _ answers: JevAnswers, of question: ChoiceQuestion<Options>
  ) -> Decision {
    decide(confidence: answers.confidence(of: question))
  }

  public func decide(_ answers: JevAnswers, of question: ScoreQuestion) -> Decision {
    decide(confidence: answers.confidence(of: question))
  }

  public func decide<Options: JevChoiceOptions>(
    _ response: JevResponse, of question: ChoiceQuestion<Options>
  ) -> Decision {
    decide(confidence: response.confidence(of: question))
  }

  public func decide(_ response: JevResponse, of question: ScoreQuestion) -> Decision {
    decide(confidence: response.confidence(of: question))
  }

  /// An unanswered question escalates: guessing would be worse than handing it
  /// to a person.
  func decide(confidence: Double?) -> Decision {
    guard let confidence else { return .escalate }
    if confidence < escalateBelow { return .escalate }
    return confidence >= autoAtOrAbove ? .auto : .confirm
  }

  // MARK: Noul

  /// Noul has no confidence, so the probability itself is the signal.
  ///
  /// `.auto` here means "adopt this answer without asking", which for a low
  /// probability means adopting the *negative*. It is not an approval to perform
  /// whatever action the question was about.
  public func decide(_ probability: Probability) -> NoulJudgement {
    let p = probability.value
    let decisiveness = probability.decisiveness

    guard !undecidedBand.contains(p) else {
      return NoulJudgement(answer: nil, decisiveness: decisiveness, decision: .escalate)
    }
    let answer = p > 0.5
    let decision: Decision =
      decisiveness < escalateBelow ? .escalate
      : decisiveness >= autoAtOrAbove ? .auto
      : .confirm
    return NoulJudgement(answer: answer, decisiveness: decisiveness, decision: decision)
  }
}

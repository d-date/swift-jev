import Foundation

/// Everything that can go wrong talking to Jev.
///
/// The macro-generated `init(answers:)` and the low-level API both fail with this
/// type, so callers have one contract to handle rather than two.
public enum JevError: Error, Sendable {
  // MARK: Transport and HTTP

  /// 401. The key is missing or invalid. Never retried.
  case unauthorized
  /// 422. The request failed server-side validation. Never retried.
  ///
  /// A state that exceeds the documented context limit arrives here: the client
  /// does not count tokens, so the server is what detects it.
  case invalidRequest(body: String)
  /// 429, after the retry policy gave up.
  case rateLimited(retryAfter: Duration?)
  /// 529, after the retry policy gave up.
  case overloaded
  case http(status: Int, body: String)
  /// A network failure, wrapped. `CancellationError` is never wrapped.
  case transport(any Error)

  // MARK: Decoding

  case malformedResponse(underlying: any Error)
  case unknownAnswerType(question: String, type: String)

  // MARK: Answer mapping

  case missingAnswer(question: String)
  case answerTypeMismatch(question: String, expected: String, actual: String)
  case unrecognizedChoice(question: String, value: String, expected: [String])

  // MARK: Request construction

  case invalidQuestion(name: String, reason: InvalidQuestionReason)
  case duplicateQuestionName(String)
  case emptyQuestionSet
}

public enum InvalidQuestionReason: Sendable, Hashable {
  /// Jev accepts 2 through 10 rubric levels.
  case scoreLevelCountOutOfRange(Int)
  case emptyChoiceOptions
  case duplicateChoiceOption(String)
  case emptyInstructions
}

extension JevError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unauthorized:
      "401: the API key is missing or invalid"
    case .invalidRequest(let body):
      "422: the request failed validation — \(body)"
    case .rateLimited(let retryAfter):
      retryAfter.map { "429: rate limited, retry after \($0)" } ?? "429: rate limited"
    case .overloaded:
      "529: the server is overloaded"
    case .http(let status, let body):
      "\(status): \(body)"
    case .transport(let error):
      "transport failure: \(error)"
    case .malformedResponse(let error):
      "the response could not be decoded: \(error)"
    case .unknownAnswerType(let question, let type):
      "question '\(question)' came back with an unknown answer type '\(type)'"
    case .missingAnswer(let question):
      "the response has no answer for question '\(question)'"
    case .answerTypeMismatch(let question, let expected, let actual):
      "question '\(question)' expected a \(expected) answer but got \(actual)"
    case .unrecognizedChoice(let question, let value, let expected):
      "question '\(question)' chose '\(value)', which is not one of \(expected)"
    case .invalidQuestion(let name, let reason):
      "question '\(name)' is invalid: \(reason)"
    case .duplicateQuestionName(let name):
      "question name '\(name)' is used more than once"
    case .emptyQuestionSet:
      "a request must carry at least one question"
    }
  }
}

extension JevError: Equatable {
  /// Wrapped errors compare by their description: `any Error` is not `Equatable`,
  /// and tests still need to assert on these cases.
  public static func == (lhs: JevError, rhs: JevError) -> Bool {
    switch (lhs, rhs) {
    case (.unauthorized, .unauthorized), (.overloaded, .overloaded),
      (.emptyQuestionSet, .emptyQuestionSet):
      true
    case let (.invalidRequest(a), .invalidRequest(b)):
      a == b
    case let (.rateLimited(a), .rateLimited(b)):
      a == b
    case let (.http(sa, ba), .http(sb, bb)):
      sa == sb && ba == bb
    case let (.transport(a), .transport(b)):
      String(describing: a) == String(describing: b)
    case let (.malformedResponse(a), .malformedResponse(b)):
      String(describing: a) == String(describing: b)
    case let (.unknownAnswerType(qa, ta), .unknownAnswerType(qb, tb)):
      qa == qb && ta == tb
    case let (.missingAnswer(a), .missingAnswer(b)):
      a == b
    case let (.answerTypeMismatch(qa, ea, aa), .answerTypeMismatch(qb, eb, ab)):
      qa == qb && ea == eb && aa == ab
    case let (.unrecognizedChoice(qa, va, ea), .unrecognizedChoice(qb, vb, eb)):
      qa == qb && va == vb && ea == eb
    case let (.invalidQuestion(na, ra), .invalidQuestion(nb, rb)):
      na == nb && ra == rb
    case let (.duplicateQuestionName(a), .duplicateQuestionName(b)):
      a == b
    default:
      false
    }
  }
}

extension JevError: Hashable {
  /// Wrapped errors hash by their description, matching how `==` compares them:
  /// `any Error` is neither `Hashable` nor `Equatable`.
  public func hash(into hasher: inout Hasher) {
    switch self {
    case .unauthorized: hasher.combine(0)
    case .invalidRequest(let body): hasher.combine(1); hasher.combine(body)
    case .rateLimited(let retryAfter): hasher.combine(2); hasher.combine(retryAfter)
    case .overloaded: hasher.combine(3)
    case let .http(status, body): hasher.combine(4); hasher.combine(status); hasher.combine(body)
    case .transport(let error): hasher.combine(5); hasher.combine(String(describing: error))
    case .malformedResponse(let error):
      hasher.combine(6); hasher.combine(String(describing: error))
    case let .unknownAnswerType(question, type):
      hasher.combine(7); hasher.combine(question); hasher.combine(type)
    case .missingAnswer(let question): hasher.combine(8); hasher.combine(question)
    case let .answerTypeMismatch(question, expected, actual):
      hasher.combine(9); hasher.combine(question); hasher.combine(expected); hasher.combine(actual)
    case let .unrecognizedChoice(question, value, expected):
      hasher.combine(10); hasher.combine(question); hasher.combine(value); hasher.combine(expected)
    case let .invalidQuestion(name, reason):
      hasher.combine(11); hasher.combine(name); hasher.combine(reason)
    case .duplicateQuestionName(let name): hasher.combine(12); hasher.combine(name)
    case .emptyQuestionSet: hasher.combine(13)
    }
  }
}

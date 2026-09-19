import Foundation
import Testing

@testable import Jev

/// Cases that came out of review. Each one pins a defect that shipped once.
@Suite("Regressions")
struct RegressionTests {
  // MARK: ScoreValue

  @Test("two string keys for one level are rejected rather than silently merged")
  func duplicateLevelKeys() {
    // "0" and "00" are distinct strings but the same level. Counting before
    // converting let a one-level score through.
    let json = """
      {"score":0.5,"probabilities":{"0":0.4,"00":0.6},"confidence":0.9}
      """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ScoreValue.self, from: Data(json.utf8))
    }
  }

  @Test("a non-integer level key is rejected")
  func nonIntegerLevelKey() {
    let json = """
      {"score":0.5,"probabilities":{"low":0.4,"high":0.6},"confidence":0.9}
      """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ScoreValue.self, from: Data(json.utf8))
    }
  }

  // MARK: Backoff

  @Test("an absurd multiplier saturates instead of collapsing back")
  func backoffSaturates() {
    // Falling back to the base delay made the second attempt wait *less* than the
    // configured growth implied.
    let policy = RetryPolicy(initialDelay: .milliseconds(500), multiplier: 1e12, jitter: 0)
    let first = policy.backoff(afterAttempt: 1, randomness: 0.5)
    let second = policy.backoff(afterAttempt: 2, randomness: 0.5)
    #expect(first == .milliseconds(500))
    #expect(second > first)
  }

  @Test("backoff never goes backwards as attempts grow")
  func backoffMonotonic() {
    let policy = RetryPolicy(initialDelay: .milliseconds(500), multiplier: 1e6, jitter: 0)
    let delays = (1...5).map { policy.backoff(afterAttempt: $0, randomness: 0.5) }
    for (earlier, later) in zip(delays, delays.dropFirst()) {
      #expect(later >= earlier)
    }
  }

  // MARK: Errors

  @Test("an undecodable body is classified as malformed, not as something else")
  func malformedIsSpecific() async throws {
    let transport = StubTransport([JevHTTPResponse.ok("{not json")])
    let client = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: transport, retryPolicy: .none,
      sleep: { _ in }, randomness: { 0.5 }, now: { Date() }
    )
    do {
      _ = try await client.evaluate(state: "x") { department; urgency; frustration }
      Issue.record("expected a failure")
    } catch let error as JevError {
      guard case .malformedResponse = error else {
        Issue.record("expected .malformedResponse, got \(error)")
        return
      }
    }
  }

  @Test("JevError is usable in a Set, as the API advertises")
  func errorHashable() {
    let errors: Set<JevError> = [
      .unauthorized, .unauthorized, .missingAnswer(question: "a"),
      .missingAnswer(question: "a"), .missingAnswer(question: "b"),
    ]
    #expect(errors.count == 3)
  }

  // MARK: Cancellation

  @Test("cancelling during a backoff surfaces CancellationError unwrapped")
  func cancellationNotWrapped() async throws {
    let transport = StubTransport([JevHTTPResponse.status(429)])
    let client = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: transport, retryPolicy: RetryPolicy(maxAttempts: 5),
      sleep: { _ in throw CancellationError() },
      randomness: { 0.5 }, now: { Date() }
    )
    await #expect(throws: CancellationError.self) {
      _ = try await client.evaluate(state: "x") { department; urgency; frustration }
    }
  }

  @Test("a transport failure is wrapped, but cancellation is not")
  func transportWrapping() async throws {
    struct Boom: Error {}
    let wrapped = StubTransport([.failure(Boom())])
    let client = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: wrapped, retryPolicy: .none,
      sleep: { _ in }, randomness: { 0.5 }, now: { Date() }
    )
    do {
      _ = try await client.evaluate(state: "x") { department; urgency; frustration }
      Issue.record("expected a failure")
    } catch let error as JevError {
      guard case .transport = error else {
        Issue.record("expected .transport, got \(error)")
        return
      }
    }

    let cancelled = StubTransport([.failure(CancellationError())])
    let cancelClient = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: cancelled, retryPolicy: .none,
      sleep: { _ in }, randomness: { 0.5 }, now: { Date() }
    )
    await #expect(throws: CancellationError.self) {
      _ = try await cancelClient.evaluate(state: "x") { department; urgency; frustration }
    }
  }

  // MARK: Retry-After inside the loop

  @Test("Retry-After is what the loop waits for, with no jitter applied")
  func retryAfterUsedByLoop() async throws {
    let recorded = Recorder()
    let transport = StubTransport([
      JevHTTPResponse.status(429, headers: ["Retry-After": "7"]),
      JevHTTPResponse.ok(realTriageJSON),
    ])
    // A jitter of 0.9 would visibly move a backoff; Retry-After must be immune.
    let policy = RetryPolicy(initialDelay: .milliseconds(100), jitter: 0.9)
    let client = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: transport, retryPolicy: policy,
      sleep: { recorded.append($0) }, randomness: { 0 }, now: { Date() }
    )
    _ = try await client.evaluate(state: "x") { department; urgency; frustration }
    #expect(recorded.values == [.seconds(7)])
  }

  @Test("without Retry-After the loop falls back to the backoff")
  func backoffUsedByLoop() async throws {
    let recorded = Recorder()
    let transport = StubTransport([
      JevHTTPResponse.status(429),
      JevHTTPResponse.ok(realTriageJSON),
    ])
    let policy = RetryPolicy(initialDelay: .milliseconds(100), jitter: 0)
    let client = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: transport, retryPolicy: policy,
      sleep: { recorded.append($0) }, randomness: { 0.5 }, now: { Date() }
    )
    _ = try await client.evaluate(state: "x") { department; urgency; frustration }
    #expect(recorded.values == [.milliseconds(100)])
  }

  // MARK: Noul routing

  @Test("outside the band but not decisive enough still escalates")
  func noulOutsideBandButWeak() {
    // 0.8 clears a 0.35...0.65 band, but a decisiveness of 0.8 is below a 0.9 bar.
    let policy = RoutingPolicy(escalateBelow: 0.9, autoAtOrAbove: 0.95)
    let judgement = policy.decide(Probability(clamping: 0.8))
    #expect(judgement.answer == true)
    #expect(judgement.decisiveness == 0.8)
    #expect(judgement.decision == .escalate)
  }

  @Test("the same holds on the negative side")
  func noulOutsideBandButWeakNegative() {
    let policy = RoutingPolicy(escalateBelow: 0.9, autoAtOrAbove: 0.95)
    let judgement = policy.decide(Probability(clamping: 0.2))
    #expect(judgement.answer == false)
    #expect(abs(judgement.decisiveness - 0.8) < 1e-12)
    #expect(judgement.decision == .escalate)
  }
}

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Duration] = []

  func append(_ duration: Duration) {
    lock.withLock { storage.append(duration) }
  }

  var values: [Duration] {
    lock.withLock { storage }
  }
}

/// Found in the release review. Routing said "act automatically" for answers the
/// caller could not actually obtain, which is the one thing this library must not do.
@Suite("Routing cannot outrun the answer")
struct RoutingConsistencyTests {
  private let policy = RoutingPolicy.default

  private var response: JevResponse {
    get throws {
      let json = """
        {"model":"m","answers":{
          "department":{"type":"choice","choice":"billing","confidence":0.95,
                        "probabilities":{"billing":0.95,"technical":0.05}},
          "other":{"type":"choice","choice":"legal","confidence":0.97,
                   "probabilities":{"legal":0.97}}},
         "usage":{"input_tokens":1,"output_tokens":0}}
        """
      return try JSONDecoder().decode(JevResponse.self, from: Data(json.utf8))
    }
  }

  @Test("a question of the wrong kind yields no confidence and escalates")
  func wrongKind() throws {
    // The wire answer is a choice; this question reads the same name as a score.
    let asScore = ScoreQuestion("department", "How bad?", levels: ["a", "b"])
    let response = try response
    #expect(throws: JevError.self) { try response.require(asScore) }
    #expect(response.confidence(of: asScore) == nil)
    #expect(policy.decide(response, of: asScore) == .escalate)
  }

  @Test("an unrecognised choice yields no confidence and escalates")
  func unrecognizedChoice() throws {
    let other = ChoiceQuestion<Department>("other", "Which team?")
    let response = try response
    #expect(throws: JevError.self) { try response.require(other) }
    #expect(response.confidence(of: other) == nil)
    #expect(policy.decide(response, of: other) == .escalate)
  }

  @Test("whenever confidence is non-nil, the answer is obtainable")
  func confidenceImpliesObtainable() throws {
    let department = ChoiceQuestion<Department>("department", "Which team?")
    let response = try response
    #expect(response.confidence(of: department) == 0.95)
    #expect(try response.require(department) == .billing)
  }

  @Test("a confidence outside 0...1 is rejected at the boundary", arguments: ["2.0", "-0.1"])
  func confidenceOutOfRange(_ value: String) {
    let json = """
      {"model":"m","answers":{"x":{"type":"choice","choice":"a","confidence":\(value),
       "probabilities":{"a":1.0}}},"usage":{"input_tokens":1,"output_tokens":0}}
      """
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(JevResponse.self, from: Data(json.utf8))
    }
  }

  @Test("an unencodable state fails as a JevError like everything else")
  func encodingFailure() async throws {
    struct Unencodable: Encodable, Sendable {
      func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(
          self, .init(codingPath: [], debugDescription: "nope")
        )
      }
    }
    let client = JevClient(
      apiKey: "k", model: "jev-latest", endpoint: .jevSystemOne,
      transport: StubTransport([JevHTTPResponse.ok(realTriageJSON)]),
      retryPolicy: .none, sleep: { _ in }, randomness: { 0.5 }, now: { Date() }
    )
    do {
      _ = try await client.evaluate(state: Unencodable()) { urgency }
      Issue.record("expected a failure")
    } catch let error as JevError {
      guard case .invalidRequestBody = error else {
        Issue.record("expected .invalidRequestBody, got \(error)")
        return
      }
    }
  }
}

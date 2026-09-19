import Foundation
import Testing

@testable import Jev

/// Builds a client whose backoff is deterministic and whose sleeps are recorded
/// instead of performed, so retry behaviour is tested without waiting.
private func makeClient(
  transport: any JevTransport,
  retryPolicy: RetryPolicy = .default,
  randomness: Double = 0.5,
  now: Date = Date(timeIntervalSince1970: 0),
  slept: @escaping @Sendable (Duration) -> Void = { _ in }
) -> JevClient {
  JevClient(
    apiKey: "test-key",
    model: "jev-latest",
    endpoint: .jevSystemOne,
    transport: transport,
    retryPolicy: retryPolicy,
    sleep: { slept($0) },
    randomness: { randomness },
    now: { now }
  )
}

@Suite("Client")
struct ClientTests {
  @Test("a successful response maps onto the typed query")
  func success() async throws {
    let transport = StubTransport([JevHTTPResponse.ok(realTriageJSON)])
    let result = try await makeClient(transport: transport)
      .evaluate(state: "any") { department; urgency; frustration }

    #expect(try result.require(department) == .billing)
    #expect(result[department] == .billing)         // the forgiving form
    #expect(result.model == "jev-1.13.0")
    #expect(result.usage.inputTokens == 394)
  }

  @Test("the request carries the key, the model and the questions")
  func requestShape() async throws {
    let transport = StubTransport([JevHTTPResponse.ok(realTriageJSON)])
    _ = try await makeClient(transport: transport).evaluate(state: "hello") { department; urgency; frustration }

    let body = try #require(transport.sentBodies.first)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(json?["model"] as? String == "jev-latest")
    #expect(json?["state"] as? String == "hello")
    let questions = json?["questions"] as? [String: Any]
    #expect(Set(questions?.keys ?? [:].keys) == ["department", "urgency", "frustration"])
  }

  @Test("401 is surfaced and never retried")
  func unauthorized() async throws {
    let transport = StubTransport([JevHTTPResponse.status(401)])
    await #expect(throws: JevError.unauthorized) {
      _ = try await makeClient(transport: transport).evaluate(state: "x") { department; urgency; frustration }
    }
    #expect(transport.callCount == 1)
  }

  @Test("422 carries the server's explanation")
  func invalidRequest() async throws {
    let transport = StubTransport([JevHTTPResponse.status(422, body: "state too large")])
    await #expect(throws: JevError.invalidRequest(body: "state too large")) {
      _ = try await makeClient(transport: transport).evaluate(state: "x") { department; urgency; frustration }
    }
    #expect(transport.callCount == 1)
  }

  @Test("an undecodable body is reported as malformed")
  func malformed() async throws {
    let transport = StubTransport([JevHTTPResponse.ok("{not json")])
    await #expect(throws: JevError.self) {
      _ = try await makeClient(transport: transport).evaluate(state: "x") { department; urgency; frustration }
    }
  }
}

@Suite("Retrying")
struct RetryTests {
  @Test("429 is retried and the eventual success is returned")
  func retriesThenSucceeds() async throws {
    let transport = StubTransport([
      JevHTTPResponse.status(429),
      JevHTTPResponse.ok(realTriageJSON),
    ])
    let result = try await makeClient(transport: transport)
      .evaluate(state: "x") { department; urgency; frustration }
    #expect(try result.require(department) == .billing)
    #expect(transport.callCount == 2)
  }

  @Test("attempts are capped and the last failure surfaces")
  func exhausts() async throws {
    let transport = StubTransport([JevHTTPResponse.status(529)])
    await #expect(throws: JevError.overloaded) {
      _ = try await makeClient(transport: transport, retryPolicy: RetryPolicy(maxAttempts: 3))
        .evaluate(state: "x") { department; urgency; frustration }
    }
    // maxAttempts counts the first try, so three calls and two retries.
    #expect(transport.callCount == 3)
  }

  @Test("no sleep happens after the final attempt")
  func noTrailingSleep() async throws {
    let sleeps = Sleeps()
    let transport = StubTransport([JevHTTPResponse.status(429)])
    _ = try? await makeClient(
      transport: transport,
      retryPolicy: RetryPolicy(maxAttempts: 3),
      slept: { sleeps.record($0) }
    ).evaluate(state: "x") { department; urgency; frustration }
    #expect(sleeps.recorded.count == 2)
  }

  @Test("backoff grows by the multiplier")
  func backoffGrows() {
    let policy = RetryPolicy(
      maxAttempts: 4, initialDelay: .milliseconds(100), multiplier: 2, jitter: 0
    )
    #expect(policy.backoff(afterAttempt: 1, randomness: 0.5) == .milliseconds(100))
    #expect(policy.backoff(afterAttempt: 2, randomness: 0.5) == .milliseconds(200))
    #expect(policy.backoff(afterAttempt: 3, randomness: 0.5) == .milliseconds(400))
  }

  @Test("jitter spreads the delay around the nominal value")
  func jitterBounds() {
    let policy = RetryPolicy(initialDelay: .milliseconds(100), multiplier: 2, jitter: 0.2)
    #expect(policy.backoff(afterAttempt: 1, randomness: 0) == .milliseconds(80))
    #expect(policy.backoff(afterAttempt: 1, randomness: 1) == .milliseconds(120))
  }

  @Test("a numeric Retry-After wins over the backoff")
  func retryAfterSeconds() {
    let response = JevHTTPResponse(status: 429, headers: ["Retry-After": "5"], body: Data())
    let delay = RetryPolicy.default.retryAfter(from: response, now: Date())
    #expect(delay == .seconds(5))
  }

  @Test("Retry-After is matched case-insensitively")
  func retryAfterCaseInsensitive() {
    let response = JevHTTPResponse(status: 429, headers: ["retry-after": "3"], body: Data())
    #expect(RetryPolicy.default.retryAfter(from: response, now: Date()) == .seconds(3))
  }

  @Test("an HTTP-date Retry-After is resolved against now")
  func retryAfterDate() {
    let now = Date(timeIntervalSince1970: 0)
    let response = JevHTTPResponse(
      status: 429,
      headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:10 GMT"],
      body: Data()
    )
    #expect(RetryPolicy.default.retryAfter(from: response, now: now) == .seconds(10))
  }

  @Test("an unparseable Retry-After falls back to the backoff", arguments: ["soon", "-1", ""])
  func retryAfterInvalid(_ value: String) {
    let response = JevHTTPResponse(status: 429, headers: ["Retry-After": value], body: Data())
    #expect(RetryPolicy.default.retryAfter(from: response, now: Date()) == nil)
  }

  @Test("Retry-After is capped")
  func retryAfterCapped() {
    let policy = RetryPolicy(maxRetryAfter: .seconds(10))
    let response = JevHTTPResponse(status: 429, headers: ["Retry-After": "9999"], body: Data())
    #expect(policy.retryAfter(from: response, now: Date()) == .seconds(10))
  }

  @Test("a nonsensical policy is normalised rather than trapping")
  func normalisation() {
    let policy = RetryPolicy(
      maxAttempts: -5, initialDelay: .seconds(-1), multiplier: 0.1, jitter: 9
    )
    #expect(policy.maxAttempts == 1)
    #expect(policy.initialDelay == .zero)
    #expect(policy.multiplier == 1)
    #expect(policy.jitter == 1)
  }

  @Test("a status outside the retryable set is not retried")
  func nonRetryable() async throws {
    let transport = StubTransport([JevHTTPResponse.status(500, body: "boom")])
    await #expect(throws: JevError.http(status: 500, body: "boom")) {
      _ = try await makeClient(transport: transport).evaluate(state: "x") { department; urgency; frustration }
    }
    #expect(transport.callCount == 1)
  }

  @Test("the retryable set is honoured when the caller widens it")
  func widenedSet() async throws {
    let transport = StubTransport([
      JevHTTPResponse.status(500),
      JevHTTPResponse.ok(realTriageJSON),
    ])
    let policy = RetryPolicy(retryableStatuses: [429, 529, 500])
    let result = try await makeClient(transport: transport, retryPolicy: policy)
      .evaluate(state: "x") { department; urgency; frustration }
    #expect(try result.require(department) == .billing)
    #expect(transport.callCount == 2)
  }
}

/// Records the delays a client asked to sleep for.
private final class Sleeps: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Duration] = []

  func record(_ duration: Duration) {
    lock.withLock { storage.append(duration) }
  }

  var recorded: [Duration] {
    lock.withLock { storage }
  }
}

import Foundation

public struct JevClient: Sendable {
  /// Applied to the request body. `.sortedKeys` makes the JSON byte-stable, which
  /// is useful for snapshotting; it does not preserve the order options were
  /// written in, because no `JSONEncoder` setting does.
  public var outputFormatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]

  private let apiKey: String
  private let model: String
  private let endpoint: URL
  private let transport: any JevTransport
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let randomness: @Sendable () -> Double
  private let now: @Sendable () -> Date

  public init(
    apiKey: String,
    model: String = "jev-latest",
    endpoint: URL = .jevSystemOne,
    transport: any JevTransport = URLSessionTransport(),
    retryPolicy: RetryPolicy = .default
  ) {
    self.init(
      apiKey: apiKey, model: model, endpoint: endpoint,
      transport: transport, retryPolicy: retryPolicy,
      sleep: { try await Task.sleep(for: $0) },
      randomness: { Double.random(in: 0...1) },
      now: { Date() }
    )
  }

  /// Seams for tests: backoff is deterministic when the clock and randomness are
  /// supplied, so a retry test does not have to wait in real time.
  init(
    apiKey: String,
    model: String,
    endpoint: URL,
    transport: any JevTransport,
    retryPolicy: RetryPolicy,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    randomness: @escaping @Sendable () -> Double,
    now: @escaping @Sendable () -> Date
  ) {
    self.apiKey = apiKey
    self.model = model
    self.endpoint = endpoint
    self.transport = transport
    self.retryPolicy = retryPolicy
    self.sleep = sleep
    self.randomness = randomness
    self.now = now
  }

  /// Reads the key from the environment. `nil` when the variable is unset or
  /// empty after trimming.
  ///
  /// There is deliberately no initializer that reads the environment implicitly:
  /// where the key came from should be visible at the call site.
  public static func fromEnvironment(
    variable: String = "TYPESAFE_API_KEY",
    model: String = "jev-latest",
    endpoint: URL = .jevSystemOne,
    transport: any JevTransport = URLSessionTransport(),
    retryPolicy: RetryPolicy = .default
  ) -> JevClient? {
    let raw = ProcessInfo.processInfo.environment[variable] ?? ""
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    return JevClient(
      apiKey: key, model: model, endpoint: endpoint,
      transport: transport, retryPolicy: retryPolicy
    )
  }

  // MARK: Evaluation

  /// Sends the questions in one request. Jev evaluates them in parallel, so
  /// adding a question costs almost no extra latency.
  public func evaluate(
    state: some Encodable & Sendable,
    @QuestionBuilder questions build: () -> [any AnyQuestion]
  ) async throws -> JevResponse {
    try await evaluate(state: state, questions: try JevQuestionSet(build()))
  }

  public func evaluate(
    state: some Encodable & Sendable,
    questions: JevQuestionSet
  ) async throws -> JevResponse {
    let body: Data
    do {
      body = try encodeBody(state: state, questions: questions)
    } catch {
      throw JevError.invalidRequestBody(underlying: error)
    }
    let request = JevHTTPRequest(
      url: endpoint,
      headers: [
        "Authorization": "Bearer \(apiKey)",
        "Content-Type": "application/json",
      ],
      body: body
    )

    let response = try await sendWithRetries(request)
    do {
      return try JSONDecoder().decode(JevResponse.self, from: response.body)
    } catch let error as JevError {
      throw error
    } catch {
      throw JevError.malformedResponse(underlying: error)
    }
  }

  private func encodeBody(
    state: some Encodable & Sendable,
    questions: JevQuestionSet
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = outputFormatting
    return try encoder.encode(Body(state: state, model: model, questions: questions))
  }

  private struct Body<State: Encodable & Sendable>: Encodable {
    let state: State
    let model: String
    let questions: JevQuestionSet
  }

  // MARK: Retrying

  private func sendWithRetries(_ request: JevHTTPRequest) async throws -> JevHTTPResponse {
    var attempt = 1
    while true {
      let response: JevHTTPResponse
      do {
        response = try await transport.send(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw JevError.transport(error)
      }

      if (200..<300).contains(response.status) { return response }

      let isLastAttempt = attempt >= retryPolicy.maxAttempts
      guard retryPolicy.retryableStatuses.contains(response.status), !isLastAttempt else {
        throw failure(for: response)
      }

      let delay = retryPolicy.retryAfter(from: response, now: now())
        ?? retryPolicy.backoff(afterAttempt: attempt, randomness: randomness())
      try await sleep(delay)
      attempt += 1
    }
  }

  private func failure(for response: JevHTTPResponse) -> JevError {
    let body = String(decoding: response.body, as: UTF8.self)
    switch response.status {
    case 401: return .unauthorized
    case 422: return .invalidRequest(body: body)
    case 429: return .rateLimited(retryAfter: retryPolicy.retryAfter(from: response, now: now()))
    case 529: return .overloaded
    default: return .http(status: response.status, body: body)
    }
  }
}

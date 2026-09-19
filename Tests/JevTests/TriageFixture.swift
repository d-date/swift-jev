import Foundation
import Jev

/// The query used across the tests. It exercises all three primitives at once,
/// which is also how a real caller would use them: one request, parallel questions.
enum Department: String, JevChoiceOptions {
  case billing, technical, sales, account

  static var optionDescriptions: [Department: String] {
    [
      .billing: "Invoices, charges, refunds",
      .technical: "Bugs, outages, integrations",
      // `sales` and `account` are deliberately undescribed: their names carry the
      // meaning, and a null description keeps the request small.
    ]
  }
}

/// The questions used across the tests. All three primitives in one request,
/// which is also how a caller would use them: Jev evaluates them in parallel.
let department = ChoiceQuestion<Department>(
  "department", "Which team should handle this customer inquiry?"
)
let urgency = NoulQuestion(
  "urgency", "Does this inquiry need to be handled today?",
  whenTrue: "States a deadline within a day, or an active outage.",
  whenFalse: "Can wait for the normal support queue."
)
let frustration = ScoreQuestion(
  "frustration", "How frustrated is the customer?",
  levels: ["Calm and factual", "Visibly annoyed", "Angry, threatening to leave"]
)

let triageQuestions: [any AnyQuestion] = [department, urgency, frustration]

/// Returns a fixed sequence of responses, one per call, so a retry test does not
/// need a live server.
final class StubTransport: JevTransport, @unchecked Sendable {
  private let responses: [Result<JevHTTPResponse, any Error>]
  private let lock = NSLock()
  private var index = 0
  private var _sentBodies: [Data] = []

  init(_ responses: [Result<JevHTTPResponse, any Error>]) {
    self.responses = responses
  }

  convenience init(status: Int, body: String, headers: [String: String] = [:]) {
    self.init([
      .success(
        JevHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
      )
    ])
  }

  var callCount: Int {
    lock.withLock { index }
  }

  /// Guarded by the same lock the writes take: an unsynchronised getter would
  /// race a concurrent `send`, whatever the current tests happen to do.
  var sentBodies: [Data] {
    lock.withLock { _sentBodies }
  }

  func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse {
    let result: Result<JevHTTPResponse, any Error> = lock.withLock {
      _sentBodies.append(request.body)
      defer { index += 1 }
      return index < responses.count ? responses[index] : responses[responses.count - 1]
    }
    return try result.get()
  }
}

extension JevHTTPResponse {
  static func ok(_ json: String) -> Result<JevHTTPResponse, any Error> {
    .success(JevHTTPResponse(status: 200, headers: [:], body: Data(json.utf8)))
  }

  static func status(
    _ code: Int, headers: [String: String] = [:], body: String = ""
  ) -> Result<JevHTTPResponse, any Error> {
    .success(JevHTTPResponse(status: code, headers: headers, body: Data(body.utf8)))
  }
}

/// A real response captured from the API, used so decoding is tested against the
/// actual wire shape rather than one we imagined.
let realTriageJSON = """
  {"model":"jev-1.13.0",
   "answers":{
     "urgency":{"type":"noul","noul":0.81},
     "department":{"type":"choice","choice":"billing","confidence":0.83,
                   "probabilities":{"technical":0.11,"sales":0.0,"billing":0.89,"account":0.0}},
     "frustration":{"type":"score","score":1.6,
                    "legend":{"0":"Calm and factual","1":"Visibly annoyed","2":"Angry, threatening to leave"},
                    "probabilities":{"0":0.05,"1":0.3,"2":0.65},"confidence":0.78}},
   "usage":{"input_tokens":394,"output_tokens":57}}
  """

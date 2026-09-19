import Foundation
import Testing

// Deliberately not `@testable`: this target exists to prove the package is usable
// from outside, with only what it makes public.
import Jev

enum SupportTeam: String, JevChoiceOptions {
  case billing, technical, sales, account

  static var optionDescriptions: [SupportTeam: String] {
    [
      .billing: "Invoices, charges, refunds, payouts, pricing on an existing contract",
      .technical: "Bugs, outages, errors, SDK and integration problems",
      .sales: "Quotes for new or expanded contracts, plan upgrades",
      .account: "Login, credentials, two-factor, seats, permissions",
    ]
  }
}

let team = ChoiceQuestion<SupportTeam>(
  "team", "Which team should handle this customer inquiry?"
)
let urgency = NoulQuestion(
  "urgency", "Does this inquiry need to be handled today?",
  whenTrue: "The customer states a deadline within a day, or describes an active outage.",
  whenFalse: "The inquiry can wait for the normal support queue."
)
let frustration = ScoreQuestion(
  "frustration", "How frustrated is the customer?",
  levels: ["Calm and factual", "Visibly annoyed", "Angry, threatening to leave"]
)

@Suite("Public API")
struct PublicAPITests {
  @Test("a question set is assembled entirely from public API")
  func assembly() throws {
    let set = try JevQuestionSet([team, urgency, frustration])
    #expect(Set(set.questions.keys) == ["team", "urgency", "frustration"])
  }

  @Test("a client, policy and stub transport are all constructible")
  func constructible() {
    _ = JevClient(
      apiKey: "key",
      retryPolicy: RetryPolicy(maxAttempts: 2, retryableStatuses: [429])
    )
    _ = RoutingPolicy(escalateBelow: 0.7, autoAtOrAbove: 0.9)
    _ = JevHTTPResponse(status: 200, headers: ["a": "b"], body: Data())
    _ = JevHTTPRequest(url: .jevSystemOne, headers: [:], body: Data())
    _ = try? Question(instructions: "x", kind: .choice([ChoiceOption("a")]))
  }

  @Test("questions can be assembled at runtime")
  func runtimeAssembly() throws {
    // Something a macro could not do: the rubric comes from data, not a literal.
    let levels = ["low", "medium", "high"]
    let dynamic = ScoreQuestion("severity", "How severe?", levels: levels)
    let set = try JevQuestionSet([team, dynamic])
    #expect(set.questions.count == 2)
  }

  @Test("fromEnvironment declines an unset variable")
  func environment() {
    #expect(JevClient.fromEnvironment(variable: "JEV_DEFINITELY_UNSET_\(UUID().uuidString)") == nil)
  }
}

/// Runs only when a key is present, so CI stays offline by default.
@Suite(
  "Live API",
  .enabled(
    if: ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?.isEmpty == false,
    "set TYPESAFE_API_KEY to run"
  )
)
struct LiveTests {
  // These assert the shape of what comes back, not which option the model picks.
  // Which team wins is a property of the rubric wording, not of this library:
  // the same inquiry moves between `billing` and `technical` depending on whether
  // the billing rubric happens to mention payments. Pinning a label here would
  // test the model and break whenever it, or the wording, changed.

  @Test("a real response decodes into every typed accessor")
  func triage() async throws {
    let client = try #require(JevClient.fromEnvironment())
    let response = try await client.evaluate(
      state: "Help! My payouts have been failing for 3 days and I need to pay staff today."
    ) {
      team
      urgency
      frustration
    }

    let chosen = try response.require(team)
    #expect(SupportTeam.allCases.contains(chosen))
    #expect((0...1).contains(try response.require(urgency).value))
    #expect((0...2).contains(try response.require(frustration).value))
    #expect(response.usage.inputTokens > 0)
    // Output is reported but never billed, so cost tracks input alone.
    #expect(response.usage.estimatedCostUSD > 0)

    let confidence = try #require(response.confidence(of: team))
    #expect((0...1).contains(confidence))

    let distribution = try #require(response.probabilities(of: team))
    #expect(!distribution.isEmpty)
    #expect(abs(distribution.values.reduce(0, +) - 1) < 0.05)
    // The chosen option must be the one the distribution peaks at.
    #expect(distribution.max { $0.value < $1.value }?.key == chosen)
  }

  // An explicit outage is about as unambiguous as this task gets, so this is the
  // one semantic assertion worth making against a live model.
  @Test("an active outage reads as urgent")
  func urgencyReadsThrough() async throws {
    let client = try #require(JevClient.fromEnvironment())
    let response = try await client.evaluate(
      state: "The production API returns 502 in every region and has been down for five minutes."
    ) {
      team
      urgency
    }

    let judgement = RoutingPolicy.default.decide(try response.require(urgency))
    #expect(judgement.answer == true)
    #expect(judgement.decision != .escalate)
  }

  @Test("a score answer carries its legend back")
  func scoreLegend() async throws {
    let client = try #require(JevClient.fromEnvironment())
    let response = try await client.evaluate(
      state: "This is the fourth time I have written about the same bug. I am done."
    ) {
      frustration
    }
    let score = try response.require(frustration)
    #expect(score.legend.count == 3)
    #expect(score.normalized != nil)
    #expect((0...2).contains(score.rounded))
  }

  @Test("routing turns a live answer into a decision")
  func routing() async throws {
    let client = try #require(JevClient.fromEnvironment())
    let response = try await client.evaluate(
      state: "I would like a quote for adding 40 more seats next quarter."
    ) {
      team
    }
    let decision = RoutingPolicy.default.decide(response, of: team)
    #expect([Decision.auto, .confirm, .escalate].contains(decision))
  }
}

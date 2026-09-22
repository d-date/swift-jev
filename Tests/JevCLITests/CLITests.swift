import Foundation
import Jev
import Testing
@testable import JevCLI

@Test func acceptsAllQuestionKindsAndNestedState() throws {
  let data = Data(#"{"state":{"message":"hello","tags":["a",2]},"questions":{"urgent":{"type":"noul","instructions":"Today?","criteria":{"true":"deadline","false":"none"}},"team":{"type":"choice","instructions":"Who?","criteria":{"billing":"invoices","other":null}},"mood":{"type":"score","instructions":"How?","criteria":["calm","angry"]}}}"#.utf8)
  let input = try JSONDecoder().decode(CLIRequest.self, from: data)
  let questions = try input.questionSet()
  #expect(questions.questions.count == 3)
  let state = try JSONEncoder().encode(input.state)
  let object = try #require(JSONSerialization.jsonObject(with: state) as? [String: Any])
  #expect(object["message"] as? String == "hello")
  #expect((object["tags"] as? [Any])?.count == 2)
}

@Test func rejectsInvalidQuestionCriteria() throws {
  let data = Data(#"{"state":"text","questions":{"urgent":{"type":"noul","instructions":"Today?","criteria":{"true":3}}}}"#.utf8)
  let input = try JSONDecoder().decode(CLIRequest.self, from: data)
  #expect(throws: CLIError.self) { try input.questionSet() }
}

@Test func keyFileOverridesEnvironmentAndTrimsNewline() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("from-file\n".utf8).write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  var options = Options()
  options.keyPath = url.path
  #expect(try options.apiKey(environment: ["TYPESAFE_API_KEY": "from-env"]) == "from-file")
}

@Test func remoteHTTPIsRejectedForAPIKeys() throws {
  #expect(throws: CLIError.self) {
    try Options.parse(["--endpoint", "http://example.com/evaluate"])
  }
  #expect(try Options.parse(["--endpoint", "http://127.0.0.1:8080/evaluate"]) != nil)
}

@Test func emitsAllAnswerKindsAsJSON() throws {
  let response = JevResponse(model: "jev-latest", answers: JevAnswers([
    "urgent": .noul(Probability(clamping: 0.8)),
    "team": .choice(.init(value: "billing", probabilities: ["billing": 0.9], confidence: 0.9)),
    "mood": .score(.init(value: 0.4, legend: [0: "calm", 1: "angry"], probabilities: [0: 0.6, 1: 0.4], confidence: 0.7)),
  ]), usage: Usage(inputTokens: 10, outputTokens: 2))
  let data = try CLIOutput.encode(response)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let answers = try #require(object["answers"] as? [String: [String: Any]])
  #expect(answers["urgent"]?["noul"] as? Double == 0.8)
  #expect(answers["team"]?["choice"] as? String == "billing")
  #expect((answers["mood"]?["legend"] as? [String: String])?["1"] == "angry")
}

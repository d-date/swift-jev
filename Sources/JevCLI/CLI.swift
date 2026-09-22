import Foundation
import Jev

enum CLIError: Error, CustomStringConvertible {
  case usage(String)
  case input(String)

  var description: String {
    switch self {
    case .usage(let message), .input(let message): message
    }
  }
}

struct Options {
  var inputPath: String?
  var keyPath: String?
  var model = "jev-latest"
  var endpoint = URL.jevSystemOne

  static let help = """
    Usage: jev [--input FILE] [--api-key-file FILE] [--model NAME] [--endpoint URL]

    Read JSON from FILE or standard input and write the Jev response as JSON.
    The input object needs "state" and "questions". The API key comes from
    TYPESAFE_API_KEY, or from --api-key-file when specified. A key file takes
    precedence over the environment. Do not put keys in command arguments.
    """

  static func parse(_ arguments: [String]) throws -> Options? {
    var options = Options()
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      if flag == "--help" || flag == "-h" { return nil }
      guard ["--input", "--api-key-file", "--model", "--endpoint"].contains(flag) else {
        throw CLIError.usage("unknown argument: \(flag)\n\(help)")
      }
      index += 1
      guard index < arguments.count, !arguments[index].isEmpty,
        !arguments[index].hasPrefix("--")
      else {
        throw CLIError.usage("missing value for \(flag)\n\(help)")
      }
      let value = arguments[index]
      switch flag {
      case "--input": options.inputPath = value
      case "--api-key-file": options.keyPath = value
      case "--model": options.model = value
      case "--endpoint":
        guard let url = URL(string: value), let host = url.host,
          url.scheme?.lowercased() == "https"
            || (url.scheme?.lowercased() == "http"
              && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()))
        else {
          throw CLIError.usage("--endpoint must use HTTPS (HTTP is allowed for localhost only)")
        }
        options.endpoint = url
      default: break
      }
      index += 1
    }
    return options
  }

  func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    let raw: String
    if let keyPath {
      do { raw = try String(contentsOfFile: keyPath, encoding: .utf8) }
      catch { throw CLIError.input("cannot read API key file: \(error.localizedDescription)") }
    } else {
      raw = environment["TYPESAFE_API_KEY"] ?? ""
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw CLIError.input("API key is empty; set TYPESAFE_API_KEY or use --api-key-file")
    }
    return key
  }
}

/// JSON values keep arbitrary state intact without coercing it to a string.
indirect enum JSONValue: Codable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
    else { self = .array(try container.decode([JSONValue].self)) }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

struct CLIRequest: Decodable {
  let state: JSONValue
  let questions: [String: CLIQuestion]

  func questionSet() throws -> JevQuestionSet {
    var result: [String: Question] = [:]
    for (name, question) in questions {
      do { result[name] = try question.makeQuestion() }
      catch { throw CLIError.input("question '\(name)': \(error)") }
    }
    do { return try JevQuestionSet(result) }
    catch { throw CLIError.input("invalid questions: \(error)") }
  }
}

struct CLIQuestion: Decodable {
  let type: String
  let instructions: String
  let criteria: JSONValue?

  func makeQuestion() throws -> Question {
    let kind: Question.Kind
    switch type {
    case "noul":
      if let criteria {
        guard case .object(let object) = criteria,
          Set(object.keys).isSubset(of: ["true", "false"])
        else { throw CLIError.input("noul criteria must be an object with true/false strings") }
        func optionalString(_ key: String) throws -> String? {
          guard let value = object[key] else { return nil }
          guard case .string(let string) = value else {
            throw CLIError.input("noul criteria.\(key) must be a string")
          }
          return string
        }
        kind = try .noul(whenTrue: optionalString("true"), whenFalse: optionalString("false"))
      } else {
        kind = .noul(whenTrue: nil, whenFalse: nil)
      }
    case "choice":
      guard case .object(let object) = criteria else {
        throw CLIError.input("choice criteria must be an object of option names and descriptions")
      }
      let options = try object.map { name, value -> ChoiceOption in
        switch value {
        case .string(let description): ChoiceOption(name, description)
        case .null: ChoiceOption(name)
        default: throw CLIError.input("choice criterion '\(name)' must be a string or null")
        }
      }
      kind = .choice(options)
    case "score":
      guard case .array(let array) = criteria else {
        throw CLIError.input("score criteria must be an array of 2 to 10 strings")
      }
      let levels = try array.map { value -> String in
        guard case .string(let string) = value else {
          throw CLIError.input("score criteria must contain only strings")
        }
        return string
      }
      kind = .score(levels: levels)
    default: throw CLIError.input("unknown question type '\(type)'")
    }
    return try Question(instructions: instructions, kind: kind)
  }
}

enum CLIOutput {
  static func encode(_ response: JevResponse) throws -> Data {
    var answers: [String: JSONValue] = [:]
    for name in response.answers.names {
      guard let answer = response.answers[name] else { continue }
      switch answer {
      case .noul(let probability):
        answers[name] = .object(["type": .string("noul"), "noul": .number(probability.value)])
      case .choice(let choice):
        answers[name] = .object([
          "type": .string("choice"), "choice": .string(choice.value),
          "probabilities": .object(choice.probabilities.mapValues(JSONValue.number)),
          "confidence": .number(choice.confidence),
        ])
      case .score(let score):
        // ScoreValue's public surface is encoded through its wire representation below.
        answers[name] = .object([
          "type": .string("score"), "score": .number(score.value),
          "legend": .object(Dictionary(uniqueKeysWithValues: score.legend.map { (String($0.key), .string($0.value)) })),
          "probabilities": .object(Dictionary(uniqueKeysWithValues: score.probabilities.map { (String($0.key), .number($0.value)) })),
          "confidence": .number(score.confidence),
        ])
      }
    }
    let output: JSONValue = .object([
      "model": .string(response.model), "answers": .object(answers),
      "usage": .object([
        "input_tokens": .integer(Int64(response.usage.inputTokens)),
        "output_tokens": .integer(Int64(response.usage.outputTokens)),
      ]),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(output)
    data.append(0x0A)
    return data
  }
}

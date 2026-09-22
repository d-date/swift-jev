import Foundation
import Jev

@main
enum Main {
  static func main() async {
    do {
      guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
        print(Options.help)
        return
      }
      let data: Data
      if let path = options.inputPath {
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw CLIError.input("cannot read input file: \(error.localizedDescription)") }
      } else {
        data = FileHandle.standardInput.readDataToEndOfFile()
      }
      let input: CLIRequest
      do { input = try JSONDecoder().decode(CLIRequest.self, from: data) }
      catch { throw CLIError.input("invalid input JSON: \(error)") }
      let questions = try input.questionSet()
      let key = try options.apiKey()
      let response = try await JevClient(
        apiKey: key, model: options.model, endpoint: options.endpoint
      ).evaluate(state: input.state, questions: questions)
      FileHandle.standardOutput.write(try CLIOutput.encode(response))
    } catch {
      FileHandle.standardError.write(Data("jev: \(error)\n".utf8))
      exit(error is CLIError || error is DecodingError ? 2 : 1)
    }
  }
}

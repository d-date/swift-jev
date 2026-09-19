import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension URL {
  public static let jevSystemOne = URL(string: "https://api.typesafe.ai/v1/systemone")!
}

public struct JevHTTPRequest: Sendable, Hashable {
  public var url: URL
  public var headers: [String: String]
  public var body: Data

  public init(url: URL, headers: [String: String], body: Data) {
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct JevHTTPResponse: Sendable, Hashable {
  public var status: Int
  /// Stored as given. Use `header(_:)` rather than subscripting this directly:
  /// HTTP header names are case-insensitive and `retry-after` is as valid as
  /// `Retry-After`.
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  /// Case-insensitive lookup.
  ///
  /// When two stored keys differ only by case, the first in sorted key order wins,
  /// so repeated lookups of the same response agree with each other.
  public func header(_ name: String) -> String? {
    let wanted = name.lowercased()
    return headers
      .filter { $0.key.lowercased() == wanted }
      .min { $0.key < $1.key }?
      .value
  }
}

/// One HTTP round trip.
///
/// A transport knows nothing about retrying: the client owns that, so a stub
/// transport in a test can return a fixed sequence without reimplementing backoff.
public protocol JevTransport: Sendable {
  func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse
}

public struct URLSessionTransport: JevTransport {
  private let session: URLSession
  private let timeout: TimeInterval

  public init(session: URLSession = .shared, timeout: TimeInterval = 60) {
    self.session = session
    self.timeout = timeout
  }

  public func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse {
    var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let key = key as? String, let value = value as? String {
        headers[key] = value
      }
    }
    return JevHTTPResponse(status: http.statusCode, headers: headers, body: data)
  }
}

import Foundation

/// How the client reacts to a retryable status.
public struct RetryPolicy: Sendable, Hashable {
  /// Total attempts *including* the first one. 3 means at most two retries.
  public var maxAttempts: Int
  public var initialDelay: Duration
  public var multiplier: Double
  /// The delay is multiplied by a uniform random factor in `1 - jitter ... 1 + jitter`.
  public var jitter: Double
  /// The single source of truth for what gets retried.
  ///
  /// 401 and 422 are absent by default because retrying them cannot help. Adding
  /// them is the caller's decision and the client will honour it.
  public var retryableStatuses: Set<Int>
  /// Upper bound applied to a server-supplied `Retry-After`.
  public var maxRetryAfter: Duration

  public init(
    maxAttempts: Int = 3,
    initialDelay: Duration = .milliseconds(500),
    multiplier: Double = 2.0,
    jitter: Double = 0.2,
    retryableStatuses: Set<Int> = [429, 529],
    maxRetryAfter: Duration = .seconds(60)
  ) {
    // Normalise rather than trap: a policy assembled from configuration should
    // degrade to something sane instead of crashing the process.
    self.maxAttempts = max(maxAttempts, 1)
    self.initialDelay = initialDelay < .zero ? .zero : initialDelay
    self.multiplier = max(multiplier, 1)
    self.jitter = min(max(jitter, 0), 1)
    self.retryableStatuses = retryableStatuses
    self.maxRetryAfter = maxRetryAfter < .zero ? .zero : maxRetryAfter
  }

  public static let `default` = RetryPolicy()
  public static let none = RetryPolicy(maxAttempts: 1)

  /// Backoff for the attempt that just failed, where `attempt` is 1-based.
  func backoff(afterAttempt attempt: Int, randomness: Double) -> Duration {
    let exponent = max(attempt - 1, 0)
    let scaled = initialDelay * pow(multiplier, Double(exponent))
    let factor = 1 + jitter * (randomness * 2 - 1)
    return scaled * factor
  }

  /// A server-supplied `Retry-After`, capped. Jitter is deliberately not applied:
  /// the server named a time and spreading it out would ignore the instruction.
  func retryAfter(from response: JevHTTPResponse, now: Date) -> Duration? {
    guard let raw = response.header("Retry-After")?
      .trimmingCharacters(in: .whitespaces), !raw.isEmpty
    else { return nil }

    if let seconds = Int(raw) {
      guard seconds >= 0 else { return nil }
      return min(.seconds(seconds), maxRetryAfter)
    }
    guard let date = RetryPolicy.httpDate(raw) else { return nil }
    let interval = date.timeIntervalSince(now)
    guard interval > 0 else { return .zero }
    return min(.seconds(interval), maxRetryAfter)
  }

  /// RFC 9110 permits three date formats; servers in practice send the first.
  private static func httpDate(_ raw: String) -> Date? {
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz",
                   "EEEE, dd-MMM-yy HH:mm:ss zzz",
                   "EEE MMM d HH:mm:ss yyyy"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: raw) { return date }
    }
    return nil
  }
}

extension Duration {
  /// Scales a duration, rounded to the nearest nanosecond.
  ///
  /// Rounding keeps the result predictable: scaling 100ms by 0.8 lands exactly on
  /// 80ms rather than on whatever binary floating point makes of 0.08 seconds.
  /// Nanosecond resolution is far finer than any backoff needs.
  fileprivate static func * (lhs: Duration, rhs: Double) -> Duration {
    guard rhs.isFinite, rhs > 0 else { return .zero }
    let seconds = Double(lhs.components.seconds) + Double(lhs.components.attoseconds) * 1e-18
    let nanoseconds = (seconds * rhs * 1_000_000_000).rounded()
    guard nanoseconds.isFinite else { return .saturated }
    // Saturate rather than wrapping or falling back: a backoff that got *shorter*
    // as the configured delay grew would be worse than one that is merely capped.
    guard nanoseconds < Double(Int64.max) else { return .saturated }
    return .nanoseconds(Int64(nanoseconds))
  }

  /// The largest delay this type represents in whole nanoseconds. Far longer than
  /// any caller will wait, and reached only by a nonsensical configuration.
  fileprivate static var saturated: Duration { .nanoseconds(Int64.max) }
}

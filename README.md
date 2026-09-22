# swift-jev

A Swift client for [Jev](https://docs.typesafe.ai/), TypeSafe AI's System One model.

Jev does not write text. You hand it a state and some typed questions, and it hands
back typed answers with calibrated probabilities. This package makes that exchange
type-safe from Swift, so question names never appear at a call site.

```swift
enum Department: String, JevChoiceOptions {
  case billing, technical, sales, account

  static var optionDescriptions: [Department: String] {
    [
      .billing: "Invoices, charges, refunds, payouts",
      .technical: "Bugs, outages, errors, SDK problems",
      .sales: "Quotes, plan upgrades, discounts",
      .account: "Login, credentials, two-factor, seats",
    ]
  }
}

let department = ChoiceQuestion<Department>(
  "department", "Which team should handle this customer inquiry?"
)
let urgency = NoulQuestion(
  "urgency", "Does this inquiry need to be handled today?",
  whenTrue: "States a deadline within a day, or describes an active outage.",
  whenFalse: "Can wait for the normal support queue."
)
let frustration = ScoreQuestion(
  "frustration", "How frustrated is the customer?",
  levels: ["Calm and factual", "Visibly annoyed", "Angry, threatening to leave"]
)

let client = JevClient(apiKey: key)
let response = try await client.evaluate(state: inquiry) {
  department
  urgency
  frustration
}

try response.require(department)       // Department
try response.require(urgency)          // Probability
response.confidence(of: department)    // Double?
response.probabilities(of: department) // [Department: Double]?
response.usage.estimatedCostUSD        // Double
```

All three questions travel in one request. Jev evaluates them in parallel, so
asking more of them costs almost no extra latency.

## Installation

```swift
.package(url: "https://github.com/d-date/swift-jev", from: "0.1.0")
```

```swift
.product(name: "Jev", package: "swift-jev")
```

Requires Swift 6.2. Supports macOS 13+, iOS 16+, tvOS 16+, watchOS 9+ and
visionOS 1+. Linux is declared and the code is written for it, but it is not yet
covered by CI — treat it as untested. **No dependencies**, so a clean build takes
about 20 seconds.

## CLI and agent skill

Build the `jev` executable with `swift build -c release`, or run it with
`swift run jev`. It reads a JSON request from standard input by default, or from
`--input FILE`, and writes the JSON response to standard output. Diagnostics go
to standard error. `--help` lists all options.

```json
{
  "state": {"message": "The app is down; please help today"},
  "questions": {
    "urgent": {
      "type": "noul",
      "instructions": "Does this need attention today?",
      "criteria": {"true": "Active outage or explicit deadline", "false": "Routine request"}
    },
    "department": {
      "type": "choice",
      "instructions": "Which team should handle this?",
      "criteria": {"technical": "Bugs and outages", "billing": "Charges and refunds"}
    },
    "severity": {
      "type": "score",
      "instructions": "How severe is the impact?",
      "criteria": ["Low", "Moderate", "High"]
    }
  }
}
```

Save this as `request.json`, then run `swift run jev --input request.json`.
`state` accepts any JSON value. Questions use the same `type`, `instructions`,
and `criteria` shapes as the Jev API. `choice` descriptions may be `null`;
`noul` criteria is optional. The CLI validates questions before sending them.

The CLI reads `TYPESAFE_API_KEY` from its environment. Configure that variable
through your shell or secret manager; do not put the key in the JSON request or
command arguments. Alternatively, use `--api-key-file PATH` to read a UTF-8 file
containing only the key (a trailing newline is fine). Restrict that file's
permissions, for example with `chmod 600 PATH`, and keep it outside the repo.
The file takes precedence over the environment. The CLI exits with status 2 for
input or configuration errors and 1 for API or network errors. `--model` defaults
to `jev-latest`; `--endpoint` is available for compatible HTTPS endpoints and
local HTTP testing.

The shared [Jev skill](skills/jev/SKILL.md) is linked at `.agents/skills/jev` for
Codex and `.claude/skills/jev` for Claude Code. Both agents can use the same CLI
and API key configuration from this checkout.

## The three primitives

| Question | Answer | What comes back |
|---|---|---|
| `ChoiceQuestion<Options>` | `Options` | the case, plus a distribution and a confidence |
| `NoulQuestion` | `Probability` | the probability the statement is true |
| `ScoreQuestion` | `ScoreValue` | a probability-weighted position on a rubric |

A question is an ordinary value. Its type parameter is what makes the answer typed,
so the compiler does the work with no code generation involved. That also means
questions can be built at runtime — from a database, a config file, a loop — which
a macro-based design could not do.

### Reading answers

`require(_:)` throws and explains what went wrong. The subscript is the forgiving
form and returns `nil`.

```swift
try response.require(department)  // Department, or throws .missingAnswer / .unrecognizedChoice
response[department]              // Department?
```

A question is matched to its answer **by name**. Read answers with the same question
values you sent, and do not reuse a name for a different question: a second question
with the same name and kind would read the first one's answer. Names are how the API
itself identifies answers, so this is the API's model rather than a limitation added
here.

`confidence(of:)` returns a value only when `require(_:)` would also succeed. If the
answer is of another kind, or is a choice the options type does not have, it returns
`nil` and routing escalates — a confidence that outran the answer would be the one
mistake this library must not make.

### Noul has no confidence, and the types say so

There is no `confidence(of:)` overload that accepts a `NoulQuestion`:

```swift
response.confidence(of: urgency)
// error: no exact matches in call to instance method 'confidence'
```

That is the documented design rather than an omission. For a Noul answer the
probability *is* the confidence, and a value near 0.5 means the model is genuinely
unsure — not that the statement is half true.

### Score values land between levels

`ScoreValue.value` is probability-weighted, so a rubric of three levels can return
1.3, meaning "mostly level 1, leaning towards 2". Use `rounded` for a discrete
level and `normalized` to map onto 0...1.

## Routing on confidence

The answer says *what*; the confidence says whether to act on it.

```swift
let policy = RoutingPolicy(escalateBelow: 0.6, autoAtOrAbove: 0.85)

switch policy.decide(response, of: department) {
case .auto:     route(try response.require(department))
case .confirm:  askFirst(try response.require(department))
case .escalate: handToHuman()
}
```

Hold a policy per action rather than one per client. The confidence that is plenty
for reading a balance is not enough to approve a transfer. The defaults mirror the
figures in TypeSafe's guidance and are a starting point to validate, not a
recommendation to adopt.

Noul routes through a band instead of a single cut:

```swift
let judgement = policy.decide(try response.require(urgency))
judgement.answer      // Bool?  — nil inside the undecided band
judgement.decision    // Decision
```

A hard `>= 0.5` turns the difference between 0.49 and 0.51 into a flipped answer,
which is a decision the caller makes rather than one the model expressed. The band
keeps "don't know" as its own outcome. `.auto` on a low probability means adopting
the *negative* answer with confidence — not approving whatever the question asked
about.

## Errors

Everything out of `evaluate` fails with `JevError`, so there is one contract rather
than two — including a state that cannot be encoded.

| Case | When |
|---|---|
| `.unauthorized` / `.invalidRequest` | 401 / 422. Never retried |
| `.rateLimited` / `.overloaded` | 429 / 529 after the retry policy gave up |
| `.missingAnswer` / `.answerTypeMismatch` | the response does not match the questions |
| `.unrecognizedChoice` | the model returned an option the enum does not have |
| `.malformedResponse` / `.unknownAnswerType` | the body is not the documented shape |
| `.invalidQuestion` / `.duplicateQuestionName` | the request could not be built |
| `.invalidRequestBody` | the state could not be encoded |

`CancellationError` is never wrapped.

Oversized state is not detected locally: the client has no tokenizer, so the
server's 422 is what reports it.

## Retrying

429 and 529 are retried with exponential backoff and jitter. `Retry-After` is
honoured when present, in both its numeric and HTTP-date forms, and is capped.

```swift
JevClient(
  apiKey: key,
  retryPolicy: RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(250))
)
```

`maxAttempts` counts the first try. `retryableStatuses` is the single source of
truth: widen it and the client will honour that.

## Testing against it

`JevTransport` is one method, so a stub needs no network:

```swift
struct Stub: JevTransport {
  func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse {
    JevHTTPResponse(status: 200, headers: [:], body: fixture)
  }
}

let client = JevClient(apiKey: "test", transport: Stub())
```

## A note on Foundation Models

There is no `JevFoundationModels` module, and that is deliberate. A `@Generable`
value already satisfies `Encodable & Sendable`, so it can be passed as the state
with no help from this package.

What this package also does not ship is a "normalise on device, then ask Jev"
helper. Measured over 12 Japanese inquiries, five runs each, that arrangement:

- dropped classification accuracy from 100% to 93%
- invented dates in 14 of the 28 extracted deadline fields
- multiplied latency by 6.3

Preprocessing helped one task and hurt another, so the useful default is to measure
per task rather than to reach for a convenience function. Sending the raw text is
worth trying first.

## Why there is no macro

An earlier version of this package derived the questions from a struct with a
`@JevQuery` macro. It was replaced, and the comparison is worth recording.

| | macro | question values |
|---|---|---|
| implementation | 461 lines | 120 lines |
| dependency | swift-syntax | none |
| clean build | **960s** | **21s** |
| type-checking five query sites | 0.24s | 0.26s |
| questions built at runtime | not possible | supported |
| generic containers, optionals | rejected | no restriction |
| reading a question that was never sent | impossible | compiles, resolves to `nil` |

Both designs give the same compile-time guarantees on the answers. The macro buys
one extra guarantee — a question cannot be read unless it was declared — and
charges a 46× clean build, a large dependency, and a restriction that every rubric
be a literal. Six of the eight defects found in review were in the macro or caused
by it, including one where instructions containing a newline were sent to the API
with literal backslashes.

## What is not here

- Client-side rate limiting. The client reacts to 429 rather than staying under
  1,200 req/min on its own
- Token counting
- Anything for models other than Jev

## License

MIT

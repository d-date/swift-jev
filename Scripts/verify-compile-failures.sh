#!/bin/bash
# Verifies the API rejects misuse at compile time.
#
# A normal test can only assert about code that compiles. The guarantees below are
# the opposite: they hold only if the compiler refuses the code, so each snippet is
# compiled on purpose and the script fails when one of them succeeds.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

MODULES=".build/debug"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PREAMBLE='import Jev

enum Department: String, JevChoiceOptions { case billing, technical }
struct NotAnOptionsType: Hashable, Sendable {}

let department = ChoiceQuestion<Department>("department", "Which team?")
let urgency = NoulQuestion("urgency", "Needs handling today?")
let mood = ScoreQuestion("mood", "How frustrated?", levels: ["calm", "angry"])
'

# name|snippet|why it must not compile
CASES=(
"noul_confidence|func check(_ a: JevAnswers) { _ = a.confidence(of: urgency) }|Noul carries no confidence; its probability is its confidence"

"noul_probabilities|func check(_ a: JevAnswers) { _ = a.probabilities(of: urgency) }|Noul has no option distribution"

"choice_non_conforming|let bogus = ChoiceQuestion<NotAnOptionsType>(\"x\", \"y\")|a Choice question's type parameter must conform to JevChoiceOptions"

"wrong_answer_type|func check(_ a: JevAnswers) throws { let x: Probability = try a.require(department); _ = x }|a Choice answer is not a Probability"

"score_as_choice|func check(_ a: JevAnswers) throws { let x: Department = try a.require(mood); _ = x }|a Score answer is not an options case"

"noul_as_score|func check(_ a: JevAnswers) throws { let x: ScoreValue = try a.require(urgency); _ = x }|a Noul answer is not a ScoreValue"

"routing_on_noul_question|func check(_ a: JevAnswers) { _ = RoutingPolicy.default.decide(a, of: urgency) }|routing on a Noul goes through its probability, not through a confidence"
)

failures=0
for entry in "${CASES[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  snippet="${rest%|*}"
  why="${rest##*|}"

  printf '%s\n%s\n' "$PREAMBLE" "$snippet" > "$WORK/$name.swift"

  if xcrun swiftc -typecheck -swift-version 6 \
      -I "$MODULES/Modules" -I "$MODULES" \
      "$WORK/$name.swift" >"$WORK/$name.log" 2>&1; then
    echo "FAIL  $name — compiled, but $why"
    failures=$((failures + 1))
  else
    echo "ok    $name — rejected ($why)"
  fi
done

# The positive control: if this one stops compiling, the checks above prove nothing.
cat > "$WORK/positive.swift" <<'EOF'
import Jev

enum Department: String, JevChoiceOptions { case billing, technical }

let department = ChoiceQuestion<Department>("department", "Which team?")
let urgency = NoulQuestion("urgency", "Needs handling today?")
let mood = ScoreQuestion("mood", "How frustrated?", levels: ["calm", "angry"])

func check(_ response: JevResponse) throws {
  _ = try response.require(department)      // Department
  _ = try response.require(urgency)         // Probability
  _ = try response.require(mood)            // ScoreValue
  _ = response.confidence(of: department)
  _ = response.confidence(of: mood)
  _ = response.probabilities(of: department)
  _ = RoutingPolicy.default.decide(response, of: department)
  _ = RoutingPolicy.default.decide(try response.require(urgency))
}

func send(_ client: JevClient, _ text: String) async throws -> JevResponse {
  try await client.evaluate(state: text) {
    department
    urgency
    mood
  }
}
EOF

if xcrun swiftc -typecheck -swift-version 6 \
    -I "$MODULES/Modules" -I "$MODULES" \
    "$WORK/positive.swift" >"$WORK/positive.log" 2>&1; then
  echo "ok    positive control — valid usage still compiles"
else
  echo "FAIL  positive control — valid usage no longer compiles:"
  sed 's/^/        /' "$WORK/positive.log" | head -20
  failures=$((failures + 1))
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all compile-time guarantees hold"
else
  echo "$failures compile-time guarantee(s) broken"
fi
exit "$failures"

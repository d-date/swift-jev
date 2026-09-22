---
name: jev
description: Evaluate a supplied state with TypeSafe AI Jev's noul, choice, or score questions through the swift-jev CLI. Use when the user asks Jev to classify, assess, or score content.
---

# Jev evaluation

Use the `jev` executable from this repository (or `swift run jev` from its root). Send one JSON object with `state` and `questions` through standard input or `--input FILE`. Put related questions in one request. The response is JSON on standard output; errors go to standard error.

The key must be supplied by the user or their existing environment. The CLI reads `TYPESAFE_API_KEY` by default, or a UTF-8 file named with `--api-key-file`. Never place the key in a command argument, request JSON, skill file, or repository file. If neither source is available, ask the user to configure one. Do not read or echo the key yourself. A call sends the state to TypeSafe AI; avoid including unrelated private data.

Input example:

```json
{
  "state": "Customer says the app is down and asks for a refund",
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which team should handle this inquiry?",
      "criteria": {"billing": "Refunds and charges", "technical": "Outages and bugs"}
    },
    "urgent": {
      "type": "noul",
      "instructions": "Does this need attention today?",
      "criteria": {"true": "Active outage or explicit deadline", "false": "Routine request"}
    },
    "severity": {
      "type": "score",
      "instructions": "How severe is the customer impact?",
      "criteria": ["Low", "Moderate", "High"]
    }
  }
}
```

`state` can be any JSON value. Every question needs a unique name, a `type`, and nonempty `instructions`. For `choice`, `criteria` maps option names to descriptions or `null`. For `score`, it is an ordered array of 2–10 level descriptions. For `noul`, the optional `criteria` object can describe `true` and `false`.

Interpret `noul` as the probability the statement is true. A value near 0.5 means uncertain; it has no separate confidence. `choice` and `score` return confidence and distributions. Treat results as assessments, and apply the user's decision rules before taking consequential actions. The CLI itself only evaluates; it does not authorize follow-up actions.

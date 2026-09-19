# swift-jev 仕様

TypeSafe AI の判断専用モデル **Jev**（System One Models）を Swift から使うためのクライアント。

> **改訂履歴**
> - v4（本文書）: **マクロを廃止し、質問を値として扱う設計に変更**。
>   実装と Jev 自身の判定（values 0.85 / macro 0.03、confidence 0.78）による。
>   クリーンビルドが 960 秒から 21 秒になった。
> - v3: 実装レビューの8件を反映。
> - v2: codex と Jev 自身によるレビューを反映。エラー契約・失敗モード・
>   ルーティングの全経路を確定。`JevFoundationModels` ターゲットは削除。
> - v1: 初版。レビューで17件の指摘を受けた。

## 目的と非目的

**目的**

- Jev の3プリミティブ（Noul / Choice / Score）を型安全に扱う
- 文字列キーを呼び出し側から消す
- 429 / 529 を自前で書かせない
- confidence によるルーティングを、事故りにくい形で提供する

**非目的**

- Jev 以外のモデルへの抽象化。System One 以外は対象外
- テキスト生成。Jev は構造的にできない
- 前処理パイプラインの提供（「FoundationModels について」を参照）
- **クライアント側のレート制御**。1,200 req/min を自分で下回る仕組みは v1 では持たない
- **トークン数の事前計算**。トークナイザを持たないため、超過は 422 で受ける

## 対象 API

- `POST https://api.typesafe.ai/v1/systemone`
- `Authorization: Bearer <API_KEY>` / `Content-Type: application/json`
- モデル: `jev-latest`（`jev-1.13.0` のエイリアス）
- 料金: 入力 $0.042 / 1M tokens、出力は無料
- レート制限: 250,000 tokens/sec、1,200 requests/min
- コンテキスト: リクエスト合計 64k tokens、`state` + 最長の質問で 32k tokens
- 質問は1コールで並列評価され、質問を増やしても応答時間はほとんど伸びない

### リクエスト

```json
{
  "state": "...",
  "model": "jev-latest",
  "questions": {
    "<name>": { "type": "noul|choice|score", "instructions": "...", "criteria": ... }
  }
}
```

| type | criteria | 返る値 |
|---|---|---|
| `noul` | `{"true": String, "false": String}`（省略可） | `noul`: Double (0...1) |
| `choice` | `{"<option>": String?}` | `choice`: String, `probabilities`, `confidence` |
| `score` | `[String]`（2〜10 レベル、low→high） | `score`: Double, `legend`, `probabilities`, `confidence` |

### レスポンス

```json
{
  "model": "jev-1.13.0",
  "answers": { "<name>": { "type": "...", ... } },
  "usage": { "input_tokens": 394, "output_tokens": 57 }
}
```

## パッケージ構成

```
Sources/
  Jev/          本体。型・質問・クライアント
Tests/
  JevTests/
  JevIntegrationTests/    TYPESAFE_API_KEY がある時だけ走る
Scripts/
  verify-compile-failures.sh   コンパイルで弾くべきものが弾かれるかの検証
```

- swift-tools-version: 6.2
- プラットフォーム: macOS 13+ / iOS 16+ / tvOS 16+ / watchOS 9+ / visionOS 1+、および Linux
- **依存なし。** クリーンビルドは約21秒

異常は Optional か `throws` で表す。

## エラー契約

すべての失敗をここに集約する。**マクロが生成する `init(answers:)` と低レベル API は
同じエラー型を使う。**

```swift
public enum JevError: Error, Sendable, Hashable {
    // MARK: Transport and HTTP
    case unauthorized                                  // 401. Not retried.
    case invalidRequest(body: String)                  // 422. Not retried.
    case rateLimited(retryAfter: Duration?)            // 429 after retries are exhausted.
    case overloaded                                    // 529 after retries are exhausted.
    case http(status: Int, body: String)               // Any other non-2xx.
    case transport(any Error)                          // Wrapped network failure.

    // MARK: Decoding
    case malformedResponse(underlying: any Error)      // Body is not the documented shape.
    case unknownAnswerType(question: String, type: String)

    // MARK: Answer mapping
    case missingAnswer(question: String)
    case answerTypeMismatch(question: String, expected: String, actual: String)
    case unrecognizedChoice(question: String, value: String, expected: [String])

    // MARK: Request construction
    case invalidQuestion(name: String, reason: InvalidQuestionReason)
    case duplicateQuestionName(String)
    case emptyQuestionSet
}

public enum InvalidQuestionReason: Sendable, Hashable {
    case scoreLevelCountOutOfRange(Int)   // must be 2...10
    case emptyChoiceOptions
    case duplicateChoiceOption(String)
    case emptyInstructions
}
```

`case transport` と `case malformedResponse` は既存エラーを包む。
**`CancellationError` は包まずそのまま伝播させる。**

### 失敗モードの割り当て

| 失敗 | 挙動 |
|---|---|
| 質問に対する回答が欠けている | `missingAnswer` を throw |
| 回答の `type` が質問の type と違う | `answerTypeMismatch` を throw |
| Choice の値が宣言した選択肢にない | `unrecognizedChoice` を throw |
| `probabilities` に宣言外のキーがある | **黙って捨てる**。モデルが選択肢名を正規化して返す可能性があるため、ここで失敗させない |
| レスポンス本体がデコードできない | `malformedResponse` を throw |
| 未知の answer type（将来のプリミティブ） | `unknownAnswerType` を throw |
| `state` がコンテキスト上限を超える | クライアントは検査しない。サーバの 422 を `invalidRequest` として返す |
| ネットワークのタイムアウト | トランスポートの責務。既定の `URLSessionTransport` は 60 秒。`transport` で包む |
| 1,200 req/min の超過 | クライアントは予防しない。429 をリトライし、尽きたら `rateLimited` |

## 値の型

### Probability

Noul の返り値。0...1 に制約された Double。

```swift
public struct Probability: Sendable, Hashable, Comparable, Codable {
    public let value: Double

    /// Clamps into 0...1. Traps on NaN, which is a programmer error rather than data.
    public init(clamping value: Double)

    /// `nil` when the value is NaN or outside 0...1.
    public init?(exactly value: Double)

    /// Rejects NaN and out-of-range values with a `DecodingError`, so a malformed
    /// payload cannot produce a Probability that violates its own invariant.
    public init(from decoder: any Decoder) throws
}
```

**`Decodable` は自動合成させない。** 合成された初期化子は `init(clamping:)` を通らず、
不変条件を破った値を作れてしまうため。

**confidence を持たない。** 公式ドキュメントが "(Noul answers don't carry one.)" と書くとおり、
確率そのものが確信度である。0.5 付近は「中くらい真」ではなく「本当に分からない」を意味する。

### ScoreValue

```swift
public struct ScoreValue: Sendable, Hashable, Codable {
    public let value: Double                  // probability-weighted, so fractional
    public let legend: [Int: String]
    public let probabilities: [Int: Double]
    public let confidence: Double

    public var rounded: Int { get }

    /// `nil` when there are fewer than two levels, which would divide by zero.
    public var normalized: Double? { get }
}
```

デコード時に検証する。**まずキーを整数に変換してから**レベル数を数える。
`{"0": .., "00": ..}` は文字列としては2件だが1レベルであり、変換前に数えると
単一レベルの `ScoreValue` が通ってしまうため。同じレベルが2回現れたら `DecodingError`。
レベル数が 2 未満、`value` が NaN、`value` が `0...(levels - 1)` の外でも同様。
`legend` のキーが連続していないことは許容する。

### JevChoiceOptions

```swift
public protocol JevChoiceOptions: RawRepresentable<String>, CaseIterable, Hashable, Sendable {
    /// Rubric per option. An option absent from this map is sent with a null
    /// description, which Jev reads as "the name alone specifies the choice".
    static var optionDescriptions: [Self: String] { get }
}

extension JevChoiceOptions {
    public static var optionDescriptions: [Self: String] { [:] }
}
```

## 質問の定義

### 低レベル API

マクロを使わずに書ける層。マクロはこの層の上に載る。

文字列リテラルの値は `StringLiteralExprSyntax.representedLiteralValue` で取り出す。
セグメントのソーステキストを読むと `\n` がバックスラッシュと `n` のまま残り、
**壊れた文言が API に送られる**。
**マクロを経由しないため、この層は実行時に検証する。**

```swift
public struct Question: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case noul(whenTrue: String?, whenFalse: String?)
        case choice([ChoiceOption])
        case score(levels: [String])
    }

    public var instructions: String
    public var kind: Kind

    /// Validates eagerly: empty instructions, empty or duplicated choice options,
    /// and score level counts outside 2...10 all throw.
    public init(instructions: String, kind: Kind) throws
}

public struct ChoiceOption: Sendable, Hashable {
    public var name: String
    public var description: String?
    public init(_ name: String, _ description: String? = nil)
}

public struct JevQuestionSet: Sendable, Hashable {
    /// Rejects an empty set and duplicated names.
    public init(_ questions: [String: Question]) throws
    public var questions: [String: Question] { get }
}
```

**選択肢は配列で保持する。** ただし `JSONEncoder` はキー付きコンテナの順序を保持せず、
同一プロセス内でも実行ごとに順序が変わることを実測で確認している。
送信 JSON のキー順は不定である。順序を安定させたい場合に備え
`JevClient.outputFormatting` で `.sortedKeys` を指定できるようにする（既定は付けない）。
**選択肢の順序が判断に影響するかは未検証であり、ライブラリとして保証もしない。**

### 質問の値

**マクロは使わない。** 質問は値であり、`ChoiceQuestion` の型引数が回答を型付ける。

```swift
public protocol AnyQuestion: Sendable {
    var name: String { get }
    func makeQuestion() throws -> Question
}

public struct ChoiceQuestion<Options: JevChoiceOptions>: AnyQuestion {
    public init(_ name: String, _ instructions: String)
}

public struct NoulQuestion: AnyQuestion {
    public init(_ name: String, _ instructions: String,
                whenTrue: String? = nil, whenFalse: String? = nil)
}

public struct ScoreQuestion: AnyQuestion {
    public init(_ name: String, _ instructions: String, levels: [String])
}
```

送信は result builder でまとめる。

```swift
let response = try await client.evaluate(state: text) {
    department
    urgency
    frustration
}
```

#### マクロを採らなかった理由

マクロ版（`@JevQuery`）も実装して比較した。

| | マクロ | 質問の値 |
|---|---|---|
| 実装量 | 461 行 | 120 行 |
| 依存 | swift-syntax | なし |
| クリーンビルド | **960 秒** | **21 秒** |
| 5箇所の型検査 | 0.24s | 0.26s |
| 実行時に質問を組む | 不可（リテラルのみ） | 可能 |
| ジェネリック・Optional | 拒否 | 制限なし |
| 未送信の質問を読む | 構造的に不可能 | コンパイルは通り `nil` になる |

回答に対するコンパイル時の保証は両者で同じ。マクロが追加で買えるのは
「宣言していない質問は読めない」の1点だけで、その対価が46倍のクリーンビルドと
大きな依存、そして全ての文言がリテラルでなければならないという制約だった。
実装レビューで出た8件の欠陥のうち6件がマクロ起因で、そのうち1件は
**改行を含む文言がバックスラッシュ付きで API に送られる**というものだった。

Jev 自身にも両設計を実コードで提示して判定させ、`values` 0.85 /
`macro` 0.03（confidence 0.78）だった。

## 結果の読み出し

生成された型はない。`JevResponse` と `JevAnswers` に、質問の値をキーにした
アクセサを生やす。

```swift
extension JevAnswers {
    // Forgiving: nil when absent or of another type. Swift has no throwing subscript.
    public subscript<Options: JevChoiceOptions>(question: ChoiceQuestion<Options>) -> Options?
    public subscript(question: NoulQuestion) -> Probability?
    public subscript(question: ScoreQuestion) -> ScoreValue?

    // Explaining: throws a JevError naming the question.
    public func require<Options: JevChoiceOptions>(_ q: ChoiceQuestion<Options>) throws -> Options
    public func require(_ q: NoulQuestion) throws -> Probability
    public func require(_ q: ScoreQuestion) throws -> ScoreValue

    public func confidence<Options: JevChoiceOptions>(of q: ChoiceQuestion<Options>) -> Double?
    public func confidence(of q: ScoreQuestion) -> Double?
    public func probabilities<Options: JevChoiceOptions>(of q: ChoiceQuestion<Options>) -> [Options: Double]?
}
```

`JevResponse` は同じものを転送する。

**`NoulQuestion` を受け取る `confidence(of:)` は用意しない。**
Noul に confidence は存在しないため、`response.confidence(of: urgency)` は
オーバーロード解決に失敗してコンパイルエラーになる。実測で確認済み。

**未送信の質問を読むとコンパイルは通る。** これはマクロ版にはなかった穴であり、
実行時に `nil` あるいは `missingAnswer` になる。`nil` を confidence 0 と
区別できるようにしてあり、ルーティングは `nil` を必ず `.escalate` として扱う。

## クライアント

```swift
public struct JevClient: Sendable {
    public var outputFormatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]

    public init(
        apiKey: String,
        model: String = "jev-latest",
        endpoint: URL = .jevSystemOne,
        transport: any JevTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .default
    )

    /// Reads the key from the environment. `nil` when the variable is unset or
    /// empty after trimming whitespace. Every other parameter mirrors `init`.
    public static func fromEnvironment(
        variable: String = "TYPESAFE_API_KEY",
        model: String = "jev-latest",
        endpoint: URL = .jevSystemOne,
        transport: any JevTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .default
    ) -> JevClient?

    /// Sends the questions in one request; Jev evaluates them in parallel.
    public func evaluate(
        state: some Encodable & Sendable,
        @QuestionBuilder questions build: () -> [any AnyQuestion]
    ) async throws -> JevResponse

    /// For a set assembled ahead of time.
    public func evaluate(
        state: some Encodable & Sendable,
        questions: JevQuestionSet
    ) async throws -> JevResponse
}
```

`apiKey` を省略した `init` は設けない。環境変数の暗黙読み取りをすると、
鍵がどこから来たか呼び出し側から見えなくなるため。

### トランスポート

```swift
public protocol JevTransport: Sendable {
    func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse
}

public struct JevHTTPRequest: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data
    public init(url: URL, headers: [String: String], body: Data)
}

public struct JevHTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Stored as given. Use `header(_:)` to look one up; direct dictionary access
    /// is case-sensitive and will miss `retry-after` vs `Retry-After`.
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String], body: Data)

    /// Case-insensitive lookup. Compares with `lowercased()` on both sides using
    /// the invariant behaviour of ASCII header names. When two stored keys differ
    /// only by case, the first in sorted key order wins, so the result is stable.
    public func header(_ name: String) -> String?
}
```

`URL.jevSystemOne` は `https://api.typesafe.ai/v1/systemone` を指す定数。

```swift
extension URL {
    public static let jevSystemOne = URL(string: "https://api.typesafe.ai/v1/systemone")!
}
```

すべての公開型に**明示的な public initializer を置く**。自動生成の初期化子は
internal のため、外部モジュールからスタブを組み立てられないため。

既定の `URLSessionTransport` は Apple プラットフォームでは `URLSession`、
Linux では `FoundationNetworking` を使う。タイムアウトは既定 60 秒、
`URLSessionTransport(timeout:)` で変更できる。

**トランスポートは1回の HTTP 往復だけを担い、リトライを知らない。**

### リトライ

```swift
public struct RetryPolicy: Sendable, Hashable {
    /// Total attempts including the first one. Values below 1 are treated as 1.
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var multiplier: Double
    /// Delay is multiplied by a uniform random factor in `1 - jitter ... 1 + jitter`.
    public var jitter: Double
    /// The single source of truth for what is retried. 401 and 422 are absent by
    /// default; adding them is the caller's decision and the client will honour it.
    public var retryableStatuses: Set<Int>
    /// Upper bound applied to a server-supplied Retry-After.
    public var maxRetryAfter: Duration

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(500),
        multiplier: Double = 2.0,
        jitter: Double = 0.2,
        retryableStatuses: Set<Int> = [429, 529],
        maxRetryAfter: Duration = .seconds(60)
    )

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)
}
```

確定させる規則。

- `maxAttempts` は**初回を含む**。3 なら最大2回の再試行
- **最後の試行の後は待たない**
- `retryableStatuses` が唯一の基準。既定に 401 / 422 は含まれないが、
  利用者が加えたらその指示に従う
- `Retry-After` は**整数秒と HTTP-date の両方**を解釈する。解釈できない値は無視して
  指数バックオフにフォールバックする。`maxRetryAfter` で上限を掛ける
- `Retry-After` にジッタは**適用しない**。サーバの指示をそのまま尊重する
- バックオフが `Duration` の表現範囲を超えたら**飽和させる**。基準値に戻すと、
  設定値を大きくしたのに待ち時間が短くなるという逆転が起きる
- `multiplier` が 1 未満、`jitter` が 0 未満または 1 超、負の `initialDelay` は
  初期化時に正規化する（それぞれ 1.0、0...1 にクランプ、`.zero`）
- 待機は `Task.sleep` を使い、キャンセルに応答する
- 合計待ち時間の上限は設けない。呼び出し側が `withTimeout` などで包む

## confidence ルーティング

```swift
public enum Decision: Sendable, Hashable {
    case auto        // act without asking
    case confirm     // act, but confirm first
    case escalate    // hand to a human
}

public struct RoutingPolicy: Sendable, Hashable {
    public var escalateBelow: Double        // default 0.6
    public var autoAtOrAbove: Double        // default 0.85
    public var undecidedBand: ClosedRange<Double>   // default 0.35...0.65

    public init(
        escalateBelow: Double = 0.6,
        autoAtOrAbove: Double = 0.85,
        undecidedBand: ClosedRange<Double> = 0.35...0.65
    )
}
```

### Choice と Score

```swift
extension RoutingPolicy {
    public func decide<Options: JevChoiceOptions>(
        _ answers: JevAnswers, of question: ChoiceQuestion<Options>
    ) -> Decision

    public func decide(_ answers: JevAnswers, of question: ScoreQuestion) -> Decision

    // The same two, taking a JevResponse.
}
```

- 質問が回答されていない（`confidence(of:)` が `nil`）→ `.escalate`
- `confidence < escalateBelow` → `.escalate`
- `confidence >= autoAtOrAbove` → `.auto`
- それ以外 → `.confirm`

### Noul

Noul には confidence が無いので、確率そのものから決める。
**全経路を定義する。**

```swift
public struct NoulJudgement: Sendable, Hashable {
    /// `nil` inside the undecided band: the model is saying it does not know.
    public var answer: Bool?
    /// How far the probability is from "don't know": `max(p, 1 - p)`.
    public var decisiveness: Double
    public var decision: Decision
}

extension RoutingPolicy {
    public func decide(_ probability: Probability) -> NoulJudgement
}
```

| 条件 | `answer` | `decision` |
|---|---|---|
| `undecidedBand` の内側 | `nil` | `.escalate` |
| 帯の外、`decisiveness < escalateBelow` | `p > 0.5` | `.escalate` |
| 帯の外、`decisiveness >= autoAtOrAbove` | `p > 0.5` | `.auto` |
| それ以外 | `p > 0.5` | `.confirm` |

**`.auto` は「アクションを実行してよい」ではなく「この答えを採用してよい」を意味する。**
`p = 0.01` に対する `.auto` は、`answer == false` を自信を持って採用してよい、という意味である。
否定の確信と、何かを実行する承認は別物なので、DocC に明記する。

### しきい値について

`0.6` / `0.85` は公式ドキュメントの目安をそのまま既定値にしたものであり、
**個々の用途で検証すべき値**である。同じ confidence でも、残高照会と送金承認では
要求水準が違う。`RoutingPolicy` をアクションごとに複数持てるよう、
クライアントには持たせず独立した値型にする。

## FoundationModels について

**専用ターゲットは設けない。**

`@Generable` の型はすでに `Encodable & Sendable` を満たせるため、
既存の `evaluate(state:as:)` にそのまま渡せる。`Generable` 制約を足した
オーバーロードを置いても、受け取れる入力は1つも増えない。

**前処理パイプライン（オンデバイスで整形してから Jev に投げる関数）も提供しない。**
日本語の問い合わせ12件を5回ずつ測った結果、オンデバイスでの英語整形は

- 部署分類の正解率を 100% から 93% に**下げた**
- `deadlines` に入った28項目のうち14項目が、入力に存在しない日付だった
- レイテンシを 6.3 倍にした

便利関数として出せば「まず前処理」という誤った既定を広めてしまう。
DocC の記事としてこの測定結果と使い方の例を載せ、
**タスクごとに測ってから決めること**を促すに留める。

## テスト

| 対象 | 方法 |
|---|---|
| 型制約 | Noul に confidence を要求する、回答を誤った型に束縛するなど、**弾かれるべきコードがコンパイルに失敗すること**を `Scripts/verify-compile-failures.sh` で検証 |
| 未送信の質問 | 読むと `nil` になり、ルーティングが `.escalate` になることを検証 |
| エンコード | 3プリミティブそれぞれの JSON を固定値と突き合わせる |
| デコード | 実 API のレスポンス実物をフィクスチャにする |
| エラー契約 | 回答欠損 / type 不一致 / 未知の Choice 値 / 未知の answer type / 壊れた JSON のそれぞれで、期待する `JevError` が出ることを検証 |
| `Probability` | NaN・範囲外のデコードが `DecodingError` になること |
| リトライ | スタブトランスポートで 429→200、`Retry-After`（秒・HTTP-date・不正値）、最終試行後に待たないこと、キャンセル |
| ルーティング | 0.6 / 0.85 / 帯の両端の**境界値**、`nil` confidence、Noul の全4経路 |
| 外部利用 | `@testable` を使わないテストターゲットを1つ置き、public API だけで組み立てられることを保証する |
| 実 API | `TYPESAFE_API_KEY` がある時だけ走る別スイート。CI では既定で走らせない |

デコードのフィクスチャは実測で得た実物を使う。

```json
{"model":"jev-1.13.0",
 "answers":{"is_urgent":{"type":"noul","noul":0.81},
            "department":{"type":"choice","choice":"billing","confidence":0.83,
                          "probabilities":{"technical":0.11,"sales":0.0,"billing":0.89}}},
 "usage":{"input_tokens":394,"output_tokens":57}}
```

## 未決定事項

- Linux での `URLSession` の挙動は未検証。CI で確認してから対応を確定する
- `legend` のキーがまばらな場合に `ScoreValue.rounded` が何を返すべきか。
  現案は `value` を四捨五入した整数をそのまま返し、`legend` の有無は見ない

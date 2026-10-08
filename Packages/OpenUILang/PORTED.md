# OpenUILang (ported)

A Swift port of `@openuidev/lang-core` from https://github.com/thesysdev/openui at commit
`c4c0c90575facf824d3d8a64daa11947acc8a668`. Licensed by Thesys Inc. under the MIT License (`LICENSE`); the ported
files keep those terms and are not covered by NOOP's own license.

The app uses it for Sana's interactive cards: the model writes an OpenUI Lang program, this package parses,
validates and evaluates it, and `StrandiOS/Coach/CoachGenUIViews.swift` renders the result natively. The component
library and the coach prompt block are in `Strand/Coach/CoachGenUI.swift`.

## What maps to what

| Upstream (`packages/lang-core/src`) | Here |
|---|---|
| `parser/lexer.ts`, `parser/tokens.ts` | `Lexer.swift` |
| `parser/ast.ts`, `parser/types.ts` | `AST.swift`, `Value.swift` |
| `parser/expressions.ts` | `Expressions.swift` (Pratt parser, same precedences) |
| `parser/statements.ts` | `Statements.swift` (statement split, auto-close) |
| `parser/materialize.ts`, `parser/validation.ts` | `Materialize.swift` |
| `parser/parser.ts` | `Parser.swift` (`parse`, `StreamParser` with the same watermark) |
| `parser/builtins.ts` | `Builtins.swift` |
| `parser/prompt.ts` | `Prompt.swift` |
| `runtime/evaluator.ts`, `runtime/evaluate-prop.ts`, `runtime/evaluate-tree.ts`, `runtime/store.ts` | `Evaluator.swift` |
| `library.ts` | `Library.swift` |

`Tests/OpenUILangTests/ParserTests.swift` ports `parser/parser.test.ts`; `RuntimeTests.swift` covers validation,
evaluation, actions, `@Each`, the store and the prompt.

## Differences from upstream

- **Swift-defined props.** Components declare their props with `PropType` (string, number, boolean, literal,
  array, object, component, action, binding, union, record) instead of Zod / JSON Schema. Signatures in the
  prompt are written in the same style upstream generates.
- **No tools.** `Query`, `Mutation`, the query manager, MCP and tool providers are not ported; `Query(` and
  `Mutation(` are reserved and rejected. The prompt omits the Query/Mutation sections.
- **Lenient slots.** A number in a string slot becomes its string, a numeric string in a number slot becomes the
  number, and a single value in an array slot is wrapped. Upstream reports these as type errors; models make
  these slips often and the intent is unambiguous.
- **Prompt wording.** The built-ins line says "derive values from data" (there are no Query results), and the
  Forms section appears whenever bindings are on.
- **Not ported:** `merge.ts` (edits to an existing program), `serialize.ts`, `enrich-errors.ts`,
  `validate-library.ts`, `cloud*.ts`, `reactive.ts` and telemetry.

## Updating

Diff `packages/lang-core/src` between the commit above and the new one, apply the changes to the matching Swift
file, port any new cases from `parser.test.ts`, run `swift test` here, and update the commit hash.

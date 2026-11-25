# Project context: scope, framing, phase, handoff

Moved out of the root CLAUDE.md on 2026-11-25 (WORKER-CONTEXT-DIET): CLAUDE.md loads into every agent on every turn, and these sections are read by the top-level session and by planners, not by workers. CLAUDE.md links here.

## What this project is NOT

This is a decision, not a limitation. Avoid scope drift into these areas:

- **Not a specific migration tool.** Replacing ax3 or haxe-formatter are *validation cases* for the platform, not the goal.
- **Not an automatic cross-language translator.** The platform provides infrastructure for user-written transforms, not magic.
- **Not a native code backend.** If binary emission is needed, integrate LLVM or WebAssembly as writer targets.
- **Not a live-editing incremental parser.** On-demand reparse with caching is in scope; tree-sitter-style continuous background incremental is not.
- **Not a universal language AST.** Common-family ASTs (curly-brace, Lisp, ML) are plugins; a single AST encompassing all languages is physically impossible and not attempted.


## Strategic framing — read this carefully

The project explicitly started from the universal-parser framing, *not* from specific tool replacement. The user's own words (translated): "we cannot see the future; the goal is to be maximally ready, not to waste time writing the same thing again and again". This framing is load-bearing.

**Do not narrow the scope** when reviewing code or suggesting work. Always ask two questions about any decision:

1. Does it solve a concrete validation case (ax3, haxe-formatter, or any future language)?
2. Does it generalize to the next ten formats and languages we haven't thought of yet?

Both must be true. If only (1), the decision is too narrow. If only (2), it's too abstract to ship.


## Architecture at a glance

User grammar (`@:peg` typedef/enum/class with `@:lit`/`@:kw`/`@:infix`/`@:indent`… metadata) → `@:build` macro in five passes (shape analysis → per-plugin strategy annotation → lowering to CoreIR → codegen → runtime assembly) → generated parser/writer classes (Fast: `T → T`, throws; Tolerant: `ParseResult<Node<T>>`) over `anyparse.runtime`. `Build.buildLexicalScan` runs only the base shape and generates the LEXICAL pass (`docs/strategies.md` § Lexical).

Strategies are plugins that own metadata tags and lower grammar nodes into CoreIR; formats are separate plugins describing literals and policies. Full model: `docs/architecture.md`; plugin interfaces: `docs/strategies.md`, `docs/formats.md`.


## Current phase

✅ Phase 0 walking skeleton · ✅ Phase 1 macro foundation · ✅ Phase 2 first macro-generated parser · 🔶 **Phase 3: Haxe grammar + formatter replacement — in progress** · ✅ binary format support (ar archive) · ⬜ Phase 4 AS3 grammar + AS3→Haxe transform · ⬜ Phase 5+ family IRs, cross-family bridge.

Phase deliverables and corpus pass/fail counts go stale fast — the authoritative source is `docs/roadmap.md` and project memory, never this file.


### Session handoff

Starting: read this file, `docs/roadmap.md`, project memory (`~/.claude/projects/-Users-axg-dev-lab-anyparse/memory/MEMORY.md` and linked files); run `haxe test-js.hxml && node bin/test.js` before changing anything.

Ending: leave the project green; update `docs/roadmap.md` on a phase boundary; update project memory with anything load-bearing; do not commit unless asked.


## References this project builds against

- **ax3** (AS3→Haxe converter) — the user maintains a private fork. See project memory.
- **haxe-formatter** — the user's fork at AxGord/haxe-formatter, also the `formatter` haxelib dev path. A reference and a regression corpus, NOT an authority on layout.
- **haxelib `format`** — reference library for binary format parsers; a pattern library for what binary grammars need to express.
- **Haxe compiler** — long-term goal is a Haxe-on-Haxe compiler where anyparse provides the parser/writer foundation.


## License

MIT. See `LICENSE`.


## Parent and curator commands

```sh
node bin/dev.js land <branch>              # the parent's ONLY merge command: merge, rebuild, battery, one verdict
node bin/dev.js base-engine <sha>        # a commit's apq.js, built once and cached (--repo, --cache)
node bin/dev.js parity <base> <tip-engine>   # CLI behaviour diff between two engines; <base> is a commit or an engine
node bin/dev.js probe <area> [--compile] [--record]   # review probe kits under test/probes (<area|kit.json>, --engine)
hxq lint-diff --old A.json --new B.json # blast radius, multiset diff
hxq mutation-verdict <utest-transcript> # KILLED/SURVIVED/… classifier
node bin/dev.js clone-census <label> <t2.json> <t1.json> . [--after …]   # duplicate-code census by family (docs/testing.md)
```

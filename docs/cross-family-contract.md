# Cross-family round-trip contract

This is an architectural invariant of anyparse. It is not a feature — it is a property the core must satisfy. Violations are bugs against the platform, not just against specific grammars.

## The invariant

For any grammar `G_A` projecting into family IR `Family_A`, and any grammar `G_B` projecting into family IR `Family_B`, with a bridge between `Family_A` and `Family_B`:

```
program in language A
  → parse with G_A
  → native AST of language A
  → project onto Family_A IR
  → convert via bridge to Family_B IR
  → project onto native AST of language B
  → write with G_B
  → program in language B
  → parse with G_B
  → project onto Family_B IR
  → bridge back to Family_A IR
  → project back to native AST of language A
  → write with G_A
  → program in language A
```

The final language A program must be **semantically equivalent** to the original. Not byte-identical. Not idiomatic to any particular style. Structurally equivalent — same AST shape, same operators, same bindings, same control flow.

## The canonical test

`CurlyBraceFamilyAst ↔ LispFamilyAst`. Specifically:

```
Haxe source
  → HaxeAst (native)
  → CurlyBraceFamilyAst (project)
  → LispFamilyAst (bridge)
  → ClojureAst (project)
  → Clojure source (write via ClojureFormat)
  → re-parse Clojure → ClojureAst
  → LispFamilyAst (project)
  → CurlyBraceFamilyAst (bridge back)
  → HaxeAst (project back)
  → re-write Haxe source
```

Assertion: the final Haxe AST is structurally equal to the initial Haxe AST (ignoring trivia, since trivia is lossy by design).

## Why this is the right test

Curly-brace and Lisp are the two families with the **most different structural assumptions** that still share semantic fundamentals:

- Curly languages have statement/expression distinction; Lisp treats everything as an expression.
- Curly languages have infix operators with precedence and associativity; Lisp has prefix calls with fixed evaluation order.
- Curly languages have method call syntax `obj.foo(x)` distinct from function call `foo(obj, x)`; Lisp treats both as `(foo obj x)`.
- Curly languages have `for`/`while` loops; Lisp has recursion and higher-order combinators.
- Curly languages have `return` as a statement; Lisp uses tail position.

Every one of these differences is a temptation to put curly-specific primitives into CoreIR. If we catch those temptations by requiring round-trip to a Lisp family IR, CoreIR stays family-agnostic. If we do not, CoreIR accumulates curly assumptions and becomes an IR for "languages that look like C", not a platform for any format.

## Three layers of cross-family conversion

Only the first layer is the architectural invariant. The others are optional and explicitly not guaranteed.

### Layer 1: structural equivalence

Mechanical transformation that preserves semantics without any attempt at idiom. The output may be ugly, non-idiomatic, and verbose, but it is correct:

```haxe
// Haxe input
class Point {
  public var x:Float;
  public var y:Float;
  public function new(x:Float, y:Float) { this.x = x; this.y = y; }
  public function distance(other:Point):Float {
    var dx = this.x - other.x;
    var dy = this.y - other.y;
    return Math.sqrt(dx * dx + dy * dy);
  }
}
```

```clojure
; Layer 1 Clojure output — valid, semantically correct, not idiomatic
(defrecord Point [x y])

(defn point-distance [self other]
  (let [dx (- (:x self) (:x other))
        dy (- (:y self) (:y other))]
    (Math/sqrt (+ (* dx dx) (* dy dy)))))
```

The result is valid Clojure. It compiles and runs. It is not what a Clojure programmer would write by hand (they would use maps, protocols, destructuring), but it preserves every piece of semantic information from the original.

**This is the invariant anyparse guarantees**. If you round-trip through layer 1, you get back what you started with.

### Layer 2: idiomatic conversion

Optional, library-level, not part of core. Recognizes common patterns and rewrites them to target-language idioms:

- `for (var i = 0; i < n; i++)` → `(dotimes [i n] ...)`
- `array.map(x -> f(x))` → `(map f array)`
- `if (obj != null) obj.foo()` → `(when obj (.foo obj))`

Built as a `anyparse.transform` rule library that runs after the family bridge. Each rule is a recognizer plus a rewriter. New rules extend the library but do not break existing grammars.

**Not guaranteed.** The library may or may not have a rule for your specific pattern. The output may mix idiomatic and non-idiomatic constructs. If you want pristine idiom, write your own rules.

### Layer 3: semantic conversion

Out of scope. This is what dedicated transpilers (j2objc, Transcrypt, Haxe's own cross-compilation) do: taking full account of mutable state vs immutability, ownership, effects, and standard library mapping.

**Explicitly not attempted.** The framework provides visitors, queries, and AST manipulation tools so that user code can do layer 3 transformations, but anyparse itself does not ship layer 3 for any language pair.

## What to check before adding a CoreIR primitive

Every time a new primitive is proposed for CoreIR, run it through this check:

1. **Does it have a meaningful semantics in Lisp?**
   If a primitive is `MethodCall(obj, method, args)`, its Lisp projection is just `(method obj args...)` — which is indistinguishable from a regular `Call`. So `MethodCall` is wrong; it should be `Seq([fieldAccess, Lit("("), args, Lit(")")])` in curly and a regular `Call` in Lisp.

2. **Does it encode a choice that belongs in the family IR?**
   Statement-vs-expression distinction is curly-specific. Wrapping things in `Statement(inner)` does not belong in CoreIR — it belongs in `CurlyBraceFamilyAst` as a marker that the family needs to emit semicolons and newlines after.

3. **Is it reversible for writing?**
   The writer walks CoreIR in reverse. If a primitive has no obvious "how do I emit this as text or bytes" counterpart, either the primitive is wrong or it needs an explicit write-side definition.

4. **Can a grammar avoid using it?**
   Primitives should be general. If only one specific grammar uses a primitive, the primitive is probably encoding a detail that should live in that grammar's strategy or format, not in CoreIR.

## Enforcement

When family IRs exist (Phase 5+), the round-trip test runs in CI on every commit. A failing round-trip is a build failure. The fix is either:

- Correcting the grammar's projection onto the family IR.
- Correcting the bridge.
- Removing or generalizing a curly-specific primitive from CoreIR.

In that order of preference. Changes to CoreIR are the most expensive because every strategy and writer must adapt, so we exhaust the other options first.

## Before family IRs exist

Until Phase 5, this contract is a **design-time check**, not a CI check. When reviewing CoreIR design proposals:

- Ask "how would this look in Lisp?"
- Ask "does this encode an assumption about syntax I would lose in a language without that syntax?"
- Prefer primitives that are family-neutral even if they are slightly less convenient for curly grammars.

The goal is to have zero changes to CoreIR when Phase 5 ships — if the design-time discipline worked, the round-trip tests should pass on the first run.

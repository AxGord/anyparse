# Strategies

A **strategy** is a plugin that knows how to turn a piece of grammar into a piece of CoreIR. Strategies are the extensibility point of anyparse: adding a new parsing technique (new operator precedence scheme, new indentation semantics, new binary layout) means writing a new strategy, not modifying the core.

See `architecture.md` for the overall macro pipeline and how strategies fit into it.

## The interface

```haxe
interface Strategy {
  /** A short, stable name. Used in dependency declarations and error messages. */
  var name:String;

  /** Names of strategies that must have annotated before this one runs. */
  var runsAfter:Array<String>;

  /** Names of strategies that must run after this one. */
  var runsBefore:Array<String>;

  /** Which metadata tags this strategy exclusively owns. Conflicts are a registration error. */
  var ownedMeta:Array<String>;

  /** Return true if this strategy applies to the given shape node. */
  function appliesTo(node:ShapeNode):Bool;

  /** Annotate the shape node with this strategy's namespaced slots. No lowering yet. */
  function annotate(node:ShapeNode, ctx:LoweringCtx):Void;

  /**
    Lower the shape node to CoreIR, or return null to let base lowering handle it.
    Called during pass 3.
  **/
  function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR>;

  /** Declarations of what the strategy needs at runtime — context fields, helper methods, cache key contributions. */
  var runtimeContribution:RuntimeContrib;
}

typedef RuntimeContrib = {
  ctxFields:Array<Field>,            // new fields on the Parser context
  helpers:Array<Field>,              // helper methods available to generated code
  cacheKeyContributors:Array<Expr>,  // expressions contributing to the packrat cache key
};
```

## Rules of engagement

### One owner per metadata tag

If two strategies claim `@:lit`, the registration fails at compile time. This is how we catch silent conflicts early. If two strategies need to read the same tag, one of them declares it as `owned` and the other as `reads` (a read-only dependency — not yet implemented, will be added when needed).

### Namespaced annotations

A strategy writes to `node.annotations["strategy-name.field"]`. It never touches a slot owned by another strategy. This means strategies can be developed independently and composed without fear of cross-contamination.

### Lowering is append-only on existing shape

A strategy's `lower` function returns a new `CoreIR` subtree for the node it owns. It does not modify the shape tree. If it returns `null`, base lowering handles the node with default semantics.

### Explicit dependencies, not implicit ordering

`runsAfter` and `runsBefore` declare which other strategies this one needs to see annotated before or after it. A topological sort at registration time produces a deterministic run order. Cycles are a registration error.

### Strategies do not emit Haxe code

Strategies emit CoreIR. Codegen (pass 4) turns CoreIR into `haxe.macro.Expr`. A strategy that directly calls `macro ...` is wrong — it should be emitting CoreIR with `Host` as the escape hatch if nothing else works.

## Planned strategies

### BaseShape

Not a strategy in the plugin sense — it is the pass 1 foundation that every strategy runs on top of. Handles the structural mapping from `haxe.macro.Type` to `ShapeTree`:

| Haxe form | ShapeTree form |
|---|---|
| `enum E { A; B; }` | `Alt(A, B)` |
| `class C { var f1; var f2; }` | `Seq(f1, f2)` |
| `typedef T = { f1, f2 }` | `Seq(f1, f2)` |
| `Array<T>` | `Star(T)` |
| `Null<T>` | `Opt(T)` |
| reference to another `@:peg`-type | `Ref(typeName)` |
| `abstract X(Base)` | `Terminal(Base)` — awaits further annotation |

### Lit

Owns: `@:lit`, `@:lead`, `@:trail`, `@:trailOpt`, `@:wrap`, `@:sep`.

Lowers literal glue around fields into `Lit` nodes in a `Seq`. A field with `@:lead("{")` becomes `Seq([Lit("{"), field])`. A `@:sep(",")` on a `Star` becomes `Star(item, sep=Lit(","))`.

`@:trailOpt(";")` is the optional-on-parse variant of `@:trail`. The parser emits `matchLit` (peek + consume-if-present) instead of `expectLit` (throws on absence); the writer keeps emitting the literal as canonical output. First consumer: `HxDecl.TypedefDecl` for `typedef Foo = T` without trailing `;`. Source-fidelity (preserve presence per input) is a separate slice.

### Re

Owns: `@:re`.

For an `abstract X(String) @:re("pattern")`, emits a `Re("pattern")` terminal. Used for regex-matched primitives: strings, numbers, identifiers, ASCII tokens.

### Kw

Owns: `@:kw`.

Sugar for "keyword with word boundary". Lowers `@:kw("true")` to `Seq([Lit("true"), Not(Re("[A-Za-z0-9_]"))])`. Handles the common bug where `true` matches the start of `trueish`.

### Skip

Owns: `@:skip`, `@:ws`.

Cross-cutting. Does not lower nodes directly. Instead, pushes the active skip regex onto `LoweringCtx.skipStack` when entering a scope, and base lowering inserts `currentSkip` before each `Lit`/`Re` terminal in that scope.

`@:ws` is shorthand for `@:skip('[ \t\n\r]*')`.

### Capture

Owns: `@:capture`, `@:match`.

Implements named captures for context-dependent grammars. `@:capture public var tag:XIdent` stores the matched text in a slot named after the field. `@:match(tag) public var _close:Void` asserts that the current position matches the same text. This is how XML matches `<a>...</a>`.

### Pratt

Owns: `@:infix`, `@:prefix`, `@:op`.

When an enum has constructors with `@:infix(prec, assoc)` and `@:op("...")`, Pratt takes over lowering. It splits constructors into atoms (primary expressions) and operators (with priority tables). It emits a `Host` node containing a Pratt operator-precedence climbing loop, where `parsePrimary()` is generated from the atom constructors via the normal `Alt` strategy.

This is one of only two places where `Host` is used in the base library — because the Pratt loop is genuinely stateful and iterative in a way that does not fit cleanly into PEG combinators.

### Indent

Owns: `@:indent(same)`, `@:indent(block)`, `@:indent(gt)`, `@:indent(suspend)`.

Handles indent-sensitive grammars. Requires runtime state (`indentStack:Array<Int>`) contributed to the Parser context. Wraps `@:indent(block)` fields in `Host` nodes that push and pop the stack with `try/finally` semantics.

The `@:indent(suspend)` variant freezes the indent stack within a scope — needed for Python-style implicit line continuation inside `(...)` groups.

### Binary

Owns: `@:u8`, `@:u16le`, ..., `@:magic`, `@:tag`, `@:tagMask`, `@:fromTag`, `@:lenPrefix`, `@:countPrefix`, `@:count`, `@:decode`, `@:bytes`.

The biggest strategy by metadata count. Lowers binary format primitives into `Bin(BinKind)` nodes, `Switch` nodes for tagged unions, and `Count`/`BytesVar` for length-prefixed structures.

Interacts with `Skip` by overriding it to empty when entering a `@:bin` type (binary formats have no whitespace).

### Recovery (future)

Owns: `@:commit`, `@:recover`.

Activated only in Tolerant mode. Wraps relevant rules in error-recovery logic: on error after a `@:commit`, collects the error and advances to the nearest sync point declared by `@:recover(syncRe)`, then resumes parsing.

Not in Phase 1 or 2. Appears when Tolerant mode becomes a full target.

## Writing a new strategy

High-level procedure:

1. **Pick an owned metadata name**. Check `strategies/` for conflicts. Name should be short and specific to what it does.
2. **Pick dependencies**. If your strategy lowers to primitives that another strategy handles (e.g., `Kw` lowers to `Lit` + `Not`), declare `runsBefore` so you run first.
3. **Implement `appliesTo`**: check for your metadata on the node.
4. **Implement `annotate`**: write into namespaced slots. Do not lower yet.
5. **Implement `lower`**: produce `CoreIR`. If your strategy is purely annotation (like `Skip`), return null and let base lowering handle structural form.
6. **Declare `runtimeContribution`**: if you need a field on the Parser context or a helper method, declare it. Strategies that do not need runtime state return empty arrays.
7. **Register in the strategy registry**: one line in the strategies list.
8. **Write tests**: a small `@:peg` type using your metadata, compile it, assert the generated code behaves correctly.

## Error cases the framework catches at registration

- Two strategies claiming the same `ownedMeta`.
- Cyclic `runsAfter`/`runsBefore` dependencies.
- A strategy declaring `ctxFields` but no `cacheKeyContributors` (packrat integrity).
- A strategy declaring a helper with the same name as another strategy's helper.

These are all compile-time errors and prevent surprising runtime behavior from ambiguous composition.

## Why strategies are in the architecture

Without strategies, everything about grammar handling would live in one giant macro. Adding Pratt-style operators would mean editing the core. Adding indent sensitivity would mean editing the core again. Adding binary would mean editing the core a third time.

With strategies, each of these is a file in `strategies/`. The core macro pipeline is unchanged. Strategies are composed at registration, their order is deterministic, and conflicts fail fast.

This is the same reasoning as compiler passes in LLVM, lints in clippy, Babel plugins, Webpack loaders. It is the correct decomposition for extensible code transformation, and it applies here.

# The typing service

`anyparse.query.TypingService` is the one place a typing question is asked. It is the core a later typer by
specification grows from (the plan: T1 a conformance harness, T2 an ancestor table and a memo of `unify` on pure types,
T3 the `using` order, T4 the cast graph of abstracts, T5 overloads), shaped so that it could become the typer of a
Haxe written in Haxe: answers cached by declaration, signatures apart from bodies, dependencies by declaration, no
global state, one set of declarations shared by every compiler configuration of a project. What it DOES today is only
what its consumers and the harness ask; this note says where each later step plugs in.

## Where it lives and how long

One `SymbolIndex` builds one service (`index.typing`) over its own immutable tables — the files, the name resolver
(`TypeRefIndex`), the inheritance graph (`SubtypeGraph`), the grammar's type syntax and shape — and the service is
dropped with the index. `SymbolIndex.without` builds a new index and so a new service. Nothing is static: the walk and
its hosts are functions of their arguments, and every remembered answer is instance state of the service of one run.

## The API

| part | side | what it answers |
|---|---|---|
| `ancestors` (`AncestorTable`) | signature | a declaration's supertype links (each resolved once), its alias target, what its chain passes to an ancestor's type parameters |
| `unification` (`Unification`) | signature | whether a value of one plain type unifies with another (`tUnification.ml`) |
| `members` (`MemberLookup`) | signature | what a named type declares or inherits, with what declared type, return, visibility, accessor shape; the type a READ of a member carries (`memberReadType`) |
| `structural` (`StructuralTypes`) | signature | unification with an anonymous structure, membership of a builtin structural type (`Iterable`, `Iterator`) |
| `expectations` (`ExpectedTypes`) | body | the type a value is expected to have where it is written, and through it an untyped lambda parameter's |
| `typeWalk` + `TypingHost` | body | the type an expression carries: the walk owns the shapes, a host answers each in its own currency |
| `cache` (`QueryCache`) | — | the remembered answers, one `DeclarationQuery` table per question |

A SIGNATURE question reads declarations only — `FileInfo` / `TypeDeclInfo` / `MemberInfo`, which the index builds from a
declarations-only read (bodies skipped, `BodySkip`). A BODY question walks a parsed tree. The split is what makes a body
edit unable to change a signature answer.

The walk has four hosts, each a consumer of the service: the index host (`NominalTypes`, a type source as written,
resolved where it is written), the call graph's (`CallGraphEdges`, a type source keyed the way the graph keys types), the
operand binder's (`OperandBinder`, what a written type BINDS to, a `TypeNameBinding.Tier`) and the argument typer's
(`ArgumentTypes`). The call graph keeps its own `ExpectedTypes`: it may run with no index, so with no service.

## Cache keys

`DeclarationKey` names the declaration a question is about: the declaring file and the declaration's offset there, plus
the member name for a question about a member of that type (`ofType`, `ofMember`), or both declarations of a question
about two (`ofPair`: does `a` unify with `b`, what does `a`'s chain pass to `b`). It is never a simple name — two
namesakes in two packages, or two types of one module, are two keys — and it never names a configuration: the index
reads every `#if` branch and folds a type declared in several branches into one declaration (`withAlternate`), so one
declaration is one key and every one of a project's compiler configurations asks the same table.

A question may be cached only when its answer is a pure function of its key and the immutable index. Today that is the
four fresh-walk roots of `MemberLookup`: `lacksMember` (`lacksMemberClosure`), `declaredMember`
(`declaredMemberClosure`), `memberTypeSource` (`memberTypeSourceWalk`) and `freeOfExtensionTypes`; and the T2 tables:
`ancestorLinks` and `aliasTargets` (by `ofType`), `ancestorArguments` and `unifies` (by `ofPair`). `memberReadType` is not a
table of its own: its key would carry the receiver's written arguments, and it is composed of two cached answers
(`declaredMember`, `ancestorArguments`) and a substitution. A walk entered with a
caller's own `seen` set is never cached — its answer depends on what that caller already visited — and neither is a
question keyed by a name (`memberGetter`, `supertypesDeclareNone`), whose answer is a union over every declaration of
the name. `DeclarationQuery` boxes each answer so a remembered `null` is not computed again.

## Invalidation

None is needed yet: a run builds its index, and so its service, once. When a mode that edits and re-asks arrives (a
watch mode, a Haxe-in-Haxe server), invalidation plugs in at `DeclarationQuery.answer`: each computation records the
declarations it read (the `ResolvedType`s a closure walk visits are already in hand at each `markSeen`), and an edit to a
file drops the keys of its declarations and every answer that read one of them. A body edit drops body answers only;
a signature answer reads no body.

## The conformance harness (T1)

`tools/TyperConformance.hx` (`haxe tools/typer-conformance.hxml`) asks the typing layers questions the compiler has
answered and scores each answer MATCH (the compiler's), UNKNOWN (declined) or DIFFERENT. The rule is the one every layer
here keeps: the compiler's answer or Unknown, never another one. The UNKNOWN share of an area is its coverage.

- `upstream <clone>` reads a pinned Haxe 4.3.7 checkout — the tests are never copied into this repository. From
  `tests/display`: each test's doc-comment code with its `{-N-}` markers taken out, and its `type`, `position` and
  `usage` assertions asked of the typer (the written-source and the nominal currency apart); every other display
  assertion is counted, unanswered. From `tests/misc`: each `compile-fail` stderr's `$type` warnings (only where
  `$type(` encloses the range) and its top `A should be B` errors (a `... ` line belongs to the chain above it).
- `facts [<configuration>]`, in a project root, compiles the project's oracles (`apqlint.json`) with the facts hook and
  asks the type of every range the compiler gave a value type (`FactsTypeOracle.valueType`), by node kind.

What the harness may not do is make an answer match. It compares two spellings of one type in one spelling (`TypeText`:
qualifiers dropped, either function syntax, structure fields in name order; a nominal through its typedef alias hops) and
refuses to pose a question it cannot place: a display position on a seam between two expressions, a cursor on a
construction's type name (the display answers the constructor), a definition or use whose binding is not a local
declaration or a parameter (the scope-correct part of the reference walk); and, in the facts, a range whose facts are
not the text's own — the body an inlined call spliced there, a copy of an inline body typed in a caller's terms, the
compiler's own code lowered into it (a std call into its target's runtime class), the implicit `this` a bare member read
shares it with, a type the harness cannot expand to the typer's alias or `@:generic` spelling. Each refusal is counted
UNSCORED, never as a match.

A DIFFERENT answer the harness cannot attribute to itself is an engine finding, input for the later steps; the run
groups its `DIFFERENT` lines, and the findings standing on the tree this was written on are kinds, not sites: the
written-source currency leaves out the implicit `Null<>` of an optional declaration (`?x: T`, an `@:optional` field),
a callee's own type parameter reaches a call's answer unsubstituted (`T`), an expression inside a `macro` reification
is typed as code rather than as the `Expr` it is, and the reference walk binds a name a reification pattern captures
(`case macro $i{foo}:`) to the member of that name. T2 closed the first two (below); the kinds left after it are a
typedef written without the arguments it aliases (`RadioButton` for `RadioButton<Void>`), an abstract over another type
read through its `this` (`DiskSystemItemInternal`), a `for` binder whose iterable's element type is a structure, the
inference of a local's type from more than its initializer, and the two reification kinds.

## Where T2–T5 plug in

- **T2 — ancestor table, `unify` memo (done, FU4).** `AncestorTable` (`index.typing.ancestors`): each declaration's
  supertype links resolved once with the arguments they write (`ancestorLinks`, `ofType`), its alias target
  (`aliasTargets`), and what a chain passes to an ancestor's parameters in the start's terms (`argumentsTo`,
  `ancestorArguments`, `ofPair`; `tUnification.ml` `loop … apply_params`, the first link that reaches it). Every
  closure walk of `MemberLookup` follows `links` / `aliasTarget` instead of resolving each link again. On it,
  `MemberLookup.memberReadType`: the type a READ of a member carries — the declaring type's parameters bound through the
  receiver's arguments or the chain, an optional structure field (`MemberInfo.optional`) as `Null<T>`; the index host
  wraps an optional parameter the same way, and a call returning a type parameter has no nominal (inferring what the
  call binds it to is T5). `Unification` (`index.typing.unification`, `unifies`, `ofPair`): `unify` over PLAIN types — a
  class, an interface or an enum with no type parameter, not under `#if`, through plain aliases — `Fits` / `Misfits` by
  the chain, `MayFit` for every other pair. Consumers: `ArgumentTypes.fit` (`plainFit`) and
  `StructuralTypes.memberCouldUnify` (a read-only structure member unifies covariantly, a mutable one by declaration).
  Measured: upstream DIFFERENT 0 before and after; facts DIFFERENT anyparse 5060 / 4998 → 56 / 29 (source / nominal),
  client 1529 / 1349 → 200 / 121, Pony 345 / 332 → 95 / 111; UNKNOWN shares unchanged or lower (client source 36.0 → 35.9 %,
  nominal 23.4 → 23.2 %); the all-rules lint of four trees byte-identical.
- **T3 — the `using` order (next).** One body question, "which static extension does `recv.name` bind", keyed by the file and
  the receiver's declaration, answered in the compiler's order (`fields.ml`: the receiver type's own `@:using` first, then
  the file's `using` lines last to first); `OperandBinder.extensionTier`, `NominalTypes.staticExtensionNominal` and
  `ValueNameBinding.usingTypes` become its consumers.
- **T4 — the cast graph of abstracts.** A table per abstract declaration of its `from` / `to` edges, keyed by
  `DeclarationKey.ofType` (`abstractCast.ml`: the first unequal `from` wins); `ArgumentTypes`' `MayFit` for an abstract
  parameter becomes `Fits` or `Misfits` where the graph decides.
- **T5 — overloads.** Argument types computed once per call site (a body table keyed by the enclosing declaration and the
  site's offset) and an overload chosen over them; a choice that depends on the expected type answers Unknown.
  Consumers: `OperandCallees.selectsItsSignature`, `ArgumentSlots`.

Each step lands as a table in `QueryCache` with its consumers moved onto it, and is measured on the harness: a step
may lower an area's UNKNOWN share and may turn a DIFFERENT into a MATCH or an UNKNOWN, and must add no DIFFERENT.

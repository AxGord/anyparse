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
| `casts` (`AbstractCasts`) | signature | the cast graph of each abstract: its `from` / `to` clauses per `#if` branch and its `@:from` / `@:to` members, each resolved once into a `TypeEnd` |
| `unification` (`Unification`) | signature | whether a value of one type unifies with another (`tUnification.ml`), and whether an argument of one type is accepted where another is expected (`casts`, `abstractCast.ml`) |
| `operators` (`OperatorOverloads`) | signature | the `@:op` overload an abstract selects for a binary operator over two operand types, and the type it yields (`operators.ml`) |
| `members` (`MemberLookup`) | signature | what a named type declares or inherits, with what declared type, return, visibility, accessor shape; the type a READ of a member carries and the declaration writing it (`memberRead`) |
| `structural` (`StructuralTypes`) | signature | unification with an anonymous structure, membership of a builtin structural type (`Iterable`, `Iterator`) |
| `extensions` (`StaticExtensions`) | body | which static extension `recv.name` binds in a file on a receiver of a declaration (`fields.ml`), and what a file's `using` statements bring |
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
about two (`ofPair`: does `a` unify with `b`, what does `a`'s chain pass to `b`), or the file a body question is asked in
with the declaration and member it is about (`ofUse`: what `recv.name` binds there). It is never a simple name — two
namesakes in two packages, or two types of one module, are two keys — and it never names a configuration: the index
reads every `#if` branch and folds a type declared in several branches into one declaration (`withAlternate`), so one
declaration is one key and every one of a project's compiler configurations asks the same table.

A question may be cached only when its answer is a pure function of its key and the immutable index. Today that is the
four fresh-walk roots of `MemberLookup`: `lacksMember` (`lacksMemberClosure`), `declaredMember`
(`declaredMemberClosure`), `memberTypeSource` (`memberTypeSourceWalk`) and `freeOfExtensionTypes`; and the T2 tables:
`ancestorLinks` and `aliasTargets` (by `ofType`), `ancestorArguments` and `unifies` (by `ofPair`); and the T3 table `extensionBindings`
(by `ofUse`), whose answer reads a file's `using` statements and declarations, never a body; and the T4 tables
`castGraphs` (by `ofType`) and `casts` (by `ofPair`, for two declarations — a pair with a core value type on one side is
computed each time, it is a few clauses long). The T4b overload question (`OperatorOverloads.binaryResult`) is no table:
it is keyed by two ends and an operator and walks a few members of one declaration. `memberRead` is not a
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
qualifiers dropped, either function syntax — one unnamed type in parentheses before an arrow groups an argument of an
old-style chain, `(A -> B) -> C -> D` taking two —, structure fields in name order, an optional field's type as the
optional value's, `?a: Int` as `?a: Null<Int>` (4.3.7 prints it so, and the two assign both ways); a nominal through its
typedef alias hops) and refuses to pose a question it cannot place: a display position on a seam between two
expressions, a cursor on a construction's type name (the display answers the constructor), a definition or use whose
binding is not a local declaration or a parameter (the scope-correct part of the reference walk); and, in the facts, a
range whose facts are not the text's own — the body an inlined call spliced there, a copy of an inline body typed in a
caller's terms, the compiler's own code lowered into it (a std call into its target's runtime class), the implicit `this`
a bare member read shares it with, a type the harness cannot expand to the typer's alias or `@:generic` spelling, a
typedef the index cannot follow (declared in several `#if` branches) that every typedef of its name the compiled build
typed aliases to the compiler's type (`TypeFact.targets`). Each refusal is counted UNSCORED, never as a match.

A DIFFERENT answer the harness cannot attribute to itself is an engine finding, input for the later steps; the run
groups its `DIFFERENT` lines, and the findings standing on the tree this was written on are kinds, not sites: the
written-source currency leaves out the implicit `Null<>` of an optional declaration (`?x: T`, an `@:optional` field),
a callee's own type parameter reaches a call's answer unsubstituted (`T`), an expression inside a `macro` reification
is typed as code rather than as the `Expr` it is, and the reference walk binds a name a reification pattern captures
(`case macro $i{foo}:`) to the member of that name. T2 closed the first two (below). FU28 measured the kinds left
after it and closed five: a reference leaving out arguments its declaration gives defaults (`class Box<T = Void>` written
`Box` — not a typedef alias, as first attributed), a bare call of a local function typed by the member it shadows, the
package-blind member walk answering a member written with its type's parameter unsubstituted, an expression inside a
reification typed as code (now Unknown), and — on the facts side — ranges whose facts were not the text's own (the
`this` an abstract's inlined accessor is handed, at the member's name; the code of an inlined body at the call's range;
FU28 below). Left, by size: `@:overload` returns (T5), the compiler's code an inlined call with a default argument leaves
at the call's range with no inline site recorded, and a `Dynamic`-typed std library member a project library declares
with a type.

## Where T2–T5 plug in

- **T2 — ancestor table, `unify` memo (done, FU4).** `AncestorTable` (`index.typing.ancestors`): each declaration's
  supertype links resolved once with the arguments they write (`ancestorLinks`, `ofType`), its alias target
  (`aliasTargets`), and what a chain passes to an ancestor's parameters in the start's terms (`argumentsTo`,
  `ancestorArguments`, `ofPair`; `tUnification.ml` `loop … apply_params`, the first link that reaches it). Every
  closure walk of `MemberLookup` follows `links` / `aliasTarget` instead of resolving each link again. On it,
  `MemberLookup.memberRead` (named `memberReadType` before T4b): the type a READ of a member carries — the declaring type's parameters bound through the
  receiver's arguments or the chain, an optional structure field (`MemberInfo.optional`) as `Null<T>`; the index host
  wraps an optional parameter the same way, and a call returning a type parameter has no nominal (inferring what the
  call binds it to is T5). `Unification` (`index.typing.unification`, `unifies`, `ofPair`): `unify` over PLAIN types — a
  class, an interface or an enum with no type parameter, not under `#if`, through plain aliases — `Fits` / `Misfits` by
  the chain, `MayFit` for every other pair. Consumers: `ArgumentTypes.fit` (`plainFit`) and
  `StructuralTypes.memberCouldUnify` (a read-only structure member unifies covariantly, a mutable one by declaration).
  Measured: upstream DIFFERENT 0 before and after; facts DIFFERENT anyparse 5060 / 4998 → 56 / 29 (source / nominal),
  client 1529 / 1349 → 200 / 121, Pony 345 / 332 → 95 / 111; UNKNOWN shares unchanged or lower (client source 36.0 → 35.9 %,
  nominal 23.4 → 23.2 %); the all-rules lint of four trees byte-identical.
- **T3 — the `using` order (done, FU14).** `StaticExtensions` (`index.typing.extensions`): `binding(fi, receiver, name)`,
  which static extension `recv.name` binds in the file `fi` on a receiver of the declaration `receiver` — keyed by
  `DeclarationKey.ofUse` (file, receiver declaration, name), table `extensionBindings`. The compiler's order of
  `fields.ml` (`type_field`, Haxe 4.3.7), each step compiled first on `--interp` and `-js`: a field of the receiver's type
  binds first (`declarationLacksMember`); then the type extensions (`mt_using`): the receiver type's own `@:using` paths
  (recorded by the index, `TypeDeclInfo.extensionTypesRaw`, read ABSOLUTELY) the last written first, then its
  superclass's whole list, then each interface's (`typeloadFields.ml`'s `inherit_using`, walked over `ancestors.links`), a
  `typedef`'s own then the aliased type's (`aliasTarget`); then the file's `using`s the last first, then the ambient
  `import.hx` chain's, the nearest first. One path brings its module's types the LAST declared first (`filter_classes`), a
  typedef alias as the class it names, module-level functions after them (`usingHosts`). Each candidate's first
  parameter is unified with the receiver (`StructuralTypes.receiverFitsParameter`, now over `unification.unifies` instead
  of a simple-name `isSubtype`), and one that REJECTS it is passed over — into the next type, the next path, from the
  type's `@:using` into the file's. `Unification` decides two more pairs for it: a declaration with no type parameter is
  itself whatever its kind or `#if` (`unify` starts with `a == b`), and a GIVEN type with type parameters against a
  plain wanted one is decided by its chain. Not decided (`null`, the walk ends): a module-level function (no signature in
  the index), a private or default-visibility static (reached from its class only — the key does not see the class), a
  method type parameter (its constraint is not recorded: `<T:Int>(t:T)` passes a `String` over), an abstract or a type
  argument on the parameter (T4/T5), `@:overload` / macro statics, a candidate under `#if` or built by a macro, a guarded
  `using` that may supply one, a module held in several files one of which supplies one, a supertype one `#if` branch of
  the receiver writes that brings one, and no binding at all (the global `haxe.EnumTools` extensions come last).
  Consumers moved onto it: `OperandBinder.extensionTier` / `resolveTier` (`maySupply`), `OperandCallees.extensionParams`,
  `NominalTypes.staticExtensionNominal` (`ChainTypeContext.usings` deleted), `CallGraphImports.staticExtensionsOf`
  (`usingTypes`), `ArgumentValues.affixResolves` (`bindingUsing`); deleted: `ValueNameBinding`'s using walk
  (`usingTypes`, `usingHosts`, `usingDeclarations`, `extensionDeclaration`, `bindingUsing`, `builtAtOrAbove` →
  `AncestorTable.builtAtOrAbove`), `UsingScan.extensionUsings`, `StructuralTypes.extensionReturnNominal`. Measured:
  upstream DIFFERENT 0 before and after; facts DIFFERENT unchanged (anyparse 56 / 29, client 200 / 121, Pony 95 / 111), client
  nominal `Call` 7 UNKNOWN → MATCH; the all-rules lint of four trees byte-identical. Left for later: `PreferStaticExtension`'s
  `UsingScan.usingConflict` asks a hypothetical `using` the rewrite would insert, which this question does not model.
- **T4 — the cast graph of abstracts (done, FU18).** The index records each abstract header's clauses per `#if` branch
  (`TypeDeclInfo.castClauses`: the `from` / `to` types as written, `@:coreType` / `@:transitive`, `@:multiType`; null for
  a branch that declares no abstract and for a clause under `#if`). `AbstractCasts` (`index.typing.casts`, table
  `castGraphs` by `ofType`) resolves them once into `TypeEnd`s — a declaration, a core value type (a top-level
  declaration of a `coreValueTypes` name, or such a name nothing resolves), the dynamic type, `Open` — with the
  `@:from` / `@:to` members (`certain` only for a member of a one-branch declaration not under `#if`); no graph for an
  abstract with type parameters, a `@:multiType` one, one the compiler unifies by hand (`handUnifiedAbstractPaths`:
  `Void`, `EnumValue`, `Class`, `Enum`, `haxe.NotVoid` / `FlatEnum` / `Function` / `Constructible`). `Unification` reads
  every pair as two `TypeEnd`s: the T2 arms for classes, interfaces and enums, core types by `widens` (a core type no
  class, interface or enum takes), and for an abstract on either side `unify_to` / `unify_from` through the clauses, a
  non-transitive abstract's clause allowing no second abstract cast (`get_abstract_context`), every branch agreeing.
  `Unification.casts` (table `casts` by `ofPair`) adds the argument's implicit cast (`do_check_cast`): the members, and
  past them the FIRST clause unequal to the abstract cast to again (`loop2`); a core abstract (`Int`, `Float`, `Bool` —
  `CoreValueTypes.classNames` names `String` as the class) takes the abstract/abstract arm, which tries members only.
  Consumers: `ArgumentTypes.fit` (`castFit`: a core type against a plain name is now decided too),
  `StructuralTypes.receiverFitsParameter` (plain unification: an `@:from`-only parameter passes the receiver over, `Any`
  takes every one) and `memberCouldUnify` (a read-only member through `to` clauses), all through `Unification`;
  `TypedEventConstant` reads `castClauses` instead of re-parsing the declaring file. Each arm compiled first on Haxe
  4.3.7 (`docs/decisions.md`, FU18).
- **T4b — std types for argument fits, `@:op` results, enum-abstract values (done, FU24).** `ArgumentTypes` resolves
  every written type in the run's resolution index where it holds the file writing it (`heldFor`: the std and the
  libraries resolve there; the call graph's own index answers otherwise, and still says which names are core), and a
  field read — bare, off `this`, a static off its own type — carries the type `MemberLookup.memberRead` answers with
  the file of the declaration writing it (`MemberReading.host`). `OperatorOverloads` (`index.typing.operators`,
  `operators.ml`): the overload of a binary operator the left operand's abstract, else the right one's, selects — the
  first in declaration order whose first parameter EQUALS the left operand's type and whose second the right operand
  casts to (`Unification.casts`), mirrored on the right, swapped for a `@:commutative` one — every `#if` branch of the
  abstract agreeing (`CastClauses.span`, `AbstractCasts.branchMembers`); `ArgumentTypes.arithmeticType` asks it past
  core numbers. `AbstractCasts.holdsUntypedValue`: a value written with no type in every branch of an abstract is an
  enum-abstract value, of the abstract (`ArgumentTypes.accessType` asks it; the index host's deep walk does not yet).
  Measured on a client corpus: one false positive loses the call chain whose argument is `a - b` over `UInt` fields; its
  other chains stay, each passing a value of an enum abstract shaped like `openfl.text.TextFormatAlign`, which stays
  untyped — its first branch writes `enum` under `#if` (a split header the index reads as no abstract) and its flash
  branch aliases a std target type the resolution scope does not hold (`flash.text.TextFormatAlign`).
- **FU28 — default type arguments, and what a facts range holds (done).** The index records each type parameter's
  default (`TypeDeclInfo.typeParamDefaults`, through the span-info projection; a type several `#if` branches declare keeps
  a default only where every branch writes it). `AncestorTable.withDefaults` binds the trailing parameters a reference
  leaves out to them, and `AncestorTable.completed` writes them into a written type (4.3.7: `Box` names `Box<Int>` for
  `class Box<T = Int>`, inside `Box` too, as an argument, through an extends link; a default that leaves out its own
  arguments is completed in its own file). The source currency completes a binding's annotation (`NominalTypes.boundType`),
  a member's written type in its host's file (`MemberLookup.memberRead`) and a method's written return
  (`returnSourceOf`); an extends link passes the defaults (`AncestorTable.linkOf`). Unknown where a parameter left out has
  no default (no type the compiler accepts but `Dynamic`), the name may be a type parameter there, a default names a type
  the reading file does not resolve to the same declaration, or a default reaches its own type. Three typer arcs were made
  positive on the way: a bare call `f(x)` is the sibling member's only when `f` binds to a member declaration (a local
  function shadowing it answers Unknown), the package-blind member walk answers no member written with a parameter of
  its type or of the member, and neither currency types an expression inside a reification
  (`TypeResolver.reified`: under a `RefShape.opaqueKinds` node with no `interpolationKinds` node between — the walk
  `Refs` reads `MacroEmit` by). On the compiler side, `CompilerFacts.typeOfExpressionAt` answers a range only when every
  fact typed there is the text's: a local read records the local's name and counts only under it (the `this` an
  abstract's inlined accessor is handed sits at the member's name), a call's receiver only beside a call its own file
  spells at the call's range (an inlined body elsewhere taking the text as its receiver, or the function value a
  memberless call calls), and a local the compiler declares at the range (a `?.` / `??` temporary, an inlined call's
  parameter) only beside a site of the text's own; any other fact there — an inlined body's — makes the range no answer
  instead of the sites left once it is passed over. Measured (source / nominal DIFFERENT): upstream 0 / 0 before and
  after; anyparse 56 / 29 → 0 / 8, a client corpus 200 / 121 → 2 / 1, Pony 95 / 111 → 3 / 8; MATCH counts within
  0.2 % of before on anyparse and the client corpus, Pony −2.2 % (ranges whose facts held an inlined body's code now
  decline).
- **T5 — overloads.** Argument types computed once per call site (a body table keyed by the enclosing declaration and the
  site's offset) and an overload chosen over them; a choice that depends on the expected type answers Unknown.
  Consumers: `OperandCallees.selectsItsSignature`, `ArgumentSlots`.

Each step lands as a table in `QueryCache` with its consumers moved onto it, and is measured on the harness: a step
may lower an area's UNKNOWN share and may turn a DIFFERENT into a MATCH or an UNKNOWN, and must add no DIFFERENT.

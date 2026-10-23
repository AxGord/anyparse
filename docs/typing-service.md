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
| `builds` (`BuildBranches`) | signature | which `#if` branches of a declaration some build the run declares may compile (every branch when the run knows no builds) |
| `ancestors` (`AncestorTable`) | signature | a declaration's supertype links (each resolved once), its alias target, what its chain passes to an ancestor's type parameters |
| `casts` (`AbstractCasts`) | signature | the cast graph of each abstract: its `from` / `to` clauses per `#if` branch and its `@:from` / `@:to` members, each resolved once into a `TypeEnd` |
| `unification` (`Unification`) | signature | whether a value of one type unifies with another (`tUnification.ml`), and whether an argument of one type is accepted where another is expected (`casts`, `abstractCast.ml`) |
| `operators` (`OperatorOverloads`) | signature | the `@:op` overload an abstract selects for a binary operator over two operand types, and the type it yields (`operators.ml`); the read access an index access takes on an abstract (`indexRead`, `abstractCast.ml`) |
| `calls` (`CallSelection`) | signature | the signature a call selects among a member's own and its overloads over the arguments' types, and the type it returns (`callUnification.ml`) |
| `members` (`MemberLookup`) | signature | what a named type declares or inherits, with what declared type, return, visibility, accessor shape; the type a READ of a member carries and the declaration writing it (`memberRead`) |
| `structural` (`StructuralTypes`) | signature | unification with an anonymous structure, membership of a builtin structural type (`Iterable`, `Iterator`) |
| `extensions` (`StaticExtensions`) | body | which static extension `recv.name` binds in a file on a receiver of a declaration (`fields.ml`), what a file's `using` statements bring, what one `using` offers a receiver (`offers`) and whether an access may bind through it (`mayBindThrough`) |
| `expectations` (`ExpectedTypes`) | body | the type a value is expected to have where it is written, and through it an untyped lambda parameter's |
| `inference` (`InferencePolicy`; `Monomorphs`, `TypeTerm`) | body | the language's reading of an inference: a call's type parameters as the cells `Monomorphs` binds, a written type as a `TypeTerm`, the arcs a unification reads a given type through (Haxe's: `HaxeInferencePolicy`) |
| `typeWalk` + `TypingHost` | body | the type an expression carries: the walk owns the shapes, a host answers each in its own currency |
| `cache` (`QueryCache`) | — | the remembered answers, one `DeclarationQuery` table per question |

A SIGNATURE question reads declarations only — `FileInfo` / `TypeDeclInfo` / `MemberInfo`, which the index builds from a
declarations-only read (bodies skipped, `BodySkip`). A BODY question walks a parsed tree. The split is what makes a body
edit unable to change a signature answer.

The walk has four hosts, each a consumer of the service: the index host (`NominalTypes`, a type source as written,
resolved where it is written), the call graph's (`CallGraphEdges`, a type source keyed the way the graph keys types), the
operand binder's (`OperandBinder`, what a written type BINDS to, a `TypeNameBinding.Tier`) and the argument typer's
(`ArgumentTypes`). The call graph keeps its own `ExpectedTypes`: it may run with no index, so with no service. The index
host's arcs over a value composed of others — a construction, an element read by index, an operator, an array or object
literal, an interval's loop element, an enum-abstract value — live in `ComposedValues`, which reads what a literal is
expected to be through `ExpectedTypes` with the index host's own `ExpectationHost`. The index
host's entry points (`expressionTypeSource`, `expressionTypeNominal`) answer two more shapes past the walk, only for the
node asked and never on the way to a receiver or an argument (`ValueDoors`): a local declaration and a type name read as
a value.

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
computed each time, it is a few clauses long). The T5 body table `callArguments` (by `ofSite`: the file, the declaration
enclosing a call site, the site's offset — and the call's text and the file's length, since a `lint --fix` run asks again of
an index built before it rewrote the file) holds what a call hands its callee, each argument typed once with no expected
type; the T5 selection itself is no table: it walks the few signatures of one member over those arguments. The T4b overload question (`OperatorOverloads.binaryResult`) is no table:
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
a signature answer reads no body. The run's builds (`builds`, T6) are read once per index and never change under it: an
answer that read them is one the index's run holds, the way the thirteen configurations already share every key.

## The conformance harness (T1)

`tools/src/dev/TyperConformance.hx` (`node bin/dev.js typer-conformance`, built by `haxe tools/dev.hxml`) asks the typing layers questions the compiler has
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
a bare member read shares it with, the default an inlined call hands a parameter it leaves out (the facts place an inlined
call at the statement around it, so its range holds only that value), a type the harness cannot expand to the typer's alias or `@:generic` spelling, a
typedef the index cannot follow (declared in several `#if` branches) that every typedef of its name the compiled build
typed aliases to the compiler's type (`TypeFact.targets`), the value of an enum a constructor read bare is read off
(`Enum<E>` at `Text`, the text naming no `E`). A `should be` error at an ascription's range — `(e : T)`, a local
declaration — is asked of the value failing the written type, and one with a `... have:` chain under it is not asked: its
own pair is the innermost that failed (an element, a field), and `have` a view of the whole that is not the type's
spelling (a class shown as the structure it was unified as). Each refusal is counted UNSCORED, never as a match.

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
FU28 below). Left, by size after T5 (below) closed the `@:overload` returns: a `Dynamic`-typed std library member a
project library declares with a type, and the code of an inlined body at a call's range (FU32 below took the
inlined-default-argument family out of the scored set and the package-blind namesake return out of the answers).

`--census` says where the UNKNOWN answers come from, without touching the table: it prints after it, and the table
is byte-identical with and without the flag. Each UNKNOWN type answer, in each currency, is walked from the expression
asked through what it is made of — an identifier to its binding, a call to its callee, a member access to its receiver, a
declaration to its initializer — to the first thing the typer could not answer, and rooted there (`UnknownCauses`). The
roots are the three inference forms (`F1-local-monomorph`: a local declared without a type or a local function's
parameter; `F2-inferred-signature`: a member written without its return or field type; `F3-lambda-parameter` and
`F3-literal-or-lambda-value`: a type the expected type gives) and the gaps that need no inference: the doors of the index
host (`type-expression`, `declaration-node`, `string-segment`, `check-type`), `member-not-found`,
`declared-type-not-read`, `pattern-capture`, `loop-element`, `index-access`, `construction`, `operator-result`, `other`.
Lines: `CENSUS <currency> <area> <root> <n>`; `CENSUS-CAUSE <currency> <root> <detail> <n> <samples>`, the walk's own
reason under a root (for `F3-lambda-parameter`, what the callee declares at the lambda's position — not declared on the
receiver type, a method or a class type parameter, a concrete type); per currency `CENSUS-UNKNOWN <currency> <unknown>
<cases> <unknown%>` (the share of the scored answers, as the table counts it) and `CENSUS-TOTAL <currency> <root> <n>
<share of the UNKNOWN>`. The roots of a currency sum to its UNKNOWN answers or the run fails. The roots are an estimate that measures
the typer, never an answer of it: a kind with no rule is rooted at its first unanswered child, a callee parameter naming
a lone capital letter is taken for a class type parameter, and `member-not-found` does not tell a static extension from a
std gap. Readings: `docs/journal/testing-log.md`.

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
  `AncestorTable.builtAtOrAbove`), `UsingScan.extensionUsings`, `StructuralTypes.extensionReturnNominal`. Later consumers: `UsingSites` (`anyparse.check`), the one answer to whether a `using` takes part in an access — `offers` is `pathStep` asked of one path whatever else is in scope, `mayBindThrough` the binding when the walk proves one and `offers` when it does not — read by `unused-import`, `redundant-import`, `hoist-common-import` and the move carry in place of a text scan by method name. Measured:
  upstream DIFFERENT 0 before and after; facts DIFFERENT unchanged (anyparse 56 / 29, client 200 / 121, Pony 95 / 111), client
  nominal `Call` 7 UNKNOWN → MATCH; the all-rules lint of four trees byte-identical. Left for later: `PreferStaticExtension`'s
  `UsingScan.usingConflict` asks a hypothetical `using` the rewrite would insert, which this question does not model.
- **T4 — the cast graph of abstracts (done, FU18).** The index records each abstract header's clauses per `#if` branch
  (`TypeDeclInfo.castClauses`, since T6 `DeclBranch.clauses`: the `from` / `to` types as written, `@:coreType` /
  `@:transitive`, `@:multiType`; null for a branch that declares no abstract and for a clause under `#if`). `AbstractCasts` (`index.typing.casts`, table
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
  `TypedEventConstant` reads the clauses (since T6 `AbstractCasts.clausesOf`) instead of re-parsing the declaring file.
  Each arm compiled first on Haxe 4.3.7 (`docs/decisions.md`, FU18).
- **T4b — std types for argument fits, `@:op` results, enum-abstract values (done, FU24).** `ArgumentTypes` resolves
  every written type in the run's resolution index where it holds the file writing it (`heldFor`: the std and the
  libraries resolve there; the call graph's own index answers otherwise, and still says which names are core), and a
  field read — bare, off `this`, a static off its own type — carries the type `MemberLookup.memberRead` answers with
  the file of the declaration writing it (`MemberReading.host`). `OperatorOverloads` (`index.typing.operators`,
  `operators.ml`): the overload of a binary operator the left operand's abstract, else the right one's, selects — the
  first in declaration order whose first parameter EQUALS the left operand's type and whose second the right operand
  casts to (`Unification.casts`), mirrored on the right, swapped for a `@:commutative` one — every `#if` branch of the
  abstract agreeing (the branch's range, since T6 `DeclBranch.span`; `AbstractCasts.branchMembers`);
  `ArgumentTypes.arithmeticType` asks it past core numbers. `AbstractCasts.holdsUntypedValue`: a value written with no type in every branch of an abstract is an
  enum-abstract value, of the abstract (`ArgumentTypes.accessType` asks it, and since T7c the index host, `ComposedValues.enumAbstractValue`).
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
- **T5 — overloads (steps 1–3 done, FU25).** The index records each function's signatures (`MemberInfo.signatures`: its own, then
  each `@:overload` annotation's function in written order; the return types read off the span info,
  `SpanTypeInfo.returnTypeSources`, never a type parameter's bound beside them). `CallSelection` (`index.typing.calls`,
  `callUnification.ml`): whether a call compiles against a signature is the compiler's greedy path over `Unification.casts`
  per argument (`ArgumentSlots.compiles`), the own signature and then the annotations are tried in order and the first
  that compiles binds (an `overload` static: the one compiling), a candidate that may compile binds when it is the last one
  open (the code compiles), and a choice left open answers the return every open candidate agrees on. Arguments are typed
  ONCE with no expected type (`CallArgument`; the body table above): a lambda or a literal the expected type types is
  untyped, so a choice that depends on it answers Unknown. Consumers: the index host's call arms (`CallReturns`: a bare
  call through the enclosing declaration, a static call through the declaration its file writes, a value's call through
  every declaration of its type's name agreeing, the chain's arguments bound by `AncestorTable.boundType`), the name walk
  (`MemberLookup.returnNominalWalk` refuses an overloaded member and a supertype declaring the member with a return it
  cannot name: the superclass chain is where the compiler finds it, before the interfaces), `ArgumentValues` (an
  `@:overload` callee's body parameters are bound only when its own signature is selected: the arguments reach the body by
  position), `OperandCallees` (a lambda typed by the signature the arguments' count selects). Measured (source / nominal
  DIFFERENT; UNKNOWN share): upstream 0 / 0 before and after (69.4 / 68.2 %); anyparse 0 / 8 → 3 / 3 (44.0 / 33.7 → 34.4 /
  33.7 %), a client corpus 2 / 1 → 2 / 1 (35.8 / 23.0 → 28.2 / 22.7 %), Pony 3 / 8 → 3 / 4 (33.3 / 26.4 → 27.9 / 26.2 %).
  The `@:overload` families are MATCH (`readFileSync` 5, `Socket.on` 4 — the latter the superclass-first walk, not an
  overload); anyparse's three new source DIFFERENT are the inlined-default-argument facts family the nominal currency
  already showed. MATCH lost: one (an object-literal argument, typed by the expected type); gained: source 49032 /
  7376 / 603, nominal 25 / 213 / 24 (anyparse / client / Pony); the all-rules lint of four trees and the thread-safety
  scores byte-identical.
  Step 2, method type parameters (FU25 S2): a parameter written as the signature's type parameter takes any value or,
  bounded, one unifying with its bounds (`CallSignature.typeParamConstraints`), and the call's return names the type the
  arguments bind it to (`TypeEnd.Param`; a declaration by its module path); Unknown for two bindings not known to be
  one, an untyped or a `Null<…>` argument; `MemberInfo.returnSource` is read off the span info, never a bound. Measured:
  tables unchanged, source MATCH +28 on the client corpus (+1 anyparse).
  Step 3, generic abstracts (FU25 S3): a generic abstract written with type arguments, or aliased by a plain `typedef`
  with them, is an end of its own (`TypeEnd.Applied`) whose clauses read the arguments for its type parameters
  (`AbstractCasts.appliedGraph`; invariant otherwise). Measured: tables and MATCH counts unchanged on all four trees.
  Step 4, typing by the declared builds, is T6.
- **FU32 — three small items (done).** A function's written return is read off the span info by EVERY reader
  (`CallGraphNames.returnSourceOf(fn, returns)` over `SpanTypeInfo.returnTypeSources`; the call graph's nodes, its
  per-declaration and `@:overload` reads, the lock-alias bounds, the operand binder): the query-tree reader took a type
  parameter's bound for the return of a local function or a lambda written with none. The walk by simple name
  (`MemberLookup.receiverDeclarationsOf`, read by `returnNominalWalk` and the source currency's `returnSourceOf`) asks
  the member a declaration of the name INHERITS beside the ones declaring it (a `Socket` inheriting `write` beside a
  namesake declaring `write(): Void`), all agreeing or Unknown, `CallReturns.selectedReturn` deciding where the
  arguments exclude a namesake. The harness leaves unscored an inlined call leaving out an argument of the type its
  range holds (`leavesAnInlinedArgumentOut`). Measured (source / nominal DIFFERENT; UNKNOWN share): upstream 0 / 0
  before and after (69.4 / 68.2 %); anyparse 3 / 3 → 0 / 0 (34.4 / 33.7 %, three sites unscored), a client corpus
  2 / 1 → 2 / 1 (28.2 / 22.7 %; four MATCH per currency now Unknown, `_std` copies disagreeing on an inherited return
  written with none), Pony 3 / 4 → 2 / 3 (27.9 / 26.2 %; `socket.write` a MATCH).

- **T6 — typing by the declared builds (done, FU31).** The index keeps one record per `#if` branch of every declaration
  (`TypeDeclInfo.branches`, `DeclBranch`: the kind the branch writes, its range, an abstract's header clauses), so a
  declaration whose branches are of different kinds — an abstract in one build, a `typedef` to a target type in another
  — keeps its abstract branches' clauses. `BuildBranches` (`index.typing.builds`) answers which branches some build the
  run declares may compile (`of`): `ReachLiveness.live` over the builds the host probes (`SymbolIndexHost.reachBuilds`,
  the compiler oracle's configurations declared complete), read once per index and only for a declaration with more
  than one branch; every branch when no build is known — under `--no-oracle` unless an oracle run stored the builds of the
  very same compile input (`ReachBuildsCache`, `docs/cli-query-tool.md`), since a configuration's define lists cannot
  show that no build sets a define (`docs/decisions.md`, FU31) — and when no build compiles any. Consumers:
  `AbstractCasts.clausesOf` (the clauses of those branches, null when one is no abstract; also `TypedEventConstant`'s),
  `branchMembers` (so `holdsUntypedValue` and `OperatorOverloads`) and the cast graph (clauses and conversion members
  of those branches only). The split header `#if … enum #else @:enum #end abstract` needed nothing: it projects as a
  conditional followed by a plain abstract node, whose clauses the index already read. Measured: the all-rules lint of
  four trees and the three `--no-oracle` thread-safety scores byte-identical (nothing is known there); an oracle-enabled
  thread-safety run on a client corpus loses exactly its one targeted false positive (a constructor reached with an
  enum-abstract value whose library declaration aliases a target type under `#else`: 161 → 160 reported, FP 4 → 3,
  recall 102/102). The harness builds its
  index with no builds known, so its tables are unchanged: source / nominal DIFFERENT upstream 0 / 0, anyparse 3 / 3, a
  client corpus 2 / 1, Pony 3 / 4, every per-case list byte-identical.
- **T7-doors — what an expression asked as a value of its own carries, with no inference (done).** Four of the
  census's roots needed no monomorph. The walk carries two more shapes for every host: a text segment of an interpolated
  string is the string literal's type (`RefShape.stringInterpTextKind`), an ascription `(e : T)` the type it writes
  (`TypingHost.ascribed`; the index host and the argument typer read it off `TypeInfoProvider.castTargetSources`, handed
  in as `ChainTypeContext.castTargetSources`, the other hosts type none). Past the walk the index host's entry points
  answer the node asked (`ValueDoors`): a local declaration the type a read of it carries — its written type, else its
  initializer's (none for one binding several values); a type name read as a value `Class<T>` / `Enum<T>`
  (`RefShape.typeValueTypeNames`), only where the name binds none of the values 4.3.7 looks it up as first (`typer.ml`
  `type_ident_raise`: a local, a member of the enclosing type or one it inherits, a module-level field, a constructor or
  value of a type of the module, what an import or a `using` may bring — `ValueNameBinding.mayImportValueBesideType`,
  which reads an import spelling the name as the type it names rather than as a possible static — and a constructor or
  value ANY type of the index hosts, which an expected type resolves before a type, imported or not:
  `ValueNameBinding.hostsOfValue`) and names one declaration with no type parameter. An integer literal is the integer
  type only spelled as one — decimal digits within `CoreValueTypes.integerMax`, or `hexLiteralPrefix` and hex digits;
  4.3.7 types `3000000000` as `Float`, `1i64` as `haxe.Int64`, `1u32` as `UInt` — and no answer otherwise. Not
  answered: an abstract read as a value (`Abstract<T>`, which the facts never record), a generic type, a local
  function's declaration (a function type the walk does not spell), a name the index resolves to several
  declarations (the std's per-target `_std` copies of `Std`, `sys.FileSystem`) or that an unindexed import may bring.
  Measured (UNKNOWN share source / nominal, each currency's DIFFERENT, the base re-run on the same copy): anyparse 34.4 /
  33.7 → 14.7 / 14.1 %, DIFFERENT 0 / 0; upstream 69.4 / 68.2 → 60.2 / 59.0 %, 0 / 0; Pony 27.8 / 26.1 → 21.4 / 19.8 %,
  2 / 3 unchanged; a client corpus 28.2 / 23.3 → 21.3 / 16.5 %, 14 / 13 → 2 / 1 (the integer literals past the range);
  no MATCH lost and no DIFFERENT added on any of the four; the all-rules lint of four trees and the three thread-safety
  scores byte-identical.
- **T7c — values composed of others, with no monomorph (done).** The walk gains two arcs every host may answer
  (`TypingHost.contextual`: an array or object literal, a conditional — a value whose type depends on what its position
  expects; `element` now handed the index access itself) and carries every operator a core value type takes
  (`RefShape.booleanOperatorKinds`, the compound assignments, the logical not). The rules over core value types are ONE
  shared function (`TypingService.coreOperatorType`, `compoundKeepsTarget`), the argument typer's arithmetic reading it
  too. The index host's arcs live in `ComposedValues`: a construction is the type it writes, the trailing arguments it
  leaves out their defaults (`new Two<Int>()` of `Two<A, B = Item>` is `Two<Int, Item>`); a generic one written with no
  argument is a monomorph the code binds later (`new Box(item)`, `new Def()` of `Def<T = Item>` too: Unknown); an index access reads an array's element or the
  read access an abstract takes (`OperatorOverloads.indexRead`, `abstractCast.ml` `find_array_read_access`: the first
  instance `@:arrayAccess` / `@:op([])` member taking the key, the only one when one is declared); an operator over core
  value types is the language's own (`Int + Float` is `Float`, `s + 1` `String`, `n + 1` of a `Null<Int>` `Int`, a
  comparison `Bool`, `n += 1` of a `Null<Int>` `Null<Int>`), over an abstract what its overload yields (Unknown where an
  overload of the kind sits under `#if`: the compiler tries them in source order, the index lists those last); the binder of a
  loop over an interval of two integers is the integer type; an enum-abstract value read off its type is of the abstract
  (`AbstractCasts.holdsUntypedValue`). A literal where nothing is expected of it (a local written with no type, a loop's
  iterable, a receiver, a part of such a literal) is of its parts' types (`unify_min` where they agree: one type, or
  core numbers widening to the real one, a nullable one making it nullable: `[n, 1]` of a `Null<Int>` is
  `Array<Null<Int>>`); where a type is expected (`ExpectedTypes` with the index host's
  `ExpectationHost`: a declaration's annotation, the parameter a call's selected signature binds the argument to —
  `CallReturns.selectedParameter`, `CallSelection.parameterRun` —, an array's element, a structure's field), the type
  4.3.7 prints: `Array<Dynamic>` under `Dynamic` (a map literal refused: a `haxe.ds.Map`), the expected array type, and against a structure of plain fields the
  fields the literal writes, each of its value's type where `type_eq` keeps it and the field's where the compiler casts
  (a written optional field's `Null<T>`, a value of a `T` that may be null already — a class's, an enum's, a
  structure's — keeping its own, an abstract's Unknown; a literal's for a `Dynamic` field `Dynamic`), plus the optional ones it
  leaves out. `[]` and `null` stay Unknown (T7b). The index host peels parentheses, and
  `MemberLookup.memberRead` reads only the declarations of a member some build compiles (`BuildBranches.declarations`),
  answering where they agree. The harness leaves unscored a `should be` error at an operator's range (an operand's) and
  an operator the typer takes with an `inline` overload, or that no overload decides while an operand's type declares an
  inline one (its spliced body's facts). The shapes no census tree holds live in a probe corpus checked as a gate
  (`dev typer-conformance probes`, `tools/typer-facts/`: one project per directory, DIFFERENT 0 or exit 1). Not answered: a `Map`
  read (`Map.get` writes no return), a field access on a receiver that is no path (`[1, 2].length`), a conditional
  something is expected of, an argument of an overloaded or a generic callee. Measured on the base tree (UNKNOWN share
  source / nominal; roots source construction / index / operator / literal): anyparse 14.7 / 14.1 → 12.9 / 13.1 %,
  4510 / 4756 / 2564 / 4791 → 40 / 390 / 122 / 2593; upstream 60.2 / 59.0 → 57.9 / 57.3 %; Pony 21.4 / 19.8 → 19.3 /
  18.4 %; a client corpus 21.3 / 16.5 → 16.8 / 15.5 %, 4556 / 2334 / 1384 / 2100 → 95 / 0 / 159 / 1886; DIFFERENT 0 / 0,
  0 / 0, 2 / 3, 2 / 1 unchanged, no MATCH lost on any of the four.
- **T7a — monomorphs of a call's type parameters; a lambda's parameter (done).** The inference core, apart from the
  language. `TypeTerm` (the cast graph's `TypeEnd` moved beside it) reads a written type as its head's end applied to its
  arguments' terms, a variable (`Mono`) or a type it does not take apart (`Opaque`). `Monomorphs` holds the cells of ONE
  inference — an instance per call, nothing static: the first unification meeting a cell free binds it (`link`), a second
  binding to a type not known to be that one poisons it, a free or poisoned cell answers nothing, two cells merge
  (union-find, paths compressed) and a binding naming its own cell poisons it; `unify` meets a wanted type argument by
  argument where the heads agree and asks the language to read a given type of another head as one of the wanted head.
  `InferencePolicy` is that seam (`TypingService.inference`). Haxe's (`HaxeInferencePolicy`): a call's cells are its
  signature's type parameters (`attempt_call`); a head resolves where it is written, a std type each target's `_std`
  re-declares as its first copy (`TypeRefIndex.oneDeclaration`); the arcs are the nullable wrapper (transparent, a cell
  taking it whole), the builtin `Iterable` (a std container's element, `iterationElementTypeParams`, or what a class's own
  `iterator()` yields, `StructuralTypes.iteratorElement`) and a supertype of a type with no type parameter
  (`AncestorTable.argumentsTo`). The first consumer is the index host's `parameter` arc (`LambdaParameters`): a lambda's
  parameter written with no type is the parameter of the function type the lambda is expected to be
  (`ExpectedTypes.lambdaParamTypes` over `ComposedValues`' expectations) — a declaration's type, a structure field's, an
  array's element, the parameter a call binds the lambda to (`CallReturns.selectedParameter`: the receiver's written
  arguments binding its type's parameters, the arguments before the lambda its signature's own, left to right,
  `unify_call_args`) and a static extension's, the receiver bound first (`CallReturns.extensionParameter` over
  `StaticExtensions.binding`). Declarations of a callee agree when they spell one type (`TypeSyntax.spellsAs`: `T -> Bool`
  and `(item: T) -> Bool`). Unknown: a part naming a cell no argument before the lambda binds (`Expectation.unbound` — the
  lambda's body may bind it), a cell two arguments bind to types not known to be one, a parameter expected to be `Dynamic`
  (a monomorph does not bind to it; its uses shape it), an argument before the lambda the walk does not type, a parameter
  written `?x` or with a default value (a `Null<T>`), and a type read in another file where a name it spells resolves
  otherwise in the lambda's (`TypeRefIndex.readsAlike`, checked on the callee's written parameter, on what a chain passes
  and on what an arc reads from a third file; a caller's namesake would take the type's place). A cell does not bind to
  the dynamic type, at any depth (`link` binds nothing there), and a method's type parameter shadows its declaring type's
  of the name (`AncestorTable.boundType`). A receiver or an argument binds a type parameter only with a type the lambda's file
  writes (`CallReturns.writtenType`: a member read carries its declaring file's text). On the way
  the T3 walk proves `using Lambda` on a std container (`satisfiesIterable` over the first copy, an `iterator()` return
  followed by its written path). Measured (`F3-lambda-parameter`; UNKNOWN share; DIFFERENT; source / nominal):
  anyparse 12 510 / 12 510 → 4 417 / 5 610, 13.0 / 13.2 → 11.6 / 11.9 %, 1 / 1 unchanged; Pony 26 / 26 → 21 / 21,
  19.3 / 18.4 → 19.2 / 18.4 %, 2 / 3 unchanged; upstream unchanged (57.9 / 57.3 %, 0 / 0); the probe corpus DIFFERENT
  0. Per case on one tree, the base engine against the slice's: no MATCH lost, no DIFFERENT added (anyparse +14 151 MATCH,
  Pony +12). The all-rules lint of four trees moves only where a lambda's parameter is now typed (a
  `prefer-static-extension` message naming a resolved receiver, two `simplify-negated-compound` findings over an
  element's `Int` fields); the three thread-safety scores are byte-identical.
Each step lands as a table in `QueryCache` with its consumers moved onto it, and is measured on the harness: a step
may lower an area's UNKNOWN share and may turn a DIFFERENT into a MATCH or an UNKNOWN, and must add no DIFFERENT.

package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.BooleanLogic.BooleanLogicSupport;

/**
 * Plugin contract for a grammar that the query engine can operate on.
 *
 * The engine sees the AST exclusively through this interface: parse a
 * source string, get a `QueryNode` tree, walk it. The engine never
 * references grammar-specific types — adding a new language is a
 * matter of writing a `GrammarPlugin` implementation in that grammar's
 * package, never touching engine code.
 */
@:nullSafety(Strict)
interface GrammarPlugin {

	/** Short name used by `--lang`. */
	public function langName(): String;

	/**
	 * Parse `source` and return a generic node tree. The plugin is
	 * responsible for choosing kind names and name slots — see
	 * `QueryNode` for the contract.
	 *
	 * Plugins may throw on parse failure; callers handle the
	 * exception. The engine itself never catches.
	 */
	public function parseFile(source: String): QueryNode;

	/**
	 * Parse a `apq search` pattern — language source extended with
	 * `$X` / `$_` metavariables.
	 *
	 * The plugin is free to substitute the metavariable token before
	 * invoking the grammar parser and to wrap the pattern in synthetic
	 * decl/stmt scaffolding so the grammar accepts it; the returned
	 * `Pattern.root` is the user's pattern subtree with all metavar
	 * leaves reclassified to `kind='Metavar'`. See `Pattern` and the
	 * pattern-syntax section of `docs/cli-query-tool.md`.
	 *
	 * Plugins throw on parse failure across every try-fallback attempt;
	 * the CLI catches and surfaces the most-informative error.
	 */
	public function parsePattern(source: String): Pattern;

	/**
	 * Declare which `QueryNode.kind` values the `Refs` walker should
	 * treat as identifier references and binding-declaration hosts.
	 * Plugin-supplied so the walker stays language-agnostic.
	 *
	 * See `docs/cli-query-tool.md` (`apq refs`) for the user-facing
	 * contract and `RefShape` for field semantics.
	 */
	public function refShape(): RefShape;

	/**
	 * Declare which `QueryNode.kind` values the `Meta` walker should
	 * treat as annotation nodes and which kinds are declaration hosts
	 * an annotation can attach to. Plugin-supplied so the walker stays
	 * language-agnostic.
	 *
	 * See `docs/cli-query-tool.md` (`apq meta`) for the user-facing
	 * contract and `MetaShape` for field semantics.
	 */
	public function metaShape(): MetaShape;

	/**
	 * Kind-equivalence relation for `apq ast --select`: groups
	 * `QueryNode.kind` values a `--select <Kind>` should treat as one, so
	 * a selector matches the grammar's wrapper-shaped variants of a decl.
	 * For Haxe this folds the `final` wrappers — `ClassDecl ≡ ClassForm`
	 * (a `final class`'s named inner node) and `FnMember ≡
	 * FinalModifiedMember` (a `final` method) — so `--select ClassDecl` /
	 * `--select FnMember` cover final declarations too. Deliberately
	 * SEPARATE from the search-only `SEARCH_KIND_EQUIVALENCE`: `--select`
	 * keeps its precise per-position kinds (`VarMember` ≠ `VarStmt`), only
	 * the final-wrapper folding is added. A plugin with no wrapper shapes
	 * returns an empty relation (every kind equivalent only to itself).
	 */
	public function selectKindEquivalence(): KindEquivalence;

	/**
	 * Parse `source` like `parseFile`, but additionally surface
	 * type-position references (field/var type annotations, enum-ctor
	 * parameter types, …) as addressable nodes. `parseFile` deliberately
	 * drops these to keep the tree lean for `ast`/`search`/`refs`/`meta`;
	 * this parallel projection is consumed ONLY by the `uses` walker, so
	 * those four consumers stay byte-identical by construction.
	 *
	 * See `docs/cli-query-tool.md` (`apq uses`) and `TypeRefShape`.
	 */
	public function parseFileTypeRefs(source: String): QueryNode;

	/**
	 * Declare which `QueryNode.kind` values the `Uses` walker should
	 * treat as type references. Plugin-supplied so the walker stays
	 * language-agnostic. Only meaningful on a tree produced by
	 * `parseFileTypeRefs`.
	 */
	public function typeRefShape(): TypeRefShape;

	/**
	 * Optional: parse `source` with the grammar's pretty-printer-aware
	 * pipeline (the format that preserves comments / blank lines where
	 * available) and emit the formatted source back. Used by `apq ast
	 * --writer-output` for fast writer-bug iteration without round-trip
	 * through the project's test runner.
	 *
	 * Return `null` when the grammar plugin has no writer wired up — the
	 * CLI surfaces a "no writer for lang X" error.
	 *
	 * `optsJson` is an optional, language-defined JSON config string
	 * driving writer options (e.g. an `hxformat.json`-shaped payload for
	 * the Haxe plugin). `null` → plugin uses its built-in defaults; non-
	 * null → plugin parses and applies. Plugins that don't recognise the
	 * format may ignore the argument (the CLI threads `.hxtest` section-1
	 * here so a single fixture reproduces the corpus harness's writer
	 * settings without manually rebuilding options).
	 *
	 * Plugins may throw on parse failure; callers handle the exception.
	 */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String>;

	/**
	 * Optional: parse `source` with the plain (non-trivia) parser and
	 * emit via the plain writer. Drops comments and source-layout
	 * newlines — flattens to the writer's canonical form. Used by `apq
	 * ast --writer-output-plain` and by `apq writer-equals --plain`
	 * because this is what unit tests like
	 * `HxModuleWriter.write(HaxeModuleParser.parse(src))` actually see.
	 *
	 * The trivia pipeline (`writeRoundTrip`) and the plain pipeline emit
	 * different bytes on the same input — unit-test expected strings
	 * MUST be probed via the plain entry. Return `null` when the
	 * grammar plugin has no plain writer (binary grammars, plugins with
	 * a single unified pipeline).
	 *
	 * `optsJson` follows the same convention as `writeRoundTrip` — a
	 * language-defined JSON config or `null` for defaults.
	 *
	 * Plugins may throw on parse failure; callers handle the exception.
	 */
	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String>;

	/**
	 * Optional: strict trivia-mode parse used by `apq recon` for corpus
	 * skip-parse sweeps. Returns `true` on successful parse; throws
	 * `ParseError` (or other `Exception`) on parse failure so the caller
	 * can cluster by error locus; returns `false` when the plugin has no
	 * trivia parser wired up (CLI surfaces a `no recon parser for lang X`
	 * and exits).
	 *
	 * The trivia pipeline preserves comments / blank lines and matches
	 * the surface accepted by the writer's round-trip path, so a recon
	 * run mirrors what the corpus harness sees on each fixture.
	 */
	public function reconParse(source: String): Bool;

	/**
	 * Optional: the grammar's naming-convention capability, consumed by the
	 * `naming` analysis check. Return null when the grammar has no naming
	 * concept (binary formats) — the check then no-ops for it, mirroring the
	 * optional writer methods above.
	 */
	public function namingSupport(): Null<NamingSupport>;

	/**
	 * Optional: the grammar's adjacent-string-literal folding capability, consumed
	 * by the `fold-adjacent-string-literals` check. Null when the grammar has no
	 * string-concatenation concept — the check then no-ops, like `namingSupport`.
	 */
	public function stringFoldSupport(): Null<StringFoldSupport>;

	/**
	 * The maximum cyclomatic complexity a function may have before the
	 * `complexity` check flags it, for the file at `path` — sourced from a
	 * project config (e.g. a `checkstyle.json`) when present, else null so the
	 * check keeps its built-in default. Grammars without such a config return null.
	 */
	public function maxComplexity(path: String): Null<Int>;

	/**
	 * Optional: the grammar's control-flow capability, consumed by the
	 * `dead-code` check. Null when the grammar has no statement / block concept
	 * (binary formats) — the check then no-ops, like `stringFoldSupport`.
	 */
	public function controlFlowSupport(): Null<ControlFlowSupport>;

	/**
	 * Optional: the grammar's boolean-expression simplification capability,
	 * consumed by the `simplify-boolean-ternary` check. Null when the grammar has
	 * no boolean-ternary concept — the check then no-ops, like the other optional
	 * support methods above.
	 */
	public function booleanLogicSupport(): Null<BooleanLogicSupport>;

	/**
	 * Optional: the extension-method names a `using <modulePath>` brings into
	 * scope, for module paths the grammar knows from its standard library. The
	 * `unused-import` check uses this to verify that a `using` whose bound name is
	 * never referenced directly is still live via an extension call. Return null
	 * for an unknown module path (the check then leaves that `using` an
	 * unverifiable advisory) and for a grammar with no `using` concept.
	 */
	public function knownExtensionMethods(modulePath: String): Null<Array<String>>;

	/**
	 * Lint-check option overrides discovered from the grammar's native config
	 * near `path` (Haxe: `checkstyle.json`), or null when the grammar has no such
	 * config or none is found. The neutral counterpart of `maxComplexity` for the
	 * checks wired to honour a project's existing checkstyle config.
	 */
	public function checkOverrides(path: String): Null<CheckOverrides>;

}

/**
 * Plugin-declared contract for `apq refs`. The walker reads these
 * slots and never inspects grammar-specific node types.
 *
 * `identKind` is the `QueryNode.kind` value the plugin produces for a
 * bare identifier reference (e.g. `'IdentExpr'` for Haxe). Each such
 * node contributes its `name` slot as a candidate reference.
 *
 * `declHostKinds` is the set of node kinds whose own `name` slot is a
 * binding declaration — variables, functions, parameters, types. The
 * walker emits each matching node as a `decl` hit. Decl-host detection
 * takes precedence over identifier detection when a kind appears in
 * both sets.
 *
 * `scopeKinds` is the set of node kinds that introduce a fresh lexical
 * scope (function body, block, for-loop, class body, …). The walker
 * pushes a new frame on entering one of these and pops on exit;
 * declarations inside the frame shadow same-named bindings in
 * enclosing frames. A kind can simultaneously be a scope-introducer,
 * a decl-host, and an ident — the three roles are orthogonal.
 *
 * `writeParentKinds` is the set of node kinds whose first positional
 * child, when an `identKind` node, is a write target rather than a
 * read. The walker reclassifies that child's hit from `Read` to
 * `Write`. The "first positional child" rule is intentional and
 * implicit — sufficient for assign-style ctors in curly-brace
 * grammars (e.g. `Assign(left, right)`, `AddAssign(left, right)`)
 * where the LHS is the binding being modified. Nested LHS shapes
 * (`FieldAccess`, `IndexAccess`, paren-wrapped, etc.) deliberately
 * do not trigger a Write reclassification on inner identifiers —
 * those inner identifiers remain Reads, which matches semantic
 * expectation (`arr[i] = v` reads `arr` and `i`, writes `arr[i]`;
 * `obj.x = 1` reads `obj`, writes `obj.x`).
 *
 * Phase 3.3 scope: write classification via parent-kind context.
 * Compound assignments (`x += 1`) are classified as `Write` —
 * `RefKind` carries one classification per hit; the read-then-write
 * semantics of compound assigns folds into the `--writes` query
 * intent. Plugin-contract enrichment for transparent-struct decl
 * sites (3.2b) layers on top without breaking this shape.
 *
 * `selfScopeDeclKinds` (Phase 3.2b-α) is the set of scope-introducer
 * kinds whose own `name` slot is a binding declared into THEIR OWN
 * scope frame — the iterator/parameter-on-the-scope-node pattern (Haxe
 * `for (i in xs) …`). Such a kind emits a `Decl` hit (self-bound, like
 * `declHostKinds`) but, unlike `declHostKinds`, the binding is visible
 * only *inside* the construct: a read of `i` after the loop does NOT
 * resolve to it. This is the opposite of `declHostKinds`, where the
 * name binds into the *enclosing* frame and is visible to siblings
 * (function / type names). A kind here must also appear in `scopeKinds`
 * (the walker only self-declares when it pushes a frame) and must NOT
 * appear in `declHostKinds` (the two bind into different frames).
 * Catch-clause and lambda-parameter bindings are NOT covered — they
 * sit on transparent typedef-structs that carry no runtime span, so a
 * correct per-clause/per-param binding span is deferred (3.2b-β).
 */
@:nullSafety(Strict)
typedef RefShape = {
	var identKind: String;
	var declHostKinds: Array<String>;
	var scopeKinds: Array<String>;
	var writeParentKinds: Array<String>;
	var selfScopeDeclKinds: Array<String>;

	/**
	 * Node kinds whose SUBTREE is opaque to textual reference analysis —
	 * metaprogramming reification where an identifier's uses are injected by
	 * splicing rather than written literally (Haxe's `macro { … }`, surfaced as
	 * `MacroExpr`). A reference-analysis check (e.g. `unused-local`) must not
	 * flag a binding declared inside such a subtree: its uses may be spliced in
	 * from elsewhere and are invisible to a source scan. Optional — a grammar
	 * with no reification leaves it unset (treated as empty).
	 */
	@:optional var opaqueKinds: Array<String>;

	/** Kinds that each add one decision point to a function's cyclomatic complexity. */
	@:optional var branchKinds: Array<String>;

	/**
	 * Function-declaration kinds — each is a measured cyclomatic-complexity unit;
	 * branch counting stops at a nested one (it is measured on its own).
	 */
	@:optional var functionKinds: Array<String>;

	/**
	 * Binary-operator kinds for which identical operands are suspicious — the
	 * `identical-operands` check flags `a == a` / `a != a` / `a < a` / `a && a` and
	 * the like. Optional; a grammar that leaves it unset makes the check a no-op.
	 */
	@:optional var comparisonKinds: Array<String>;

	/**
	 * The assignment node kind — the `self-assignment` check flags a bare-identifier
	 * assignment to itself (`x = x`). Optional; unset makes the check a no-op.
	 */
	@:optional var assignKind: String;

	/**
	 * The function-call node kind — lets the `identical-operands` check EXCLUDE an
	 * operand that contains a call (so `g() == g()`, whose two calls may differ, is
	 * not flagged). Optional.
	 */
	@:optional var callKind: String;

	/**
	 * The switch case-branch node kind — the `duplicate-case` check flags a second
	 * unguarded branch whose pattern source repeats an earlier one. Optional; unset
	 * makes the check a no-op.
	 */
	@:optional var caseBranchKind: String;

	/**
	 * The parenthesized-expression node kind — the `redundant-parens` check flags a
	 * redundant double wrap (`((e))`). Optional; unset makes the check a no-op.
	 */
	@:optional var parenKind: String;

	/**
	 * The boolean-literal node kind — lets the `constant-condition` check
	 * recognise a literal `true` / `false` used as a condition. Optional; unset
	 * makes the check a no-op.
	 */
	@:optional var boolLitKind: String;

	/**
	 * Conditional node kinds whose `children[0]` is the condition — the
	 * `constant-condition` check flags a `boolLitKind` condition here (`if (true)`
	 * / `if (false)`: a branch always or never taken). Loops are intentionally
	 * excluded (`while (true)` is an idiomatic infinite loop). Optional; unset
	 * makes the check a no-op.
	 */
	@:optional var branchConditionKinds: Array<String>;

	/**
	 * The statement-scope empty-statement node kind — a stray `;` inside a body.
	 * The `empty-statement` check flags every one and its `--fix` deletes it.
	 * Optional; unset makes the check ignore statement-scope strays.
	 */
	@:optional var emptyStmtKind: String;

	/**
	 * The member-scope empty-statement node kind — a stray `;` after a class
	 * member (e.g. `function f():Void {};`). Flagged by the same `empty-statement`
	 * check alongside `emptyStmtKind`. Optional; unset makes the check ignore
	 * member-scope strays.
	 */
	@:optional var emptyMemberKind: String;

	/**
	 * Statement-position local declaration kinds — a plain local `var` / `final`
	 * (not params, `for` iterators, `catch` vars, or class fields). Used by
	 * reference-analysis checks to tell a local binding from a field: `unused-local`
	 * indexes these as deletable declarations, and `self-assignment` flags `x = x`
	 * only when `x` resolves to one (a field's `x = x` may invoke a property setter,
	 * so it is left alone). Optional — unset makes both treat it as empty.
	 */
	@:optional var localDeclKinds: Array<String>;

	/**
	 * Statement-position `if` kinds — the `redundant-else-after-return` check flags
	 * an `else` on one of these whose then-branch always exits. Expression-position
	 * `if` (`var x = if (c) a else b`) is excluded: its `else` is required. Optional;
	 * unset makes the check a no-op.
	 */
	@:optional var ifStatementKinds: Array<String>;

	/**
	 * Equality-operator kinds — the `comparison-to-boolean` check flags a comparison
	 * against a boolean literal (`x == true` / `x != false`). Optional; unset makes the
	 * check a no-op.
	 */
	@:optional var equalityKinds: Array<String>;

	/**
	 * The null-safe field-access node kind (`a?.b`) — lets `comparison-to-boolean` SKIP an
	 * operand reached through `?.`, whose value may be `Null<Bool>`, so the `== true` is
	 * load-bearing under strict null-safety rather than redundant. Optional.
	 */
	@:optional var nullSafeAccessKind: String;

	/**
	 * The logical-not node kind — the `double-negation` check flags `!!x` (a `notKind`
	 * node directly wrapping another). Optional; unset makes the check a no-op.
	 */
	@:optional var notKind: String;

	/**
	 * The statement-block node kind — lets `collapsible-if` unwrap a single-statement
	 * `{ … }` then-branch to reach a nested `if`. Optional; unset means only a brace-free
	 * nested `if` is collapsed.
	 */
	@:optional var blockStmtKind: String;

	/**
	 * Condition node kinds that bind no tighter than `&&`, so they need parentheses when
	 * merged — `collapsible-if` wraps an outer/inner condition of one of these (`||`,
	 * ternary, `??`, assignment) so `if (a || c) if (b)` collapses to `if ((a || c) && b)`, not the
	 * mis-precedenced `if (a || c && b)`. Optional.
	 */
	@:optional var andLowerPrecedenceKinds: Array<String>;

	/**
	 * The logical-and operator text — the joiner `collapsible-if` emits between the two
	 * merged conditions. Optional; unset disables the `collapsible-if` autofix.
	 */
	@:optional var andOperatorText: String;

	/**
	 * The ternary / conditional-expression node kind (`cond ? a : b`) — the
	 * `prefer-null-coalescing` check rewrites a null-guarding ternary to `??`.
	 * Optional; unset makes the check a no-op.
	 */
	@:optional var ternaryKind: String;

	/**
	 * The null-literal node kind (`null`) — lets `prefer-null-coalescing`
	 * recognise the `… != null` / `… == null` guard. Optional.
	 */
	@:optional var nullLiteralKind: String;

	/**
	 * The equality (`==`) operator kind — `prefer-null-coalescing` needs to tell
	 * `==` from `!=` to know which branch holds the guarded value. Optional.
	 */
	@:optional var eqKind: String;

	/**
	 * The inequality (`!=`) operator kind — the `!=`-form counterpart of `eqKind`
	 * for `prefer-null-coalescing`. Optional.
	 */
	@:optional var notEqKind: String;

	/**
	 * The `new T(...)` node kind — `prefer-array-literal` / `prefer-map-literal`
	 * recognise a `new Array()` / `new Map()` replaceable by the `[]` literal. The
	 * node's `name` is the constructed type; its children are type parameters, not
	 * constructor arguments. Optional; unset makes both checks a no-op.
	 */
	@:optional var newExprKind: String;

	/**
	 * The field-access node kind (`a.b`) — lets `prefer-interpolation` recognise the
	 * `Std.string(...)` call it rewrites to string interpolation. Optional; unset makes
	 * the check a no-op.
	 */
	@:optional var fieldAccessKind: String;

	/**
	 * The force-unwrap field-access node kind (`a!.b`) — same child shape as
	 * `fieldAccessKind` (the receiver is `children[0]`); `null-dereference` flags
	 * one whose receiver is provably null by flow. Optional.
	 */
	@:optional var forceFieldAccessKind: String;

	/**
	 * The index-access node kind (`a[i]`) — the receiver is `children[0]`, the
	 * index expression the second child; `null-dereference` flags one whose
	 * receiver is provably null by flow. Optional.
	 */
	@:optional var indexAccessKind: String;

	/**
	 * Mutable statement-position local declaration kinds — a plain local `var`
	 * (NOT `final`, params, `for` iterators, `catch` vars, or class fields). The
	 * `prefer-final` check flags one never reassigned in its scope and rewrites it
	 * to `final`. A subset of `localDeclKinds`, which also lists the already-`final`
	 * form. Optional — unset makes the check a no-op.
	 */
	@:optional var mutableLocalDeclKinds: Array<String>;

	/**
	 * The value-returning `return` statement kind (`return e;`) — the
	 * `prefer-ternary-return` check collapses an `if (c) return a;` immediately
	 * followed by a `return b;` into `return c ? a : b;`. A value-less `return;`
	 * is a distinct kind and is excluded (it has no ternary value). Optional;
	 * unset makes the check a no-op.
	 */
	@:optional var returnStatementKind: String;

	/**
	 * Conditional kinds whose condition is `children[0]` (`if` / `while`) — the
	 * `assignment-in-condition` check looks at that child for an `assignKind` node
	 * (`if (a = b)`). Optional; unset (with `conditionLastChildKinds`) → no-op.
	 */
	@:optional var conditionFirstChildKinds: Array<String>;

	/**
	 * Conditional kinds whose condition is the LAST child (`do … while`) — the
	 * `assignment-in-condition` check looks at that child for an `assignKind` node.
	 * Separate from `conditionFirstChildKinds` because the condition position differs
	 * per construct. Optional.
	 */
	@:optional var conditionLastChildKinds: Array<String>;

	/**
	 * The parenthesized arrow-lambda kind (`() -> body`) — the `prefer-bind` check
	 * rewrites a `() -> f(a, b)` (a single wrapped `callKind`, no parameters) to
	 * `f.bind(a, b)`. Optional; unset makes the check a no-op.
	 */
	@:optional var parenLambdaKind: String;

	/**
	 * The `for` statement kind — the `redundant-map-iter-key` check flags a key-value
	 * loop that discards its key (`for (_ => v in m)`), reading the iterator variable
	 * from the node name. Optional; unset makes the check a no-op.
	 */
	@:optional var forStmtKind: String;

	/**
	 * Function-parameter node kinds (Haxe `Required` / `Optional` / `Rest`) — the
	 * `unused-parameter` check inspects a function's direct children of these kinds.
	 * Optional; unset makes the check a no-op.
	 */
	@:optional var paramKinds: Array<String>;

	/**
	 * Supertype-clause node kinds (`extends` / `implements`) — the
	 * `unused-parameter` check treats a function whose PARENT carries one of these
	 * as a contract candidate (an override / interface implementation, whose
	 * signature is fixed elsewhere) and skips its parameters. Optional.
	 */
	@:optional var supertypeClauseKinds: Array<String>;

	/**
	 * The body-less function marker kind (Haxe `NoBody`, for an interface / abstract
	 * method declaration) — the `unused-parameter` check skips a function carrying
	 * one, having no body to reference its parameters in. Optional.
	 */
	@:optional var noBodyKind: String;

	/**
	 * The catch-clause node kind (Haxe `CatchClause`, carrying the exception
	 * variable as its `name` and the handler block as its last child) — the
	 * `swallowed-exception` check inspects each one. Optional; unset makes the check
	 * a no-op.
	 */
	@:optional var catchClauseKind: String;

	/**
	 * Deliberate control-exit node kinds (Haxe `ThrowStmt` / `ThrowExpr` /
	 * `ReturnStmt` / `VoidReturnStmt`) — the `swallowed-exception` check treats a
	 * catch body containing one as deliberate escalation / recovery (a rethrow or a
	 * fallback return), not a silent swallow, and skips it. Optional; unset disables
	 * the exemption.
	 */
	@:optional var controlExitKinds: Array<String>;

	/**
	 * Literal-expression node kinds usable verbatim as a switch `case` pattern
	 * (int / float / bool / null; interpolation-free strings are matched via `stringFoldSupport` instead) — the `prefer-switch` check needs to tell
	 * a comparison against a constant (convertible to `case <lit>:`) from one against
	 * an arbitrary expression. Optional; unset makes the check a no-op.
	 */
	@:optional var caseLiteralKinds: Array<String>;

	/**
	 * Declaration kinds whose members require an explicit visibility modifier — a
	 * class / abstract (NOT an interface, whose members are implicitly public, nor
	 * an enum abstract, whose values are). The `missing-visibility` check scans each
	 * one's members. Optional; unset makes the check a no-op.
	 */
	@:optional var visibilityContainerKinds: Array<String>;

	/**
	 * Class / abstract member-host kinds (Haxe `VarMember` / `FinalMember` /
	 * `FnMember` / `FinalModifiedMember`) — a modifier run attaches to one of these.
	 * The `missing-visibility` and `modifier-order` checks tell a member from the
	 * modifier siblings that precede it; `explicit-type` splits them into fields
	 * (`fieldDeclKinds`) and the rest (functions). Optional.
	 */
	@:optional var memberDeclKinds: Array<String>;

	/**
	 * The visibility-modifier sibling kinds (Haxe `Public` / `Private`) — the
	 * `missing-visibility` check treats a member-host preceded by none of these in
	 * its modifier run as lacking explicit visibility. Optional; unset → no-op.
	 */
	@:optional var visibilityModifierKinds: Array<String>;

	/**
	 * The canonical modifier order — a modifier's rank is its index here. The
	 * `modifier-order` check flags a member's run of these whose ranks are not
	 * non-decreasing (`override` → `public` / `private` → `static` → `inline`).
	 * Modifiers absent from the list carry no documented order and are ignored.
	 * Optional; unset makes the check a no-op.
	 */
	@:optional var modifierOrderKinds: Array<String>;

	/**
	 * The field member-host kinds (Haxe `VarMember` / `FinalMember`) — the subset of
	 * `memberDeclKinds` that declare a value, checked by `explicit-type` for a type
	 * annotation. The remaining `memberDeclKinds` are the function hosts whose
	 * parameters and return type it checks. Optional; unset → no-op.
	 */
	@:optional var fieldDeclKinds: Array<String>;

	/**
	 * The function-body marker kinds (Haxe `BlockBody` / `ExprBody` / `NoBody`) —
	 * `explicit-type` treats a function child that is neither a parameter
	 * (`paramKinds`) nor one of these as the return type, so a function with no such
	 * child has no explicit return type. Optional.
	 */
	@:optional var functionBodyKinds: Array<String>;

	/**
	 * The enum-abstract declaration kind (Haxe `EnumAbstractDecl`) — `explicit-type`
	 * exempts its value members from the field type-annotation rule, their type being
	 * the abstract's underlying type. Optional.
	 */
	@:optional var enumAbstractDeclKind: String;

	/**
	 * The value-less `return` statement kind (Haxe `VoidReturnStmt`) — the
	 * `redundant-void-return` check flags one that is the last statement of a
	 * function body, where falling off the end is equivalent. Distinct from the
	 * value-returning `returnStatementKind`. Optional; unset makes the check a no-op.
	 */
	@:optional var voidReturnKind: String;

	/**
	 * Mutable field member-host kinds (Haxe `VarMember`) — a class `var` field, the
	 * subset of `fieldDeclKinds` excluding the already-`final` `FinalMember`. The
	 * `prefer-final-field` check flags one whose initializer is never reassigned and
	 * rewrites `var` to `final`. Optional; unset makes the check a no-op.
	 */
	@:optional var mutableFieldDeclKinds: Array<String>;

	/**
	 * The visibility keyword whose insertion preserves behaviour — the language's
	 * default member visibility (Haxe `private`). The `missing-visibility` check
	 * inserts it to fix a member lacking explicit visibility; a grammar whose default
	 * cannot be safely auto-inserted leaves it unset (report-only). Optional.
	 */
	@:optional var defaultVisibilityModifierText: String;

	/**
	 * The `override` modifier kind (Haxe `Override`) — the `missing-visibility`
	 * autofix skips inserting a default visibility on an overriding member, whose
	 * effective visibility is inherited from the supertype (forcing `private` on an
	 * override of a public method would lower visibility below the superclass — a
	 * compile error). Optional; unset disables that exemption.
	 */
	@:optional var overrideModifierKind: String;

	/**
	 * Operand kinds whose value may be null or whose non-nullness the analyzer
	 * cannot prove without a typechecker — `comparison-to-boolean` skips a
	 * comparison whose non-literal operand subtree reaches any of these, since
	 * `expr == true` on a `Null<Bool>` is load-bearing under strict null-safety.
	 * (Haxe: `Call`, `FieldAccess`, `SafeFieldAccess`.) Optional; unset falls
	 * back to the legacy `nullSafeAccessKind`-only skip.
	 */
	@:optional var nullableOperandKinds: Array<String>;

	/**
	 * Numeric-literal node kinds (`IntLit` / `FloatLit` / `HexLit`) — the
	 * `magic-number` check flags one used in executable code (inside a
	 * `functionKinds` unit) whose value is not in the small exempt set.
	 * Optional; a grammar that leaves it unset makes the check a no-op.
	 */
	@:optional var numericLiteralKinds: Array<String>;

	/**
	 * Nested-function kinds (local `function` declarations) that fold into their
	 * enclosing measured function for the `complexity` check instead of being
	 * measured as separate units. Prevents a block from evading the metric by
	 * being wrapped in a local function. Unset -> every `functionKinds` entry is an
	 * independent unit. NOT subtracted by the other checks that read `functionKinds`.
	 */
	@:optional var localFunctionKinds: Array<String>;

	/**
	 * Lambda / anonymous-function kinds — expression-position function values
	 * (`x -> …`, `(a, b) -> …`, `function(…) { … }`). The call-graph layer
	 * registers each as an anonymous function node (a `Contains` edge from its
	 * enclosing function) and a `Ref` edge when passed as a call argument.
	 * Unset → lambdas are invisible to the call graph.
	 */
	@:optional var lambdaKinds: Array<String>;

	/**
	 * Object-literal field kind — a numeric literal that is the DIRECT value of such
	 * a field (`{ value: 30 }`) is declarative DATA, not logic, so `magic-number`
	 * exempts it. A computed field value (`{ value: 30 * k }`) keeps the literal
	 * under the operator node (not the field), so it stays flagged. Unset → no
	 * object-field exemption.
	 */
	@:optional var objectFieldKind: String;

	/**
	 * Kinds INSIDE an `opaqueKinds` reification subtree that RE-OPEN normal
	 * reference resolution: macro interpolation — `${…}` (`DollarBlockExpr`) and
	 * `$v{…}`/`$i{…}`/`$p{…}` (`DollarReifExpr`). A plain identifier under a
	 * reified node is a runtime emit (NOT a reference to the enclosing scope), but
	 * an identifier under an interpolation IS a real compile-time reference.
	 * Optional — unset leaves a reification subtree fully opaque.
	 */
	@:optional var interpolationKinds: Array<String>;

	/**
	 * The identifier that qualifies an instance-member access with the enclosing
	 * object — `this` in curly-brace families, `self` in Python. Used by the
	 * `redundant-this` check to recognise a self-qualified access (`this.field`)
	 * reducible to a bare reference when no local shadows the name. Optional —
	 * unset disables the check.
	 */
	@:optional var selfReferenceText: Null<String>;

	/**
	 * Type-declaration kinds whose `this` is the underlying value rather than an
	 * instance — a compile-time `abstract A(T)` / `enum abstract`, where a
	 * `this.field` accesses the underlying type's member and the `this.` qualifier
	 * is MANDATORY (there is no implicit-this). The `redundant-this` check skips
	 * members of these types. An OOP `abstract class` is a real class and is NOT
	 * listed. Optional — unset means no such types exist.
	 */
	@:optional var underlyingThisTypeKinds: Array<String>;

	/**
	 * The `static` modifier kind (Haxe `Static`) — the `member-order` check uses it to
	 * tell a static field/method (a constant / static-method-section member) from an
	 * instance one. Optional; unset makes the check treat every member as instance.
	 */
	@:optional var staticModifierKind: String;

	/**
	 * The constructor's member name (Haxe `new`) — the `member-order` check ranks the
	 * constructor between the fields and the instance methods. Optional; unset means no
	 * constructor is recognised (it sorts as an ordinary instance method).
	 */
	@:optional var constructorName: String;

	/**
	 * Name prefixes of property accessor methods (Haxe `get_` / `set_`) — the
	 * `member-order` check ranks them immediately after the constructor, ahead of the
	 * other instance methods. Optional; unset means accessors sort as ordinary methods.
	 */
	@:optional var accessorMethodPrefixes: Array<String>;

	/**
	 * The conditional-compilation member kind (Haxe `Conditional`, a `#if … #end`
	 * region wrapping whole member declarations). The `member-order` check descends
	 * into it to collect a guarded member with the condition it is declared under,
	 * and the reorder autofix re-wraps the sorted members in `#if`/`#end`. Optional;
	 * unset means the grammar has no conditional members (no descent).
	 */
	@:optional var conditionalMemberKind: String;

	/** The `#if` directive keyword (Haxe `#if`) opening a conditional region — read to recover its condition text. Optional. */
	@:optional var conditionalIfKeyword: String;

	/**
	 * The `#else` / `#elseif` directive keywords. The `member-order` reorder cannot yet
	 * split a conditional's then-body from its else-body (both project as flat
	 * children), so it bails a container whose member gaps contain one. Optional.
	 */
	@:optional var conditionalElseKeywords: Array<String>;

	/**
	 * Type names that are provably non-nullable on static targets — Haxe value
	 * types (`Int` / `Float` / `Bool` / `UInt`) whose `!= null` comparison is
	 * constant regardless of null-safety. The `unnecessary-null-check` check
	 * flags a comparison against `null` whose other operand resolves (via
	 * `TypeInfoProvider.declaredTypes`) to one of these. Optional; unset removes
	 * the value-type half of that check.
	 */
	@:optional var nonNullableTypeNames: Array<String>;

	/**
	 * The metadata name (including the `@:` prefix, e.g. `@:nullSafety`) that marks
	 * a type declaration as null-checked. When present on the enclosing type,
	 * `unnecessary-null-check` treats any non-`Null<…>` nominal local/param/field
	 * (present in `declaredTypes`) as non-null. Optional; unset disables the
	 * null-safety half of that check, leaving only `nonNullableTypeNames`.
	 */
	@:optional var nullSafetyMetaName: String;

	/**
	 * Typed-cast / type-check expression kinds whose target type the
	 * `redundant-cast` check compares against its operand's declared type —
	 * Haxe `cast(expr, T)` (`TypedCastExpr`) and `(expr : T)` (`ECheckTypeExpr`).
	 * The untyped `cast expr` (no target type) is excluded. The target type is
	 * recovered via `TypeInfoProvider.castTargetTypes`. Optional; unset makes the
	 * check a no-op.
	 */
	@:optional var typedCastKinds: Array<String>;

	/**
	 * Nominal type names that stay nullable even under a null-safety meta — the
	 * explicit `Null<…>` wrapper (recovered as its outer name `Null`) and the
	 * null-safety escape hatches (`Dynamic` / `Any`). `unnecessary-null-check`
	 * never treats one of these as non-null, so a `!= null` on it is reported as
	 * load-bearing, not redundant. Optional; unset adds no exclusions.
	 */
	@:optional var nullableWrapperTypeNames: Array<String>;

	/**
	 * The argument identifier of the null-safety meta that DISABLES checking
	 * (Haxe `@:nullSafety(Off)`). When the enclosing type's null-safety meta
	 * carries it, `unnecessary-null-check` does not treat the type as null-checked.
	 * Optional; unset means any presence of `nullSafetyMetaName` counts as enabled.
	 */
	@:optional var nullSafetyDisableArg: String;

	/**
	 * The node kind of an OPTIONAL parameter (Haxe `?x: T`, projected as
	 * `Optional`), whose value is nullable despite a nominal `:Type` annotation
	 * (which `declaredTypes` records). A parameter with a default value (`x: T = d`)
	 * projects as the required kind and is non-null. `unnecessary-null-check` skips
	 * an operand bound to an optional parameter. Optional; unset disables the skip.
	 */
	@:optional var optionalParamKind: String;

	/**
	 * The null-coalescing operator node kind (`a ?? b`, Haxe `NullCoal`) — the
	 * `redundant-null-coalescing` check flags one whose left operand is provably
	 * non-null (`TypeResolver.isProvablyNonNull`), making the right operand dead.
	 * Optional; unset makes the check a no-op.
	 */
	@:optional var nullCoalesceKind: String;

	/**
	 * The `is` type-check expression kind (`x is T`) — the `redundant-is-check`
	 * check flags one whose value operand is a plain identifier of declared type
	 * `T` (and provably non-null), so the test is always true. The node's
	 * `children[0]` is the value operand, `children[1]` the checked type (its span
	 * covers the full written type, generics included). Optional; unset makes the
	 * check a no-op.
	 */
	@:optional var isExprKind: String;

	/**
	 * Type names that, as an EARLIER catch-clause exception type, catch every thrown
	 * value (Haxe `Dynamic` / `Any`), making any later clause unreachable. The
	 * `unreachable-catch` check reads these. Optional; unset → only same-type and
	 * subtype-after-supertype unreachability is detected.
	 */
	@:optional var catchAllTypeNames: Array<String>;

	/**
	 * The runtime-CHECKED cast node kind (Haxe `cast(x, T)` — `TypedCastExpr`), which does a
	 * runtime type test and throws on mismatch — distinct from the compile-time `(x : T)`
	 * ascription. The `impossible-cast` check reads it. Optional; unset makes the check a no-op.
	 */
	@:optional var checkedCastKind: String;

	/**
	 * Identifier names that project as a plain identifier expression but denote a
	 * loop jump (Haxe `break` / `continue` surface as `IdentExpr` nodes named so,
	 * not as dedicated kinds) — the `dead-store` check treats one as jumping to an
	 * unknown point, conservatively making every variable live. Optional; unset
	 * loses that protection only for grammars that project jumps this way.
	 */
	@:optional var loopJumpNames: Array<String>;

	/**
	 * The string-interpolation identifier kind (Haxe `Ident` — a simple `$name`
	 * inside a single-quoted string projects as this, not as `identKind`) — the
	 * `dead-store` check counts one as a read so an interpolated-only use keeps its
	 * variable's stores live. Optional.
	 */
	@:optional var stringInterpIdentKind: String;

	/**
	 * Node kinds a local declaration projects for its TYPE ANNOTATION (Haxe `Anon`
	 * — only a top-level anonymous-struct annotation survives projection; nominal
	 * and function types are dropped) — a decl's initializer is its last child
	 * EXCLUDING these, so flow engines must not mistake the type for the init.
	 * Optional.
	 */
	@:optional var declTypeChildKinds: Array<String>;

	/**
	 * The `default:` branch kind of a `switch` (Haxe `DefaultBranch` — a distinct
	 * kind from `caseBranchKind`, with the branch body as its children) — the
	 * null-flow engine joins it as an always-matching branch. Optional.
	 */
	@:optional var defaultBranchKind: String;

	/**
	 * The case-pattern wrapper kind (Haxe `Plain` — a `CaseBranch`'s first child;
	 * a guard does NOT change the wrapper — it projects as a bare parenthesized
	 * expression sibling between the pattern and the body statements) — the
	 * null-flow engine recognises an exhaustive wildcard case through it,
	 * rejecting guarded branches via that sibling. Optional.
	 */
	@:optional var plainCasePatternKind: String;

	/**
	 * The wildcard pattern identifier (Haxe `_`) — an unguarded case whose whole
	 * pattern is this identifier matches every subject, making the switch
	 * exhaustive for the null-flow join. Optional.
	 */
	@:optional var wildcardPatternName: String;

	/**
	 * The expression-statement wrapper kind (Haxe `ExprStmt`) — a loop jump
	 * (`loopJumpNames`) appears as this wrapping a lone identifier, which the
	 * null-flow engine treats as a branch exit. Optional.
	 */
	@:optional var exprStatementKind: String;

	/**
	 * The null-coalescing assignment kind (Haxe `x ??= e` — `NullCoalAssign`) —
	 * assigning a definitely non-null value through it leaves the target non-null
	 * on every path, which the null-flow engine narrows on. Optional.
	 */
	@:optional var nullCoalAssignKind: String;

	/**
	 * The `macro`-modifier node kind. A function declared with it runs at
	 * COMPILE time — its body is not runtime code, so the call graph skips the
	 * declaration entirely (a runtime call site expands in place instead of
	 * dispatching to it). Optional — unset treats every function as runtime.
	 */
	@:optional var macroModifierKind: String;

	/**
	 * Operator node kinds that consume their operands as non-null numbers —
	 * arithmetic (`+ - * / %`), relational (`< > <= >=`), bitwise (`& | ^`),
	 * shift (`<< >> >>>`) and the unary `-` / `~`. The `unchecked-nullable`
	 * check flags a `nullableNumericReturnCalls` result appearing directly as an
	 * operand of one of these. Null-tolerant `==` / `!=` and the type-incompatible
	 * logical `&&` / `||` are intentionally excluded. Optional; unset makes the
	 * check a no-op.
	 */
	@:optional var numericOperatorKinds: Array<String>;

	/**
	 * Dotted `Receiver.method` signatures of calls whose result is a nullable
	 * number (Haxe `Std.parseInt` / `Std.parseFloat`, both `Null<Int>` /
	 * `Null<Float>`) — the nullable sources the `unchecked-nullable` check
	 * recognises. Matched structurally: a `callKind` whose callee is a
	 * `fieldAccessKind` named `method` on an `identKind` receiver named
	 * `Receiver`. Optional; unset makes the check a no-op.
	 */
	@:optional var nullableNumericReturnCalls: Array<String>;

	/**
	 * String-literal node kinds (Haxe `SingleStringExpr` / `DoubleStringExpr`) —
	 * the `unchecked-nullable` check skips a numeric-operator node bearing one
	 * as an operand, since `+` there is string concatenation (`n + "x"`), not a
	 * numeric use. Optional; unset removes that carve-out.
	 */
	@:optional var stringLiteralKinds: Array<String>;

	/**
	 * Nominal type names whose index-access `x[k]` yields a nullable value (Haxe's
	 * `Map` family — `Map` / `StringMap` / `IntMap` / `ObjectMap` / `EnumValueMap`
	 * / `WeakMap`, all returning `Null<V>`) — as opposed to `Array` / `String`,
	 * whose index yields a non-null `T`. The `possible-null-dereference` check
	 * flags a deref of an index-access whose receiver's declared type (outer
	 * nominal, via `TypeResolver.identTypeName`) is one of these. Optional; unset
	 * makes the check a no-op.
	 */
	@:optional var nullableIndexTypeNames: Array<String>;

	/**
	 * Dotted `Type.method` signatures of INSTANCE calls whose result is nullable
	 * (Haxe `Array.pop` / `Array.shift` / `List.pop`, each returning `Null<T>`) —
	 * the call-result nullable sources the `possible-null-dereference` check
	 * recognises alongside `nullableIndexTypeNames`. Matched structurally: a
	 * `callKind` whose callee is a `fieldAccessKind` named `method` on an
	 * `identKind` receiver whose declared outer-nominal type (via
	 * `TypeResolver.identTypeName`) is `Type`. Optional; unset drops the
	 * call-result half of the check.
	 */
	@:optional var nullableInstanceReturnCalls: Array<String>;

	/**
	 * Return-type outer-nominal names that mark a function's result as nullable —
	 * Haxe's explicit `Null<T>` wrapper (outer name `Null`). The
	 * `possible-null-dereference` check flags a deref of a call whose callee is a
	 * plain identifier binding to a function whose `TypeInfoProvider.returnTypes`
	 * entry is one of these. `Dynamic` / `Any` are intentionally excluded — a
	 * deref of an untyped result is not a clear NPE. Optional; unset drops the
	 * call-return half of the check.
	 */
	@:optional var nullableReturnMarkerTypes: Array<String>;

	/**
	 * Dotted `Type.method` instance-call sources EXCLUDED from the flow-sensitive
	 * `unguarded-nullable-deref` seed — the length-guarded collection accessors
	 * (`Array.pop` / `Array.shift` / `List.pop` / `List.first` / `List.last`), whose
	 * dominant real-world idiom (`while (c.length > 0) c.pop()`) is provably safe by a
	 * guard flow cannot model, so seeding them as `MaybeNull` produces systematic false
	 * positives at `Warning` severity. The point-wise `possible-null-dereference` still
	 * flags them at `Info` (advisory). Optional; unset excludes nothing.
	 */
	@:optional var nullableFlowExcludedCalls: Array<String>;

	/**
	 * Dotted `Type.method` calls that ASSERT their single plain-identifier argument is
	 * non-null (they throw otherwise) — e.g. the test framework's `Assert.notNull`. The
	 * flow engine clears the argument's `MaybeNull` fact after such a call (`maybe`-only —
	 * the six flow checks are unaffected), so a `var u = f(); Assert.notNull(u); u.field`
	 * guard is honoured. A project lists its own precondition helpers here. Optional; unset
	 * models no assertion narrowing.
	 */
	@:optional var nullAssertionCalls: Array<String>;

	/**
	 * Field names that denote a collection's element count (`length`) — the
	 * `magic-number` check exempts a numeric literal compared against such a
	 * field access (`args.length == 3`), a self-documenting structural arity
	 * check, while a threshold comparison against a domain value (`score ==
	 * 100`) stays flagged. Optional; unset removes the carve-out.
	 */
	@:optional var sizeFieldNames: Array<String>;

	/**
	 * Type-declaration kinds whose CONSTRUCTORS/values are referenceable as bare
	 * identifiers (Haxe `EnumDecl` / `EnumAbstractDecl`) — an `import pkg.Enum;`
	 * of such a type is used when one of its constructors appears bare
	 * (expected-type resolved), even though the type name never does. Lets
	 * `unused-import` avoid deleting a needed enum import. Optional; unset drops
	 * the carve-out.
	 */
	@:optional var bareConstructorTypeKinds: Array<String>;

	/**
	 * Method names that take or return a STRING POSITION / offset (`substr`,
	 * `substring`, `charAt`, `charCodeAt`, `indexOf`, `lastIndexOf`, StringTools'
	 * `hex`) — the `magic-number` check exempts a numeric literal that reaches such a
	 * call's argument, directly or through `+`/`-` offset arithmetic (`s.charCodeAt(i
	 * + 5)`, `s.substr(0, 4)`): the number is a position, not a hidden quantity.
	 * Optional; unset removes the carve-out.
	 */
	@:optional var positionMethodNames: Array<String>;

	/**
	 * Additive-operator node kinds (`Add` / `Sub`) — let the `magic-number` check see
	 * through `x + N` / `x - N` offset arithmetic when deciding whether a literal sits
	 * in a size (`s.length - 3`) or string-position (`charCodeAt(i + 5)`) context.
	 * Optional; unset removes those carve-outs.
	 */
	@:optional var additiveKinds: Array<String>;

	/**
	 * Switch node kinds (`SwitchStmt` / `SwitchStmtBare` / `SwitchExpr` /
	 * `SwitchExprBare` for Haxe) — the `complexity` check counts a switch as ONE
	 * decision (cognitive-complexity model) rather than one per `case`. Identified by
	 * kind, not by "has a case child", so an `#if`-guarded case run wrapped in a
	 * conditional node is not mistaken for a second switch. Optional; unset falls back
	 * to per-`case` cyclomatic counting.
	 */
	@:optional var switchKinds: Array<String>;

	/**
	 * The unary-negation node kind (`Neg`) — a `-1` initializer parses as a negation
	 * wrapping a non-negative literal (`Neg(IntLit 1)`). Lets `prefer-enum-abstract`
	 * see a negative-literal constant (`X_UNKNOWN = -1`) as numeric. Optional; unset
	 * treats a negation-wrapped value as non-numeric.
	 */
	@:optional var negationKind: String;
}
@:nullSafety(Strict)
typedef MetaShape = {
	var metaKinds: Array<String>;
	var declHostKinds: Array<String>;
}

/**
 * Plugin-declared contract for `apq uses`. The walker reads this slot
 * and never inspects grammar-specific node types.
 *
 * `typeRefKinds` is the set of `QueryNode.kind` values the plugin emits
 * for a type-position reference on a `parseFileTypeRefs` tree (for Haxe:
 * `'TypeRef'` for the name-slot `type` annotations the default
 * projection drops, plus `'Named'` / `'NewExpr'` for type positions
 * already present in both trees — return types, type-param
 * constraints, `extends`/`implements`, `new T`). `Uses` emits every
 * node whose kind is in this set and whose `name` slot matches the
 * query target.
 */
@:nullSafety(Strict)
typedef TypeRefShape = {
	var typeRefKinds: Array<String>;
}

/**
 * Lint-check option overrides a grammar discovered from its native config — for
 * Haxe, mapped from a project `checkstyle.json` (see `CheckstyleConfigLoader`).
 * Each field is the neutral form of one checkstyle option; an unset field means
 * the project did not configure that check, so the check keeps its own default.
 */
typedef CheckOverrides = {
	/** `magic-number` exempt values (checkstyle `MagicNumber.ignoreNumbers`). */
	@:optional var magicNumberIgnore: Array<Float>;

	/** `unused-import` never-flag module list (checkstyle `UnusedImport.ignoreModules`). */
	@:optional var unusedImportIgnoreModules: Array<String>;

	/** `modifier-order` canonical order, as RefShape modifier kinds (checkstyle `ModifierOrder.modifiers`). */
	@:optional var modifierOrder: Array<String>;

	/** `prefer-single-quotes` active — false when checkstyle `StringLiteral.policy` prefers double quotes. */
	@:optional var preferSingleQuotesEnabled: Bool;

	/** `explicit-type` exempts enum-abstract values (checkstyle `Type.ignoreEnumAbstractValues`). */
	@:optional var explicitTypeIgnoreEnumAbstract: Bool;

	/** `empty-block` active — false when checkstyle `EmptyBlock.option` allows empty blocks. */
	@:optional var emptyBlockEnabled: Bool;
};

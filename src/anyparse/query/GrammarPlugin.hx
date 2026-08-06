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
	 * The branch-aware projection of an ALREADY-PARSED `tree` of `source`: every
	 * conditional-compilation region that sits in a STATEMENT list is regrouped into one
	 * synthetic `CondBranch` node per branch.
	 *
	 * `parseFile` projects a `#if A … #elseif B … #else … #end` region as ONE node with
	 * every branch's statements flattened as siblings, which is not a statement list but N
	 * of them — so the checks that walk a statement list
	 * (`ControlFlowSupport.blockKinds`) deliberately skip it. This parallel projection
	 * recovers the branch boundaries from the directive text in the gaps between child
	 * spans and gives each branch its own list. Consumed ONLY by the checks that opt in via
	 * `CheckScan.parseBranchAwareOrNull`, so every other consumer stays byte-identical to
	 * `parseFile` by construction.
	 *
	 * A projection over a tree, not a parse, so a decorator can memoize it without parsing
	 * twice and a grammar can supply its own without owning the cache. The caller passes the
	 * tree it already has — `CheckScan.parseBranchAwareOrNull` pairs it with `parseFile`.
	 *
	 * A plugin whose grammar exposes no conditional seams — or whose
	 * `ControlFlowSupport.blockKinds()` does not name `CondBranch` — returns `tree` itself.
	 * Pure: `tree` is never mutated, and any subtree the rewrite does not touch is SHARED
	 * with it rather than copied.
	 */
	public function projectBranchAware(tree: QueryNode, source: String): QueryNode;

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
	 *
	 * A plugin whose writer cannot round-trip every comment MUST throw
	 * `anyparse.format.comment.CommentLossException` rather than return
	 * output with a comment missing — `apq fmt` and every op that
	 * canonicalises through `RefactorSupport` treat that as the signal to
	 * leave the file's bytes alone. Returning lossy output instead makes
	 * those callers delete an author's comment with no diagnostic; there is
	 * no way for them to detect it after the fact.
	 * `CommentInventory.firstMissing` implements the check.
	 */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String>;

	/**
	 * Optional: the layout numbers the writer would use for `optsJson` — the
	 * target line width and the column width of one indent character. Lets a check
	 * reason about how wide a construct may be BEFORE paying for a
	 * `writeRoundTrip`, using the same configuration the writer itself would.
	 *
	 * `optsJson` follows the `writeRoundTrip` convention: a language-defined JSON
	 * config string (an `hxformat.json` payload for the Haxe plugin) or `null` for
	 * the plugin's built-in defaults. Return `null` when the grammar has no writer
	 * / no width concept — a width-aware check then no-ops for it.
	 */
	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics>;

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
	 * Run-scoped reference-resolution cache. A caching plugin wrapper attaches its
	 * per-run `RefsCache` here so `Refs.find` resolves against a memoized full-file
	 * index instead of walking the tree per query. Optional — a bare grammar shape
	 * leaves it unset and `Refs.find` walks directly, byte-identical behavior.
	 */
	@:optional var refsCache: RefsCache;

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
	 *
	 * SEAM: `redundant-parens` reads it (with `arrayLiteralKind` / `newExprKind`) as
	 * a SPLICING host — see `spliceSensitiveExprKinds`.
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
	 * redundant double wrap (`((e))`), and `prefer-ternary-expression` counts it as a
	 * delimited slot (a grouping paren bounds its child on both sides). Optional; unset
	 * makes `redundant-parens` a no-op and drops that one slot from
	 * `prefer-ternary-expression`.
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
	 * EXPRESSION-position local declaration kinds — the same local `var` / `final`
	 * bindings when they parse as expressions rather than statements (Haxe:
	 * `VarExpr` / `FinalExpr`, e.g. under a metadata wrapper
	 * `@:nullSafety(Off) var x = …` or inside a macro quotation). A scope- or
	 * collision-scan that walks `localDeclKinds` must usually also recognise
	 * these (reaching through the wrapper) or it under-counts declared names —
	 * `guard-continue`'s shadowing gate is the motivating consumer. Optional —
	 * unset treats the set as empty.
	 */
	@:optional var localDeclExprKinds: Array<String>;

	/**
	 * STATIC local declaration kinds — a local binding whose storage outlives the call
	 * (Haxe 4.3: `static var x = …` / `static final x = …` inside a function body,
	 * `StaticVarStmt` / `StaticFinalStmt`). It binds its name in the enclosing function
	 * exactly like a plain local, so every SHADOW scan must see it; it is NOT in
	 * `localDeclKinds` because the consumers of that set reason about per-call storage
	 * (dead stores, init-at-declaration, type inference on a fresh slot). Optional —
	 * unset treats the set as empty.
	 */
	@:optional var staticLocalDeclKinds: Array<String>;

	/**
	 * Statement-position `if` kinds — the `redundant-else-after-return` check flags
	 * an `else` on one of these whose then-branch always exits. Expression-position
	 * `if` (`var x = if (c) a else b`) is excluded: its `else` is required. Optional;
	 * unset makes the check a no-op.
	 */
	@:optional var ifStatementKinds: Array<String>;

	/**
	 * EXPRESSION-position `if` kinds (Haxe `IfExpr`) — the same `if` when it parses as a
	 * VALUE rather than a statement (`var x = if (c) a else b`, `return if (c) a else b`,
	 * `f(if (c) a else b)`), children `[cond, then, else]` exactly like the statement
	 * form. Disjoint from `ifStatementKinds` by construction, and kept apart because the
	 * two positions differ in what a rewrite may emit: a value-position chain has to stay
	 * exhaustive, a statement chain need not.
	 *
	 * Consumers: `prefer-ternary-expression` rewrites a 2-branch one into a ternary;
	 * `prefer-switch-expression` walks a right-nested chain of these (and of
	 * `ternaryKind`) and rewrites it to a switch expression.
	 *
	 * The kind proves the node YIELDS a value; it does NOT prove the surrounding slot
	 * tolerates an expression of `?:` precedence. An `if`-expression is self-delimiting —
	 * `a || if (c) x else y` groups as `a || (…)` — so a check that rewrites one INTO a
	 * ternary (`prefer-ternary-expression`) must still gate on the parent slot
	 * (`delimitedAllChildKinds` / `delimitedTailChildKinds`), or it silently re-associates.
	 * Optional; unset leaves the if-expression shape unmatched for those checks (a bare
	 * `ternaryKind` chain still converts to a switch).
	 */
	@:optional var ifExpressionKinds: Array<String>;

	/**
	 * STATEMENT-position `try` / `catch` kinds (Haxe `TryCatchStmt`, plus the bare-body
	 * `TryCatchStmtBare`) — `children[0]` is the try body, every following child a
	 * `catchClauseKind`. The `prefer-try-expression-assignment` / `-return` checks collapse
	 * one whose body and every catch body is a single assignment / valued `return` into a
	 * try-EXPRESSION; `prefer-try-expression-assignment` additionally reads it (with
	 * `tryExpressionKinds`) to know when it is INSIDE a handled region. Optional; unset
	 * makes both checks a no-op.
	 */
	@:optional var tryStatementKinds: Array<String>;

	/**
	 * EXPRESSION-position `try` kinds (Haxe `TryExpr`) — the value form the
	 * `prefer-try-expression-*` checks PRODUCE.
	 *
	 * NOT inert when unset: `prefer-try-expression-assignment` folds it into the ancestor
	 * set that tells it whether a declaration + `try` pair sits inside an enclosing handled
	 * region, which is what licenses dropping the declaration's initializer. Leaving it
	 * unset for a grammar that HAS a try-expression silently weakens that soundness gate;
	 * `TryExpressionShape` also reads it to know which emitted value needs parentheses so a
	 * following `catch` cannot re-parent onto it. Optional only for a grammar with no
	 * expression-position `try` at all.
	 */
	@:optional var tryExpressionKinds: Array<String>;

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
	 * Parent kinds in which a value-position chain may be rewritten to a switch
	 * EXPRESSION — the positions where a multi-line `switch { … }` reads at least as
	 * well as the chain it replaces (Haxe: a `return`, a local / member initializer, an
	 * assignment r-value). Deliberately a WHITELIST rather than "any expression
	 * position": a switch spliced into a call argument parses but reads worse than the
	 * ternary it replaced. The `prefer-switch-expression` check requires a chain head's
	 * PARENT kind to be one of these. Optional; unset makes that check a no-op. Two Haxe
	 * hosts are deliberately NOT listed yet and are follow-ups: a static member
	 * initializer (`StaticVarStmt`) and a compound-assignment r-value.
	 */
	@:optional var switchExpressionHostKinds: Array<String>;

	/**
	 * Parent kinds in which a value-position conditional chain may be rewritten to an
	 * if-EXPRESSION chain (`if (c1) v1 else if (c2) v2 else v3`) — the positions where the
	 * multi-line if-chain reads at least as well as the nested ternary it replaces (Haxe: a
	 * `return`, a local / member initializer, an assignment r-value, an arrow-lambda body).
	 * A SUPERSET of `switchExpressionHostKinds`, which lists the same value hosts for the
	 * heavier `switch` rewrite; the lambda bodies are added here because a comparator written
	 * as an if-chain is the established shape while a `switch` in that slot is not.
	 *
	 * Deliberately a WHITELIST rather than "any expression position", for the same reason the
	 * switch seam is one: an if-chain spliced into a call argument or into a construct's own
	 * `(` … `)` condition slot parses (an `if`-expression is a legal expression atom
	 * everywhere a ternary is, and its else-arm is parsed at the same precedence, so no
	 * position re-associates) but reads WORSE than the ternary it replaced. The
	 * `prefer-if-expression-chain` check requires a chain head's PARENT kind to be one of
	 * these. Optional; unset makes that check a no-op.
	 */
	@:optional var ifExpressionChainHostKinds: Array<String>;

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
	 * The logical-AND (`&&`) node kind — its two operands are `children[0]` /
	 * `children[1]`. The condition-simplification autofixes (`dead-null-guard`,
	 * `unnecessary-null-check`, `redundant-is-check`) drop an always-TRUE conjunct
	 * from one of these (`Y && true` ≡ `Y`). Optional; unset disables the `&&`-drop
	 * shape of those fixes.
	 */
	@:optional var logicalAndKind: String;

	/**
	 * The logical-OR (`||`) node kind — the `||`-counterpart of `logicalAndKind`.
	 * The same autofixes drop an always-FALSE disjunct from one of these
	 * (`Y || false` ≡ `Y`). Optional; unset disables the `||`-drop shape.
	 */
	@:optional var logicalOrKind: String;

	/**
	 * The `new T(...)` node kind — `prefer-array-literal` / `prefer-map-literal`
	 * recognise a `new Array()` / `new Map()` replaceable by the `[]` literal. The
	 * node's `name` is the constructed type; its children are the type parameters
	 * FOLLOWED BY the constructor arguments (`new Array<Int>((1))` projects as
	 * `NewExpr Array (Named Int) (ParenExpr …)`), so a consumer that cares about one
	 * group must tell them apart by kind. Optional; unset makes both checks a no-op.
	 *
	 * SEAM: `redundant-parens` reads it (with `callKind` / `arrayLiteralKind`) as a
	 * SPLICING host — see `spliceSensitiveExprKinds`.
	 */
	@:optional var newExprKind: String;

	/**
	 * The field-access node kind (`a.b`) — lets `prefer-interpolation` recognise the
	 * `Std.string(...)` call it rewrites to string interpolation. Optional; unset makes
	 * the check a no-op.
	 */
	@:optional var fieldAccessKind: String;

	/**
	 * The anonymous function-literal expression kind (`function(args) { … }`) —
	 * `prefer-arrow-callback` flags one in call-argument position and rewrites it
	 * to an arrow lambda. Optional; unset makes the check a no-op.
	 */
	@:optional var fnExprKind: String;

	/**
	 * Node kinds that are TYPE annotations, never argument expressions — a `new T<…>`
	 * type argument, a function literal's return-type hint (`Named` / `Anon` /
	 * function-type forms). `prefer-arrow-callback` excludes them when indexing call
	 * arguments and uses them to spot a literal's return hint. Optional; unset makes
	 * that check a no-op.
	 */
	@:optional var typeAnnotationKinds: Array<String>;

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
	 *
	 * SEAM: `redundant-parens` reads the same slot as a DELIMITED position — the
	 * construct writes its own `(` `)` around the condition, so a `parenKind` node
	 * there is a second, redundant pair. A kind belongs here only if its condition
	 * really is bracketed by the construct and really is `children[0]`.
	 */
	@:optional var conditionFirstChildKinds: Array<String>;

	/**
	 * Conditional kinds whose condition is the LAST child (`do … while`) — the
	 * `assignment-in-condition` check looks at that child for an `assignKind` node.
	 * Separate from `conditionFirstChildKinds` because the condition position differs
	 * per construct. Optional.
	 *
	 * SEAM: read by `redundant-parens` as a delimited position too — see
	 * `conditionFirstChildKinds`.
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
	 * catch body containing one as deliberate escalation / recovery (a rethrow or a fallback return), not a silent swallow, and skips it. A SECOND consumer, `RefactorSupport.guardReachedIntact`, asks whether a constructor can exit before a statement it is about to move code past, so completeness of this set is load-bearing for a soundness gate, not only for an exemption: that consumer refuses outright when the set is unset, since an empty set would silently accept every early return. Optional; unset disables the swallowed-exception exemption.
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
	 * The delimiters a switch over a TUPLE of discriminants writes around its subject
	 * and around each `case` pattern (Haxe `[` / `]` — `switch [a, b] { case [X, Y]: … }`).
	 * Both switch checks read them to convert a rung condition that is a
	 * `logicalAndKind` conjunction of equalities over SEVERAL discriminants; with one
	 * discriminant no delimiter is written and the field is not consulted. Optional;
	 * unset means the grammar offers no tuple form and both checks stay on the
	 * single-discriminant shape.
	 */
	@:optional var tuplePatternDelimiters: { open: String, close: String };

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
	 * non-decreasing (`override` → `public` / `private` → `static` → `inline` →
	 * `final`). The trailing `Final` entry (`finalModifierRankKind`) ranks a method's
	 * `final` keyword, which the grammar folds into `finalModifierMemberKind` rather
	 * than emitting as a sibling modifier node. Modifiers absent from the list carry
	 * no documented order and are ignored. Optional; unset makes the check a no-op.
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
	 * The grammar's raw dynamic-type name (Haxe `Dynamic`) — the `avoid-dynamic`
	 * check flags a whole-word occurrence of it in a declared type position (field,
	 * parameter, return, type argument, or annotated local). A typed abstraction whose
	 * name merely starts with it (`DynamicAccess`) is excluded by the whole-word match;
	 * the sanctioned top type (`Any`) is a different name and never flagged. Optional;
	 * unset makes the `avoid-dynamic` check a no-op.
	 */
	@:optional var rawDynamicTypeName: String;

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
	 * The `dynamic` modifier kind (Haxe `Dynamic`) — a function carrying it is a
	 * reassignable callback slot whose signature external assigners rely on. The
	 * `unused-parameter` check skips such a function wholesale: an unreferenced
	 * parameter in its (often trivial / no-op) body is by design, not dead code,
	 * and removing it would break every external assignment. Optional; unset does
	 * not exempt dynamic functions.
	 */
	@:optional var dynamicModifierKind: String;

	/**
	 * The extern-modifier node kind (Haxe `Extern`) that, as a preceding sibling of a
	 * visibility container, marks the members implicitly public. The
	 * `missing-visibility` autofix must not insert `private` there — it would lower an
	 * externally-public member to private. Optional; unset disables the exemption.
	 */
	@:optional var externModifierKind: String;

	/**
	 * Meta names on a visibility container that make its members public by default
	 * (Haxe `@:publicFields`). Like an extern class, such a container's members are
	 * implicitly public, so the `missing-visibility` autofix leaves them report-only
	 * rather than forcing `private`. Optional; unset → empty (no such meta).
	 */
	@:optional var publicDefaultMetaNames: Array<String>;

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
	 * Function-declaration kinds that are `inline` BY KIND rather than by a modifier
	 * sibling — Haxe's local `inline function` (`LocalInlineFnStmt`), which the grammar
	 * gives its own ctor instead of a `Inline` + `LocalFnStmt` pair. A check that must
	 * know whether a body is spliced into its call sites (`prefer-safe-nav-comparison`,
	 * whose rewrite would drop the narrowing an inlined boolean guard grants its
	 * callers) reads this alongside `inlineModifierKind`. Optional — a grammar whose
	 * inline-ness is always a modifier leaves it unset.
	 */
	@:optional var inlineFunctionKinds: Array<String>;

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
	 * The `inline` modifier kind (Haxe `Inline`) — the `inline-constant` check reads it
	 * to skip a field that is ALREADY inline, and (paired with the member host span) to
	 * place an inserted `inline` keyword after `static` and before `final` in canonical
	 * modifier order. Optional; unset makes the check a no-op.
	 */
	@:optional var inlineModifierKind: String;

	/**
	 * The literal node kinds whose `static final` constant can be safely and beneficially
	 * rewritten to `static inline final` — the `inline-constant` check inlines only an
	 * initializer of one of these kinds (or a `negationKind` wrapping a numeric one). The
	 * grammar owns the policy: the Haxe grammar lists the basic scalar kinds (`IntLit` /
	 * `HexLit` / `FloatLit` / `BoolLit`) and DELIBERATELY OMITS the string kinds. Evidence
	 * (hxcpp codegen): an inlined String re-emits its full literal (`HX_("...")`) at every
	 * use site, duplicating the string bytes once per use across translation units, whereas
	 * a non-inline `static final` keeps a single shared copy — with no compensating runtime
	 * benefit (both are static-backed, allocation-free). A scalar instead folds to an
	 * immediate at each use with zero duplication. Optional; unset makes the check a no-op.
	 */
	@:optional var inlineConstantLiteralKinds: Array<String>;

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
	 * children), so it bails a container whose member gaps contain one; `CondDirectives`
	 * reads them as the branch half of its keyword vocabulary. Optional.
	 */
	@:optional var conditionalElseKeywords: Array<String>;

	/**
	 * The `#end` directive keyword (Haxe `#end`) closing a conditional region. Read by
	 * `CondDirectives` so a directive scan reports a region's closer alongside its opener,
	 * and so the closer is never mistaken for a condition-bearing keyword; unset leaves the
	 * closer out of the scanned set. Optional.
	 */
	@:optional var conditionalEndKeyword: String;

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
	 * (which `declaredTypes` records). A parameter with a NON-null default (`x: T = d`)
	 * projects as the required kind and is non-null; a NULL default (`x: T = null`) is
	 * nullable per Haxe null-safety and is exempted separately via `paramKinds` +
	 * `nullLiteralKind`. `unnecessary-null-check` skips an operand bound to an optional
	 * parameter. Optional; unset disables the skip.
	 */
	@:optional var optionalParamKind: String;

	/**
	 * The node kind of a REST parameter (Haxe `...x: T`, projected as `Rest`), whose
	 * body type is `haxe.Rest<T>` — NOT the written `T`. Lets a check that copies a
	 * parameter's written type source (`explicit-local-type`) exempt a rest parameter,
	 * whose source `T` differs from its effective type. Optional; unset disables the skip.
	 */
	@:optional var restParamKind: String;

	/**
	 * Node kinds whose direct children name a STRUCTURE FIELD rather than a lexical
	 * binding — an anonymous-structure type body and an object literal (Haxe `Anon` /
	 * `ObjectLit`, the latter covering a structure PATTERN `case { x: n }` too). Such a
	 * name is a member of the type / value, reachable only through a receiver, so a
	 * scope-collision proof must not read it as a binding of that name — the same
	 * exclusion `isMemberNamePosition` makes for the dotted `o.x` slot. Optional; unset
	 * leaves the exclusion off.
	 */
	@:optional var structureFieldHostKinds: Array<String>;

	/**
	 * Node kinds that CONTINUE a variable declaration — every binding after the first in
	 * `var a = 1, b = 2;` (Haxe `VarMore`). Each is a declaration node in its own right,
	 * nested right-recursively inside the head declaration, so a consumer enumerating a
	 * statement's bound names must walk the chain rather than read the head's name alone.
	 * Optional; unset means the grammar has no such continuation form.
	 */
	@:optional var localDeclContinuationKinds: Array<String>;

	/**
	 * The null-coalescing operator node kind (`a ?? b`, Haxe `NullCoal`) — the
	 * `redundant-null-coalescing` check flags one whose left operand is provably
	 * non-null (`TypeResolver.isProvablyNonNull`), making the right operand dead.
	 * Optional; unset makes the check a no-op.
	 */
	@:optional var nullCoalesceKind: String;

	/**
	 * The null-coalescing operator TEXT (`??`) — the emitter counterpart of
	 * `nullCoalesceKind`, used by `RefactorSupport.ctorConditionalDefaultFinalEdits`
	 * to build the `<param> ?? <default>` assignment that folds a null-guarded
	 * constructor default into a `final` field. Optional; unset makes that fold a
	 * no-op (and with it the `prefer-final-field` / `prefer-final-public-field`
	 * conditional-default arm), so a grammar without a coalescing operator is
	 * byte-inert.
	 */
	@:optional var nullCoalesceOperatorText: String;

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
	 * The fully-qualified path of the language's canonical exception TYPE — the wrapper a raw
	 * thrown value should be boxed in (Haxe `haxe.Exception`). The `prefer-typed-throw` check
	 * rewrites `throw <string literal>` to `throw new <this type>(<literal>)`, spelling the
	 * reference through `TypeRefPrinter` (short name plus an import when free, else the
	 * fully-qualified path). Optional; unset makes that check a no-op — a grammar without a
	 * canonical exception type has nothing to box into.
	 */
	@:optional var exceptionTypePath: String;

	/**
	 * The fully-qualified path of the type a raw (unboxed) thrown value is WRAPPED in by the
	 * runtime — Haxe's `haxe.ValueException`, the `Exception` subclass its unified-exception
	 * model builds for `throw 'boom'`. A `catch` clause typed this way matches a raw throw but
	 * NOT a boxed one, so `prefer-typed-throw` adds its simple name to the clause types that
	 * degrade the rule to report-only. Optional; unset just drops that one name from the gate.
	 */
	@:optional var rawThrowWrapperTypePath: String;

	/**
	 * The runtime-CHECKED cast node kind (Haxe `cast(x, T)` — `TypedCastExpr`), which does a
	 * runtime type test and throws on mismatch — distinct from the compile-time `(x : T)`
	 * ascription. The `impossible-cast` check reads it. Optional; unset makes the check a no-op.
	 */
	@:optional var checkedCastKind: String;

	/**
	 * The single-argument UNCHECKED cast expression kind — Haxe `cast expr`, no target type
	 * (`CastExpr`) — which performs no runtime test and takes its result type from the CONTEXT
	 * rather than from the expression itself (the checked forms, which carry their own type and
	 * THROW on a non-null mismatch, are `checkedCastKind` / `typedCastKinds`). Two consumers read
	 * it, both off the same "nothing is tested, nothing can throw" fact: it is a transparent
	 * single-child wrapper, so `TypeResolver.isDeletionPure` treats one as pure exactly when its
	 * operand is, and `prefer-comprehension` counts it among the PURE expression kinds its
	 * evaluation-order gates accept. Historically it was also the motivating example of a
	 * LOAD-BEARING type annotation — `final t:T = cast e` is what gives the cast its result type —
	 * but the annotation decision no longer consults this seam: every inlined local keeps its
	 * annotation as an ascription unless the target position provably restates it. Optional; unset
	 * means the wrapper arm never fires (an unchecked cast falls through to the conservative
	 * default) and costs that purity reach.
	 */
	@:optional var uncheckedCastKind: String;

	/**
	 * The compile-time type-check / ascription node kind (Haxe `(x : T)` — `ECheckTypeExpr`),
	 * distinct from the runtime-CHECKED `checkedCastKind`. The `redundant-ascription` check reads
	 * it (with `newExprKind`) to flag a `(new T(...) : T)` whose ascribed type only restates the
	 * construction it wraps. Optional; unset makes the check a no-op.
	 */
	@:optional var checkTypeKind: String;

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
	 * The language's reserved words — identifiers no binding may be named. A check that
	 * DERIVES a new identifier (`no-underscore-prefix` strips a leading `_`) must refuse a
	 * result that lands on one, or it emits source the parser rejects. A naming policy cannot
	 * stand in for this: a policy adapted from a project config carries no normalizer, and
	 * every camelCase format matches `dynamic` / `is` / `macro` just as it matches `event`.
	 * Optional; unset means a deriving check has no reserved-word veto.
	 */
	@:optional var reservedWords: Array<String>;

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
	 * Nominal type names whose `.get(key)` / `.set(key, value)` calls are INTERCHANGEABLE
	 * with index access `x[key]` / `x[key] = value` — Haxe's `Map` ABSTRACT only. Its
	 * `@:arrayAccess` operators back the index syntax; the concrete `haxe.ds.StringMap` /
	 * `IntMap` / `ObjectMap` classes carry `.get` / `.set` but NO array access, so this seam
	 * is narrower than `nullableIndexTypeNames` (which also lists the concrete maps). The
	 * `prefer-index-access` check flags a `get` / `set` call whose receiver's declared
	 * outer-nominal type (via `TypeResolver.identTypeName`, or a `Null<Map<…>>` wrapper
	 * unwrapped from `TypeInfoProvider.declaredTypeSources`) is one of these. Optional; unset
	 * makes the check a no-op.
	 */
	@:optional var mapAbstractTypeNames: Array<String>;

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
	 * Dotted `Type.method` calls asserting their first argument (a boolean
	 * expression) is TRUE — e.g. the test framework's `Assert.isTrue`. When that
	 * argument narrows a plain own-name ident non-null on its truth path
	 * (`u != null`, or a conjunction of such — parens / De-Morgan `!` honoured),
	 * the flow engine clears the ident's `MaybeNull` fact after the call
	 * (`maybe`-only — the six base flow checks are byte-identical, and it never
	 * adds a `NonNull` fact, so it cannot delete a guard), honouring an
	 * `Assert.isTrue(u != null); u.field` precondition. Optional; unset models none.
	 */
	@:optional var assertTrueCalls: Array<String>;

	/**
	 * Dotted `Type.method` calls asserting their first argument (a boolean
	 * expression) is FALSE — e.g. `Assert.isFalse`. The mirror of `assertTrueCalls`:
	 * a plain own-name ident the argument proves non-null when FALSE (`u == null`,
	 * or a disjunction of such) has its `MaybeNull` fact cleared after the call
	 * (`maybe`-only). Optional; unset models none.
	 */
	@:optional var assertFalseCalls: Array<String>;

	/**
	 * Map membership-test method names (`exists`) — inside the then-arm of
	 * `if (m.exists(k))`, a following `var u = m[k]` binding of the SAME map and key
	 * is not seeded `MaybeNull` (`maybe`-only, so the six base flow checks are
	 * unaffected). Optional; unset disables the exists-guard suppression.
	 */
	@:optional var mapExistsMethods: Array<String>;

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
	 * STATEMENT-position `switch` kinds (Haxe `SwitchStmt` / `SwitchStmtBare`) — the
	 * subset of `switchKinds` whose arms need not yield a value, so the arm list need
	 * not be exhaustive. Mirrors the `ifStatementKinds` / `ifExpressionKinds` and
	 * `tryStatementKinds` / `tryExpressionKinds` splits, and exists for the same
	 * reason: a rewrite that is sound on a statement switch can break an expression
	 * one. The `prefer-case-guard` check converts a case body into a case GUARD, and a
	 * guard that evaluates false resumes matching — sound only where the arm list may
	 * leave a value unmatched. Optional; unset makes that check a no-op.
	 */
	@:optional var switchStatementKinds: Array<String>;

	/**
	 * The unary-negation node kind (`Neg`) — a `-1` initializer parses as a negation
	 * wrapping a non-negative literal (`Neg(IntLit 1)`). Lets `prefer-enum-abstract`
	 * see a negative-literal constant (`X_UNKNOWN = -1`) as numeric. Optional; unset
	 * treats a negation-wrapped value as non-numeric.
	 */
	@:optional var negationKind: String;

	/**
	 * Maps a literal-expression node kind to the name of the type it denotes —
	 * `IntLit` gives `Int`, a string-literal kind gives `String`. The `explicit-type`
	 * autofix reads it to annotate a field / parameter whose initializer is a literal
	 * of a statically-certain type. Optional; unset gives the autofix nothing to infer
	 * from literals.
	 */
	@:optional var literalTypeNames: Map<String, String>;

	/**
	 * The array-literal node kind (Haxe `ArrayExpr`, whose children are the element
	 * expressions) — the `explicit-local-type` autofix annotates a local whose
	 * initializer is a NON-EMPTY array literal of one KNOWN literal element type as
	 * `Array<T>` (a non-empty literal pins the element type, so the annotation
	 * re-states the compiler's inference). Optional; unset disables array inference.
	 *
	 * SEAM: `redundant-parens` reads it (with `callKind` / `newExprKind`) as a
	 * SPLICING host — see `spliceSensitiveExprKinds`.
	 */
	@:optional var arrayLiteralKind: String;

	/**
	 * Maps a String method name to the FIXED type its call returns on a String
	 * receiver (`split` → `Array<String>`; `substr` / `substring` / `charAt` /
	 * `toUpperCase` / `toLowerCase` / `toString` → `String`; `indexOf` /
	 * `lastIndexOf` → `Int`). The `explicit-local-type` autofix annotates a local
	 * whose initializer is `recv.method(...)` where `recv` is provably a String — a
	 * string literal, or a variable whose declared type resolves to `String` (a
	 * `Null<String>` narrowed in a guard included) — with the tabled return type. A
	 * method whose return depends on generics / inference (`map` / `filter`) or that
	 * returns a nullable (`charCodeAt` → `Null<Int>`) is deliberately ABSENT, so it
	 * stays report-only — coverage never trumps soundness. Optional; unset disables
	 * the string-receiver method-return inference.
	 */
	@:optional var stringLiteralMethodReturns: Map<String, String>;

	/**
	 * Maps a simple `Type.method` name of a stdlib / macro-API STATIC function to the
	 * FIXED, non-generic type its call returns (`Context.resolvePath` → `String`,
	 * `Context.currentPos` → `haxe.macro.Expr.Position`, `Date.now` → `Date`). The
	 * `explicit-local-type` autofix annotates a local whose initializer is
	 * `Type.method(...)` — the receiver a genuine TYPE reference (not a value binding),
	 * unshadowed by a same-named indexed project type — with the tabled return type; the
	 * display oracle is BLIND inside a macro function, so this table is the only route to a
	 * sound annotation there. A call whose return depends on generics / inference is
	 * deliberately ABSENT, so it stays report-only. Optional; unset disables the
	 * static-method-return inference.
	 */
	@:optional var staticMethodReturns: Map<String, String>;

	/**
	 * Node kinds that constitute a value-returning `return <expr>` — both the statement
	 * form (`ReturnStmt`) and the expression form (`ReturnExpr`, e.g. a `return` inside
	 * a ternary or an expression-bodied function). The `explicit-type` autofix infers a
	 * `: Void` return type only when a function's own scope holds NONE of these; a bare
	 * `return;` (the separate `voidReturnKind`) does not count. Optional; unset disables
	 * the Void return-type inference.
	 *
	 * SEAM: must be a SUPERSET — it has to contain `returnStatementKind`'s kind plus
	 * every expression-form return kind. `explicit-type`'s Void inference (this field)
	 * and `prefer-ternary-return` (`returnStatementKind`) must agree on what a value
	 * return is: a plugin that sets one without the other makes the two checks disagree.
	 */
	@:optional var valueReturnKinds: Array<String>;

	/**
	 * Node kinds that constitute a `throw` (Haxe `ThrowStmt` / `ThrowExpr`). The
	 * `explicit-type` autofix skips its `: Void` inference for a function whose own
	 * scope contains one: a throw-only body unifies with any return type, so
	 * annotating `: Void` would break a caller that uses the call as a value.
	 * Optional; unset disables the throw guard.
	 */
	@:optional var throwKinds: Array<String>;

	/**
	 * The block-body node kind (`BlockBody`) — a function whose body is a `{ … }` block.
	 * The `explicit-type` autofix infers a `: Void` return type only for such functions;
	 * an expression-bodied (`function f() expr;`) or bodyless (interface / extern) member
	 * is left report-only, its return type being uncertain. Optional; unset disables the
	 * Void return-type inference.
	 *
	 * SEAM: must be one of `functionBodyKinds` — the block flavor of that function-body
	 * marker set (`BlockBody`, alongside `ExprBody` / `NoBody`).
	 */
	@:optional var blockBodyKind: String;

	/**
	 * The language's unit / void type NAME exactly as it is written in a return-type
	 * annotation (Haxe `Void`). `guard-return`'s implicit-tail arm compares a function's
	 * DECLARED return type's source text to it to prove that a value-less `return;`
	 * compiles before inserting one. Optional; unset → a function carrying ANY declared
	 * return type is refused and only the un-annotated / no-value-return inference path
	 * remains.
	 */
	@:optional var voidTypeName: String;

	/**
	 * The metadata tag requesting a final class (Haxe `@:final`) — the
	 * `prefer-final-class` check flags it on a class declaration and its `--fix`
	 * replaces the meta with the `final` class modifier. Optional; unset (or a
	 * missing class-decl kind) makes the check a no-op.
	 */
	@:optional var finalClassMetaName: String;

	/**
	 * The plain class-declaration node kind (Haxe `ClassDecl`) — a `finalClassMetaName`
	 * meta on one is a `@:final class` the modifier replaces; the `prefer-final-class`
	 * fix removes the meta and inserts `final ` before the class keyword. Optional.
	 */
	@:optional var plainClassDeclKind: String;

	/**
	 * The already-`final` class-declaration node kind (Haxe `FinalDecl`, the `final
	 * class` projection) — a `finalClassMetaName` meta on one is a REDUNDANT `@:final
	 * final class`; the `prefer-final-class` fix removes the meta only. Optional.
	 */
	@:optional var finalClassDeclKind: String;

	/**
	 * The member-host kind of a `final`-modified method (Haxe `FinalModifiedMember`).
	 * The grammar folds a method's `final` modifier into this wrapper instead of
	 * emitting it as a sibling modifier node, and nests any modifier written after
	 * `final` as the wrapper's children. The `modifier-order` check ranks the
	 * wrapper's leading `final` keyword by `finalModifierRankKind` and treats those
	 * nested modifiers as the tail of the modifier run, so `final` is enforced last
	 * (`override -> public/private -> static -> inline -> final`). Optional; unset
	 * makes the check ignore method `final`.
	 */
	@:optional var finalModifierMemberKind: String;

	/**
	 * The sentinel entry in `modifierOrderKinds` that ranks a `final`-modified
	 * method's `final` keyword. No real node carries this kind — the `final` modifier
	 * is folded into `finalModifierMemberKind` — so it exists only to give `final` a
	 * rank in the order table. Optional; paired with `finalModifierMemberKind`.
	 */
	@:optional var finalModifierRankKind: String;

	/**
	 * The `break` statement node kind — lets `prefer-find` confirm the second statement
	 * of a `{ r = x; break; }` first-match loop body is a `break` (not a `continue`,
	 * which finds the last match). Optional; unset disables `prefer-find`'s break form.
	 */
	@:optional var breakStatementKind: String;

	/**
	 * The `continue` statement node kind (Haxe `ContinueStmt`) — lets `loop-guard`
	 * recognise a leading `if (c) continue;` loop-body guard. Optional; unset makes the
	 * check a no-op.
	 */
	@:optional var continueStatementKind: String;

	/**
	 * Loop-statement kinds whose LAST child is the loop body (Haxe `ForStmt` /
	 * `WhileStmt`) — `loop-guard` reads the body off the last child to flag a leading
	 * `if`-continue guard liftable to the loop header. A `do … while` is excluded (its
	 * body is not the last child). Optional; unset makes the check a no-op.
	 */
	@:optional var loopStatementKinds: Array<String>;

	/**
	 * Loop-statement kinds whose FIRST child is the loop body and whose condition is
	 * the LAST child (Haxe `DoWhileStmt`, the `do … while` form) — the body-first
	 * counterpart of `loopStatementKinds`. The `guard-continue` check reads the body
	 * off `children[0]` to de-nest a trailing `if (c) { … }` into an `if (!c) continue;`
	 * guard. Optional; unset makes `guard-continue` skip do-while loops.
	 */
	@:optional var doWhileLoopKinds: Array<String>;

	/**
	 * The range / interval node kind (`a...b`) — lets `prefer-find` skip a loop over a
	 * range: its `IntIterator` is not an `Iterable`, so a `Lambda.find` rewrite would
	 * not compile. Optional; unset means range loops are not specially excluded.
	 */
	@:optional var intervalKind: String;

	/**
	 * The `while` statement node kind (Haxe `WhileStmt`) — lets `prefer-range-loop`
	 * recognise a `while (i < B)` counter loop adjacent to its `var i = A;`
	 * declaration. Optional; unset makes the check a no-op.
	 */
	@:optional var whileStmtKind: String;

	/**
	 * The strict less-than comparison node kind (Haxe `Lt`) — `prefer-range-loop`
	 * flags only the `i < B` condition form (`<=` / reversed / `!=` are not an
	 * `A...B` range). Optional; unset makes the check a no-op.
	 */
	@:optional var ltKind: String;

	/**
	 * The post-increment node kind (Haxe `PostIncr`, `i++`) — `prefer-range-loop`
	 * requires the loop body's trailing statement to be exactly `i++`. Optional;
	 * unset makes the check a no-op.
	 */
	@:optional var postIncrKind: String;

	/**
	 * Top-level type-declaration kinds that constitute a documentable public API
	 * surface (Haxe `ClassDecl` / `FinalDecl` / `AbstractClassDecl` / `AbstractDecl`
	 * / `InterfaceDecl` / `EnumDecl` / `TypedefDecl`). The `doc-coverage` check flags
	 * one declared at module scope without a leading doc comment (unless a preceding
	 * `private` modifier makes it module-private). Optional; unset makes the check's
	 * type-level requirement a no-op.
	 */
	@:optional var typeDeclKinds: Array<String>;

	/**
	 * The module's own package / namespace declaration kind (Haxe `PackageDecl`) — the
	 * ONE top-level child that names the module rather than importing into it, and always
	 * its first. `misplaced-type-doc` uses it to tell a FILE header (a block above the
	 * package statement, which belongs to the file) from a doc written for the module's
	 * type but stranded above the imports. Optional; unset makes that check a no-op.
	 */
	@:optional var packageDeclKind: String;

	/**
	 * Member-host container kinds whose members are IMPLICITLY public (Haxe
	 * `InterfaceDecl`) — as opposed to `visibilityContainerKinds`, where a member is
	 * public only with an explicit `public` modifier. The `doc-coverage` check treats
	 * every member of one of these as public API. Optional; unset means no such
	 * container exists.
	 */
	@:optional var interfaceDeclKinds: Array<String>;

	/**
	 * The public-visibility modifier kind (Haxe `Public`) — the entry of
	 * `visibilityModifierKinds` that grants public access. The `doc-coverage` check
	 * treats a `visibilityContainerKinds` member whose modifier run carries one as
	 * public API. Optional; unset makes the check treat class/abstract members as
	 * never explicitly public.
	 */
	@:optional var publicModifierKind: String;

	/**
	 * Type-declaration kinds that are PLAIN CLASSES — nominal types with no
	 * implicit-conversion semantics (no `@:from` casts, no aliasing), as they
	 * appear in the `SymbolIndex` (Haxe `ClassDecl`; a `final class` is
	 * normalised to it by `typeDeclOf`). `FieldWriteIndex.hasUnresolvedWriteTargeting`
	 * frees a candidate field only when its declared type resolves to exactly one
	 * of these — any other kind (abstract, interface, typedef, enum) could accept
	 * a builtin-typed value through an implicit conversion or aliasing, so the
	 * candidate stays poisoned. Optional; unset disables the targeting bail.
	 */
	@:optional var classDeclKinds: Array<String>;

	/**
	 * Maps a container type's SIMPLE name to the index of the type parameter that
	 * its index-access `x[k]` yields (Haxe `Map<K, V>` → 1, `Array<T>` → 0).
	 * `FieldWriteIndex` uses it to resolve the receiver of a
	 * `container[key].field = …` write to the container's ELEMENT type. Only
	 * containers whose index access provably yields the listed parameter belong
	 * here; any other container type leaves the write unresolved. Optional; unset
	 * makes every index-access receiver unresolved.
	 */
	@:optional var indexedElementTypeParams: Map<String, Int>;

	/**
	 * Scope-introducing node kinds whose OWN name binds the ITERATION KEY-OR-ELEMENT and whose
	 * FIRST NON-BINDER child is the iterable expression (Haxe `ForStmt` / `ForExpr`). Lets a
	 * consumer answer the type of a `for` binder, which no `:Type` annotation covers: the binder
	 * has none, so `TypeInfoProvider.declaredTypes` has no entry for it and the element type can
	 * only come from the iterable.
	 *
	 * "First NON-binder child" rather than `children[0]`: a key-value iteration carries its VALUE
	 * binder as an `iterationValueBinderKinds` node ahead of the iterable, so a consumer that
	 * indexes `children[0]` blindly reads the binder where it wanted the iterable.
	 *
	 * DISTINCT from the singular `forStmtKind`, which names the STATEMENT kind
	 * `redundant-map-iter-key` reads a discarded key off: this is the BINDER question, so it
	 * also lists the comprehension / expression form of the loop, whose binder scopes exactly
	 * the same way. Optional; unset makes the for-binding element-type arm a no-op (every
	 * binder stays unresolved, which is the conservative direction).
	 */
	@:optional var iterationBindingKinds: Array<String>;

	/**
		 * Node kinds carrying the VALUE binder of a key-value iteration — the `v` in Haxe's
		 * `for (k => v in m)` (`KeyValueBinder`). The node is a direct child of an
		 * `iterationBindingKinds` loop, sits BEFORE the iterable child, carries the bound name on
		 * itself and spans exactly that identifier.
		 *
		 * Two independent jobs. A consumer reading the loop's OPERANDS must skip these to reach the
		 * iterable (see `iterationBindingKinds`). A consumer collecting BOUND NAMES must include
		 * them: the loop node's own `name` is the KEY only, so a scan keyed on it alone misses every
		 * value binder — the blindness that made shadow scans read the loop's header TEXT instead.
		 *
		  * Optional; unset means the grammar has no separate value binder. OBLIGATION on a grammar that
	 * DOES have key-value iteration: publish the kind here. Consumers read an unset field as "no
	 * loop binds two names", so a grammar that binds two and names neither kind here leaves them
	 * unable to tell a KEY binder from a VALUE one — and the element-type arm
	 * (`iterationElementTypeParams`) would then type a key as the element and license a rewrite on
	 * it. Unset is only safe when no loop in the grammar binds a second name.
	 */
	@:optional var iterationValueBinderKinds: Array<String>;

	/**
	  * Maps a container type's SIMPLE name to the index of the type parameter a `for` iteration
	 * over it YIELDS (Haxe `Array<T>` → 0, `Map<K, V>` → 1, since iterating a map yields its
	 * VALUES). Only containers whose iteration provably yields the listed parameter belong
	 * here; any other container leaves the binder unresolved.
	 *
	 * The same entry answers for a key-value loop's VALUE binder, which is the same yield — so an
	 * entry is admissible only when the container's single-binder element type and its key-value
	 * VALUE type coincide. They can diverge in principle (a type is free to declare unrelated
	 * `iterator()` and `keyValueIterator()`), and a consumer of this map may license a rewrite off
	 * the answer, so a divergent container must be left out rather than approximated.
	 *
	 * A DIFFERENT question from `indexedElementTypeParams`, which answers what INDEX ACCESS
	 * `x[k]` yields. The two happen to agree on the three container names they share, but the
	 * questions are independent — a container can be iterable without being indexable and vice
	 * versa — so they must not be merged. Optional; unset makes the for-binding element-type
	 * arm a no-op.
	 */
	@:optional var iterationElementTypeParams: Map<String, Int>;

	/**
	 * Expression kinds whose SUBTREE escapes the type system (Haxe `untyped` —
	 * `UntypedExpr`). A write inside one has neither a trustworthy receiver type
	 * nor a trustworthy RHS type, so `FieldWriteIndex` treats the subtree like an
	 * opaque reification: every write target there is an unresolved write with an
	 * unknown RHS. Optional; unset means no such escape hatch exists.
	 */
	@:optional var untypedKinds: Array<String>;

	/**
	 * Case-pattern BINDER kinds that carry the bound name on the node itself with
	 * no identifier child (Haxe `case var x:` — `Capture`). Pattern binders are
	 * invisible to the scope resolver, so `FieldWriteIndex` collects these names
	 * (with every name inside a `plainCasePatternKind` subtree) as potential
	 * shadowers that disable identifier-receiver resolution for the file.
	 * Optional; unset means only `plainCasePatternKind` subtrees are scanned.
	 */
	@:optional var casePatternBinderKinds: Array<String>;

	/**
	 * Case-pattern node kinds that EVALUATE an expression while MATCHING — the Haxe
	 * extractor `Arrow` (`case f(_) => p:` calls `f` on the subject, then matches `p`
	 * against the result). A rewrite that makes a previously-unreachable arm reachable
	 * has to refuse these: reaching one newly RUNS its expression, exactly what a case
	 * guard would. Optional; unset models a family whose patterns evaluate nothing.
	 */
	@:optional var casePatternExtractorKinds: Array<String>;

	/**
	 * Type-declaration kinds with ALIASING semantics — a value's field access does
	 * not target the declared name itself: a typedef (an alias of another type) and
	 * an abstract (whose `@:forward` field access reaches the UNDERLYING type).
	 * `FieldWriteIndex` refuses to record a resolved write under such an owner —
	 * the write would be filed away from the type it actually mutates — and falls
	 * back to the unresolved bail. Optional; unset rejects nothing.
	 */
	@:optional var aliasingDeclKinds: Array<String>;

	/**
	 * Node kinds EVERY child of which sits in a DELIMITED expression slot — one the
	 * surrounding construct bounds on both sides with its own hard tokens (bracket,
	 * separator, terminator or keyword) and parses at the loosest precedence, so no
	 * operator can bind across the boundary. A lone `parenKind` node there cannot be
	 * load-bearing and `redundant-parens` flags it. Haxe: the var / final
	 * initializer hosts (`VarStmt` / `FinalStmt` / `VarExpr` / `FinalExpr` /
	 * `VarMember` / `FinalMember` — `= expr` up to `;` or `,`), the value returns
	 * (`ReturnStmt` / `ReturnExpr` — the `return` keyword parses its value as a full
	 * expression), the array / map literal (`ArrayExpr` — `[` `,` … `,` `]`), the
	 * object-literal field (`Field` — `:` … `,` or `}`), `new T(args)`
	 * (`NewExpr`) and the `${ … }` string interpolation (`Block` — `${` … `}`,
	 * whose one expression child the compiler slices out on brace count and parses
	 * standalone). A host may also carry non-expression children (a type annotation,
	 * a type argument); those never project as `parenKind`, so listing the host is
	 * still exact. Read by `redundant-parens` and by `prefer-ternary-expression`, which asks
	 * the same question from the other side — a bare `?:` may only LAND in such a slot.
	 * Optional; unset leaves `redundant-parens` with only its double-paren arm and makes
	 * `prefer-ternary-expression` (with `delimitedTailChildKinds` / `parenKind` also unset)
	 * accept no slot at all, i.e. inert.
	 */
	@:optional var delimitedAllChildKinds: Array<String>;

	/**
	 * Node kinds whose children are delimited EXCEPT the first — a head plus a
	 * delimited tail. Haxe: `Call` (the callee at child 0 is NOT delimited —
	 * `(a ? b : c)(x)` needs its parens — while every argument after it is bounded
	 * by `(` / `,` … `,` / `)`), `IndexAccess` (the receiver at child 0 is likewise
	 * an operand position, while the index at child 1 is bounded by the `[` and `]`
	 * themselves and parses at the loosest precedence — `arr[untyped i]`,
	 * `arr[if (c) 1 else 2]`, `arr[@:privateAccess q.v]` all compile bare), and the
	 * assignment family (`Assign` and the compound `*Assign` forms: the target at
	 * child 0 is an operand position, the right-hand side is not — those operators
	 * are the loosest precedence tier AND right-associative, so their right operand
	 * is parsed as a full expression that already reaches the slot's terminator).
	 * Read by `redundant-parens` together with `delimitedAllChildKinds`, and by
	 * `prefer-ternary-expression` for the slot a bare `?:` may land in (child 0
	 * excluded there too). Optional; unset lists no such host.
	 */
	@:optional var delimitedTailChildKinds: Array<String>;

	/**
	 * Expression kinds whose own syntax can CONSUME the separator that ends a
	 * delimited slot, so a `parenKind` wrapping one must KEEP its parentheses even
	 * there. Haxe: the expression-position declarations `VarExpr` / `FinalExpr` —
	 * their multi-declaration form (`var a = 1, b = 2`) reaches past the `,` that
	 * separates a call argument, an array element, an object field or a second
	 * declarator. The reachable case in practice is a `macro` quotation around one,
	 * which re-enters the unrestricted expression parse that allows the
	 * continuation: `f((macro final w = 1), x)` unwrapped becomes
	 * `f(macro final w = 1, x)`, where the compiler reads `x` as a second declarator
	 * and rejects the whole call.
	 *
	 * The hazard is positional, not structural: it exists only while the greedy
	 * construct is the RIGHTMOST thing inside the parens, with no bracket of its own
	 * closing after it. `redundant-parens` therefore walks the interior's LAST child
	 * while that child ends where its parent ends — which reaches through a metadata
	 * wrapper (`@:m macro final w = 1`), a ternary / `if`-`else` whose last branch is
	 * one, and a trailing binary operand, and correctly stops at a bracket-closed
	 * host (`q(macro final w = 1)`, `[macro final w = 1]`, `{k: macro final w = 1}`),
	 * whose closing token already bounds the construct. Optional; unset excludes
	 * nothing.
	 */
	@:optional var separatorGreedyExprKinds: Array<String>;

	/**
	 * Expression kinds whose meaning is POSITION-SENSITIVE — the construct expands to
	 * a different ARITY when it is directly an argument / element of a splicing host
	 * than when anything, a `parenKind` included, wraps it. Removing that paren is a
	 * silent rewrite: it changes the call, not the syntax, so nothing rejects it.
	 * Haxe: `DollarReifExpr`, the `$x{…}` macro-reification kind. Its `$a{}` form
	 * splices an `Array<Expr>` into the surrounding argument / element list, so
	 * `macro g(($a{args}))` builds a ONE-argument call and `macro g($a{args})` a
	 * two-argument one; wrapping it in a paren is what suppresses the splice.
	 *
	 * `redundant-parens` tests it at the paren's DIRECT child, and only in the slots
	 * of a splicing host — the existing `callKind` / `arrayLiteralKind` /
	 * `newExprKind` seams. Nothing else splices, so an object-literal field value or
	 * a var initializer is left to the ordinary rules. The sibling `$b{}` / `$v{}` /
	 * `$i{}` / `$p{}` forms share this one kind and are arity-neutral, so listing the
	 * kind is deliberately conservative there: it costs a missed cleanup, never a
	 * wrong rewrite. Optional; unset excludes nothing.
	 */
	@:optional var spliceSensitiveExprKinds: Array<String>;

	/**
	 * Expression kinds that bind STRICTLY TIGHTER than the ternary `?:` operator, so a
	 * `parenKind` wrapping one as a ternary CONDITION (`(e) ? a : b`) is redundant —
	 * unwrapping it re-parses to the same tree. A fail-closed WHITELIST: a kind absent
	 * from it keeps its parentheses, because the loose / right-greedy kinds (assignment,
	 * a nested ternary, an arrow lambda, `untyped` / `macro` / a metadata wrapper, a
	 * block-like `if` / `switch` expression) would otherwise ABSORB the `? … : …` on
	 * unwrap and change the parse. Haxe: the comparison / boolean / null-coalescing /
	 * arithmetic / bitwise / shift binary operators, the interval and `is` operators,
	 * the unary prefixes and in/decrement, and the primary atoms (identifier, literal,
	 * call, field / index access, array literal, `new`). Object literals and casts are
	 * deliberately omitted (a leading `{` is block-ambiguous; a cast condition is rare)
	 * — both cost only a missed cleanup.
	 *
	 * TWO consumers, asking two related questions of one list. `redundant-parens` reads it
	 * with `ternaryKind` for the CONDITION slot (which ends at the `?`);
	 * `prefer-ternary-expression` reads it for the two ARM slots (which end at the `:` and at
	 * the enclosing terminator), where the property needed is "no unsealed top-level `:`" and
	 * "not separator-greedy". Both hold for every kind listed, but the two properties are NOT
	 * the same: an object literal is a safe ARM (`c ? {k: 1} : {k: 2}` compiles) yet is
	 * excluded for the condition's leading-`{` ambiguity, and a hypothetical unsealed-`:`
	 * kind would be a fine condition and a broken arm. Split the list before adding a kind
	 * that satisfies only one side.
	 *
	 * Optional; unset drops `redundant-parens`' ternary-condition arm AND makes
	 * `prefer-ternary-expression` a no-op (it has no other source of accepted branch kinds).
	 */
	@:optional var ternaryConditionUnwrapKinds: Array<String>;

	/**
	 * Expression kinds that are ATOMIC on their own — SELF-DELIMITING, so no operator
	 * outside can bind into them and a `parenKind` wrapping one is inert in EVERY
	 * expression position. Their children, if any, are internal structure rather than
	 * operands and are NOT re-examined: a Haxe single-quoted string projects its
	 * segments and its `${…}` interpolations as children, all of them sealed inside the
	 * quotes. Haxe: `IdentExpr` (`this` included — the grammar spells it as an
	 * identifier) and the int / float / hex / bool / null / string literals.
	 *
	 * `RegexLit` is deliberately ABSENT: it ends in `/`, which welds onto a following
	 * `/` into a line comment (`(~/x/)/a` -> `~/x//a`). Read by `redundant-parens` for
	 * its opt-in `atoms` arm, with `atomChainKinds`; optional, unset drops that arm.
	 */
	@:optional var atomExprKinds: Array<String>;

	/**
	 * Expression kinds that are TRANSPARENT LINKS — atomic exactly when every child is
	 * itself atomic, which is what admits a whole dotted chain (`a.b.c`) as one atom
	 * while rejecting a chain broken by something that is not (`f().b`, `arr[i].b`).
	 * Haxe: `FieldAccess`.
	 *
	 * Deliberately ABSENT: `Call` / `IndexAccess` (an argument or index subtree is not
	 * part of the name, and a call is not a pure read) and `SafeFieldAccess` — `(a?.b).c`
	 * and `a?.b.c` disagree on what the null short-circuit covers, so the pair is
	 * load-bearing. Read by `redundant-parens` with `atomExprKinds`; optional, unset
	 * leaves the atom vocabulary to the self-delimiting kinds alone.
	 */
	@:optional var atomChainKinds: Array<String>;

	/**
	 * Groups of binary operator kinds that share ONE precedence tier and associate to
	 * the LEFT. Within a group the grammar already parses `a OP1 b OP2 c` as
	 * `(a OP1 b) OP2 c`, so a `parenKind` around the LEFT operand of a group member
	 * whose content is another member of the SAME group re-parses to the identical
	 * tree. Haxe: `['Mul', 'Div']` and `['Add', 'Sub']`.
	 *
	 * `Mod` is deliberately in NO group: Haxe binds `%` tighter than `*` and `/`
	 * (`2 * 7 % 4` evaluates to 6, i.e. `2 * (7 % 4)`), and the Haxe grammar models that
	 * as a prec-10 tier of its own for `%` — so `%` shares a tier with no other operator
	 * and no group can hold it. A single-member `['Mod']` group would be sound but is not
	 * admitted. Read by `redundant-parens` for its opt-in
	 * `sameOperatorLeft` arm; optional, unset drops that arm. The RIGHT operand is never
	 * a candidate under any grouping — `a / (b * c)` is a different computation.
	 */
	@:optional var leftAssociativeBinaryFamilies: Array<Array<String>>;

	/**
	 * Binary operator kinds of the COMPARISON tier — the hosts whose parenthesized
	 * operands the opt-in `redundant-parens` arm `comparisonOperands` may unwrap. Haxe:
	 * `Eq`, `NotEq`, `Lt`, `LtEq`, `Gt`, `GtEq` — the six `@:infix(…, 5)` ctors that
	 * compare two VALUES.
	 *
	 * NOT the same list as `comparisonKinds` above, and not interchangeable with it:
	 * that one names the operators for which IDENTICAL OPERANDS are suspicious
	 * (`identical-operands`) and therefore includes the boolean `&&` / `||`, which are a
	 * looser tier and would be wrong hosts here. This one is a PRECEDENCE fact
	 * confined to one tier's value comparisons.
	 *
	 * The tier's two other members are deliberately ABSENT. `Is` takes a TYPE on its
	 * right, so its operand slots are not symmetric and a paren on that side is not an
	 * expression pair at all; `Interval` spells its operator `...`, which abuts the `.`
	 * lexing of a numeric literal or a field access on either side, an edge this check
	 * has no reason to walk into. Both cost a missed cleanup, never a wrong rewrite.
	 * Read by `redundant-parens` with `comparisonOperandUnwrapKinds`; optional, unset
	 * drops that arm.
	 */
	@:optional var comparisonOperandHostKinds: Array<String>;

	/**
	 * The ARITHMETIC CORE of the kinds that bind strictly tighter than the comparison
	 * tier: those that also parse identically across the C-family languages, so a
	 * `parenKind` wrapping one as an operand of a `comparisonOperandHostKinds` operator
	 * is redundant on every reading. A fail-closed WHITELIST in the manner of
	 * `ternaryConditionUnwrapKinds`: a kind absent from it keeps its parentheses. Haxe:
	 * the arithmetic `Add` / `Sub` (tier 8), `Mul` / `Div` (tier 9) and `Mod` (tier 10).
	 * The unary `Neg` is NOT on it — `unaryMinusKinds` refuses a leading minus at any
	 * depth, which subsumes the bare `Neg` root.
	 *
	 * A DELIBERATE SUBSET, not an exhaustive one — the tighter-binding kinds left out are
	 * choices, each for its own reason. The BITWISE kinds (`BitAnd` / `BitOr` / `BitXor`,
	 * tier 6) are out for CORRECTNESS: Haxe binds them tighter than a comparison but C
	 * binds `&` / `|` / `^` LOOSER than `==` and `!=`, so `(x & m) != 0` reads
	 * differently there once the pair is gone, and that pair is cross-language insurance
	 * an author writes on purpose. The SHIFT kinds (`Shl` / `Shr` / `UShr`, tier 7) bind
	 * tighter than a comparison in C exactly as they do here and WOULD be provable on
	 * both readings; they are out on READABILITY alone, since a shift operand is
	 * habitually parenthesized. The remaining unary and primary kinds
	 * (`Not` / `BitNot` / the in/decrements, and the atoms) are out because this arm has
	 * no need of them: `atoms` owns the atomic content and the two arms converge over
	 * `lint --fix` passes, while the rest buy a rarity. Admitting any of them later is
	 * additive and breaks nothing. Read by `redundant-parens` with
	 * `comparisonOperandHostKinds`; optional, unset drops that arm.
	 */
	@:optional var comparisonOperandUnwrapKinds: Array<String>;

	/**
	 * Binary operator kinds of the ADDITIVE tier — the hosts whose parenthesized operands
	 * the opt-in `redundant-parens` arm `additiveOperands` may unwrap. Haxe: `Add` and
	 * `Sub`, the two `@:infix(…, 8)` ctors.
	 *
	 * The additive tier ALONE, deliberately — never the multiplicative one just above it.
	 * Haxe binds `%` a whole tier tighter than `*` and `/`, so `a * (b % c)` would be
	 * provable HERE; but C makes the three ONE tier, where a bare `a * b % c` reads
	 * `(a * b) % c`, so the pair is what makes the two readings agree. The same class of
	 * cross-language trap as the bitwise exclusion on `comparisonOperandUnwrapKinds`, and
	 * kept out the same way. The bitwise and shift tiers are not hosts either, and NOT
	 * because a drop there would be wrong — `(a * b) & c` bare re-parses to the tree it
	 * already had, in this language and in C alike. They are out on the same READABILITY
	 * ground that keeps the shift tier off `comparisonOperandUnwrapKinds`: a bitwise or
	 * shift operand is habitually parenthesized. Admitting either later is additive and
	 * breaks nothing. Read by `redundant-parens` with `additiveOperandUnwrapKinds`;
	 * optional, unset drops that arm.
	 */
	@:optional var additiveOperandHostKinds: Array<String>;

	/**
	 * The kinds binding STRICTLY tighter than the additive tier that also parse alike
	 * across the C family, so a `parenKind` wrapping one as an operand of an
	 * `additiveOperandHostKinds` operator is redundant on every reading. A fail-closed
	 * WHITELIST in the manner of `comparisonOperandUnwrapKinds`: a kind absent from it
	 * keeps its parentheses. Haxe: `Mul` / `Div` (tier 9) and `Mod` (tier 10) — C agrees
	 * that all three bind tighter than `+` and `-`, which is what the `%` exclusion on the
	 * HOST side does not get to assume.
	 *
	 * The SAME-TIER kinds (`Add` / `Sub`) are the reason this is a whitelist rather than a
	 * tier test: dropping the pair around one RE-ASSOCIATES the expression
	 * (`a + (b - c)` becomes `(a + b) - c`), a different rounding for floats and a
	 * different value outright under `-`. The unary `Neg` IS provable — `a - (-b)` binds
	 * the same either way — and is out on READABILITY alone, since the bare form reads
	 * `a - -b`. Everything looser (bitwise, shift, comparison and below) is excluded by
	 * construction: such content re-associates outward on unwrap. Read by
	 * `redundant-parens` with `additiveOperandHostKinds`; optional, unset drops that arm.
	 */
	@:optional var additiveOperandUnwrapKinds: Array<String>;

	/**
	 * Expression kinds that CAPTURE EVERYTHING TO THEIR RIGHT — a construct whose extent
	 * ends only where its enclosing bracket does, so a `parenKind` around content that
	 * ends in one is load-bearing however tight the content's ROOT binds. Haxe: the
	 * prefix keywords whose operand is a whole expression (`untyped`, `macro`, `cast`,
	 * `throw`, `return`, `inline`, a metadata annotation), the function literals and
	 * arrow lambdas, the block-like expressions whose trailing branch is open
	 * (`if … else`, `for`, `while`, `try … catch`) and the ternary's else branch.
	 *
	 * Read by `redundant-parens` for EVERY precedence-gated slot — the three opt-in
	 * operand arms and the shipped, default-on ternary condition — because all four judge
	 * the content's root kind alone: `a + (b * untyped c) - d` has an arithmetic root over
	 * a tail that swallows the `- d` (measured against the compiler: 9 with the pair, 7
	 * without). The DELIMITED slots do not need it; their own separator bounds the capture,
	 * which is what the narrower `separatorGreedyExprKinds` is for.
	 *
	 * ERR INCLUSIVE. A kind wrongly listed costs a missed cleanup; a kind wrongly omitted
	 * is a rewrite that changes the parse, and the tree-shape oracle CANNOT catch it —
	 * this parser's own model of `cast` and of a metadata annotation disagrees with the
	 * compiler about exactly this extent, so both trees look equivalent while the real
	 * ones are not. Optional; unset leaves every slot judging the root alone.
	 */
	@:optional var rightGreedyExprKinds: Array<String>;

	/**
	 * The UNARY MINUS kinds. Content whose leftmost token is one of them keeps its
	 * parentheses in the `comparisonOperands` / `additiveOperands` slots, whatever its
	 * root: `a + (-b * c)` has a `Mul` root and still reads `a + -b * c` bare, the defect
	 * those arms exclude a bare `Neg` root for. Haxe: `Neg`.
	 *
	 * A READABILITY gate, not a correctness one — every such drop is provable. Read by
	 * `redundant-parens`; optional, unset judges the root alone, which is what those arms
	 * did before.
	 */
	@:optional var unaryMinusKinds: Array<String>;

	/**
	 * Kinds that PREFIX an expression with an annotation binding to whatever that
	 * expression starts with. A `parenKind` on the LEFT EDGE beneath one is what holds the
	 * annotation over its own content, so it keeps its parentheses. Haxe: `MetaExpr` (the
	 * `@:m expr` wrapper; the `@:m(args)` annotation itself is a `MetaCall` CHILD of it,
	 * and its arguments are the separate concern `parenRequiredHostKinds` covers).
	 *
	 * A CORRECTNESS gate rather than an operand-arm concern, so it is read whether or not a
	 * project opted an arm in: this parser models `@:m` as wrapping everything that
	 * follows, while the compiler binds it to the immediate primary, and the difference is
	 * a compile error (`@:privateAccess (A.s * B.s) + 1` compiles, the bare form does not).
	 *
	 * NOT the same list as `parenRequiredHostKinds`, and deliberately narrower. That one
	 * answers for a DIRECT paren child and holds statement hosts (`CaseBranch`, the
	 * `switch` subjects) whose header ends in a hard token — nothing binds across a
	 * `case … :`, so a pair further inside is ordinary. Reading this rule off that list
	 * instead measurably over-suppressed: two corpus ternary conditions written as
	 * `case _: (v <= 2) ? a : b;` stopped being reported. Optional, unset excludes nothing.
	 */
	@:optional var prefixAnnotationKinds: Array<String>;

	/**
	 * Host kinds whose DIRECT `parenKind` child keeps its parentheses — either the
	 * grammar requires the pair there or the project declines to own the idiom. Haxe:
	 * `CaseBranch` (its direct paren child is the mandatory `case X if (g)` guard — a
	 * branch BODY arrives wrapped in a statement kind, so it is still reached),
	 * the `switch` subject kinds (the construct carries its own `(` `)`, so a paren
	 * child there is a second pair whose presence is a style choice), and the metadata
	 * kinds (`MetaCall` arguments, a `MetaExpr` annotated expression).
	 *
	 * Read by `redundant-parens` for a DIRECT `parenKind` child and, for the metadata
	 * kinds, along the LEFT EDGE of the annotated expression: this parser models `@:m`
	 * as wrapping everything that follows, while the compiler binds it to the immediate
	 * primary, so `@:privateAccess (a * b) + c` needs its pair to hold the annotation over
	 * the multiplication (measured: the bare form fails with `Cannot access private
	 * field`). That makes this list a CORRECTNESS gate for the shipped, default-on arms
	 * rather than an operand-arm concern, so — unlike `parenOpaqueSubtreeKinds` — it is
	 * read whether or not a project opted an arm in. Optional, unset excludes nothing.
	 */
	@:optional var parenRequiredHostKinds: Array<String>;

	/**
	 * Kinds whose ENTIRE SUBTREE the opt-in `redundant-parens` operand arms leave alone,
	 * because a parenthesis inside is not merely grouping. Haxe: `MacroExpr` — inside a
	 * quotation a pair reifies as an `EParenthesis` node, so dropping it rewrites the
	 * expression the macro builds with nothing rejecting it — and `Plain`, the case
	 * PATTERN body, whose syntax is matched structurally rather than by expression
	 * precedence. Optional; unset suppresses nothing.
	 */
	@:optional var parenOpaqueSubtreeKinds: Array<String>;
}
/**
 * Plugin-declared contract for `apq meta`: `metaKinds` are the `QueryNode.kind` values a metadata annotation carries, and `declHostKinds` the kinds that may host one. The meta walker reads these slots and never inspects grammar-specific node types.
 */
@:nullSafety(Strict)
typedef MetaShape = {
	var metaKinds: Array<String>;
	var declHostKinds: Array<String>;
}

/**
 * The writer's layout numbers for one config (`GrammarPlugin.layoutMetrics`).
 * `lineWidth` is the target column a rendered line should not exceed;
 * `indentWidth` is how many columns ONE indent character occupies (a tab's
 * `tabWidth`, or the space-indent size), so a caller can convert a source
 * position into a column without knowing the grammar's indent style.
 */
@:nullSafety(Strict)
typedef LayoutMetrics = {
	final lineWidth: Int;
	final indentWidth: Int;
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

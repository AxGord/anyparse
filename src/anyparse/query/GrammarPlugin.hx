package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;

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

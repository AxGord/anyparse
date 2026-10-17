package anyparse.grammar.haxe;

import anyparse.format.IndentChar;
import anyparse.format.comment.CommentInventory;
import anyparse.format.comment.CommentLossException;
import anyparse.format.comment.FormatterOff;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CondBranchProjection;
import anyparse.query.CondDirectives;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.ParseGate;
import anyparse.query.ParsedRootProvider;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SpanTypeInfoProvider;
import anyparse.query.StdResolver;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeSyntax;
import anyparse.runtime.BodySkip;
import anyparse.runtime.ParseError;
import anyparse.runtime.Parser;
import anyparse.runtime.StringInput;
import haxe.Exception;

using Lambda;

/**
 * Haxe grammar binding for the `apq` query engine.
 *
 * Parses with the macro-generated span-mode `HaxeModuleSpanParser` and
 * translates the typed AST into a generic `QueryNode` tree using
 * runtime type introspection (`Type` / `Reflect`). The span-mode parser
 * returns the paired `HxModuleS` typed AST directly — each enum value
 * carries its own `_span:Span` as the trailing positional arg
 * (`SpanTypeSynth` synthesises these on every Alt ctor).
 *
 *  - **Enum values become nodes.** `kind` is the constructor name
 *    verbatim (`ClassDecl`, `FnDecl`, `IfStmt`, …). The span is read
 *    directly from the value's last positional arg (post-Phase-2:
 *    in-AST instead of side-channel) so Reflect ordering of struct
 *    fields can no longer desynchronise span attribution.
 *  - **Anonymous structs are transparent.** Their fields contribute
 *    children to the enclosing enum-ctor node. A struct's `name` field
 *    (when a String) becomes the parent ctor's `name` slot.
 *  - **Arrays are transparent.** Their elements contribute children.
 *  - **Trivial-mode wrappers** (`{ node:T, leadingComments:…, … }`) are
 *    transparent on the `node` slot; the span-mode parser does not
 *    produce them, but the descent is in place for a future Trivia +
 *    Spans composition.
 *  - **Primitive leaves** (`String`/`Int`/`Float`/`Bool`/`Span`) do not
 *    emit nodes — they are absorbed into name detection or, in the
 *    case of `Span`, attached to the enclosing enum node.
 *
 * The root is a synthetic `module` node so users have a single
 * top-level handle in selectors and JSON output. The root carries no
 * span — `HxModule` itself is a Seq (struct) so no enum-ctor span
 * applies. Its children (top-level decls) carry their own spans.
 */
@:nullSafety(Strict)
final class HaxeQueryPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider
		implements ParsedRootProvider {

	/**
	 * Search-only kind-equivalence. One Haxe declaration keyword surfaces as several
	 * position-specific `QueryNode` kinds — a `var` is module-level `VarDecl`, class-field
	 * `VarMember`, local `VarStmt`; a `function` is `FnDecl` / `FnMember` / `LocalFnStmt`; a
	 * `final` binding is `VarForm` / `FinalMember` / `FinalStmt` — while a pattern always parses
	 * through the Decl attempt and lands on the module-level kind. Without an equivalence such
	 * a pattern matches NOTHING outside module scope, and `search --explain` says so.
	 *
	 * Carried on the `Pattern` and consulted only by the search `Matcher`, so the `QueryNode`
	 * tree keeps the precise per-position kinds: `ast` / `--select` / `refs` / `meta` vocabulary
	 * is unchanged, and `DECL_HOST_KINDS` above stays correct. A module-level `final` names
	 * itself ONE LEVEL DOWN: `final x = 1;` projects as `FinalDecl(VarForm x …)`, so `FinalDecl`
	 * carries no name and one extra child and can never unify with the flat `FinalMember` /
	 * `FinalStmt` (the matcher compares the name slot and the child COUNT); the group is keyed
	 * on the named inner `VarForm`, and `parsePattern` re-roots the pattern onto it
	 * (`HaxePatternFragment.rerootFinalVarDecl`).
	 *
	 * A group holds only the variants whose span carries NOTHING but the family keyword, and
	 * that is a correctness rule rather than taste: this same relation drives `Rewrite.rewrite`
	 * and `--match` addressing, which splice over the MATCHED node's span. A variant that
	 * consumes an extra modifier keyword into its own span loses it — `final function sealed()`
	 * (`FinalModifiedMember`, span starts at `final`) and a local `inline function`
	 * (`LocalInlineFnStmt`, span starts at `inline`) both come back stripped of their modifier by
	 * a `function $n(…)` rewrite, silently and re-parseably. `(Public)` / `(Static)` are safe
	 * for the opposite reason: they project as SIBLING leaves outside the member's span. The
	 * same rule explains the var family's omission of `StaticVarStmt` / `StaticFinalStmt`.
	 * `SELECT_KIND_EQUIVALENCE` below DOES fold `FinalModifiedMember` onto `FnMember`, and search
	 * deliberately does not follow it: `--select` is a read-only projection with no rewriting
	 * consumer. The residual gap — no pattern reaches a `final function` or a local `inline
	 * function` — is left open on purpose: closing it needs a rewrite-safe split, not a wider
	 * constant. The groups also stay per-keyword (`var $v = 0` must not match a `final` binding),
	 * and expression-position forms are outside the criterion.
	 *
	 * One asymmetry is kept because the alternative is worse: a module-level `final` matches AS
	 * the `VarForm`, whose span starts after the `final` keyword, so a rewrite through it
	 * re-emits the keyword and the canonical gate rejects the whole result (`result does not
	 * parse`) instead of writing it — loud, and that spelling is rare; a member or local
	 * `final`, whose span does start at the keyword, rewrites correctly.
	 */
	private static final SEARCH_KIND_EQUIVALENCE: KindEquivalence = new KindEquivalence([
		['VarDecl', 'VarMember', 'VarStmt'],
		['FnDecl', 'FnMember', 'LocalFnStmt'],
		['VarForm', 'FinalMember', 'FinalStmt']
	]);

	/**
	 * `--select` kind-equivalence: folds the `final` modifier-wrapper
	 * shapes onto their plain counterparts so `--select ClassDecl` matches
	 * a `final class` (projected as `FinalDecl(ClassForm …)` — the named
	 * node is `ClassForm`) and `--select FnMember` matches a `final
	 * function` (`FinalModifiedMember`). Distinct from
	 * `SEARCH_KIND_EQUIVALENCE` — `--select` keeps its precise per-position
	 * kinds; only the final-wrapper folding is shared. NOT the Var/Final
	 * family (a `final` FIELD is a separate kind by design, not a wrapper).
	 */
	private static final SELECT_KIND_EQUIVALENCE: KindEquivalence = new KindEquivalence(
		[['ClassDecl', 'ClassForm'], ['FnMember', 'FinalModifiedMember']]
	);

	/**
	 * FALLBACK table of `using`-eligible extension-method names, consulted only when `StdResolver` cannot discover the std
	 * sources `knownExtensionMethods` derives these from at runtime. Its entries were themselves sourced from the
	 * installed std (every static `FnMember` of each module, private helpers included), so it is a subset of what the live
	 * extraction returns — a superset there is harmless (it only makes the `unused-import` "used" test more generous).
	 */
	private static final EXTENSION_METHODS: Map<String, Array<String>> = [
		'StringTools' => [
			'_charAt',
			'contains',
			'endsWith',
			'fastCodeAt',
			'hex',
			'htmlEscape',
			'htmlUnescape',
			'isEof',
			'isSpace',
			'iterator',
			'keyValueIterator',
			'lpad',
			'ltrim',
			'postProcessUrlEncode',
			'quoteUnixArg',
			'quoteWinArg',
			'replace',
			'rpad',
			'rtrim',
			'startsWith',
			'trim',
			'unsafeCodeAt',
			'urlDecode',
			'urlEncode',
			'utf16CodePointAt'
		],
		'Lambda' => [
			'array',
			'concat',
			'count',
			'empty',
			'exists',
			'filter',
			'find',
			'findIndex',
			'flatMap',
			'flatten',
			'fold',
			'foldi',
			'foreach',
			'has',
			'indexOf',
			'iter',
			'list',
			'map',
			'mapi'
		]
	];

	/**
	 * Per-module-path cache of the std extension-method extraction; a cached
	 * null (a non-std / missing module) is retained via `exists`, not recomputed.
	 */
	private static final extMethodsCache: Map<String, Null<Array<String>>> = [];

	/**
	 * Member-modifier node kinds — a `Static` among these marks the following `FnMember` static; any other is
	 * a non-`Static` modifier that preserves the accumulated flag (used by `collectStaticMethodsWithParam`).
	 */
	private static final MODIFIER_KINDS: Array<String> = [
		'Static',
		'Public',
		'Private',
		'Inline',
		'Override',
		'Final',
		'Dynamic',
		'Extern',
		'Macro',
		'Abstract'
	];

	/**
	 * Non-function member kinds that end a modifier run (a static var / final field), so their
	 * `Static` never leaks onto a following method (used by `collectStaticMethodsWithParam`).
	 */
	private static final FIELD_BOUNDARY_KINDS: Array<String> = ['VarMember', 'FinalMember', 'FinalModifiedMember'];

	public function new() {}

	public function langName(): String return 'haxe';

	public function parseFile(source: String): QueryNode {
		return treeFromRoot(parseRoot(source), source, false);
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		return treeFromRoot(parseRoot(source), source, true);
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		return CondBranchProjection.branchAwareTree(tree, source, refShape(), controlFlowSupport(), lexicalRegions.bind(source));
	}

	/**
	 * Parse + write round-trip via the Trivia pipeline so comments and
	 * blank lines survive. Defaults to `HaxeFormat.instance.defaultWriteOptions`
	 * — the same defaults the corpus harness uses when no `hxformat.json`
	 * config is provided. When `optsJson` is non-null, it is parsed as an
	 * `hxformat.json`-shaped payload via `HaxeFormatConfigLoader` so a
	 * `.hxtest` fixture's section-1 config (or any inline JSON) drives the
	 * writer for this one call. `loadHxFormatJson('{}')` is byte-identical
	 * to the defaults, so an empty config is a true no-op. Used by `apq ast
	 * --writer-output` for writer-bug probes without going through the full
	 * test runner.
	 *
	 * FAIL-CLOSED on comment loss: the Trivia parser only captures a
	 * comment where a capture slot exists, so an inline comment in a
	 * slot-less seam (`if (/* c *\/ x)`, `return /* r *\/ x;`, a type
	 * annotation, a class header) never reaches the AST and the writer
	 * re-emits the construct without it. Rather than hand back output
	 * that silently deletes an author's bytes, such a round trip throws
	 * `CommentLossException`: `fmt` names the file and leaves it byte-
	 * identical, and the ops' `RefactorSupport.canonicalize` refuses the
	 * edit instead of writing a file without the comment. Every whole-file
	 * consumer inherits the guard from this one seat — including the
	 * read-only probes (`ast --writer-output`, `writer-probe`,
	 * `writer-equals`, `recon --writer-equals`), which report the refusal
	 * on stderr and emit nothing. `APQ_ALLOW_COMMENT_LOSS` (any value but
	 * empty / `0`) declines the guard for the whole process, so writer
	 * development can see the raw emission; the CLI warns when it is set,
	 * because it re-arms the data loss on the WRITE paths too.
	 */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		final tree: Dynamic = HaxeModuleTriviaParser.parse(source);
		final emitted: Null<String> = HaxeModuleTriviaWriter.write(tree, writeOptionsOf(optsJson));
		if (emitted == null) return null;
		// Before the guard, not after: restoring an `@formatter:off` region
		// puts the source bytes back, so a comment living only inside one is
		// present again by the time the inventory compares the two sides.
		final written: String = FormatterOff.restore(source, emitted, HaxeLexicalRegions.scanComments);
		if (written == source || CommentInventory.guardDeclined()) return written;
		final lost: Null<String> = CommentInventory.firstMissing(source, written, HaxeLexicalRegions.scanComments);
		if (lost != null) throw new CommentLossException(lost);
		return written;
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		final opts: HxModuleWriteOptions = writeOptionsOf(optsJson);
		return {
			lineWidth: opts.lineWidth,
			indentWidth: opts.indentChar == Tab ? opts.tabWidth : opts.indentSize
		};
	}

	/**
	 * Parse + write round-trip via the PLAIN (non-trivia) pipeline.
	 * Mirrors the unit-test entry
	 * `HxModuleWriter.write(HaxeModuleParser.parse(source))` — flattens
	 * source layout, drops comments. Used by `apq ast
	 * --writer-output-plain` and `apq writer-equals` (default) so
	 * expected strings built off the probe match what unit tests
	 * actually see. The two pipelines emit different bytes on the same
	 * input (anon-struct flattens, terminators differ); always probe
	 * the pipeline that matches the test entry being constructed.
	 *
	 * `optsJson` follows the same convention as `writeRoundTrip`
	 * (`writeOptionsOf`) — an `hxformat.json`-shaped payload routes
	 * through `HaxeFormatConfigLoader.loadHxFormatJson`; `null`, and
	 * equally a BLANK payload, keeps the defaults.
	 */
	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		return HxModuleWriter.write(HaxeModuleParser.parse(source), writeOptionsOf(optsJson));
	}

	/**
	 * Trivia-mode strict parse for `apq recon`. Returns `true` on
	 * success; the surrounding `ParseError` propagates to the CLI on
	 * failure so the recon clusters by `error.span` locus. Same entry
	 * point the corpus harness drives, so a recon-OK fixture is a
	 * fixture the harness can attempt to format (the byte-comparison
	 * may still fail downstream, but the parse no longer blocks).
	 */
	public function reconParse(source: String): Bool {
		HaxeModuleTriviaParser.parse(source);
		return true;
	}

	public function typeRefShape(): TypeRefShape {
		// Type-position references reach the `parseFileTypeRefs` tree via
		// two complementary kinds, and `uses` must match both for a
		// complete blast-radius answer:
		//  - `TypeRef` — emitted by `appendTypeRefs` for the name-slot
		//    `type` fields that the default projection deliberately drops
		//    (var / class-member / anon / enum-ctor-param / fn-param
		//    annotations), one node per nominal name (head + each param).
		//  - `Named` / `NewExpr` — already present in BOTH projections
		//    (they were never on the dropped `type` path): function/lambda
		//    return types and type-param constraints (`Named`), `extends`
		//    / `implements` heritage (a `Named` child of the clause), and
		//    `new T(...)` (`NewExpr`).
		// Listing them here only widens the `Uses` walker (kind-filtered);
		// the `parseFile` tree and `ast`/`search`/`refs`/`meta` are
		// untouched — zero regression by construction.
		return { typeRefKinds: ['TypeRef', 'Named', 'NewExpr'] };
	}

	/**
	 * `GrammarPlugin`: the generated walker's own kind vocabulary, verbatim.
	 *
	 * Derived by `QueryWalkerLowering` from the shape the walk is emitted from, so a ctor
	 * added to the grammar lands here with no hand edit — which is what makes it usable as
	 * the other half of a differential against the hand-typed kind sets below.
	 */
	public function projectedKinds(): Array<String> return HaxeQueryWalker.projectedKinds();

	/** `GrammarPlugin`: the Haxe grammar's kind table, `HaxeRefShape`. */
	public function refShape(): RefShape return HaxeRefShape.shape();

	public function metaShape(): MetaShape {
		// Annotation nodes come through the three `HxMetadata` enum ctors: `MetaCall` for the
		// paren-bearing `@:name(args)` form (its arg expressions are children), `Meta` for the
		// paren-less `@:name`, and `PlainMeta` for the verbatim raw catch-all (`@:name(args)` carried
		// inline as the node's `name` slot). Decl-host kinds are shared with `refShape` so an
		// annotation attributes to the same binding-declaration nodes the refs walker recognises.
		return {
			metaKinds: ['MetaCall', 'Meta', 'PlainMeta'],
			declHostKinds: HaxeRefShape.DECL_HOST_KINDS
		};
	}

	public function selectKindEquivalence(): KindEquivalence {
		return SELECT_KIND_EQUIVALENCE;
	}

	public function parsePattern(source: String): Pattern {
		// `$X` / `$_` are not valid Haxe identifier prefixes outside string
		// interpolation, so we substitute them for reserved-identifier
		// placeholders before parsing and reclassify the resulting leaves
		// post-parse. The grammar parser stays unmodified.
		final substituted: String = Metavar.substituteMetavarsHaxe(source);
		final attempts: Array<{ wrap: String -> String, extract: QueryNode -> Null<QueryNode>, category: PatternCategory }> = [
			{ wrap: src -> src, extract: HaxePatternFragment.extractFirstDecl, category: PatternCategory.Decl },
			{ wrap: HaxePatternFragment.wrapAsStmt, extract: HaxePatternFragment.extractFirstStmt, category: PatternCategory.Stmt },
			{ wrap: HaxePatternFragment.wrapAsExpr, extract: HaxePatternFragment.extractFirstExpr, category: PatternCategory.Expr },
			{ wrap: HaxePatternFragment.wrapAsMetaArgs, extract: HaxePatternFragment.extractFirstMeta, category: PatternCategory.MetaArgs }
		];
		// A declaration / statement fragment whose only defect is the missing
		// terminator (`final x:T = []`) parses with a `;` appended — retried as a
		// SECOND variant through the SAME category ladder, so it lands in its
		// proper category with correct spans (a single-category retry mis-spans).
		for (variant in [substituted, '$substituted;']) for (attempt in attempts) {
			final wrapped: String = attempt.wrap(variant);
			final tree: Null<QueryNode> = try parseFile(wrapped) catch (e: ParseError) null
			catch (e: Exception) null;
			if (tree == null) continue;
			final extracted: Null<QueryNode> = attempt.extract(tree);
			if (extracted == null) continue;
			// A Decl extraction must CONSUME the whole fragment: modifiers
			// project as separate sibling nodes, so `static final x = []`
			// extracts a bare `(Static)` leaf — a degenerate pattern that would
			// silently match every static modifier. Reject partial extractions.
			if (attempt.category == PatternCategory.Decl && !HaxePatternFragment.consumesVariant(extracted, variant)) continue;
			// A bare-meta pattern (`@:foo($_)`) with the auto-appended `;`
			// parses as `MetaStmt(meta, EmptyStmt)` since the MetaStmt slice —
			// a degenerate statement that would shadow the MetaArgs attempt
			// every meta pattern relied on. Reject it so the ladder falls
			// through; real `@:meta <keyword-stmt>` patterns keep matching.
			if (
				attempt.category == PatternCategory.Stmt && extracted.kind == 'MetaStmt' && extracted.children.length > 0
				&& extracted.children[extracted.children.length - 1].kind == 'EmptyStmt'
			)
				continue;
			// `final x = …` extracts as the nameless wrapper `FinalDecl(VarForm …)`,
			// which can never unify with the flat `FinalMember` / `FinalStmt`. Re-root
			// onto the named inner node — after the `consumesVariant` gate above, which
			// needs the wrapper's span.
			final rooted: QueryNode = HaxePatternFragment.rerootFinalVarDecl(extracted);
			// Only a bare-identifier node may collapse into a whole-subtree
			// metavar: it is the one position where `$x` genuinely stands for
			// "any expression". A metavar landing in the NAME slot of a node
			// that happens to be childless — `new $x()`, `extends $B`, a
			// return type — is a name-position metavar, and collapsing it
			// erased its kind, turning the pattern into a match-everything
			// wildcard.
			// The `...` ellipsis first, so the metavar path never sees the star
			// placeholder: a star is not a metavar (it does not bind), and the
			// same `reclassify` collapse that erased `new $x()` would erase a
			// starred node just as silently.
			final starred: QueryNode = PatternStar.reclassify(rooted);
			final refusal: Null<String> = PatternStar.validate(starred);
			if (refusal != null) throw refusal;
			final reclassified: QueryNode = Metavar.reclassify(starred, refShape().identKind);
			return new Pattern(
				reclassified, attempt.category, source, SEARCH_KIND_EQUIVALENCE, Metavar.ignoredNames(variant, reclassified)
			);
		}
		// Every attempt's parser error is offset into a synthetic wrapper
		// string, so leaking it (`expected HxDecl at 0`) only misleads.
		// Report the actionable fact: the fragment is not valid in any
		// supported pattern position.
		throw 'pattern: not valid as a declaration, statement, expression, or metadata argument (a statement fragment is retried with a '
			+ 'trailing ";" automatically; a MODIFIER-bearing declaration cannot be a pattern — modifiers project as separate nodes; for '
			+ 'those and for non-standalone fragments such as object fields use `apq patch` or `replace-node --select`)';
	}

	/** The Haxe naming-convention capability — projects declarations and resolves a file's policy. */
	public function namingSupport(): Null<NamingSupport> {
		return new HaxeNamingSupport();
	}

	/**
	 * The Haxe adjacent-string-literal folding capability, consumed by the
	 * `fold-adjacent-string-literals` check.
	 */
	public function stringFoldSupport(): Null<StringFoldSupport> {
		return new HaxeStringFoldSupport();
	}

	/**
	 * The maximum cyclomatic complexity the `complexity` check should allow for a
	 * function in the file at `path`: read from a discovered `checkstyle.json`'s
	 * `CyclomaticComplexity` config, or null when none applies (the check then
	 * uses its built-in default).
	 */
	public function maxComplexity(path: String): Null<Int> {
		final content: Null<String> = CheckstyleConfigFinder.findConfigContent(path);
		return content == null ? null : try CheckstyleConfigLoader.loadComplexityMax(content) catch (exception: Exception) null;
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		return new HaxeControlFlowSupport();
	}

	public function lexicalRegions(source: String): Array<LexRegion> {
		return HaxeLexicalRegions.scan(source);
	}

	public function booleanLogicSupport(): Null<BooleanLogicSupport> {
		return new HaxeBooleanLogicSupport();
	}

	/**
	 * The `using`-eligible extension methods `using <modulePath>` brings into scope,
	 * DERIVED from the discovered std source via `StdResolver`: any-visibility static
	 * `FnMember`s of the module that take at least a first parameter, computed lazily
	 * and cached per module path. Falls back to the hardcoded `EXTENSION_METHODS`
	 * constant when std is undiscovered or the module is not a std file — so a name a
	 * live `using` relies on is never dropped. `unused-import` deletes a `using` only
	 * when NONE of the returned names is called, and a superset name is harmless (it
	 * only makes the "used" test more generous).
	 */
	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		return extensionMethodsFromStd(modulePath) ?? EXTENSION_METHODS[modulePath];
	}

	public function checkOverrides(path: String): Null<CheckOverrides> {
		final content: Null<String> = CheckstyleConfigFinder.findConfigContent(path);
		return content == null ? null : try CheckstyleConfigLoader.loadOverrides(content) catch (exception: Exception) null;
	}

	public function ambientImportSources(path: String, pkg: String): AmbientImports {
		return HaxeAmbientImports.chainFor(path, pkg);
	}

	public function ambientImportGovernance(path: String): Null<AmbientImportGovernance> {
		return HaxeAmbientImports.governanceFor(path);
	}

	public function ambientImportSites(path: String, pkg: String): Array<String> {
		return HaxeAmbientImports.sitesFor(path, pkg);
	}

	/**
	 * `TypeInfoProvider`: maps each typed declaration's binding-span `from` to the
	 * SIMPLE name of its nominal declared type, recovered from the grammar AST
	 * (which the QueryNode projection drops). Walks the same structure `appendNodes`
	 * does, associating an enum-ctor decl's Span param with the `type` on its
	 * payload struct, and a spanned struct's `_span` with its own `type`.
	 */
	public function declaredTypes(source: String): Map<Int, String> {
		return spanTypeInfo(source).declaredTypes;
	}

	public function returnTypes(source: String): Map<Int, String> {
		return spanTypeInfo(source).returnTypes;
	}

	/**
	 * `TypeInfoProvider`: maps each property-bearing member's binding-span `from` to
	 * whether its read accessor is a getter (`get` / `dynamic` → side-effecting,
	 * true) vs a plain stored read (`default` / `never` / a method name → false).
	 * A member with NO accessor clause (a plain field) is ABSENT — the consumer
	 * treats absence as a plain field. Same grammar-AST walk as `declaredTypes`,
	 * keyed on `HxVarDecl.access` (dropped from the QueryNode projection).
	 */
	public function propertyAccessors(source: String): Map<Int, Bool> {
		return spanTypeInfo(source).propertyAccessors;
	}

	/**
	 * `TypeInfoProvider`: maps each property-bearing member's binding-span `from` to
	 * whether its WRITE accessor is a setter (`set` / `dynamic` -> side-effecting,
	 * true) vs a plain stored write (`default` / `null` / `never` -> false). The
	 * write-side counterpart of `propertyAccessors`, keyed on `HxVarDecl.access`
	 * `ids[1]`. A member with NO accessor clause (a plain field) is ABSENT - the
	 * consumer treats absence as no set-accessor.
	 */
	public function propertyWriteAccessors(source: String): Map<Int, Bool> {
		return spanTypeInfo(source).propertyWriteAccessors;
	}

	/**
	 * `TypeInfoProvider`: maps each declaration's binding-span `from` to the VERBATIM
	 * source of its `:Type` annotation (`var x: Array<Int>` → `Array<Int>`), recovered
	 * by slicing the type node's span. Same walk + key as `declaredTypes`; the value is
	 * the written form rather than the package-stripped simple name.
	 */
	public function declaredTypeSources(source: String): Map<Int, String> {
		return spanTypeInfo(source).declaredTypeSources;
	}

	/**
	 * `TypeInfoProvider`: maps each typed-cast / type-check node's payload `_span.from`
	 * to the VERBATIM source of its TARGET type (`cast(x, Array<Int>)` → `Array<Int>`).
	 * Same discriminated walk as the simple-name cast recovery (a `type` field plus an
	 * operand `target` / `expr`, no `name`), but the value is the written type source.
	 */
	public function castTargetSources(source: String): Map<Int, String> {
		return spanTypeInfo(source).castTargetSources;
	}

	/** `TypeInfoProvider`: each declaration's type-parameter names, keyed by the span `from` of the node declaring them. */
	public function typeParamNames(source: String): Map<Int, Array<String>> {
		return spanTypeInfo(source).typeParamNames;
	}

	/**
	 * `SpanTypeInfoProvider`: the six span-indexed maps from ONE `HaxeModuleSpanParser`
	 * parse + ONE `walkGrammarSpans` traversal - the batched form of `declaredTypes`
	 * / `returnTypes` / `propertyAccessors` / `propertyWriteAccessors` / `declaredTypeSources`
	 * / `castTargetSources`, whose six separate `walkSpanMap` calls each re-parse the
	 * source. Each map is produced by the SAME visitor logic as its individual accessor
	 * over the SAME traversal, so the bundle is byte-for-byte the six separate walks
	 * (pinned by `SpanTypeInfoPinTest`).
	 */
	public function spanTypeInfo(source: String): SpanTypeInfo {
		return spanTypeInfoFromRoot(parseRoot(source), source);
	}

	/**
	 * `ParsedRootProvider`: parse `source` into the grammar root - the handle the three
	 * projections below share, so a caller needing more than one of them pays ONE parse
	 * instead of one per projection. Null when the source does not parse; each projection
	 * then behaves exactly as its source-taking twin did on that source.
	 */
	public function parseRoot(source: String): Null<Any> {
		return HaxeQueryWalker.parseRoot(source);
	}

	/**
	 * `ParsedRootProvider`: the declarations-only parse of `source` — the span parser with a `BodySkip` over this
	 * grammar's own non-code regions and directives, so `HxFnBlock`'s `@:skimmable` statements are jumped over. Not
	 * memoised here; the caching host memoises what it reads off it.
	 */
	public function parseDeclarationsRoot(source: String): Null<Any> {
		final regions: Array<LexRegion> = lexicalRegions(source);
		final ctx: Parser = new Parser(new StringInput(source));
		ctx.bodySkip = new BodySkip(SourceComments.collectNonCodeRegions(regions), CondDirectives.skipMarks(source, refShape(), regions));
		return try HaxeModuleSpanParser.parseWith(ctx) catch (exception: Exception) null;
	}

	/**
	 * `ParsedRootProvider`: the `parseFile` / `parseFileTypeRefs` projection of an
	 * already-parsed root, with `HxInterpProjection` applied: a single-quoted literal's
	 * text fragment may SPELL its interpolation through escapes (`'\x24a'` is a read
	 * of `a`), which the `@:rawString` terminal deliberately keeps verbatim and every
	 * tree consumer would otherwise read as plain text. Applied at this one seat so
	 * `parseFile` and `parseFileTypeRefs` — and through them every check, op and
	 * probe — see the same model the compiler does. Throws on a null root, exactly as
	 * `parseFile` always threw on a source that does not parse.
	 */
	public function treeFromRoot(root: Null<Any>, source: String, withTypeRefs: Bool): QueryNode {
		// A null root IS the parse failure, and the walker never saw the source, so on its own it can
		// only throw `parse failed` — which is verbatim what every op reported when its own rewrite
		// stopped parsing, with no file offset to look at. Re-raise the parser's own error here, where
		// the source is in hand: the memo the null root came from still holds it, so this costs nothing
		// on the common path and one re-parse on a path that throws either way.
		final parsed: Any = root ?? (HaxeQueryWalker.parseRootStrict(source): Any);
		final tree: QueryNode = new QueryNode('module', null, HaxeQueryWalker.walkRoot(cast parsed, withTypeRefs));
		HxInterpProjection.reproject(tree, source);
		HxArrowParamProjection.reproject(tree, source);
		return tree;
	}

	/** `ParsedRootProvider`: the `spanTypeInfo` projection of an already-parsed root — the empty bundle on a null one. */
	public function spanTypeInfoFromRoot(root: Null<Any>, source: String): SpanTypeInfo {
		return HaxeQueryWalker.spanInfoRoot(cast root, source);
	}

	/**
	 * `TypeInfoProvider`: maps each simple name brought into scope by a plain
	 * `import a.b.X;` to its fully-qualified path (`X` → `a.b.X`). Aliased / wildcard
	 * imports and `using` are skipped (an alias's original path is not exposed by the
	 * grammar). A name also used as a TYPE PARAMETER anywhere in the file is excluded —
	 * a type param shadows an import of the same name within its scope, so a bare
	 * reference to it must not resolve to the import (drops the rare collision).
	 */
	public function importMap(source: String, ?path: String): Map<String, String> {
		return importMapFromRoot(parseRoot(source), source, path);
	}

	/**
	 * `ParsedRootProvider`: the `importMap` projection of an already-parsed root. The
	 * import walk and the type-parameter sweep both read THIS root, where the
	 * source-taking form parsed once for each of them. The empty map on a null root.
	 */
	public function importMapFromRoot(root: Null<Any>, source: String, ?path: String): Map<String, String> {
		final out: Map<String, String> = [];
		final tree: Null<QueryNode> = try treeFromRoot(root, source, false) catch (exception: Exception) null;
		if (tree == null) return out;
		// FARTHEST ambient source first, so a nearer one overwrites it and the module's own
		// statements below overwrite the whole chain — the compiler's order, verified against it.
		// The recursive projection is handed no path, which is what stops the chain from having one.
		// An EMPTY path is the "no file to locate" value a check with no violation to read one off
		// carries, and walking a chain from the process cwd for it would answer a different tree.
		if (path != null && path != '') {
			final chain: Array<AmbientImportSource> = ambientImportSources(path, packageOfTree(tree)).sources;
			var i: Int = chain.length - 1;
			while (i >= 0) {
				final ambient: AmbientImportSource = chain[i--];
				for (name => imported in importMapFromRoot(parseRoot(ambient.source), ambient.source)) out[name] = imported;
			}
		}
		for (node in tree.children) if (node.kind == 'ImportDecl') {
			final raw: Null<String> = node.name;
			if (raw != null) {
				out[SourceText.lastSegment(raw)] = raw;
			}
		}
		for (tp in HaxeQueryWalker.typeParamNamesRoot(cast root, source)) out.remove(tp);
		return out;
	}

	/**
	 * Lazily extract + cache the `using`-eligible method names of `modulePath`
	 * from the std source, or null when std / the module file is absent.
	 */
	private function extensionMethodsFromStd(modulePath: String): Null<Array<String>> {
		if (extMethodsCache.exists(modulePath)) return extMethodsCache[modulePath];
		final computed: Null<Array<String>> = computeExtensionMethodsFromStd(modulePath);
		extMethodsCache[modulePath] = computed;
		return computed;
	}

	/**
	 * Parse `<std>/<modulePath>.hx` and collect its static-with-first-param `FnMember`
	 * names, or null when std is undiscovered or the file is missing / unparseable.
	 */
	private function computeExtensionMethodsFromStd(modulePath: String): Null<Array<String>> {
		final dir: Null<String> = StdResolver.stdDir();
		if (dir == null) return null;
		final src: Null<String> = readStdModule(dir, modulePath);
		if (src == null) return null;
		final tree: Null<QueryNode> = ParseGate.parseOrNull(this, src);
		if (tree == null) return null;
		final names: Array<String> = [];
		collectStaticMethodsWithParam(tree, names);
		return names;
	}

	/**
	 * The write options `optsJson` names: the writer's own defaults for `null` (no
	 * config discovered) and equally for a BLANK payload, which is what a 0-byte
	 * `hxformat.json` reads as — settings the project did not state. Handing that to
	 * the config parser instead raises `unexpected input (expected {)`. The three
	 * entries that read it (`writeRoundTrip`, `layoutMetrics`, `writeRoundTripPlain`)
	 * must agree on that, or a width-aware check MEASURES through one and WRITES
	 * through another and reports findings it can never apply.
	 */
	private static function writeOptionsOf(optsJson: Null<String>): HxModuleWriteOptions {
		final stated: Null<String> = FormatConfigDiscovery.normalize(optsJson);
		return stated == null ? HaxeFormat.instance.defaultWriteOptions : HaxeFormatConfigLoader.loadHxFormatJson(stated);
	}

	/**
	 * Read `<dir>/<modulePath-as-path>.hx`, or null when it does not exist
	 * / is unreadable (a non-std module then falls back to the table).
	 */
	private static function readStdModule(dir: String, modulePath: String): Null<String> {
		#if (sys || nodejs)
		final file: String = haxe.io.Path.join([dir, '${modulePath.split('.').join('/')}.hx']);
		return !sys.FileSystem.exists(file) ? null : try sys.io.File.getContent(file) catch (exception: Exception) null;
		#else
		return null;
		#end
	}

	/**
	 * Walk `container`'s children collecting the names of static `FnMember`s that take
	 * at least one parameter. Modifiers are FLAT siblings preceding their member, so a
	 * `Static` seen since the last member marks the next `FnMember` static; a
	 * non-`Static` modifier preserves the flag. `#if` members nest in a `Conditional`
	 * (their own modifier + member sequence) and type decls nest their members — both
	 * are recursed into. Visibility is intentionally NOT filtered: a private static can
	 * never be reached through `using`, so including it is a harmless superset that
	 * also preserves the historical `EXTENSION_METHODS` table (which listed private
	 * helpers).
	 */
	private static function collectStaticMethodsWithParam(container: QueryNode, into: Array<String>): Void {
		var sawStatic: Bool = false;
		// A `#if X inline #end` between `static` and the function wraps its modifiers in a
		// `Conditional`; flattening those inline keeps the modifier run continuous, and a
		// whole `#if`-guarded member (its own modifiers + FnMember) is handled by the same
		// linear pass — so target-conditional statics are captured either way.
		for (child in flattenConditionals(container.children)) {
			final kind: String = child.kind;
			if (kind == 'Static')
				sawStatic = true;
			else if (kind == 'FnMember') {
				final name: Null<String> = child.name;
				if (sawStatic && name != null && hasParam(child)) into.push(name);
				sawStatic = false;
			} else if (FIELD_BOUNDARY_KINDS.contains(kind))
				sawStatic = false;
			else if (!MODIFIER_KINDS.contains(kind)) {
				collectStaticMethodsWithParam(child, into);
				sawStatic = false;
			}
		}
	}

	/**
	 * Dissolve `Conditional` (`#if`) wrappers, splicing their children in place (recursively),
	 * so a modifier or member guarded by conditional compilation reads as a plain sibling.
	 */
	private static function flattenConditionals(children: Array<QueryNode>): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		for (c in children) if (c.kind == 'Conditional')
			for (g in flattenConditionals(c.children)) out.push(g);
		else
			out.push(c);
		return out;
	}

	/** Whether `fn` declares at least one parameter (a `Required` / `Optional` / `Rest` child) — the `using`-eligibility gate. */
	private static function hasParam(fn: QueryNode): Bool {
		return fn.children.exists(c -> c.kind == 'Required' || c.kind == 'Optional' || c.kind == 'Rest');
	}

	/** `GrammarPlugin` — `HxTypeSyntax` documents how each spelling reads. */
	public function typeSyntax(typeSource: String): Null<TypeSyntax> {
		return HxTypeSyntax.of(typeSource);
	}

	/** The package a projected module tree declares, empty for a root-package module. */
	private static function packageOfTree(tree: QueryNode): String {
		for (node in tree.children) if (node.kind == 'PackageDecl') return node.name ?? '';
		return '';
	}

}

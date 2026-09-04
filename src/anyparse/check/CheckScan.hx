package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.ElementSpan;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MemberKinds;
import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Shared scan helpers for the `run` / `fix` paths of the analysis checks.
 * A check parses INDEPENDENTLY in `run` and in `fix` — the platform's
 * thread-safety invariant forbids any shared mutable state or cache between
 * the two calls — so these are PURE static helpers taking the `(plugin,
 * source)` a check already holds. Not a base class (`Check` is an interface),
 * not a cache.
 */
@:nullSafety(Strict)
final class CheckScan {

	/** The read-accessor method-name prefix; its length also slices the property name off. */
	public static inline final GET_PREFIX: String = 'get_';

	/** The write-accessor method-name prefix (same length as `GET_PREFIX`, which slices both). */
	public static inline final SET_PREFIX: String = 'set_';

	/** The static-text child kind inside an interpolated string expression. */
	public static inline final STRING_FRAGMENT_KIND: String = 'Literal';

	/**
	 * The largest top-level statement count a bare `{ … }` statement block may hold and still read as noise
	 * rather than as a deliberate section marker. Calibrated on a real tree: the blocks a reader wants gone
	 * hold two or three statements, while every block that turned out to be delimiting a phase of a long
	 * function held more.
	 *
	 * Shared by `unnecessary-block`, which decides whether to unwrap an existing bare block, and by
	 * `keptBodyText`, which decides whether an always-true `if` leaves one behind — the two must agree, or the
	 * fixers disagree about the same shape and one of them emits what the other refuses to clean.
	 */
	public static inline final BARE_BLOCK_MAX_STATEMENTS: Int = 5;

	/** The class-body member kinds a method declaration projects as — a plain method and a `final` one. */
	public static final METHOD_KINDS: Array<String> = ['FnMember', 'FinalModifiedMember'];

	/** The node kinds a string expression projects as — the hosts whose `Literal` children are interpolation fragments. */
	public static final STRING_EXPR_KINDS: Array<String> = ['SingleStringExpr', 'DoubleStringExpr'];

	/** A sole-referenced declaration has exactly one non-declaration reference resolving to it. */
	private static inline final SOLE_REFERENCE_COUNT: Int = 1;

	/** The last dot-segment of a module path — the name a call site spells (`utils.TextUtil` -> `TextUtil`); `RefactorSupport.lastSegment` under a name that says which question the check layer is asking. */
	public static inline function simpleModuleName(path: String): String {
		return SourceText.lastSegment(path);
	}

	/**
	 * Whether `[from, to)` of `source` holds a `//` or `/*` comment marker — the check
	 * layer's entry point to `RefactorSupport.hasCommentMarker`, which owns the scan and
	 * the recorded per-caller argument for why it stays string-blind.
	 *
	 * The conservative "don't delete a comment" guard: for every consumer but the negation
	 * pair below, a marker found inside a string literal only ever REFUSES a fix, never
	 * deletes code. `negateConditionText` / `negationIsClean` read it as a tier selector
	 * instead — see the primitive's doc before changing anything here.
	 */
	public static inline function hasCommentMarker(source: String, from: Int, to: Int): Bool {
		return SourceComments.hasCommentMarker(source, from, to);
	}

	/**
	 * The check layer's entry point to `RefactorSupport.lineDeletionSpan`, which owns the scan:
	 * `span` extended BACKWARD over its own line's leading indentation and the newline before it, so
	 * deleting the result removes the whole line instead of leaving a blank one. Every caller pairs it
	 * with a comment gate over the region its deletion disturbs — the scan stops at the first
	 * non-whitespace, so a comment there would survive to document whatever follows.
	 */
	public static inline function lineDeletionSpan(source: String, span: Span): Span {
		return ElementSpan.lineDeletionSpan(source, span);
	}

	/**
	 * Whether `kind` is a class-body node whose direct children carry the members —
	 * `ClassDecl` (a plain class), `ClassForm` (the inner form of a `final` class
	 * under a `FinalDecl` wrapper), or `AbstractClassDecl` (an `abstract class`).
	 * Shared by the class-walking checks (PreferInline / TrivialGetter / UnusedPrivate / Naming) so their walkers agree on
	 * the set; note PreferInline and TrivialGetter REWRITE members of whatever this admits — widen it only with their fix
	 * gates in mind.
	 */
	public static inline function isClassBodyKind(kind: String): Bool {
		return kind == 'ClassDecl' || kind == 'ClassForm' || kind == 'AbstractClassDecl';
	}

	/**
	 * The delete-the-whole-member edit for `node`: its modifier / metadata run (`declGroupSpan`,
	 * which needs the declaring `parent` for the sibling run) folded in, then the LEADING
	 * `/**` DOC (`docExtendedSpan` with `docOnly`, so a section banner or licence header
	 * above the member is NOT deleted with it), then the whole line (`lineExtendedSpan`) so no blank
	 * modifier line is left behind, and finally ONE flanking blank line (`blankExtendedSpan`) so the deletion gives
	 * back the separator the member owned instead of leaving a doubled run. The doc goes because a deleted member takes its
	 * documentation with it — kept behind, the block silently becomes the doc of whatever
	 * declaration follows, which is exactly the orphan `fragmented-doc-comment` reports.
	 */
	public static inline function deletionEdit(
		source: String, node: QueryNode, parent: QueryNode, span: Span, regions: Array<LexRegion>
	): { span: Span, text: String } {
		final group: Span = ElementSpan.declGroupSpan(node, parent, span);
		final lines: Span = ElementSpan.lineExtendedSpan(source, ElementSpan.docExtendedSpan(source, group, regions, true));
		return { span: ElementSpan.blankExtendedSpan(source, lines), text: '' };
	}

	/** The `<file>#<from>:<to>` key one declaration is memoised under between a check's `run` and its `fix`. */
	public static inline function spanKey(file: String, span: Span): String {
		return '$file#${span.from}:${span.to}';
	}

	/**
	 * Parse `source` with `plugin`, or null on any parse failure — the tolerant
	 * parse every check's `run` / `fix` opens with (`Check` forbids throwing on
	 * unparseable input, so both failure modes collapse to null).
	 */
	public static function parseOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * Every entry of `files` that PARSES, with its tree — the loop a whole-scope check opens with,
	 * here once instead of once per check. An unparseable file is dropped silently, which is the
	 * `Check` contract: a check must be as tolerant as `SymbolIndex.build`.
	 */
	public static function parseAll(
		plugin: GrammarPlugin, files: Array<{ file: String, source: String }>
	): Array<{ file: String, source: String, tree: QueryNode }> {
		final out: Array<{ file: String, source: String, tree: QueryNode }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = parseOrNull(plugin, entry.source);
			if (tree != null) out.push({ file: entry.file, source: entry.source, tree: tree });
		}
		return out;
	}

	/**
	 * `parseOrNull` over the TYPE-REFERENCE projection (`GrammarPlugin.parseFileTypeRefs`) — the
	 * parallel tree that surfaces the annotation positions the default projection drops into trivia.
	 * Same tolerance contract; a check reads one or the other, never both from one parse.
	 */
	public static function parseTypeRefsOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFileTypeRefs(source) catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * `parseOrNull` over the BRANCH-AWARE projection (`GrammarPlugin.projectBranchAware`) — the
	 * plain tree with every statement-position conditional-compilation region regrouped into one
	 * `CondBranch` statement list per branch, so a statement-list check reads N lists instead of
	 * one flat run of every branch's statements. Same tolerance contract as `parseOrNull`; a
	 * check reads one projection or the other, never both from one parse.
	 *
	 * The plain parse and the projection are two calls on purpose: the plugin's own caching
	 * decorator memoizes each, so the pair costs ONE parse plus one projection per source no
	 * matter how many checks opt in.
	 */
	public static function parseBranchAwareOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try {
			final tree: QueryNode = plugin.parseFile(source);
			plugin.projectBranchAware(tree, source);
		} catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * The autofix skeleton shared by every span-indexed `fix`: parse `source`,
	 * index its `indexKinds` nodes by `from:to`, then for each violation with a
	 * span re-find the flagged node and let `produce` build its edit (null to
	 * skip that one). Returns the batched edits (empty when `source` does not
	 * parse). `produce` closes over the check's own seams and `source`; the
	 * helper owns only the parse + span-lookup boilerplate.
	 */
	public static function applyBySpan(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, indexKinds: Array<String>,
		produce: (node:QueryNode, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		return collectSpanEdits(violations, nodesByKind(plugin, source, indexKinds), produce);
	}

	/**
	 * The autofix skeleton for a check whose MATCHES already carry their replacement text: parse
	 * `source`, re-run `collect` over it, index each match's text by its span, and return the edits
	 * for the violations the caller was actually asked to fix (contained edits dropped). Empty when
	 * `source` does not parse. Sibling of `applyBySpan`, for a check that re-derives whole
	 * `{span, text}` matches rather than looking single nodes up by kind.
	 */
	public static function applyTextMatches(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>,
		collect: (tree:QueryNode, source:String) -> Array<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final textBySpan: Map<String, String> = [];
		for (m in collect(tree, source)) textBySpan['${m.span.from}:${m.span.to}'] = m.text;
		return CanonicalEdit.dropContainedEdits(collectSpanEdits(violations, textBySpan, (text, span) -> ({ span: span, text: text })));
	}

	/**
	 * Every spanned node of `kinds` in `source`, keyed `from:to` — the lookup table a span-addressed
	 * fix re-derives its targets from. Empty when `source` does not parse, which every caller reads
	 * as "nothing to do here" rather than as an error.
	 */
	public static function nodesByKind(plugin: GrammarPlugin, source: String, kinds: Array<String>): Map<String, QueryNode> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		final byKey: Map<String, QueryNode> = [];
		if (tree != null) MemberKinds.indexNodesByKind(tree, kinds, byKey);
		return byKey;
	}

	/**
	 * The null-comparison flavour of `simplifyConditionFixes`: `!=` is always-true,
	 * `==` always-false. Shared verbatim by `dead-null-guard` and
	 * `unnecessary-null-check`, whose `fix` differ only in how `run` proved the
	 * operand non-null — the rewrite is identical.
	 */
	public static function simplifyNullComparisonFixes(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final eq: Null<String> = shape.eqKind;
		final notEq: Null<String> = shape.notEqKind;
		if (eq == null || notEq == null) return [];
		final ne: String = notEq;
		return simplifyConditionFixes(plugin, source, violations, [eq, notEq], node -> node.kind == ne);
	}

	/**
	 * Rewrite each flagged provably-constant boolean comparison, dropping it where a
	 * safe span edit exists and refusing (leaving it a finding) everywhere else. The
	 * flagged node is recovered by span (its kind is in `flaggedKinds`); `alwaysTrueOf`
	 * gives its constant polarity (an `x != null` / `x is T` is always-true, an
	 * `x == null` always-false). Two rewrite shapes only:
	 *
	 *  - (a) the SOLE condition of a no-`else` `if` statement — an always-true one
	 *    unwraps the body, an always-false one deletes the whole `if` (both refuse
	 *    when a comment sits in the removed region, never silently dropping it);
	 *  - (b) a direct operand of a homogeneous same-operator logical chain — an
	 *    always-true conjunct is dropped from `&&`, an always-false disjunct from
	 *    `||` (both identities). A mixed `&&`/`||` nesting, a parenthesised operand,
	 *    a ternary / other expression position, or an `else`-bearing `if` all refuse.
	 *
	 * Edits are de-overlapped (two conjuncts flagged in one chain, or a dead `if`
	 * inside a dead `if`) so the batch applies cleanly; the deferred ones converge on
	 * a later `--fix` pass. The result is re-emitted through the canonical writer by
	 * the caller, which re-indents an unwrapped body and validates the splice.
	 */
	public static function simplifyConditionFixes(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, flaggedKinds: Array<String>, alwaysTrueOf: (QueryNode) -> Bool
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final blockKinds: Array<String> = support != null ? support.blockKinds() : [];
		// Without the block-container seam `ScopeFrames` cannot collect a frame, so every collision test would
		// pass vacuously — leave `containerKinds` empty and never unwrap rather than unwrap unchecked.
		final caseBranchKinds: Array<String> = support == null
			? []
			: [for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k];
		final seams: CondSimplifySeams = {
			ifKinds: shape.ifStatementKinds ?? [],
			andKind: shape.logicalAndKind ?? '',
			orKind: shape.logicalOrKind ?? '',
			parenKind: shape.parenKind ?? '',
			blockKinds: blockKinds,
			blockStmtKind: shape.blockStmtKind,
			containerKinds: blockKinds.concat(caseBranchKinds),
			scopeKinds: shape.scopeKinds,
			functionKinds: shape.functionKinds ?? [],
			localDeclKinds: ScopeFrames.bindingKinds(shape),
			condKind: shape.conditionalMemberKind
		};
		final parents: Map<QueryNode, QueryNode> = [];
		fillParents(root, parents);
		final frames: Map<QueryNode, Array<String>> = ScopeFrames.frameIndex(root, seams);
		final byKey: Map<String, QueryNode> = [];
		MemberKinds.indexNodesByKind(root, flaggedKinds, byKey);
		return nonOverlappingEdits(
			collectSpanEdits(violations, byKey, (node, _) -> conditionEdit(node, alwaysTrueOf(node), parents, frames, source, seams))
		);
	}

	/**
	 * The operand-type probe `negateConditionText` hands to a `BooleanLogicSupport` so it may
	 * flip an ordered comparison instead of wrapping it `!(…)` — see
	 * `BooleanLogicSupport.negateCondition`. Answers a node's declared type nominal through the
	 * run's resolution scope, or null for anything it cannot pin, which keeps the wrap.
	 *
	 * The probe is `NominalTypes.expressionTypeNominal`, run in its DEEP mode — the
	 * `ChainTypeContext` built below. On top of the plain identifier / field-path answer it
	 * resolves five further shapes:
	 *
	 *  - a METHOD CALL's return nominal, through its receiver chain (`chain.indexOf(x)` → `Int`);
	 *  - a `for` BINDER's type, read off the iterable's element type parameter — the binder carries
	 *    no `:Type`, so it has no `declaredTypes` entry of its own;
	 *  - a TABLED stdlib static call's return (`RefShape.staticMethodReturns`), which is what makes
	 *    the binder arm reach `for (key in Reflect.fields(o))`;
	 *  - a generic member's TYPE ARGUMENT, so `b.payload.text` on a `b:Box<Item>` reaches `Item`'s
	 *    member instead of stopping at the verbatim parameter name `T`;
	 *  - a `using`-brought STATIC EXTENSION on a call tail, which is what lets a chain survive its
	 *    first extension link (`text.trim().toLowerCase()`) instead of dying there — the file's
	 *    `using` header rides in the context for it.
	 *
	 * All five are added PROOF only: every extra resolution can turn a conservative `!(a < b)`
	 * wrap into a licensed flip, never the reverse, so the unproven → refuse default every
	 * guard-family consumer relies on is untouched.
	 *
	 * The deep mode stays an OPT-IN parameter rather than a widening of
	 * `NominalTypes.valueTypeNominal` because its other consumers read a resolved nominal as a
	 * licence to ACT, so each has to decide for itself. `map-keys-lookup` has not opted in;
	 * `prefer-static-extension` HAS, deliberately — see `PreferStaticExtension.receiverNominal` for
	 * why each deep arm is type-CORRECT and fail-closed rather than merely more permissive, which is
	 * the bar an arm must clear before an acting consumer may take it.
	 *
	 * Null when the grammar carries no type information at all: the caller then passes nothing
	 * and every ordered comparison stays wrapped, exactly as before this seam existed.
	 *
	 * `asReceiver` asks about each node in MEMBER-LOOKUP position rather than as a value, so a
	 * member-transparent wrapper is peeled off the top and a `Null<Map<K, V>>` binding answers
	 * `Map`. The distinction is not cosmetic and the two modes are not interchangeable: a value's
	 * own nominal is what a consumer reads to decide what is legal to DO with the value, and
	 * `Null<Int>` is not `Int` there. The receiver answer may be used for ONE thing — deciding which
	 * member a name resolves to on that receiver — which is what a rule splicing `<recv>.<member>(…)`
	 * has to know, and why the measured `baseData:Null<Map<Int, ObjectFrameData>>` site needs it
	 * while the `Iterable`-shape proof next to it must keep asking the value question.
	 */
	public static function typeNominalResolver(
		source: String, plugin: GrammarPlugin, tree: QueryNode, file: String, ?index: SymbolIndex, asReceiver: Bool = false
	): Null<(QueryNode) -> Null<String>> {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (provider == null) return null;
		final declaredTypes: Map<Int, String> = provider.declaredTypes(source);
		final shape: RefShape = plugin.refShape();
		// The resolution index sees the std + configured libraries, so a member type such as
		// `Array.length` resolves; the report index alone would stop at the project boundary.
		final resolved: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final chain: ChainTypeContext = {
			declaredTypeSources: provider.declaredTypeSources(source),
			source: source,
			usings: UsingScan.usingModules(UsingScan.headerOf(tree, source, plugin))
		};
		return node -> NominalTypes.expressionTypeNominal(node, tree, shape, declaredTypes, resolved, file, chain, asReceiver);
	}

	/**
	 * The node kinds whose presence in a subtree makes a once-vs-twice evaluation
	 * rewrite unsafe: every binding-write (`writeParentKinds`), plus `callKind` and
	 * `newExprKind` when the grammar exposes them. Shared by the checks that collapse a
	 * repeated operand (`prefer-null-coalescing`, `prefer-safe-nav-comparison`) — the
	 * gate is SYNTACTIC, so it sees a call or a construction but not an implicit
	 * property getter behind a plain field read.
	 */
	public static function mutationKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = shape.writeParentKinds.copy();
		final callKind: Null<String> = shape.callKind;
		if (callKind != null) kinds.push(callKind);
		final newExprKind: Null<String> = shape.newExprKind;
		if (newExprKind != null) kinds.push(newExprKind);
		return kinds;
	}

	/**
	 * Every class-body node in `root`'s subtree (`isClassBodyKind`), pre-order —
	 * the collector shared by PreferInline and TrivialGetter (Naming / UnusedPrivate run their own stateful walks over the same predicate).
	 */
	public static function classBodies(root: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectClassBodies(root, out);
		return out;
	}

	/**
	 * The whitespace-normalized view of `[from, to)`: every run of spaces / tabs /
	 * newlines collapsed to a single space with the ends trimmed, plus the count of
	 * non-whitespace characters. The shared text-identity metric of `duplicate-code`
	 * (which hashes statement norms to find clones and gates a run on its non-whitespace
	 * size), `extract-repeated-expression` (which buckets equal expressions) and
	 * `tail-merge` (which compares a branch tail against the shared fall-through run). Deliberately NOT string-literal-aware: whitespace INSIDE a literal collapses
	 * too, so `f("a  b")` and `f("a b")` normalize equal — a consumer needing exact token
	 * identity pairs this with a structural comparison rather than relying on it alone.
	 */
	public static function normalizeSpan(source: String, from: Int, to: Int): NormalizedSpan {
		final buf: StringBuf = new StringBuf();
		var nonWs: Int = 0;
		var pendingSpace: Bool = false;
		for (i in from ... to) {
			final c: Int = source.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				pendingSpace = true;
			} else {
				if (pendingSpace && nonWs > 0) buf.addChar(' '.code);
				pendingSpace = false;
				buf.addChar(c);
				nonWs++;
			}
		}
		return { norm: buf.toString(), nonWs: nonWs };
	}

	/**
	 * The end offsets of every doc block in `source` — the lookup a doc-anchor test needs,
	 * built ONCE per file. Comment boundaries come from the parser's own tokenizer, so a
	 * `/*` sequence inside a doc body (an escaped example) never fools the anchor — the trap
	 * a naive `lastIndexOf('/*')` hits.
	 */
	public static function docBlockEnds(source: String, regions: Array<LexRegion>): Map<Int, Bool> {
		return [
			for (tok in SourceComments.collectCommentTokens(regions)) if (SourceComments.isDocBlock(source, tok)) tok.to => true
		];
	}

	/**
	 * Whether a doc block's close sits at the last non-whitespace byte before `pos` — one
	 * immediately precedes the declaration anchored there. `docEnds` comes from
	 * `docBlockEnds`; a line comment or a plain `/* … *\/` block is absent from it, so
	 * neither reads as documentation.
	 */
	public static function hasDocBefore(source: String, docEnds: Map<Int, Bool>, pos: Int): Bool {
		var i: Int = pos - 1;
		while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) i--;
		return i >= 0 && docEnds.exists(i + 1);
	}

	/**
	 * Whether `node` is a leading modifier / `@:meta` annotation — part of the sibling run
	 * that PRECEDES a declaration in the projection, rather than a declaration itself. The
	 * run's start is where a doc comment sits in source, so every doc-anchor walk needs it.
	 * `modifierKinds` is the grammar's modifier-kind set; a metadata node is recognised by
	 * its `@`-prefixed name, which no grammar spells differently.
	 */
	public static function isLeadingAnnotation(node: QueryNode, modifierKinds: Array<String>): Bool {
		final nm: Null<String> = node.name;
		if (nm != null && nm.length > 0 && StringTools.fastCodeAt(nm, 0) == '@'.code) return true;
		return modifierKinds.contains(node.kind);
	}

	/**
	 * The declared name of a type node — its own, or the name of the `containerKinds` child
	 * that carries it for a wrapped shape (a Haxe `final class`, whose name sits on the inner
	 * `ClassForm`). `'<anonymous>'` when neither has one.
	 */
	public static function typeDeclName(node: QueryNode, containerKinds: Array<String>): String {
		final own: Null<String> = node.name;
		if (own != null) return own;
		for (c in node.children) {
			final nm: Null<String> = c.name;
			if (nm != null && containerKinds.contains(c.kind)) return nm;
		}
		return '<anonymous>';
	}

	/**
	 * Every node kind that projects as a leading MODIFIER sibling before a declaration —
	 * the set `isLeadingAnnotation` tests a decl's preceding run against, so a check can
	 * find where a declaration's doc anchor starts.
	 *
	 * `RefShape.modifierKinds` is the grammar's OWN answer and wins whenever it is set —
	 * one list, so a keyword the grammar admits as a modifier cannot be known to one run
	 * walk and unknown to the next. Copied, because callers extend what they get back.
	 *
	 * A grammar declaring none falls back to the assembly this used to be:
	 * `modifierOrderKinds` (the ordered core) plus the seams that sit outside it — the
	 * visibility pair and the four standalone modifier kinds, deduped. That assembly can
	 * only ever see a modifier some OTHER seam already needed, so it misses precisely the
	 * ones no check singles out: Haxe's `overload` and `abstract` are ranked by nothing
	 * and named by nothing, and both were absent from every consumer of this set.
	 */
	public static function modifierKinds(shape: RefShape): Array<String> {
		final declared: Null<Array<String>> = shape.modifierKinds;
		if (declared != null) return declared.copy();
		final out: Array<String> = [for (m in shape.modifierOrderKinds ?? []) m];
		for (m in shape.visibilityModifierKinds ?? []) if (!out.contains(m)) out.push(m);
		for (kind in [
			shape.externModifierKind,
			shape.dynamicModifierKind,
			shape.macroModifierKind,
			shape.overrideModifierKind
		]) if (kind != null && !out.contains(kind)) out.push(kind);
		return out;
	}

	/**
	 * A function's declared RETURN annotation as written, or null when it declares none — the SOLE `typeAnnotationKinds`
	 * direct child that starts AFTER the parameter list's closing `)`. Position is the whole gate:
	 * a type-parameter CONSTRAINT (`function f<T:Foo>()`) projects the very same `Named` node in
	 * the very same child slot, always BEFORE the parameter list, so trusting "exactly one
	 * annotation child" made a constrained function with NO return type read as annotated `Foo`.
	 * The `)` is searched from the last parameter's end (or the function's start when it declares
	 * none), which puts a default value's parentheses behind the cursor; metadata projects as a
	 * sibling node outside the function span. A parameter's own annotation nests UNDER the
	 * parameter node, never as a direct child of the function, so it is never a candidate.
	 */
	public static function returnAnnotationText(fn: QueryNode, shape: RefShape, source: String): Null<String> {
		final fnSpan: Null<Span> = fn.span;
		if (fnSpan == null) return null;
		final paramsEnd: Int = lastParamEnd(fn, shape.paramKinds ?? []);
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		var found: Null<Span> = null;
		var prevEnd: Int = fnSpan.from;
		for (child in fn.children) {
			final childSpan: Null<Span> = child.span;
			if (childSpan == null) return null;
			if (annotationKinds.contains(child.kind) && afterParamList(childSpan, prevEnd, paramsEnd, source)) {
				if (found != null) return null;
				found = childSpan;
			}
			prevEnd = childSpan.to;
		}
		return found == null ? null : source.substring(found.from, found.to);
	}

	/**
	 * The display width of `source[from, to)` with tabs expanded to `indentWidth` -- the
	 * column arithmetic every width-aware check needs. Pass a line's own `[lineStart, pos)`
	 * for the column `pos` sits at, or `[0, line.length)` for a whole line's width.
	 * Shared so `fold-adjacent-string-literals` and `prefer-case-guard` cannot drift on
	 * what a tab is worth.
	 */
	public static function displayColumn(source: String, from: Int, to: Int, indentWidth: Int): Int {
		var cols: Int = 0;
		for (i in from ... to) cols += source.fastCodeAt(i) == '\t'.code ? indentWidth : 1;
		return cols;
	}

	/**
	 * Whether `branch` (an `if`'s then-branch, or any statement in branch position)
	 * unconditionally exits: a terminal statement directly, or a block whose LAST direct child
	 * is terminal. The shared reading of "this branch never falls through" — `redundant-else`
	 * de-nests on it, `redundant-replace-loop` reads a pre-loop guard with it.
	 */
	public static function branchAlwaysExits(branch: QueryNode, support: ControlFlowSupport): Bool {
		if (support.isTerminal(branch)) return true;
		if (!support.blockKinds().contains(branch.kind)) return false;
		final kids: Array<QueryNode> = branch.children;
		return kids.length > 0 && support.isTerminal(kids[kids.length - 1]);
	}

	/**
	 * The whole `fix` of a member-DELETING check: for every violation whose span is in `deletable`,
	 * one edit removing that method with its modifier / metadata run and its leading doc comment.
	 *
	 * Shared verbatim by `orphan-accessor` and `unused-public-member`, which differ only in how `run`
	 * proved the method dead. Each method's group span is computed against its OWN host, not the
	 * container: a method written inside a member-position `#if` region has its run one level down,
	 * and a span computed against the container would leave it behind as debris that does not parse.
	 */
	public static function deleteMethodsFix(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, deletable: Array<String>
	): Array<{ span: Span, text: String }> {
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null && deletable.contains(spanKey(v.file, span))) wanted.push('${span.from}:${span.to}');
		}
		if (wanted.length == 0) return [];
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final edits: Array<{ span: Span, text: String }> = [];
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		for (cls in classBodies(tree)) MemberKinds.eachMemberHost(cls, host -> {
			for (child in host.children) {
				final span: Null<Span> = child.span;
				if (span != null && METHOD_KINDS.contains(child.kind) && wanted.contains('${span.from}:${span.to}'))
					edits.push(deletionEdit(source, child, host, span, regions));
			}
		});
		return edits;
	}

	/**
	 * The `from` of the declaration's own name token when the local `name` bound at `declSpan`
	 * has EXACTLY one non-declaration reference resolving to it, or null otherwise. Reads the
	 * name token (a self-binding hit inside `declSpan`) and counts every other hit whose
	 * binding falls inside `declSpan`.
	 *
	 * Shared by the joins that collapse a single-use local away (`join-return`,
	 * `join-single-use-local`): both must prove the declaration has exactly ONE consumer before
	 * they may delete it.
	 */
	public static function soleReferenceNameFrom(name: String, declSpan: Span, tree: QueryNode, shape: RefShape): Null<Int> {
		var declNameFrom: Null<Int> = null;
		var otherRefs: Int = 0;
		for (h in Refs.find(name, tree, shape)) {
			final hs: Span = h.span;
			final bs: Null<Span> = h.bindingSpan;
			final selfBind: Bool = bs != null && bs.from == hs.from && bs.to == hs.to;
			if (selfBind && hs.from >= declSpan.from && hs.to <= declSpan.to) {
				declNameFrom = hs.from;
				continue;
			}
			if (bs != null && bs.from >= declSpan.from && bs.to <= declSpan.to) otherRefs++;
		}
		return otherRefs == SOLE_REFERENCE_COUNT ? declNameFrom : null;
	}

	/**
	 * Whether a reference OUTSIDE the conditional-compilation region holding `declSpan` binds to a
	 * same-name declaration INSIDE it — in which case the declaration is not sole-referenced and
	 * whatever collapse `soleReferenceNameFrom` cleared must not happen.
	 *
	 * Branch-aware resolution (`Refs`' `CondBranch` preference frame) is exact only INSIDE a
	 * region: past `#end` the enclosing block's first-wins rule points such a read at the FIRST
	 * branch's declaration, while the compiler points it at whichever branch the configuration
	 * activates. A post-region read is therefore a reference to EVERY branch's declaration at
	 * once, and collapsing any one of them away would leave that read unbound in that branch's
	 * configuration — a `--fix` that does not compile. Counting the read against every declaration
	 * in the region restores the pre-branch-frame verdict for exactly this shape and nothing else:
	 * when the region declares the name only once, the read already binds inside `declSpan` and
	 * the sole-reference count has it.
	 *
	 * A null `conditionalMemberKind` (a grammar with no conditional compilation) makes this a
	 * no-op, as does a declaration outside any region.
	 */
	public static function escapesConditionalRegion(name: String, declSpan: Span, tree: QueryNode, shape: RefShape): Bool {
		final region: Null<Span> = enclosingConditionalRegion(tree, declSpan, shape.conditionalMemberKind);
		if (region == null) return false;
		final r: Span = region;
		for (h in Refs.find(name, tree, shape)) if (h.kind != RefKind.Decl) {
			final bs: Null<Span> = h.bindingSpan;
			if (bs == null || bs.from < r.from || bs.to > r.to) continue;
			if (h.span.from < r.from || h.span.to > r.to) return true;
		}
		return false;
	}

	/** The span of the innermost conditional-compilation region (`conditionalMemberKind`) containing `inner`, or null. */
	public static function enclosingConditionalRegion(node: QueryNode, inner: Span, condKind: Null<String>): Null<Span> {
		if (condKind == null) return null;
		final span: Null<Span> = node.span;
		if (span != null && (span.from > inner.from || span.to < inner.to)) return null;
		for (c in node.children) {
			final hit: Null<Span> = enclosingConditionalRegion(c, inner, condKind);
			if (hit != null) return hit;
		}
		return node.kind == condKind ? span : null;
	}

	/**
	 * Iterate `violations`, recover each flagged entry from `byKey` by its `from:to`
	 * span, and collect the non-null edits `produce` builds — the span-lookup loop
	 * every `fix()` runs over its own match index. `T` is whatever the caller indexed:
	 * a `QueryNode` (`applyBySpan`, `simplifyConditionFixes`), a bare `Span`, or a
	 * check's own match record.
	 */
	public static function collectSpanEdits<T>(
		violations: Array<Violation>, byKey: Map<String, T>, produce: (node:T, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<T> = byKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final edit: Null<{ span: Span, text: String }> = produce(node, span);
			if (edit != null) edits.push(edit);
		}
		return edits;
	}

	/**
	 * Whether a FRAMEWORK reaches the METHOD `name` of type `owner` with no written call —
	 * `NamingSupport.frameworkReachable` asked with the project's declared roster, which the
	 * implementation unions with the frameworks its own language ships (in Haxe, a utest
	 * `test` / `spec` / `setup` / `teardown` method of a class transitively extending `Test`).
	 *
	 * The predicate itself has one home and always did; what was copied was this ADAPTER — the
	 * three lines that lift a `(name, owner, span)` a check already holds into the `NamedDecl`
	 * the seam takes. `unused-public-member` grew it first, `prefer-inline` needed the same
	 * question, and a second private copy is how a roster reaches one rule and not its sibling.
	 * `unused-private` does not route through here: it holds a REAL projected `NamedDecl` with
	 * the declaration's own modifiers, and synthesising a blank-modifier one over it would
	 * discard information the seam is free to read.
	 *
	 * That `mods: []` is a real gap for the two callers that DO route here, not a harmless
	 * simplification: utest skips a STATIC method (`!isStatic && isTestName(...)`), verified live,
	 * yet a `public static function testX()` in a `Test` subclass is exempted by both of them today.
	 * A `static` gate added to `nominated` would fix `unused-private` and silently miss these two.
	 * Closing it means passing the real modifiers, which both call sites hold.
	 *
	 * `index` is a THUNK for the reason the seam declares: naming the declaration is a string
	 * test, the supertype closure a whole-scope index, and a caller that has built none pays
	 * only when a contract actually claims the name. A grammar with no naming support answers
	 * `false` — the framework question is unprovable, and every caller's safe direction there is
	 * to keep judging the member on its own evidence.
	 */
	public static function frameworkReachableMethod(
		naming: Null<NamingSupport>, name: String, owner: String, span: Span, index: () -> Null<SymbolIndex>,
		contracts: Array<FrameworkContract>, isStatic: Bool
	): Bool {
		if (naming == null) return false;
		final decl: NamedDecl = {
			span: span,
			name: name,
			category: NamingCategory.Method,
			// The ONE modifier the predicate reads, carried as a resolved BOOLEAN rather than a
			// modifier array: the two callers hold the member's modifier run as grammar KINDS
			// (`Static`) and `NamedDecl.mods` spells NAMES (`static`), so an array parameter would
			// hand the translation to each call site and the wrong spelling would answer `false`
			// silently — the same shape as the empty list it replaces. A gate on a SECOND modifier
			// must widen this parameter, not read `decl.mods` and find it absent.
			// The literal, not a constant: this module may not import the grammar that OWNS the
			// vocabulary, so the spelling stands in two places by construction. Its pair is
			// `HaxeNamingSupport.nominated`, and `UnusedPublicMemberCheckTest`'s static fixture stops
			// flagging the moment either side drifts.
			mods: isStatic ? ['static'] : [],
			enclosingType: owner
		};
		return naming.frameworkReachable(decl, index, contracts);
	}

	/**
	 * The edit for one flagged constant comparison `node`, or null (refuse). Shape (a)
	 * when `node` is the sole condition of a no-`else` `if`; shape (b) when it is a
	 * direct operand of the matching homogeneous logical chain (`&&` for always-true,
	 * `||` for always-false); refuse otherwise.
	 */
	private static function conditionEdit(
		node: QueryNode, alwaysTrue: Bool, parents: Map<QueryNode, QueryNode>, frames: Map<QueryNode, Array<String>>, source: String,
		seams: CondSimplifySeams
	): Null<{ span: Span, text: String }> {
		final parent: Null<QueryNode> = parents[node];
		if (parent == null) return null;
		if (seams.ifKinds.contains(parent.kind) && parent.children.length == 2 && parent.children[0] == node)
			return ifShapeEdit(parent, alwaysTrue, parents, frames, source, seams);
		final wantKind: String = alwaysTrue ? seams.andKind : seams.orKind;
		return wantKind != '' && parent.kind == wantKind && homogeneousChain(parent, wantKind, parents, seams)
			? dropOperandEdit(parent, node, source)
			: null;
	}

	/**
	 * Shape (a): `ifNode` is a no-`else` `if` whose sole condition is a proven
	 * constant. Always-true replaces the whole `if` with its body source (a bare
	 * block keeps its braces, preserving scope); always-false deletes the `if`
	 * (line-extended when it sits in a statement list, else `{}` so an enclosing
	 * branch is not orphaned). Refuses when a comment sits in any removed region.
	 */
	private static function ifShapeEdit(
		ifNode: QueryNode, alwaysTrue: Bool, parents: Map<QueryNode, QueryNode>, frames: Map<QueryNode, Array<String>>, source: String,
		seams: CondSimplifySeams
	): Null<{ span: Span, text: String }> {
		final ns: Null<Span> = ifNode.span;
		final body: QueryNode = ifNode.children[1];
		final bs: Null<Span> = body.span;
		if (ns == null || bs == null) return null;
		final ifParent: Null<QueryNode> = parents[ifNode];
		// An always-true guard keeps only the body — refuse if a comment sits in the removed
		// `if (…)` header or trailing region (comments inside the body are preserved).
		if (alwaysTrue) return hasCommentMarker(source, ns.from, bs.from) || hasCommentMarker(source, bs.to, ns.to) ? null : {
			span: ns,
			text: keptBodyText(body, bs, ifParent, frames, source, seams)
		};
		if (hasCommentMarker(source, ns.from, ns.to)) return null;
		final inBlock: Bool = ifParent != null && seams.blockKinds.contains(ifParent.kind);
		// A collapsed-away `if` is a PURE deletion like a member removal, so it gives back its
		// flanking blank line the same way; the `{}` arm replaces rather than deletes and must not.
		return inBlock ? {
			span: ElementSpan.blankExtendedSpan(source, ElementSpan.lineExtendedSpan(source, ns)),
			text: ''
		} : { span: ns, text: '{}' };
	}

	/**
	 * Shape (b): drop `operand` (one of the two children of the binary logical
	 * `chain` node) together with its adjacent operator — the right operand deletes
	 * `[left.to, right.to)` (` && x`), the left deletes `[left.from, right.from)`
	 * (`x && `). The surviving operand's source (its parentheses included) is
	 * untouched. Refuses when a comment sits in the removed operator / operand region.
	 */
	private static function dropOperandEdit(chain: QueryNode, operand: QueryNode, source: String): Null<{ span: Span, text: String }> {
		if (chain.children.length != 2) return null;
		final left: QueryNode = chain.children[0];
		final right: QueryNode = chain.children[1];
		final ls: Null<Span> = left.span;
		final rs: Null<Span> = right.span;
		if (ls == null || rs == null) return null;
		// Drop the operand together with its adjacent operator: the right operand deletes
		// `[left.to, right.to)` (` && x`), the left `[left.from, right.from)` (`x && `).
		final drop: Null<Span> = if (operand == right)
			new Span(ls.to, rs.to)
		else if (operand == left)
			new Span(ls.from, rs.from)
		else
			null;
		return drop == null || hasCommentMarker(source, drop.from, drop.to) ? null : { span: drop, text: '' };
	}

	/**
	 * Whether every logical ancestor of `node` up to the first non-logical boundary is
	 * the SAME operator as `wantKind` — a pure `&&` (or pure `||`) chain. A different
	 * logical operator (mixed `&&`/`||`) or a parenthesised wrap returns false, so the
	 * conservative drop fires only inside a homogeneous chain.
	 */
	private static function homogeneousChain(
		node: QueryNode, wantKind: String, parents: Map<QueryNode, QueryNode>, seams: CondSimplifySeams
	): Bool {
		var cur: QueryNode = node;
		while (true) {
			final p: Null<QueryNode> = parents[cur];
			if (p == null) return true;
			if (p.kind == seams.andKind || p.kind == seams.orKind) {
				if (p.kind != wantKind) return false;
				cur = p;
			} else
				return p.kind != seams.parenKind;
		}
	}

	/** Record each node's parent, so a flagged node can be classified by its enclosing context. */
	private static function fillParents(node: QueryNode, out: Map<QueryNode, QueryNode>): Void {
		for (c in node.children) {
			out[c] = node;
			fillParents(c, out);
		}
	}

	/**
	 * Keep a maximal non-overlapping subset of `edits` (earliest span first) so the
	 * `RefactorSupport.applyEdits` no-overlap contract holds — two conjuncts flagged
	 * in one chain, or a dead `if` nested in a dead `if`, would otherwise splice
	 * overlapping deletions. The dropped edits converge on a later `--fix` pass.
	 */
	private static function nonOverlappingEdits(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		final kept: Array<{ span: Span, text: String }> = [];
		var lastTo: Int = -1;
		for (e in sorted) if (e.span.from >= lastTo) {
			kept.push(e);
			lastTo = e.span.to;
		}
		return kept;
	}

	private static function collectClassBodies(node: QueryNode, out: Array<QueryNode>): Void {
		if (isClassBodyKind(node.kind)) out.push(node);
		for (child in node.children) collectClassBodies(child, out);
	}

	/**
	 * The end offset of `fn`'s LAST declared parameter, or -1 when it declares none.
	 */
	private static function lastParamEnd(fn: QueryNode, paramKinds: Array<String>): Int {
		var end: Int = -1;
		for (child in fn.children) if (paramKinds.contains(child.kind)) {
			final paramSpan: Null<Span> = child.span;
			if (paramSpan != null && paramSpan.to > end) end = paramSpan.to;
		}
		return end;
	}

	/**
	 * Whether the annotation at `annotationSpan` sits AFTER the parameter list — the test that tells a
	 * RETURN type from a type-parameter CONSTRAINT, which projects the same node kind in the same child
	 * slot but always precedes the parameter list.
	 *
	 * With at least one declared parameter the answer is purely structural: every constraint precedes
	 * the first parameter, so starting after the LAST one settles it, whatever the header contains.
	 * A parameterless function has no such landmark, so the empty list's `)` is located in the text
	 * between the preceding sibling and the annotation. That window is guarded: a `)` may also sit
	 * inside a structural constraint (`<A:{ function n():Void; }, B:Foo>`), which is why the search
	 * starts at `prevEnd` rather than at the function's start, and a comment in the window refuses
	 * outright rather than letting a `)` inside it stand in for the parameter list.
	 */
	private static function afterParamList(annotationSpan: Span, prevEnd: Int, lastParamEnd: Int, source: String): Bool {
		if (lastParamEnd >= 0) return annotationSpan.from > lastParamEnd;
		if (CheckScan.hasCommentMarker(source, prevEnd, annotationSpan.from)) return false;
		final close: Int = source.indexOf(')', prevEnd);
		return close != -1 && close < annotationSpan.from;
	}

	/**
	 * The text an always-true `if` leaves behind in its own place.
	 *
	 * Normally that is the body verbatim: a block self-terminates, is legal wherever an `if` statement was, and
	 * keeps the scope the braces held — the one substitution that is safe in every position. But when the `if`
	 * sits directly in a statement list, those braces buy nothing, and leaving them behind is how this fixer
	 * used to manufacture the bare blocks `unnecessary-block` then had to clean up on a later pass. So the
	 * braces are dropped when the parent is a statement-list container AND the body's own top-level bindings do
	 * not collide with that container's frame — the same gate, and the same scope model, `unnecessary-block`
	 * applies (`ScopeFrames.collidesWithScope` documents why a collision must refuse rather than shadow).
	 *
	 * An empty body keeps its braces: splicing nothing would delete the statement, which is `empty-block`'s
	 * call to make, not this one's. So does an over-weight one, at the same threshold `unnecessary-block`
	 * applies — see `BARE_BLOCK_MAX_STATEMENTS`.
	 */
	private static function keptBodyText(
		body: QueryNode, bs: Span, ifParent: Null<QueryNode>, frames: Map<QueryNode, Array<String>>, source: String,
		seams: CondSimplifySeams
	): String {
		final whole: String = source.substring(bs.from, bs.to);
		if (
			ifParent == null || body.kind != seams.blockStmtKind || body.children.length == 0
			|| body.children.length > BARE_BLOCK_MAX_STATEMENTS
		)
			return whole;
		final parent: QueryNode = ifParent;
		return seams.containerKinds.contains(parent.kind)
			&& !ScopeFrames.collidesWithScope(body.children, seams.localDeclKinds, frames[parent] ?? [])
			? source.substring(bs.from + 1, bs.to - 1).trim()
			: whole;
	}

}

/**
 * The result of `CheckScan.normalizeSpan`: the whitespace-collapsed text of a source
 * range (`norm`) and its non-whitespace character count (`nonWs`, the content-gate metric).
 */
typedef NormalizedSpan = {
	final norm: String;
	final nonWs: Int;
};

/** The condition / logical / block seam kinds `simplifyConditionFixes` reads from the grammar. */
private typedef CondSimplifySeams = {
	final ifKinds: Array<String>;
	final andKind: String;
	final orKind: String;
	final parenKind: String;
	final blockKinds: Array<String>;
	final blockStmtKind: Null<String>;
	final containerKinds: Array<String>;
	final scopeKinds: Array<String>;
	final functionKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final condKind: Null<String>;
};

/**
 * The condition-kind seams `NegationScan.negateConditionText` reads to invert a condition:
 * the logical-not (`notKind`) it strips, the paren (`parenKind`) it unwraps, the
 * `==` / `!=` kinds (`eqKind` / `notEqKind`) it flips, the atomic-expression kinds
 * (`atomicKinds`) that take a bare `!` rather than `!(…)`, and the logical
 * (`andKind` / `orKind`) kinds that word `simplify-negated-compound`'s finding — `andKind`
 * also discriminates the and-slot for `negateConditionText`'s STRIP arm.
 * `andLowerPrecedenceKinds` is the `RefShape` list `collapsible-if` merges with — it decides
 * the parenthesis pair when a caller asks for the negation as an operand of the
 * logical-and slot.
 */
typedef NegationSeams = {
	final notKind: Null<String>;
	final parenKind: Null<String>;
	final eqKind: Null<String>;
	final notEqKind: Null<String>;
	final atomicKinds: Array<String>;
	final andKind: Null<String>;
	final orKind: Null<String>;
	final andLowerPrecedenceKinds: Array<String>;
};

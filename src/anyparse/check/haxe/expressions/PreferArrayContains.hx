package anyparse.check.haxe.expressions;

import anyparse.check.Check.VersionGated;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions;
import anyparse.query.NodeShape;
import anyparse.query.ParenGuard;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;

using StringTools;

/** The resolved seams `PreferArrayContains` reads in both `run` and `fix`. */
private typedef Seams = {
	final callKind: String;
	final fieldAccessKind: String;
	final operators: Map<String, String>;
	final unaryMinusKinds: Array<String>;
	final numericLiteralKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final metaKinds: Array<String>;
};

/** An `xs.indexOf(v)` call: its receiver and the one value it searches for. */
private typedef Search = { final receiver: QueryNode; final value: QueryNode; };

/** A membership test: the comparison it spans, the search it reads and whether it asks for the value's ABSENCE. */
private typedef Site = { final span: Span; final search: Search; final absent: Bool; };

/**
 * Flags an `Array.indexOf` result compared against the not-found marker and rewrites it to `contains`, which states the
 * membership test directly: `xs.indexOf(v) < 0`, `== -1` and `-1 == xs.indexOf(v)` become `!xs.contains(v)`; `>= 0`, `!= -1`
 * and `> -1` become `xs.contains(v)`, each also with the operands on the other side (`0 > xs.indexOf(v)`, `-1 < xs.indexOf(v)`).
 * `Severity.Info`, with an autofix, never past a declared `languageVersion` older than `Array.contains`.
 *
 * ## What a site must be
 *
 * - **The receiver is an `Array`**, by its written or declared type or as an array literal. `String.indexOf` is a substring
 *   search and `contains` on a string is another call; a `Dynamic`, an `Any`, an untyped receiver and a `haxe.ds.Vector` have
 *   no proof and are left alone.
 * - **The call has one argument.** An `indexOf(v, fromIndex)` searches from a position and `contains` has no such form.
 * - **The result is used only as the test.** One that is assigned, passed or compared with any other number is a position, and
 *   stays.
 * - **No comment inside the comparison.**
 *
 * Both sides search by `==` and evaluate the receiver and the value once, so the rewrite reorders nothing; the one exception is a
 * NaN element on js with `js-es` 6 or later, where `contains` is `includes` (SameValueZero) and finds a NaN that `indexOf` does
 * not. Parentheses are `ParenGuard`'s, asked of the parser: the result is wrapped only where the `!` or the call would bind across
 * a postfix. A test nested in the value is rewritten by the next `--fix` pass.
 *
 * ## Grammar-agnostic
 *
 * Driven by `callKind`, `fieldAccessKind`, `eqKind`, `notEqKind`, `orderedComparisonOperators`, `unaryMinusKinds` and
 * `numericLiteralKinds`; a missing one, or a plugin without type information, makes the rule a no-op.
 */
@:nullSafety(Strict)
final class PreferArrayContains extends HaxeRule implements VersionGated {

	private static inline final RULE_ID: String = 'prefer-array-contains';
	private static inline final NEG_CHILD_COUNT: Int = 1;

	/** `Array.contains` is in the std of this version. */
	private static final MIN_VERSION: String = '4.0';

	private static final ARRAY_TYPE: String = 'Array';
	private static final SEARCH_METHOD: String = 'indexOf';
	private static final CONTAINS_CALL: String = '.contains(';
	private static final CLOSE: String = ')';
	private static final NEGATION: String = '!';
	private static final ZERO: String = '0';
	private static final ONE: String = '1';

	/** The comparison names `Seams.operators` maps a kind to; the ordered four are the grammar's own. */
	private static final EQUAL: String = 'eq';

	private static final UNEQUAL: String = 'ne';
	private static final LESS: String = 'lt';
	private static final GREATER_OR_EQUAL: String = 'ge';
	private static final GREATER: String = 'gt';

	/** The comparison of the same two operands with their sides swapped. */
	private static final MIRROR: Map<String, String> = [
		'eq' => 'eq',
		'ne' => 'ne',
		'lt' => 'gt',
		'gt' => 'lt',
		'le' => 'ge',
		'ge' => 'le'
	];

	/** Whether `call <comparison> 0` asks for the value's absence (true) or presence (false); a comparison not listed asks neither. */
	private static final AGAINST_ZERO: Map<String, Bool> = [LESS => true, GREATER_OR_EQUAL => false];

	/** The same for `call <comparison> -1`. */
	private static final AGAINST_MINUS_ONE: Map<String, Bool> = [EQUAL => true, UNEQUAL => false, GREATER => false];

	public function new() {
		super(
			RULE_ID, 'an Array.indexOf result compared against the not-found marker, replaceable with contains', RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, seamsOf(plugin), (entry, tree, seams, out) -> {
			for (site in proved(tree, entry.file, entry.source, plugin, seams, index())) out.push({
				file: entry.file,
				span: site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this indexOf() comparison tests membership: it can be ${site.absent ? '!' : ''}contains()'
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = seamsOf(plugin);
		final tree: Null<QueryNode> = seams == null || violations.length == 0 ? null : ParseGate.parseOrNull(plugin, source);
		if (seams == null || tree == null) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final wanted: Array<String> = violations.map(v -> spanKey(v.span));
		final scope: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		final edits: Array<GuardedEdit> = [
			for (site in proved(tree, file, source, plugin, seams, scope())) if (wanted.contains(spanKey(site.span))) rewrite(site, source)
		];
		return ParenGuard.guard(source, edits, plugin);
	}

	public function minLanguageVersion(): String {
		return MIN_VERSION;
	}

	/** The membership tests of `tree` whose receiver is proved an `Array`. */
	private static function proved(
		tree: QueryNode, file: String, source: String, plugin: GrammarPlugin, s: Seams, index: Null<SymbolIndex>
	): Array<Site> {
		final sites: Array<Site> = [];
		collect(tree, source, ElementSpan.lazyRegions(source, plugin), s, sites);
		if (sites.length == 0) return sites;
		final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, index);
		return nominal == null ? [] : sites.filter(site -> nominal(site.search.receiver) == ARRAY_TYPE);
	}

	/** Every membership test under `node`, the outermost only: a test nested in the value is found by the next pass. */
	private static function collect(node: QueryNode, source: String, regions: () -> Array<LexRegion>, s: Seams, out: Array<Site>): Void {
		if (s.opaqueKinds.contains(node.kind) || s.metaKinds.contains(node.kind)) return;
		final site: Null<Site> = siteAt(node, source, regions, s);
		if (site != null) {
			out.push(site);
			return;
		}
		for (c in node.children) collect(c, source, regions, s, out);
	}

	/** `node` read as a membership test, or null for any other node and for one carrying a comment the rewrite would drop. */
	private static function siteAt(node: QueryNode, source: String, regions: () -> Array<LexRegion>, s: Seams): Null<Site> {
		final span: Null<Span> = node.span;
		final comparison: Null<String> = s.operators[node.kind];
		if (span == null || comparison == null || !NodeShape.hasComparisonShape(node)) return null;
		final left: QueryNode = node.children[0];
		final right: QueryNode = node.children[1];
		final leftSearch: Null<Search> = searchOf(left, s);
		final rightSearch: Null<Search> = searchOf(right, s);
		// Read as if the call stood on the left: the sides swap and the comparison mirrors.
		final search: Null<Search> = leftSearch ?? rightSearch;
		final bound: Null<Int> = integerOf(leftSearch == null ? left : right, source, s);
		final absent: Null<Bool> = search == null || bound == null
			? null
			: asksAbsence(leftSearch == null ? MIRROR[comparison] ?? comparison : comparison, bound);
		return absent == null || search == null || LexicalRegions.commentIntersects(span.from, span.to, regions())
			? null
			: { span: span, search: search, absent: absent };
	}

	/** Whether `call <comparison> bound` asks for the value's absence (true) or presence (false); null when it asks neither. */
	private static function asksAbsence(comparison: String, bound: Int): Null<Bool> {
		return if (bound == 0)
			AGAINST_ZERO[comparison]
		else if (bound == -1)
			AGAINST_MINUS_ONE[comparison]
		else
			null;
	}

	/** The one-argument `indexOf` call that `node` is, or null. */
	private static function searchOf(node: QueryNode, s: Seams): Null<Search> {
		if (node.kind != s.callKind || !NodeShape.hasOneArgCallShape(node)) return null;
		final callee: QueryNode = node.children[0];
		return callee.kind == s.fieldAccessKind && callee.name == SEARCH_METHOD && callee.children.length == 1
			? { receiver: callee.children[0], value: node.children[1] }
			: null;
	}

	/** `0` or `-1` as written, the only two numbers an `indexOf` result is held against to ask for membership; else null. */
	private static function integerOf(node: QueryNode, source: String, s: Seams): Null<Int> {
		if (s.unaryMinusKinds.contains(node.kind) && node.children.length == NEG_CHILD_COUNT)
			return isNumber(node.children[0], ONE, source, s) ? -1 : null;
		return isNumber(node, ZERO, source, s) ? 0 : null;
	}

	private static function isNumber(node: QueryNode, text: String, source: String, s: Seams): Bool {
		final span: Null<Span> = node.span;
		return span != null && s.numericLiteralKinds.contains(node.kind) && source.substring(span.from, span.to) == text;
	}

	/** The edit writing the test as `[!]receiver.contains(value)`, the receiver and the value holes for `ParenGuard`. */
	private static function rewrite(site: Site, source: String): GuardedEdit {
		final receiver: String = textOf(site.search.receiver, source);
		final value: String = textOf(site.search.value, source);
		final prefix: Int = site.absent ? NEGATION.length : 0;
		final valueFrom: Int = prefix + receiver.length + CONTAINS_CALL.length;
		return {
			span: site.span,
			text: (site.absent ? NEGATION : '') + receiver + CONTAINS_CALL + value + CLOSE,
			holes: [
				new Span(prefix, prefix + receiver.length),
				new Span(valueFrom, valueFrom + value.length)
			]
		};
	}

	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	private static function spanKey(span: Null<Span>): String {
		return span == null ? '' : '${span.from}:${span.to}';
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final eqKind: Null<String> = shape.eqKind;
		final notEqKind: Null<String> = shape.notEqKind;
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final ordered: Null<Map<String, String>> = shape.execution?.orderedComparisonOperators;
		final unaryMinusKinds: Array<String> = shape.unaryMinusKinds ?? [];
		final numericLiteralKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (
			callKind == null || fieldAccessKind == null || eqKind == null || notEqKind == null || ordered == null
			|| unaryMinusKinds.length == 0 || numericLiteralKinds.length == 0
			|| !(plugin is TypeInfoProvider)
		)
			return null;
		final operators: Map<String, String> = [eqKind => EQUAL, notEqKind => UNEQUAL];
		for (kind => name in ordered) operators[kind] = name;
		return {
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			operators: operators,
			unaryMinusKinds: unaryMinusKinds,
			numericLiteralKinds: numericLiteralKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			metaKinds: plugin.metaShape().metaKinds
		};
	}

}

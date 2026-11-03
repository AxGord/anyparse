package anyparse.check.haxe.expressions;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Supersedes;
import anyparse.check.scan.IfExpressionChain;
import anyparse.check.scan.PurityScan;
import anyparse.check.scan.RunScan;
import anyparse.query.DeclaredNullity;
import anyparse.query.IndexScope;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.query.TypingService;

using StringTools;

/**
 * Flags a sort callback that spells a three-way comparison of two values by hand where `Reflect.compare(a, b)` says it.
 * `Severity.Info`, with an autofix.
 *
 *     xs.sort((a, b) -> a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
 *     // -> xs.sort((a, b) -> Reflect.compare(a.path, b.path));
 *
 * The forms are the ternary chain, the if-expression chain, and the statement chain closing a function body — `if (a < b)
 * return -1; if (a > b) return 1; return 0;` and the same as one `else if` chain. A descending chain (`a < b ? 1 : a > b
 * ? -1 : 0`) is the ascending one with its operands swapped, so the fix swaps them.
 *
 * ## What a site must be
 *
 * - **A sort callback.** The function literal, of two parameters, is an argument of a call named `sort`. Only the SIGN of
 *   a comparator's result is read there, and `Reflect.compare` promises a sign, not `-1` / `1`.
 * - **Two strict comparisons of the SAME two operands in opposite directions**, valued `-1` and `1` in either order,
 *   and `0` for the rest. `<=`, `>=` and `==` arms are another function and stay silent.
 * - **Both operands `Int`, or both `String`.** A `Float` operand is out: a `NaN` makes the chain answer `0` where
 *   `Reflect.compare` answers a sign. An operand of unknown type stays silent.
 * - **Pure operands.** The chain reads each operand twice, the call once.
 * - **No comment in the replaced text.** The fix would delete it.
 *
 * ## Where the fix is offered
 *
 * `Reflect.compare` answers `-1` for `null` against any value in BOTH argument orders, where the chain answers `0`: a
 * rewrite there changes an answer. So the fix is offered only where both operands are proved non-null by
 * `TypeResolver.isProvablyNonNull` (a local or parameter of a type that excludes `null`). Anything it cannot prove — a
 * field of another value, whose uninitialised `Int` reads `undefined` on a dynamic target — is still reported, without a
 * fix.
 *
 * `Reflect.compare` compares as `Dynamic`, which a static target may box: a speed-critical sort there keeps the explicit
 * chain, hence `DefaultOff`.
 *
 * ## Option
 *
 * `inline: true` (default `false`) makes the fix write `inline Reflect.compare(a, b)`: the call-site `inline` removes the cost of
 * the call on hxcpp. It stays off because not every target survives it: on hl, where `Reflect.compare` is a native stub with a
 * placeholder body, the inline writes that body and the comparator answers `0` with no error; on jvm it does not compile over
 * `Int`. The report and the message do not depend on it.
 */
@:nullSafety(Strict)
final class PreferReflectCompare extends HaxeRule implements DefaultOff implements Supersedes implements ConfigAware {

	private static inline final RULE_ID: String = 'prefer-reflect-compare';

	/** The method whose callback is read for its sign only. */
	private static inline final SORT: String = 'sort';

	private static inline final COMPARE: String = 'Reflect.compare';

	/** The option that makes the fix write the call as `inline Reflect.compare(…)`; off by default. */
	private static inline final OPTION_INLINE: String = 'inline';

	private static inline final INLINE_PREFIX: String = 'inline ';
	private static inline final LESS: String = 'lt';
	private static inline final GREATER: String = 'gt';

	/** A callback of this many parameters is a comparator. */
	private static inline final COMPARATOR_PARAMS: Int = 2;

	/** A chain of this many comparisons, then a terminal value, is a three-way comparison. */
	private static inline final RUNGS: Int = 2;

	private static inline final ELSE_SLOT: Int = 2;
	private static inline final ASCENDING: String = '-1';
	private static inline final DESCENDING: String = '1';
	private static inline final EQUAL: String = '0';

	/** The linter's per-file config resolver (`inline`), or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a sort callback spelling a three-way comparison by hand where Reflect.compare(a, b) says it',
			RuleCategory.Expressions
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, out) -> {
			for (m in matches(tree, entry.file, entry.source, seams, plugin, index)) out.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this sort callback spells ${m.call} by hand'
				+ (m.fixable ? '' : '; no fix, an operand may be null and the call then answers differently')
			});
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final inlined: Bool = LintConfig.resolveWith(_resolveConfig, file).boolOption(RULE_ID, OPTION_INLINE) ?? false;
		final scope: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		return CheckScan.applyTextMatches(
			plugin, source, violations, (tree, text) -> edits(matches(tree, file, text, seams, plugin, scope), inlined)
		);
	}

	public function supersedes(): Array<String> {
		return ['prefer-if-expression-chain', 'prefer-if-expression-return'];
	}

	/** Every hand-written three-way comparison in a sort callback under `tree`. */
	private static function matches(
		tree: QueryNode, file: String, source: String, seams: Seams, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>
	): Array<Match> {
		final out: Array<Match> = [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		var typed: Null<Typed> = null;
		var built: Bool = false;
		function typing(): Null<Typed> {
			if (!built) {
				built = true;
				final idx: Null<SymbolIndex> = index();
				final purity: Null<PurityCtx> = idx == null ? null : PurityScan.contextOf(plugin, source, tree, idx);
				final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, idx);
				final nullity: DeclaredNullity = DeclaredNullity.of(
					file, tree, source, seams.shape, RunScan.typeInfoOf(plugin), plugin.typeSyntax, index
				);
				typed = purity == null || nominal == null ? null : {
					purity: purity,
					nominal: nominal,
					nonNull: operand -> TypeResolver.isProvablyNonNull(operand, tree, seams.shape, nullity)
				};
			}
			return typed;
		}
		function walk(node: QueryNode): Void {
			final callee: Null<QueryNode> = node.children[0];
			if (node.kind == seams.callKind && callee != null && callee.kind == seams.fieldAccessKind && callee.name == SORT) {
				for (arg in node.children) if (isComparator(arg, seams)) fromCallback(arg, source, seams, typing, comments, out);
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	private static function isComparator(node: QueryNode, s: Seams): Bool {
		return s.lambdaKinds.contains(node.kind) && node.children.count(c -> s.paramKinds.contains(c.kind)) == COMPARATOR_PARAMS;
	}

	/** The comparisons a callback's body holds: its value, a returned value, or the statements closing it. */
	private static function fromCallback(
		fn: QueryNode, source: String, s: Seams, typing: () -> Null<Typed>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		out: Array<Match>
	): Void {
		final body: Null<QueryNode> = fn.children[fn.children.length - 1];
		if (body == null) return;
		final chains: Array<Chain> = [];
		if (s.blockKinds.contains(body.kind)) {
			final stmts: Array<QueryNode> = body.children;
			for (st in stmts) {
				final value: Null<QueryNode> = returnValue(st, s);
				if (value != null) addIfSome(chains, valueChain(value, s));
			}
			final last: Null<QueryNode> = stmts[stmts.length - 1];
			if (last != null)
				addIfSome(chains, s.ifStatementKinds.contains(last.kind) ? statementChain(last, s) : sequentialChain(stmts, s));
		} else {
			final inner: QueryNode = s.expressionBodyKinds.contains(body.kind) && body.children.length == 1 ? body.children[0] : body;
			addIfSome(chains, valueChain(returnValue(inner, s) ?? inner, s));
		}
		for (chain in chains) {
			final called: Null<Called> = comparison(chain, source, s, typing);
			final extent: Span = IfExpressionChain.tokenSpan(chain.extent, source, comments);
			if (called == null || CheckScan.hasCommentMarker(source, extent.from, extent.to)) continue;
			out.push(matched(chain, extent, called));
		}
	}

	private static function matched(chain: Chain, extent: Span, called: Called): Match {
		return {
			span: extent,
			call: called.call,
			fixable: called.nonNull,
			asReturn: chain.asReturn
		};
	}

	private static function rung(cond: QueryNode, value: QueryNode): Rung {
		return { cond: cond, value: value };
	}

	private static function addIfSome(chains: Array<Chain>, chain: Null<Chain>): Void {
		if (chain != null) chains.push(chain);
	}

	/**
	 * The ternary or if-expression chain `node` is, parentheses peeled at the head and at every `else`. It stays beside
	 * `IfExpressionChain.unrollTernaryTail`, which unrolls ternary links only and leaves an `else` link's parentheses.
	 */
	private static function valueChain(node: QueryNode, s: Seams): Null<Chain> {
		final rungs: Array<Rung> = [];
		final head: QueryNode = BoolExprShape.unwrapParens(node, s.parenKind);
		var at: QueryNode = head;
		while ((at.kind == s.ternaryKind || s.ifExpressionKinds.contains(at.kind)) && at.children.length == ELSE_SLOT + 1) {
			rungs.push(rung(at.children[0], at.children[1]));
			at = BoolExprShape.unwrapParens(at.children[ELSE_SLOT], s.parenKind);
		}
		return chained(head, rungs, at);
	}

	/** An `if (…) return v; else if (…) return v; else return v;` chain. */
	private static function statementChain(node: QueryNode, s: Seams): Null<Chain> {
		final found: Null<IfChain> = IfExpressionChain.collect(node, s.ifStatementKinds, s.blockStmtKind, RUNGS);
		final extent: Null<Span> = node.span;
		return found == null || extent == null ? null : returning(found, extent, s);
	}

	/** `if (…) return v; if (…) return v; return v;` closing a block. */
	private static function sequentialChain(stmts: Array<QueryNode>, s: Seams): Null<Chain> {
		final n: Int = stmts.length;
		if (n < RUNGS + 1) return null;
		final found: Null<IfChain> = IfExpressionChain.collectCascade(stmts, n - RUNGS - 1, s.ifStatementKinds, s.blockStmtKind, RUNGS);
		final from: Null<Span> = stmts[n - RUNGS - 1].span;
		final to: Null<Span> = stmts[n - 1].span;
		return found == null || from == null || to == null ? null : returning(found, new Span(from.from, to.to), s);
	}

	/** The chain `found` is when it is exactly two rungs and a terminal that each return a value. */
	private static function returning(found: IfChain, extent: Span, s: Seams): Null<Chain> {
		if (found.branches.length != RUNGS) return null;
		final first: Null<QueryNode> = returnValue(found.branches[0].stmt, s);
		final second: Null<QueryNode> = returnValue(found.branches[1].stmt, s);
		final terminal: Null<QueryNode> = returnValue(found.terminal, s);
		return first == null || second == null || terminal == null ? null : {
			rungs: [rung(found.branches[0].cond, first), rung(found.branches[1].cond, second)],
			terminal: terminal,
			extent: extent,
			asReturn: true
		};
	}

	/** The value a `return v;` statement returns. */
	private static function returnValue(node: QueryNode, s: Seams): Null<QueryNode> {
		return s.returnKinds.contains(node.kind) && node.children.length == 1 ? node.children[0] : null;
	}

	/**
	 * The `Reflect.compare(…)` call the chain computes, or null when it computes something else or cannot be proved to. It
	 * answers `nonNull` only when both operands are proved non-null: on `null` the call answers `-1` in both argument
	 * orders where the chain answers `0`, so a rewrite there changes an answer.
	 */
	private static function comparison(chain: Chain, source: String, s: Seams, typing: () -> Null<Typed>): Null<Called> {
		final first: Null<Order> = order(chain.rungs[0].cond, s);
		final second: Null<Order> = order(chain.rungs[1].cond, s);
		final v1: String = valueText(chain.rungs[0].value, source, s);
		final v2: String = valueText(chain.rungs[1].value, source, s);
		if (first == null || second == null) return null;
		if (
			valueText(chain.terminal, source, s) != EQUAL
			|| (v1 != ASCENDING || v2 != DESCENDING)
			&& (v1 != DESCENDING || v2 != ASCENDING)
			|| !IfExpressionChain.sameSource(first.smallNode, second.bigNode, source)
			|| !IfExpressionChain.sameSource(first.bigNode, second.smallNode, source)
		)
			return null;
		final t: Null<Typed> = typing();
		if (t == null) return null;
		final left: QueryNode = v1 == ASCENDING ? first.smallNode : first.bigNode;
		final right: QueryNode = v1 == ASCENDING ? first.bigNode : first.smallNode;
		final type: Null<String> = t.nominal(left);
		return type != null
			&& (type == s.intType || type == s.stringType)
			&& t.nominal(right) == type
			&& PurityScan.isPure(left, t.purity)
			&& PurityScan.isPure(right, t.purity)
			? { call: '$COMPARE(${textOf(left, source)}, ${textOf(right, source)})', nonNull: t.nonNull(left) && t.nonNull(right) }
			: null;
	}

	/** The two operands of a strict comparison, the smaller first. */
	private static function order(cond: QueryNode, s: Seams): Null<Order> {
		final node: QueryNode = BoolExprShape.unwrapParens(cond, s.parenKind);
		if (node.children.length != 2) return null;
		final lhs: QueryNode = node.children[0];
		final rhs: QueryNode = node.children[1];
		final ascending: Bool = node.kind == s.ltKind;
		return !ascending && node.kind != s.gtKind ? null : { smallNode: ascending ? lhs : rhs, bigNode: ascending ? rhs : lhs };
	}

	/** An integer literal's text, spaces dropped; empty for anything else. */
	private static function valueText(node: QueryNode, source: String, s: Seams): String {
		return s.valueKinds.contains(node.kind) ? textOf(node, source).split(' ').join('') : '';
	}

	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final lt: Null<String> = orderedKind(shape, LESS);
		final gt: Null<String> = orderedKind(shape, GREATER);
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final ternaryKind: Null<String> = shape.ternaryKind;
		final ifStatementKinds: Null<Array<String>> = shape.ifStatementKinds;
		final returnKinds: Null<Array<String>> = shape.valueReturnKinds;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final intType: Null<String> = shape.coreValueTypes?.integer;
		final stringType: Null<String> = TypingService.stringType(shape);
		return lt == null
			|| gt == null
			|| callKind == null
			|| fieldAccessKind == null
			|| ternaryKind == null
			|| ifStatementKinds == null
			|| returnKinds == null
			|| lambdaKinds == null
			|| paramKinds == null
			|| blockKinds.length == 0
			|| blockStmtKind == null
			|| intType == null
			|| stringType == null
			? null
			: {
				ltKind: lt,
				gtKind: gt,
				callKind: callKind,
				fieldAccessKind: fieldAccessKind,
				ternaryKind: ternaryKind,
				ifExpressionKinds: shape.ifExpressionKinds ?? [],
				ifStatementKinds: ifStatementKinds,
				returnKinds: returnKinds,
				expressionBodyKinds: shape.expressionBodyKinds ?? [],
				lambdaKinds: lambdaKinds,
				paramKinds: paramKinds,
				blockKinds: blockKinds,
				blockStmtKind: blockStmtKind,
				shape: shape,
				parenKind: shape.parenKind,
				valueKinds: (shape.numericLiteralKinds ?? []).concat(shape.unaryMinusKinds ?? []),
				intType: intType,
				stringType: stringType
			};
	}

	/** The chain `host` spells, when it is exactly the comparisons of a three-way comparison. */
	private static function chained(host: QueryNode, rungs: Array<Rung>, terminal: QueryNode): Null<Chain> {
		final extent: Null<Span> = host.span;
		return extent == null || rungs.length != RUNGS ? null : {
			rungs: rungs,
			terminal: terminal,
			extent: extent,
			asReturn: false
		};
	}

	/** The kind of the ordered comparison `op` (`lt`, `gt`), by the grammar's own naming. */
	private static function orderedKind(shape: RefShape, op: String): Null<String> {
		final ordered: Null<Map<String, String>> = shape.execution?.orderedComparisonOperators;
		return ordered == null ? null : [for (kind => named in ordered) if (named == op) kind][0];
	}

	/** The fixes of the matches that have one. */
	private static function edits(found: Array<Match>, inlined: Bool): Array<FixEdit> {
		final out: Array<FixEdit> = [];
		for (m in found) if (m.fixable) {
			final call: String = inlined ? INLINE_PREFIX + m.call : m.call;
			out.push(edit(m.span, m.asReturn ? 'return $call;' : call));
		}
		return out;
	}

	private static function edit(span: Span, text: String): FixEdit {
		return { span: span, text: text };
	}

}

private typedef Seams = {
	final ltKind: String;
	final gtKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final ternaryKind: String;
	final ifExpressionKinds: Array<String>;
	final ifStatementKinds: Array<String>;
	final returnKinds: Array<String>;
	final expressionBodyKinds: Array<String>;
	final lambdaKinds: Array<String>;
	final paramKinds: Array<String>;
	final blockKinds: Array<String>;
	final blockStmtKind: String;
	final parenKind: Null<String>;
	final shape: RefShape;
	final valueKinds: Array<String>;
	final intType: String;
	final stringType: String;
}

/** One comparison of the chain and the value it selects. */
private typedef Rung = { cond: QueryNode, value: QueryNode }

/** The chain, the span a fix replaces, and whether that span is statements (so the replacement is a `return`). */
private typedef Chain = {
	rungs: Array<Rung>,
	terminal: QueryNode,
	extent: Span,
	asReturn: Bool
}

/** The two operands of a strict comparison, the smaller first. */
private typedef Order = {
	smallNode: QueryNode,
	bigNode: QueryNode
}

/** What the type, purity and null proofs answer about an operand. */
private typedef Typed = {
	purity: PurityCtx,
	nominal: (QueryNode) -> Null<String>,
	nonNull: (QueryNode) -> Bool
}

/** The call a chain computes, and whether both its operands are proved non-null. */
private typedef Called = { call: String, nonNull: Bool }

/** A finding; `fixable` is false where the rewrite would not be behaviour-preserving. */
private typedef Match = {
	span: Span,
	call: String,
	fixable: Bool,
	asReturn: Bool
}

package anyparse.check.common.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.common.control.BranchChain;
import anyparse.check.common.control.CollapsibleIf;
import anyparse.check.scan.NumericLiteral;
import anyparse.query.Constructs;
import anyparse.query.MemberKinds;
import anyparse.query.SourceComments;
import anyparse.query.StableChain;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.UnchangedLocal;

/** The `RefShape` vocabulary `PreferModuloWrap` reads. */
private typedef Seams = {
	var shape: RefShape;
	var whileKind: String;
	var identKind: String;
	var exprStmtKind: String;
	var blockKinds: Array<String>;
	var blockKind: Null<String>;
	var ifKinds: Array<String>;
	var numericKinds: Array<String>;
	var geKinds: Array<String>;
	var ltKinds: Array<String>;
	var subtractAssignKinds: Array<String>;
	var addAssignKinds: Array<String>;
}

/** The per-file scan state: the source, its comment tokens, the seams and what proves a name keeps its value. */
private typedef Ctx = {
	var source: String;
	var tree: QueryNode;
	var seams: Seams;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	var locals: UnchangedLocal;
	var chains: StableChain;
	var declared: Null<Map<Int, String>>;
	var build: Null<Constructs>;
}

/** One loop of a wrap: its statement span, which edge it walks, the wrapped identifier and the step or bound it names. */
private typedef Half = {
	var span: Span;
	var upper: Bool;
	var target: QueryNode;
	var amount: QueryNode;
	var condition: QueryNode;
}

/** A flagged pair: the span covering both loops, the two replacement edits (null = report-only) and why it is report-only. */
private typedef Match = { var span: Span; var edits: Null<Array<FixEdit>>; var note: String; }

/**
 * Flags two adjacent loops that wrap a local into `[0, N)` one step at a time, `while (v >= N) v -= N;` and
 * `while (v < 0) v += N;` in either order, the upper one possibly still behind the `if (v >= N)` that
 * `redundant-if-before-while` removes. They are `v %= N; if (v < 0) v += N;`. `N` is one positive numeric literal
 * or one name nothing rebinds (`StableChain`), spelled the same in the bound and in both steps; `v` is a local or
 * parameter no function literal writes (`UnchangedLocal`). Only adjacent statements match, so nothing reads `v`
 * between the loops.
 *
 * `fix` applies when `v` is declared `Int`: `%` follows the sign of its dividend (checked on js), so the result is the
 * same for every input a terminating loop takes. A Float is report-only. `%` is an exact `fmod`, but the loops end a negative
 * multiple of `N` on `+0` where the rewrite ends on `-0`, the second loop of the other order can round a tiny negative up to `N` before
 * the first one subtracts it, and a fractional `N` makes the repeated step round. A type no annotation names is
 * report-only too. Where the loops would never end (`N` a name that is zero, a Float beyond the step's resolution, an
 * infinity) the rewrite ends. A negative `N` is no wrap at all: where Int overflows at 32 bits the loops end on a value the
 * rewrite does not give. The double-modulo `((v % N) + N) % N` is never
 * offered: its `+ N` rounds an in-range Float.
 *
 * ## Grammar-agnostic
 *
 * Kinds come from `RefShape` (`whileStmtKind`, `ifStatementKinds`, `exprStatementKind`, the block kinds, and
 * `ExecutionShape.orderedComparisonOperators` / `compoundAssignOperators` / `integerFoldOperators` for `>=`, `<`,
 * `-=` and `+=`); any unset makes the check a no-op.
 */
@:nullSafety(Strict)
final class PreferModuloWrap extends RuleBase {

	private static final MESSAGE: String = 'these loops wrap a value into [0, N) one step at a time: v %= N; if (v < 0) v += N; does it';
	private static final COMMENT_NOTE: String = ' (comment inside - merge by hand)';
	private static final TYPE_NOTE: String =
		' (v is not declared Int: a negative multiple of N would end as -0 and a fractional N rounds differently - merge by hand)';
	private static final INT_TYPE: String = 'Int';

	public function new() {
		super(
			'prefer-modulo-wrap',
			'two adjacent loops wrapping a local into [0, N) by repeated subtraction and addition of N — v %= N; if (v < 0) v += N;',
			RuleCategory.Loops
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in scan(tree, entry.source, plugin, entry.file, seams, symbols)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'prefer-modulo-wrap',
				severity: Severity.Warning,
				message: MESSAGE + m.note
			});
		});
	}

	/** Replace the first loop of each flagged pair with `v %= N;` and the second with `if (v < 0) v += N;`. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.matchedEdits(
			plugin, source, readSeams(plugin), violations, index,
			(tree, seams, symbols, file) -> scan(tree, source, plugin, file, seams, symbols), m -> m.edits ?? []
		);
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final whileKind: Null<String> = shape.whileStmtKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final compound: Map<String, String> = shape.execution?.compoundAssignOperators ?? [];
		final fold: Map<String, String> = shape.execution?.integerFoldOperators ?? [];
		final order: Map<String, String> = shape.execution?.orderedComparisonOperators ?? [];
		final subtractAssignKinds: Array<String> = kindsOf(compound, fold, 'subtract');
		final addAssignKinds: Array<String> = kindsOf(compound, fold, 'add');
		final geKinds: Array<String> = kindsOf(order, null, 'ge');
		final ltKinds: Array<String> = kindsOf(order, null, 'lt');
		return whileKind == null || exprStmtKind == null || ifKinds.length == 0 || subtractAssignKinds.length == 0
			|| addAssignKinds.length == 0 || geKinds.length == 0 || ltKinds.length == 0
			? null
			: {
				shape: shape,
				whileKind: whileKind,
				identKind: shape.identKind,
				exprStmtKind: exprStmtKind,
				blockKinds: [ for (k in [shape.blockStmtKind, shape.blockBodyKind]) if (k != null) k ],
				blockKind: shape.blockStmtKind,
				ifKinds: ifKinds,
				numericKinds: shape.numericLiteralKinds ?? [],
				geKinds: geKinds,
				ltKinds: ltKinds,
				subtractAssignKinds: subtractAssignKinds,
				addAssignKinds: addAssignKinds
			};
	}

	private static function scan(
		tree: QueryNode, source: String, plugin: GrammarPlugin, file: String, seams: Seams, symbols: () -> Null<SymbolIndex>
	): Array<Match> {
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final locals: UnchangedLocal = new UnchangedLocal(tree, seams.shape);
		final out: Array<Match> = [];
		walk(tree, {
			source: source,
			tree: tree,
			seams: seams,
			comments: SourceComments.collectCommentTokens(plugin.lexicalRegions(source)),
			locals: locals,
			chains: new StableChain(tree, seams.shape, locals, TypeInfoMemo.declaredTypeSources(typed, source), symbols, file),
			declared: typed?.declaredTypes(source),
			build: plugin.constructs()
		}, out);
		return out;
	}

	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.blockKinds.contains(node.kind)) {
			var i: Int = 0;
			while (i + 1 < node.children.length) {
				final m: Null<Match> = matchPair(node.children[i], node.children[i + 1], ctx);
				if (m != null) out.push(m);
				i += m == null ? 1 : 2;
			}
		}
		for (c in node.children) walk(c, ctx, out);
	}

	private static function matchPair(first: QueryNode, second: QueryNode, ctx: Ctx): Null<Match> {
		final a: Null<Half> = half(first, ctx.seams);
		if (a == null) return null;
		final b: Null<Half> = half(second, ctx.seams);
		if (b == null || a.upper == b.upper) return null;
		final upper: Half = a.upper ? a : b;
		final lower: Half = a.upper ? b : a;
		final name: Null<String> = a.target.name;
		if (name == null || name != b.target.name || !MemberKinds.structurallyEqual(upper.amount, lower.amount)) return null;
		if (!ctx.locals.survivesCalls(a.target) || !positiveAmount(upper.amount, name, ctx)) return null;
		final from: Span = a.span;
		final to: Span = b.span;
		final span: Span = new Span(from.from, to.to);
		final bound: Null<Span> = upper.amount.span;
		if (bound == null) return null;
		final note: String = refusal(a.target, span, ctx);
		return { span: span, note: note, edits: note == '' ? wrapEdits(from, to, upper, lower, bound, ctx) : null };
	}

	/** The loop `stmt` is when it walks one edge of a wrap — `while (v >= N) v -= N;` or `while (v < 0) v += N;` — else null. */
	private static function half(stmt: QueryNode, s: Seams): Null<Half> {
		final span: Null<Span> = stmt.span;
		final loop: Null<QueryNode> = loopOf(stmt, s);
		if (span == null || loop == null) return null;
		final cond: QueryNode = LoopScan.whileCondition(loop);
		final upper: Bool = s.geKinds.contains(cond.kind);
		if ((!upper && !s.ltKinds.contains(cond.kind)) || cond.children.length != 2 || (loop != stmt && !upper)) return null;
		final target: QueryNode = cond.children[0];
		final step: Null<QueryNode> = stepOf(loop, upper ? s.subtractAssignKinds : s.addAssignKinds, s);
		if (step == null || target.kind != s.identKind || step.children[0].name != target.name) return null;
		final bound: QueryNode = cond.children[1];
		return (upper ? !MemberKinds.structurallyEqual(bound, step.children[1]) : !isZero(bound, s)) ? null : {
			span: span,
			upper: upper,
			target: target,
			amount: upper ? bound : step.children[1],
			condition: cond
		};
	}

	/** A numeric literal of value zero (`0`, `0.0`). */
	private static function isZero(node: QueryNode, s: Seams): Bool {
		return s.numericKinds.contains(node.kind) && NumericLiteral.valueOf(node.name ?? '') == 0;
	}

	/** Whether `amount` is a positive numeric literal, or a name other than the wrapped one that nothing rebinds. */
	private static function positiveAmount(amount: QueryNode, wrapped: String, ctx: Ctx): Bool {
		final s: Seams = ctx.seams;
		if (!s.numericKinds.contains(amount.kind))
			return amount.kind == s.identKind && amount.name != wrapped && ctx.chains.read(amount) != null;
		final value: Null<Float> = NumericLiteral.valueOf(amount.name ?? '');
		return value != null && value > 0;
	}

	/** Why the fix is refused, or the empty string when the rewrite is safe. */
	private static function refusal(target: QueryNode, span: Span, ctx: Ctx): String {
		for (c in ctx.comments) if (c.to > span.from && c.from < span.to) return COMMENT_NOTE;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(target, ctx.tree, ctx.seams.shape);
		final typeName: Null<String> = bindingFrom == null ? null : ctx.declared?.get(bindingFrom);
		return typeName == INT_TYPE ? '' : TYPE_NOTE;
	}

	/** The `while` a statement is: itself, or the one an `if` with the same condition and no `else` holds; else null. */
	private static function loopOf(stmt: QueryNode, s: Seams): Null<QueryNode> {
		var loop: QueryNode = stmt;
		if (s.ifKinds.contains(stmt.kind)) {
			if (!BranchChain.hasThen(stmt) || BranchChain.hasElse(stmt)) return null;
			loop = CollapsibleIf.unwrapBlock(BranchChain.thenOf(stmt), s.blockKind);
			if (loop.kind != s.whileKind || !LoopScan.hasWhileShape(loop)) return null;
			if (!MemberKinds.structurallyEqual(BranchChain.condOf(stmt), LoopScan.whileCondition(loop))) return null;
		}
		return loop.kind == s.whileKind && LoopScan.hasWhileShape(loop) ? loop : null;
	}

	/** The compound assignment of `kinds` that is the whole body of `loop`, writing an identifier; else null. */
	private static function stepOf(loop: QueryNode, kinds: Array<String>, s: Seams): Null<QueryNode> {
		final body: QueryNode = CollapsibleIf.unwrapBlock(LoopScan.whileBody(loop), s.blockKind);
		if (body.kind != s.exprStmtKind || body.children.length != 1) return null;
		final step: QueryNode = body.children[0];
		return kinds.contains(step.kind) && step.children.length == 2 && step.children[0].kind == s.identKind ? step : null;
	}

	/** The kinds whose meaning is `meaning`, read off `from` or, given `via`, through the operator kind `from` names. */
	private static function kindsOf(from: Map<String, String>, via: Null<Map<String, String>>, meaning: String): Array<String> {
		return [ for (kind => name in from) if ((via == null ? name : via[name]) == meaning) kind ];
	}

	/**
	 * The two statements replacing a wrap's loops, asked of the grammar: `v %= N;` over `first` and `if (v < 0) v += N;` over
	 * `second`, with the bound `bound` and the lower loop's own condition copied. Null when the grammar builds either one not.
	 */
	private static function wrapEdits(first: Span, second: Span, upper: Half, lower: Half, bound: Span, ctx: Ctx): Null<Array<FixEdit>> {
		final build: Null<Constructs> = ctx.build;
		final targetSpan: Null<Span> = upper.target.span;
		final belowSpan: Null<Span> = lower.condition.span;
		if (build == null || targetSpan == null || belowSpan == null) return null;
		final target: Null<Built> = build.copied(ctx.source, targetSpan, Expression);
		final amount: Null<Built> = build.copied(ctx.source, bound, Expression);
		final below: Null<Built> = build.copied(ctx.source, belowSpan, Expression);
		if (target == null || amount == null || below == null) return null;
		final wrapped: Null<Built> = build.compoundAssignment(target, Remainder, amount);
		final step: Null<Built> = build.compoundAssignment(target, Add, amount);
		final raised: Null<Built> = step == null ? null : build.conditional(below, step);
		return wrapped == null || raised == null ? null : [{ span: first, text: wrapped.text }, { span: second, text: raised.text }];
	}

}

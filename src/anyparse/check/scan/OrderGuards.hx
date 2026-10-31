package anyparse.check.scan;

import anyparse.query.Refs;
import anyparse.query.ShapeVocab;
import anyparse.query.UnchangedLocal;
import anyparse.query.WriteSites;

/** An integer sum of operands plus a constant: `len - k + 1` is `{len: 1, k: -1}` and `1`, each operand by its storage key. */
typedef LinearTerm = {
	final terms: Map<String, Int>;
	final constant: Int;
};

/**
 * A term known `>= 0` throughout `region`, the code its condition guards. `cause` is the condition that proved it, which
 * runs between the comparison and the region, so a write or call there may change an operand too.
 */
typedef Bound = {
	final term: LinearTerm;
	final region: Span;
	final cause: Null<Span>;
};

/** One file's inputs to `OrderGuards.provesNonNegative`, built by `OrderGuards.contextOf`. */
typedef OrderContext = {
	final seams: OrderSeams;
	final tree: QueryNode;
	final source: String;
	final writes: Array<WriteSite>;
	final effects: CallEffects;
	final calls: Array<CallSite>;
	final locals: UnchangedLocal;
	final survivors: Map<String, Bool>;
};

/**
 * What the caller's typing knows about calls, for a bound over storage a call might change: a hook the caller fills
 * from the owners, never an answer of its own — whether a call is effect-free is `StdlibPurity.isEffectFreeCallee`'s.
 */
typedef CallEffects = {

	/** Whether the call or construction `call` changes no storage the program can read. */
	final effectFree: (call:QueryNode) -> Bool;

	/** Whether the value `receiver` reads cannot change in place, so a member read off it changes only with the receiver. */
	final immutable: (receiver:QueryNode) -> Bool;
};

/** A call or construction, with the span of the innermost function literal or declaration holding it. */
typedef CallSite = {
	final node: QueryNode;
	final span: Span;
	final within: Null<Span>;
};

/** The grammar kinds `OrderGuards` reads, gathered once per run by `seamsOf`. */
typedef OrderSeams = {
	final shape: RefShape;
	final relations: Map<String, String>;
	final foldOps: Map<String, String>;
	final numericKinds: Array<String>;
	final negKinds: Array<String>;
	final parenKind: Null<String>;
	final notKind: Null<String>;
	final andKind: Null<String>;
	final orKind: Null<String>;
	final ternaryKind: Null<String>;
	final ifKinds: Array<String>;
	final forKind: Null<String>;
	final intervalKind: Null<String>;
	final blockKinds: Array<String>;
	final exitKinds: Array<String>;
	final barrierKinds: Array<String>;
	final callKinds: Array<String>;
	final memberKinds: Array<String>;
};

/**
 * Whether the conditions enclosing an integer expression prove it non-negative: the bounds a `&&` / `||` left operand, a
 * ternary or `if` condition, a `for` range, or an earlier exiting `if` of the same block hands the code it guards. A
 * `while` condition is not read: its body is where the operands it compares change. Each bound is a linear inequality
 * over operands (`n > k` is `n - k - 1 >= 0`), and the expression is proved when it differs from one bound by a
 * non-negative constant (`s.length > k ? s.substr(s.length - k) : s`).
 *
 * An operand is the storage it reads, keyed by `WriteSites.accessPath`, so a shadowing local or lambda parameter is
 * another operand, and one the binder cannot name matches nothing. A bound holds only while no write in the region it
 * guards, or in the condition that proved it, may change one of its operands (`WriteSites.mayOverlap`), and no bound
 * crosses a function literal, which may run after any write. A call there voids a bound over storage a callee may change
 * — a field, a static, a member read through a mutable receiver, a local a function literal writes — unless the caller's
 * typing knows it effect-free (`CallEffects`). Only a written call is seen: a property getter or setter, an implicit
 * `toString`, an abstract's operator overload run code no call node shows, and keep a bound they may void. An ordered
 * comparison is read as total, which holds for the integer operands an integer expression
 * shares with its guard (a `null` operand fails the expression too).
 */
@:nullSafety(Strict)
final class OrderGuards {

	/** The seams the guard reading needs; a grammar naming no ordered comparison proves constants alone. */
	public static function seamsOf(shape: RefShape): OrderSeams {
		return {
			shape: shape,
			relations: shape.execution?.orderedComparisonOperators ?? [],
			foldOps: shape.execution?.integerFoldOperators ?? [],
			numericKinds: shape.numericLiteralKinds ?? [],
			negKinds: shape.unaryMinusKinds ?? [],
			parenKind: shape.parenKind,
			notKind: shape.notKind,
			andKind: shape.logicalAndKind,
			orKind: shape.logicalOrKind,
			ternaryKind: shape.ternaryKind,
			ifKinds: (shape.ifStatementKinds ?? []).concat(shape.ifExpressionKinds ?? []),
			forKind: shape.forStmtKind,
			intervalKind: shape.intervalKind,
			blockKinds: [for (k in [shape.blockStmtKind, shape.blockBodyKind]) if (k != null) k],
			exitKinds: shape.controlExitKinds ?? [],
			barrierKinds: (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? [])
				.concat([for (k in [shape.namedFnExprKind]) if (k != null) k]),
			callKinds: [for (k in [shape.callKind, shape.newExprKind]) if (k != null) k],
			memberKinds: ShapeVocab.memberAccessKinds(shape)
		};
	}

	/** One file's inputs: its tree and source, every write and call in it, and what `effects` knows of the calls. */
	public static function contextOf(tree: QueryNode, source: String, seams: OrderSeams, effects: CallEffects): OrderContext {
		final calls: Array<CallSite> = [];
		function walk(node: QueryNode, within: Null<Span>): Void {
			final span: Null<Span> = node.span;
			var inner: Null<Span> = within;
			if (span != null && seams.barrierKinds.contains(node.kind)) inner = span;
			if (span != null && seams.callKinds.contains(node.kind)) {
				final at: Span = span;
				calls.push({ node: node, span: at, within: within });
			}
			for (c in node.children) walk(c, inner);
		}
		walk(tree, null);
		final locals: UnchangedLocal = new UnchangedLocal(tree, seams.shape);
		return {
			seams: seams,
			tree: tree,
			source: source,
			writes: locals.writes,
			effects: effects,
			calls: calls,
			locals: locals,
			survivors: []
		};
	}

	/**
	 * Whether `expr` is proved non-negative by its own constant value or by a bound of the conditions on `path`, the
	 * ancestors of `expr` from the root down to its parent.
	 */
	public static function provesNonNegative(expr: QueryNode, path: Array<QueryNode>, ctx: OrderContext): Bool {
		final value: LinearTerm = linear(expr, ctx);
		if (value.terms.empty()) return value.constant >= 0;
		for (bound in bounds(expr, path, ctx)) {
			final rest: LinearTerm = difference(value, bound.term);
			if (rest.terms.empty() && rest.constant >= 0 && unwritten(bound, ctx) && uncalled(bound, path, ctx)) return true;
		}
		return false;
	}

	/** `t - 1`: a strict bound over integers. */
	private static inline function minusOne(t: LinearTerm): LinearTerm {
		return { terms: t.terms, constant: t.constant - 1 };
	}

	/**
	 * Every bound the conditions on `path` hand `expr`. A function literal on the way down drops the bounds above it: its
	 * body runs whenever it is called, after any write.
	 */
	private static function bounds(expr: QueryNode, path: Array<QueryNode>, ctx: OrderContext): Array<Bound> {
		final seams: OrderSeams = ctx.seams;
		final out: Array<Bound> = [];
		for (i => node in path) {
			final child: QueryNode = i + 1 < path.length ? path[i + 1] : expr;
			final kids: Array<QueryNode> = node.children;
			final slot: Int = kids.indexOf(child);
			final region: Null<Span> = child.span;
			if (seams.barrierKinds.contains(node.kind)) out.resize(0);
			if (slot < 0 || region == null) continue;
			if ((node.kind == seams.andKind || node.kind == seams.orKind) && slot == 1)
				facts(kids[0], node.kind == seams.andKind, region, kids[0].span, ctx, out);
			else if ((node.kind == seams.ternaryKind || seams.ifKinds.contains(node.kind)) && slot > 0)
				facts(kids[0], slot == 1, region, kids[0].span, ctx, out);
			else if (node.kind == seams.forKind && slot == kids.length - 1)
				rangeFacts(node, region, ctx, out);
			else if (seams.blockKinds.contains(node.kind))
				for (k in 0...slot) exitGuardFacts(kids[k], node, ctx, out);
		}
		return out;
	}

	/**
	 * The bounds of a `for (i in lo...hi)` body: `i - lo >= 0` and `hi - i - 1 >= 0`. The binder is keyed by its
	 * own declaration, which the binder answers at the loop, the key `WriteSites.accessPath` gives every read of it.
	 */
	private static function rangeFacts(loop: QueryNode, body: Span, ctx: OrderContext, out: Array<Bound>): Void {
		final binder: Null<String> = loop.name;
		final range: Null<QueryNode> = loop.children.find(c -> c.kind == ctx.seams.intervalKind);
		final ends: Array<QueryNode> = range?.children ?? [];
		final declared: Null<Span> = loop.span;
		final binding: Null<Int> = binder == null || declared == null
			? null
			: Refs.bindingAt(binder, declared.from, ctx.tree, ctx.seams.shape);
		if (binder == null || binding == null || ends.length != 2) return;
		final i: LinearTerm = { terms: ['$binder@$binding' => 1], constant: 0 };
		out.push({ term: difference(i, linear(ends[0], ctx)), region: body, cause: range?.span });
		out.push({ term: minusOne(difference(linear(ends[1], ctx), i)), region: body, cause: range?.span });
	}

	/** The bounds an `if (c) <exit>` with no else hands the rest of `block`: `c` is false there. */
	private static function exitGuardFacts(stmt: QueryNode, block: QueryNode, ctx: OrderContext, out: Array<Bound>): Void {
		final kids: Array<QueryNode> = stmt.children;
		final guard: Null<Span> = stmt.span;
		final whole: Null<Span> = block.span;
		if (!ctx.seams.ifKinds.contains(stmt.kind) || kids.length != 2 || guard == null || whole == null) return;
		final body: QueryNode = kids[1];
		final run: Array<QueryNode> = ctx.seams.blockKinds.contains(body.kind) ? body.children : [body];
		if (run.length > 0 && ctx.seams.exitKinds.contains(run[run.length - 1].kind))
			facts(kids[0], false, new Span(guard.to, whole.to), kids[0].span, ctx, out);
	}

	/** The bounds `cond` evaluating to `truth` proves over `region`, pushed onto `out`. */
	private static function facts(
		cond: QueryNode, truth: Bool, region: Span, cause: Null<Span>, ctx: OrderContext, out: Array<Bound>
	): Void {
		final seams: OrderSeams = ctx.seams;
		final kids: Array<QueryNode> = cond.children;
		if (cond.kind == seams.parenKind && kids.length == 1) return facts(kids[0], truth, region, cause, ctx, out);
		if (cond.kind == seams.notKind && kids.length == 1) return facts(kids[0], !truth, region, cause, ctx, out);
		if (kids.length != 2) return;
		if ((cond.kind == seams.andKind && truth) || (cond.kind == seams.orKind && !truth)) {
			facts(kids[0], truth, region, cause, ctx, out);
			facts(kids[1], truth, region, cause, ctx, out);
			return;
		}
		final relation: Null<String> = seams.relations[cond.kind];
		if (relation == null) return;
		final left: LinearTerm = linear(kids[0], ctx);
		final right: LinearTerm = linear(kids[1], ctx);
		// `a < b` holding is `b - a - 1 >= 0`; failing, `a - b >= 0`; the other three rotate the same two forms.
		final leftAbove: Bool = (relation == 'gt' || relation == 'ge') == truth;
		final strict: Bool = (relation == 'lt' || relation == 'gt') == truth;
		final gap: LinearTerm = leftAbove ? difference(left, right) : difference(right, left);
		out.push({ term: strict ? minusOne(gap) : gap, region: region, cause: cause });
	}

	/** Whether no write inside `bound`'s region may change one of its operands; a write no path names may change any. */
	private static function unwritten(bound: Bound, ctx: OrderContext): Bool {
		for (w in ctx.writes) {
			final at: Null<Span> = w.node.span;
			if (at == null || !covers(bound, at.from)) continue;
			final written: Null<String> = w.path;
			if (written == null) return false;
			for (atom in bound.term.terms.keys()) if (WriteSites.mayOverlap(written, atom, false)) return false;
		}
		return true;
	}

	/**
	 * `node` as a linear term: literals, negation and the grammar's add / subtract fold, a constant multiple; else an
	 * operand keyed by the storage it reads, or by its own offset when the binder cannot name it, which matches nothing.
	 */
	private static function linear(node: QueryNode, ctx: OrderContext): LinearTerm {
		final seams: OrderSeams = ctx.seams;
		final kids: Array<QueryNode> = node.children;
		final span: Null<Span> = node.span;
		if (span == null) return { terms: ['?' => 1], constant: 0 };
		if (node.kind == seams.parenKind && kids.length == 1) return linear(kids[0], ctx);
		final text: String = ctx.source.substring(span.from, span.to);
		if (seams.numericKinds.contains(node.kind) && ~/^[0-9]+$/.match(text)) return { terms: [], constant: Std.parseInt(text) ?? 0 };
		if (seams.negKinds.contains(node.kind) && kids.length == 1) return scaled(linear(kids[0], ctx), -1);
		final op: Null<String> = seams.foldOps[node.kind];
		if (op != null && kids.length == 2) {
			final a: LinearTerm = linear(kids[0], ctx);
			final b: LinearTerm = linear(kids[1], ctx);
			if (op == 'add') return difference(a, scaled(b, -1));
			if (op == 'subtract') return difference(a, b);
			if (op == 'multiply' && a.terms.empty()) return scaled(b, a.constant);
			if (op == 'multiply' && b.terms.empty()) return scaled(a, b.constant);
		}
		final key: Null<String> = WriteSites.accessPath(node, ctx.tree, seams.shape);
		if (key == null) return { terms: ['?${span.from}' => 1], constant: 0 };
		if (!ctx.survivors.exists(key)) ctx.survivors[key] = survivesCalls(node, ctx);
		return { terms: [key => 1], constant: 0 };
	}

	/** `a - b`, dropping a zero coefficient. */
	private static function difference(a: LinearTerm, b: LinearTerm): LinearTerm {
		final terms: Map<String, Int> = a.terms.copy();
		for (atom => k in b.terms) {
			final sum: Int = (terms[atom] ?? 0) - k;
			if (sum == 0)
				terms.remove(atom)
			else
				terms[atom] = sum;
		}
		return { terms: terms, constant: a.constant - b.constant };
	}

	/** `t * factor`. */
	private static function scaled(t: LinearTerm, factor: Int): LinearTerm {
		return factor == 0
			? { terms: [], constant: 0 }
			: { terms: [for (atom => k in t.terms) atom => k * factor], constant: t.constant * factor };
	}

	/**
	 * Whether no call inside `bound`'s region may change one of its operands: a call enclosing the use (on `path`) runs after
	 * its arguments are read, a call inside a function literal of the region runs only when another call does, and an
	 * effect-free one changes nothing. Only an operand `survivesCalls` refuses can be changed by a call.
	 */
	private static function uncalled(bound: Bound, path: Array<QueryNode>, ctx: OrderContext): Bool {
		if ([for (atom in bound.term.terms.keys()) if (ctx.survivors[atom] != true) atom].length == 0) return true;
		for (c in ctx.calls) if (covers(bound, c.span.from) && !path.contains(c.node)) {
			final within: Null<Span> = c.within;
			if (within != null && covers(bound, within.from)) continue;
			if (!ctx.effects.effectFree(c.node)) return false;
		}
		return true;
	}

	/**
	 * Whether the storage `node` reads can change only by a write in the code that reads it, never by a call: a local no
	 * function literal writes, or a member of an immutable value read off such a local. A field, a static and a member
	 * reached through anything else are storage a callee may change.
	 */
	private static function survivesCalls(node: QueryNode, ctx: OrderContext): Bool {
		final seams: OrderSeams = ctx.seams;
		final kids: Array<QueryNode> = node.children;
		if (node.kind == seams.parenKind && kids.length == 1) return survivesCalls(kids[0], ctx);
		if (seams.memberKinds.contains(node.kind) && kids.length == 1) return survivesCalls(kids[0], ctx) && ctx.effects.immutable(kids[0]);
		return ctx.locals.survivesCalls(node);
	}

	/** Whether `at` lies in the code a write or call there may change `bound` from: its region or the condition that proved it. */
	private static function covers(bound: Bound, at: Int): Bool {
		final cause: Null<Span> = bound.cause;
		return (at >= bound.region.from && at < bound.region.to) || (cause != null && at >= cause.from && at < cause.to);
	}

}

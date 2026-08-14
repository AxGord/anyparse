package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.IfChain;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an `if` / `else if` / … / `else` chain whose EVERY branch is the SAME call differing in
 * exactly ONE argument, and sinks the branching INTO that argument:
 *
 * ```haxe
 * if (i < 10)       items.push('a$i');
 * else if (i < 100) items.push('b$i');
 * else              items.push('c$i');
 * // ->
 * items.push(if (i < 10) 'a$i' else if (i < 100) 'b$i' else 'c$i');
 * ```
 *
 * The call — receiver, method, every OTHER argument — is written once instead of N times, and the
 * chain shrinks from N statements to one. Purely structural apart from the purity gate below, so
 * it holds without a type-checker. `Info` -- the code is correct, this is a readability
 * simplification.
 *
 * ## Boundary with the assignment family
 *
 * `prefer-ternary-assignment` / `prefer-if-expression-assignment` collapse a chain whose branches
 * ASSIGN one l-value; this one collapses a chain whose branches CALL one function. The two shapes
 * are disjoint by construction: a branch statement is either an assignment or a call expression,
 * never both.
 *
 * A 2-branch `if`/`else` IS claimed here (unlike the assignment family, which reserves it for the
 * ternary rule) because the ternary handoff happens downstream instead: this rule always emits the
 * if-EXPRESSION form, and `prefer-ternary-expression` then rewrites a 2-branch one to `c ? a : b`.
 * The `--fix` driver loops to a fixed point, so one `lint --fix` run reaches the ternary;
 * splitting the shape across two rules here would only duplicate the ternary assembly.
 *
 * In VALUE position the two rules match the SAME span, and `Cli.computeFileLintEdits` keeps the
 * edit of whichever check comes FIRST in `Linter.builtins()` -- the ternary -- which would write
 * the callee TWICE and settle there. `claims` below is the handoff that prevents it: the ternary
 * rule asks before rewriting a 2-branch if-EXPRESSION and declines when this rule owns the chain.
 * The downstream ternary still happens, one pass later, on the single call left behind.
 *
 * ## Positions
 *
 * BOTH `if` positions are claimed: the STATEMENT chain (`if (c) f(x); else f(y);`) and the value
 * chain an if-EXPRESSION heads (`final e = if (c) f(x) else f(y);`, `return if (c) …`, an argument
 * slot). One `IfPosition` per claimed kind set drives the walk, so the two share every gate and
 * differ in exactly two places.
 *
 * The first is what a BRANCH may be. A statement branch is unwrapped through `exprStatementKind`
 * (and `blockStmtKind` for the braced form); a value branch IS the call expression, with no
 * statement to unwrap. A BRACED value branch is therefore out of scope: it parses as a block
 * EXPRESSION, which `blockStmtKind` does not name, so the site refuses cleanly. That kind is
 * perfectly nameable -- `ControlFlowSupport.blockKinds()` carries `BlockExpr`, and a dozen sibling
 * checks read it -- so this is an UNCLAIMED shape, not an unreachable one; claiming it would mean
 * unwrapping a second block seam here.
 *
 * The second is the TERMINATOR, which belongs to whichever NODE owns it. An `if` STATEMENT owns
 * its own `;`, so the rebuilt text re-emits one. An if-EXPRESSION does not: it is a child of the
 * `final` / `return` / argument node that owns the `;`, so the rebuild must not add a second. The
 * expression's own SPAN is no guide to this -- like every expression span it runs on through the
 * trailing trivia, and can even cover a comment written past the last branch value, which
 * `droppedComment` catches and refuses the site over.
 *
 * ## What is flagged
 *
 * A chain HEAD (an `if` that is not itself the `else if` link of another) whose:
 *
 * - else-nesting terminates in a plain `else` -- a chain with no final `else` leaves the argument
 *   with no value on the missing path (`IfExpressionChain.collect`);
 * - every branch AND the terminal is a single call carrying at least one argument -- a call
 *   STATEMENT in statement position (a bare `f(…);` or a braced `{ f(…); }` wrapping one), a bare
 *   call EXPRESSION in value position (see `## Positions` above). A multi-statement block is
 *   deliberately grouped and never collapsed, and a branch that assigns, returns or does anything
 *   but call is not this rule's shape;
 * - all the calls have the same argument count and a TEXTUALLY IDENTICAL callee
 *   (whitespace-normalized source), so the receiver and the method are the same expression written
 *   the same way;
 * - EXACTLY ONE argument index varies. Zero varying arguments means the branches are identical
 *   statements -- `tail-merge` / `duplicate-code` territory, and collapsing it here would hide that
 *   the whole `if` is pointless. Two or more cannot be expressed as one if-expression without
 *   evaluating the conditions twice;
 * - the HOISTED parts are PURE (`PurityScan.isPure`): the callee and every common argument. They
 *   move from AFTER the conditions to BEFORE them -- the collapsed form evaluates
 *   `receiver`, the common arguments, then the conditions -- so anything they could observe or do
 *   must be nothing. A getter read, an instance call, a `new` in the receiver all refuse;
 * - every CONDITION is pure by the same predicate. This is the other half of the same reordering:
 *   a condition that WRITES what the hoisted reads see (`if (reset()) list.push(1) else …`, where
 *   `reset()` rebinds `list`) would be observed by the hoisted `list` read only in the original
 *   order. Refusing every condition that can write is the cheap sound answer; it costs the
 *   findings whose conditions call something (`map.exists(k)`), which is the safe direction;
 * - no NON-TERMINAL branch holds an else-less conditional. The collapse emits a ` else ` after
 *   every branch value but the last, and an `if` without its own `else` ends an expression OPEN, so
 *   it ABSORBS that ` else ` and the rest of the chain silently becomes its else branch -- output
 *   that still parses, so the `--fix` re-parse gate would wave it through
 *   (`IfExpressionChain.holdsElseLessConditional`). The TERMINAL is exempt: what follows its value
 *   is the rest of the call (`)` or `, next)`), and neither can continue an `if`.
 *
 * ## Comments
 *
 * Fail-closed, like the ternary siblings: any comment inside the collapsed region that is not
 * inside a verbatim-copied span (`IfExpressionChain.droppedComment`) leaves the chain unflagged.
 * The copied spans are each condition, each branch's varying argument, and the FIRST call's prefix
 * (`receiver.method(` up to that argument) and suffix (from it to the closing `)`) -- so a comment
 * inside the surviving call text rides along, and one in a region the rebuild drops (a header
 * keyword, the braces, another branch's repeated callee) refuses the site. Every copied span is
 * `IfExpressionChain.tokenSpan`-trimmed first: an expression node's span runs on past its last
 * token through the trailing trivia, and a `//` comment copied inline would comment out whatever
 * the rebuild welds after it.
 *
 * ## Type unification
 *
 * The branch values become the branches of ONE if-expression, so they must unify. The call's
 * PARAMETER type flows into them exactly as an l-value's type flows into the assignment family's
 * collapse, which covers the ordinary case; a parameter typed `Dynamic` / `Any` leaves them to
 * unify with each other. Not gated -- no type information is available here -- and a chain that
 * genuinely cannot unify is caught by the compiler, or by the oracle when one is configured.
 *
 * Needs `ifStatementKinds`, `exprStatementKind`, `blockStmtKind` and `callKind`; any unset makes
 * the check a no-op. `ifExpressionKinds` is OPTIONAL -- unset, only the statement position is
 * claimed. The purity context additionally needs a symbol index -- without one the check
 * reports nothing rather than guessing.
 */
@:nullSafety(Strict)
final class JoinBranchCall implements Check {

	/** The rule id, also the `rule` field of every violation it reports. */
	private static inline final RULE_ID: String = 'join-branch-call';

	/** A 2-branch `if`/`else` (one branch plus the terminal) is claimed too -- see the class doc. */
	private static inline final MIN_CHAIN_BRANCHES: Int = 1;

	/** A call node's `children[0]` is its callee; the arguments follow, so a call with one is 2 children. */
	private static inline final CALLEE_INDEX: Int = 0;

	/** No argument index varies across the branches -- the branches are identical calls. */
	private static inline final NO_VARYING: Int = -1;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an if/else-if chain whose branches call the same function differing in one argument, collapsible to a single call with an '
			+ 'if-expression argument';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final symbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final ctx: Null<Ctx> = contextOf(plugin, entry.source, resolved, symbols);
			if (ctx == null) continue;
			walk(ctx.root, violations, entry.file, ctx);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final files: Array<{ file: String, source: String }> = [{ file: violations[0].file, source: source }];
		final ctx: Null<Ctx> = contextOf(plugin, source, seams, RefactorSupport.lazySymbolIndex(files, plugin, index));
		if (ctx == null) return [];
		final resolved: Ctx = ctx;
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, [for (kind in seams.byKind.keys()) kind], (node, span) -> {
				final pos: Null<IfPosition> = positionOf(node, resolved.seams);
				// The index was built from `byKind`'s own keys, so every node reaching here has one.
				if (pos == null) throw new Exception('join-branch-call: no claimed position for indexed kind ${node.kind}');
				final m: Null<Match> = match(node, resolved, pos);
				return m == null ? null : { span: span, text: buildText(m, pos) };
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Whether THIS rule claims the value-position chain headed by `head` -- its branches are the
	 * same call differing in exactly one argument, so it will emit the single-call form.
	 *
	 * `prefer-ternary-expression` asks before rewriting a 2-branch if-EXPRESSION, because both rules
	 * match that span and only one edit survives: `Cli.computeFileLintEdits` keeps whichever check
	 * comes FIRST in `Linter.builtins()`, and the ternary is earlier. Without this handoff the user
	 * saw two contradictory advisories on one span, and `--fix` wrote the callee TWICE
	 * (`a ? log(1) : log(2)`) -- the very duplication this rule exists to remove, and a fixed point
	 * no later rule reclaims (`prefer-if-expression-chain` needs three values). Mirrors
	 * `PreferSwitchExpression.claims`, which `prefer-if-expression-chain` consults the same way, and
	 * inherits its one caveat: the handoff does not know whether THIS rule is enabled, so a config
	 * that disables `join-branch-call` also costs the ternary on these spans.
	 *
	 * Takes the caller's ALREADY-PARSED tree and comment list: this runs per candidate, and parsing
	 * the file again each time would be quadratic. The symbol index stays behind `symbols` and is
	 * forced only once every structural gate has passed, which on a 2-branch ternary candidate is
	 * rare -- both branches must be calls of one textually identical callee.
	 */
	public static function claims(
		plugin: GrammarPlugin, source: String, root: QueryNode, head: QueryNode, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		symbols: () -> Null<SymbolIndex>
	): Bool {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return false;
		final resolved: Seams = seams;
		final pos: Null<IfPosition> = positionOf(head, resolved);
		if (pos == null || pos.statement) return false;
		return match(head, ctxOn(plugin, source, root, comments, resolved, symbols), pos) != null;
	}

	/** The source text of `span`. */
	private static inline function slice(source: String, span: Span): String {
		return source.substring(span.from, span.to);
	}

	/** Bundle the required `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final stmtKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (stmtKinds.length == 0) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final positions: Array<IfPosition> = [{ kinds: stmtKinds, statement: true }];
		final valueKinds: Array<String> = shape.ifExpressionKinds ?? [];
		if (valueKinds.length > 0) positions.push({ kinds: valueKinds, statement: false });
		final byKind: Map<String, IfPosition> = [];
		// FIRST position wins. A grammar naming one kind in BOTH lists would otherwise get the value
		// position for a statement chain and lose its `;`; Haxe's two sets are disjoint, so this is
		// a guard against a future grammar rather than a live case.
		for (p in positions) for (kind in p.kinds) if (!byKind.exists(kind)) byKind[kind] = p;
		return {
			byKind: byKind,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			callKind: callKind,
			conditionalKinds: IfExpressionChain.conditionalKinds(shape)
		};
	}

	/** The claimed `if` position `node` heads a chain in, or null when its kind heads none. */
	private static function positionOf(node: QueryNode, s: Seams): Null<IfPosition> {
		return s.byKind[node.kind];
	}

	/**
	 * The per-file scan context -- the parsed tree, the comment tokens and a LAZY purity scan -- or
	 * null when the source does not parse. The purity context is built at most ONCE per file and only
	 * when a chain survives the structural gates: building it forces the symbol index, and most files
	 * hold no candidate at all. A file that cannot produce one (no index, or a grammar seam unset)
	 * reports nothing rather than hoisting an unproven expression.
	 */
	private static function contextOf(plugin: GrammarPlugin, source: String, seams: Seams, symbols: () -> Null<SymbolIndex>): Null<Ctx> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		return tree == null ? null : ctxOn(plugin, source, tree, RefactorSupport.collectCommentTokens(source), seams, symbols);
	}

	/**
	 * The same context over an ALREADY-parsed tree and comment list. `claims` answers for a foreign
	 * check mid-walk, where re-parsing the file per candidate would be quadratic -- so the two entry
	 * points share ONE context builder rather than one of them growing a second lazy-purity closure
	 * that could drift from this one.
	 */
	private static function ctxOn(
		plugin: GrammarPlugin, source: String, root: QueryNode, comments: Array<{ from: Int, to: Int, isLine: Bool }>, seams: Seams,
		symbols: () -> Null<SymbolIndex>
	): Ctx {
		var purity: Null<PurityCtx> = null;
		var built: Bool = false;
		return {
			root: root,
			source: source,
			comments: comments,
			seams: seams,
			purity: () -> {
				if (!built) {
					built = true;
					final index: Null<SymbolIndex> = symbols();
					purity = index == null ? null : PurityScan.contextOf(plugin, source, root, index);
				}
				return purity;
			}
		};
	}

	/** Walk `node`, flagging each chain HEAD whose branches are the same call differing in one argument. */
	private static function walk(node: QueryNode, out: Array<Violation>, file: String, ctx: Ctx, ?parent: QueryNode): Void {
		final pos: Null<IfPosition> = positionOf(node, ctx.seams);
		if (pos != null && !IfExpressionChain.isElseIfLink(node, parent, pos.kinds)) {
			final span: Null<Span> = node.span;
			if (span != null && match(node, ctx, pos) != null) out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'these branch calls differ in one argument and can be a single call with an if-expression argument'
			});
		}
		for (c in node.children) walk(c, out, file, ctx, node);
	}

	/**
	 * If `head` is a chain whose every branch is the same call differing in exactly one argument,
	 * whose hoisted parts and conditions are pure, and no comment sits in a dropped region, return
	 * the copied text parts; else null.
	 */
	private static function match(head: QueryNode, ctx: Ctx, pos: IfPosition): Null<Match> {
		final s: Seams = ctx.seams;
		final chain: Null<IfChain> = IfExpressionChain.collect(head, pos.kinds, s.blockStmtKind, MIN_CHAIN_BRANCHES);
		if (chain == null) return null;
		final calls: Array<QueryNode> = [];
		for (b in chain.branches) {
			// A NON-terminal branch value that ends an expression OPEN would absorb the ` else `
			// emitted after it, re-parenting the rest of the chain onto it -- output that parses.
			if (IfExpressionChain.holdsElseLessConditional(b.stmt, s.conditionalKinds)) return null;
			final call: Null<QueryNode> = callIn(b.stmt, s, pos);
			if (call == null) return null;
			calls.push(call);
		}
		final terminal: Null<QueryNode> = callIn(chain.terminal, s, pos);
		if (terminal == null) return null;
		calls.push(terminal);
		final first: QueryNode = calls[0];
		for (c in calls) if (c.children.length != first.children.length) return null;
		for (c in calls) if (!IfExpressionChain.sameSource(first.children[CALLEE_INDEX], c.children[CALLEE_INDEX], ctx.source)) return null;
		final varying: Int = varyingIndex(calls, ctx.source);
		if (varying == NO_VARYING) return null;
		final purity: Null<PurityCtx> = ctx.purity();
		if (purity == null) return null;
		final scan: PurityCtx = purity;
		if (!hoistedPure(first, varying, scan)) return null;
		for (b in chain.branches) if (!PurityScan.isPure(b.cond, scan)) return null;
		return assemble(head, chain, calls, varying, ctx);
	}

	/**
	 * The single call a branch holds, carrying at least one argument. In STATEMENT position that is
	 * a bare `f(…);` or a braced `{ f(…); }` wrapping one; in VALUE position the branch IS the call
	 * expression, with no statement to unwrap -- so a braced value branch, which parses as a block
	 * EXPRESSION rather than the `blockStmtKind` this unwraps through, falls through to null (an
	 * out-of-scope shape, not an unreachable one -- see the class doc). Null for anything else.
	 */
	private static function callIn(stmt: QueryNode, s: Seams, pos: IfPosition): Null<QueryNode> {
		if (!pos.statement) return callWithArguments(stmt, s);
		final inner: QueryNode = stmt.kind == s.blockStmtKind && stmt.children.length == 1 ? stmt.children[0] : stmt;
		return inner.kind != s.exprStmtKind || inner.children.length != 1 ? null : callWithArguments(inner.children[0], s);
	}

	/** `node` itself when it is a call carrying at least one argument, else null. */
	private static function callWithArguments(node: QueryNode, s: Seams): Null<QueryNode> {
		return node.kind == s.callKind && node.children.length > CALLEE_INDEX + 1 ? node : null;
	}

	/**
	 * The ONE argument index whose source text differs across `calls`, or `NO_VARYING` when none
	 * does (identical calls) or several do (not expressible as one if-expression). The callee is
	 * compared separately by the caller, so the scan starts past it.
	 */
	private static function varyingIndex(calls: Array<QueryNode>, source: String): Int {
		final first: QueryNode = calls[0];
		var varying: Int = NO_VARYING;
		for (i in CALLEE_INDEX + 1...first.children.length) {
			var same: Bool = true;
			for (c in calls) if (!IfExpressionChain.sameSource(first.children[i], c.children[i], source)) {
				same = false;
				break;
			}
			if (same) continue;
			if (varying != NO_VARYING) return NO_VARYING;
			varying = i;
		}
		return varying;
	}

	/** Whether the parts hoisted out of the branches -- the callee and every argument but `varying` -- are pure. */
	private static function hoistedPure(call: QueryNode, varying: Int, purity: PurityCtx): Bool {
		for (i in 0...call.children.length) if (i != varying && !PurityScan.isPure(call.children[i], purity)) return false;
		return true;
	}

	/**
	 * The copied text parts of a matched chain, or null when a span is missing or a comment sits in
	 * a region the rebuild drops. The surviving call is the FIRST branch's, split around its varying
	 * argument into the prefix (`receiver.method(` and any earlier argument) and the suffix (any
	 * later argument and the closing `)`); each branch contributes its condition and its own varying
	 * argument.
	 */
	private static function assemble(head: QueryNode, chain: IfChain, calls: Array<QueryNode>, varying: Int, ctx: Ctx): Null<Match> {
		final headSpan: Null<Span> = head.span;
		final callSpan: Null<Span> = calls[0].span;
		if (headSpan == null || callSpan == null) return null;
		final values: Array<Span> = [];
		for (c in calls) {
			final span: Null<Span> = c.children[varying].span;
			if (span == null) return null;
			values.push(IfExpressionChain.tokenSpan(span, ctx.source, ctx.comments));
		}
		final conditions: Array<Span> = [];
		for (b in chain.branches) {
			final span: Null<Span> = b.cond.span;
			if (span == null) return null;
			conditions.push(IfExpressionChain.tokenSpan(span, ctx.source, ctx.comments));
		}
		final prefix: Span = new Span(callSpan.from, values[0].from);
		final suffix: Span = new Span(values[0].to, IfExpressionChain.tokenSpan(callSpan, ctx.source, ctx.comments).to);
		final kept: Array<Span> = [prefix, suffix].concat(values).concat(conditions);
		return IfExpressionChain.droppedComment(headSpan, kept, ctx.comments) ? null : {
			prefix: slice(ctx.source, prefix),
			suffix: slice(ctx.source, suffix),
			pairs: [
				for (i in 0...conditions.length) { cond: slice(ctx.source, conditions[i]), value: slice(ctx.source, values[i]) }
			],
			terminal: slice(ctx.source, values[values.length - 1])
		};
	}

	/**
	 * Build the `receiver.method(if (c1) v1 else if (c2) v2 … else vN)` text replacing the whole
	 * head-`if` span. The `;` is appended only in STATEMENT position, because the terminator
	 * belongs to whichever NODE owns it: an `if` statement owns its own, while an if-EXPRESSION is a
	 * child of the `final` / `return` / argument node that owns the `;`.
	 */
	private static function buildText(m: Match, pos: IfPosition): String {
		final terminator: String = pos.statement ? ';' : '';
		return '${m.prefix}${IfExpressionChain.buildValue(m.pairs, m.terminal)}${m.suffix}$terminator';
	}

}

/**
 * One `if` POSITION this rule claims: the kinds that head a chain there, and whether the rebuilt
 * text owns its `;`. A statement chain owns its own terminator; an if-EXPRESSION does not --
 * the `final` / `return` / argument node it is a child of owns that `;`.
 */
private typedef IfPosition = {
	var kinds: Array<String>;
	var statement: Bool;
}

/** The `RefShape` kinds `JoinBranchCall` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	/** Every claimed `if` kind mapped to the position it heads -- `positionOf` is one lookup, per node. */
	var byKind: Map<String, IfPosition>;

	var exprStmtKind: String;
	var blockStmtKind: String;
	var callKind: String;
	var conditionalKinds: Array<String>;
}

/** The per-file scan state: the parsed tree, its comment tokens, the resolved seams and the purity scan. */
private typedef Ctx = {
	var root: QueryNode;
	var source: String;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	var seams: Seams;
	var purity: () -> Null<PurityCtx>;
}

/** A matched chain's copied text: the surviving call split around its varying argument, and the (condition, value) pairs. */
private typedef Match = {
	var prefix: String;
	var suffix: String;
	var pairs: Array<{ cond: String, value: String }>;
	var terminal: String;
}

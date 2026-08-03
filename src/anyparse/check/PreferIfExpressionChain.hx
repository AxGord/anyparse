package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.Carried;
import anyparse.check.IfExpressionChain.CarrySeat;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a RIGHT-NESTED ternary chain of three or more values already written in value
 * position, and rewrites it to the equivalent if-expression chain:
 *
 * ```haxe
 * moves.sort((a:Item, b:Item) -> a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
 * // ->
 * moves.sort((a:Item, b:Item) -> if (a.path < b.path) -1 else if (a.path > b.path) 1 else 0);
 * ```
 *
 * Purely structural (no type information). `Info` — the code is correct, this is the
 * convergence half of the project's documented conditional canon: a TWO-branch value
 * conditional is a ternary, a THREE-or-more-branch one an if-expression chain, and an
 * equality-shaped chain a `switch`. The statement-side rules (`prefer-ternary-return` /
 * `-assignment`, `prefer-if-expression-return` / `-assignment`) already produce that canon
 * from `if` STATEMENTS; `prefer-ternary-expression` produces the 2-branch half from an
 * if-EXPRESSION. This check owns the remaining direction — a chain the author wrote as
 * nested `?:` in the first place, which no statement-side rule can see.
 *
 * ## Disjoint from `prefer-ternary-expression` by RUNG COUNT
 *
 * That check turns a 2-branch if-expression into a ternary; this one turns a 3+-value
 * ternary chain into an if-expression chain. They cannot ping-pong: the shapes are
 * disjoint by construction and each is the other's 0-finding fixed point.
 *
 * - A 2-rung ternary (`c ? a : b`) has ONE condition, below this check's minimum.
 * - An if-expression CHAIN is refused by `prefer-ternary-expression` twice over — the head
 *   because its else-branch is another if-expression, absent from that check's branch
 *   whitelist, and the inner link because its parent is that head, which is no delimited
 *   slot.
 *
 * ## What is flagged
 *
 * The HEAD of a chain — a `ternaryKind` / `ifExpressionKinds` node NOT reached as another
 * chain node's else-slot, so an inner rung is never re-reported — with:
 *
 * - **A whitelisted host.** The head's PARENT kind must be in `ifExpressionChainHostKinds`
 *   (a `return`, a local / member initializer, an assignment r-value, an arrow-lambda
 *   body). This is a READABILITY gate, not a correctness one: an `if`-expression is a legal
 *   expression atom everywhere a ternary is, and its else-arm parses at the same precedence
 *   as the ternary's, so no slot re-associates (verified on 4.3.7 in a call argument, an
 *   array element and index, an object-literal value, a map value, and the then-arm of an
 *   enclosing ternary). It reads WORSE in most of those, so the whitelist keeps the rewrite
 *   to the positions where a multi-line chain belongs. It also removes the one shape that
 *   would need thought — a chain in the then-arm of an enclosing ternary, whose parent kind
 *   is a chain kind and so is never a host.
 * - **At least two conditions** (three leaf values). A single ternary IS the canon and is
 *   left alone; this minimum is the whole disjointness proof against
 *   `prefer-ternary-expression`.
 * - **At least one ternary rung.** A chain already written entirely as if-expressions is the
 *   canon — flagging it would report a fixed point. A MIXED chain (`c1 ? v1 : if (c2) v2
 *   else v3`, which neither this check's predecessor nor `prefer-ternary-expression` could
 *   move) does have one, and converges here.
 * - **No claim by `prefer-switch-expression`.** An equality-shaped chain over a uniform
 *   discriminant tuple in a host THAT check accepts belongs to it, and this check defers by
 *   asking it directly (`PreferSwitchExpression.claims`) rather than mirroring its gate
 *   structurally — a mirror is a second implementation of one question and drifts the moment
 *   a gate there moves. The deferral is asymmetric on purpose: that check's host whitelist is
 *   narrower (no lambda body), so an equality-shaped comparator lambda is unclaimed there and
 *   converts here.
 * - **No else-less conditional in a NON-TERMINAL rung value.** The emitted ` else ` follows
 *   every rung value but the last, and an `if` without its own `else` ends an expression
 *   OPEN: `a ? if (q) p() : b ? r() : s()` would emit
 *   `if (a) if (q) p() else if (b) r() else s()`, where the rest of the chain becomes the
 *   INNER `if`'s else branch — 6 of the 8 input combinations then behave differently, and
 *   the output re-parses, so the `--fix` re-parse gate would wave it through. The scan
 *   covers the whole value subtree rather than only its right spine: an else-less `if` in a
 *   delimited interior is harmless, but proving which is which costs more than the rare
 *   cleanup it buys. The TERMINAL value needs no such gate, and that is a fact about the
 *   PARSE rather than an omission — an `else` that could have followed the chain was already
 *   bound INTO the terminal (`a ? 1 : if (q) p() else X` parses as
 *   `a ? 1 : (if (q) p() else X)`), which makes that node a RUNG; so a terminal that is
 *   else-less proves nothing follows it that could re-parent. The scan and that exemption
 *   live in `IfExpressionChain.holdsElseLessConditional`, shared with
 *   `prefer-if-expression-return` and `prefer-if-expression-assignment`: those collapse an
 *   `if` CHAIN rather than a ternary one, but emit the same ` else ` and so carry the same
 *   hazard.
 * - **No comment the rewrite cannot place.** The `?` / `:` glue goes away. A comment between
 *   a rung's condition and its value (where the `?` sat), or directly after a rung value with
 *   nothing at all in between, rides the matching slot of the rebuilt branch
 *   (`IfExpressionChain.carriedComments`) and keeps its position; any OTHER comment between
 *   the copied pieces — anything past the `:`, which opens the NEXT rung — still skips the
 *   chain, per the family's fail-closed guard. Each copied span is first cut back to its last
 *   TOKEN (`IfExpressionChain.tokenSpan`, shared with the two statement-side collapse rules
 *   for the same reason), so a comment the parser folded into a node's TRAILING trivia —
 *   `a < b // why` before the `?` — is seen by the slot machinery at all, instead of being
 *   welded into the copied condition where it would comment out everything the rebuild puts
 *   after it.
 *
 * A reification subtree (`RefShape.opaqueKinds`, Haxe's `macro { … }`) is skipped wholesale,
 * as in the sibling rewrite rules: its interior is spliced code a consumer may pattern-match
 * on, not source a human reads.
 *
 * ## Autofix
 *
 * `fix` replaces the chain with `if (c1) v1 else if (c2) v2 … else vN`, assembled by the
 * shared `IfExpressionChain.buildValue` so this check and the statement-side collapse rules
 * emit byte-identical text. Conditions and values are copied verbatim from their spans, each
 * cut back to its last token, with any carried comment welded into the branch slot it came
 * from; every condition's redundant outer parentheses are stripped first, the `if (` … `)`
 * syntax supplying its own — leaving them would only draw a `redundant-parens` finding on
 * the result. No parentheses are ADDED: every piece already sat in a `?:` operand slot, and
 * both the `if` condition and its branches accept an expression of any precedence.
 *
 * The replaced region stops at the TERMINAL VALUE's last TOKEN — not at the chain head's own
 * end, and not at the terminal's raw span end either: an expression node's span runs on
 * through the trivia after its last token, and splicing that away welds the emitted chain
 * onto whatever follows.
 *
 * `run` and `fix` share one `collect`, so neither can encode a gate the other misses.
 *
 * ## Fixed-point behaviour
 *
 * `prefer-ternary-return` collapses guard returns into a ternary, and a second pass over a
 * further guard BUILDS a 3-rung nested ternary; this check then converts it, and nothing
 * converts an if-expression chain back — the pipeline terminates.
 *
 * ## Grammar-agnostic
 *
 * `ternaryKind` plus `ifExpressionKinds` are the chain kinds, `ifStatementKinds` joins them
 * for the else-less scan, `ifExpressionChainHostKinds` is the host gate, `parenKind` the
 * condition unwrap and `opaqueKinds` the subtrees to skip. No `ternaryKind` (nothing to
 * convert) or no host kind → the check is a no-op.
 */
@:nullSafety(Strict)
final class PreferIfExpressionChain implements Check {

	/** A chain node carrying an else-slot has children `[cond, then, else]`. */
	private static inline final CHAIN_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The else-slot's index among a chain node's children — where the next rung hangs. */
	private static inline final ELSE_SLOT_INDEX: Int = 2;

	/** Two conditions (three leaf values) — below this, the ternary IS the canon. */
	private static inline final MIN_RUNGS: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-if-expression-chain';
	}

	public function description(): String {
		return 'a nested ternary chain of three or more values in value position, rewritable as an if-expression chain';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolveIndex: () -> Null<SymbolIndex> = SwitchChain.lazyIndexOf(files, plugin);
		return [
			for (entry in files) for (m in collect(plugin, entry.source, seams, resolveIndex))
				{
					file: entry.file,
					span: m.span,
					rule: 'prefer-if-expression-chain',
					severity: Severity.Info,
					message: 'this nested ternary chain can be an if-expression chain'
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolveIndex: () -> Null<SymbolIndex> = SwitchChain.lazyIndexOf([{ file: '', source: source }], plugin, index);
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, source, seams, resolveIndex)) byKey['${m.span.from}:${m.span.to}'] = m;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.editSpan, text: m.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Every convertible chain in `source` (empty when it does not parse). `run` and `fix`
	 * both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams, resolveIndex: () -> Null<SymbolIndex>): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<Match> = [];
		walk(tree, source, RefactorSupport.collectCommentTokens(source), s, plugin, resolveIndex, out, null, false);
		return out;
	}

	/**
	 * Bundle the kinds this check reads, or null when the grammar leaves it nothing to
	 * convert: no ternary kind, or no host kind for the result.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		final hostKinds: Array<String> = shape.ifExpressionChainHostKinds ?? [];
		if (ternaryKind == null || hostKinds.length == 0) return null;
		final ifExpressionKinds: Array<String> = shape.ifExpressionKinds ?? [];
		final chainKinds: Array<String> = ifExpressionKinds.copy();
		if (!chainKinds.contains(ternaryKind)) chainKinds.push(ternaryKind);
		return {
			ternaryKind: ternaryKind,
			chainKinds: chainKinds,
			conditionalKinds: IfExpressionChain.conditionalKinds(shape),
			hostKinds: hostKinds,
			parenKind: shape.parenKind,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/**
	 * Walk `node`, collecting every convertible chain HEAD. `parentKind` carries the slot the
	 * node occupies (the host gate) and `inElseSlot` whether it is an inner rung of an
	 * enclosing chain, which is skipped so a chain is reported once. A reification subtree is
	 * skipped whole.
	 */
	private static function walk(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, plugin: GrammarPlugin,
		resolveIndex: () -> Null<SymbolIndex>, out: Array<Match>, parentKind: Null<String>, inElseSlot: Bool
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final isChain: Bool = s.chainKinds.contains(node.kind);
		if (isChain && !inElseSlot && parentKind != null && s.hostKinds.contains(parentKind)) {
			final m: Null<Match> = match(node, source, comments, s, plugin, resolveIndex, parentKind);
			if (m != null) out.push(m);
		}
		final elseSlot: Int = isChain ? ELSE_SLOT_INDEX : -1;
		for (i in 0...node.children.length)
			walk(node.children[i], source, comments, s, plugin, resolveIndex, out, node.kind, i == elseSlot);
	}

	/**
	 * The rewrite of the chain at `head`, or null when a gate refuses it (see the class doc).
	 * The edit stops at the terminal value rather than at the head's own end: a conditional
	 * node's span runs on through the trivia after its last token.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, plugin: GrammarPlugin,
		resolveIndex: () -> Null<SymbolIndex>, parentKind: String
	): Null<Match> {
		final headSpan: Null<Span> = head.span;
		if (headSpan == null) return null;
		final rungs: Array<Rung> = [];
		var ternaryRungs: Int = 0;
		var cur: QueryNode = head;
		while (s.chainKinds.contains(cur.kind) && cur.children.length == CHAIN_WITH_ELSE_CHILD_COUNT) {
			if (cur.kind == s.ternaryKind) ternaryRungs++;
			// The emitted `if (` … `)` supplies its own delimiters, so a copied paren pair would
			// only draw a `redundant-parens` finding on the result; nothing inside a condition
			// slot can be load-bearing, the construct bounding it on both sides.
			rungs.push({ cond: RefactorSupport.unwrapParens(cur.children[0], s.parenKind), value: cur.children[1] });
			cur = cur.children[ELSE_SLOT_INDEX];
		}
		final rawTerminal: Null<Span> = cur.span;
		if (rungs.length < MIN_RUNGS || ternaryRungs == 0 || rawTerminal == null) return null;
		if (PreferSwitchExpression.claims(source, head, parentKind, plugin, resolveIndex)) return null;
		final terminalSpan: Span = IfExpressionChain.tokenSpan(rawTerminal, source, comments);
		final kept: Array<Span> = [terminalSpan];
		final spans: Array<{ cond: Span, value: Span }> = [];
		for (rung in rungs) {
			final rawCond: Null<Span> = rung.cond.span;
			final rawValue: Null<Span> = rung.value.span;
			// The emitted ` else ` follows every NON-terminal value, and only an else-less
			// conditional can absorb it — the value would silently become that `if`'s else
			// branch. The terminal needs no such gate: an `else` that could follow the chain
			// was already bound INTO the terminal by the parser, which turns it into a rung.
			if (rawCond == null || rawValue == null || IfExpressionChain.holdsElseLessConditional(rung.value, s.conditionalKinds))
				return null;
			final condSpan: Span = IfExpressionChain.tokenSpan(rawCond, source, comments);
			final valueSpan: Span = IfExpressionChain.tokenSpan(rawValue, source, comments);
			kept.push(condSpan);
			kept.push(valueSpan);
			spans.push({ cond: condSpan, value: valueSpan });
		}
		final seats: Array<CarrySeat> = [
			for (i in 0...spans.length)
				{
					condEnd: spans[i].cond.to,
					value: spans[i].value,
					nextStart: i + 1 < spans.length ? spans[i + 1].cond.from : terminalSpan.from
				}
		];
		final carried: Null<Carried> = IfExpressionChain.carriedComments(
			headSpan, kept, IfExpressionChain.carryGaps(seats), source, comments
		);
		if (carried == null) return null;
		final pairs: Array<{ cond: String, value: String }> = [
			for (p in spans)
				{ cond: source.substring(p.cond.from, p.cond.to), value: IfExpressionChain.spanText(source, p.value, carried) }
		];
		return {
			span: headSpan,
			editSpan: new Span(headSpan.from, terminalSpan.to),
			text: IfExpressionChain.buildValue(pairs, source.substring(terminalSpan.from, terminalSpan.to))
		};
	}

}

/** The kinds `PreferIfExpressionChain` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ternaryKind: String;
	var chainKinds: Array<String>;
	var conditionalKinds: Array<String>;
	var hostKinds: Array<String>;
	var parenKind: Null<String>;
	var opaqueKinds: Array<String>;
}

/** One rung of a scanned chain: its condition (parens already stripped) and its value. */
private typedef Rung = {
	var cond: QueryNode;
	var value: QueryNode;
}

/** A convertible chain: the finding key span, the (trivia-trimmed) replaced span, and the if-chain text. */
private typedef Match = {
	var span: Span;
	var editSpan: Span;
	var text: String;
}

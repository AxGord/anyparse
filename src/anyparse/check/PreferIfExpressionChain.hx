package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.Carried;
import anyparse.check.IfExpressionChain.CarrySeat;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.query.GrammarPlugin;
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
 *   (a `return`, a local /
 *   member initializer, an assignment r-value, an arrow-lambda body, a `switch` ARM's
 *   value — the last reached through the expression-statement wrapper, which `slotKindOf`
 *   makes transparent inside an arm and nowhere else). This is a READABILITY gate, not a
 *   correctness one: an `if`-expression is a legal
 *   expression atom everywhere a ternary is, and its else-arm parses at the same precedence
 *   as the ternary's, so no slot re-associates (verified on 4.3.7 in a call argument, an
 *   array element and index, an object-literal value, a map value, and the then-arm of an
 *   enclosing ternary). It reads WORSE in most of those, so the whitelist keeps the rewrite
 *   to the positions where a multi-line chain belongs. It also removes the one shape that
 *   would need thought — a chain in the then-arm of an enclosing ternary, whose parent kind
 *   is a chain kind and so is never a host.
 * - **At least two conditions** (three leaf values) once the conjunctive flattening below has
 *   run. A single ternary IS the canon and is left alone; this minimum is the whole
 *   disjointness proof against `prefer-ternary-expression`.
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
 * ## Conjunctive flattening
 *
 * The walk follows the ELSE spine, so a ternary nested in the THEN arm contributes only ONE
 * condition and stays below the minimum. `flatten` reaches it: `a ? (b ? A : B) : C` emits
 * `if (a && b) A else if (a) B else C`.
 *
 * That rewrite is ALWAYS sound, and needs no implication between the two conditions. `a` is
 * evaluated first either way; `b` only under `a`, because the emitted `&&` short-circuits —
 * which is also what keeps a null GUARD guarding, the shape TM writes as
 * `sel != null ? sel.data.data == -1 ? x : y : z`. The SWAP form `b ? A : a ? B : C` would
 * require `b` to imply `a` and is deliberately NOT what this does.
 *
 * What the conjunction does cost is `a` a SECOND time whenever `b` is false, so `PurityScan`
 * must prove it duplicable: a call, and a property read whose getter runs code, both refuse,
 * and the chain then keeps its old silent answer rather than being rewritten.
 *
 * DEPTH CAP of one level. The outer condition is duplicated at every level, so recursion
 * would grow quadratically (`a ? b ? c ? …` giving `a && b && c`, then `a && b`, then `a`);
 * a deeper nest keeps its inner two-branch ternary, which IS the canon. Only a TERNARY value
 * expands — an if-expression in the same slot is already the form this family emits.
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
		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
	}

	/**
	 * `text` as an operand of the emitted `&&`, parenthesized when its node binds LOOSER than the
	 * conjunction (`RefShape.andLowerPrecedenceKinds`) — the same vocabulary and the same reason
	 * `collapsible-if` merges two conditions with.
	 */
	private static inline function andOperand(text: String, node: QueryNode, s: Seams): String {
		return s.andLowerPrecedence.contains(node.kind) ? '($text)' : text;
	}

	/**
	 * The kind the walk hands a child as its SLOT — normally the parent's own kind, but the
	 * ARM kind when the parent is the expression-STATEMENT wrapper of a switch arm's value.
	 * That wrapper is what stands between an arm and the chain it holds, and it is
	 * transparent HERE ONLY: a bare expression statement in an ordinary block keeps its own
	 * kind and so is no host, which is what scopes the arm host to the arm.
	 *
	 * The carried value is the SLOT rather than the true parent kind, and the two differ only
	 * across that one rewrite — a statement wrapper never nests in another — so the test can
	 * read `parentKind` as the wrapper's real parent.
	 */
	private static inline function slotKindOf(node: QueryNode, parentKind: Null<String>, s: Seams): String {
		return node.kind == s.exprStatementKind && parentKind != null && s.armKinds.contains(parentKind) ? parentKind : node.kind;
	}

	/**
	 * Where the FIRST piece the rebuild copies for `rung` starts — its leading condition span, or
	 * its value when the rung copies no condition at all. Only the SECOND half of a conjunctive
	 * expansion is that shape: its condition is the outer one, already copied by the first half.
	 */
	private static inline function firstCopiedPiece(rung: Emitted): Int {
		return rung.condSpans.length > 0 ? rung.condSpans[0].from : rung.value.from;
	}

	/**
	 * Every convertible chain in `source` (empty when it does not parse). `run` and `fix`
	 * both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams, resolveIndex: () -> Null<SymbolIndex>): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<Match> = [];
		walk(
			tree, source, RefactorSupport.collectCommentTokens(source), s, plugin, lazyOf(plugin, source, tree, resolveIndex), out, null,
			false
		);
		return out;
	}

	/**
	 * The two lazily-resolved services the walk carries: the symbol index the switch-expression
	 * deferral asks for, and the purity context the conjunctive flattening asks of a condition it
	 * is about to DUPLICATE. Both are memoised and both are only demanded by a site that reaches
	 * their gate, so a file with no such site pays for neither.
	 */
	private static function lazyOf(plugin: GrammarPlugin, source: String, root: QueryNode, resolveIndex: () -> Null<SymbolIndex>): Lazy {
		var cached: Null<PurityCtx> = null;
		var asked: Bool = false;
		function purity(): Null<PurityCtx> {
			if (asked) return cached;
			asked = true;
			final index: Null<SymbolIndex> = resolveIndex();
			return cached = index == null ? null : PurityScan.contextOf(plugin, source, root, index);
		}
		return { resolveIndex: resolveIndex, purity: purity };
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
			exprStatementKind: shape.exprStatementKind,
			armKinds: [for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k],
			andOperatorText: shape.andOperatorText,
			andLowerPrecedence: shape.andLowerPrecedenceKinds ?? [],
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
		lazy: Lazy, out: Array<Match>, parentKind: Null<String>, inElseSlot: Bool
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final isChain: Bool = s.chainKinds.contains(node.kind);
		if (isChain && !inElseSlot && parentKind != null && s.hostKinds.contains(parentKind)) {
			final m: Null<Match> = match(node, source, comments, s, plugin, lazy, parentKind);
			if (m != null) out.push(m);
		}
		final elseSlot: Int = isChain ? ELSE_SLOT_INDEX : -1;
		final childHost: String = slotKindOf(node, parentKind, s);
		for (i in 0...node.children.length) walk(node.children[i], source, comments, s, plugin, lazy, out, childHost, i == elseSlot);
	}


	/**
	 * The rewrite of the chain at `head`, or null when a gate refuses it (see the class doc).
	 * The edit stops at the terminal value rather than at the head's own end: a conditional
	 * node's span runs on through the trivia after its last token.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, plugin: GrammarPlugin,
		lazy: Lazy, parentKind: String
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
		if (rungs.length == 0 || ternaryRungs == 0 || rawTerminal == null) return null;
		final terminalSpan: Span = IfExpressionChain.tokenSpan(rawTerminal, source, comments);
		final emitted: Null<Array<Emitted>> = flatten(rungs, source, comments, s, lazy);
		if (emitted == null || emitted.length < MIN_RUNGS) return null;
		if (PreferSwitchExpression.claims(source, head, parentKind, plugin, lazy.resolveIndex)) return null;
		final kept: Array<Span> = [terminalSpan];
		for (rung in emitted) {
			for (condSpan in rung.condSpans) kept.push(condSpan);
			kept.push(rung.value);
		}
		final seats: Array<CarrySeat> = [
			for (i in 0...emitted.length)
				{
					condEnd: emitted[i].condEnd,
					value: emitted[i].value,
					nextStart: i + 1 < emitted.length ? firstCopiedPiece(emitted[i + 1]) : terminalSpan.from
				}
		];
		final carried: Null<Carried> = IfExpressionChain.carriedComments(
			headSpan, kept, IfExpressionChain.carryGaps(seats), source, comments
		);
		if (carried == null) return null;
		final pairs: Array<{ cond: String, value: String }> = [
			for (rung in emitted) { cond: rung.condText, value: IfExpressionChain.spanText(source, rung.value, carried) }
		];
		return {
			span: headSpan,
			editSpan: new Span(headSpan.from, terminalSpan.to),
			text: IfExpressionChain.buildValue(pairs, source.substring(terminalSpan.from, terminalSpan.to))
		};
	}


	/**
	 * The spine rungs as the rebuild EMITS them. A rung whose value is itself a conditional is
	 * flattened CONJUNCTIVELY — `a ? (b ? A : B) : C` emits `if (a && b) A else if (a) B` — which
	 * is what reaches a chain nested in the THEN arm, where the else spine holds only one
	 * condition and the minimum is two. Null when a gate refuses the whole chain.
	 *
	 * The conjunction preserves evaluation order and requires NO implication between `a` and `b`:
	 * `a` is evaluated first in both forms, `b` only under `a`, and short-circuiting keeps a null
	 * guard doing its job. What it does cost is `a` a SECOND time when `b` is false, which is why
	 * `PurityScan` must prove it duplicable.
	 *
	 * DEPTH CAP of one level. The outer condition is duplicated at every level, so a recursive
	 * expansion grows quadratically (`a ? b ? c ? …` would emit `a && b && c`, `a && b`, `a`);
	 * a deeper nest keeps its inner two-branch ternary, which IS the canon.
	 */
	private static function flatten(
		rungs: Array<Rung>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, lazy: Lazy
	): Null<Array<Emitted>> {
		final out: Array<Emitted> = [];
		for (rung in rungs) {
			final rawCond: Null<Span> = rung.cond.span;
			final rawValue: Null<Span> = rung.value.span;
			// The emitted ` else ` follows every NON-terminal value, and only an else-less
			// conditional can absorb it — the value would silently become that `if`'s else
			// branch. The terminal needs no such gate: an `else` that could follow the chain
			// was already bound INTO the terminal by the parser, which turns it into a rung.
			// Asking it of the WHOLE value subtree also covers both halves of an expansion.
			if (rawCond == null || rawValue == null || IfExpressionChain.holdsElseLessConditional(rung.value, s.conditionalKinds))
				return null;
			final condSpan: Span = IfExpressionChain.tokenSpan(rawCond, source, comments);
			final expanded: Null<Array<Emitted>> = expand(rung, condSpan, source, comments, s, lazy);
			if (expanded == null)
				out.push({
					condText: source.substring(condSpan.from, condSpan.to),
					condSpans: [condSpan],
					condEnd: condSpan.to,
					value: IfExpressionChain.tokenSpan(rawValue, source, comments)
				})
			else
				for (half in expanded) out.push(half);
		}
		return out;
	}

	/**
	 * The two rungs `a ? (b ? A : B) : …` flattens into, or null when this rung is not the
	 * conjunctive shape — the value is no conditional, the grammar spells no `&&`, a span is
	 * unmeasurable, or `a` is not provably duplicable. Null is a FALLBACK, not a refusal: the
	 * caller then emits the rung unexpanded, exactly as before.
	 *
	 * The second half copies NO condition span of its own — it reuses the outer condition's TEXT,
	 * which the first half already copied — so its carry seat opens where the first half's value
	 * ends.
	 */
	private static function expand(
		rung: Rung, condSpan: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, lazy: Lazy
	): Null<Array<Emitted>> {
		final andOp: Null<String> = s.andOperatorText;
		final value: QueryNode = rung.value;
		// A TERNARY value only. An if-expression in the same slot is already the canon this
		// family emits, and pulling it apart would rewrite a shape nobody asked to change.
		if (andOp == null || value.kind != s.ternaryKind || value.children.length != CHAIN_WITH_ELSE_CHILD_COUNT) return null;
		final innerCond: QueryNode = RefactorSupport.unwrapParens(value.children[0], s.parenKind);
		final rawInnerCond: Null<Span> = innerCond.span;
		final rawThen: Null<Span> = value.children[1].span;
		final rawElse: Null<Span> = value.children[ELSE_SLOT_INDEX].span;
		if (rawInnerCond == null || rawThen == null || rawElse == null) return null;
		final ctx: Null<PurityCtx> = lazy.purity();
		if (ctx == null || !PurityScan.isPure(rung.cond, ctx)) return null;
		final innerCondSpan: Span = IfExpressionChain.tokenSpan(rawInnerCond, source, comments);
		final outerText: String = source.substring(condSpan.from, condSpan.to);
		final innerText: String = andOperand(source.substring(innerCondSpan.from, innerCondSpan.to), innerCond, s);
		final thenSpan: Span = IfExpressionChain.tokenSpan(rawThen, source, comments);
		return [
			{
				condText: '${andOperand(outerText, rung.cond, s)} $andOp $innerText',
				condSpans: [condSpan, innerCondSpan],
				condEnd: innerCondSpan.to,
				value: thenSpan
			},
			{
				condText: outerText,
				condSpans: [],
				condEnd: thenSpan.to,
				value: IfExpressionChain.tokenSpan(rawElse, source, comments)
			}
		];
	}

}

/** The kinds `PreferIfExpressionChain` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ternaryKind: String;
	var chainKinds: Array<String>;
	var conditionalKinds: Array<String>;
	var hostKinds: Array<String>;
	var exprStatementKind: Null<String>;
	var armKinds: Array<String>;
	var andOperatorText: Null<String>;
	var andLowerPrecedence: Array<String>;
	var parenKind: Null<String>;
	var opaqueKinds: Array<String>;
}

/** One rung of a scanned chain: its condition (parens already stripped) and its value. */
private typedef Rung = {
	var cond: QueryNode;
	var value: QueryNode;
}

/**
 * One rung as the rebuild EMITS it: the condition TEXT, the condition spans it copies verbatim
 * (two for the first half of a conjunctive expansion, NONE for the second, which reuses the
 * outer condition's text), where the last copied condition piece ends, and the value span.
 */
private typedef Emitted = {
	var condText: String;
	var condSpans: Array<Span>;
	var condEnd: Int;
	var value: Span;
}

/**
 * The two lazily-resolved services the walk carries — the symbol index the
 * `prefer-switch-expression` deferral asks for, and the purity context the conjunctive
 * flattening asks of a condition it is about to duplicate. Bundled so the walk's parameter list
 * does not grow one entry per service.
 */
private typedef Lazy = {
	var resolveIndex: () -> Null<SymbolIndex>;
	var purity: () -> Null<PurityCtx>;
}

/** A convertible chain: the finding key span, the (trivia-trimmed) replaced span, and the if-chain text. */
private typedef Match = {
	var span: Span;
	var editSpan: Span;
	var text: String;
}

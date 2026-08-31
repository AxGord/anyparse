package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.check.IfExpressionChain.Carried;
import anyparse.check.IfExpressionChain.CarrySeat;
import anyparse.check.SwitchChain.ChainScope;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
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
 * equality-shaped chain a `switch`. `prefer-ternary-expression` produces the 2-branch half from an
 * if-EXPRESSION. This check owns the remaining direction — a chain the author wrote as nested `?:`
 * in the first place, which no statement-side rule can see.
 *
 * ## What this check ALSO cleans up, and should not have to (S45, measured)
 *
 * The statement-side rules (`prefer-ternary-return` / `-assignment`,
 * `prefer-if-expression-return` / `-assignment`) were documented here as already producing that
 * canon from `if` STATEMENTS. They do not. `prefer-ternary-return` collapses onto a value that is
 * ALREADY a ternary, which writes a three-rung chain — a violation of THIS check, on code the
 * collapse just wrote. So a share of what arrives here is not an author's nested `?:` at all; it
 * is a sibling rule's output.
 *
 * It is not an oscillation and cannot be: this check's own output holds no ternary rung, so it is
 * its own fixed point, and `--fix` with both enabled converged in four passes. What it costs is
 * the READER. On `if (a) return 1; if (b) return 2; return 3;` the report shows ONE
 * `prefer-ternary-return`; applying it by hand exposes a second whose fix produces
 * `return a ? 1 : b ? 2 : 3` — and the next run condemns that. A `--rule prefer-ternary-return
 * --fix` run alone leaves the tree holding a finding that did not exist before it.
 *
 * Gating `prefer-ternary-return` on the crossing was BUILT AND REJECTED: it removed 70 findings
 * across 13251 external files, every one of them a step the composed `--fix` uses to reach this
 * canon, and it regressed `LintFixFixedPointCliTest.testElseIfChainConverges`. The fix belongs
 * where the canon is reachable in ONE step instead — `prefer-if-expression-return` owning the 3+
 * fall-through cascade, and `redundant-else-after-return` not taking an else-chain away from it
 * (measured: `prefer-if-expression-return` alone turns
 * `LintFixFixedPointCliTest`'s fixture into the canon in ONE fix, and loses the chain to
 * `redundant-else` in a composed run).
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
 * - **At least two conditions** (three leaf values) once the inversion below has run. A
 *   single ternary IS the canon and is left alone; this minimum is the whole
 *   disjointness proof against `prefer-ternary-expression`.
 * - **At least one ternary rung.** A chain already written entirely as if-expressions is the
 *   canon — flagging it would report a fixed point. The count is taken of the SPINE and asked
 *   BEFORE the inversion below folds anything in, so a canonical chain whose last rung VALUE
 *   happens to hold a ternary stays out: nobody wrote THAT as a nested `?:`, and folding it in
 *   inverts the emphasis the author chose (measured on `ShardPlan.compareEntries`). A MIXED
 *   chain (`c1 ? v1 : if (c2) v2 else v3`, which neither this check's predecessor nor
 *   `prefer-ternary-expression` could move) does have one, and converges here.
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
 *   cleanup it buys. The chain's OWN terminal needs no such gate, and that is a fact about
 *   the PARSE rather than an omission — an `else` that could have followed the chain was
 *   already bound INTO the terminal (`a ? 1 : if (q) p() else X` parses as
 *   `a ? 1 : (if (q) p() else X)`), which makes that node a RUNG; so a terminal that is
 *   else-less proves nothing follows it that could re-parent. An INVERTED chain ends on a
 *   DIFFERENT node, about which that argument says nothing, so THAT node is scanned like a
 *   rung value. The scan and the exemption
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
 *   after it. An INVERTED chain opens NO slot: it emits its pieces in a different order from
 *   the one the source wrote them in, so "between this value and the next piece" no longer
 *   describes where a comment would land, and every comment outside a copied span fails the
 *   site closed — the family's original guard, which is what the slot machinery degrades to
 *   with no gaps.
 *
 * A reification subtree (`RefShape.opaqueKinds`, Haxe's `macro { … }`) is skipped wholesale,
 * as in the sibling rewrite rules: its interior is spliced code a consumer may pattern-match
 * on, not source a human reads.
 *
 * ## Inversion
 *
 * The walk follows the ELSE spine, so a ternary nested in the THEN arm contributes only ONE
 * condition and stays below the minimum. `invertTail` reaches it, by INVERTING the rung that
 * holds it: `a ? (b ? A : B) : C` emits `if (!a) C else if (b) A else B`. The chain's terminal
 * moves up into the inverted rung's value, and the nested ternary's own spine takes its place.
 *
 * That rewrite is ALWAYS sound and needs no implication between the two conditions — both
 * readings enumerate the same three outcomes, one starting from `a` and the other from `!a`.
 * It also costs nothing: evaluation order is preserved and `a` is evaluated exactly ONCE, as
 * the ternary evaluated it. Measured over all four combinations with a counting probe: zero
 * divergences, and one evaluation of `a` per run against the two a CONJUNCTIVE form
 * (`if (a && b) A else if (a) B else C`) spends whenever `b` is false. Nothing here has to be
 * pure, and there is no depth cap: the loop recurses because it duplicates nothing, so a
 * deeper nest folds in one level per turn and growth is linear.
 *
 * Only the LAST rung can invert, and that is a proof rather than a simplification. A flat
 * chain tests its conditions in order, so a nested rung with more chain behind it would have
 * to test `a` — whose branch still needs `b` to pick a value — or `!a`, whose branch still
 * holds the whole remaining chain. Neither is one value, and duplicating `a` is the only way
 * around it. Such a rung keeps its inner two-branch ternary, which IS the canon. Only a
 * TERNARY value folds in: an if-expression in the same slot is already the form this family
 * emits.
 *
 * The negation is `NegationScan`'s, the same engine the `guard-*` family inverts with, so a
 * comparison operator FLIPS (`content == ''` becomes `content != ''`) and a compound De
 * Morgans rather than taking a `!( … )` wrap. Its WORTH GATE is asked too — an ordered
 * comparison the engine cannot prove NaN- and null-free stays wrapped, which reads worse than
 * the positive form — but only where declining COSTS nothing: a chain that already holds the
 * minimum rungs converts WITHOUT the fold, so a wrap there buys one more rung and pays for it,
 * while a chain below the minimum converts only BECAUSE of the fold, and declining would leave
 * exactly the nested ternary this rule exists to remove. (The conjunctive form paid for those
 * same chains with the whole condition DUPLICATED, which is worse than one wrap on every axis.)
 * A comment anywhere in the condition span declines the inversion outright — that one is
 * correctness, not worth: the engine rebuilds the condition from its operands and would drop
 * the glue the comment sits in.
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
 * The replaced region stops at the ORIGINAL chain's TERMINAL VALUE, at its last TOKEN — not
 * at the chain head's own end, and not at the terminal's raw span end either: an expression
 * node's span runs on through the trivia after its last token, and splicing that away welds
 * the emitted chain onto whatever follows. It is the ORIGINAL terminal because that node is
 * the chain's rightmost piece whatever the inversion does to the emission order — the
 * terminal the rebuild finally writes can sit well before it.
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
 * condition unwrap and `opaqueKinds` the subtrees to skip. The inversion additionally needs
 * the grammar's `BooleanLogicSupport` and `NegationScan.negationSeams`; without them the
 * negation falls back to a verbatim `!( … )` wrap, which is still correct. No `ternaryKind`
 * (nothing to convert) or no host kind → the check is a no-op.
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
			for (entry in files) for (m in collect(plugin, entry.file, entry.source, seams, resolveIndex))
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
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final resolveIndex: () -> Null<SymbolIndex> = SwitchChain.lazyIndexOf([{ file: file, source: source }], plugin, index);
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, file, source, seams, resolveIndex, index)) byKey['${m.span.from}:${m.span.to}'] = m;
		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
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
	 * Every convertible chain in `source` (empty when it does not parse). `run` and `fix`
	 * both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(
		plugin: GrammarPlugin, file: String, source: String, s: Seams, resolveIndex: () -> Null<SymbolIndex>, ?index: SymbolIndex
	): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<Match> = [];
		walk(
			tree, source, RefactorSupport.collectCommentTokens(source), s, plugin, lazyOf(plugin, file, source, tree, resolveIndex, index),
			out, null, false
		);
		return out;
	}

	/**
	 * The two lazily-resolved services the walk carries: the symbol index the switch-expression
	 * deferral asks for, and the operand-type probe the negation engine asks of a condition the
	 * inversion is about to complement — the same probe the `guard-*` family passes it, and what
	 * licenses flipping an ordered comparison rather than wrapping it. Both are memoised and both
	 * are only demanded by a site that reaches their gate, so a file with no such site pays for
	 * neither.
	 */
	private static function lazyOf(
		plugin: GrammarPlugin, file: String, source: String, root: QueryNode, resolveIndex: () -> Null<SymbolIndex>, ?index: SymbolIndex
	): Lazy {
		var cached: Null<(QueryNode) -> Null<String>> = null;
		var asked: Bool = false;
		function types(): Null<(QueryNode) -> Null<String>> {
			if (asked) return cached;
			asked = true;
			return cached = CheckScan.typeNominalResolver(source, plugin, root, file, index);
		}
		return { switchScope: { root: root, resolveIndex: resolveIndex }, types: types };
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
			negation: NegationScan.negationSeams(shape),
			logic: plugin.booleanLogicSupport(),
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
		final chain: Chain = spine(head, s);
		final rawEnd: Null<Span> = chain.terminal.span;
		// The ternary-rung minimum is asked of the SPINE, BEFORE any inversion. A chain the author
		// already wrote as if-expressions is the canon whatever its branch VALUES hold, and asking
		// after the fold would claim one whose only ternary sits in the last rung's value — a shape
		// nobody wrote as a nested `?:`, and one the fold demonstrably makes read worse.
		if (chain.rungs.length == 0 || chain.ternaryRungs == 0 || rawEnd == null) return null;
		// The EDIT stops at the ORIGINAL terminal's last token. That node is the chain's rightmost
		// piece whatever the inversion does to the EMISSION order, and the terminal the rebuild
		// finally writes can sit well before it.
		final chainEnd: Span = IfExpressionChain.tokenSpan(rawEnd, source, comments);
		final inverted: Bool = invertTail(chain, source, s, lazy);
		final rawTerminal: Null<Span> = chain.terminal.span;
		if (rawTerminal == null) return null;
		final terminalSpan: Span = IfExpressionChain.tokenSpan(rawTerminal, source, comments);
		final emitted: Null<Array<Emitted>> = emit(chain, source, comments, s, lazy, inverted);
		if (emitted == null || emitted.length < MIN_RUNGS) return null;
		if (PreferSwitchExpression.claims(source, head, parentKind, plugin, lazy.switchScope)) return null;
		final kept: Array<Span> = [terminalSpan];
		for (rung in emitted) {
			kept.push(rung.condSpan);
			kept.push(rung.value);
		}
		// An INVERTED chain emits its pieces in a different order from the one the source wrote
		// them in, so a seat's "between this value and the next piece" region no longer describes
		// where a comment would land. No seat is opened, and every comment outside a copied span
		// fails the site closed — the family's original guard, which is what `carriedComments`
		// degrades to with no gaps.
		final seats: Array<CarrySeat> = inverted ? [] : [
			for (i in 0...emitted.length)
				{
					condEnd: emitted[i].condSpan.to,
					value: emitted[i].value,
					nextStart: i + 1 < emitted.length ? emitted[i + 1].condSpan.from : terminalSpan.from
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
			editSpan: new Span(headSpan.from, chainEnd.to),
			text: IfExpressionChain.buildValue(pairs, source.substring(terminalSpan.from, terminalSpan.to))
		};
	}


	/**
	 * The chain rooted at `head` read as a SPINE: one rung per `else`-nested link, the terminal
	 * the last `else` holds, and how many of those links the author wrote as a TERNARY. Reading
	 * the spine of a NESTED value is exactly what the inversion below recurses with, so the walk
	 * lives in one function instead of inline in `match`.
	 */
	private static function spine(head: QueryNode, s: Seams): Chain {
		final rungs: Array<Rung> = [];
		var ternaryRungs: Int = 0;
		var cur: QueryNode = head;
		while (s.chainKinds.contains(cur.kind) && cur.children.length == CHAIN_WITH_ELSE_CHILD_COUNT) {
			if (cur.kind == s.ternaryKind) ternaryRungs++;
			// The emitted `if (` … `)` supplies its own delimiters, so a copied paren pair would
			// only draw a `redundant-parens` finding on the result; nothing inside a condition
			// slot can be load-bearing, the construct bounding it on both sides.
			rungs.push({ cond: RefactorSupport.unwrapParens(cur.children[0], s.parenKind), value: cur.children[1], invert: false });
			cur = cur.children[ELSE_SLOT_INDEX];
		}
		return { rungs: rungs, terminal: cur, ternaryRungs: ternaryRungs };
	}

	/**
	 * Fold a ternary nested in the LAST rung's THEN arm into the spine by INVERTING that rung —
	 * `a ? (b ? A : B) : C` becomes `if (!a) C else if (b) A else B`. The chain's terminal moves up
	 * into the inverted rung's value, and the nested ternary's own spine takes its place, so the
	 * result is FLAT. `chain` is mutated; the return says whether anything inverted.
	 *
	 * ALWAYS sound, and needing no implication between `a` and `b`: both readings enumerate the
	 * same three outcomes, one starting from `a`, the other from `!a`. Evaluation order is
	 * preserved and `a` is evaluated exactly ONCE — as the ternary evaluated it — which is why
	 * nothing here has to be pure.
	 *
	 * The loop RECURSES because inversion duplicates nothing: after one step the nested chain's own
	 * last rung is the new last rung, and a deeper nest folds in on the next turn. Growth is
	 * linear, so there is no depth cap.
	 *
	 * Only the LAST rung can invert, and that is a proof rather than a simplification. A flat chain
	 * tests its conditions in order, so a nested rung with more chain behind it would have to test
	 * `a` (whose branch still needs `b` to pick a value) or `!a` (whose branch still holds the whole
	 * remaining chain) — neither is one value. Duplicating `a` is the only way to flatten that, and
	 * duplicating is what this rewrite exists to stop doing. Such a rung keeps its inner ternary,
	 * which IS the canon.
	 *
	 * Only a TERNARY value folds in. An if-expression in the same slot is already the form this
	 * family emits, and pulling it apart would rewrite a shape nobody asked to change.
	 */
	private static function invertTail(chain: Chain, source: String, s: Seams, lazy: Lazy): Bool {
		var inverted: Bool = false;
		while (true) {
			final count: Int = chain.rungs.length;
			if (count == 0) break;
			final last: Rung = chain.rungs[count - 1];
			final nested: QueryNode = last.value;
			if (nested.kind != s.ternaryKind || nested.children.length != CHAIN_WITH_ELSE_CHILD_COUNT) break;
			final condSpan: Null<Span> = last.cond.span;
			// The negation engine REBUILDS the condition from its operands, dropping the glue between
			// them — so a comment anywhere in that span would be lost or welded into a position the
			// author did not write. Decline, and the rung stays unexpanded.
			if (condSpan == null || CheckScan.hasCommentMarker(source, condSpan.from, condSpan.to)) break;
			// The engine's OWN worth gate, the one `guard-return` / `guard-continue` / `loop-guard`
			// ask before they invert: an ordered comparison it cannot prove NaN- and null-free stays
			// wrapped `!(a < b)`, which reads worse than the positive form.
			//
			// It is asked only where declining COSTS nothing. A chain that already holds the minimum
			// rungs converts WITHOUT this fold, so a wrapped negation there buys one more rung and
			// pays a `!( … )` for it — decline, and the nested ternary stays, which IS the canon. A
			// chain BELOW the minimum converts only BECAUSE of the fold: declining leaves exactly the
			// nested ternary this rule exists to remove, and the alternative the conjunctive form used
			// to take was the whole condition DUPLICATED — worse than one wrap on every axis.
			if (count >= MIN_RUNGS && !NegationScan.negationIsClean(last.cond, source, s.logic, lazy.types())) break;
			final inner: Chain = spine(nested, s);
			chain.rungs.pop();
			chain.rungs.push({ cond: last.cond, value: chain.terminal, invert: true });
			for (rung in inner.rungs) chain.rungs.push(rung);
			chain.terminal = inner.terminal;
			inverted = true;
		}
		return inverted;
	}

	/**
	 * The spine rungs as the rebuild EMITS them — the condition TEXT (the verbatim source, or its
	 * negation for an inverted rung) and the two spans the rebuild copies. Null when a gate refuses
	 * the whole chain.
	 */
	private static function emit(
		chain: Chain, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, lazy: Lazy, inverted: Bool
	): Null<Array<Emitted>> {
		// The chain's OWN terminal is exempt from the else-less gate below, and that exemption is a
		// fact about ITS parse: an `else` that could have followed the chain was already bound INTO
		// it, which would have made it a rung. An INVERTED chain ends on a DIFFERENT node, about
		// which that argument says nothing — an `else` written after the whole chain would re-parent
		// onto it — so it is scanned like a rung value.
		if (inverted && IfExpressionChain.holdsElseLessConditional(chain.terminal, s.conditionalKinds)) return null;
		final out: Array<Emitted> = [];
		for (rung in chain.rungs) {
			final rawCond: Null<Span> = rung.cond.span;
			final rawValue: Null<Span> = rung.value.span;
			// The emitted ` else ` follows every NON-terminal value, and only an else-less
			// conditional can absorb it — the value would silently become that `if`'s else branch.
			// The whole value subtree is scanned, not just its right spine.
			if (rawCond == null || rawValue == null || IfExpressionChain.holdsElseLessConditional(rung.value, s.conditionalKinds))
				return null;
			final condSpan: Span = IfExpressionChain.tokenSpan(rawCond, source, comments);
			final condText: String = rung.invert
				? NegationScan.negateConditionText(rung.cond, source, s.negation, s.logic, lazy.types())
				: source.substring(condSpan.from, condSpan.to);
			out.push({ condText: condText, condSpan: condSpan, value: IfExpressionChain.tokenSpan(rawValue, source, comments) });
		}
		return out;
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
	var negation: NegationSeams;
	var logic: Null<BooleanLogicSupport>;
	var parenKind: Null<String>;
	var opaqueKinds: Array<String>;
}

/**
 * One rung of a scanned chain: its condition (parens already stripped), its value, and whether
 * the rebuild emits that condition NEGATED — which is what an INVERTED rung is.
 */
private typedef Rung = {
	var cond: QueryNode;
	var value: QueryNode;
	var invert: Bool;
}

/**
 * A chain read as a spine: its rungs, the terminal the last `else` holds, and how many of its
 * links the author wrote as a ternary. `invertTail` mutates the first two as it folds a nested
 * ternary in, which is why they travel together rather than as separate returns; the count is
 * read BEFORE that, so it stays a fact about the SPINE the author wrote.
 */
private typedef Chain = {
	var rungs: Array<Rung>;
	var terminal: QueryNode;
	var ternaryRungs: Int;
}

/**
 * One rung as the rebuild EMITS it: the condition TEXT, the condition span it copies, and the value span.
 */
private typedef Emitted = {
	var condText: String;
	var condSpan: Span;
	var value: Span;
}

/**
 * The two services the walk carries — the root-plus-index pair the `prefer-switch-expression`
 * deferral is asked with, and the lazily-resolved operand-type probe the negation engine asks of a
 * condition the inversion complements. Bundled so the walk's parameter list does not grow one entry
 * per service.
 */
private typedef Lazy = {
	var switchScope: ChainScope;
	var types: () -> Null<(QueryNode) -> Null<String>>;
}

/** A convertible chain: the finding key span, the (trivia-trimmed) replaced span, and the if-chain text. */
private typedef Match = {
	var span: Span;
	var editSpan: Span;
	var text: String;
}

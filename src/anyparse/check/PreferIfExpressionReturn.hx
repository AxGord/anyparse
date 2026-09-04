package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.Carried;
import anyparse.check.IfExpressionChain.CarrySeat;
import anyparse.check.IfExpressionChain.IfChain;
import anyparse.check.IfExpressionChain.TernaryTail;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags an `if / else if / … / else` CHAIN whose EVERY branch is a valued `return`,
 * collapsing the whole chain to one `return` of an if-expression:
 *
 * ```haxe
 * if (cond)   return a;
 * else if (d) return b;
 * else        return c;
 * // ->
 * return if (cond) a else if (d) b else c;
 * ```
 *
 * Purely structural, so it holds without a type-checker. `Info` -- the code is correct,
 * this is a readability simplification. The `return` sibling of
 * `prefer-if-expression-assignment`; see it and `IfExpressionChain` for the chain shape,
 * the single-statement rule, the comment slots and why no null-narrowing guard is needed.
 *
 * ## Boundary with `prefer-ternary-return`
 *
 * Split by VALUE COUNT, not by spelling. Two leaf values are a ternary and
 * `prefer-ternary-return`'s; three or more are an if-expression chain and this rule's - in EITHER
 * spelling of the same control flow, the written `if / else if / … / else` chain and the
 * fall-through cascade `redundant-else-after-return` rewrites it into. A terminal value that is
 * itself a ternary spine counts its own leaves, so `if (c) return a; return p ? q : r;` is three.
 *
 * The other two rules defer by ASKING this one (`claimsChain` / `claimsCascade`), gates and all,
 * rather than mirroring the shape: a shape-only deferral silences them wherever this rule refuses
 * on a comment, and S45 measured 14 of 69 findings lost that way with no replacement anywhere.
 * The claim is also march-GATED (`marchable`): it may not reach past what the pairwise route
 * already collapsed, or silencing that route CHANGES the fixed point.
 *
 * ## What is flagged
 *
 * A chain HEAD whose else-nesting terminates in a plain `else`, every branch AND the
 * terminal is exactly ONE valued `return` statement (a bare `return;` -- a distinct
 * node kind -- disqualifies). The reported span is the whole head `if`. Two further gates
 * guard the ` else ` this rule EMITS, and are shared with the sibling collapse rules
 * (`IfExpressionChain`):
 *
 * - **No else-less conditional in a NON-TERMINAL branch value.** The emitted ` else ` follows
 *   every returned value but the last, and an `if` without its own `else` ends an expression
 *   OPEN, so it ABSORBS it. `if (a) { return if (q) 1; } else if (b) return 2; else return 3;`
 *   would emit `return if (a) if (q) 1 else if (b) 2 else 3;`, where `else if (b) 2 else 3`
 *   has become the INNER `if`'s else branch and the outer condition has lost its else
 *   entirely. The braces are what let the source `else` bind outward in the first place, and
 *   the single-statement unwrap (`IfExpressionChain.singleStmt`) is what re-exposes the
 *   else-less tail; the output still re-parses, so the `--fix` re-parse gate would wave it
 *   through. The whole value subtree is scanned, not only its right spine -- proving which
 *   else-less `if` sits in a delimited interior costs more than the rare cleanup it buys. The
 *   TERMINAL value is EXEMPT from THIS scan: nothing follows it but the emitted `;`, so nothing
 *   can re-parent onto it.
 * - **No else-less conditional at the TERMINAL value's ROOT.** A separate, narrower refusal with
 *   a span cause rather than a re-parenting one: the parser folds a statement's own `;` INTO an
 *   else-less conditional, so the terminal of `else return if (q) 3;` spans `if (q) 3;` and the
 *   rebuild appends its own `;`, writing `return … else if (q) 3;;`. anyparse re-parses that, so
 *   the `--fix` gate passes it, but Haxe rejects it (`Expected }` on 4.3.7) -- and the input IS
 *   legal Haxe whenever the carrier is `Void`-typed, so the fix turns working code into code that
 *   does not compile. ROOT-only on purpose: a delimited-interior conditional (`return g(if (q) 3)`)
 *   cannot swallow the terminator, and stays claimable.
 * - **No comment the rebuild cannot place.** The header keywords, the braces and every
 *   non-head `return ` go away. A comment sitting between a branch's condition and its
 *   returned value, or after that value with nothing but the branch's own `;` / `}` in
 *   between, rides the matching slot of the rebuilt branch
 *   (`IfExpressionChain.carriedComments`) and keeps its position; any OTHER comment in the
 *   folded region -- past the `else` that opens the next branch, above the head, inside the
 *   condition -- still fails the site closed, per the family's stance that a comment is never
 *   dropped nor moved somewhere that changes what it says. Each copied span is first cut back
 *   to its last TOKEN (`IfExpressionChain.tokenSpan`) -- a node's span runs on through the
 *   trivia after it, so `return u + v // why` hands back a value span that SWALLOWS the
 *   comment; trimming both moves it out of the copied text and into the slot machinery's view,
 *   which is the only reason either the carry or the refusal sees it.
 *
 * ## Autofix
 *
 * `fix` replaces the head `if` with `return if (c1) a else if (c2) b … else n;` -- the
 * `return ` prefix copied from the head, the conditions and returned values from their
 * spans, each cut back to its last token, with any carried comment welded into the branch
 * slot it came from. `Match` carries those TRIMMED SPANS rather than nodes, so the text
 * `buildEdit` copies and the region the comment classification reports as kept cannot drift
 * apart. Needs `ifStatementKinds`, `returnStatementKind`, `blockStmtKind` (any unset makes
 * it a no-op).
 */
@:nullSafety(Strict)
final class PreferIfExpressionReturn implements Check {

	/** This check's rule id, written into every finding it raises. */
	private static inline final RULE_ID: String = 'prefer-if-expression-return';

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	/**
	 * The fewest CONDITIONS a claim needs — three leaf values. Two values are a ternary and belong
	 * to `prefer-ternary-return`; the count is taken AFTER the terminal ternary spine is folded in,
	 * so `if (c) return a; return p ? q : r;` reaches it with one written `if`.
	 */
	private static inline final MIN_CHAIN_RUNGS: Int = 2;

	/**
	 * `IfExpressionChain.collect` / `collectCascade` are asked for a ONE-branch chain and the rung
	 * minimum above is applied after folding, rather than asking them for two branches: the fold
	 * turns a written branch count into a value count, and only the value count decides.
	 */
	private static inline final MIN_COLLECT_BRANCHES: Int = 1;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an if/else-if chain returning in every branch, collapsible to a single if-expression return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final blockKinds: Array<String> = blockKindsOf(plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			// BRANCH-AWARE, and the cascade arm is why. A cascade is a SIBLING relation, so it is
			// only visible where the statements share a statement list — and in the plain projection
			// a conditional-compilation region is ONE node whose branches are flattened children, no
			// block at all. `prefer-ternary-return` reads the branch-aware projection and defers to
			// this rule, so a cascade inside a `#if` region would be deferred to a walk that never
			// saw it: measured on openfl's `Lib.hx`, where a three-`return` cascade under `#end`
			// lost its only finding. The else-chain arm is indifferent — it flags a chain head
			// wherever the walk reaches one, and an `if` node's own children are the same in both
			// projections.
			final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> =
				SourceComments.collectCommentTokens(plugin.lexicalRegions(entry.source));
			walk(tree, violations, entry.file, entry.source, comments, seams);
			walkCascades(tree, violations, entry.file, entry.source, comments, seams, blockKinds);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifKinds, (node, span) -> {
				final m: Null<Match> = match(node, source, comments, seams, false);
				return m == null ? null : buildEdit(m, source, span);
			});
		// The cascade arm cannot go through `applyBySpan`: its edit spans the head `if` THROUGH a
		// later SIBLING, and a node handed back by kind carries no access to its siblings. It
		// re-walks the tree the way `prefer-ternary-return` does, keyed on the same flagged spans.
		final blockKinds: Array<String> = blockKindsOf(plugin);
		final tree: Null<QueryNode> = blockKinds.length == 0 ? null : CheckScan.parseBranchAwareOrNull(plugin, source);
		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(IfExpressionChain.spanKey(span));
		}
		if (tree != null) collectCascadeFixes(tree, source, comments, seams, blockKinds, flagged, edits);
		return CanonicalEdit.dropContainedEdits(edits);
	}

	/**
	 * Whether this check claims the else-linked chain headed by `head` — the EXACT question, every
	 * gate included, not its shape. `redundant-else-after-return` asks it before flagging: its
	 * de-nest takes a chain of valued returns away from a rule whose single fix IS the canon, and
	 * the composed `--fix` then reaches the same text the long way, through the three-rung ternary
	 * `prefer-if-expression-chain` condemns. Asking the shape instead would silence that rule on
	 * every site THIS one refuses on a comment — a finding lost with no replacement.
	 */
	public static function claimsChain(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, shape: RefShape
	): Bool {
		// March-gated where the REPORT is not: this rule already flagged every valued-return chain
		// before this slice and its own edit was deferred by the de-nest's, so gating the report
		// would lose a finding the base had. The CLAIM is what silences the other rule, and it may
		// only silence where this rule reaches the same text the march did.
		final seams: Null<Seams> = readSeams(shape);
		return seams != null && match(head, source, comments, seams, true) != null;
	}

	/**
	 * Whether this check claims the fall-through cascade starting at `kids[at]` — the same exact
	 * question for the other spelling. `prefer-ternary-return` asks it before flagging a pair: a
	 * pair that is the TAIL of a claimed cascade is one rung of a rewrite this rule performs whole,
	 * and collapsing it alone writes the ternary chain that has to be unrolled again afterwards.
	 */
	public static function claimsCascade(
		kids: Array<QueryNode>, at: Int, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, shape: RefShape
	): Bool {
		final seams: Null<Seams> = readSeams(shape);
		return seams != null && cascadeMatch(kids, at, source, comments, seams) != null;
	}

	/**
	 * The index at which the fall-through run holding `kids[at]` STARTS — the first index whose
	 * predecessor is not a rung this rule would collect.
	 *
	 * Published because `prefer-ternary-return` has to ask `claimsCascade` about the SAME head this
	 * rule reports at. Derived separately the two disagree the moment a no-`else` `if` that does NOT
	 * return sits in front of a cascade: that statement is a rung by SHAPE, so a shape-only walk-back
	 * runs past it, asks about a head this rule never uses, and gets a `false` it reads as licence to
	 * collapse — both rules then report one control flow. Measured on heaps' `poly2tri/Point.hx`,
	 * `cpp/_std/StringBuf.hx` and `php/_std/EReg.hx`.
	 */
	public static function returnRunHead(kids: Array<QueryNode>, at: Int, shape: RefShape): Int {
		final seams: Null<Seams> = readSeams(shape);
		if (seams == null) return at;
		var head: Int = at;
		while (head > 0 && isReturnRung(kids[head - 1], seams)) head--;
		return head;
	}

	/** The source text `span` covers. */
	private static inline function text(source: String, span: Span): String {
		return source.substring(span.from, span.to);
	}

	/**
	 * The statement-list kinds the cascade arm walks, or an empty list when the grammar exposes no
	 * `ControlFlowSupport`. A cascade is a SIBLING relation, so with no statement-list model there
	 * is nothing to read and the else-chain arm carries the rule alone.
	 */
	private static function blockKindsOf(plugin: GrammarPlugin): Array<String> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? [] : support.blockKinds();
	}

	/**
	 * Walk `node`; at each statement list flag the HEAD of every fall-through return cascade. The
	 * head is the index whose predecessor is not itself a rung — the collector is greedy, so every
	 * later index of one run would collect a shorter cascade and report the same code again.
	 *
	 * The finding's span is that head `if`'s own span, the coordinate the else-chain arm reports
	 * too, so `fix` finds it and the two spellings of one control flow report at the same place.
	 */
	private static function walkCascades(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, blockKinds: Array<String>
	): Void {
		if (blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				if (i > 0 && isReturnRung(kids[i - 1], s)) continue; // not a run HEAD
				if (cascadeMatch(kids, i, source, comments, s) == null) continue;
				final span: Null<Span> = kids[i].span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this if/return cascade can be a single if-expression return'
				});
			}
		}
		for (c in node.children) walkCascades(c, out, file, source, comments, s, blockKinds);
	}

	/**
	 * Mirror `walkCascades`: collect one replacement edit per flagged cascade head. The edit's span
	 * runs from that head to the END of the terminal statement, which is why this walk exists at
	 * all — `applyBySpan` hands back a node, and the rest of the cascade is that node's siblings.
	 */
	private static function collectCascadeFixes(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, blockKinds: Array<String>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				if (i > 0 && isReturnRung(kids[i - 1], s)) continue;
				final headSpan: Null<Span> = kids[i].span;
				if (headSpan == null || !flagged.contains(IfExpressionChain.spanKey(headSpan))) continue;
				final chain: Null<IfChain> = IfExpressionChain.collectCascade(kids, i, s.ifKinds, s.blockStmtKind, MIN_COLLECT_BRANCHES);
				if (chain == null) continue;
				final endSpan: Null<Span> = chain.terminal.span;
				if (endSpan == null) continue;
				final region: Span = new Span(headSpan.from, endSpan.to);
				final m: Null<Match> = matchChain(chain, region, source, comments, s, true);
				if (m != null) edits.push(buildEdit(m, source, region));
			}
		}
		for (c in node.children) collectCascadeFixes(c, source, comments, s, blockKinds, flagged, edits);
	}

	/** Bundle the required `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind,
			conditionalKinds: IfExpressionChain.conditionalKinds(shape),
			ternaryKind: shape.ternaryKind,
			parenKind: shape.parenKind,
			shape: shape
		};
	}

	/** Walk `node`, flagging each chain HEAD whose branches all return a value. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (s.ifKinds.contains(node.kind) && !IfExpressionChain.isElseIfLink(node, parent, s.ifKinds)) {
			final m: Null<Match> = match(node, source, comments, s, false);
			if (m != null) {
				final span: Null<Span> = node.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this if/else-if return chain can be a single if-expression return'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `head` is a chain of single valued-`return` branches, no branch value would absorb the
	 * emitted ` else `, and no comment sits in a dropped region, return the match parts; else
	 * null. Every copied piece is cut back to its last token here, so `buildEdit` and
	 * `droppedComment` see the same spans.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, marchOnly: Bool
	): Null<Match> {
		final chain: Null<IfChain> = IfExpressionChain.collect(head, s.ifKinds, s.blockStmtKind, MIN_COLLECT_BRANCHES);
		final headSpan: Null<Span> = head.span;
		return chain == null || headSpan == null ? null : matchChain(chain, headSpan, source, comments, s, marchOnly);
	}

	/**
	 * The same match for the FALL-THROUGH spelling: `kids[at]` opens a run of no-`else` `if`s each
	 * returning a value, and the sibling past the run returns one too. Null when no such run starts
	 * here or when any gate of `matchChain` refuses it.
	 *
	 * The two spellings are one control flow — `redundant-else-after-return` rewrites the chain into
	 * this cascade — so both go through `matchChain` and the gates cannot answer differently for
	 * them. That is also what lets `redundant-else-after-return` and `prefer-ternary-return` defer to
	 * this rule by ASKING it (`claimsChain` / `claimsCascade`) rather than mirroring its shape: a
	 * shape-only deferral drops the findings whose site this rule refuses on a comment.
	 */
	private static function cascadeMatch(
		kids: Array<QueryNode>, at: Int, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final chain: Null<IfChain> = IfExpressionChain.collectCascade(kids, at, s.ifKinds, s.blockStmtKind, MIN_COLLECT_BRANCHES);
		if (chain == null) return null;
		final from: Null<Span> = kids[at].span;
		final to: Null<Span> = chain.terminal.span;
		// ALWAYS march-gated: this arm is new, so anything it claims beyond what
		// `prefer-ternary-return` already marched is a fixed point this slice CHANGED.
		return from == null || to == null ? null : matchChain(chain, new Span(from.from, to.to), source, comments, s, true);
	}

	/**
	 * If `chain` is a chain of single valued-`return` branches, no branch value would absorb the
	 * emitted ` else `, and no comment sits in a dropped region of `region` — the span the rebuild
	 * replaces — return the match parts; else null. Every copied piece is cut back to its last token
	 * here, so `buildEdit` and the comment classification see the same spans.
	 */
	private static function matchChain(
		chain: IfChain, region: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, marchOnly: Bool
	): Null<Match> {
		final headReturnSpan: Null<Span> = chain.branches[0].stmt.span;
		if (headReturnSpan == null) return null;
		final values: Array<QueryNode> = [];
		final pairs: Array<{ cond: Span, value: Span }> = [];
		if (!collectRungs(chain.branches, source, comments, s, pairs, values)) return null;
		final returned: Null<QueryNode> = returnValue(chain.terminal, s);
		if (returned == null) return null;
		final returnedSpan: Null<Span> = returned.span;
		if (returnedSpan == null) return null;
		// A terminal ternary SPINE becomes rungs of this chain — `IfExpressionChain.unrollTernaryTail`
		// carries the measurement for why the fixed point demands it. Fail-closed on a comment
		// anywhere inside that spine: the rebuild copies each rung's condition and value span, so a
		// comment on the `?` or the `:` between them rides no copied piece and would be dropped with
		// nothing to report it.
		final tail: TernaryTail = IfExpressionChain.unrollTernaryTail(returned, s.ternaryKind, s.parenKind);
		if (tail.pairs.length > 0 && comments.exists(tok -> tok.from >= returnedSpan.from && tok.to <= returnedSpan.to)) return null;
		if (!collectFoldedRungs(tail.pairs, source, comments, s, pairs, values)) return null;
		if (pairs.length < MIN_CHAIN_RUNGS) return null;
		final terminal: QueryNode = tail.terminal;
		values.push(terminal);
		if (marchOnly && !marchable(values, s)) return null;
		final rawTerminal: Null<Span> = terminal.span;
		if (rawTerminal == null) return null;
		// The terminal is exempt from RE-PARENTING (nothing the rebuild emits follows it but the
		// closing `;`), but not from the span: the parser folds a statement's own `;` INTO an
		// else-less conditional at the value's ROOT, so copying `if (q) 3;` and appending the
		// rebuild's `;` writes `…3;;` — which anyparse re-parses but Haxe rejects. Root-ONLY: a
		// delimited-interior one (`g(if (q) 3)`) cannot swallow the terminator and stays claimable.
		if (IfExpressionChain.isElseLessConditional(terminal, s.conditionalKinds)) return null;
		final terminalValue: Span = IfExpressionChain.tokenSpan(rawTerminal, source, comments);
		final prefix: Span = new Span(headReturnSpan.from, pairs[0].value.from);
		final kept: Array<Span> = [prefix, terminalValue];
		final seats: Array<CarrySeat> = [];
		for (i in 0...pairs.length) {
			kept.push(pairs[i].cond);
			kept.push(pairs[i].value);
			seats.push({
				condEnd: pairs[i].cond.to,
				value: pairs[i].value,
				nextStart: i + 1 < pairs.length ? pairs[i + 1].cond.from : terminalValue.from
			});
		}
		final carried: Null<Carried> =
			IfExpressionChain.carriedComments(region, kept, IfExpressionChain.carryGaps(seats), source, comments);
		if (carried == null) return null;
		// Re-bound to a non-null local: the narrowing above does not reach into a structure literal.
		final slots: Carried = carried;
		return {
			prefix: prefix,
			pairs: pairs,
			terminalValue: terminalValue,
			carried: slots
		};
	}

	/**
	 * Whether `prefer-ternary-return`'s own pairwise march would carry every one of these values to
	 * the same text this rule writes in one step. The two rules now hand one control flow back and
	 * forth — that rule defers a pair inside a claimed cascade, this one claims the cascade — so the
	 * claim must not reach further than the march did, or the CHANGE of fixed point is the change,
	 * and a guard cascade nobody asked to fold becomes one expression.
	 *
	 * Measured: without this, a full `--fix` over 1029 external files diverged from the base in 45 of
	 * them, 29 of the diffs turning a `return false;` guard into a rung. Every refusal below mirrors
	 * a gate `PreferTernaryReturn.pairAt` already applies to the pair it would collapse, read here
	 * over the whole rung list because the march applies it once per step:
	 *
	 * - a BOOL LITERAL rung. `isStuckBooleanCollapse` refuses `cond ? true : <not provably Bool>`,
	 *   and from the second step on the other side of that pair is the accumulated ternary, which
	 *   nothing can prove `Bool` without a typer. Refusing every bool-literal rung is stricter than
	 *   that gate — the march does collapse one when the enclosing function DECLARES `Bool` — and
	 *   stricter is the safe side: this rule then simply does not claim, `prefer-ternary-return`
	 *   keeps its finding, and the site converges exactly as it did before.
	 * - a STATEMENT-LIKE value (an `if` / `switch` / `try` / block used as a value) or a boolean
	 *   ternary MID-REDUCTION, both refused by that rule for reasons that do not stop being true
	 *   when the same value becomes an if-expression rung.
	 */
	private static function marchable(values: Array<QueryNode>, s: Seams): Bool {
		final boolLitKind: Null<String> = s.shape.boolLitKind;
		for (v in values) {
			if (boolLitKind != null && v.kind == boolLitKind) return false;
			if (BoolExprShape.statementLikeValue(v, s.shape)) return false;
			if (BoolExprShape.pendingBooleanTernaryTail(v, s.shape)) return false;
		}
		return true;
	}

	/** The returned expression of `stmt` when it is a valued `return`; null for a bare `return;` or any other statement. */
	private static function returnValue(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return stmt.kind == s.returnKind && stmt.children.length == RETURN_VALUE_CHILD_COUNT ? stmt.children[0] : null;
	}

	/** Build the `return if (c1) a else if (c2) b … else n;` edit replacing the whole head-`if` span. */
	private static function buildEdit(m: Match, source: String, span: Span): { span: Span, text: String } {
		final built: Array<{ cond: String, value: String }> = [
			for (p in m.pairs) { cond: text(source, p.cond), value: IfExpressionChain.spanText(source, p.value, m.carried) }
		];
		return { span: span, text: IfExpressionChain.buildText(text(source, m.prefix), built, text(source, m.terminalValue)) };
	}

	/**
	 * Append one `(condition, value)` rung per WRITTEN branch to `pairs`, and each branch's value to
	 * `values`. False when a branch is not a single valued `return`, when its value would ABSORB the
	 * emitted ` else ` (an else-less conditional anywhere below it - the rest of the chain would
	 * silently become that `if`'s else branch, and the result re-parses, so the `--fix` gate would
	 * wave it through), or when a span is missing.
	 *
	 * Conditions are copied paren-UNWRAPPED, as `PreferIfExpressionChain.spine` unwraps its own: the
	 * emitted `if (` … `)` supplies the delimiters, so a copied pair only draws a `redundant-parens`
	 * finding on the result.
	 */
	private static function collectRungs(
		branches: Array<{ cond: QueryNode, stmt: QueryNode }>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, pairs: Array<{ cond: Span, value: Span }>, values: Array<QueryNode>
	): Bool {
		for (b in branches) {
			final v: Null<QueryNode> = returnValue(b.stmt, s);
			if (v == null) return false;
			values.push(v);
			if (IfExpressionChain.holdsElseLessConditional(v, s.conditionalKinds)) return false;
			final rawCond: Null<Span> = BoolExprShape.unwrapParens(b.cond, s.parenKind).span;
			final rawValue: Null<Span> = v.span;
			if (rawCond == null || rawValue == null) return false;
			pairs.push({
				cond: IfExpressionChain.tokenSpan(rawCond, source, comments),
				value: IfExpressionChain.tokenSpan(rawValue, source, comments)
			});
		}
		return true;
	}

	/**
	 * The same, for the rungs peeled off a terminal ternary spine. Every folded rung but the last is
	 * now a NON-TERMINAL value, so the ` else `-absorption gate applies to it exactly as it does to a
	 * written branch.
	 */
	private static function collectFoldedRungs(
		folded: Array<{ cond: QueryNode, value: QueryNode }>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, pairs: Array<{ cond: Span, value: Span }>, values: Array<QueryNode>
	): Bool {
		for (rung in folded) {
			if (IfExpressionChain.holdsElseLessConditional(rung.value, s.conditionalKinds)) return false;
			values.push(rung.value);
			final rawCond: Null<Span> = rung.cond.span;
			final rawValue: Null<Span> = rung.value.span;
			if (rawCond == null || rawValue == null) return false;
			pairs.push({
				cond: IfExpressionChain.tokenSpan(rawCond, source, comments),
				value: IfExpressionChain.tokenSpan(rawValue, source, comments)
			});
		}
		return true;
	}

	/**
	 * Whether `node` is a rung THIS rule would collect: a no-`else` `if` whose single then-statement
	 * is a VALUED return. The head-of-run test needs the return, not just the shape - a leading
	 * `if (x) g();` is a rung by shape, so skipping the index behind it hid the whole cascade that
	 * followed while `collectRungs` refused the longer run that started at it.
	 */
	private static function isReturnRung(node: QueryNode, s: Seams): Bool {
		final stmt: Null<QueryNode> = IfExpressionChain.cascadeRungStatement(node, s.ifKinds, s.blockStmtKind);
		return stmt != null && returnValue(stmt, s) != null;
	}

}

/** The `RefShape` kinds `PreferIfExpressionReturn` reads. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var returnKind: String;
	var blockStmtKind: String;
	var conditionalKinds: Array<String>;
	var ternaryKind: Null<String>;
	var parenKind: Null<String>;

	/** Read only by `marchable`, which mirrors gates `PreferTernaryReturn` states over the raw shape. */
	var shape: RefShape;
}

/**
 * A matched return chain, carried as SPANS rather than nodes so `buildEdit` and
 * `droppedComment` cannot diverge on what the rebuild keeps: the copied `return ` prefix,
 * each (condition, value) pair, and the terminal value. `prefix` runs from the head
 * `return`'s start to the RAW start of its value (a start offset is exact -- only ENDS carry
 * trivia); every other span is cut back to its last token by `IfExpressionChain.tokenSpan`.
 */
private typedef Match = {
	var prefix: Span;
	var pairs: Array<{ cond: Span, value: Span }>;
	var terminalValue: Span;
	var carried: Carried;
}

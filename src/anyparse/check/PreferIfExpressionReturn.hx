package anyparse.check;

import anyparse.query.BoolExprShape;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.ParenGuard;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.IfExpressionChain;
import anyparse.check.scan.NegationScan;
import anyparse.check.scan.RunScan;

using Lambda;

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
 * OWNERSHIP is split by VALUE COUNT. Two leaf values are a ternary and `prefer-ternary-return`'s;
 * three or more are this rule's in EITHER spelling of the same control flow - the written
 * `if / else if / … / else` chain and the fall-through cascade `redundant-else-after-return`
 * rewrites it into. A terminal ternary spine counts its own leaves, so
 * `if (c) return a; return p ? q : r;` is three.
 *
 * The REWRITE is narrower than the ownership. A value chain of three or more branches reads worse
 * than the statements it replaces (the formatter keeps such a chain exploded,
 * `expressionIfFitMaxBranches: 2`), so one is written only where the author already WROTE at least
 * two conditions as an else-linked chain; the conditions a folded ternary contributes do not count,
 * and a cascade - guard returns plus a final return - is never turned into one. Either spelling is
 * rewritten when its three values MERGE into two (`mergeShape`): `if (m == null) return null;
 * return x ? p : null;` becomes `return m != null && x ? p : null;`, and a longer fall-through run
 * merges its LAST three (`mergeOf`). An owned run that is not rewritten is not reported: its
 * statements are the canon, and owning it is what keeps the pairwise march from building the same
 * chain the long way.
 *
 * The other two rules defer by ASKING this one (`claimsChain` / `claimsCascade`), gates and all,
 * rather than mirroring the shape: a shape-only deferral silences them wherever this rule refuses
 * on a comment, losing findings with no replacement anywhere.
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
 * apart. A merged run is written `return <cond> ? <then> : <else>;` instead (`mergedEdit`).
 * Needs `ifStatementKinds`, `returnStatementKind`, `blockStmtKind` (any unset makes it a no-op).
 */
@:nullSafety(Strict)
final class PreferIfExpressionReturn extends RuleBase {

	/** This check's rule id, written into every finding it raises. */
	private static inline final RULE_ID: String = 'prefer-if-expression-return';

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	/**
	 * The fewest CONDITIONS a claim needs - three leaf values. Two values are a ternary and belong
	 * to `prefer-ternary-return`; the count is taken AFTER the terminal ternary spine is folded in,
	 * so `if (c) return a; return p ? q : r;` reaches it with one written `if`. The same minimum, counted
	 * over WRITTEN conditions only (`Match.writtenRungs`), is what a chain needs to be rewritten as one.
	 */
	private static inline final MIN_CHAIN_RUNGS: Int = 2;

	/**
	 * `IfExpressionChain.collect` / `collectCascade` are asked for a ONE-branch chain and the rung
	 * minimum above is applied after folding, rather than asking them for two branches: the fold
	 * turns a written branch count into a value count, and only the value count decides.
	 */
	private static inline final MIN_COLLECT_BRANCHES: Int = 1;

	/**
	 * A merge turns exactly THREE values into two: a whole run of three, or the LAST three of a longer
	 * fall-through run, whose guards in front keep their statements.
	 */
	private static inline final MERGED_VALUE_COUNT: Int = 3;

	public function new() {
		super(
			RULE_ID,
			'an if/else-if chain returning in every branch, collapsible to a single if-expression return, or a return run '
			+ 'repeating one of its three values, collapsible to a single ternary return',
			RuleCategory.Control
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final blockKinds: Array<String> = blockKindsOf(plugin);
		// BRANCH-AWARE, and the cascade arm is why. A cascade is a SIBLING relation, so it is
		// only visible where the statements share a statement list — and in the plain projection
		// a conditional-compilation region is ONE node whose branches are flattened children, no
		// block at all. `prefer-ternary-return` reads the branch-aware projection and defers to
		// this rule, so a cascade inside a `#if` region would be deferred to a walk that never
		// saw it, and a three-`return` cascade under `#end` would lose its only finding. The
		// else-chain arm is indifferent — it flags a chain head
		// wherever the walk reaches one, and an `if` node's own children are the same in both
		// projections.
		return RunScan.collectWith(files, plugin, readSeams(plugin.refShape()), (entry, tree, seams, violations) -> {
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> =
				SourceComments.collectCommentTokens(plugin.lexicalRegions(entry.source));
			walk(tree, violations, entry.file, entry.source, comments, seams);
			walkCascades(tree, violations, entry.file, entry.source, comments, seams, blockKinds);
		}, CheckScan.parseBranchAwareOrNull);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		// ONE branch-aware parse for both arms, the projection `run` reports from: the cascade arm needs
		// it for its statement lists, and the type probe a merge's negation asks answers only for nodes
		// of the tree it was built over.
		final parsed: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (parsed == null) return [];
		// Re-bound to a non-null local: the narrowing above does not reach into the probe's closure.
		final tree: QueryNode = parsed;
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(IfExpressionChain.spanKey(span));
		}
		final file: String = violations.length == 0 ? '' : violations[0].file;
		var types: Null<(QueryNode) -> Null<String>> = null;
		var asked: Bool = false;
		final emit: Emit = {
			plugin: plugin,
			logic: plugin.booleanLogicSupport(),
			types: () -> {
				if (!asked) {
					asked = true;
					types = CheckScan.typeNominalResolver(source, plugin, tree, file, index);
				}
				return types;
			}
		};
		final edits: Array<{ span: Span, text: String }> = [];
		collectChainFixes(tree, source, comments, seams, flagged, edits, emit, null);
		// The cascade arm's edit spans the head `if` THROUGH a later SIBLING, so it is keyed on the
		// statement list rather than on the head node alone.
		final blockKinds: Array<String> = blockKindsOf(plugin);
		if (blockKinds.length > 0) collectCascadeFixes(tree, source, comments, seams, blockKinds, flagged, edits, emit);
		return CanonicalEdit.dropContainedEdits(edits);
	}

	/**
	 * Whether this check REWRITES the else-linked chain headed by `head` - the EXACT question, every
	 * gate included, not its shape. `redundant-else-after-return` asks it before flagging: its de-nest
	 * takes a chain of valued returns away from a rule whose single fix IS the canon, and the composed
	 * `--fix` then reaches the same text the long way, through the three-rung ternary
	 * `prefer-if-expression-chain` condemns. Asking the shape instead would silence that rule on every
	 * site THIS one refuses on a comment - a finding lost with no replacement. A chain this rule owns
	 * but leaves alone (two written branches and a folded ternary) is not claimed: the de-nest turns it
	 * into the cascade whose statements are the canon.
	 */
	public static function claimsChain(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, shape: RefShape
	): Bool {
		// March-gated where the REPORT is not: this rule flags every valued-return chain and its own
		// edit is deferred by the de-nest's, so gating the report would lose a finding. The CLAIM is
		// what silences the other rule, and it may only silence where this rule reaches the same text
		// the march did - and only where it REWRITES: a chain it leaves alone keeps the de-nest.
		final seams: Null<Seams> = readSeams(shape);
		if (seams == null) return false;
		final m: Null<Match> = match(head, source, comments, seams, true);
		return m != null && rewritesChain(m);
	}

	/**
	 * Whether this check OWNS the fall-through cascade starting at `kids[at]` - the same exact question
	 * for the other spelling. `prefer-ternary-return` asks it before flagging a pair: a pair that is the
	 * TAIL of an owned cascade is one rung of a run this rule decides whole, and collapsing it alone
	 * starts the march into the ternary chain that has to be unrolled again afterwards.
	 *
	 * Owned is not rewritten: the answer is true for a run whose values do not merge, which this rule
	 * leaves as its statements (see the type doc), so the deferral is what keeps those statements.
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
	 * collapse — both rules then report one control flow.
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
	 * Whether a matched chain is REWRITTEN rather than only owned: its values merge into two, or the
	 * author WROTE at least two conditions as an else-linked chain. Branches the fold of a terminal
	 * ternary contributes are not written ones, so they never make a chain on their own.
	 */
	private static inline function rewritesChain(m: Match): Bool {
		return m.merge != null || m.writtenRungs >= MIN_CHAIN_RUNGS;
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
	 * Walk `node`; at each statement list flag every fall-through return cascade whose values merge
	 * (`eachMergedRun`). The finding's span is the `if` the edit starts at: the run head's own span -
	 * the coordinate the else-chain arm reports too, so the two spellings of one control flow report at
	 * the same place - or, for a longer run whose last three values merge, the first rung of that tail.
	 */
	private static function walkCascades(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, blockKinds: Array<String>
	): Void {
		if (blockKinds.contains(node.kind)) eachMergedRun(
			node.children, source, comments, s, (_, merge, span) -> out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: merge.from == 0
					? 'this if/return cascade repeats a value and can be a single ternary return'
					: 'the last three values of this if/return cascade repeat one and can be a single ternary return'
			})
		);
		for (c in node.children) walkCascades(c, out, file, source, comments, s, blockKinds);
	}

	/**
	 * Mirror `walkCascades`: collect one replacement edit per flagged cascade, keyed on the statement
	 * the finding names. The edit's span runs from that statement to the END of the terminal one, which
	 * is why this walk exists at all — `applyBySpan` hands back a node, and the rest of the cascade is
	 * that node's siblings.
	 */
	private static function collectCascadeFixes(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, blockKinds: Array<String>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>, emit: Emit
	): Void {
		if (blockKinds.contains(node.kind)) eachMergedRun(node.children, source, comments, s, (m, merge, reported) -> {
			if (flagged.contains(IfExpressionChain.spanKey(reported))) edits.push(mergedEdit(m, merge, source, s, emit));
		});
		for (c in node.children) collectCascadeFixes(c, source, comments, s, blockKinds, flagged, edits, emit);
	}

	/**
	 * Call `found` for every fall-through run of `kids` whose values merge, with its match, the merge and
	 * the statement the finding names - the one the merged edit starts at. Only a run HEAD is asked, the
	 * index whose predecessor is not itself a rung: the collector is greedy, so every later index of one
	 * run would collect a shorter cascade of the same code. A run that is owned but does not merge is
	 * not passed on: its statements are the canon.
	 */
	private static function eachMergedRun(
		kids: Array<QueryNode>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		found: (Match, Merge, Span) -> Void
	): Void {
		for (i in 0...kids.length) {
			if (i > 0 && isReturnRung(kids[i - 1], s)) continue; // not a run HEAD
			final m: Null<Match> = cascadeMatch(kids, i, source, comments, s);
			final merge: Null<Merge> = m?.merge;
			if (m == null || merge == null) continue;
			final reported: Null<Span> = kids[i + merge.from].span;
			if (reported != null) found(m, merge, reported);
		}
	}

	/**
	 * Mirror `walk`: collect one replacement edit per flagged chain head, over the same branch-aware
	 * tree, so the node a merge negates is one the type probe was built for.
	 */
	private static function collectChainFixes(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, flagged: Array<String>,
		edits: Array<{ span: Span, text: String }>, emit: Emit, parent: Null<QueryNode>
	): Void {
		final span: Null<Span> = node.span;
		if (
			span != null && s.ifKinds.contains(node.kind) && !IfExpressionChain.isElseIfLink(node, parent, s.ifKinds)
			&& flagged.contains(IfExpressionChain.spanKey(span))
		) {
			final m: Null<Match> = match(node, source, comments, s, false);
			if (m != null && rewritesChain(m)) edits.push(buildEdit(m, source, span, s, emit));
		}
		for (c in node.children) collectChainFixes(c, source, comments, s, flagged, edits, emit, node);
	}

	/** Bundle the required `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final boolLitKind: Null<String> = shape.boolLitKind;
		return blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind,
			conditionalKinds: ShapeVocab.ifKinds(shape),
			ternaryKind: shape.ternaryKind,
			parenKind: shape.parenKind,
			shape: shape,
			negation: NegationScan.negationSeams(shape),
			mergeValueKinds: (shape.caseLiteralKinds ?? []).filter(k -> k != boolLitKind).concat([shape.identKind])
		};
	}

	/** Walk `node`, flagging each chain HEAD whose branches all return a value. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (s.ifKinds.contains(node.kind) && !IfExpressionChain.isElseIfLink(node, parent, s.ifKinds)) {
			final m: Null<Match> = match(node, source, comments, s, false);
			final span: Null<Span> = node.span;
			if (m != null && rewritesChain(m) && span != null) out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: m.merge == null
					? 'this if/else-if return chain can be a single if-expression return'
					: 'this if/else-if return chain repeats a value and can be a single ternary return'
			});
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
		return chain == null || headSpan == null ? null : matchChain(chain, [], headSpan, source, comments, s, marchOnly);
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
		// ALWAYS march-gated: anything this arm claims beyond what `prefer-ternary-return` already
		// marched is a CHANGED fixed point.
		return from == null || to == null
			? null
			: matchChain(chain, kids.slice(at, at + chain.branches.length), new Span(from.from, to.to), source, comments, s, true);
	}

	/**
	 * If `chain` is a chain of single valued-`return` branches, no branch value would absorb the
	 * emitted ` else `, and no comment sits in a dropped region of `region` — the span the rebuild
	 * replaces — return the match parts; else null. Every copied piece is cut back to its last token
	 * here, so `buildEdit` and the comment classification see the same spans.
	 */
	private static function matchChain(
		chain: IfChain, rungs: Array<QueryNode>, region: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, marchOnly: Bool
	): Null<Match> {
		final headReturnSpan: Null<Span> = chain.branches[0].stmt.span;
		if (headReturnSpan == null) return null;
		final values: Array<QueryNode> = [];
		final conds: Array<QueryNode> = [];
		final pairs: Array<{ cond: Span, value: Span }> = [];
		if (!collectRungs(chain.branches, source, comments, s, pairs, conds, values)) return null;
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
		if (!collectFoldedRungs(tail.pairs, source, comments, s, pairs, conds, values)) return null;
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
		for (i => pair in pairs) {
			kept.push(pair.cond);
			kept.push(pair.value);
			seats.push({
				condEnd: pair.cond.to,
				value: pair.value,
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
			carried: slots,
			conds: conds,
			writtenRungs: chain.branches.length,
			merge: mergeOf(values, chain, rungs, pairs, region, source, comments, s)
		};
	}

	/**
	 * Whether `prefer-ternary-return`'s own pairwise march would carry every one of these values to
	 * the same text this rule writes in one step. The two rules now hand one control flow back and
	 * forth — that rule defers a pair inside a claimed cascade, this one claims the cascade — so the
	 * claim must not reach further than the march did, or the CHANGE of fixed point is the change,
	 * and a guard cascade nobody asked to fold becomes one expression.
	 *
	 * Without this a full `--fix` turns `return false;` guards into rungs. Every refusal below
	 * mirrors a gate `PreferTernaryReturn.pairAt` already applies to the pair it would collapse,
	 * read here over the whole rung list because the march applies it once per step:
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
	private static function buildEdit(m: Match, source: String, span: Span, s: Seams, emit: Emit): { span: Span, text: String } {
		final merge: Null<Merge> = m.merge;
		if (merge != null) return mergedEdit(m, merge, source, s, emit);
		final built: Array<{ cond: String, value: String }> = [
			for (p in m.pairs) { cond: text(source, p.cond), value: IfExpressionChain.spanText(source, p.value, m.carried) }
		];
		return { span: span, text: IfExpressionChain.buildText(text(source, m.prefix), built, text(source, m.terminalValue)) };
	}

	/**
	 * Build the merged `return <cond> ? <then> : <else>;` edit replacing `merge.span`, from the two
	 * rungs at `merge.from` and the terminal. `Leading` joins the
	 * two conditions with `||` and returns the repeated value first; `Outer` negates the first
	 * condition (`NegationScan`'s engine, the one the `guard-*` family inverts with, so `m == null`
	 * flips to `m != null`) and joins it with `&&`. Every piece is a `ParenGuard` hole: a condition
	 * that sat in an `if (…)` or `?:` slot may bind looser than the operator it now meets, and gains a
	 * pair exactly there.
	 */
	private static function mergedEdit(m: Match, merge: Merge, source: String, s: Seams, emit: Emit): { span: Span, text: String } {
		final rung: Int = merge.from;
		final first: String = switch merge.shape {
			case Leading: text(source, m.pairs[rung].cond);
			case Outer: NegationScan.negateConditionText(m.conds[rung], source, s.negation, emit.logic, emit.types());
		};
		final pieces: Array<String> = [
			first,
			merge.shape == Leading ? ' || ' : ' && ',
			text(source, m.pairs[rung + 1].cond),
			' ? ',
			text(source, merge.shape == Leading ? m.pairs[rung].value : m.pairs[rung + 1].value),
			' : ',
			text(source, m.terminalValue)
		];
		final span: Span = merge.span;
		final head: String = text(source, merge.prefix);
		final holes: Array<Span> = [];
		var at: Int = head.length;
		for (i => piece in pieces) {
			if (i % 2 == 0) holes.push(new Span(at, at + piece.length));
			at += piece.length;
		}
		final guarded: Array<{ span: Span, text: String }> = ParenGuard.guard(
			source,
			[{ span: span, text: '$head${pieces.join('')};', holes: holes }],
			emit.plugin
		);
		return { span: span, text: guarded[0].text };
	}

	/**
	 * Which three values of a matched run merge into two, and how, or null when none do. A run of
	 * exactly three merges whole. A LONGER run merges its LAST three only: the guards in front stay the
	 * statements they are, and the merged return replaces the tail from the `if` that returns the first
	 * of the three. The last three because the merged text ENDS at the terminal - two rungs and the
	 * terminal are the pieces `mergedEdit` copies, so any other window would drop a condition.
	 *
	 * A tail must start at a WRITTEN rung of the fall-through spelling, `rungs` being that spelling's
	 * rung statements. An else-linked chain passes none: it is one statement, there is no tail to cut out
	 * of it, and its own chain fix stands. A tail whose first value is FOLDED sits inside the terminal
	 * ternary, and re-shaping a ternary is not a cascade merge. A tail whose preceding value repeats
	 * one of its own is refused too (`repeatsTail`), so a run merges at most once.
	 */
	private static function mergeOf(
		values: Array<QueryNode>, chain: IfChain, rungs: Array<QueryNode>, pairs: Array<{ cond: Span, value: Span }>, region: Span,
		source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Merge> {
		final from: Int = values.length - MERGED_VALUE_COUNT;
		if (from < 0 || from > 0 && from >= rungs.length) return null;
		final start: Null<Span> = from == 0 ? region : rungs[from].span;
		final returned: Null<Span> = chain.branches[from].stmt.span;
		if (start == null || returned == null) return null;
		final span: Span = new Span(start.from, region.to);
		final tail: Array<QueryNode> = values.slice(from);
		final shape: Null<MergeShape> = mergeShape(tail, span, source, comments, s);
		return shape == null || from > 0 && repeatsTail(values[from - 1], tail, source, comments) ? null : {
			shape: shape,
			from: from,
			span: span,
			prefix: new Span(returned.from, pairs[from].value.from)
		};
	}

	/**
	 * Whether `before` - the value returned just ahead of a tail - repeats one of the tail's values. The
	 * merged return would then leave a run whose last three are `before` and the two merged leaves, which
	 * the next pass merges AGAIN: a guard ladder (`if (a) return null; if (b) return null; if (c) return
	 * null; return x;`) would end as one nested `a || (b || c) ? null : x`. A ladder reads as the ladder
	 * it is, so its tail is not merged, and no run is merged twice.
	 */
	private static function repeatsTail(
		before: QueryNode, tail: Array<QueryNode>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		final repeated: Null<String> = valueText(before, source, comments);
		return repeated != null && tail.exists(v -> valueText(v, source, comments) == repeated);
	}

	/**
	 * How three values ending a matched return run merge into TWO, or null when they do not; `region`
	 * is the span their statements cover, which the merged return replaces.
	 *
	 * Only the two merges that keep every evaluation exactly as the statements had it are taken, so
	 * neither needs the conditions to be pure: `Leading` (`v1 == v2`) evaluates `c2` only when `c1`
	 * is false, as the second guard did, and `Outer` (`v1 == v3`, `!c1 && c2`) the same. A repeated
	 * MIDDLE value (`v2 == v3`) would drop `c2`'s evaluation and is refused — it needs a purity proof
	 * nothing here owns, and the source shape (a guard that changes no outcome) is rare.
	 *
	 * The repeated value must be on the positive list `mergeValueKinds` — a non-boolean literal or a
	 * name. Equal TEXT is one value because the statements are siblings, so nothing rebinds a name
	 * between them; what equal text does NOT promise is one TYPE, since a branch's value is typed under
	 * the narrowing its own condition gave it and the merged one is not. A literal or a bare name does
	 * not depend on that narrowing; a field read or a call can (`m.x` under `m != null`), so it stays
	 * off the list. A boolean literal stays off too: a cascade of them is the march's, and
	 * `simplify-boolean-*` reduces it further than a merge does.
	 *
	 * Fail-closed on ANY comment in the replaced region: the rebuild drops one value and reorders the
	 * rest, so no slot keeps a comment's position. A comment in front of a merged tail is outside it and
	 * stays where it is.
	 */
	private static function mergeShape(
		values: Array<QueryNode>, region: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<MergeShape> {
		if (comments.exists(tok -> tok.to > region.from && tok.from < region.to)) return null;
		if (!marchable(values, s) || !s.mergeValueKinds.contains(values[0].kind)) return null;
		final repeated: Null<String> = valueText(values[0], source, comments);
		if (repeated == null) return null;
		if (valueText(values[1], source, comments) == repeated) return Leading;
		return valueText(values[2], source, comments) == repeated ? Outer : null;
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
		s: Seams, pairs: Array<{ cond: Span, value: Span }>, conds: Array<QueryNode>, values: Array<QueryNode>
	): Bool {
		for (b in branches) {
			final v: Null<QueryNode> = returnValue(b.stmt, s);
			if (v == null) return false;
			values.push(v);
			if (IfExpressionChain.holdsElseLessConditional(v, s.conditionalKinds)) return false;
			final cond: QueryNode = BoolExprShape.unwrapParens(b.cond, s.parenKind);
			conds.push(cond);
			final rawCond: Null<Span> = cond.span;
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
		s: Seams, pairs: Array<{ cond: Span, value: Span }>, conds: Array<QueryNode>, values: Array<QueryNode>
	): Bool {
		for (rung in folded) {
			if (IfExpressionChain.holdsElseLessConditional(rung.value, s.conditionalKinds)) return false;
			values.push(rung.value);
			conds.push(rung.cond);
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

	/** The text of `value` cut back to its last token, or null when it carries no span. */
	private static function valueText(
		value: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Null<String> {
		final span: Null<Span> = value.span;
		return span == null ? null : text(source, IfExpressionChain.tokenSpan(span, source, comments));
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

	/** The kinds `NegationScan` negates a merged `Outer` run's first condition with. */
	var negation: NegationSeams;

	/** The positive list of value kinds a merge may repeat: every non-boolean case literal, plus a bare name. */
	var mergeValueKinds: Array<String>;
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

	/** Each rung's condition NODE, paren-unwrapped, parallel to `pairs` — what a merge negates. */
	var conds: Array<QueryNode>;

	/** How many conditions the author WROTE as an else-linked chain; the folded ternary's are not counted. */
	var writtenRungs: Int;

	/** Which three values merge into two and how, or null when none do. */
	var merge: Null<Merge>;
}

/**
 * How a three-value return run merges into a two-value ternary: `Leading` when the first two
 * values repeat (`c1 || c2 ? v1 : v3`), `Outer` when the first and the last do (`!c1 && c2 ? v2 : v1`).
 */
private enum MergeShape {
	Leading;
	Outer;
}

/**
 * A merge of a matched run: its `shape`, the index `from` of the first of the three merged values
 * (0 for a run of exactly three, else the start of the run's tail), the `span` the merged return
 * replaces - from the statement holding that value to the end of the terminal - and the `return `
 * prefix copied from that statement's own `return`.
 */
private typedef Merge = {
	var shape: MergeShape;
	var from: Int;
	var span: Span;
	var prefix: Span;
}

/**
 * What a merged edit needs beyond the match: the plugin `ParenGuard` re-parses with, the grammar's
 * negation engine, and the lazily-built operand-type probe that licenses flipping an ordered comparison.
 */
private typedef Emit = {
	var plugin: GrammarPlugin;
	var logic: Null<BooleanLogicSupport>;
	var types: () -> Null<(QueryNode) -> Null<String>>;
}

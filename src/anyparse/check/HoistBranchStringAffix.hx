package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.CondBranchProjection;
import anyparse.query.CondDirectives;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a statement-position conditional-compilation region whose EVERY branch is one
 * `return <string>;` and whose branch strings begin and/or end with the same text, and writes that
 * shared text ONCE around the region moved into expression position:
 *
 * ```haxe
 * #if flash
 * return 'SystemData${endl()}{${endl()}  OS: $osName${endl()}}';
 * #elseif mobile
 * return 'SystemData${endl()}{${endl()}  RAM: $totalMemory${endl()}}';
 * #else
 * return 'SystemData${endl()}{${endl()}  GPU: $gpuName${endl()}}';
 * #end
 * // ->
 * return 'SystemData${endl()}{${endl()}'
 *     + #if flash '  OS: $osName' #elseif mobile '  RAM: $totalMemory' #else '  GPU: $gpuName' #end
 *     + '${endl()}}';
 * ```
 *
 * The frame is written once instead of N times, and a later edit to it can no longer be applied to
 * two branches and forgotten in the third. `Info` -- the code is correct, this is a readability
 * simplification -- and `DefaultOff`: moving a `#if` into expression position is a house-style
 * choice, and a project that keeps its conditionals at statement level should not be nagged.
 *
 * ## Why the conditional-compilation position, and only it
 *
 * This is the one statement shape the statement-list rules deliberately cannot reach. A
 * `Conditional` node is excluded from `ControlFlowSupport.blockKinds()` (else `dead-code` would
 * call branches 2..N unreachable after branch 1's `return`), so `tail-merge`, `join-return` and
 * `duplicate-code` never see a run of branch statements as a list. `string-literal-dup` sees the
 * repetition but prescribes a different cure (a named constant, which cannot hold interpolation),
 * and `fold-adjacent-string-literals` only squeezes segments that are already ADJACENT inside one
 * branch.
 *
 * An `if` / `else` chain of `return`s is NOT claimed, and that is a boundary rather than an
 * omission: `prefer-ternary-return` / `prefer-if-expression-return` already collapse it to a
 * single `return` with a value-position conditional, after which an affix hoist would have to
 * claim the same span as `prefer-ternary-expression` and hand off to it.
 *
 * ONE other check does claim this span: `cond-assign-merge` sees the same region as "every branch
 * exits with the same keyword" and merges it into one `return` with a conditional value -- this
 * rule's output MINUS the hoist. Both edits cannot land, and `Cli.computeFileLintEdits` keeps
 * whichever check comes first in `Linter.builtins()`, so this one is registered AHEAD of it. That
 * ordering is load-bearing: with `cond-assign-merge` first the region becomes a value-position
 * `ConditionalExpr`, which this rule (statement position only) no longer claims, and the shared
 * edges would stay written N times with nothing left to reclaim them. It costs nothing in the
 * default configuration, where this rule is off and `cond-assign-merge` owns the site alone.
 *
 * ## The emitted region is a first-class node, not a raw splice
 *
 * A `#if` in EXPRESSION position is only swallowed as an opaque `CondSpliceExpr` when its branches
 * do not each form ONE balanced expression -- the shape the sibling `SystemData.toString` has,
 * where the region straddles the `+` operators. What this rule emits gives every branch exactly one
 * expression, which parses as a `ConditionalExpr` whose branch values are fully modelled. So the
 * rewrite does not trade a parsed region for an opaque one; it produces the BETTER of the two
 * conditional-expression shapes.
 *
 * ## What is flagged
 *
 * A region (`RefShape.conditionalMemberKind`) whose parent is a statement list, and whose:
 *
 * - branch runs recover from the directive text (`CondBranchProjection.conditionalBranchRuns`) as
 *   at least two runs, one per opener directive;
 * - LAST opener is the condition-less `#else`. Without it some build compiles no branch at all and
 *   the enclosing `return` would be left with no value -- a compile error, not a rewrite;
 * - every branch run is EXACTLY ONE `return` carrying a value. That is also the whole
 *   name-resolution proof, see below;
 * - branch value's FIRST and LAST concatenation operand is a string literal carrying segment
 *   children (`'…'`) that tile its interior. A double-quoted literal projects no children, so it
 *   has no modelled cut point and is refused;
 * - shared leading and/or trailing text SNAPS to a safe cut (see below) and PAYS for itself.
 *
 * ## The name-resolution gate -- what makes a `#if` hoist different from an `if` / `else` one
 *
 * Text hoisted out of the branches is written BEFORE the region rather than inside it, so every
 * name it reads must resolve to the same declaration it resolved to in each branch. Under an
 * ordinary `if` that is trivial. Under conditional compilation it is not, and the reason is not
 * the branch conditions: exactly one branch survives the preprocessor per build, and the hoisted
 * text was present in that build already, so the SET of names each build evaluates is unchanged.
 * What can change is a POSITIONAL binding -- a declaration written inside the region, before the
 * `return`, that the hoisted text would now be lifted above:
 *
 * ```haxe
 * #if a
 * final endl = () -> '\r';   // shadows the member
 * return 'H${endl()}x';
 * #else
 * return 'H${endl()}y';      // the member
 * #end
 * ```
 *
 * Hoisting `'H${endl()}'` here silently rebinds it to the member in the `a` build. The
 * one-statement gate is what forecloses it: a branch that is exactly one `return` declares
 * nothing, so the region contributes no binding for the hoisted text to escape. A branch holding
 * anything else is refused rather than analysed -- the fail-closed answer, and the reason the gate
 * is a hard shape requirement rather than a scan.
 *
 * Two shapes that LOOK like the same hazard and are not, recorded so a future widening does not
 * re-litigate them: a member declared under its own `#if` (`#if flash function endl() … #end`) is
 * per-build unique either way, and a name only some builds declare is already referenced by EVERY
 * branch -- so a build missing it was broken before the hoist.
 *
 * ## Where a cut may fall
 *
 * The shared text is the longest common run of raw source characters across the branches, snapped
 * back to a cut the string model can express. A SEGMENT BOUNDARY always qualifies. A position
 * INSIDE a segment qualifies only in the segment nearest the edge -- the case where no whole
 * segment is shared at all -- and only when that segment's raw text holds neither a backslash nor
 * the interpolation sigil. That is what lets `'connection-alpha'` / `'connection-beta'` share
 * `connection-` although each is ONE literal segment, while refusing to cut inside `\n` or
 * `${f()}`, where a character-level split would corrupt the escape or the hole.
 *
 * Restricting the character-level cut to the first segment is a readability choice with a reason:
 * it exists to reach literals the segment model cannot split at all, not to extend a cut that
 * already landed on a boundary. Without the restriction the motivating site shares the two leading
 * spaces of `'   OS: '` / `'  OS : '` as well, and the emitted branches start mid-indentation for
 * two characters nobody would have written that way.
 *
 * A single-operand branch always keeps a character of its own, and a branch whose remainder text
 * comes out identical to every other branch's is refused: nothing varies, which is
 * `cond-region-merge` / `duplicate-code` territory rather than a hoist. Where a branch has SEVERAL
 * operands an outer one may be eaten whole -- the remainder then starts at the next operand and
 * the `+` that joined them goes with it.
 *
 * ## Paying for itself
 *
 * Hoisting an affix removes it from N branches and re-writes it once as its own operand, which
 * costs two quotes and a ` + `. A side is hoisted only when `(branches - 1) * length` exceeds that
 * cost, so a two-branch region sharing five characters is left alone while a three-branch one
 * sharing three is not. The two sides are decided independently -- the common case is a shared head
 * worth hoisting and a tail that is not.
 *
 * ## Comments
 *
 * Fail-closed. What the rebuild copies verbatim is each branch's remainder span and each of the
 * region's own directives; a comment anywhere else inside the region (between `return` and its
 * string, say) would be dropped, and leaves the region unflagged.
 *
 * Needs `conditionalMemberKind`, the directive keywords, `returnStatementKind`,
 * `stringLiteralKinds`, a `ControlFlowSupport` and a `StringFoldSupport` (for the concatenation
 * operator); any unset makes the check a no-op.
 */
@:nullSafety(Strict)
final class HoistBranchStringAffix implements Check implements DefaultOff {

	/** The rule id, also the `rule` field of every violation it reports. */
	private static inline final RULE_ID: String = 'hoist-branch-string-affix';

	/** What re-writing a hoisted affix as its own operand costs in characters: two quotes plus a ` + `. */
	private static inline final AFFIX_SYNTAX_COST: Int = 5;

	/** A region with one branch has nothing to share text WITH. */
	private static inline final MIN_BRANCHES: Int = 2;

	/** The one message, true whether the shared text sits at one edge or at both. */
	private static inline final MESSAGE: String = 'every branch of this conditional-compilation region returns a string with the same '
		+ 'edges - write the shared text once outside the region';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a conditional-compilation region whose every branch returns a string with the same edges, the shared text hoistable out '
			+ 'of the region';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(tree, null, violations, entry.file, contextOf(entry.source, resolved));
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final ctx: Ctx = contextOf(source, seams);
		return RefactorSupport.dropContainedEdits(CheckScan.applyBySpan(plugin, source, violations, [seams.condKind], (node, span) -> {
			final m: Null<Match> = match(node, ctx);
			return m == null ? null : { span: m.region, text: buildText(m) };
		}));
	}

	/** The `k`-th character of `lit`'s interior, counted from the leading or from the trailing edge. */
	private static inline function charAtEdge(source: String, lit: Literal, k: Int, leading: Bool): String {
		return source.charAt(leading ? lit.from + k : lit.to - 1 - k);
	}

	/** `shared` when hoisting it beats the two quotes and the ` + ` it costs, else nothing at all. */
	private static inline function worthIt(branches: Array<Branch>, shared: Int): Int {
		return (branches.length - 1) * shared <= AFFIX_SYNTAX_COST ? 0 : shared;
	}

	/**
	 * How many characters of its first (or last) operand a branch may give up. A branch with SEVERAL
	 * operands may give up the whole one -- the remainder then starts at the next operand. A
	 * single-operand branch must keep a character of its own, and its tail is additionally capped by
	 * the head cut already taken out of the same interior.
	 */
	private static inline function budgetOf(b: Branch, leading: Bool, head: Int): Int {
		final lit: Literal = leading ? b.head : b.tail;
		return b.count == 1 ? lit.to - lit.from - 1 - head : lit.to - lit.from;
	}

	/** Whether `raw` is text a cut may fall inside -- no escape introducer, no interpolation sigil. */
	private static inline function plainText(raw: String): Bool {
		return raw.indexOf('\\') == -1 && raw.indexOf('$') == -1;
	}

	/** Bundle the required seams, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final condKind: Null<String> = shape.conditionalMemberKind;
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		final elseKeywords: Null<Array<String>> = shape.conditionalElseKeywords;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (condKind == null || ifKeyword == null || endKeyword == null || elseKeywords == null || returnKind == null) return null;
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final fold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (stringKinds.length == 0 || flow == null || fold == null) return null;
		final blockKinds: Array<String> = flow.blockKinds();
		final concatKind: String = fold.concatKind();
		return {
			shape: shape,
			condKind: condKind,
			ifKeyword: ifKeyword,
			endKeyword: endKeyword,
			elseKeywords: elseKeywords,
			returnKind: returnKind,
			stringKinds: stringKinds,
			blockKinds: blockKinds,
			concatKind: concatKind
		};
	}

	/** The per-file scan state: the source, its comment tokens, its conditional directives and the seams. */
	private static function contextOf(source: String, seams: Seams): Ctx {
		return {
			source: source,
			comments: RefactorSupport.collectCommentTokens(source),
			directives: CondDirectives.scan(source, seams.shape),
			seams: seams
		};
	}

	/** Walk `node`, flagging every statement-position conditional region whose branches share string edges. */
	private static function walk(node: QueryNode, parent: Null<QueryNode>, out: Array<Violation>, file: String, ctx: Ctx): Void {
		final span: Null<Span> = node.span;
		if (
			span != null && node.kind == ctx.seams.condKind && parent != null && ctx.seams.blockKinds.contains(parent.kind)
			&& match(node, ctx) != null
		) out.push({
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: MESSAGE
		});
		for (c in node.children) walk(c, node, out, file, ctx);
	}

	/** The hoist `region` admits, or null when any gate refuses it. */
	private static function match(region: QueryNode, ctx: Ctx): Null<Match> {
		final span: Null<Span> = region.span;
		if (span == null) return null;
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			region, ctx.source, ctx.seams.elseKeywords, ctx.comments
		);
		if (runs == null || runs.length < MIN_BRANCHES) return null;
		final directives: Null<Array<CondDirective>> = ownDirectives(span, ctx);
		// One opener per branch run, and the last opener must be the condition-less `#else`: a region
		// some build compiles nothing of cannot become a value.
		if (directives == null || directives.length != runs.length + 1 || directives[directives.length - 2].condition != null) return null;
		final branches: Null<Array<Branch>> = branchesOf(runs, ctx);
		return branches == null ? null : affixesOf(branches, span, directives, ctx);
	}

	/**
	 * The region's OWN directives in source order (the opener, each `#elseif` / `#else`, the closer),
	 * or null when the nesting does not close cleanly or the region has too few branches. A directive
	 * of a NESTED region is skipped by depth, so this reads the region's own branch structure only.
	 */
	private static function ownDirectives(region: Span, ctx: Ctx): Null<Array<CondDirective>> {
		final out: Array<CondDirective> = [];
		var depth: Int = 0;
		for (d in ctx.directives) {
			if (d.span.from < region.from || d.span.to > region.to) continue;
			if (d.keyword == ctx.seams.ifKeyword) {
				if (depth == 0) out.push(d);
				depth++;
			} else if (d.keyword == ctx.seams.endKeyword) {
				depth--;
				if (depth < 0) return null;
				if (depth == 0) out.push(d);
			} else if (depth == 1 && ctx.seams.elseKeywords.contains(d.keyword))
				out.push(d);
		}
		return depth != 0 || out.length < MIN_BRANCHES + 1 ? null : out;
	}

	/**
	 * Each branch decomposed into its `return` value's concatenation operands plus the first and last
	 * operand read as a cuttable literal, or null when a branch is not exactly one `return` of a
	 * concatenation whose outer operands are segment-bearing string literals.
	 */
	private static function branchesOf(runs: Array<CondBranchRun>, ctx: Ctx): Null<Array<Branch>> {
		final out: Array<Branch> = [];
		for (run in runs) {
			if (run.nodes.length != 1) return null;
			final stmt: QueryNode = run.nodes[0];
			if (stmt.kind != ctx.seams.returnKind || stmt.children.length != 1) return null;
			final operands: Array<QueryNode> = flattenConcat(stmt.children[0], ctx.seams.concatKind);
			final head: Null<Literal> = literalOf(operands[0], ctx);
			final tail: Null<Literal> = literalOf(operands[operands.length - 1], ctx);
			if (head == null || tail == null) return null;
			// Re-bound to non-null locals: strict null-safety narrowing does not reach into an
			// anonymous struct literal.
			final open: Literal = head;
			final close: Literal = tail;
			final second: Null<Span> = operands.length > 1 ? operands[1].span : null;
			final penultimate: Null<Span> = operands.length > 1 ? operands[operands.length - 2].span : null;
			if (operands.length > 1 && (second == null || penultimate == null)) return null;
			out.push({
				count: operands.length,
				secondFrom: second == null ? 0 : second.from,
				penultimateTo: penultimate == null ? 0 : penultimate.to,
				head: open,
				tail: close
			});
		}
		return out;
	}

	/** The operands of the maximal left-associative concatenation rooted at `node`, in source order. */
	private static function flattenConcat(node: QueryNode, concatKind: String): Array<QueryNode> {
		if (node.kind != concatKind || node.children.length != 2) return [node];
		final left: Array<QueryNode> = flattenConcat(node.children[0], concatKind);
		left.push(node.children[1]);
		return left;
	}

	/**
	 * `node` as a cuttable string literal -- its own bounds, the interior its segment children tile,
	 * those segments and its quote character -- or null when it is not a string literal, carries no
	 * segment children, or its children do not tile a proper interior contiguously.
	 */
	private static function literalOf(node: QueryNode, ctx: Ctx): Null<Literal> {
		final span: Null<Span> = node.span;
		if (span == null || !ctx.seams.stringKinds.contains(node.kind) || node.children.length == 0) return null;
		final segments: Array<Span> = [];
		for (c in node.children) {
			final s: Null<Span> = c.span;
			if (s == null || s.to <= s.from) return null;
			if (segments.length > 0 && segments[segments.length - 1].to != s.from) return null;
			segments.push(s);
		}
		final from: Int = segments[0].from;
		final to: Int = segments[segments.length - 1].to;
		// The quote characters must sit OUTSIDE the tiled interior, or this is not the shape assumed.
		return from <= span.from || to >= span.to ? null : {
			open: span.from,
			close: span.to,
			from: from,
			to: to,
			quote: ctx.source.charAt(span.from),
			segments: segments
		};
	}

	/**
	 * The head and tail cuts every branch agrees on, or null when neither side survives its gates.
	 * The head is decided first and caps the tail, so the two cuts of a single-operand branch can
	 * never meet.
	 */
	private static function affixesOf(branches: Array<Branch>, region: Span, directives: Array<CondDirective>, ctx: Ctx): Null<Match> {
		final quote: String = branches[0].head.quote;
		for (b in branches) if (b.head.quote != quote || b.tail.quote != quote) return null;
		final head: Int = worthIt(branches, sharedRun(branches, ctx, true, [for (b in branches) budgetOf(b, true, 0)]));
		final tail: Int = worthIt(branches, sharedRun(branches, ctx, false, [for (b in branches) budgetOf(b, false, head)]));
		if (head == 0 && tail == 0) return null;
		final kept: Array<Span> = [for (d in directives) d.span];
		final texts: Null<Array<String>> = remaindersOf(branches, head, tail, kept, ctx);
		if (texts == null || IfExpressionChain.droppedComment(region, kept, ctx.comments)) return null;
		final first: Literal = branches[0].head;
		final last: Literal = branches[0].tail;
		return {
			region: new Span(directives[0].span.from, directives[directives.length - 1].span.to),
			head: head == 0 ? '' : quote + ctx.source.substring(first.from, first.from + head) + quote,
			tail: tail == 0 ? '' : quote + ctx.source.substring(last.to - tail, last.to) + quote,
			directives: [for (d in directives) CondDirectives.text(ctx.source, d)],
			branches: texts
		};
	}


	/**
	 * Each branch's surviving text, and the spans of it that the rebuild copies verbatim appended to
	 * `kept`. Null when a branch would be left with no value at all, or when every branch's remainder
	 * comes out the same -- nothing varies, which is a merge rather than a hoist.
	 */
	private static function remaindersOf(branches: Array<Branch>, head: Int, tail: Int, kept: Array<Span>, ctx: Ctx): Null<Array<String>> {
		final texts: Array<String> = [];
		for (b in branches) {
			final start: Int = b.head.from + head;
			final end: Int = b.tail.to - tail;
			if (b.count <= 2 && start == b.head.to && end == b.tail.from) return null;
			kept.push(new Span(start, end));
			texts.push(remainderText(b, start, end, ctx));
		}
		for (t in texts) if (t != texts[0]) return texts;
		return null;
	}

	/**
	 * The number of raw source characters every branch shares at one edge, snapped to a cut EVERY
	 * branch's literal can express. `budgets` caps each branch's own contribution; a snap that lands
	 * differently in two branches refuses the whole side rather than guessing.
	 */
	private static function sharedRun(branches: Array<Branch>, ctx: Ctx, leading: Bool, budgets: Array<Int>): Int {
		var shared: Int = budgets[0];
		for (b in budgets) if (b < shared) shared = b;
		if (shared <= 0) return 0;
		final first: Literal = leading ? branches[0].head : branches[0].tail;
		for (i in 1...branches.length) {
			final other: Literal = leading ? branches[i].head : branches[i].tail;
			var k: Int = 0;
			while (k < shared && charAtEdge(ctx.source, first, k, leading) == charAtEdge(ctx.source, other, k, leading)) k++;
			shared = k;
		}
		var snapped: Int = shared;
		for (b in branches) {
			final at: Int = snapCut(leading ? b.head : b.tail, snapped, leading, ctx);
			if (at < snapped) snapped = at;
		}
		if (snapped <= 0) return 0;
		// A second pass can only shrink further, and a side that does not settle in one is refused.
		for (b in branches) if (snapCut(leading ? b.head : b.tail, snapped, leading, ctx) != snapped) return 0;
		return snapped;
	}

	/**
	 * The largest cut no greater than `want`, counted from the given edge, that the literal can
	 * express: a segment boundary, or a position inside a segment whose raw text holds neither an
	 * escape introducer nor the interpolation sigil.
	 */
	private static function snapCut(lit: Literal, want: Int, leading: Bool, ctx: Ctx): Int {
		final count: Int = lit.segments.length;
		var offset: Int = 0;
		for (i in 0...count) {
			final s: Span = lit.segments[leading ? i : count - 1 - i];
			final length: Int = s.to - s.from;
			if (offset + length > want) return i == 0 && plainText(ctx.source.substring(s.from, s.to)) ? want : offset;
			offset += length;
			if (offset == want) return want;
		}
		return offset;
	}

	/**
	 * One branch's surviving text: its first operand from the head cut, its own operators and inner
	 * operands verbatim, and its last operand up to the tail cut. A single-operand branch is the same
	 * slice with no middle.
	 */
	private static function remainderText(b: Branch, start: Int, end: Int, ctx: Ctx): String {
		final q: String = b.head.quote;
		if (b.count == 1) return q + ctx.source.substring(start, end) + q;
		final openEaten: Bool = start == b.head.to;
		final closeEaten: Bool = end == b.tail.from;
		// The middle slice starts and ends at the seam an eaten operand leaves behind, so the `+` that
		// joined it is dropped with it.
		final middle: String = ctx.source.substring(openEaten ? b.secondFrom : b.head.close, closeEaten ? b.penultimateTo : b.tail.open);
		return (openEaten ? '' : q + ctx.source.substring(start, b.head.to) + q) + middle
			+ (closeEaten ? '' : q + ctx.source.substring(b.tail.from, end) + q);
	}

	/**
	 * The single `return` the region collapses to, with the region itself spliced into the value slot.
	 *
	 * The newline before every branch value and every following directive is LOAD-BEARING, not
	 * cosmetic: the writer lays a conditional EXPRESSION out from its source seams, and given the
	 * whole region on one line it picks the directive ladder but leaves an over-wide branch value
	 * flat, which a SECOND round-trip then breaks. `lint --fix` canonicalizes once per pass, so the
	 * one-line form ships a file `fmt --list` still reports as drifted. Emitting the seams the writer
	 * would have chosen makes the first round-trip a fixed point. `#if <cond>` stays welded to the
	 * `return` line so that a hoist with no head never emits a bare `return` followed by a newline.
	 */
	private static function buildText(m: Match): String {
		final buffer: StringBuf = new StringBuf();
		buffer.add('return ');
		if (m.head != '') buffer.add('${m.head} + ');
		buffer.add(m.directives[0]);
		for (i in 0...m.branches.length) buffer.add('\n${m.branches[i]}\n${m.directives[i + 1]}');
		if (m.tail != '') buffer.add(' + ${m.tail}');
		buffer.add(';');
		return buffer.toString();
	}

}

/** The `RefShape` seams and support kinds this check reads, bundled once per run. */
private typedef Seams = {
	var shape: RefShape;
	var condKind: String;
	var ifKeyword: String;
	var endKeyword: String;
	var elseKeywords: Array<String>;
	var returnKind: String;
	var stringKinds: Array<String>;
	var blockKinds: Array<String>;
	var concatKind: String;
}

/** The per-file scan state: the source, its comment tokens, its conditional directives and the seams. */
private typedef Ctx = {
	var source: String;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	var directives: Array<CondDirective>;
	var seams: Seams;
}

/** A string literal a cut may fall in: its own bounds, the interior its segments tile, and those segments. */
private typedef Literal = {
	var open: Int;
	var close: Int;
	var from: Int;
	var to: Int;
	var quote: String;
	var segments: Array<Span>;
}

/**
 * One branch's `return` value: how many concatenation operands it has, the two literals the cuts
 * apply to, and the seams a wholly-eaten outer operand leaves the remainder starting / ending at.
 */
private typedef Branch = {
	var count: Int;
	var secondFrom: Int;
	var penultimateTo: Int;
	var head: Literal;
	var tail: Literal;
}

/** A matched region's copied text: the span to replace, the hoisted affixes, the directives and each branch's remainder. */
private typedef Match = {
	var region: Span;
	var head: String;
	var tail: String;
	var directives: Array<String>;
	var branches: Array<String>;
}

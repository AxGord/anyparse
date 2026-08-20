package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * A recognised `if / else if / … / else` CHAIN of single-statement branches: the
 * per-branch `(condition, statement)` pairs and the terminal `else`'s statement. The
 * chain is what the two if-expression collapse rules
 * (`prefer-if-expression-assignment` / `prefer-if-expression-return`) rewrite; this
 * shape is what they SHARE. `branches` holds the head `if` and every `else if` (so
 * `branches.length >= 2` for a real chain — a 2-branch `if`/`else` is not one, and is
 * left to the ternary rules), `terminal` is the final `else`'s statement.
 */
typedef IfChain = {
	var branches: Array<{ cond: QueryNode, stmt: QueryNode }>;
	var terminal: QueryNode;
}

/**
 * One branch's carry seat, as the rule that owns the rebuild sees it: where that branch's
 * CONDITION text ends, the value span the rebuild copies, and where the next copied piece starts
 * (the following branch's condition, or the terminal value). `IfExpressionChain.carryGaps` turns
 * a seat into the two comment slots around that value. A branch whose value is not ONE copied
 * span — a nested `switch` / `if` construct in the assignment hoist — opens no seat, and its
 * comments keep failing the site closed.
 */
typedef CarrySeat = {
	var condEnd: Int;
	var value: Span;
	var nextStart: Int;
}

/**
 * A region between two verbatim-copied pieces whose comments the collapse CARRIES instead of
 * refusing: `key` names the copied piece they ride (`IfExpressionChain.spanKey`) and `before`
 * whether they are emitted in front of its text or behind it.
 */
typedef CarryGap = {
	var from: Int;
	var to: Int;
	var key: String;
	var before: Bool;
}

/** Carried comment text per copied span (`IfExpressionChain.spanKey`), one map per slot. */
typedef Carried = {
	var before: Map<String, String>;
	var after: Map<String, String>;
}

/**
 * The two kind lists `IfExpressionChain.childShielded` reads, bundled into one argument.
 * Both are `Array<String>`, so as adjacent positional parameters a transposed call would have
 * compiled silently and mis-gated every site — three of them, across two modules. Bundling
 * removes the CALL-SITE transposition entirely: there is one construction site and it fills the
 * fields by name. A swap INSIDE that factory would still compile, which is why
 * `IfExpressionChain.shieldSeams` is the only constructor.
 */
typedef ShieldSeams = {
	/** Parents that close every child with a delimiter, so no `else` can follow one. */
	var shieldKinds: Array<String>;

	/** Every `if` form, statement and expression — what an emitted else-less header could absorb. */
	var conditionalKinds: Array<String>;
}

/**
 * The dangling-`else` family's shared home. Two things live here: the `if`-CHAIN shape that
 * `prefer-if-expression-assignment` and `prefer-if-expression-return` rewrite — recognising a
 * chain of single-statement branches and assembling the collapsed
 * `if (c1) v1 else if (c2) v2 … else vN` text — and the POSITION machinery its two OTHER
 * consumers need: `prefer-lambda-expression-body` and the LIFT arm of `loop-guard` each emit
 * an else-LESS conditional, and have to know whether a FOREIGN ` else ` written after it
 * could rebind onto what they emitted. The two collapse rules differ only in what
 * each branch's statement must be (an assignment to the same l-value vs a valued `return`) and
 * in the copied prefix (`lhs op ` vs `return `); everything structural lives here.
 *
 * Unlike the ternary siblings, no null-narrowing guard is needed: the collapsed form is
 * an `if`-EXPRESSION whose conditions are the verbatim `if (…)` conditions, so a branch
 * runs under EXACTLY the narrowing it had as a statement — the transformation is
 * null-safety-preserving by construction.
 *
 * Two hazards of EMITTING that ` else ` reach further than the chain shape does:
 * `prefer-if-expression-chain` rewrites a nested TERNARY rather than an `if` chain, yet
 * assembles the same text and so runs the same risks. `holdsElseLessConditional` (a branch
 * value that would ABSORB the emitted ` else `) and `tokenSpan` (a copied span that would
 * SWALLOW the trailing comment after its last token) therefore live here too, and all three
 * rules share them.
 *
 * ## Position
 *
 * Whether an emitted ` else ` can reach ANYTHING is a property of where the rewritten
 * construct SITS, not of its shape, and that question is not the chain rules' alone —
 * `prefer-lambda-expression-body` collapses a lambda body to an else-less `if`, and the LIFT arm
 * of `loop-guard` emits an else-less loop header, so a trailing `else` rebinds onto either.
 * `shieldSeams` names the parents that close every child with a delimiter, and `childShielded`
 * re-derives one boolean per child from that pair and the parent's own answer; a walk seeds it
 * true at the module root and carries it down. Neither consumer rewrites an `if` chain, so
 * this module's charter is the hazard, not the chain: `conditionalKinds` /
 * `isElseLessConditional` / `holdsElseLessConditional` say WHAT could absorb an ` else `, and
 * `shieldSeams` / `childShielded` say WHERE one could arrive.
 *
 * ## Comments
 *
 * The rebuild copies conditions and values and drops everything between them, so a comment
 * in the dropped text has to be accounted for. Two answers live here, and each rule picks
 * per comment:
 *
 * - `droppedComment` — the family's original fail-closed guard: any comment outside every
 *   copied span refuses the site. Still the whole answer for the sibling rules that carry
 *   nothing (`prefer-ternary-expression`, `prefer-try-expression-*`, …).
 * - `carriedComments` — the same scan with SLOTS. A branch seat (`CarrySeat`) opens two
 *   gaps around that branch's value: the condition-to-value gap, whose comments are emitted
 *   between the rebuilt `if (…)` and the value, and the value-to-next-piece gap, whose
 *   comments are emitted after the value and before the ` else `. Both keep the comment in
 *   the position the author gave it, so the carry is faithful reproduction rather than
 *   re-attribution. Anything outside a slot still refuses, so nothing is ever dropped or
 *   moved to a place that would change what it says.
 *
 * The trailing gap is the narrower of the two because its region runs on THROUGH the `else`
 * (or the ternary `:`) that opens the next branch, and the parser projects NO node for
 * either: a comment written past one describes the branch that FOLLOWS, and emitting it in
 * front of the rebuilt ` else ` would re-read it as being about the branch before. So the
 * gate is what SEPARATES the comment from the value — only a statement's own punctuation
 * (whitespace, the `;` that ended it, the `}` that closed its block) may stand there, and
 * every other character IS that separator (`unseparated`). LAYOUT decides nothing here; it
 * only decides whether the carried comment keeps its own line. The TERMINAL value opens no
 * seat at all: the region behind it belongs to whatever the enclosing rule welds on, and a
 * `//` comment there would swallow the `;`.
 *
 * `buildValue` joins the pieces with one space EXCEPT across a line break a carried comment
 * introduced, so the emitted text is byte-unchanged whenever nothing is carried.
 */
@:nullSafety(Strict)
final class IfExpressionChain {

	/** An `if` with an `else` has exactly [condition, then-branch, else-branch] children. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	/** A real chain is a head plus at least one `else if` — a 2-branch `if`/`else` (one branch) is left to the ternary rules. */
	private static inline final MIN_CHAIN_BRANCHES: Int = 2;

	/** A conditional's then-branch is `children[1]`, between the condition and the else-branch. */
	private static inline final THEN_BRANCH_INDEX: Int = 1;

	/** `span`'s `from:to` key — how a carried comment finds the copied piece it rides. */
	public static inline function spanKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

	/**
	 * Recognise the chain rooted at `head`: follow the else-nesting (`children[2]` being
	 * another `if`) to the terminal plain `else`, collecting each branch's single
	 * statement. Returns null unless it IS a chain (≥1 `else if`) that TERMINATES in a
	 * plain `else` and every branch plus the terminal is a single statement — a chain
	 * with no final `else` yields no if-expression value on the missing path and is
	 * rejected. Rule-agnostic: the branch statements are returned raw, not inspected.
	 */
	public static function collect(head: QueryNode, ifKinds: Array<String>, blockStmtKind: String, ?minBranches: Int): Null<IfChain> {
		final min: Int = minBranches ?? MIN_CHAIN_BRANCHES;
		final branches: Array<{ cond: QueryNode, stmt: QueryNode }> = [];
		var current: QueryNode = head;
		while (true) {
			if (current.children.length != IF_ELSE_CHILD_COUNT) return null; // no `else` -> not collapsible
			final thenStmt: Null<QueryNode> = singleStmt(current.children[1], blockStmtKind);
			if (thenStmt == null) return null;
			branches.push({ cond: current.children[0], stmt: thenStmt });
			final elseBranch: QueryNode = current.children[2];
			if (ifKinds.contains(elseBranch.kind)) {
				current = elseBranch; // `else if` -> continue the chain
			} else {
				final terminal: Null<QueryNode> = singleStmt(elseBranch, blockStmtKind);
				return if (terminal == null)
					null
				else if (branches.length >= min)
					{ branches: branches, terminal: terminal }
				else
					null;
			}
		}
	}

	/**
	 * Whether `node` is an `else if` LINK — the else-branch (`children[2]`) of a parent
	 * `if`. Only a chain HEAD is flagged; a link is part of the head's chain and is
	 * skipped when the walk reaches it on its own.
	 */
	public static function isElseIfLink(node: QueryNode, parent: Null<QueryNode>, ifKinds: Array<String>): Bool {
		return parent != null && ifKinds.contains(parent.kind) && parent.children.length == IF_ELSE_CHILD_COUNT && parent.children[2]
			== node;
	}

	/** Whether two subtrees have identical whitespace-normalized source — the l-value equality key. */
	public static function sameSource(a: QueryNode, b: QueryNode, source: String): Bool {
		final aSpan: Null<Span> = a.span;
		final bSpan: Null<Span> = b.span;
		return aSpan != null && bSpan != null
			&& normalize(source.substring(aSpan.from, aSpan.to)) == normalize(source.substring(bSpan.from, bSpan.to));
	}

	/**
	 * Assemble `${prefix}if (c1) v1 else if (c2) v2 … else vTerminal;` from verbatim
	 * condition / value source slices. No condition parentheses are added — the
	 * `if (…)` syntax already delimits each condition.
	 */
	public static function buildText(prefix: String, pairs: Array<{ cond: String, value: String }>, terminalValue: String): String {
		return '$prefix${buildValue(pairs, terminalValue)};';
	}

	/**
	 * Assemble `if (c1) v1 else if (c2) v2 … else vTerminal` (no prefix, no trailing `;`) — the
	 * if-EXPRESSION VALUE form used both as a statement's r-value (via `buildText`, which wraps it
	 * with a prefix and a terminating `;`) and, recursively, as the branch / arm value of an
	 * enclosing assignment-tree hoist.
	 */
	public static function buildValue(pairs: Array<{ cond: String, value: String }>, terminalValue: String): String {
		final parts: Array<String> = [];
		for (i in 0...pairs.length) {
			if (i > 0) parts.push('else');
			parts.push('if (${pairs[i].cond})');
			parts.push(pairs[i].value);
		}
		parts.push('else');
		parts.push(terminalValue);
		var out: String = parts[0];
		// One space between pieces, EXCEPT across a line break a carried comment put there: a
		// value ending in a `//` comment must be followed by the next piece on a new line, and a
		// value whose leading comment kept its own line must not be pulled back onto the `if (…)`
		// one. Without a carry every boundary takes the space, so the text is byte-unchanged.
		for (i in 1...parts.length) out += out.endsWith('\n') || StringTools.startsWith(parts[i], '\n') ? parts[i] : ' ${parts[i]}';
		return out;
	}

	/**
	 * Whether a comment sits inside the collapsed `if` region `[headSpan.from, headSpan.to)`
	 * but outside every verbatim-copied span (`kept`: the head prefix, each condition, each
	 * value). Such a comment would be dropped by the rebuild — the header keywords, the
	 * braces and the non-head l-values / `return`s all go away — so the finding is skipped
	 * rather than silently losing it.
	 */
	public static function droppedComment(headSpan: Span, kept: Array<Span>, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		return comments.exists(tok -> tok.from >= headSpan.from && tok.to <= headSpan.to && !contained(tok, kept));
	}

	/** An empty carry — what the phase-one build reads, before the comments have been classified. */
	public static function noCarry(): Carried {
		return { before: [], after: [] };
	}

	/**
	 * The source `span` covers with its carried comments welded on — `before` text in front,
	 * `after` text behind. A null `carried` (or one holding no entry for the span) yields the
	 * plain verbatim slice, so EVERY emitter of a copied piece can go through this one function
	 * and none of them needs to know whether the chain carries anything.
	 */
	public static function spanText(source: String, span: Span, carried: Null<Carried>): String {
		final body: String = source.substring(span.from, span.to);
		if (carried == null) return body;
		final key: String = spanKey(span);
		return '${carried.before[key] ?? ''}$body${carried.after[key] ?? ''}';
	}

	/**
	 * The two carry gaps each branch seat opens: the condition-to-value gap, whose comments are
	 * emitted between the rebuilt `if (…)` and the branch value (a LEADING slot), and the
	 * value-to-next-piece gap, whose comments are emitted after that value and before the
	 * ` else ` (a TRAILING slot). Both keep the comment in the SAME relative position it held in
	 * the source, which is what makes the carry faithful rather than a re-attribution.
	 */
	public static function carryGaps(seats: Array<CarrySeat>): Array<CarryGap> {
		final gaps: Array<CarryGap> = [];
		for (seat in seats) {
			final key: String = spanKey(seat.value);
			gaps.push({
				from: seat.condEnd,
				to: seat.value.from,
				key: key,
				before: true
			});
			gaps.push({
				from: seat.value.to,
				to: seat.nextStart,
				key: key,
				before: false
			});
		}
		return gaps;
	}

	/**
	 * Classify every comment the rebuild would otherwise DROP — one inside the collapsed region
	 * `[headSpan.from, headSpan.to)` and outside every verbatim-copied span (`kept`) — into the
	 * slot of `gaps` that holds it. Returns the per-span carry, or null when ANY such comment has
	 * no slot: fail-closed exactly as `droppedComment` is, so the family never drops or misplaces
	 * one. `droppedComment` is this function with no gaps, and stays the entry point for the
	 * sibling rules that carry nothing.
	 */
	public static function carriedComments(
		headSpan: Span, kept: Array<Span>, gaps: Array<CarryGap>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Null<Carried> {
		final carried: Carried = noCarry();
		for (tok in comments) if (tok.from >= headSpan.from && tok.to <= headSpan.to && !contained(tok, kept)) {
			final gap: Null<CarryGap> = carrier(tok, gaps, source);
			if (gap == null) return null;
			final map: Map<String, String> = gap.before ? carried.before : carried.after;
			final text: String = source.substring(tok.from, tok.to).trim();
			final prev: String = map[gap.key] ?? '';
			// A comment the author put on its OWN line keeps one — pulled up it would re-read as
			// being about the CONDITION (leading slot) or as trailing the value (trailing slot), both
			// different statements from the one it makes where it stands. Otherwise the single space
			// `buildValue` does not supply goes on the side the slot needs it.
			final own: Bool = crossesLine(source, gap.from, tok.from) && !prev.endsWith('\n');
			final head: String = if (own)
				'\n'
			else if (gap.before)
				''
			else
				' ';
			// A LINE comment runs to the end of its line, so whatever the rebuild welds after it has
			// to start on the next one — that newline is the only legal layout, and the writer
			// re-flows the spliced file anyway. A block comment rides inline.
			final tail: String = if (tok.isLine)
				'\n'
			else if (gap.before)
				' '
			else
				'';
			map[gap.key] = '$prev$head$text$tail';
		}
		return carried;
	}

	/**
	 * Every `if` form the grammar has — the expression kinds and the statement kinds together.
	 * This is the set the else-less scan below must recognise, and it is deliberately BOTH: an
	 * else-less conditional of either kind absorbs a ` else ` emitted after it, and a rule that
	 * emits one cannot afford to know only the kind its own construct is written in (a
	 * statement-position `if` reaches an expression branch value through a block unwrap, and an
	 * if-EXPRESSION is a legal branch statement).
	 */
	public static function conditionalKinds(shape: RefShape): Array<String> {
		return (shape.ifExpressionKinds ?? []).concat(shape.ifStatementKinds ?? []);
	}

	/**
	 * Whether `node` ITSELF is a conditional with no else-slot (fewer children than the
	 * `[condition, then, else]` an `if`/`else` has). The one definition of "else-less"; the
	 * subtree scan below and the terminal gates in the statement-side rules both ask it, so they
	 * cannot drift apart on what counts.
	 */
	public static function isElseLessConditional(node: QueryNode, conditionalKinds: Array<String>): Bool {
		return conditionalKinds.contains(node.kind) && node.children.length < IF_ELSE_CHILD_COUNT;
	}

	/**
	 * Whether `node`'s subtree holds an else-less conditional anywhere. Such a construct ends an
	 * expression OPEN: the ` else ` the collapse rules emit after a NON-TERMINAL branch value
	 * re-parents onto it, turning the rest of the chain into that `if`'s else branch — a silent
	 * behaviour change whose output still PARSES, so the `--fix` re-parse gate would wave it
	 * through. (Verified on 4.3.7 with a `Void`-typed carrier, where the input is legal Haxe: the
	 * collapse changes what runs for every input combination and still compiles.)
	 *
	 * The whole subtree is scanned rather than only its right spine: an else-less `if` in a
	 * delimited interior (a call argument, a paren) is harmless, but proving WHICH is which
	 * costs more than the rare cleanup it buys, and the answer to any uncertainty is skip.
	 *
	 * The TERMINAL branch value is EXEMPT from THIS scan, and that is a fact about the PARSE
	 * rather than an omission: an `else` that could have followed the chain was already bound
	 * INTO the terminal, which would have made it one more link. The per-level exemption
	 * survives NESTING for one reason worth stating outright, because it is not obvious — at
	 * every OUTER level the caller scans the branch's WHOLE STATEMENT subtree, which SUBSUMES
	 * any nested chain's own exempted terminal. So a nested chain whose terminal ends in an
	 * else-less `if` is exempt where nothing follows it, and still refused by the level whose
	 * ` else ` would actually re-parent onto it.
	 *
	 * A terminal is exempt from RE-PARENTING only. The statement-side rules apply the ROOT-only
	 * `isElseLessConditional` to it separately, for the unrelated span reason documented there.
	 */
	public static function holdsElseLessConditional(node: QueryNode, conditionalKinds: Array<String>): Bool {
		return isElseLessConditional(node, conditionalKinds)
			|| node.children.exists(child -> holdsElseLessConditional(child, conditionalKinds));
	}

	/**
	 * The two `childShielded` inputs for `shape`. The SHIELD half names the parent kinds that
	 * CLOSE every child with a delimiter, so no `else` can follow one: `blockKinds` plus the
	 * grammar's call / `new` / paren / array-literal / index-access / object-field / case-branch
	 * kinds, each taken only when the grammar sets it. Fewer entries there means fewer positions
	 * proved safe, so an unset one makes `childShielded` answer "unshielded" more often — the
	 * conservative direction. An EMPTY `blockKinds` is the extreme of that: a block's TAIL child
	 * then INHERITS instead of being proved safe, which fails the CALLER closed, the intended
	 * answer for a grammar with no `ControlFlowSupport`. The CONDITIONAL half runs the OTHER way
	 * — see `childShielded` — which is why a consumer of this gate must require its `if` kinds
	 * outright rather than treat them as optional.
	 *
	 * `blockKinds()` carries `CondBranchProjection.COND_BRANCH_KIND`, so on a BRANCH-AWARE tree a
	 * `CondBranch` counts as a shield. Both current consumers walk the RAW tree
	 * (`CheckScan.parseOrNull`), where that kind never appears, and the projection is
	 * block-parented wherever it does — so nothing rests on it today; a consumer switching to
	 * `parseBranchAwareOrNull` inherits the assumption.
	 */
	public static function shieldSeams(shape: RefShape, blockKinds: Array<String>): ShieldSeams {
		// `blockKinds()` hands back the plugin's SHARED static array — copy before pushing,
		// or every other consumer of that seam inherits this list's additions.
		final kinds: Array<String> = blockKinds.copy();
		final delimitedHosts: Array<Null<String>> = [
			shape.callKind,
			shape.newExprKind,
			shape.parenKind,
			shape.arrayLiteralKind,
			shape.indexAccessKind,
			shape.objectFieldKind,
			shape.caseBranchKind
		];
		for (host in delimitedHosts) if (host != null) kinds.push(host);
		return { shieldKinds: kinds, conditionalKinds: conditionalKinds(shape) };
	}

	/**
	 * Whether `parent`'s child at `index` is closed by a token that cannot be an `else`.
	 *
	 * A SHIELD parent writes a `)` / `,` / `]` / `}` — or a next statement — after every one
	 * of its children. A child with a FOLLOWING SIBLING is separated from it by a token that
	 * is not an `else`, except the then-branch of a conditional, whose following sibling IS
	 * the else-branch, and except a `#if` region, whose siblings are the OTHER branches and
	 * separate nothing. A TAIL child is bounded by whatever bounds the parent, so it inherits
	 * `shielded`.
	 */
	public static function childShielded(parent: QueryNode, index: Int, seams: ShieldSeams, shielded: Bool): Bool {
		if (seams.shieldKinds.contains(parent.kind)) return true;
		// A `#if` region projects EVERY branch's nodes as FLAT siblings, so a following sibling
		// may belong to a different branch and separate nothing at all: under the defines that
		// select this child's branch, whatever follows the region follows the child. Inherit.
		return if (RefactorSupport.isConditionalKind(parent.kind))
			shielded
		else if (index < parent.children.length - 1)
			!(index == THEN_BRANCH_INDEX && seams.conditionalKinds.contains(parent.kind))
		else
			shielded;
	}

	/**
	 * `span` with its trailing TRIVIA cut off — an expression node's span runs on past its last
	 * token, through the whitespace and any comment that follows, up to the next construct's
	 * start. Two things depend on the tight end: the copied text (a trailing `// …` inside a raw
	 * slice would comment out whatever the rebuild welds after it, and even a block comment
	 * would arrive re-indented into a position the author did not write), and the replaced
	 * region, whose loose end would splice away spacing the author wrote.
	 *
	 * Cutting the comment out of the KEPT span is also what makes `droppedComment` see it: a
	 * token now outside every kept span is one the rebuild would drop, so the site is skipped
	 * instead of being emitted with the comment in a new place.
	 */
	public static function tokenSpan(span: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Span {
		var end: Int = span.to;
		var shrunk: Bool = true;
		while (shrunk) {
			shrunk = false;
			while (end > span.from && isTrailingSpace(source, end - 1)) {
				end--;
				shrunk = true;
			}
			for (token in comments) if (token.to == end && token.from >= span.from) {
				end = token.from;
				shrunk = true;
				break;
			}
		}
		return new Span(span.from, end);
	}

	/** Whether `source[from…to)` breaks a line — the one line-boundary question the carry asks. */
	private static inline function crossesLine(source: String, from: Int, to: Int): Bool {
		return source.substring(from, to).indexOf('\n') >= 0;
	}

	/** Whether `source[at]` is whitespace — the trivia `tokenSpan` walks back over. */
	private static inline function isTrailingSpace(source: String, at: Int): Bool {
		final c: Int = source.fastCodeAt(at);
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/**
	 * The one statement a branch holds — a bare statement, or the sole child of a
	 * `{ … }` wrapping EXACTLY one. Null when the branch is a block of zero or several
	 * statements (a deliberately grouped body is never collapsed).
	 */
	private static function singleStmt(branch: QueryNode, blockStmtKind: String): Null<QueryNode> {
		return if (branch.kind != blockStmtKind)
			branch
		else if (branch.children.length == 1)
			branch.children[0]
		else
			null;
	}

	/** Collapse whitespace runs to a single space and trim. */
	private static function normalize(s: String): String {
		return StringTools.trim((~/\s+/g).replace(s, ' '));
	}

	/** Whether some span in `spans` fully holds `tok` — the "already inside verbatim-copied text" test both comment guards run. */
	private static function contained(tok: { from: Int, to: Int }, spans: Array<Span>): Bool {
		return spans.exists(s -> tok.from >= s.from && tok.to <= s.to);
	}

	/**
	 * The gap that carries `tok`, or null when none does and the site must fail closed.
	 *
	 * A LEADING gap takes the comment whatever its layout: it sits between a branch's condition
	 * and that branch's value, a region holding nothing but the closing `)`, an opening `{` and
	 * the dropped `return ` / l-value — no keyword that could make it belong to a NEIGHBOUR.
	 *
	 * A TRAILING gap is narrower, because its region spans the `else` that opens the next branch
	 * and the parser projects no node for that keyword: a comment written AFTER it describes the
	 * branch that follows, and emitting it in front of the rebuilt ` else ` would re-read it as
	 * being about the branch before. Only the unambiguous shape is taken — the comment starts on
	 * the value's own line and the next copied piece starts on a later one, so the `else` cannot
	 * have preceded it.
	 */
	private static function carrier(tok: { from: Int, to: Int }, gaps: Array<CarryGap>, source: String): Null<CarryGap> {
		for (gap in gaps) if (tok.from >= gap.from && tok.to <= gap.to)
			return gap.before || unseparated(source, gap.from, tok.from) ? gap : null;
		return null;
	}

	/**
	 * Whether `source[from…to)` holds nothing but a statement's own punctuation — whitespace, the
	 * `;` that ended it, the `}` that closed its block. This IS the trailing slot's gate. The
	 * region it scans runs on past those, through the `else` / `:` that opens the NEXT branch, and
	 * the parser projects no node for either keyword; a comment written AFTER one describes the
	 * branch that FOLLOWS, so emitting it in front of the rebuilt ` else ` would re-read it as
	 * being about the branch before. Every character beyond the three IS that separator (or
	 * something else the rebuild does not model), and the site fails closed.
	 */
	private static function unseparated(source: String, from: Int, to: Int): Bool {
		for (i in from ... to) {
			final c: Int = source.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code && c != ';'.code && c != '}'.code) return false;
		}
		return true;
	}

}

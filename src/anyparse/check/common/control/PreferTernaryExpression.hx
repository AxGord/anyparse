package anyparse.check.common.control;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.QuotationAware;
import anyparse.check.common.control.NegatedCondition.InversionSeams;
import anyparse.check.common.control.NegatedCondition.InversionSite;
import anyparse.check.scan.IfExpressionChain;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions;
import anyparse.query.MemberKinds;
import anyparse.query.ParenGuard;
import anyparse.query.ParseGate;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;

/** The kinds `PreferTernaryExpression` reads, bundled once so the walkers take one argument. */
private typedef Seams = {

	var ifExprKinds: Array<String>;
	var branchKinds: Array<String>;
	var delimitedAllKinds: Array<String>;
	var delimitedTailKinds: Array<String>;

	/** The arrow lambdas whose body is a value slot; empty when the grammar leaves a seam this read needs unset. */
	var arrowKinds: Array<String>;
	var blockKinds: Array<String>;
	var ifStmtKinds: Array<String>;
	var exprStmtKind: Null<String>;
	var callKinds: Array<String>;

	/** The negation read the emitted ternary is oriented by; null when the grammar has no not kind. */
	var negation: Null<InversionSeams>;
	var shape: RefShape;

}

/** A rewritable `if`-expression: the finding key span, the (trivia-trimmed) replaced span, and the ternary text. */
private typedef Match = {

	var span: Span;

	/** `cond ? then : else` over the `if`-expression up to its else-branch's end, the condition a `ParenGuard` hole. */
	var edit: GuardedEdit;

}

/** The per-file walk state: the parsed tree, its source and comment tokens, the seams, and the lazy symbol index. */
private typedef Scan = {

	var root: QueryNode;
	var source: String;
	var file: String;

	/** The file's negation site (`NegatedCondition`), null when the grammar has no not kind. */
	var site: Null<InversionSite>;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	var seams: Seams;
	var plugin: GrammarPlugin;
	var resolveIndex: () -> Null<SymbolIndex>;

}

/**
 * Flags a 2-branch `if`-EXPRESSION already written in value position, rewriting it to a
 * ternary:
 *
 * ```haxe
 * final start:Int = if (lastIndex > 1 || !path.startsWith(':'))
 *     lastIndex
 * else
 *     1;
 * // ->
 * final start:Int = lastIndex > 1 || !path.startsWith(':') ? lastIndex : 1;
 * ```
 *
 * Purely structural (no type information). `Info` -- the code is correct, this is a
 * readability simplification matching the user's documented preference for a ternary over a
 * two-branch `if`.
 *
 * ## The coverage gap this closes
 *
 * The rest of the family matches a SHAPE AROUND the `if`: `prefer-ternary-assignment` /
 * `prefer-ternary-return` take an `if`/`else` STATEMENT whose branches assign or return, and
 * `prefer-if-expression-assignment` / `-return` take a CHAIN (>= 1 `else if`) of such
 * statements. An `if`-expression the author already wrote as a value (`var x = if (c) a else
 * b`, `return if (c) a else b`, `f(if (c) a else b)`) is a statement to nobody, so none of
 * them see it. This check owns exactly that node.
 *
 * ## What is flagged
 *
 * An `ifExpressionKinds` node -- expression BY KIND, so it always yields a value -- with:
 *
 * - exactly `[condition, then, else]` children. A no-`else` `if`-expression yields no value
 *   on the missing path and never matches;
 * - both branches drawn from `ternaryConditionUnwrapKinds`, the grammar's own whitelist of
 *   kinds that bind STRICTLY TIGHTER than `?:` -- the same set `redundant-parens` trusts to
 *   survive unwrapping into a ternary CONDITION, which is exactly the property an operand slot
 *   needs. Being a whitelist it is fail-closed by CONSTRUCTION rather than by enumeration: a
 *   bodied construct (a block, a nested `if` / `switch` / `try`), a control exit
 *   (`return` / `throw`), a `macro` / `untyped` quotation, an assignment, an arrow lambda and
 *   a nested ternary are all absent from it, so none can reach a ternary arm and none had to
 *   be thought of. It is also what keeps this check off `prefer-if-expression-*` output: a
 *   chain HEAD's `else` is another `if`-expression, absent from the whitelist;
 * - a SLOT that accepts a bare `?:` (`slotAcceptsTernary`). This is the gate an
 *   "if-expressions are value position by kind, so no position analysis is needed" reading
 *   misses, and it is a correctness gate, not a taste one: the `if`-expression it replaces is
 *   self-delimiting, a ternary is the loosest-binding operator above assignment, so
 *   `var v = a || if (c) x else y;` (which groups as `a || (…)`) would become
 *   `var v = a || c ? x : y;` -- which groups as `(a || c) ? x : y`, compiles, and returns a
 *   different value. The accepted slots come from the grammar: `delimitedAllChildKinds`,
 *   `delimitedTailChildKinds` for any child after the head, and a plain paren. A chain LINK is
 *   refused by the same gate for free -- its parent is the head `if`-expression, which is no
 *   host's delimited slot; that subsumption holds only while no `ifExpressionKinds` entry is ALSO
 *   a delimited host. The slots the gate is conservative about are known and cost only a missed
 *   cleanup: a `throw` operand, a cast or `(e : T)` check, an index, and a comprehension or
 *   map-literal element would all be safe;
 * - or the body an ARROW lambda returns (`ShapeVocab.arrowLambdaKinds`): its expression body, or
 *   the `if` STATEMENT ending its block body, whose value the lambda returns without `return`
 *   (a `function` literal's block does not, so it is no arrow). There both branches must be plain
 *   values, not calls: a branching lambda of calls stays an `if` under the brace policy;
 * - no comment in a region the rebuild drops (the `if (` / `)` / `else` glue and the braces
 *   all go away), following the family's fail-closed comment guard.
 *
 * A `macro { … }` quotation is read like any other code (`QuotationAware`): the ternary types the same as the
 * if-expression, and a spliced branch is not in the whitelist, so it never reaches an arm.
 *
 * ## Handoff to `join-branch-call`
 *
 * A 2-branch value `if` whose branches are the SAME call differing in one argument is BOTH this
 * rule's shape and `join-branch-call`'s -- and only one of the two edits can survive, because
 * `Cli.computeFileLintEdits` keeps whichever check comes first in `Linter.builtins()`, which is
 * this one. Keeping it here writes the callee TWICE (`a ? log(1) : log(2)`) and settles there,
 * since `prefer-if-expression-chain` needs three values to reclaim it. So `match` asks
 * `JoinBranchCall.claims` and declines: that rule sinks the branching into the argument
 * (`log(if (a) 1 else 2)`), and THIS rule takes the result on the next `--fix` pass, where the
 * branch values are no longer calls. The same shape as `prefer-if-expression-chain` deferring to
 * `PreferSwitchExpression.claims`. It costs the lazy symbol index `claims` may force -- only
 * after every structural gate of that rule has passed, so effectively never.
 *
 * The reported span is the whole `if`-expression.
 *
 * ## Autofix
 *
 * `fix` replaces the `if`-expression with `cond ? then : else` -- no trailing `;`, the node
 * being an expression, so the enclosing statement's terminator is untouched. The three pieces
 * are copied verbatim from their spans. The condition is a `ParenGuard` hole: it gains parentheses exactly
 * where it would bind across `?` bare (a ternary, an assignment, an arrow lambda, `in`), per the user's
 * no-redundant-parens preference; the branches are copied bare, which the branch whitelist is what makes
 * safe. A condition whose top-level node is a built-in `!` is emitted POSITIVE, the two values swapped
 * and both made holes too (`NegatedCondition.ternaryEdit`, the read `invert-negated-if-else` makes).
 *
 * The replaced region stops at the ELSE-BRANCH's end, not at the node's own: an
 * `if`-expression span runs on through the trivia after its last token, and splicing that
 * away welds the ternary's tail onto whatever follows (`q` + `else` -> the identifier
 * `qelse`) -- which still PARSES, so the `--fix` re-parse gate would wave it through.
 *
 * `run` and `fix` share one `collect`, so neither can encode a gate the other misses.
 *
 * Needs `ifExpressionKinds` and `ternaryConditionUnwrapKinds`; either unset makes the check a
 * no-op. `delimitedAllChildKinds` / `delimitedTailChildKinds` / `parenKind` are optional --
 * with none of them set NO slot is accepted and the check is inert, which is the safe direction. The arrow-body read
 * needs `lambdaKinds` with `fnExprKind`, and for a block tail `ifStatementKinds`, `exprStatementKind` and the
 * `controlFlowSupport` block kinds; unset, no arrow body is read.
 */
@:nullSafety(Strict)
@:lintBefore(JoinBranchCall)
final class PreferTernaryExpression extends RuleBase implements ConfigAware implements QuotationAware {

	/** The linter's per-file config resolver (`invert-negated-if-else` `keepDefaultElse`), or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super('prefer-ternary-expression', 'a two-branch if-expression in value position, rewritable as a ternary', RuleCategory.Control);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin, files, _resolveConfig);
		if (seams == null) return [];
		final resolveIndex: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return [ for (entry in files) for (m in collect(plugin, entry.file, entry.source, seams, resolveIndex)) {
			file: entry.file,
			span: m.span,
			rule: 'prefer-ternary-expression',
			severity: Severity.Info,
			message: 'this two-branch if-expression can be a ternary'
		} ];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final seams: Null<Seams> = readSeams(plugin, [{ file: file, source: source }], _resolveConfig, index);
		if (seams == null) return [];
		final resolveIndex: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: '', source: source }], plugin, index);
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, file, source, seams, resolveIndex)) byKey['${m.span.from}:${m.span.to}'] = m;
		final guarded: Array<GuardedEdit> = [];
		final plain: Array<{ span: Span, text: String }> = CheckScan.collectSpanEdits(violations, byKey, (m, _) -> {
			guarded.push(m.edit);
			return m.edit;
		});
		// `plain` and `guarded` hold the same edits in the same order, so a containment index of one is the other's.
		return ParenGuard.guard(source, [ for (i in 0...guarded.length) if (!CanonicalEdit.isContainedEdit(plain, i)) guarded[i] ], plugin);
	}

	/**
	 * Whether this rule rewrites arrow `lambda`'s expression body into a ternary: the handoff `lambda-branching-body-braces`
	 * asks before bracing that body, since a plain-value two-branch `if` there is the ternary's by the user's call and
	 * braces would contradict the rewrite on the same span. A body whose rebuild would drop a comment stays the braces'.
	 */
	public static function claimsArrowBody(plugin: GrammarPlugin, source: String, lambda: QueryNode): Bool {
		final shape: RefShape = plugin.refShape();
		final ifBody: Null<QueryNode> = arrowIfBody(
			lambda, shape.ifExpressionKinds ?? [], shape.ternaryConditionUnwrapKinds ?? [], MemberKinds.invocationKinds(shape)
		);
		return ifBody != null
			&& rewrite(
				ifBody, BranchChain.condOf(ifBody), BranchChain.thenOf(ifBody), BranchChain.elseBranch(ifBody), source,
				SourceComments.collectCommentTokens(plugin.lexicalRegions(source)), null
			) != null;
	}

	/**
	 * Every rewritable 2-branch value `if` in `file`'s `source` (empty when it does not parse).
	 * `run` and `fix` both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(
		plugin: GrammarPlugin, file: String, source: String, s: Seams, resolveIndex: () -> Null<SymbolIndex>
	): Array<Match> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final out: Array<Match> = [];
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		walk(root, {
			root: root,
			source: source,
			file: file,
			site: NegatedCondition.siteOf(s.negation, file, source, root, () -> regions),
			comments: SourceComments.collectCommentTokens(regions),
			seams: s,
			plugin: plugin,
			resolveIndex: resolveIndex
		}, out, null, 0);
		return out;
	}

	/**
	 * Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op).
	 * `files` / `report` scope the negation read's operator table (`NegatedCondition.readSeams`).
	 */
	private static function readSeams(
		plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, config: Null<(String) -> LintConfig>, ?report: SymbolIndex
	): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifExprKinds: Null<Array<String>> = shape.ifExpressionKinds;
		if (ifExprKinds == null || ifExprKinds.length == 0) return null;
		// A branch is ACCEPTED only from the grammar's own whitelist of kinds that bind
		// strictly tighter than `?:` — the same set `redundant-parens` trusts to survive
		// unwrapping into a ternary CONDITION, which is exactly the property an operand
		// slot needs. Fail-closed by construction: a bodied construct (block / `if` /
		// `switch` / `try`), a control exit, a `macro` / `untyped` quotation, an
		// assignment, an arrow lambda and a nested ternary are all absent from it, so
		// none of them can reach a ternary arm without anyone having to enumerate them.
		final branchKinds: Null<Array<String>> = shape.ternaryConditionUnwrapKinds;
		if (branchKinds == null || branchKinds.length == 0) return null;
		// The slots a bare `?:` may LAND in: a host that delimits every child, plus one
		// that delimits every child after its head (a call argument, an assignment
		// r-value) and a plain paren. Anywhere else an operator outside would bind into
		// the emitted ternary — `a || if (c) x else y` is `a || (…)`, but
		// `a || c ? x : y` is `(a || c) ? x : y`.
		final parenKind: Null<String> = shape.parenKind;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return {
			ifExprKinds: ifExprKinds,
			branchKinds: branchKinds,
			delimitedAllKinds: (shape.delimitedAllChildKinds ?? []).concat(parenKind == null ? [] : [parenKind]),
			delimitedTailKinds: shape.delimitedTailChildKinds ?? [],
			arrowKinds: ShapeVocab.arrowLambdaKinds(shape),
			blockKinds: support == null ? [] : support.blockKinds(),
			ifStmtKinds: shape.ifStatementKinds ?? [],
			exprStmtKind: shape.exprStatementKind,
			callKinds: MemberKinds.invocationKinds(shape),
			negation: NegatedCondition.readSeams(plugin, files, config, report),
			shape: shape
		};
	}

	/**
	 * Walk `node`, collecting every value `if` that is rewritable IN ITS SLOT. `parent` /
	 * `childIndex` carry the slot the node occupies, which the emitted ternary — unlike the
	 * self-delimiting `if`-expression it replaces — is sensitive to. An arrow lambda's body is
	 * read from the lambda itself (`matchArrowBody`), since its block tail is a slot two levels down.
	 */
	private static function walk(node: QueryNode, scan: Scan, out: Array<Match>, parent: Null<QueryNode>, childIndex: Int): Void {
		if (scan.seams.ifExprKinds.contains(node.kind) && slotAcceptsTernary(parent, childIndex, scan.seams)) {
			final m: Null<Match> = match(node, scan);
			if (m != null) out.push(m);
		}
		if (scan.seams.arrowKinds.contains(node.kind)) {
			final m: Null<Match> = matchArrowBody(node, scan);
			if (m != null) out.push(m);
		}
		for (i in 0...node.children.length) walk(node.children[i], scan, out, node, i);
	}

	/**
	 * Whether a bare `?:` may occupy the slot `parent`.`childIndex` — the slot delimits every
	 * child, or delimits every child after its head and this is not the head. Everywhere else
	 * an operator outside would bind INTO the emitted ternary: `a || if (c) x else y` groups
	 * as `a || (…)`, while `a || c ? x : y` groups as `(a || c) ? x : y` — same tokens,
	 * different program, no compile error. A chain LINK is refused here for free: its parent
	 * is the head `if`-expression, which is no host's delimited slot.
	 */
	private static function slotAcceptsTernary(parent: Null<QueryNode>, childIndex: Int, s: Seams): Bool {
		return parent != null
			&& (s.delimitedAllKinds.contains(parent.kind) || (childIndex > 0 && s.delimitedTailKinds.contains(parent.kind)));
	}

	/**
	 * The rewrite of `node` when it is a 2-branch value `if` both of whose branches are plain
	 * values and whose rebuild drops no comment; else null (see the class doc for every gate).
	 */
	private static function match(node: QueryNode, scan: Scan): Null<Match> {
		final s: Seams = scan.seams;
		if (!BranchChain.hasElse(node)) return null;
		final thenBranch: QueryNode = BranchChain.thenOf(node);
		final elseBranch: QueryNode = BranchChain.elseBranch(node);
		if (!s.branchKinds.contains(thenBranch.kind) || !s.branchKinds.contains(elseBranch.kind)) return null;
		// `join-branch-call` owns a chain whose branches are the SAME call differing in one
		// argument: it writes the callee once, a ternary writes it twice. Both match this span and
		// only one edit survives -- `Cli.computeFileLintEdits` keeps the earlier check in
		// `Linter.builtins()` order, which is this one -- so the handoff has to happen here.
		if (JoinBranchCall.claims(scan.plugin, scan.source, scan.root, node, scan.comments, scan.resolveIndex, scan.file)) return null;
		return rewrite(node, BranchChain.condOf(node), thenBranch, elseBranch, scan.source, scan.comments, scan.site);
	}

	/**
	 * The rewrite of the `if` an arrow lambda returns: its expression body (`arrowIfBody`), or the last statement
	 * of its block body, which the lambda returns without `return`. Both branches must be plain values (`plainValue`).
	 */
	private static function matchArrowBody(lambda: QueryNode, scan: Scan): Null<Match> {
		final s: Seams = scan.seams;
		final ifBody: Null<QueryNode> = arrowIfBody(lambda, s.ifExprKinds, s.branchKinds, s.callKinds);
		if (ifBody != null)
			return rewrite(
				ifBody, BranchChain.condOf(ifBody), BranchChain.thenOf(ifBody), BranchChain.elseBranch(ifBody), scan.source, scan.comments,
				scan.site
			);
		if (lambda.children.length == 0) return null;
		final body: QueryNode = lambda.children[lambda.children.length - 1];
		if (!s.blockKinds.contains(body.kind) || body.children.length == 0) return null;
		final tail: QueryNode = body.children[body.children.length - 1];
		if (!s.ifStmtKinds.contains(tail.kind) || !BranchChain.hasElse(tail)) return null;
		final thenValue: Null<QueryNode> = statementValue(BranchChain.thenOf(tail), s);
		final elseValue: Null<QueryNode> = statementValue(BranchChain.elseBranch(tail), s);
		return thenValue == null || elseValue == null
			? null
			: rewrite(tail, BranchChain.condOf(tail), thenValue, elseValue, scan.source, scan.comments, scan.site);
	}

	/** The expression body of arrow `lambda` when it is a two-branch `if`-expression of plain values; else null. */
	private static function arrowIfBody(
		lambda: QueryNode, ifExprKinds: Array<String>, branchKinds: Array<String>, callKinds: Array<String>
	): Null<QueryNode> {
		if (lambda.children.length == 0) return null;
		final body: QueryNode = lambda.children[lambda.children.length - 1];
		return ifExprKinds.contains(body.kind)
			&& BranchChain.hasElse(body)
			&& plainValue(BranchChain.thenOf(body), branchKinds, callKinds)
			&& plainValue(BranchChain.elseBranch(body), branchKinds, callKinds)
			? body
			: null;
	}

	/**
	 * Whether `node` may stand as an arm of a ternary an arrow lambda returns: a whitelisted branch kind and no call. A
	 * call is a statement the lambda runs, and a branching lambda of calls keeps its `if` under the brace policy.
	 */
	private static function plainValue(node: QueryNode, branchKinds: Array<String>, callKinds: Array<String>): Bool {
		return branchKinds.contains(node.kind) && !callKinds.contains(node.kind);
	}

	/** The plain value an expression STATEMENT branch holds, or null when the branch is anything else. */
	private static function statementValue(branch: QueryNode, s: Seams): Null<QueryNode> {
		final value: Null<QueryNode> = branch.kind == s.exprStmtKind && branch.children.length == 1 ? branch.children[0] : null;
		return value != null && plainValue(value, s.branchKinds, s.callKinds) ? value : null;
	}

	/**
	 * The ternary rewrite of `node`, an `if` on `condition` choosing `thenValue` or `elseValue`; null when a span is
	 * unknown or the rebuild drops one of `comments`. The edit stops at the else value rather than at the node's own end: an
	 * `if`-expression span runs on through the trivia that follows its last token, and splicing that away welds the
	 * ternary's tail onto whatever comes next (`q` + `else` -> `qelse`, which still PARSES, so the `--fix` validation gate
	 * would pass it); a statement's terminator after it stays the ternary's.
	 */
	private static function rewrite(
		node: QueryNode, condition: QueryNode, thenValue: QueryNode, elseValue: QueryNode, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, site: Null<InversionSite>
	): Null<Match> {
		final span: Null<Span> = node.span;
		final condSpan: Null<Span> = condition.span;
		final thenSpan: Null<Span> = thenValue.span;
		final elseSpan: Null<Span> = elseValue.span;
		return if (span == null || condSpan == null || thenSpan == null || elseSpan == null)
			null
		else if (IfExpressionChain.droppedComment(span, [condSpan, thenSpan, elseSpan], comments))
			null
		else
			{
				span: span,
				edit: NegatedCondition.ternaryEdit(new Span(span.from, elseSpan.to), '', condition, thenValue, elseValue, '', source, site)
			};
	}

}

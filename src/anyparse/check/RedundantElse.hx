package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `else` that follows an `if` branch which always exits — a
 * `return` / `throw` / `break` / `continue`. The `else` adds needless nesting:
 * its body can be de-nested to run as the `if`'s siblings, because control only
 * reaches them when the condition was false (the then-branch having exited
 * otherwise). Purely structural (no type information), so it holds without a
 * type-checker. `Info` — the code is correct, this is a readability
 * simplification (mirroring the sibling `redundant-parens`).
 *
 * ## What is flagged
 *
 * Only an `if` STATEMENT that is a DIRECT child of a statement list, has an `else`, and
 * whose then-branch always exits: the then-branch is itself terminal
 * (`ControlFlowSupport.isTerminal`) or is a block whose last direct child is
 * terminal. The block-direct-child restriction is the correctness gate — an
 * inline `if (outer) if (a) return; else b();` (the inner `if` being the
 * un-braced body of another statement) is NOT flagged, since de-nesting its
 * `else` would pull `b()` out of `outer`'s control. Expression-position `if`
 * (`var x = if (c) a else b`, whose `else` is required) never appears as a
 * direct block child and is excluded from `RefShape.ifStatementKinds`. The
 * reported span is the `else` branch — the redundant code.
 *
 * The check reads the BRANCH-AWARE projection (`CheckScan.parseBranchAwareOrNull`), so one
 * conditional-compilation branch is a statement list of its own and an `else` guarded by `#if`
 * is flagged and de-nested like any other. Only statements of the SAME branch are ever siblings,
 * so a de-nest can never splice across a `#else` / `#end` directive.
 *
 * ## Autofix
 *
 * `fix` de-nests the `else` body: it replaces the whole `if` statement with the else-less `if`
 * followed by the else body's statements as siblings. Two gates can withhold the edit and leave
 * the finding report-only.
 *
 * The SCOPE gate refuses when an else-body top-level local (`RefShape.localDeclKinds`) carries a
 * name already bound where the de-nested run would land — de-nesting it would redeclare the name
 * in the same scope. That set is accumulated down the tree (`collectDeNests`): the enclosing
 * function's parameters, plus, for the INNERMOST enclosing scope (`RefShape.scopeKinds` — a real
 * `{ … }` block, a function body, a `for`, a `catch`), every local declared anywhere in that
 * scope's subtree down to the next scope boundary (`frameLocalNames`). A conditional region is not
 * a boundary, so a local inside ANY `#if` region of that scope counts wherever it sits relative to
 * the flagged `if`; a real `{ … }` block IS one, so a de-nest inside it may legally shadow an
 * outer name and only that block's own frame applies. The one subtraction: a branch never sees
 * what a SIBLING branch of its OWN region binds, those being mutually exclusive configurations.
 *
 * The COMMENT gate refuses when the rewrite would DELETE a comment. Only two source slices are
 * re-emitted verbatim — the `if` through the end of its then-branch, and the else body's
 * first-to-last statement run — so a comment leading the body, trailing it, sitting between the
 * branches, or filling a body that holds no statement at all would be dropped; the message then
 * carries a note saying so. A comment BETWEEN two de-nested statements is inside the run, survives
 * verbatim, and does not withhold the fix.
 *
 * An `else if` chain surfaces the inner `else` only after the outer one is de-nested (a later
 * pass), and a nested flagged `if` inside the de-nested run is dropped
 * (`RefactorSupport.dropContainedEdits`) so edits never overlap. Needs `ControlFlowSupport`; unset
 * makes the check report-only.
 */
@:nullSafety(Strict)
final class RedundantElse implements Check {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	private static inline final MESSAGE: String = 'this else is redundant — the if branch always exits';

	/** ASCII-only note appended when a comment the de-nest would delete withholds the autofix. */
	private static inline final COMMENT_NOTE: String = ' (comment in the else body - de-nest by hand)';

	public function new() {}

	public function id(): String {
		return 'redundant-else-after-return';
	}

	public function description(): String {
		return 'an else after an if branch that always exits (return / throw / break / continue)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, seams, RefactorSupport.collectCommentTokens(entry.source));
		}
		return violations;
	}

	/**
	 * De-nest each flagged `else`. Walks blocks and rewrites only their direct-child
	 * flagged `if` statements, so the de-nested body lands in a real statement list.
	 * `dropContainedEdits` keeps a single non-overlapping edit when a flagged `if`
	 * sits inside another's de-nested run. Needs `ControlFlowSupport`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectDeNests(tree, source, seams, [], RefactorSupport.collectCommentTokens(source), flagged, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Walk `node`; at each block flag the direct-child `if` statements whose `else`
	 * is redundant. The whole tree is walked so nested blocks are reached.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, seams: Seams, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Void {
		if (seams.support.blockKinds()
			.contains(node.kind)) for (stmt in node.children) if (seams.ifKinds.contains(stmt.kind))
			flagIf(out, file, stmt, seams.support, comments);
		for (c in node.children) walk(out, file, c, seams, comments);
	}

	/**
	 * Emit one `Info` on the `else` branch of `ifNode` when its then-branch always exits, noting in
	 * the message when a comment the de-nest cannot carry keeps the finding report-only.
	 */
	private static function flagIf(
		out: Array<Violation>, file: String, ifNode: QueryNode, support: ControlFlowSupport,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		if (!branchAlwaysExits(ifNode.children[1], support)) return;
		final elseSpan: Null<Span> = ifNode.children[2].span;
		if (elseSpan != null) out.push({
			file: file,
			span: elseSpan,
			rule: 'redundant-else-after-return',
			severity: Severity.Info,
			message: deNestDropsComment(ifNode, support, comments) ? MESSAGE + COMMENT_NOTE : MESSAGE
		});
	}

	/**
	 * Whether de-nesting `ifNode`'s `else` would DELETE a comment. The rewrite re-emits exactly two
	 * verbatim slices — the `if` through the end of its then-branch, and the else body's
	 * first-to-last statement run — so a comment anywhere else inside the `if`'s span is dropped: one
	 * leading the body, one trailing it, one between the branches, and every comment of a body that
	 * holds no statement at all. A comment BETWEEN two de-nested statements is inside the run,
	 * survives verbatim, and is not counted.
	 */
	private static function deNestDropsComment(
		ifNode: QueryNode, support: ControlFlowSupport, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return false;
		final ifSpan: Null<Span> = ifNode.span;
		final thenSpan: Null<Span> = ifNode.children[1].span;
		final run: Null<Span> = deNestedRun(ifNode.children[2], support);
		if (ifSpan == null || thenSpan == null || run == null) return false;
		for (tok in comments) if (tok.from >= thenSpan.to && tok.to <= ifSpan.to && (tok.to <= run.from || tok.from >= run.to)) return true;
		return false;
	}

	/**
	 * The span of the else-body text `deNestText` re-emits verbatim: the body's own span when it is a
	 * single statement, its first-to-last statement run when it is a block, and an EMPTY span at the
	 * body's end when the block holds no statement. Null when a coordinate is missing.
	 */
	private static function deNestedRun(elseNode: QueryNode, support: ControlFlowSupport): Null<Span> {
		final elseSpan: Null<Span> = elseNode.span;
		if (elseSpan == null) return null;
		if (!support.blockKinds().contains(elseNode.kind)) return elseSpan;
		final kids: Array<QueryNode> = elseNode.children;
		if (kids.length == 0) return new Span(elseSpan.to, elseSpan.to);
		final first: Null<Span> = kids[0].span;
		final last: Null<Span> = kids[kids.length - 1].span;
		return first == null || last == null ? null : new Span(first.from, last.to);
	}

	/**
	 * Whether `node` (an `if`'s then-branch) unconditionally exits: a terminal
	 * statement directly, or a block whose last direct child is terminal.
	 */
	private static function branchAlwaysExits(node: QueryNode, support: ControlFlowSupport): Bool {
		if (support.isTerminal(node)) return true;
		if (support.blockKinds().contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			return kids.length > 0 && support.isTerminal(kids[kids.length - 1]);
		}
		return false;
	}

	/**
	 * Mirror `walk`: collect a de-nest edit for each direct-child flagged `if`, threading the
	 * bindings a de-nested local would land beside. `inherited` are the names already bound where
	 * `node` sits — the enclosing function's parameters, plus the frame of every enclosing statement
	 * list the de-nest cannot shadow; a statement list unions its OWN frame (`frameLocalNames`, its
	 * whole subtree down to the next scope boundary) onto them to form the collision scope.
	 *
	 * Whether a child RESETS that set is decided by the grammar's own scope seam
	 * (`RefShape.scopeKinds`), not by the block seam. Everything in `scopeKinds` — a real `{ … }`
	 * block, a function body, a `for`, a `catch` clause — resets it, so a name de-nested inside one
	 * legally SHADOWS an outer binding; everything NOT in it passes the set through, which is how a
	 * `#if` branch keeps seeing the enclosing function's parameters and the innermost real block's
	 * locals.
	 *
	 * A conditional REGION is the one child treated specially: it receives the block's frame MINUS
	 * its own subtree, so each of its branches starts from what the region inherited and adds only
	 * its own locals. Sibling branches therefore never see each other's — mutually exclusive
	 * configurations can never coexist.
	 */
	private static function collectDeNests(
		node: QueryNode, source: String, seams: Seams, inherited: Array<String>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		final isBlock: Bool = seams.support.blockKinds().contains(node.kind);
		final scopeNames: Array<String> = isBlock ? inherited.concat(frameLocalNames(node, seams, null)) : inherited;
		if (isBlock) for (stmt in node.children) if (seams.ifKinds.contains(stmt.kind))
			deNest(stmt, source, seams, scopeNames, comments, flagged, edits);
		// A function hands its OWN parameters to every child, which is how its body block gets
		// them; otherwise a scope-opening child starts fresh and anything else continues here.
		final ownParams: Null<Array<String>> = seams.functionKinds.contains(node.kind) ? paramNamesOf(node, seams.support) : null;
		for (c in node.children) {
			final childNames: Array<String> = if (ownParams != null)
				ownParams;
			else if (seams.scopeKinds.contains(c.kind))
				[];
			else if (isBlock && c.kind == seams.condKind)
				inherited.concat(frameLocalNames(node, seams, c));
			else
				scopeNames;
			collectDeNests(c, source, seams, childNames, comments, flagged, edits);
		}
	}

	/**
	 * The parameter names of a function node: its direct children that carry a name and are
	 * not blocks (that excludes the body block; the return-type node's name is harmless — a
	 * local can never share a type's name, so it never causes a false collision).
	 */
	private static function paramNamesOf(fn: QueryNode, support: ControlFlowSupport): Array<String> {
		final names: Array<String> = [];
		for (c in fn.children) {
			final nm: Null<String> = c.name;
			if (nm != null && !support.blockKinds().contains(c.kind)) names.push(nm);
		}
		return names;
	}

	/**
	 * The local-declaration names bound in `block`'s own frame: every `localDeclKinds` node in its
	 * subtree down to the next scope boundary (`RefShape.scopeKinds`) — the model
	 * `UnusedLocal` / `SelfAssignment` / `TypeResolver` resolve names with. A conditional region
	 * and its `CondBranch`es are not boundaries, so a local declared inside one binds HERE, which
	 * is what makes a local in a DIFFERENT `#if` region of the same block visible to the gate.
	 *
	 * `skip`'s subtree is left out. The only caller passes the region a child is about to descend
	 * into, so a branch never inherits what a SIBLING branch of its own region binds: the two are
	 * mutually exclusive configurations and can never coexist.
	 *
	 * An un-braced `if (c) var n;` body is collected too — Haxe scopes that binding to the branch,
	 * so counting it can only REFUSE a de-nest that would have been legal, never allow a wrong one.
	 */
	private static function frameLocalNames(block: QueryNode, seams: Seams, skip: Null<QueryNode>): Array<String> {
		final names: Array<String> = [];
		collectFrameNames(block, seams, skip, names);
		return names;
	}

	/** Append every local-decl name under `node` to `out`, descending through anything that is not `skip` or a scope. */
	private static function collectFrameNames(node: QueryNode, seams: Seams, skip: Null<QueryNode>, out: Array<String>): Void {
		for (c in node.children) if (c != skip && !seams.scopeKinds.contains(c.kind)) {
			final nm: Null<String> = c.name;
			if (nm != null && seams.localDeclKinds.contains(c.kind)) out.push(nm);
			collectFrameNames(c, seams, skip, out);
		}
	}

	/**
	 * Replace the flagged `if`'s whole span with the else-less `if` plus the
	 * de-nested else body. Skips a scope-unsafe body (`deNestText` returns null).
	 * `scopeNames` are the enclosing-scope bindings the de-nested locals must not collide with.
	 */
	private static function deNest(
		ifNode: QueryNode, source: String, seams: Seams, scopeNames: Array<String>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		final elseNode: QueryNode = ifNode.children[2];
		final elseSpan: Null<Span> = elseNode.span;
		if (elseSpan == null || !flagged.contains('${elseSpan.from}:${elseSpan.to}')) return;
		if (deNestDropsComment(ifNode, seams.support, comments)) return;
		final ifSpan: Null<Span> = ifNode.span;
		final thenSpan: Null<Span> = ifNode.children[1].span;
		if (ifSpan == null || thenSpan == null) return;
		final deNested: Null<String> = deNestText(elseNode, source, seams.support, seams.localDeclKinds, scopeNames);
		if (deNested == null) return;
		final ifKept: String = source.substring(ifSpan.from, thenSpan.to);
		edits.push({ span: new Span(ifSpan.from, ifSpan.to), text: deNested == '' ? ifKept : '$ifKept\n$deNested' });
	}

	/**
	 * The else body's source de-nested to top-level statements: the statement run `deNestedRun`
	 * marks out, taken verbatim (an empty block yields ''). Returns null when an else-body top-level
	 * local (`localDeclKinds`) has a name in `scopeNames` (the enclosing scope) — de-nesting would
	 * redeclare it in the same scope — or when a coordinate is missing.
	 */
	private static function deNestText(
		elseNode: QueryNode, source: String, support: ControlFlowSupport, localDeclKinds: Array<String>, scopeNames: Array<String>
	): Null<String> {
		final stmts: Array<QueryNode> = support.blockKinds().contains(elseNode.kind) ? elseNode.children : [elseNode];
		if (collidesWithScope(stmts, localDeclKinds, scopeNames)) return null;
		final run: Null<Span> = deNestedRun(elseNode, support);
		return run == null ? null : source.substring(run.from, run.to);
	}

	/**
	 * Whether any top-level local declaration among `stmts` (kinds in `localDeclKinds`)
	 * has a name already bound in the enclosing scope (`scopeNames`) — de-nesting it would
	 * be a same-scope redeclaration (an error under `-D no-shadowing`), so such a body is
	 * left nested.
	 */
	private static function collidesWithScope(stmts: Array<QueryNode>, localDeclKinds: Array<String>, scopeNames: Array<String>): Bool {
		for (s in stmts) {
			final nm: Null<String> = s.name;
			if (nm != null && localDeclKinds.contains(s.kind) && scopeNames.contains(nm)) return true;
		}
		return false;
	}


	/** Resolve the if seam kinds plus control-flow support and the local-decl / function kinds, or null when a required piece is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			ifKinds: ifKinds,
			support: support,
			localDeclKinds: shape.localDeclKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			scopeKinds: shape.scopeKinds,
			condKind: shape.conditionalMemberKind
		};
	}

}

/**
 * The resolved seams `RedundantElse` reads in `run` and `fix`; `localDeclKinds`, `functionKinds`,
 * `scopeKinds` and `condKind` are used only by `fix`'s de-nest scope-collision check.
 */
private typedef Seams = {
	final ifKinds: Array<String>;
	final support: ControlFlowSupport;
	final localDeclKinds: Array<String>;
	final functionKinds: Array<String>;
	final scopeKinds: Array<String>;
	final condKind: Null<String>;
};

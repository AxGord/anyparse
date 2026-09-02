package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

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
 * An else-CHAIN whose every branch is ONE valued `return` is `prefer-if-expression-return`'s and is
 * NOT flagged here: that rule's single fix IS the canon, where this de-nest starts a pairwise
 * march to the same text through a ternary chain the `prefer-if-expression-chain` rule condemns.
 * The deferral asks that rule (`claimsChain`), so a chain it refuses keeps its finding here.
 *
 * Only an `if` STATEMENT that is a DIRECT child of a statement list, has an `else`, and whose
 * then-branch always exits: the then-branch is itself terminal
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
 * scope's subtree down to the next scope boundary (`ScopeFrames.frameLocalNames`). A conditional region is not
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
			if (tree != null)
				walk(
					violations, entry.file, entry.source, tree, seams,
					RefactorSupport.collectCommentTokens(plugin.lexicalRegions(entry.source))
				);
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
		collectDeNests(tree, source, seams, [], RefactorSupport.collectCommentTokens(plugin.lexicalRegions(source)), flagged, edits, []);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Walk `node`; at each block flag the direct-child `if` statements whose `else`
	 * is redundant. The whole tree is walked so nested blocks are reached.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, seams: Seams,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Void {
		if (seams.support.blockKinds().contains(node.kind))
			for (stmt in node.children)
				if (seams.ifKinds.contains(stmt.kind)) flagIf(out, file, source, stmt, seams, comments);
		for (c in node.children) walk(out, file, source, c, seams, comments);
	}

	/**
	 * Emit one `Info` on the `else` branch of `ifNode` when its then-branch always exits, noting in
	 * the message when a comment the de-nest cannot carry keeps the finding report-only.
	 */
	private static function flagIf(
		out: Array<Violation>, file: String, source: String, ifNode: QueryNode, seams: Seams,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		if (!CheckScan.branchAlwaysExits(ifNode.children[1], seams.support)) return;
		// An else-CHAIN of valued returns is `prefer-if-expression-return`'s, and that rule's single fix
		// IS the canon. De-nesting it here takes the chain away from it: the cascade left behind is
		// collapsed pairwise into a three-rung ternary, which `prefer-if-expression-chain` then unrolls
		// back into the very text one `prefer-if-expression-return` edit would have written — three
		// findings and six passes for one rewrite, and a reader who applies the first is shown a
		// finding the run before it never mentioned. Asked of that rule directly, gates and all, so a
		// chain it refuses (a comment in a folded region) keeps its `redundant-else` finding.
		if (PreferIfExpressionReturn.claimsChain(ifNode, source, comments, seams.shape)) return;
		final elseSpan: Null<Span> = ifNode.children[2].span;
		if (elseSpan != null) out.push({
			file: file,
			span: elseSpan,
			rule: 'redundant-else-after-return',
			severity: Severity.Info,
			message: deNestDropsComment(ifNode, seams.support, comments) ? MESSAGE + COMMENT_NOTE : MESSAGE
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
		return ifSpan != null && thenSpan != null && run != null
			&& comments.exists(tok -> tok.from >= thenSpan.to && tok.to <= ifSpan.to && (tok.to <= run.from || tok.from >= run.to));
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
	 * Mirror `walk`: collect a de-nest edit for each direct-child flagged `if`, threading the
	 * bindings a de-nested local would land beside. `inherited` are the names already bound where
	 * `node` sits; `ScopeFrames` owns the visibility model itself — this walker only threads what
	 * it returns, so `RedundantElse` and `GuardReturn` gate on one shared notion of "already
	 * bound here".
	 */
	private static function collectDeNests(
		node: QueryNode, source: String, seams: Seams, inherited: Array<String>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>, narrowed: Array<String>
	): Void {
		final scopeNames: Array<String> = ScopeFrames.ownScopeNames(node, seams, inherited);
		if (seams.blockKinds.contains(node.kind))
			for (stmt in node.children)
				if (seams.ifKinds.contains(stmt.kind)) deNest(stmt, source, seams, scopeNames, comments, flagged, edits, narrowed);
		final ownParams: Null<Array<String>> = ScopeFrames.ownParamNames(node, seams);
		for (index => c in node.children)
			collectDeNests(
				c, source, seams, ScopeFrames.childScopeNames(node, c, seams, inherited, scopeNames, ownParams), comments, flagged, edits,
				narrowedIn(node, index, seams, narrowed)
			);
	}

	/**
	 * The null-guard subjects holding inside `node`'s child `index`. Entering the THEN branch of an
	 * `if (<subject> != null)` adds that subject; a function boundary drops the whole set, a guard
	 * being unable to reach into a nested body.
	 */
	private static function narrowedIn(node: QueryNode, index: Int, seams: Seams, narrowed: Array<String>): Array<String> {
		if (seams.functionKinds.contains(node.kind)) return [];
		if (index != 1 || !seams.ifKinds.contains(node.kind) || node.children.length == 0) return narrowed;
		final subject: Null<String> = guardSubject(node.children[0], seams);
		return subject == null || narrowed.contains(subject) ? narrowed : narrowed.concat([subject]);
	}

	/** The self-normalised name an `<x> != null` / `null != <x>` condition narrows, or null for any other shape. */
	private static function guardSubject(cond: QueryNode, seams: Seams): Null<String> {
		final node: QueryNode = seams.parenKind != null && cond.kind == seams.parenKind && cond.children.length > 0
			? cond.children[0]
			: cond;
		if (node.kind != seams.notEqKind || node.children.length < 2) return null;
		final left: QueryNode = node.children[0];
		final right: QueryNode = node.children[1];
		if (left.kind == seams.nullLitKind) return receiverName(right, seams);
		return right.kind == seams.nullLitKind ? receiverName(left, seams) : null;
	}

	/** `node` read as a narrowable subject: a bare identifier, or a `this.<name>` field read — both spelling one member. */
	private static function receiverName(node: QueryNode, seams: Seams): Null<String> {
		if (node.kind == seams.identKind) return node.name;
		final self: Null<String> = seams.selfRef;
		return node.kind == seams.fieldAccessKind && self != null && node.children.length > 0 && node.children[0].kind == seams.identKind
			&& node.children[0].name == self
			? node.name
			: null;
	}


	/**
	 * Replace the flagged `if`'s whole span with the else-less `if` plus the
	 * de-nested else body. Skips a scope-unsafe body (`deNestText` returns null).
	 * `scopeNames` are the enclosing-scope bindings the de-nested locals must not collide with.
	 */
	private static function deNest(
		ifNode: QueryNode, source: String, seams: Seams, scopeNames: Array<String>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>, narrowed: Array<String>
	): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		final elseNode: QueryNode = ifNode.children[2];
		final elseSpan: Null<Span> = elseNode.span;
		if (elseSpan == null || !flagged.contains('${elseSpan.from}:${elseSpan.to}')) return;
		if (deNestDropsComment(ifNode, seams.support, comments)) return;
		if (narrowingLapses(ifNode, elseNode, seams, narrowed)) return;
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
		if (ScopeFrames.collidesWithScope(stmts, localDeclKinds, scopeNames)) return null;
		final run: Null<Span> = deNestedRun(elseNode, support);
		return run == null ? null : source.substring(run.from, run.to);
	}


	/**
	 * Whether de-nesting would move a dereference out from under the narrowing that makes it legal.
	 * An `if / else` chain evaluates its else branch in the state the CONDITION left, but a de-nested
	 * statement runs after the whole `if`, and Haxe drops a FIELD's non-null narrowing at the first
	 * call or assignment it cannot see through. So `if (p != null) { if (a) { f(); return; } else
	 * p.length; }` compiles and its de-nested form does not — `Cannot access "length" of a nullable
	 * value`, the two errors that rolled a 190-file `--fix` wave back over one file.
	 *
	 * Three conditions, all structural: a `!= null` guard on `subject` encloses this `if`
	 * (`narrowed`), the KEPT then-branch performs a call / write (with none, the narrowing survives
	 * and the de-nest is fine — measured), and the else body dereferences `subject`. A LOCAL narrows
	 * across the same gap, so this withholds a few fixes it need not; telling a field from a local
	 * needs resolution this check does not have, and the wrong direction here is a build failure.
	 */
	private static function narrowingLapses(ifNode: QueryNode, elseNode: QueryNode, seams: Seams, narrowed: Array<String>): Bool {
		if (narrowed.length == 0 || !subtreeHasKind(ifNode.children[1], seams.resetKinds)) return false;
		return narrowed.exists(subject -> dereferences(elseNode, subject, seams));
	}

	/** Whether `node`'s subtree holds a node of one of `kinds`. */
	private static function subtreeHasKind(node: QueryNode, kinds: Array<String>): Bool {
		return kinds.contains(node.kind) || node.children.exists(child -> subtreeHasKind(child, kinds));
	}

	/** Whether `node`'s subtree reads a member off `subject` — a field access whose receiver is that subject. */
	private static function dereferences(node: QueryNode, subject: String, seams: Seams): Bool {
		if (node.kind == seams.fieldAccessKind && node.children.length > 0 && receiverName(node.children[0], seams) == subject) return true;
		return node.children.exists(child -> dereferences(child, subject, seams));
	}

	/** The node kinds that drop a field's non-null narrowing where the compiler cannot see through them: a call or a write. */
	private static function resetKindsOf(shape: RefShape): Array<String> {
		final out: Array<String> = (shape.writeParentKinds ?? []).copy();
		for (kind in [shape.callKind, shape.assignKind]) if (kind != null && !out.contains(kind)) out.push(kind);
		return out;
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
			shape: shape,
			blockKinds: support.blockKinds(),
			localDeclKinds: shape.localDeclKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			scopeKinds: shape.scopeKinds,
			condKind: shape.conditionalMemberKind,
			identKind: shape.identKind,
			fieldAccessKind: shape.fieldAccessKind,
			notEqKind: shape.notEqKind,
			nullLitKind: shape.nullLiteralKind,
			parenKind: shape.parenKind,
			selfRef: shape.selfReferenceText,
			resetKinds: resetKindsOf(shape)
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

	/** Read by nothing here — handed to `PreferIfExpressionReturn.claimsChain`, which reads its own. */
	final shape: RefShape;
	final blockKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final functionKinds: Array<String>;
	final scopeKinds: Array<String>;
	final condKind: Null<String>;

	/** The `fix` narrowing gate's kinds: the guard shape it recognises and the receivers it compares. */
	final identKind: String;

	final fieldAccessKind: Null<String>;
	final notEqKind: Null<String>;
	final nullLitKind: Null<String>;
	final parenKind: Null<String>;
	final selfRef: Null<String>;

	/** Kinds that drop a field's non-null narrowing when the kept then-branch holds one. */
	final resetKinds: Array<String>;
};

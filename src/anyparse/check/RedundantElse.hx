package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * Only an `if` STATEMENT that is a DIRECT child of a block, has an `else`, and
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
 * ## Autofix
 *
 * `fix` de-nests the `else` body: it replaces the whole `if` statement with the
 * else-less `if` followed by the else body's statements as siblings. The de-nest
 * is skipped (the finding stays report-only) when the else body declares a local
 * (`RefShape.localDeclKinds`): de-nesting would widen that binding into the
 * enclosing scope. An `else if` chain surfaces the inner `else` only after the
 * outer one is de-nested (a later pass), and a nested flagged `if` inside the
 * de-nested run is dropped (`RefactorSupport.dropContainedEdits`) so edits never
 * overlap. Needs `ControlFlowSupport`; unset makes the check report-only. A comment attached to the relocated else body (leading, trailing, or between-branch) is dropped — the de-nested text is rebuilt from statement spans only.
 */
@:nullSafety(Strict)
final class RedundantElse implements Check {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return 'redundant-else-after-return';
	}

	public function description(): String {
		return 'an else after an if branch that always exits (return / throw / break / continue)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final ifKinds: Array<String> = plugin.refShape().ifStatementKinds ?? [];
		if (ifKinds.length == 0) return [];
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, support, ifKinds);
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
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return [];
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectDeNests(tree, source, support, ifKinds, localDeclKinds, flagged, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Walk `node`; at each block flag the direct-child `if` statements whose `else`
	 * is redundant. The whole tree is walked so nested blocks are reached.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, support: ControlFlowSupport, ifKinds: Array<String>
	): Void {
		if (support.blockKinds()
			.contains(node.kind)) for (stmt in node.children) if (ifKinds.contains(stmt.kind)) flagIf(out, file, stmt, support);
		for (c in node.children) walk(out, file, c, support, ifKinds);
	}

	/** Emit one `Info` on the `else` branch of `ifNode` when its then-branch always exits. */
	private static function flagIf(out: Array<Violation>, file: String, ifNode: QueryNode, support: ControlFlowSupport): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		if (!branchAlwaysExits(ifNode.children[1], support)) return;
		final elseSpan: Null<Span> = ifNode.children[2].span;
		if (elseSpan != null) out.push({
			file: file,
			span: elseSpan,
			rule: 'redundant-else-after-return',
			severity: Severity.Info,
			message: 'this else is redundant — the if branch always exits'
		});
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

	/** Mirror `walk`: collect a de-nest edit for each direct-child flagged `if`. */
	private static function collectDeNests(
		node: QueryNode, source: String, support: ControlFlowSupport, ifKinds: Array<String>, localDeclKinds: Array<String>,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (support.blockKinds()
			.contains(node.kind)) for (stmt in node.children) if (ifKinds.contains(stmt.kind))
			deNest(stmt, source, support, localDeclKinds, flagged, edits);
		for (c in node.children) collectDeNests(c, source, support, ifKinds, localDeclKinds, flagged, edits);
	}

	/**
	 * Replace the flagged `if`'s whole span with the else-less `if` plus the
	 * de-nested else body. Skips a scope-unsafe body (`deNestText` returns null).
	 */
	private static function deNest(
		ifNode: QueryNode, source: String, support: ControlFlowSupport, localDeclKinds: Array<String>, flagged: Array<String>,
		edits: Array<{ span: Span, text: String }>
	): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		final elseNode: QueryNode = ifNode.children[2];
		final elseSpan: Null<Span> = elseNode.span;
		if (elseSpan == null || !flagged.contains('${elseSpan.from}:${elseSpan.to}')) return;
		final ifSpan: Null<Span> = ifNode.span;
		final thenSpan: Null<Span> = ifNode.children[1].span;
		if (ifSpan == null || thenSpan == null) return;
		final deNested: Null<String> = deNestText(elseNode, source, support, localDeclKinds);
		if (deNested == null) return;
		final ifKept: String = source.substring(ifSpan.from, thenSpan.to);
		edits.push({ span: new Span(ifSpan.from, ifSpan.to), text: deNested == '' ? ifKept : ifKept + '\n' + deNested });
	}

	/**
	 * The else body's source de-nested to top-level statements: a block's inner
	 * statements (empty block → ''), or a single statement verbatim. Returns null
	 * when the body declares a local (`localDeclKinds`) that would escape its scope.
	 */
	private static function deNestText(
		elseNode: QueryNode, source: String, support: ControlFlowSupport, localDeclKinds: Array<String>
	): Null<String> {
		if (support.blockKinds().contains(elseNode.kind)) {
			final kids: Array<QueryNode> = elseNode.children;
			if (kids.length == 0) return '';
			for (k in kids) if (localDeclKinds.contains(k.kind)) return null;
			final first: Null<Span> = kids[0].span;
			final last: Null<Span> = kids[kids.length - 1].span;
			return first == null || last == null ? null : source.substring(first.from, last.to);
		}
		if (localDeclKinds.contains(elseNode.kind)) return null;
		final s: Null<Span> = elseNode.span;
		return s == null ? null : source.substring(s.from, s.to);
	}

}

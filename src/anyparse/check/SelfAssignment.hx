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

using Lambda;

/**
 * Flags a local variable assigned to itself — `x = x` (SonarLint S1656),
 * typically a typo for `this.x = x` or an edit leftover. `Warning`.
 *
 * ## Why only locals — the setter trap
 *
 * In Haxe `x = x` is NOT always a no-op: when `x` is a field backed by a
 * property setter (`var x(default, set)`), the bare assignment still routes
 * through `set_x` — the `this.` is implicit — so the statement has a real side
 * effect and may be a deliberate "force the setter" idiom. A purely textual
 * `identifier = identifier` check cannot tell that field from a plain local
 * without type information. So `x = x` is flagged ONLY when `x` resolves to a
 * local declaration (`localDeclKinds`) whose enclosing scope contains the
 * assignment: a local can never carry an accessor, so a local self-assignment
 * is a provable no-op. Every field, property, array element (`a[i] = a[i]`) and
 * field-access (`this.x = this.x`) self-assignment is left alone.
 *
 * ## Autofix
 *
 * A local self-assignment is a provable no-op, so `fix` deletes it — but only
 * when it is a standalone block statement (its enclosing block is a
 * `ControlFlowSupport.blockKinds()` node), so a single-statement `if (c) x = x;`
 * body or a `for (x = x; ...)` header is never left dangling. The whole physical
 * line is removed (`lineExtendedSpan`) so the batched `canonicalize` leaves no
 * blank residue.
 *
 * ## Grammar-agnostic
 *
 * The assignment kind comes from `RefShape.assignKind` (unset → no-op), the
 * bare-identifier kind from `RefShape.identKind`, the local-declaration kinds
 * from `RefShape.localDeclKinds`, and scope boundaries from `RefShape.scopeKinds`.
 * The autofix additionally needs `ControlFlowSupport` for the block kinds.
 */
@:nullSafety(Strict)
final class SelfAssignment implements Check {

	public function new() {}

	public function id(): String {
		return 'self-assignment';
	}

	public function description(): String {
		return 'a local variable assigned to itself (x = x)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return [];
		final identKind: String = shape.identKind;
		final scopeKinds: Array<String> = shape.scopeKinds;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final locals: Array<{ name: String, scope: Span, declEnd: Int }> = [];
			final candidates: Array<{ span: Span, name: String }> = [];
			collect(tree, null, entry.source, assignKind, identKind, scopeKinds, opaqueKinds, localDeclKinds, locals, candidates);
			// A candidate binds to a local — never a field that could carry a setter —
			// only when a same-named local declaration encloses it (scope containment)
			// AND lexically precedes it (`declEnd <= use`): before its declaration the
			// name still resolves to the field, so an earlier `x = x` may force `set_x`.
			for (c in candidates) if (locals.exists(
				l -> l.name == c.name && l.scope.from <= c.span.from && c.span.to <= l.scope.to && l.declEnd <= c.span.from
			)) violations.push({
				file: entry.file,
				span: c.span,
				rule: 'self-assignment',
				severity: Severity.Warning,
				message: 'this local variable is assigned to itself'
			});
		}
		return violations;
	}

	/**
	 * Delete each flagged local self-assignment that is a standalone block
	 * statement. The deletion is safe — a local self-assign is a provable no-op —
	 * but is emitted only for a statement whose parent block is a `blockKinds()`
	 * node, so an inline `if (c) x = x;` body (whose removal would leave a
	 * dangling `if`) is left untouched. Needs `ControlFlowSupport`; unset makes
	 * the check report-only.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final assignKind: Null<String> = plugin.refShape().assignKind;
		if (assignKind == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectDeletions(tree, source, support.blockKinds(), assignKind, flagged, edits);
		return edits;
	}

	/**
	 * Walk `node`, tracking the innermost enclosing scope, collecting every local
	 * declaration (`localDeclKinds`, with the span of its enclosing scope) into
	 * `locals` and every `ident = sameIdent` assignment into `candidates`. A
	 * reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function collect(
		node: QueryNode, enclosingScope: Null<QueryNode>, source: String, assignKind: String, identKind: String, scopeKinds: Array<String>,
		opaqueKinds: Array<String>, localDeclKinds: Array<String>, locals: Array<{ name: String, scope: Span, declEnd: Int }>,
		candidates: Array<{ span: Span, name: String }>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (localDeclKinds.contains(node.kind)) {
			final name: Null<String> = node.name;
			final declSpan: Null<Span> = node.span;
			final scope: Null<Span> = enclosingScope != null ? enclosingScope.span : null;
			if (name != null && declSpan != null && scope != null) locals.push({ name: name, scope: scope, declEnd: declSpan.to });
		}
		final span: Null<Span> = node.span;
		if (
			span != null && node.kind == assignKind && node.children.length == 2 && node.children[0].kind == identKind
			&& node.children[1].kind == identKind && RefactorSupport.sameSource(node.children[0], node.children[1], source)
		) {
			final c0: Null<Span> = node.children[0].span;
			if (c0 != null) candidates.push({ span: span, name: source.substring(c0.from, c0.to) });
		}
		final childScope: Null<QueryNode> = scopeKinds.contains(node.kind) ? node : enclosingScope;
		for (c in node.children)
			collect(c, childScope, source, assignKind, identKind, scopeKinds, opaqueKinds, localDeclKinds, locals, candidates);
	}

	/**
	 * Walk `node`; in each `blockKinds` block, for a direct child statement that
	 * wraps exactly one flagged self-assign, emit a whole-line deletion. Only
	 * block-statement position is reached, so the edit is always structurally
	 * valid (the block keeps parsing with one fewer statement).
	 */
	private static function collectDeletions(
		node: QueryNode, source: String, blockKinds: Array<String>, assignKind: String, flagged: Array<String>,
		edits: Array<{ span: Span, text: String }>
	): Void {
		if (blockKinds.contains(node.kind)) for (stmt in node.children) if (
			stmt.children.length == 1 && stmt.children[0].kind == assignKind
		) {
			final a: Null<Span> = stmt.children[0].span;
			final s: Null<Span> = stmt.span;
			if (a != null && s != null && flagged.contains('${a.from}:${a.to}'))
				edits.push({ span: RefactorSupport.lineExtendedSpan(source, s), text: '' });
		}
		for (c in node.children) collectDeletions(c, source, blockKinds, assignKind, flagged, edits);
	}

}

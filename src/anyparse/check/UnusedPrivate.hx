package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags `private` class members (fields / methods) that are never referenced —
 * dead members the formatter cannot remove. The completion of the unused-*
 * family (import -> local -> private member) and the second consumer of the
 * cross-file `SymbolIndex`: a member is only flagged when the index proves its
 * enclosing type confined to its file, so the in-file reference scan sees every
 * possible reference.
 *
 * ## Why both a confinement gate and a text scan
 *
 * A Haxe `private` member is reachable only from its own class — UNLESS a
 * subtype, an `@:access` grant, or an `@:allow` exposes it across files, or a
 * file the parser skipped hides one of those.
 * `RefactorSupport.isPrivateMemberConfined` rules those out (conservatively —
 * any doubt keeps the member). When confined, the member's only possible
 * references live in its declaring file, so a raw word-boundary scan of that
 * file outside the declaration (`RefactorSupport.referencedInRange`) is a
 * complete usage test — the conservative approach `unused-local` / `unused-import`
 * use, erring only toward keeping a live member.
 *
 * ## Implicitly-reachable members are skipped
 *
 * Constructors, property accessors (`get_` / `set_`, reached via `(get, set)`,
 * not by name), and annotation-bearing members (`@:keep`, abstract `@:from` /
 * `@:op`, ...) can be used without an in-source identifier reference. The
 * grammar marks these via `NamedDecl.implicitlyReachable`; the check never flags
 * them — a missed dead member, never a deleted live one. Members reachable only through a framework or macro across files are skipped too: a `static final` macro-force field (`= SomeType`, via `implicitlyReachable`), and a utest `test*` method whose class transitively extends `Test` (via `NamingSupport.frameworkReachable`, resolved through the cross-file index).
 *
 * ## Autofix
 *
 * A flagged member is wholly unreferenced, so deleting a method is always safe
 * and deleting a field is safe when its initializer carries no side effect
 * (`RefactorSupport.isSideEffectFree`); a side-effecting field initializer is
 * reported but left for the author. The member is removed with its modifier /
 * meta group and whole line, batched per file by the caller.
 */
@:nullSafety(Strict)
final class UnusedPrivate implements Check {

	public function new() {}

	public function id(): String {
		return 'unused-private';
	}

	public function description(): String {
		return 'private field/method declared but never referenced';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (decl in support.project(tree)) {
				final v: Null<Violation> = violationFor(entry.file, entry.source, decl, index, support);
				if (v != null) violations.push(v);
			}
		}
		return violations;
	}

	/**
	 * Delete each fixable unused private member. A flagged member is wholly
	 * unreferenced, so a method is always safe to remove and a field is safe when
	 * its initializer has no side effect; a side-effecting field initializer is
	 * skipped (no edit). The member is removed with its modifier / meta group
	 * (`declGroupSpan`) and whole physical line (`lineExtendedSpan`); the caller
	 * batches the edits into one canonicalize per file.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return edits;

		final memberByFrom: Map<Int, { node: QueryNode, parent: QueryNode }> = [];
		collectMembers(tree, memberByFrom);

		for (v in violations) if (v.severity == Severity.Warning) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final hit: Null<{ node: QueryNode, parent: QueryNode }> = memberByFrom[span.from];
			if (hit == null) continue;
			if (!deletableMember(hit.node)) continue;
			final group: Span = RefactorSupport.declGroupSpan(hit.node, hit.parent, span);
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, group), text: '' });
		}
		return edits;
	}

	/**
	 * A `Warning` for `decl` if it is an unreferenced, confined, non-implicitly-
	 * reachable private member, else null. Skips public members, non-members
	 * (types / locals / params), implicitly-reachable members, and any member
	 * whose enclosing type the index cannot prove confined.
	 */
	private static function violationFor(
		file: String, source: String, decl: NamedDecl, index: SymbolIndex, support: NamingSupport
	): Null<Violation> {
		final category: NamingCategory = decl.category;
		if (category != NamingCategory.Field && category != NamingCategory.Method && category != NamingCategory.Constant) return null;
		if (decl.mods.contains('public') || decl.implicitlyReachable == true || support.frameworkReachable(decl, index)) return null;
		final owner: Null<String> = decl.enclosingType;
		final span: Null<Span> = decl.span;
		return owner == null || span == null
			? null
			: !RefactorSupport.isPrivateMemberConfined(owner, source, index)
				? null
				: RefactorSupport.referencedInRange(source, decl.name, 0, source.length, [span]) ? null : {
					file: file,
					span: span,
					rule: 'unused-private',
					severity: Severity.Warning,
					message: 'unused private \'${decl.name}\''
				};
	}

	/**
	 * Whether removing `member`'s declaration drops no behaviour: a method
	 * declaration never executes at its site (always deletable); a field is
	 * deletable only when it has no initializer or a side-effect-free one (its
	 * first child is the initializer expression).
	 */
	private static function deletableMember(member: QueryNode): Bool {
		if (member.kind == 'VarMember' || member.kind == 'FinalMember') {
			final init: Null<QueryNode> = member.children.length > 0 ? member.children[0] : null;
			return init == null || RefactorSupport.isSideEffectFree(init);
		}
		return true;
	}

	/**
	 * Index every field / method member node by its span's `from` offset, each
	 * with its direct parent (the context `declGroupSpan` needs to fold the
	 * member's modifier / meta siblings).
	 */
	private static function collectMembers(node: QueryNode, out: Map<Int, { node: QueryNode, parent: QueryNode }>): Void {
		for (child in node.children) {
			if (RefactorSupport.isFieldMemberKind(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null) out[span.from] = { node: child, parent: node };
			}
			collectMembers(child, out);
		}
	}

}

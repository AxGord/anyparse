package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a class / abstract member declared without an explicit `public` or
 * `private` visibility modifier. Haxe defaults an unmodified member to `private`,
 * so the omission is not a bug — but leaving visibility implicit hides intent, and
 * stating it on every member is a documented project rule. Report-only (`fix`
 * yields no edits): inserting the right keyword at the canonical position is left
 * to a follow-up.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.visibilityContainerKinds` lists the declaration kinds whose members
 * require visibility (a class / abstract — NOT an interface, whose members are
 * implicitly public, nor an enum abstract, whose values are). A member-host kind
 * comes from `RefShape.memberDeclKinds`, the visibility keywords from
 * `RefShape.visibilityModifierKinds`. Any unset → no-op.
 */
@:nullSafety(Strict)
final class MissingVisibility implements Check {

	public function new() {}

	public function id(): String {
		return 'missing-visibility';
	}

	public function description(): String {
		return 'a class / abstract member without an explicit public or private modifier';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		if (containers.length == 0 || members.length == 0 || visibility.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, containers, members, visibility);
		}
		return violations;
	}

	/** Missing-visibility has no autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`; for every visibility-requiring container, flag each member lacking a visibility modifier. */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, containers: Array<String>, members: Array<String>, visibility: Array<String>
	): Void {
		if (containers.contains(node.kind)) flagContainer(out, file, node, members, visibility);
		for (c in node.children) walk(out, file, c, containers, members, visibility);
	}

	/**
	 * Scan `container`'s direct children in source order. Modifier siblings precede
	 * the member they attach to, so a running `sawVisibility` flag — set by a
	 * visibility node, read and reset at each member — tells whether the member that
	 * just appeared had a visibility keyword in its preceding modifier run.
	 */
	private static function flagContainer(
		out: Array<Violation>, file: String, container: QueryNode, members: Array<String>, visibility: Array<String>
	): Void {
		var sawVisibility: Bool = false;
		for (child in container.children) {
			if (visibility.contains(child.kind))
				sawVisibility = true;
			else if (members.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (!sawVisibility && span != null) out.push({
					file: file,
					span: span,
					rule: 'missing-visibility',
					severity: Severity.Warning,
					message: 'member declared without an explicit public or private modifier'
				});
				sawVisibility = false;
			}
		}
	}

}

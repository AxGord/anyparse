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
 * `private` modifier. Haxe defaults an unmodified member to `private`, so the
 * omission is not a bug — but leaving visibility implicit hides intent, and stating
 * it on every member is a documented project rule. `--fix` inserts the default
 * visibility keyword (`private` — the Haxe default, so a behaviour-preserving
 * change) at the canonical position.
 *
 * ## The autofix skips an `override`
 *
 * An unmodified `override` inherits its visibility from the supertype, NOT the
 * class default — forcing `private` on an override of a public method lowers
 * visibility below the superclass, a compile error. Without type information the
 * check cannot know the supertype's visibility, so the autofix leaves an
 * `overrideModifierKind`-bearing member report-only (it is still flagged — explicit
 * visibility is the rule — but the keyword is the author's to choose).
 *
 * ## Grammar-agnostic
 *
 * `RefShape.visibilityContainerKinds` lists the declaration kinds whose members
 * require visibility (a class / abstract — NOT an interface, whose members are
 * implicitly public, nor an enum abstract, whose values are). A member-host kind
 * comes from `RefShape.memberDeclKinds`, the visibility keywords from
 * `RefShape.visibilityModifierKinds`. Any unset → no-op. The autofix additionally
 * needs `RefShape.defaultVisibilityModifierText` (the keyword to insert),
 * `RefShape.modifierOrderKinds` (to place it after `override` / `@:meta` and before
 * `static` / `inline`), and `RefShape.overrideModifierKind` (to exempt overrides);
 * a grammar leaving the keyword unset is report-only.
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

	/**
	 * Insert the default visibility keyword on each flagged non-override member.
	 * Re-parses `source`, re-walks the containers, and for a member whose host-span
	 * `from` matches a violation (and which carries no `overrideModifierKind` in its
	 * run) inserts `defaultVisibilityModifierText` at the canonical visibility slot:
	 * after any `override` / `@:meta`, before the first `static` / `inline` (a run
	 * sibling ranked above visibility in `modifierOrderKinds`), else immediately
	 * before the member host. Inserting the language default is behaviour-preserving
	 * for a non-override (Haxe already treats an unmodified member as `private`). No
	 * default keyword set → report-only.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		final keyword: Null<String> = shape.defaultVisibilityModifierText;
		if (containers.length == 0 || members.length == 0 || visibility.length == 0 || keyword == null) return [];
		final overrideKind: Null<String> = shape.overrideModifierKind;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		var visRank: Int = -1;
		for (v in visibility) {
			final r: Int = order.indexOf(v);
			if (r > visRank) visRank = r;
		}
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		insertWalk(edits, tree, containers, members, order, visRank, keyword, overrideKind, flagged);
		return edits;
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

	/** Walk `node`; insert the keyword on each flagged member of a container. */
	private static function insertWalk(
		edits: Array<{ span: Span, text: String }>, node: QueryNode, containers: Array<String>, members: Array<String>,
		order: Array<String>, visRank: Int, keyword: String, overrideKind: Null<String>, flagged: Array<Int>
	): Void {
		if (containers.contains(node.kind)) insertContainer(edits, node, members, order, visRank, keyword, overrideKind, flagged);
		for (c in node.children) insertWalk(edits, c, containers, members, order, visRank, keyword, overrideKind, flagged);
	}

	/**
	 * Scan `container`'s children; for each flagged member that is not an override,
	 * emit a zero-width insert of `keyword` at its canonical visibility slot.
	 * `insertAt` tracks the start of the first preceding-run sibling ranked above
	 * visibility (`static` / `inline`), and `sawOverride` whether the run carries an
	 * override; both reset at each member. The keyword lands at `insertAt`, else
	 * immediately before the member host — after any `override` / `@:meta`, which
	 * rank at or below visibility.
	 */
	private static function insertContainer(
		edits: Array<{ span: Span, text: String }>, container: QueryNode, members: Array<String>, order: Array<String>, visRank: Int,
		keyword: String, overrideKind: Null<String>, flagged: Array<Int>
	): Void {
		var insertAt: Int = -1;
		var sawOverride: Bool = false;
		for (child in container.children) {
			if (members.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null && !sawOverride && flagged.contains(span.from)) {
					final pos: Int = insertAt >= 0 ? insertAt : span.from;
					edits.push({ span: new Span(pos, pos), text: keyword + ' ' });
				}
				insertAt = -1;
				sawOverride = false;
			} else {
				if (overrideKind != null && child.kind == overrideKind) sawOverride = true;
				if (insertAt < 0 && visRank >= 0 && order.indexOf(child.kind) > visRank) {
					final span: Null<Span> = child.span;
					if (span != null) insertAt = span.from;
				}
			}
		}
	}

}

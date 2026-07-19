package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a class / abstract member declared without an explicit `public` or
 * `private` modifier. Haxe defaults an unmodified member to `private`, so the
 * omission is not a bug — but leaving visibility implicit hides intent, and stating
 * it on every member is a documented project rule. `--fix` inserts the default
 * visibility keyword (`private` — the Haxe default, so a behaviour-preserving
 * change) at the canonical position.
 *
 * ## The autofix resolves an `override` through the SymbolIndex
 *
 * An unmodified `override` inherits its visibility from the supertype, NOT the
 * class default — forcing `private` on an override of a public method lowers
 * visibility below the superclass, a compile error. The autofix instead asks the
 * `SymbolIndex` for the overridden member's declared keyword
 * (`memberVisibilityOf`, which walks the supertype closure and defers through
 * unmarked mid-chain overrides) and inserts THAT keyword. When the index cannot
 * prove one — no index, an unindexed supertype, a simple-name collision that
 * disagrees, or an unmarked non-override base (whose default depends on a
 * public-default container the index does not model) — the member stays
 * report-only (it is still flagged — explicit visibility is the rule — but the
 * keyword is the author's to choose).
 *
 * ## The autofix skips a public-default container
 *
 * An extern class and a `@:publicFields` class default their unmodified members to
 * `public`, not `private` — so inserting `private` there is NOT behaviour-preserving,
 * it lowers visibility. The autofix leaves every member of such a container
 * report-only (still flagged — explicit visibility is the rule — but the keyword is
 * the author's, being `public` rather than the class default). Detection is
 * unchanged; only the fix skips.
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
 * `static` / `inline`), `RefShape.overrideModifierKind` (to route overrides through
 * the index resolution above), and `RefShape.externModifierKind` /
 * `RefShape.publicDefaultMetaNames` (to exempt a public-default container); a
 * grammar leaving the keyword unset is report-only.
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
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, seams.containers, seams.members, seams.visibility);
		}
		return violations;
	}

	/**
	 * Insert the visibility keyword on each flagged member of a private-default
	 * container. Re-parses `source`, re-walks the containers, and for a member whose
	 * host-span `from` matches a violation inserts the keyword at the canonical
	 * visibility slot: after any `override` / `@:meta`, before the first `static` /
	 * `inline` (a run sibling ranked above visibility in `modifierOrderKinds`), else
	 * immediately before the member host. A non-override gets
	 * `defaultVisibilityModifierText` — behaviour-preserving in a plain class /
	 * abstract (Haxe treats an unmodified member there as `private`). An
	 * `overrideModifierKind`-bearing member gets the SUPERTYPE's keyword resolved
	 * through `index.memberVisibilityOf`, or stays report-only when unprovable. A
	 * container whose members are implicitly public — an extern class
	 * (`externModifierKind`) or one carrying a public-default meta
	 * (`publicDefaultMetaNames`, e.g. `@:publicFields`) — is skipped: it stays
	 * report-only rather than being lowered to `private`. No default keyword set →
	 * report-only.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final keyword: Null<String> = seams.keyword;
		if (keyword == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		var visRank: Int = -1;
		for (v in seams.visibility) {
			final r: Int = seams.order.indexOf(v);
			if (r > visRank) visRank = r;
		}
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		insertWalk(
			edits, tree, seams.containers, seams.members, seams.order, visRank, keyword, seams.overrideKind, flagged, seams.externKind,
			seams.publicMetaNames, false, index
		);
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

	/**
	 * Walk `node`; insert the keyword on each flagged member of a container. A container
	 * preceded by an extern modifier or a public-default meta (`@:publicFields`) is skipped
	 * — its members are implicitly public, so inserting `private` would change visibility.
	 * `incomingPublicDefault` carries that skip into a wrapper decl node (Haxe `final class`
	 * projects the class as a `ClassForm` nested in a `FinalDecl`); the returned flag tells a
	 * caller frame a child subtree opened a container, so its own run resets there.
	 */
	private static function insertWalk(
		edits: Array<{ span: Span, text: String }>, node: QueryNode, containers: Array<String>, members: Array<String>,
		order: Array<String>, visRank: Int, keyword: String, overrideKind: Null<String>, flagged: Array<Int>, externKind: Null<String>,
		publicMetaNames: Array<String>, incomingPublicDefault: Bool, index: Null<SymbolIndex>
	): Bool {
		var publicDefault: Bool = incomingPublicDefault;
		var sawDecl: Bool = false;
		for (child in node.children) {
			final metaName: Null<String> = child.name;
			if (externKind != null && child.kind == externKind || metaName != null && publicMetaNames.contains(metaName))
				publicDefault = true;
			final childConsumes: Bool = if (containers.contains(child.kind)) {
				if (!publicDefault) insertContainer(edits, child, members, order, visRank, keyword, overrideKind, flagged, index);
				insertWalk(
					edits, child, containers, members, order, visRank, keyword, overrideKind, flagged, externKind, publicMetaNames, false,
					index
				);
				true;
			} else
				insertWalk(
					edits, child, containers, members, order, visRank, keyword, overrideKind, flagged, externKind, publicMetaNames,
					publicDefault, index
				);
			if (!childConsumes) continue;
			publicDefault = false;
			sawDecl = true;
		}
		return sawDecl;
	}

	/**
	 * Scan `container`'s children; for each flagged member, emit a zero-width insert
	 * at its canonical visibility slot — `keyword` for a plain member, the
	 * index-resolved supertype keyword for an override (none provable → no edit).
	 * `insertAt` tracks the start of the first preceding-run sibling ranked above
	 * visibility (`static` / `inline`), and `sawOverride` whether the run carries an
	 * override; both reset at each member. The keyword lands at `insertAt`, else
	 * immediately before the member host — after any `override` / `@:meta`, which
	 * rank at or below visibility.
	 */
	private static function insertContainer(
		edits: Array<{ span: Span, text: String }>, container: QueryNode, members: Array<String>, order: Array<String>, visRank: Int,
		keyword: String, overrideKind: Null<String>, flagged: Array<Int>, index: Null<SymbolIndex>
	): Void {
		final typeName: Null<String> = container.name;
		var insertAt: Int = -1;
		var sawOverride: Bool = false;
		for (child in container.children) {
			if (members.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null && flagged.contains(span.from)) {
					final memberName: Null<String> = child.name;
					final insert: Null<String> = if (!sawOverride)
						keyword;
					else if (index != null && typeName != null && memberName != null)
						index.memberVisibilityOf(typeName, memberName);
					else
						null;
					if (insert != null) {
						final pos: Int = insertAt >= 0 ? insertAt : span.from;
						edits.push({ span: new Span(pos, pos), text: '$insert ' });
					}
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


	/** Resolve the container / member / visibility seam kinds plus the fix-only autofix seams, or null when any required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		if (containers.length == 0) return null;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (members.length == 0) return null;
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		if (visibility.length == 0) return null;
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		return {
			containers: containers,
			members: members,
			visibility: visibility,
			order: order,
			keyword: shape.defaultVisibilityModifierText,
			overrideKind: shape.overrideModifierKind,
			externKind: shape.externModifierKind,
			publicMetaNames: shape.publicDefaultMetaNames ?? []
		};
	}

}

/** The resolved seams `MissingVisibility` reads in both `run` and `fix`. */
private typedef Seams = {
	final containers: Array<String>;
	final members: Array<String>;
	final visibility: Array<String>;
	final order: Array<String>;
	final keyword: Null<String>;
	final overrideKind: Null<String>;
	final externKind: Null<String>;
	final publicMetaNames: Array<String>;
};

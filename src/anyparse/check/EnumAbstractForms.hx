package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The enum abstracts a grammar does NOT project under its own `RefShape.enumAbstractDeclKind`
 * — the two Haxe spellings that reach the same type through a leading annotation instead of the
 * `enum abstract` keyword pair:
 *
 * - the pre-4.2 form `@:enum abstract A(Int) {}`, still valid (deprecated) in Haxe 4.x;
 * - the cross-version idiom `#if (haxe_ver >= 4.2) enum #else @:enum #end abstract A(Int) {}`,
 *   whose true branch carries the bare `enum` keyword and no metadata at all
 *   (`RefShape.condDeclPrefixKeywordKinds`).
 *
 * Both project as a plain abstract with the marker sitting OUTSIDE its node, in the leading run.
 * Every member rule keys its enum-abstract exemption off the projected kind: a value is
 * implicitly public, is typed by the abstract rather than by its literal, is PascalCase by
 * convention, and is API even when its own file never reads it. Under a plain abstract all four
 * exemptions lapse at once — measured on one real file, `--fix` rewrote 17 values as
 * `private final Default: Int = 39` and then deleted 15 of them as unused privates. The result
 * did not typecheck, and the whole 214-file wave was rolled back over it.
 *
 * The conditional match is deliberately coarse: ANY declaration-prefix keyword the region
 * contributes, not the `enum` one specifically (the kind set names no individual keyword).
 * Restricting the HOSTS to `RefShape.underlyingThisTypeKinds` is what selects the enum case —
 * `final` and `abstract`, the other two keywords, introduce a class, never an abstract — and a
 * shape the restriction lets through costs a finding, never a wrong rewrite. A leading region
 * carrying only UNRELATED annotations contributes nothing and is not a match: those members stay
 * reported.
 *
 * Grammar-agnostic: a grammar with no abstract-like declaration kind, or with neither an
 * enum-abstract meta name nor declaration-prefix keywords, gets an empty answer.
 */
@:nullSafety(Strict)
final class EnumAbstractForms {

	/** Whether `span` starts one of `valueStarts` — the exemption test the member rules share. */
	public static inline function isValue(span: Null<Span>, starts: Array<Int>): Bool {
		return span != null && starts.contains(span.from);
	}

	/**
	 * The span starts of every member declared inside such an abstract. Span starts, not nodes: a
	 * check parses INDEPENDENTLY in `run` and in `fix`, so a node from one walk is never the node
	 * from the other.
	 */
	public static function valueStarts(plugin: GrammarPlugin, tree: QueryNode): Array<Int> {
		final members: Array<String> = plugin.refShape().memberDeclKinds ?? [];
		final out: Array<Int> = [];
		if (members.length == 0) return out;
		for (host in hosts(plugin, tree)) collectMemberStarts(host, members, out);
		return out;
	}

	/** The unprojected enum-abstract declarations of `tree`, in document order. */
	private static function hosts(plugin: GrammarPlugin, tree: QueryNode): Array<QueryNode> {
		final shape: RefShape = plugin.refShape();
		final abstracts: Array<String> = shape.underlyingThisTypeKinds ?? [];
		final prefixKinds: Array<String> = shape.condDeclPrefixKeywordKinds ?? [];
		final metaName: Null<String> = shape.enumAbstractMetaName;
		final out: Array<QueryNode> = [];
		if (abstracts.length == 0 || prefixKinds.length == 0 && metaName == null) return out;
		final leading: Array<String> = CheckScan.modifierKinds(shape).concat(plugin.metaShape().metaKinds);
		collectHosts(tree, {
			condKind: shape.conditionalMemberKind,
			prefixKinds: prefixKinds,
			metaName: metaName,
			abstracts: abstracts,
			leading: leading
		}, out);
		return out;
	}

	/**
	 * Walk `node`'s children in source order, pushing every abstract-like declaration whose
	 * contiguous leading run carries the enum marker. `seams.leading` are the kinds that do NOT end
	 * that run (modifiers and annotations); any other kind ends it, so a marker written for one
	 * declaration cannot reach the next. A conditional region is exempt from ending the run whether
	 * or not it carries the marker — losing the marker there would report a value the next build
	 * makes public.
	 */
	private static function collectHosts(node: QueryNode, seams: Seams, out: Array<QueryNode>): Void {
		var marked: Bool = false;
		for (child in node.children) {
			if (seams.condKind != null && child.kind == seams.condKind) {
				if (carriesEnumMarker(child, seams)) marked = true;
			} else if (seams.metaName != null && child.name == seams.metaName)
				marked = true;
			else if (seams.abstracts.contains(child.kind)) {
				if (marked) out.push(child);
				marked = false;
			} else if (!seams.leading.contains(child.kind))
				marked = false;
			collectHosts(child, seams, out);
		}
	}

	/** Whether `region` holds a declaration-prefix keyword or the enum-abstract meta in any branch. */
	private static function carriesEnumMarker(region: QueryNode, seams: Seams): Bool {
		return seams.prefixKinds.contains(region.kind) || seams.metaName != null && region.name == seams.metaName
			|| region.children.exists(child -> carriesEnumMarker(child, seams));
	}

	/** The span start of every `members`-kind declaration under `node`. */
	private static function collectMemberStarts(node: QueryNode, members: Array<String>, out: Array<Int>): Void {
		for (child in node.children) {
			final span: Null<Span> = child.span;
			if (members.contains(child.kind) && span != null) out.push(span.from);
			collectMemberStarts(child, members, out);
		}
	}

}

/** The resolved seams the host walk threads through every frame — read once per tree. */
private typedef Seams = {

	/** The conditional-compilation region kind, or null when the grammar has none. */
	final condKind: Null<String>;

	/** The declaration-starting keyword kinds such a region may contribute (`RefShape.condDeclPrefixKeywordKinds`). */
	final prefixKinds: Array<String>;

	/** The annotation that makes an abstract an enum abstract (`RefShape.enumAbstractMetaName`). */
	final metaName: Null<String>;

	/** The abstract-like declaration kinds (`RefShape.underlyingThisTypeKinds`). */
	final abstracts: Array<String>;

	/** The kinds a declaration's leading run may hold; any other kind ENDS the run. */
	final leading: Array<String>;
};

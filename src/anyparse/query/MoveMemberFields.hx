package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MoveMember.MemberGroup;
import anyparse.query.MoveMember.MovePrep;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;

using Lambda;

/**
 * Which instance fields a `move-member` group takes along: the ones only its members read or write
 * (`ownedFieldClosure`), and, for the refusal when a field is shared, which staying members keep it.
 */
@:nullSafety(Strict)
@:access(anyparse.query.MoveMember)
final class MoveMemberFields {

	/**
	 * The instance DATA fields the moved members alone own, beyond `names` — a field the moved bodies read or write and
	 * nothing else does — to a fixed point, since a field taken along may initialise from another. Such a field is state
	 * of the moved group, not something to mirror: listing it by hand already moved it, and leaving it out refused the
	 * move ("shared mutable state cannot be mirrored") over a split nothing outside the group could observe.
	 *
	 * Positive and fail-closed: a field qualifies only when every bare reference `Refs` binds to it lies inside a moved
	 * member, no FIELD ACCESS of its name (`this.x`, `other.x`, in any scope file) lies outside them, it is a plain field —
	 * a `var` with no accessor clause (`SourceText.isProperty`: the accessors would stay behind) or a `final` with an
	 * initializer (one without is assigned by the constructor, which stays) — it is not `#if`-guarded, and the destination
	 * declares no member of that name. Anything else stays, and the sibling scan refuses or mirrors it as before.
	 */
	public static function ownedFieldClosure(
		srcDecl: TypeDeclMatch, srcTree: QueryNode, srcSource: String, names: Array<String>, destDecl: TypeDeclMatch, destSource: String,
		trees: Map<String, QueryNode>, plugin: GrammarPlugin
	): Array<String> {
		final shape: RefShape = plugin.refShape();
		final all: Array<MemberGroup> = MoveMember.membersOf(srcDecl, srcSource, shape, plugin.lexicalRegions);
		final regions: Array<LexRegion> = plugin.lexicalRegions(srcSource);
		final added: Array<String> = [];
		while (true) {
			final cuts: Array<Span> = [
				for (g in all) if (names.contains(g.member.name ?? '') || added.contains(g.member.name ?? ''))
					ElementSpan.memberCutSpan(srcSource, g.groupSpan, regions)
			];
			final slices: String = [for (c in cuts) srcSource.substring(c.from, c.to)].join('\n');
			final candidates: Array<MemberGroup> = all.filter(g -> {
				final nm: String = g.member.name ?? '';
				return nm != '' && !names.contains(nm) && !added.contains(nm) && slices.indexOf(nm) != -1
					&& ownableField(g, srcDecl, srcSource, destDecl, destSource, plugin);
			});
			final owned: Array<String> = ownedBy(candidates, cuts, srcTree, trees, shape);
			if (owned.length == 0) break;
			for (nm in owned) added.push(nm);
		}
		return added;
	}

	/**
	 * Which members staying on the source also reach the `fields` a moved body reads — the reason they were not moved
	 * along (`ownedFieldClosure`) — as a clause for the refusal, or '' when no bare reference names a staying member (the
	 * field is then kept by a field access elsewhere, a destination member of its name, or its shape).
	 */
	public static function stayingReadersNote(prep: MovePrep, fields: Array<String>, plugin: GrammarPlugin): String {
		final members: Array<MemberGroup> = MoveMember.membersOf(prep.srcDecl, prep.srcSource, prep.shape, plugin.lexicalRegions);
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(fields, prep.srcTree, prep.shape);
		final readers: Array<String> = [];
		for (field in fields) for (h in hitsByName[field] ?? []) if (
			h.kind != RefKind.Decl && !MoveMember.insideAnyCut(prep, h.span.from)
		) {
			final holder: Null<MemberGroup> = members.find(g -> h.span.from >= g.groupSpan.from && h.span.from < (g.member.span?.to ?? -1));
			final name: Null<String> = holder?.member.name;
			if (name != null && name != field) MoveMember.pushUnique(readers, name);
		}
		return readers.length == 0 ? '' : ' — staying member(s) ${MoveMember.quoted(readers)} use them too; move those along';
	}

	/**
	 * Whether `g` has the SHAPE of a field a moved group may take along (`ownedFieldClosure`): a non-static `var` with no
	 * accessor clause or a non-static `final` with an initializer, outside every `#if` region, that the destination does
	 * not declare a member of the same name for.
	 */
	private static function ownableField(
		g: MemberGroup, srcDecl: TypeDeclMatch, srcSource: String, destDecl: TypeDeclMatch, destSource: String, plugin: GrammarPlugin
	): Bool {
		final span: Null<Span> = g.member.span;
		final name: Null<String> = g.member.name;
		if (span == null || name == null || g.modifiers.exists(m -> m.kind == 'Static')) return false;
		final plain: Bool = if (MoveMember.FINAL_FIELD_KINDS.contains(g.member.kind))
			g.member.children.length > 0
		else if (MemberKinds.isDataFieldKind(g.member.kind)) {
			final at: Int = SourceText.identTokenOffset(srcSource, span, name);
			at >= 0 && !SourceText.isProperty(srcSource, at + name.length);
		} else
			false;
		final shape: RefShape = plugin.refShape();
		return plain && !MemberBranchScan.isGuardedMember(srcDecl, shape, srcSource, g.member, plugin.lexicalRegions.bind(srcSource))
			&& MoveMember.memberGroupOf(destDecl, name, destSource, shape, plugin.lexicalRegions) == null;
	}

	/**
	 * The `candidates` only the code inside `cuts` reaches: at least one bare reference bound to the field, every one of
	 * them inside a cut, and no field access of its name outside them in any scope file (`accessedOutside`).
	 */
	private static function ownedBy(
		candidates: Array<MemberGroup>, cuts: Array<Span>, srcTree: QueryNode, trees: Map<String, QueryNode>, shape: RefShape
	): Array<String> {
		if (candidates.length == 0) return [];
		function inside(at: Int): Bool return cuts.exists(c -> at >= c.from && at < c.to);
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti([for (c in candidates) c.member.name ?? ''], srcTree, shape);
		final out: Array<String> = [];
		for (c in candidates) {
			final nm: String = c.member.name ?? '';
			final declAt: Int = c.member.span?.from ?? -1;
			final bound: Array<RefHit> = (hitsByName[nm] ?? []).filter(h -> h.kind != RefKind.Decl && h.bindingSpan?.from == declAt);
			if (bound.length > 0 && bound.foreach(h -> inside(h.span.from)) && !accessedOutside(nm, trees, srcTree, inside)) out.push(nm);
		}
		return out;
	}

	/**
	 * Whether any scope file reaches a field named `name` through a FIELD ACCESS outside the moved members (`inside`
	 * answers for offsets of the source tree): `this.x`, or `o.x` on any receiver — not proven to be another type's, so
	 * read as a reader of this one.
	 */
	private static function accessedOutside(name: String, trees: Map<String, QueryNode>, srcTree: QueryNode, inside: Int -> Bool): Bool {
		function walk(node: QueryNode, inSource: Bool): Bool {
			final span: Null<Span> = node.span;
			if (node.kind == MemberKinds.FIELD_ACCESS_KIND && node.name == name && span != null && !(inSource && inside(span.from)))
				return true;
			return node.children.exists(c -> walk(c, inSource));
		}
		return Lambda.exists(trees, tree -> walk(tree, tree == srcTree));
	}

}

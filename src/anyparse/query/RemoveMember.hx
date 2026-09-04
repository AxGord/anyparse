package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.runtime.ParseError;
import haxe.Exception;

using Lambda;

/**
 * Remove a member from a class / interface / abstract / enum / typedef by
 * name — the by-name convenience over cursor-based `RemoveElement`, sister
 * to `add-member`. `typeName` selects the enclosing type (resolved through
 * the final-aware `RefactorSupport.typeDeclOf`, so a `final class` is
 * found); `memberName` the member within it (a field or method —
 * `FIELD_MEMBER_KINDS`). `typeName` must resolve to EXACTLY ONE node.
 *
 * `memberName` may resolve to SEVERAL: declarations of one name spread over
 * conditional-compilation regions are the same logical member — the rule
 * `rename` already applies — and every one of them is removed. A region that
 * loses ALL its members is removed with its directives; a region nested
 * inside one that is already going is left to the outer removal, since two
 * nesting deletion spans would corrupt the file rather than compose.
 *
 * Outside a conditional region a name cannot legally repeat, so a match set
 * that is not wholly conditional means the source is already rejected by the
 * compiler; that stays an `Err` rather than being quietly laundered. The
 * check is region-level, not branch-level — the tree flattens a region's
 * branches into one child list — so two declarations inside the SAME branch,
 * equally illegal, are removed rather than refused.
 *
 * ## The doc comment goes with the member
 *
 * A leading doc block is trivia OUTSIDE the member node span, so removing only the
 * declaration left it behind — where it silently became the documentation of the next
 * one. It goes too, through `RefactorSupport.docExtendedSpan`: the same region `set-doc`
 * replaces and `move-member` carries, not a second notion of it. Pass `withDoc = false`
 * (`--keep-doc`) to opt out. Four boundaries, decided:
 *
 * - NO doc: only code or whitespace precedes, the span comes back unchanged, and the
 *   removal is byte-for-byte what it always was.
 * - A comment TRAILING the previous declaration, on the line of that declaration, is NOT
 *   taken. It ends just above the victim and is exactly as adjacent as a real doc, so
 *   adjacency cannot tell them apart; the line it OPENS on can, and that decides.
 * - A `@:meta` / modifier group between the doc and the declaration is already folded in
 *   by `declGroupSpan`, which the doc region is measured from — so the doc above
 *   `@:keep public static` is found, not the gap under it.
 * - `#if` guards: a doc INSIDE the region goes with the member; a doc written ABOVE the
 *   guard goes with the region on the removal that empties it. A region with a surviving
 *   branch keeps its directives and the doc of that branch.
 *
 * A plain non-doc block is never absorbed at all on this path. Directly above a
 * declaration it is a licence header or a section banner far more often than it is
 * documentation, and unlike `move-member` — which carries the region it absorbs and so
 * loses nothing by guessing wrong — a removal cannot give it back. So the deleting
 * callers pass `docOnly` and `/**` is the proof; `move-member` and `set-doc` keep the
 * generous reading.
 */
@:nullSafety(Strict)
final class RemoveMember {

	/**
	 * Remove every declaration named `memberName` of the type named `typeName`,
	 * with its modifier / `@:meta` group and its leading doc comment. `reformat`
	 * opts into a whole-file canonicalisation when the source is not already
	 * writer-canonical; `withDoc = false` keeps the doc. Returns `Ok(rewritten)`
	 * or an `Err`.
	 */
	public static function removeMember(
		source: String, typeName: String, memberName: String, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true,
		?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final typeNode: Null<QueryNode> = findType(tree, typeName);
		if (typeNode == null) return Err('no type named "$typeName" found');

		final members: Array<{ node: QueryNode, parent: QueryNode }> = [];
		collectMembers(typeNode, memberName, members);
		if (members.length == 0) return Err('no member named "$memberName" in type "$typeName"');

		final condKind: Null<String> = plugin.refShape().conditionalMemberKind;
		// Several declarations of one name are the SAME logical member spread over conditional
		// branches — the rule `rename` already applies — so all of them go. Outside a branch the
		// name cannot legally repeat, so a second UNGUARDED declaration means the source is already
		// rejected by the compiler; deleting both would quietly launder that, and the refusal names
		// it instead.
		if (members.length > 1 && members.exists(m -> condKind == null || m.parent.kind != condKind))
			return Err('ambiguous — "$memberName" matches ${members.length} members in "$typeName", not all conditional');

		final targets: Array<{ node: QueryNode, parent: Null<QueryNode> }> = [];
		final regionsTaken: Array<QueryNode> = [];
		for (hit in members) {
			// A region left with NO member takes its directives with it. The leftover
			// `#if` / `#else` / `#end` is syntax the Haxe compiler accepts, that this parser now
			// accepts too (the member-position empty-region slice) and that the writer re-emits
			// verbatim — so the husk no longer breaks the re-parse gate; it is simply a directive
			// pair that guards nothing, which nothing else would ever clean up. Counting what the
			// region still HOLDS after this call — not whether this member is its only one — is what
			// covers the branch pair, where the region holds two members and loses both.
			//
			// `MemberBranchScan.regionMembers` is what "holds" means, shared with the deletion
			// checks' `survivingDeletions` so the two cannot drift: it reaches through every branch
			// AND through a nested region, because a member of an inner region is a member of the
			// outer one too. That is why the walk climbs — emptying `#if a #if b f #end #end` of `f`
			// empties both regions, and stopping at the inner one leaves the outer husk behind.
			final region: QueryNode = hit.parent;
			final taken: Null<{ node: QueryNode, parent: QueryNode }> = emptiedRegionTarget(typeNode, region, members, condKind);
			if (taken == null) {
				targets.push({ node: hit.node, parent: region });
				continue;
			}
			if (regionsTaken.contains(taken.node)) continue;
			regionsTaken.push(taken.node);
			targets.push({ node: taken.node, parent: taken.parent });
		}
		// Nested regions (`#if a f #if b f #end #end`) put a target inside a target; `deleteNodes`
		// keeps the outer one, which removes the inner anyway.
		return ElementSpan.deleteNodes(source, targets, reformat, plugin, withDoc, optsJson);
	}

	/** The node whose `typeDeclOf().name == typeName`, first in pre-order. */
	private static function findType(tree: QueryNode, typeName: String): Null<QueryNode> {
		var result: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (result != null) return;
			final m: Null<RefactorSupport.TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) {
				result = node;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return result;
	}

	/**
	 * Collect field / method member nodes named `memberName` in `typeNode`'s
	 * subtree, each with its direct parent (the context `declGroupSpan` needs
	 * to fold the member's modifier / meta siblings). The whole subtree is
	 * walked so a `final class`'s members (under the inner `ClassForm`) are
	 * reached as well as a plain class's direct children; locals are never
	 * matched because they carry statement kinds, not `FIELD_MEMBER_KINDS`.
	 */
	private static function collectMembers(node: QueryNode, memberName: String, out: Array<{ node: QueryNode, parent: QueryNode }>): Void {
		MemberKinds.eachMemberHost(node, host -> for (child in host.children) if (
			MemberKinds.isFieldMemberKind(child.kind) && child.name == memberName
		)
			out.push({ node: child, parent: host }));
	}

	/**
	 * The OUTERMOST conditional region that removing every member in `deleting` would leave with
	 * no member declaration at all, paired with the member host that holds it — or null when
	 * `region` keeps a member, or is not a conditional region, in which case only the member goes.
	 *
	 * The walk climbs because regions nest: a member of an inner region is a member of the outer
	 * one too, so emptying `#if a #if b f #end #end` of `f` empties both, and stopping at the
	 * inner one leaves the outer directives behind guarding nothing.
	 * `MemberBranchScan.regionMembers` is what "holds" means here — the same count the deletion
	 * checks' `survivingDeletions` uses, so the two answers cannot drift.
	 */
	private static function emptiedRegionTarget(
		typeNode: QueryNode, region: QueryNode, deleting: Array<{ node: QueryNode, parent: QueryNode }>, condKind: Null<String>
	): Null<{ node: QueryNode, parent: QueryNode }> {
		if (condKind == null || region.kind != condKind) return null;
		var result: Null<{ node: QueryNode, parent: QueryNode }> = null;
		var cur: Null<QueryNode> = region;
		while (cur != null) {
			final scope: QueryNode = cur;
			final held: Array<QueryNode> = MemberBranchScan.regionMembers(scope, n -> MemberKinds.isFieldMemberKind(n.kind));
			if (held.length == 0 || held.exists(n -> !deleting.exists(m -> m.node == n))) break;
			var host: Null<QueryNode> = null;
			MemberKinds.eachMemberHost(typeNode, h -> if (h.children.contains(scope)) host = h);
			if (host == null) break;
			final owner: QueryNode = host;
			result = { node: scope, parent: owner };
			cur = owner.kind == condKind ? owner : null;
		}
		return result;
	}

}

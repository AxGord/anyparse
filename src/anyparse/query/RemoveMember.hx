package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
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
 * A plain non-doc block above the doc — a licence header, a section banner — is never
 * reached: the adjacent block is absorbed, then only further doc blocks above it.
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
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
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
			// A region left with NO member takes its directives with it: cutting only the members
			// leaves the bare `#if` / `#else` / `#end` behind — syntax that compiles, that the writer
			// re-emits verbatim, and that no check reports. Counting what the region still HOLDS after
			// this call — not whether this member is its only one — is what covers the branch pair,
			// where the region holds two members and loses both.
			final region: QueryNode = hit.parent;
			final held: Array<QueryNode> = region.children.filter(n -> RefactorSupport.isFieldMemberKind(n.kind));
			final losing: Int = members.count(m -> m.parent == region);
			if (condKind == null || region.kind != condKind || held.length != losing) {
				targets.push({ node: hit.node, parent: region });
				continue;
			}
			if (regionsTaken.contains(region)) continue;
			var regionHost: Null<QueryNode> = null;
			RefactorSupport.eachMemberHost(typeNode, host -> if (host.children.contains(region)) regionHost = host);
			if (regionHost == null)
				targets.push({ node: hit.node, parent: region });
			else {
				regionsTaken.push(region);
				targets.push({ node: region, parent: regionHost });
			}
		}
		// Nested regions (`#if a f #if b f #end #end`) put a target inside a target; `deleteNodes`
		// keeps the outer one, which removes the inner anyway.
		return RefactorSupport.deleteNodes(source, targets, reformat, plugin, withDoc, optsJson);
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
		RefactorSupport.eachMemberHost(node, host -> for (child in host.children) if (
			RefactorSupport.isFieldMemberKind(child.kind) && child.name == memberName
		)
			out.push({ node: child, parent: host }));
	}

}

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
 * `FIELD_MEMBER_KINDS`). Each must resolve to EXACTLY ONE node; zero or many
 * is an `Err`. The member is removed with its modifier / meta group through
 * `RefactorSupport.deleteNode`.
 */
@:nullSafety(Strict)
final class RemoveMember {

	/**
	 * Remove the member named `memberName` of the type named `typeName`.
	 * `reformat` opts into a whole-file canonicalisation when the source is
	 * not already writer-canonical. Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function removeMember(
		source: String, typeName: String, memberName: String, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = false,
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
		if (members.length > 1) return Err('ambiguous — "$memberName" matches ${members.length} members in "$typeName"');

		final hit: { node: QueryNode, parent: QueryNode } = members[0];
		// A member that is the ONLY declaration of its `#if` region takes the region with it: cutting
		// just the member leaves the bare directives behind — syntax that compiles, that the writer
		// re-emits verbatim, and that no check reports. A region with a declaration in ANOTHER branch
		// keeps its directives, since the remaining branch still needs them.
		final condKind: Null<String> = plugin.refShape().conditionalMemberKind;
		final region: QueryNode = hit.parent;
		final held: Array<QueryNode> = region.children.filter(n -> RefactorSupport.isFieldMemberKind(n.kind));
		if (condKind == null || region.kind != condKind || held.length != 1)
			return RefactorSupport.deleteNode(source, hit.node, region, reformat, plugin, withDoc, optsJson);
		var regionHost: Null<QueryNode> = null;
		RefactorSupport.eachMemberHost(typeNode, host -> if (host.children.contains(region)) regionHost = host);
		return regionHost == null
			? RefactorSupport.deleteNode(source, hit.node, region, reformat, plugin, withDoc, optsJson)
			: RefactorSupport.deleteNode(source, region, regionHost, reformat, plugin, withDoc, optsJson);
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

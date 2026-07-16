package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** One scope file parsed once. */
private typedef Parsed = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

/**
 * `safe-delete` — remove a member ONLY when it is provably unreferenced
 * across a scope. The guarded form of `remove-member` (and the cross-file,
 * any-visibility generalisation of the `unused-private` / `unused-local`
 * `lint --fix`): it scans every `.hx` under the scope for a reference to
 * the member and refuses the deletion when one exists, listing where.
 *
 * ## Correctness model — refuse on any doubt
 *
 * A reference is counted CONSERVATIVELY (the opposite bias to `rename`,
 * which rewrites only proven bindings): ANY `x.member` field access (of
 * any receiver type) and any bare in-declaring-type reference that binds
 * to the declaration counts. Self-references inside the member's own body
 * (recursion) do not. So a member whose name is also used as a field on an
 * UNRELATED type is kept — a false refusal, never a wrong deletion. When
 * the count is zero the member is removed through `RemoveMember`
 * (canonical-gated; `reformat` re-canonicalises a drifted file).
 *
 * Overrides / interface implementations of the member in other types are
 * not treated as references — deleting a base member that a subclass still
 * overrides is a LOUD compile error, never a silent change; the advisory
 * says so.
 */
@:nullSafety(Strict)
final class SafeDelete {

	/**
	 * Remove `memberName` of `srcTypeName` from `srcFile` when no reference
	 * to it survives under `scopeFiles`. Returns `Ok(newSource)` for
	 * `srcFile`, or an `Err` — a reference list when blocked, or a
	 * resolution / removal diagnostic. PURE.
	 */
	public static function safeDelete(
		srcFile: String, srcTypeName: String, memberName: String, reformat: Bool, scopeFiles: Array<{ file: String, source: String }>,
		plugin: GrammarPlugin, refShape: RefShape
	): EditResult {
		final parsed: Array<Parsed> = [];
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: Exception) null;
			if (tree == null) return Err('cannot check references: ${entry.file} does not parse');
			final treeNN: QueryNode = tree;
			parsed.push({ file: entry.file, source: entry.source, tree: treeNN });
		}

		final srcEntry: Null<Parsed> = parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Err('source file $srcFile is not in the scope file set');
		final src: Parsed = srcEntry;
		final memberSpan: Null<Span> = memberSpanOf(src.tree, srcTypeName, memberName);
		if (memberSpan == null) return Err('no member "$memberName" on a unique type "$srcTypeName" in $srcFile');
		final memberSpanNN: Span = memberSpan;

		final refs: Array<{ file: String, count: Int }> = collectReferences(parsed, srcFile, memberName, memberSpanNN, refShape);
		if (refs.length > 0) {
			final where: String = [for (r in refs) '${r.file} (${r.count})'].join(', ');
			return Err('"$memberName" is still referenced — refusing to delete: $where');
		}

		return RemoveMember.removeMember(src.source, srcTypeName, memberName, reformat, plugin, true);
	}

	/**
	 * The span of the member `memberName` declared by the sole type
	 * `typeName` in `tree` (final-aware), or null when the type or member is
	 * absent / ambiguous.
	 */
	private static function memberSpanOf(tree: QueryNode, typeName: String, memberName: String): Null<Span> {
		final decls: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) decls.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		if (decls.length != 1) return null;
		for (child in decls[0].nameNode.children) if (RefactorSupport.isFieldMemberKind(child.kind) && child.name == memberName)
			return child.span;
		return null;
	}

	/**
	 * The per-file reference counts of `memberName` across the scope: every
	 * `x.member` field access (any receiver), plus — in the declaring file —
	 * every bare reference the scope resolver binds to the declaration.
	 * References inside the member's own body span (`memberSpan`, `srcFile`
	 * only) are excluded so recursion does not block deletion.
	 */
	private static function collectReferences(
		parsed: Array<Parsed>, srcFile: String, memberName: String, memberSpan: Span, refShape: RefShape
	): Array<{ file: String, count: Int }> {
		final out: Array<{ file: String, count: Int }> = [];
		for (entry in parsed) {
			final inSrc: Bool = entry.file == srcFile;
			var count: Int = 0;
			function walk(node: QueryNode): Void {
				if (node.kind == 'FieldAccess' && node.name == memberName) {
					final span: Null<Span> = node.span;
					if (span != null && !(inSrc && span.from >= memberSpan.from && span.from < memberSpan.to)) count++;
				}
				for (c in node.children) walk(c);
			}
			walk(entry.tree);
			if (inSrc) for (h in Refs.find(memberName, entry.tree, refShape)) if (h.kind != RefKind.Decl) {
				final b: Null<Span> = h.bindingSpan;
				if (b == null || b.from != memberSpan.from) continue;
				if (h.span.from >= memberSpan.from && h.span.from < memberSpan.to) continue;
				count++;
			}
			if (count > 0) out.push({ file: entry.file, count: count });
		}
		return out;
	}

}

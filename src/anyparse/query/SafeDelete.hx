package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.QualifiedReceiver.ReceiverTarget;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.ValueNameBinding.ImportedStatic;
import anyparse.query.ValueNameBinding.ImportedStatics;
import anyparse.runtime.Span;

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
	 *
	 * `optsJson` is the formatter config that governs `srcFile`, and it is the
	 * SAME argument every sibling writer-emit op takes: the removal is
	 * canonical-gated, so without it the gate compares the file against
	 * COMPILED DEFAULTS and refuses every file a project config formats
	 * differently from them — with the one remedy it names (`apq fmt --write`)
	 * being the thing that put the file in that state. `--reformat` had the
	 * mirror defect: it re-canonicalised under the defaults, i.e. de-formatted
	 * the file it was asked to edit.
	 */
	public static function safeDelete(
		srcFile: String, srcTypeName: String, memberName: String, reformat: Bool, scopeFiles: Array<{ file: String, source: String }>,
		plugin: GrammarPlugin, refShape: RefShape, ?optsJson: String
	): EditResult {
		final parsed: Array<Parsed> = [];
		for (entry in scopeFiles) {
			final tree: QueryNode = switch ParseGate.parse(plugin, entry.source, entry.file) {
				case Unparsed(_): return Err('cannot check references: ${entry.file} does not parse');
				case Parsed(read): read;
			};
			parsed.push({ file: entry.file, source: entry.source, tree: tree });
		}

		final srcEntry: Null<Parsed> = parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Err('source file $srcFile is not in the scope file set');
		final src: Parsed = srcEntry;
		final memberSpan: Null<Span> = memberSpanOf(
			src.tree, srcTypeName, memberName, src.source, refShape, plugin.lexicalRegions.bind(src.source)
		);
		if (memberSpan == null) return Err('no member "$memberName" on a unique type "$srcTypeName" in $srcFile');
		final memberSpanNN: Span = memberSpan;

		// An unparsed conditional-compilation region projects no nodes, so `collectReferences` reads
		// "unreferenced" over one that mentions the member - the exact false ABSENCE this op deletes on.
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionInAny(parsed, memberName, refShape, 'delete of "$memberName"');
		if (opaque != null) return Err(opaque);

		final refs: Array<{ file: String, count: Int }> = collectReferences(
			parsed, srcFile, memberName, memberSpanNN, refShape, plugin, IndexScope.lazySymbolIndex(scopeFiles, plugin)
		);
		if (refs.length <= 0) return RemoveMember.removeMember(src.source, srcTypeName, memberName, reformat, plugin, true, optsJson);
		final where: String = [for (r in refs) '${r.file} (${r.count})'].join(', ');
		return Err('"$memberName" is still referenced — refusing to delete: $where');
	}

	/**
	 * Why `memberName`, declared at `memberSpan` of `srcFile`, cannot be removed from that file alone: a reference to it from
	 * another file of `scopeFiles` (counted as `safeDelete` counts), a file of the scope that does not parse, or an unparsed
	 * conditional region naming it. Null when no other file can reach it. Files are compared by `FileIdentity`, and a file whose
	 * text never spells the name is not parsed. `index` resolves the receivers of those references, over `scopeFiles` when
	 * omitted.
	 */
	public static function foreignReferenceRefusal(
		scopeFiles: Array<{ file: String, source: String }>, srcFile: String, memberName: String, memberSpan: Span, plugin: GrammarPlugin,
		refShape: RefShape, ?index: () -> Null<SymbolIndex>
	): Null<String> {
		final self: String = FileIdentity.realPath(srcFile);
		final parsed: Array<Parsed> = [];
		for (entry in scopeFiles) if (entry.source.indexOf(memberName) >= 0 && FileIdentity.realPath(entry.file) != self) {
			final tree: QueryNode = switch ParseGate.parse(plugin, entry.source, entry.file) {
				case Unparsed(_): return 'cannot check references: ${entry.file} does not parse';
				case Parsed(read): read;
			};
			parsed.push({ file: entry.file, source: entry.source, tree: tree });
		}
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionInAny(parsed, memberName, refShape, 'removing "$memberName"');
		if (opaque != null) return opaque;
		final refs: Array<{ file: String, count: Int }> = collectReferences(
			parsed, srcFile, memberName, memberSpan, refShape, plugin, index ?? IndexScope.lazySymbolIndex(scopeFiles, plugin)
		);
		return refs.length <= 0
			? null
			: '"$memberName" is referenced from another file: ' + [for (r in refs) '${r.file} (${r.count})'].join(', ');
	}

	/**
	 * The span of the member `memberName` declared by the sole type
	 * `typeName` in `tree` (final-aware), or null when the type or member is
	 * absent / ambiguous.
	 */
	private static function memberSpanOf(
		tree: QueryNode, typeName: String, memberName: String, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Null<Span> {
		final decl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(tree, typeName);
		if (decl == null) return null;
		var hit: Null<Span> = null;
		// Branch-aware: a member a `#if` region declares is not a direct child of the type. The delete
		// cuts it in place, inside that region.
		MemberBranchScan.eachTypeMember(decl, shape, source, n -> MemberKinds.isFieldMemberKind(n.kind), (child, _) -> {
			if (hit == null && child.name == memberName) hit = child.span;
		}, regions);
		return hit;
	}

	/**
	 * The per-file reference counts of `memberName` across the scope: every
	 * `x.member` field access whose receiver is not proven to name another
	 * type declaring its own `memberName` (`QualifiedReceiver`, read through
	 * `index`), plus — in the declaring file — every bare reference the scope
	 * resolver binds to the declaration; in every other file, the references
	 * its imports make (`importedReferences`). References inside the member's own
	 * body span (`memberSpan`, `srcFile` only) are excluded so recursion does
	 * not block deletion.
	 */
	private static function collectReferences(
		parsed: Array<Parsed>, srcFile: String, memberName: String, memberSpan: Span, refShape: RefShape, plugin: GrammarPlugin,
		index: () -> Null<SymbolIndex>
	): Array<{ file: String, count: Int }> {
		final out: Array<{ file: String, count: Int }> = [];
		for (entry in parsed) {
			final inSrc: Bool = entry.file == srcFile;
			final receivers: QualifiedReceiver = new QualifiedReceiver(
				entry.file, entry.source, plugin, refShape, memberSpan.from, srcFile, index
			);
			var count: Int = 0;
			function walk(node: QueryNode): Void {
				if (node.kind == 'FieldAccess' && node.name == memberName) {
					final span: Null<Span> = node.span;
					if (
						span != null
						&& !(inSrc && span.from >= memberSpan.from && span.from < memberSpan.to)
						&& !(node.children.length > 0 && receivers.read(node.children[0], memberName) == OtherType)
					)
						count++;
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
			if (!inSrc) count += importedReferences(entry, memberName, memberSpan, srcFile, refShape, index);
			if (count > 0) out.push({ file: entry.file, count: count });
		}
		return out;
	}

	/**
	 * The references `entry`, a file other than the declaring one, makes to the member through its imports
	 * (`ValueNameBinding.importedStatics`): its statement naming the member (`import p.T.m;`), and each bare use no in-file
	 * declaration binds while an import may bring the member in (`import p.T.*;`), plus each alias of it. A static the imports
	 * bind to another type's own declaration does not count, one whose owner the index does not hold does. With no index
	 * entry for the file, every unbound bare use counts, and every import statement of its own tree naming the member.
	 */
	private static function importedReferences(
		entry: Parsed, memberName: String, memberSpan: Span, srcFile: String, refShape: RefShape, index: () -> Null<SymbolIndex>
	): Int {
		if (entry.source.indexOf(memberName) < 0) return 0;
		final unbound: Int = [
			for (h in Refs.find(memberName, entry.tree, refShape)) if (h.kind != RefKind.Decl && h.bindingSpan == null) h
		].length;
		final idx: Null<SymbolIndex> = index();
		final fi: Null<FileInfo> = idx?.fileInfo(entry.file) ?? idx?.allFiles().find(f -> FileIdentity.same(f.file, entry.file));
		if (idx == null || fi == null) return unbound + importsNaming(entry, memberName);
		final reaches: ImportedStatic -> Bool = s ->
			s.member == memberName
				&& (s.decls.length == 0
					|| s.decls.exists(
						d ->
							FileIdentity.same(d.file.file, srcFile)
							&& d.type.span.from <= memberSpan.from
							&& memberSpan.from < d.type.span.to
					));
		final statics: ImportedStatics = idx.values.importedStatics(fi, memberName);
		var count: Int = 0;
		if (statics.unknown || statics.statics.exists(reaches)) count += unbound + (idx.fileImportsMemberName(fi.file, memberName) ? 1 : 0);
		for (a in idx.values.fieldAliases(fi)) {
			final target: Null<ImportedStatic> = a.target;
			if (target == null || reaches(target)) count++;
		}
		return count;
	}

	/**
	 * The import statements of `entry`'s own tree whose path, or aliased path, ends in `memberName` — read off the syntax
	 * alone, for a file the index does not hold: deleting the member breaks each of them.
	 */
	private static function importsNaming(entry: Parsed, memberName: String): Int {
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			final name: String = node.name ?? '';
			final span: Null<Span> = node.span;
			if (ModuleScan.IMPORT_DECL_KINDS.contains(node.kind)) {
				final aliased: String = span == null ? '' : ModuleScan.aliasTargetOf(entry.source.substring(span.from, span.to));
				if (SourceText.lastSegment(name) == memberName || aliased != '' && SourceText.lastSegment(aliased) == memberName) count++;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(entry.tree);
		return count;
	}

}

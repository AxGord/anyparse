package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.ScopeFiles.ParsedFile;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.ValueNameBinding.ImportedStatics;
import anyparse.runtime.Span;

using Lambda;

/** The constructor being renamed, and where its enum lives. */
typedef CtorTarget = {
	final typeName: String;
	final ctor: String;
	final newName: String;

	/** The module declaring the enum. */
	final module: ModulePath;

	/** The file declaring the enum. */
	final cursorFile: String;
}

/** One file's constructor-token offsets, or the refusal that stops the whole rename. */
typedef CtorOffsets = {
	final offsets: Array<Int>;
	final error: Null<String>;
}

/**
 * The references of an enum CONSTRUCTOR a member rename (`CrossRenameMember`) does not reach through a receiver: the
 * import of the constructor itself, and every BARE spelling, which Haxe resolves through the reading file's imports or
 * through an expected type. A bare spelling is renamed only on a proof — an expected type the member rename already
 * proved, or an import bringing the enum's values in with nothing outranking it — and any other refuses the whole rename:
 * a spelling left on the old name is a program that no longer compiles, or one that now means something else.
 */
@:nullSafety(Strict)
@:access(anyparse.query.CrossRename)
@:access(anyparse.query.CrossRenameMember)
final class EnumCtorRefs {

	/** How many typedef hops `aliasReceiverOffsets` follows before it stops proving. */
	private static inline final ALIAS_HOPS: Int = 8;

	/**
	 * Why renaming the constructor `ctor` of `typeName` to `newName` cannot be proven complete over `parsed`, or null: a
	 * value of either name hosted by another type of the scope, which a bare spelling may mean as well, or a case pattern
	 * binding the old name, which the language may read as a capture.
	 */
	public static function refusal(
		typeName: String, ctor: String, newName: String, parsed: Array<ParsedFile>, index: SymbolIndex, refShape: RefShape
	): Null<String> {
		final rival: Null<String> = index.values.hostsOfValue(ctor).find(host -> host != typeName);
		if (rival != null)
			return 'cannot rename constructor "$ctor": "$rival" also hosts a value of that name, and a bare "$ctor" may mean either';
		if ((refShape.implicitValueNames ?? []).contains(newName))
			return 'cannot rename constructor "$ctor" to "$newName": "$newName" is a name every module reads without an import';
		final taken: Array<String> = index.values.hostsOfValue(newName);
		if (taken.length > 0) return 'cannot rename constructor "$ctor" to "$newName": "${taken[0]}" already hosts a value of that name';
		final capturing: Null<ParsedFile> = parsed.find(entry -> BinderScan.casePatternCaptures(entry.tree, refShape).contains(ctor));
		return capturing == null
			? null
			: 'cannot rename constructor "$ctor": a case pattern in ${capturing.file} binds the name, which may be read as a capture';
	}

	/**
	 * The constructor-token offsets of `entry` the rename adds to those the member rename already collected (`proven`): the
	 * import naming the constructor, and every bare spelling an import of the enum's values brings in — in the enum's own
	 * module, or through `ValueNameBinding.importBringsValue` — that no local, member, module-level value or imported
	 * static outranks. A bare spelling neither of those proves is the refusal, and so is one the NEW name would bind elsewhere,
	 * a bare spelling of the new name anywhere (the renamed constructor may take it over), and a bare old-name spelling
	 * in a file importing a module the scope does not hold (`ValueNameBinding.unlistedValueImportOf`).
	 */
	public static function offsets(
		entry: ParsedFile, target: CtorTarget, proven: Array<Int>, index: SymbolIndex, refShape: RefShape, regions: Array<LexRegion>
	): CtorOffsets {
		final ctor: String = target.ctor;
		final fi: Null<FileInfo> = index.fileInfo(entry.file);
		final out: Array<Int> = importOffsets(entry, target, refShape)
			.concat([
				for (off in aliasReceiverOffsets(entry, target, fi, index, refShape, regions)) if (!proven.contains(off)) off
			]);
		final visible: Bool = entry.file == target.cursorFile || fi != null
			&& index.values.importBringsValue(fi, typePathOf(target), target.module.path, ctor);
		// What the new name already means here the renamed constructor may take over — through an import of the enum, or
		// through an expected type, which reaches a pattern variable or an imported static in a file importing nothing.
		final taken: Array<{ offset: Int, host: Null<String> }> = bareSpellings(entry, target.newName, refShape);
		if (taken.length > 0)
			return refused(
				'"${target.newName}" at ${where(entry, taken[0].offset)} already names something the renamed constructor would take over'
			);
		final spellings: Array<{ offset: Int, host: Null<String> }> = bareSpellings(entry, ctor, refShape);
		final unlisted: Null<String> = if (spellings.length == 0)
			null
		else if (fi == null)
			entry.file
		else
			index.values.unlistedValueImportOf(fi);
		if (unlisted != null)
			return refused(
				'"$ctor" is spelled bare here and the file imports $unlisted, which the scope does not hold — it may bring a '
				+ 'constructor of the old or the new name'
			);
		for (spelling in spellings) {
			final isProven: Bool = proven.contains(spelling.offset);
			if (!isProven && (!visible || outranked(entry, fi, spelling.host, ctor, index, refShape)))
				return refused(
					'"$ctor" at ${where(entry, spelling.offset)} may be the constructor — Haxe resolves it through an import or an '
					+ 'expected type this rename cannot prove — refusing rather than renaming part of the scope'
				);
			if (outranked(entry, fi, spelling.host, target.newName, index, refShape))
				return refused(
					'"${target.newName}" at ${where(entry, spelling.offset)} would bind a member, a module-level value or an imported '
					+ 'static of that name instead of the constructor'
				);
			if (!isProven && !out.contains(spelling.offset)) out.push(spelling.offset);
		}
		return { offsets: out, error: null };
	}

	/**
	 * Why the rewritten file `newSource` binds a renamed spelling to something other than the constructor — a local or a
	 * parameter of the new name whose scope covers it — or null. `edits` are the rename's, in source coordinates.
	 */
	public static function capturedAfter(
		newSource: String, newTree: QueryNode, edits: Array<{ span: Span, text: String }>, newName: String, refShape: RefShape
	): Null<String> {
		if (edits.length == 0) return null;
		final froms: Array<Int> = [for (e in edits) e.span.from];
		froms.sort((a, b) -> a - b);
		final delta: Int = newName.length - (edits[0].span.to - edits[0].span.from);
		final moved: Array<Int> = [for (i => from in froms) from + i * delta];
		final hit: Null<RefHit> = Refs.find(newName, newTree, refShape)
			.find(h -> isBoundRead(h) && moved.exists(m -> m >= h.span.from && m < h.span.to));
		if (hit == null) return null;
		final at: Position = hit.span.lineCol(newSource);
		return 'the renamed "$newName" at ${at.line}:${at.col} is captured by a binding that shadows the constructor';
	}

	private static inline function refused(error: String): CtorOffsets {
		return { offsets: [], error: error };
	}

	/** A read or write the file's own scope binds to a declaration — a local, a parameter, a member. */
	private static inline function isBoundRead(h: RefHit): Bool {
		return (h.kind == RefKind.Read || h.kind == RefKind.Write) && h.bindingSpan != null;
	}

	/** The type path of the enum: `p.E` for its module's main type, `p.Mod.E` for a sub-type. */
	private static inline function typePathOf(target: CtorTarget): String {
		return target.typeName == target.module.base ? target.module.path : '${target.module.path}.${target.typeName}';
	}

	/** The 1-based `line:col` of `off`; the caller prefixes the file. */
	private static inline function where(entry: ParsedFile, off: Int): String {
		final at: Position = new Span(off, off).lineCol(entry.source);
		return '${at.line}:${at.col}';
	}

	/** The offset of the constructor's segment in every import naming the constructor itself (`import p.E.A;`, aliased or not). */
	private static function importOffsets(entry: ParsedFile, target: CtorTarget, refShape: RefShape): Array<Int> {
		final ctorPath: String = '${typePathOf(target)}.${target.ctor}';
		final out: Array<Int> = [];
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && ModuleScan.IMPORT_DECL_KINDS.contains(node.kind)) {
				final off: Int = CrossRename.throughOffset(
					entry.source, span, CrossRename.importedPath(node, entry.source, refShape), ctorPath, target.ctor
				);
				if (off >= 0 && !out.contains(off)) out.push(off);
			}
			for (c in node.children) walk(c);
		}
		walk(entry.tree);
		return out;
	}

	/**
	 * The constructor token of every `R.A` whose receiver names the enum — under ANOTHER name too: an import alias of the
	 * enum's type (its own or the ambient chain's) or a typedef chain ending at it, which the member rename's type-namespace
	 * match (`E.A`, `p.E.A`) does not see. A receiver the file's scope binds as a value is a field read and is left alone.
	 */
	private static function aliasReceiverOffsets(
		entry: ParsedFile, target: CtorTarget, fi: Null<FileInfo>, index: SymbolIndex, refShape: RefShape, regions: Array<LexRegion>
	): Array<Int> {
		final out: Array<Int> = [];
		if (fi == null) return out;
		final aliases: Array<String> = index.values.typeAliasesOf(fi, typePathOf(target));
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			final recvSpan: Null<Span> = node.children[0]?.span;
			if (span != null && recvSpan != null && node.kind == MemberKinds.FIELD_ACCESS_KIND && node.name == target.ctor) {
				final path: String = RefactorSupport.flattenPath(node.children[0]);
				final valueBound: Bool = RefactorSupport.valueBoundOffsets(path.split('.')[0], entry.tree, refShape)
					.contains(recvSpan.from);
				final off: Int = path == '' || valueBound || !(aliases.contains(path) || typedefReaches(path, entry.file, target, index))
					? -1
					: OccurrenceScan.activeCodeIdentTokenOffset(entry.source, new Span(recvSpan.to, span.to), target.ctor, regions);
				if (off >= 0 && !out.contains(off)) out.push(off);
			}
			for (c in node.children) walk(c);
		}
		walk(entry.tree);
		return out;
	}

	/**
	 * Whether the written type `path`, read from `file`, resolves to the enum, directly or through a typedef chain — a
	 * direct spelling the member rename's qualified paths already proved is filtered out by the caller.
	 */
	private static function typedefReaches(path: String, file: String, target: CtorTarget, index: SymbolIndex): Bool {
		var from: String = file;
		var written: String = path;
		for (_ in 0...ALIAS_HOPS) {
			final matches: Array<ResolvedType> = index.resolveTypeRefsFrom(written, from);
			if (matches.length != 1) return false;
			final hit: ResolvedType = matches[0];
			if (hit.type.name == target.typeName && hit.file.file == target.cursorFile) return true;
			final next: Null<String> = hit.type.aliasTargetRaw;
			if (next == null) return false;
			from = hit.file.file;
			written = next;
		}
		return false;
	}

	/**
	 * Every bare spelling of `ctor` in `entry` its own scope does not bind to a local, a parameter or a member — an identifier
	 * or a braceless interpolation — with the offset of its token and the type hosting it (null at module level).
	 */
	private static function bareSpellings(entry: ParsedFile, ctor: String, refShape: RefShape): Array<{ offset: Int, host: Null<String> }> {
		final out: Array<{ offset: Int, host: Null<String> }> = [];
		if (SourceText.identTokenOffset(entry.source, new Span(0, entry.source.length), ctor) < 0) return out;
		final bound: Array<Int> = [
			for (h in Refs.find(ctor, entry.tree, refShape)) if (isBoundRead(h)) h.span.from
		];
		final identKinds: Array<String> = [
			for (k in [refShape.identKind, refShape.stringInterpIdentKind]) if (k != null) k
		];
		function walk(node: QueryNode, host: Null<String>): Void {
			final owner: Null<String> = RefactorSupport.typeDeclOf(node)?.name ?? host;
			final span: Null<Span> = node.span;
			if (span != null && node.name == ctor && identKinds.contains(node.kind) && !bound.contains(span.from))
				out.push({ offset: SourceText.identTokenOffset(entry.source, span, ctor), host: owner });
			for (c in node.children) walk(c, owner);
		}
		walk(entry.tree, null);
		return out;
	}

	/**
	 * Whether something the language resolves BEFORE an imported enum's values binds the bare `name` in `entry` at a use
	 * hosted by `host`: a member of the host or of an ancestor (or an ancestor the index cannot see), a module-level value
	 * of the file, or a static an import binds under the name — or one the index cannot list.
	 */
	private static function outranked(
		entry: ParsedFile, fi: Null<FileInfo>, host: Null<String>, name: String, index: SymbolIndex, refShape: RefShape
	): Bool {
		if (fi == null) return true;
		final statics: ImportedStatics = index.values.importedStatics(fi, name);
		return statics.unknown || statics.statics.length > 0 || CrossRenameMember.hostShadows(host, name, index)
			|| CrossRenameMember.declaresModuleBinding(entry.tree, name, refShape);
	}

}

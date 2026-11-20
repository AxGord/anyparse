package anyparse.query;

import anyparse.check.common.unused.AnnotatedDeclScan;
import anyparse.check.common.unused.StaticReflectionReach;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.ReflectionScan;
import anyparse.query.GrammarPlugin.AmbientImports;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.OccurrenceScan.ClassifiedOccurrence;
import anyparse.query.OccurrenceScan.OccurrenceClass;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.query.ScopeFiles.ParsedFile;
import anyparse.query.ScopeFiles.ScopeParse;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;

using Lambda;

/** What `SafeDeleteType.safeDeleteType` decided about one type. */
enum SafeDeleteTypeResult {

	/** The type is dead and alone in its module: `file` is to be deleted, and `notes` name what the deletion leaves. */
	RemoveFile(file: String, notes: Array<String>);

	/** The type is dead and shares its module: `file` is to be rewritten to `source`, and `notes` name what it leaves. */
	RemoveDeclaration(file: String, source: String, notes: Array<String>);

	/** Something still reaches the type, or the scope cannot prove otherwise: every reason, one line each. */
	Refused(reasons: Array<String>);

}

/**
 * The one answer to "is this type declaration provably unreferenced across a scope, and what does removing it take":
 * the type form of `SafeDelete`, with the same bias — refuse on any doubt, list every reason.
 *
 * A reference is every type-namespace occurrence `CrossRename.collectOccurrences` reads (type positions, `new`,
 * static access, imports and `using`, qualified paths, access grants), those inside the type's own declaration
 * excepted; an unparsed conditional region naming it, a string that may reach it at run time, and a `@:keep` /
 * `@:expose` on it refuse as well. A constructor of an enum (or a value of an enum abstract) spelled bare anywhere in the scope
 * refuses, and so does a `using` of the module of a type with a static function, which brings it in
 * as an extension. A same-named type elsewhere in the scope refuses too (ambiguous: a false refusal,
 * never a wrong deletion). The only type of its module takes the module file with it; a type among others is cut
 * out of its file alone.
 *
 * Comments, directives, a module's ambient import sources and its test companions never block: the op names them.
 */
@:nullSafety(Strict)
final class SafeDeleteType {

	/**
	 * Decide the removal of `typeName` from `srcFile` under `scopeFiles`. `scopeLabel` is the scope as the caller spells it
	 * (for the `mentions` call a note suggests) and `companions` the test files its layout declares for the module. PURE;
	 * `plugin` must be the run's caching plugin, so the declaration found here is the node the removal cuts.
	 */
	public static function safeDeleteType(
		srcFile: String, typeName: String, reformat: Bool, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		scopeLabel: String, companions: Array<String>, ?optsJson: String
	): SafeDeleteTypeResult {
		final parse: ScopeParse = ScopeFiles.parseScope(scopeFiles, plugin, 'safe-delete');
		final parseError: Null<String> = parse.error;
		if (parseError != null) return Refused([parseError]);
		final srcEntry: Null<ParsedFile> = parse.parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Refused(['source file $srcFile is not in the scope file set']);
		final src: ParsedFile = srcEntry;
		final uniqueness: Null<String> = ScopeFiles.uniquenessRefusal(parse.parsed, srcFile, typeName);
		if (uniqueness != null) return Refused([uniqueness]);
		final declOrNull: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(src.tree, typeName);
		if (declOrNull == null) return Refused(['no type "$typeName" in $srcFile']);
		final decl: TypeDeclMatch = declOrNull;
		final shape: RefShape = plugin.refShape();

		final reasons: Array<String> = [];
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionInAny(parse.parsed, typeName, shape, 'delete of "$typeName"');
		if (opaque != null) reasons.push(opaque);
		for (reference in references(parse.parsed, src, decl, plugin, shape)) reasons.push('"$typeName" is referenced at $reference');
		final index: Null<SymbolIndex> = IndexScope.lazySymbolIndex(scopeFiles, plugin)();
		reflectiveReasons(src, decl, typeName, scopeFiles, plugin, index, reasons);
		if (index != null) reachThroughScope(index, parse.parsed, src, decl, plugin, shape, reasons);
		if (reasons.length > 0) return Refused(reasons);

		final sole: Bool = isOnlyType(src.tree, decl, plugin, shape);
		final removed: Null<String> = sole ? null : cutDeclaration(src.source, decl, reformat, plugin, optsJson, reasons);
		if (reasons.length > 0) return Refused(reasons);
		final remaining: Array<{ file: String, text: String }> = [ for (p in parse.parsed) if (p.file != srcFile) {
			file: p.file, text: p.source
		} ];
		if (removed != null) remaining.push({ file: srcFile, text: removed });
		final notes: Array<String> = notesOf(srcFile, src.tree, typeName, remaining, plugin, shape, scopeLabel, sole ? companions : []);
		return removed == null ? RemoveFile(srcFile, notes) : RemoveDeclaration(srcFile, removed, notes);
	}

	/** Every `file:line:col` at which the scope names the type, outside its own declaration. */
	private static function references(
		parsed: Array<ParsedFile>, src: ParsedFile, decl: TypeDeclMatch, plugin: GrammarPlugin, shape: RefShape
	): Array<String> {
		final module: ModulePath = ModuleScan.moduleOf(src.tree, src.file);
		final out: Array<String> = [];
		for (entry in parsed) {
			final lines: LineIndex = new LineIndex(entry.source);
			final hits: Array<Span> = CrossRename.collectOccurrences(
				entry.source, decl.name, entry.tree, plugin, plugin.typeRefShape(), shape, module
			);
			for (hit in hits) {
				final inside: Bool = entry.file == src.file && hit.from >= decl.fullSpan.from && hit.from < decl.fullSpan.to;
				if (inside) continue;
				final at: Position = lines.lineColAt(hit.from);
				out.push('${entry.file}:${at.line}:${at.col}');
			}
		}
		return out;
	}

	/**
	 * Push to `out` what reaches the type without naming it: an enum constructor or an enum abstract value written bare
	 * (the type comes in with the module, an import of it or the expected type), and a static extension a `using` of the
	 * type's module brings in.
	 */
	private static function reachThroughScope(
		index: SymbolIndex, parsed: Array<ParsedFile>, src: ParsedFile, decl: TypeDeclMatch, plugin: GrammarPlugin, shape: RefShape,
		out: Array<String>
	): Void {
		final declared: Null<TypeDeclInfo> = index.fileInfo(src.file)?.types.find(t -> t.name == decl.name);
		if (declared == null) {
			out.push('"${decl.name}" has no declaration record in the scope index, so what reaches it bare cannot be read');
			return;
		}
		final type: TypeDeclInfo = declared;
		for (place in bareValueUses(parsed, src, decl, bareValueNames(type, shape), plugin))
			out.push('a constructor or value of "${decl.name}" is named bare at $place');
		final hasStatic: Bool = type.members.exists(m -> m.isStatic && MemberKinds.FN_DECL_KINDS.contains(m.kind));
		if (!type.isPrivate && !type.isMain && hasStatic)
			for (fi in index.allFiles())
				if (index.typing.extensions.usingTypes(fi).contains(decl.name))
					out.push('${fi.file} brings "${decl.name}" in as a static extension through a `using`');
	}

	/** The names a file reaches bare once the type is in scope: its enum constructors, the values of an enum abstract. */
	private static function bareValueNames(type: TypeDeclInfo, shape: RefShape): Array<String> {
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		return [
			for (m in type.members)
				if (MemberKinds.isEnumConstructorKind(m.kind) || (type.isEnumAbstract && !m.isStatic && fields.contains(m.kind))) m.name
		];
	}

	/** Every `file:line:col` (and the name) at which the scope spells one of `names` unqualified, outside the type's own declaration. */
	private static function bareValueUses(
		parsed: Array<ParsedFile>, src: ParsedFile, decl: TypeDeclMatch, names: Array<String>, plugin: GrammarPlugin
	): Array<String> {
		final out: Array<String> = [];
		for (entry in parsed) {
			final lines: LineIndex = new LineIndex(entry.source);
			final comments: Array<Span> = SourceComments.collectCommentRegions(plugin.lexicalRegions(entry.source));
			final own: Array<Span> = entry.file == src.file ? [decl.fullSpan] : [];
			for (name in names) {
				final found: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
					entry.source, name, plugin, 0, entry.source.length, own
				);
				if (found == null) {
					out.push('${entry.file} (unreadable, `$name`)');
					continue;
				}
				for (hit in found) {
					final code: Bool = hit.kind == OccurrenceClass.ActiveCode || hit.kind == OccurrenceClass.ConditionalRaw;
					if (!code || OccurrenceScan.qualifiedBefore(entry.source, hit.span.from, comments)) continue;
					final at: Position = lines.lineColAt(hit.span.from);
					out.push('${entry.file}:${at.line}:${at.col} (`$name`)');
				}
			}
		}
		return out;
	}

	/** Push to `out` the reasons a string, a macro or an annotation may reach the type without naming it in a position. */
	private static function reflectiveReasons(
		src: ParsedFile, decl: TypeDeclMatch, typeName: String, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		index: Null<SymbolIndex>, out: Array<String>
	): Void {
		final shape: RefShape = plugin.refShape();
		final kept: Array<String> = [
			for (name in [shape.retainedDeclMetaName, shape.exportedDeclMetaName]) if (name != null) name
		];
		if (AnnotatedDeclScan.typeStartsAny(plugin, src.tree, kept).contains(decl.declNode.span?.from ?? -1))
			out.push('"$typeName" carries ${kept.join(' / ')} — its readers are outside the scope');
		final surface: ReflectionSurface = ReflectionScan.reflectionSurface(scopeFiles, plugin);

		final reach: Null<StaticReflectionReach> = index == null ? null : StaticReflectionReach.build(scopeFiles, plugin, surface);
		final reflective: String = '"$typeName" may be reached at run time: a string naming it, a class value or a macro the scope builds';
		if (index == null || reach == null)
			out.push(reflective);
		else if (reach.staticReachable(typeName, src.file, typeName, index))
			out.push(reflective);
	}

	/** Whether the module holds nothing but `decl`: no other type, field or region, only its header and the type's own annotations. */
	private static function isOnlyType(tree: QueryNode, decl: TypeDeclMatch, plugin: GrammarPlugin, shape: RefShape): Bool {
		final prefix: Array<String> = plugin.metaShape().metaKinds.concat(CheckScan.modifierKinds(shape));
		return tree.children.foreach(
			c ->
				c == decl.declNode
				|| ModuleScan.IMPORT_DECL_KINDS.contains(c.kind)
				|| ModuleScan.PACKAGE_DECL_KINDS.contains(c.kind)
				|| prefix.contains(c.kind)
		);
	}

	/** `source` without `decl` (and its doc and annotations), or null with the reason pushed to `reasons`. */
	private static function cutDeclaration(
		source: String, decl: TypeDeclMatch, reformat: Bool, plugin: GrammarPlugin, optsJson: Null<String>, reasons: Array<String>
	): Null<String> {
		return switch RemoveElement.removeTarget(source, ByNode(decl.declNode), reformat, plugin, true, optsJson) {
			case Ok(text): text;
			case Err(message):
				reasons.push(message);
				null;
		};
	}

	/** What the removal leaves behind that the caller must read: comments, directives, ambient import sources, test companions. */
	private static function notesOf(
		srcFile: String, tree: QueryNode, typeName: String, remaining: Array<{ file: String, text: String }>, plugin: GrammarPlugin,
		shape: RefShape, scopeLabel: String, companions: Array<String>
	): Array<String> {
		final out: Array<String> = [];
		final comments: Null<String> = CommentMentions.leftBehindAcross(remaining, plugin, typeName, scopeLabel);
		if (comments != null) out.push(comments);
		var directives: Int = 0;
		for (f in remaining) directives += directiveMentions(f.text, plugin, shape, typeName);
		if (directives > 0)
			out.push(
				'$directives conditional-compilation directive(s) still spell `$typeName`: apq lit $typeName $scopeLabel'
				+ ' --include-directives'
			);
		final ambient: AmbientImports = plugin.ambientImportSources(srcFile, ModuleScan.packageOf(tree));
		for (source in ambient.sources) if (RawSourceScan.mentionsWord(source.source, typeName))
			out.push('${source.file} (an ambient import source of the module) spells `$typeName` and is left as it is');
		for (c in companions) out.push('$c (a declared test companion of the module) is left in place');
		return out;
	}

	/** How many conditional-compilation directives of `text` spell `name` as a word. */
	private static function directiveMentions(text: String, plugin: GrammarPlugin, shape: RefShape, name: String): Int {
		final regions: () -> Array<LexicalRegions.LexRegion> = ElementSpan.lazyRegions(text, plugin);
		return CondDirectives.scan(text, shape, regions).count(d -> RawSourceScan.mentionsWord(CondDirectives.text(text, d), name));
	}

}

package anyparse.query;

import anyparse.query.ComposedValues.LiteralExpectation;
import anyparse.query.CrossRenameMember.LocatedOffsets;
import anyparse.query.CrossRenameMember.MemberTarget;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NominalTypes.IndexTyping;
import anyparse.query.ScopeFiles.ParsedFile;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.ValueNameBinding.ImportedStatics;
import anyparse.runtime.Span;

using Lambda;

/**
 * An object literal naming the member: `subject` the value a `switch` matches it against when the literal is a pattern, null when
 * it is a value, and `head` whether it is the pattern at that switch's own level rather than one nested in another.
 */
typedef LiteralSite = {
	final literal: QueryNode;
	final field: QueryNode;
	final subject: Null<QueryNode>;
	final head: Bool;
};

/**
 * The one answer to "which object-literal keys and which reads belong to a field of a structure, and which leave a rename
 * undecidable": a rename takes the proven ones with the declaration and refuses over an undecided one.
 */
@:nullSafety(Strict)
final class StructureFieldOffsets {

	/**
	 * The field-name tokens of every object literal in one file a written type proves builds the member's type, a structure or
	 * a `@:structInit` class alike: such a field IS the member, and a field written anywhere else is a loud compile error at best.
	 * For a field of a structure a literal no written type decides, whose fields could be exactly the structure's, is unprovable
	 * either way, so it refuses the whole rename; a literal a written type proves to be something else keeps its field.
	 */
	public static function literalFieldOffsets(
		entry: ParsedFile, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex, cursorFile: String
	): LocatedOffsets {
		final sites: Array<LiteralSite> = target.isStatic ? [] : literalFieldSites(entry.tree, target.memberName, refShape);
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (sites.length == 0 || provider == null) return { offsets: [], error: null };
		final typing: IndexTyping = fileTyping(entry.tree, entry.source, entry.file, provider, refShape, index);
		final typeParams: Array<String> = fileTypeParams(entry.source, provider);
		final returns: Map<Int, String> = CallGraphNames.returnSourcesOf(plugin, entry.source);
		final regions: Array<LexRegion> = plugin.lexicalRegions(entry.source);
		final isStructure: Bool = structureOf(target, index, cursorFile) != null;
		final out: Array<Int> = [];
		for (site in sites) {
			final subject: Null<QueryNode> = site.subject;
			final claim: LiteralExpectation = if (subject == null)
				ComposedValues.literalExpectation(site.literal, returns, target.memberName, typeParams, typing)
			else if (site.head)
				ComposedValues.receiverExpectation(subject, target.memberName, typeParams, typing)
			else
				Unwritten;
			final undecided: Bool = switch claim {
				case NotADeclaration: false;
				case Unwritten: mayBuildStructure(site.literal, target, refShape, index, cursorFile, subject != null);
				case Unfollowed: isStructure;
				case Declared(decl):
					!buildsStructure(decl, target, index, cursorFile) && wrapsStructure(decl, target, index, cursorFile);
			};
			if (undecided) return { offsets: [], error: undecidedLiteral(entry.source, site.literal, target) };
			final decl: Null<ResolvedType> = switch claim {
				case Declared(found) if (buildsStructure(found, target, index, cursorFile) && !namesConstructorParameters(found, refShape)):
					found;
				case _: null;
			};
			final span: Null<Span> = site.field.span;
			if (decl == null || span == null) continue;
			// a quoted key names the field inside its quotes, and the token is no identifier there
			final off: Int = site.field.name == target.memberName
				? OccurrenceScan.activeCodeIdentTokenOffset(entry.source, span, target.memberName, regions)
				: span.from + 1;
			if (off < 0) return { offsets: [], error: CrossRenameMember.unlocatableAccess(entry.source, span, target.memberName) };
			out.push(off);
		}
		return { offsets: out, error: null };
	}

	/** The structure the target is a field of, null when it is a member of any other type. */
	public static function structureOf(target: MemberTarget, index: SymbolIndex, cursorFile: String): Null<ResolvedType> {
		final file: Null<FileInfo> = index.fileInfo(cursorFile);
		if (file == null) return null;
		final decl: Null<ResolvedType> = switch index.typing.resolve(file, target.typeName, target.declFrom) {
			case Declared(found): found;
			case Unknown: null;
		};
		return decl != null && decl.type.isAnonStruct ? decl : null;
	}

	/**
	 * Reads and writes of a structure field, in whichever access form. The type moves through every receiver the expression typing
	 * proves is the structure or a type built on it; a receiver typed as something else keeps the old name; a receiver that stays
	 * unknown refuses the whole rename, naming the read, because the old name would otherwise survive a success.
	 */
	public static function structureReadOffsets(
		source: String, file: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex,
		cursorFile: String
	): LocatedOffsets {
		final memberName: String = target.memberName;
		final candidates: Array<{ recv: QueryNode, fa: QueryNode }> = structureReadCandidates(tree, memberName, refShape);
		final provider: TypeInfoProvider = cast plugin;
		final typing: IndexTyping = fileTyping(tree, source, file, provider, refShape, index);
		final typeParams: Array<String> = fileTypeParams(source, provider);
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final out: Array<Int> = [];
		for (cand in candidates) {
			final recvSpan: Null<Span> = cand.recv.span;
			final faSpan: Null<Span> = cand.fa.span;
			if (recvSpan == null || faSpan == null || isLiteralReceiver(cand.recv, refShape)) continue;
			final moves: Bool = switch ComposedValues.receiverExpectation(cand.recv, memberName, typeParams, typing) {
				case Declared(decl) if (buildsStructure(decl, target, index, cursorFile)): true;
				case Declared(decl) if (wrapsStructure(decl, target, index, cursorFile)):
					return { offsets: [], error: undecidedRead(source, faSpan, target) };
				case Declared(_), NotADeclaration: false;
				case Unwritten if (isTypePathReceiver(cand.recv, tree, refShape, index, file)): false;
				case Unwritten, Unfollowed: return { offsets: [], error: undecidedRead(source, faSpan, target) };
			};
			if (!moves) continue;
			final unlocated: Null<String> = addAccessOffset(source, recvSpan, faSpan, memberName, regions, out);
			if (unlocated != null) return { offsets: [], error: unlocated };
		}
		return { offsets: out, error: null };
	}

	/** Adds the member token of one proven access to `out`, once; the diagnostic when no such token is in code. */
	public static function addAccessOffset(
		source: String, recvSpan: Span, faSpan: Span, memberName: String, regions: Array<LexRegion>, out: Array<Int>
	): Null<String> {
		final off: Int = OccurrenceScan.activeCodeIdentTokenOffset(source, new Span(recvSpan.to, faSpan.to), memberName, regions);
		if (off < 0) return CrossRenameMember.unlocatableAccess(source, faSpan, memberName);
		if (!out.contains(off)) out.push(off);
		return null;
	}

	/**
	 * A receiver spelled as a literal has the literal's own type, so it cannot
	 * hold a value of the structure even when the typing reads no type off it.
	 */
	private static inline function isLiteralReceiver(recv: QueryNode, shape: RefShape): Bool {
		return recv.kind == shape.objectLiteralKind || recv.kind == shape.arrayLiteralKind;
	}

	/**
	 * Whether a receiver no typing answered spells a type path (`Date`, `haxe.Json`), which no structure field is read through: it
	 * ends in a type-cased segment, the segments before that are a lowercase package, and its root binds no value, neither a
	 * local nor an imported static or module field. `Other.LIMIT`, `inherited.x` and an imported `DEFAULT` may hold the structure.
	 */
	private static function isTypePathReceiver(recv: QueryNode, tree: QueryNode, shape: RefShape, index: SymbolIndex, file: String): Bool {
		final name: Null<String> = recv.name;
		if (name == null || !SourceText.isUpperInitial(name) || !TypeResolver.receiverRootIsUnboundType(recv, tree, shape)) return false;
		var root: QueryNode = recv;
		while (root.kind == shape.fieldAccessKind && root.children.length == 1) {
			root = root.children[0];
			final segment: Null<String> = root.name;
			if (segment == null || SourceText.isUpperInitial(segment)) return false;
		}
		final rootName: Null<String> = root.name;
		final rootSpan: Null<Span> = root.span;
		final info: Null<FileInfo> = index.fileInfo(file);
		if (rootName == null || rootSpan == null || info == null) return false;
		final statics: ImportedStatics = index.values.importedStatics(info, rootName);
		return !statics.unknown && statics.statics.length == 0 && index.values.moduleValuesAt(info, rootName, rootSpan.from) == null;
	}

	/** Every object literal of `tree` with a field named `memberName`, one record per such field. */
	private static function literalFieldSites(tree: QueryNode, memberName: String, shape: RefShape): Array<LiteralSite> {
		final out: Array<LiteralSite> = [];
		final switchKinds: Array<String> = shape.switchKinds ?? [];
		final structuralKinds: Array<Null<String>> = [shape.objectLiteralKind, shape.arrayLiteralKind, shape.callKind];
		function visit(node: QueryNode, subject: Null<QueryNode>, head: Bool): Void {
			if (node.kind == shape.objectLiteralKind)
				for (field in literalFields(node, shape)) if (namesField(field, memberName)) out.push({
					literal: node,
					field: field,
					subject: subject,
					head: head
				});
			final isSwitch: Bool = switchKinds.contains(node.kind) && node.children.length > 0;
			final nextHead: Bool = head && !structuralKinds.contains(node.kind);
			for (child in node.children) if (isSwitch && child.kind == shape.caseBranchKind) {
				final patterns: Array<QueryNode> = CasePatterns.patternRun(child, shape);
				for (part in child.children) if (patterns.contains(part))
					visit(part, node.children[0], true)
				else
					visit(part, null, false);
			} else {
				visit(child, subject, nextHead);
			}
		}
		visit(tree, null, false);
		return out;
	}

	/** The fields `literal` writes, a `#if` region's among them. */
	private static function literalFields(literal: QueryNode, shape: RefShape): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function collect(host: QueryNode): Void {
			for (child in host.children) if (child.kind == shape.objectFieldKind)
				out.push(child)
			else if (child.kind == shape.conditionalMemberKind)
				collect(child);
		}
		collect(literal);
		return out;
	}

	/** Whether the literal field `field` names `name`, bare or quoted: a quoted key is the same field. */
	private static function namesField(field: QueryNode, name: String): Bool {
		return field.name == name || field.name == '"$name"' || field.name == '\'$name\'';
	}

	/**
	 * Could `literal` be a value of the structure declaring the member? Haxe takes a literal as a structure only when it writes
	 * no other field and leaves out none but an optional one, so any other literal is no value of it, whatever its type.
	 * A structure with a supertype has fields of its own type alone listed here, so such a literal is taken as one.
	 */
	private static function mayBuildStructure(
		literal: QueryNode, target: MemberTarget, shape: RefShape, index: SymbolIndex, cursorFile: String, partial: Bool
	): Bool {
		final decl: Null<ResolvedType> = structureOf(target, index, cursorFile);
		if (decl == null) return false;
		if (decl.type.supertypes.length > 0) return true;
		final fields: Array<QueryNode> = literalFields(literal, shape);
		final members: Array<MemberInfo> = decl.type.members;
		return fields.foreach(f -> members.exists(m -> namesField(f, m.name)))
			&& (partial || members.foreach(m -> m.optional || m.guarded || fields.exists(f -> namesField(f, m.name))));
	}

	/** The refusal of a rename over the object literal `literal`, which nothing written decides. */
	private static function undecidedLiteral(source: String, literal: QueryNode, target: MemberTarget): String {
		final at: Null<Position> = literal.span?.lineCol(source);
		return 'object literal at ${at?.line ?? 0}:${at?.col ?? 0} may build "${target.typeName}" but no written type proves it — '
			+ 'annotate it, or rename "${target.memberName}" by hand';
	}

	/** `decl` is the type declaring the target, or a type built on it. */
	private static function buildsStructure(decl: ResolvedType, target: MemberTarget, index: SymbolIndex, cursorFile: String): Bool {
		return (decl.type.name == target.typeName && decl.file.file == cursorFile)
			|| index.subtypes.isSubtype(decl.type.name, target.typeName);
	}

	/**
	 * An abstract over the target's type, declaring no such member of its
	 * own: a value of it may be the structure, through a cast or `@:forward`.
	 */
	private static function wrapsStructure(decl: ResolvedType, target: MemberTarget, index: SymbolIndex, cursorFile: String): Bool {
		final underlying: Null<String> = decl.type.underlyingRaw;
		if (underlying == null || decl.type.isEnumAbstract || decl.type.members.exists(m -> m.name == target.memberName)) return false;
		final inner: Null<ResolvedType> = index.refs.resolveTypeRef(underlying, decl.file);
		return inner != null && buildsStructure(inner, target, index, cursorFile);
	}

	/** A class written with its own constructor reads a literal's fields as that constructor's parameters, not as its fields. */
	private static function namesConstructorParameters(decl: ResolvedType, shape: RefShape): Bool {
		final ctor: Null<String> = shape.constructorName;
		return ctor != null && decl.type.members.exists(m -> m.name == ctor);
	}

	/** The typed view of one file a literal's expectation or a read's receiver is asked over. */
	private static function fileTyping(
		tree: QueryNode, source: String, file: String, provider: TypeInfoProvider, shape: RefShape, index: SymbolIndex
	): IndexTyping {
		return {
			root: tree,
			shape: shape,
			declaredTypes: provider.declaredTypes(source),
			chain: {
				declaredTypeSources: provider.declaredTypeSources(source),
				source: source,
				castTargetSources: TypeInfoMemo.castTargetSources(provider, source),
				typeSyntax: index.typeSyntax
			},
			index: index,
			file: file,
			seen: []
		};
	}

	/** Every type parameter the file declares: a written `T` of one names no declaration, and can hold the structure through its bound. */
	private static function fileTypeParams(source: String, provider: TypeInfoProvider): Array<String> {
		return [for (names in provider.typeParamNames(source)) for (name in names) name];
	}

	/** Every access of the member name, through whichever access operator the grammar spells it with. */
	private static function structureReadCandidates(
		tree: QueryNode, memberName: String, shape: RefShape
	): Array<{ recv: QueryNode, fa: QueryNode }> {
		final kinds: Array<Null<String>> = [shape.fieldAccessKind, shape.nullSafeAccessKind, shape.forceFieldAccessKind];
		final out: Array<{ recv: QueryNode, fa: QueryNode }> = [];
		function visit(node: QueryNode): Void {
			if (kinds.contains(node.kind) && node.name == memberName && node.children.length == 1)
				out.push({ recv: node.children[0], fa: node });
			for (child in node.children) visit(child);
		}
		visit(tree);
		return out;
	}

	private static function undecidedRead(source: String, span: Span, target: MemberTarget): String {
		final at: Position = span.lineCol(source);
		return 'read of "${target.memberName}" at ${at.line}:${at.col} has a receiver no written type proves is "${target.typeName}'
			+ '" or something else — annotate it, or rename "${target.memberName}" by hand';
	}

}

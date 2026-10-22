package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NominalTypes.ChainTypeContext;
import anyparse.query.NominalTypes.IndexTyping;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.runtime.Span;

using Lambda;

/**
 * The doors of the index host's deep walk (`NominalTypes`): the type an expression asked as a value of its own carries
 * where the walk's arcs do not reach it — a local declaration, a type name read as a value — never on the way to a receiver
 * or an argument, which the arcs type their own way. Each answers what Haxe 4.3.7 types there or null.
 */
@:nullSafety(Strict)
final class ValueDoors {

	/**
	 * The type a door of the deep walk gives `node` of the file `file` (its tree `root`, its declarations' written types
	 * `declaredTypes` and `chain`) where it is asked as a value of its own — never on its way to a receiver or an argument,
	 * which the walk's arcs reach their own way: a local declaration (`declarationTypeSource`) and, unless `node` is asked
	 * as a receiver (`asReceiver`), a type name read as a value (`typeValueSource`). Null otherwise.
	 */
	public static function typeSource(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		index: Null<SymbolIndex>, file: String, asReceiver: Bool
	): Null<String> {
		final c: IndexTyping = {
			root: root,
			shape: shape,
			declaredTypes: declaredTypes,
			chain: chain,
			index: index,
			file: file,
			seen: []
		};
		return if ((shape.localDeclKinds ?? []).contains(node.kind))
			declarationTypeSource(node, c)
		else if (!asReceiver && node.kind == c.shape.identKind)
			typeValueSource(node, c)
		else
			null;
	}

	/**
	 * The type the local declaration `decl` gives the one value it binds — what a read of it carries (`INDEX_HOST.bound`):
	 * its written type, else its initializer's (4.3.7 types `var x = e` as `e`). Null for a declaration binding several
	 * (`RefShape.localDeclContinuationKinds`), one written with a type the host cannot read, and one with no initializer.
	 */
	@:access(anyparse.query.NominalTypes)
	private static function declarationTypeSource(decl: QueryNode, c: IndexTyping): Null<String> {
		final at: Null<Span> = decl.span;
		final continuations: Array<String> = c.shape.localDeclContinuationKinds ?? [];
		if (at == null || decl.children.exists(child -> continuations.contains(child.kind))) return null;
		final from: Int = at.from;
		if (c.chain.declaredTypeSources.exists(from) || c.declaredTypes.exists(from)) return NominalTypes.INDEX_HOST.bound(from, c);
		final init: Null<QueryNode> = CtorFieldFold.declInitializer(decl, c.shape);
		if (init == null || c.seen.contains(from)) return null;
		c.seen.push(from);
		final held: Null<String> = TypingService.typeWalk(init, c.shape, NominalTypes.INDEX_HOST, c);
		c.seen.pop();
		return held;
	}

	/**
	 * The type a type name read as a value carries (4.3.7 `type_ident`, `type_module_type`): the identifier `ident` binds
	 * none of the values the compiler looks up first (`bindsNoValue`) and names one declaration, with no type parameter, of a
	 * kind `RefShape.typeValueTypeNames` gives a value type — that name applied to it (`Class<T>`). Null otherwise: a generic
	 * one's value carries arguments nothing spells.
	 */
	private static function typeValueSource(ident: QueryNode, c: IndexTyping): Null<String> {
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		final name: Null<String> = ident.name;
		final at: Null<Span> = ident.span;
		if (index == null || fi == null || name == null || at == null) return null;
		if (!bindsNoValue(ident, name, at, fi, c, index)) return null;
		final named: Null<ResolvedType> = index.refs.resolveTypeRef(name, fi, at.from);
		final wrapper: Null<String> = named == null || named.type.typeParamNames.length > 0
			? null
			: c.shape.typeValueTypeNames?.get(named.type.kind);
		return wrapper == null || NominalTypes.shadowedByNonStdType(index, wrapper) ? null : '$wrapper<$name>';
	}

	/**
	 * Whether the bare `name`, read by `ident` at `at` of the file `fi`, binds none of the values 4.3.7 looks a bare
	 * identifier up as before a type (`typer.ml` `type_ident_raise`): a local, a member of the enclosing type or one it
	 * inherits (`MemberLookup.declarationLacksMember`), a module-level field, a constructor or value of a type of the module
	 * (any member of one, read over-inclusively), anything an import or the ambient chain may bring
	 * (`ValueNameBinding.mayImportValue`; an unbounded chain may bring anything).
	 */
	private static function bindsNoValue(ident: QueryNode, name: String, at: Span, fi: FileInfo, c: IndexTyping, index: SymbolIndex): Bool {
		if (!fi.ambientImportsBounded || TypeResolver.identBindingFrom(ident, c.root, c.shape) != null) return false;
		if (fi.moduleFields.exists(f -> f.name == name) || fi.types.exists(t -> t.members.exists(m -> m.name == name))) return false;
		final enclosing: Null<TypeDeclMatch> = TypeResolver.enclosingTypeDecl(c.root, at);
		final own: Null<ResolvedType> = enclosing == null ? null : index.refs.findDeclaredType(c.file, enclosing.name);
		if (enclosing != null && (own == null || !index.typing.members.declarationLacksMember(own, name))) return false;
		return !index.values.mayImportValueBesideType(fi, name) && index.values.hostsOfValue(name).length == 0;
	}

}

package anyparse.check;

import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypingService;
import anyparse.runtime.SortedOffsets;
import anyparse.runtime.Span;

/** A type as an argument or a parameter is written: its text, and the file writing it — null for a type no file spells. */
typedef WrittenType = {
	final text: String;
	final file: Null<String>;
}

/** Where `ArgumentTypes` types an argument: the file and tree it is written in, the type of the function writing it. */
private typedef ArgumentScope = {
	final types: ArgumentTypes;
	final file: String;
	final root: QueryNode;
	final owner: Null<String>;
	final seen: Array<Int>;
}

/**
 * The written type of a call's argument, and how it meets the type of a parameter (`ArgumentFit`) — what `ArgumentSlots`
 * decides the binding of a call by, for `ArgumentValues`. The shapes are THE structural walk every typer shares
 * (`TypingService.typeWalk`); this is its resolution over the call graph (`HOST`), answering a written type: a literal's
 * core type, a local's or a parameter's annotation (a local written with none by its initializer), a field of the
 * enclosing type's chain read bare or off the self reference, a static field read off a type name, and arithmetic over core
 * numbers (`RefShape.coreValueTypes`, `arithmeticKinds`). Everything else is untyped.
 *
 * A positive whitelist for the fit: two core types (each one no indexed type of its name shadows) fit when they are the same
 * or one widens to the other and misfit otherwise; `null` fits a parameter a call may leave out; the same plain type name
 * written in one file, no type parameter on either side, fits. Every other pair — an abstract converting through `@:from`
 * / `@:to` (`openfl.text.TextFormatAlign` takes a `String`), a type parameter, a type written in two files — may fit.
 */
@:nullSafety(Strict)
final class ArgumentTypes {

	/** The call graph's resolution of the shared walk, answering a written type; an arc it does not know answers null. */
	private static final HOST: TypingHost<WrittenType, ArgumentScope> = {
		peel: (node, s) -> s.types.unwrap(node),
		isAccess: (kind, s) -> kind == s.types._shape.fieldAccessKind,
		literal: (typeName, _) -> {text: typeName, file: null },
		self: (_, _) -> null,
		binding: (ident, s) -> s.types.bindingOf(ident, s),
		bound: (from, s) -> {
			final written: Null<String> = s.types.typeSourcesOf(s.file)[from];
			written == null ? null : { text: written, file: s.file };
		},
		initializer: (_, use, s) -> NominalTypes.localInitializer(use, s.root, s.types._shape, s.types.typeSourcesOf(s.file)),
		loopElement: (_, _) -> null,
		parameter: null,
		unbound: (ident, s) -> s.types.ownField(ident.name, s.owner, false),
		access: (node, s) -> s.types.accessType(node, s),
		element: null,
		call: (_, _) -> null,
		construction: null,
		arithmetic: (node, operands, s) -> s.types.arithmeticType(node, operands),
		reading: s -> s.seen
	};

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;

	/** What reads the written types of declarations; null for a plugin that reads none, which then knows no type. */
	private final _types: Null<TypeInfoProvider>;

	/** File -> its declarations' written types, by binding offset (`TypeInfoProvider.declaredTypeSources`). */
	private final _typeSources: Map<String, Map<Int, String>> = [];

	/** File -> the offsets `typeSourcesOf` answers for, ascending (`annotationOf`). */
	private final _typeSourceOffsets: Map<String, Array<Int>> = [];

	public function new(graph: CallGraph, trees: FunctionTrees, plugin: GrammarPlugin) {
		_graph = graph;
		_trees = trees;
		_plugin = plugin;
		_shape = plugin.refShape();
		_types = plugin is TypeInfoProvider ? cast plugin : null;
	}

	/** The written type of the argument `arg`, written in `file` by the function `callerId`; null where no arc types it. */
	public function argumentType(arg: QueryNode, file: String, callerId: String): Null<WrittenType> {
		final root: Null<QueryNode> = _trees.ofFile(file);
		if (root == null) return null;
		final tree: QueryNode = root;
		final scope: ArgumentScope = {
			types: this,
			file: file,
			root: tree,
			owner: _graph.node(callerId)?.typeName,
			seen: []
		};
		return TypingService.typeWalk(arg, _shape, HOST, scope);
	}

	/**
	 * How the argument `arg`, of the written type `given`, meets a parameter written `wanted` in `wantedFile` — one a call may
	 * leave out when `optional` — of `calleeId`, called by `callerId`.
	 */
	public function fit(
		arg: QueryNode, given: Null<WrittenType>, wanted: Null<String>, wantedFile: String, optional: Bool, callerId: String,
		calleeId: String
	): ArgumentFit {
		if (unwrap(arg).kind == _shape.nullLiteralKind) return optional ? Fits : MayFit;
		if (given == null || wanted == null) return MayFit;
		final a: Null<String> = coreName(given.text);
		final p: Null<String> = coreName(wanted);
		final widens: Map<String, Array<String>> = _shape.coreValueTypes?.widens ?? [];
		if (a != null && p != null) return a == p || (widens[a] ?? []).contains(p) ? Fits : Misfits;
		return a == null && p == null && given.file == wantedFile && sameNamedType(given.text, wanted, callerId, calleeId) ? Fits : MayFit;
	}

	/**
	 * The type annotation of the declaration `decl` of `file` (a parameter, a local), as written without whitespace: the one
	 * the plugin records at the declaration's binding, the first one inside its range. Null when it has none.
	 */
	public function annotationOf(decl: QueryNode, file: String): Null<String> {
		final span: Null<Span> = decl.span;
		if (span == null) return null;
		final sources: Map<Int, String> = typeSourcesOf(file);
		final best: Int = SortedOffsets.firstIn(typeSourceOffsetsOf(file, sources), span.from, span.to);
		final written: Null<String> = best < 0 ? null : sources[best];
		return written == null ? null : ~/\s+/g.replace(written, '');
	}

	/**
	 * The core type `text` names (`RefShape.coreValueTypes`), a `Null<…>` peeled, when no indexed type bears its name; null
	 * for any other type.
	 */
	public function coreName(text: String): Null<String> {
		final peeled: String = ~/\s+/g.replace(
			NominalTypes.unwrapNullable(StringTools.trim(text), _shape.memberTransparentWrapperTypeNames ?? [], _plugin.typeSyntax), ''
		);
		final names: Array<String> = _shape.coreValueTypes?.names ?? [];
		return names.contains(peeled) && _graph.types.declarationCount(peeled) == 0 ? peeled : null;
	}

	/** `node` with its parentheses peeled off. */
	public function unwrap(node: QueryNode): QueryNode {
		var at: QueryNode = node;
		while (at.kind == _shape.parenKind && at.children.length == 1) at = at.children[0];
		return at;
	}

	/** The written types of every annotated declaration of `file`, by binding offset (`TypeInfoProvider.declaredTypeSources`). */
	private function typeSourcesOf(file: String): Map<Int, String> {
		final known: Null<Map<Int, String>> = _typeSources[file];
		if (known != null) return known;
		final source: Null<String> = _graph.sourceOf(file);
		final provider: Null<TypeInfoProvider> = _types;
		final read: Map<Int, String> = source == null || provider == null ? [] : provider.declaredTypeSources(source);
		_typeSources[file] = read;
		return read;
	}

	private function typeSourceOffsetsOf(file: String, sources: Map<Int, String>): Array<Int> {
		final known: Null<Array<Int>> = _typeSourceOffsets[file];
		if (known != null) return known;
		final offsets: Array<Int> = [for (at in sources.keys()) at];
		offsets.sort(Reflect.compare);
		_typeSourceOffsets[file] = offsets;
		return offsets;
	}

	/** The binding offset of the value the identifier `ident` reads in `scope`'s file, or null when it binds none there. */
	private function bindingOf(ident: QueryNode, scope: ArgumentScope): Null<Int> {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		final bound: Null<Int> = name == null || span == null ? null : Refs.bindingAt(name, span.from, scope.root, _shape);
		return bound != null && bound >= 0 ? bound : null;
	}

	/**
	 * The type of the field `name` of `owner`'s chain, read bare (a supertype's static is not in scope bare) or, with
	 * `onSelf`, off the self reference: its written type, when the chain declares it as a field.
	 */
	private function ownField(name: Null<String>, owner: Null<String>, onSelf: Bool): Null<WrittenType> {
		if (name == null || owner == null) return null;
		final declaring: Null<String> = _graph.types.declaringTypeOf(owner, name);
		final m: Null<MemberInfo> = _graph.types.memberOnChain(owner, name);
		if (declaring == null || m == null) return null;
		final member: MemberInfo = m;
		if (!isField(member) || member.isStatic && !onSelf && declaring != owner) return null;
		final written: Null<String> = member.typeSource;
		return written == null ? null : { text: written, file: null };
	}

	/**
	 * What the field access `node` reads: a field of the enclosing type's chain off the self reference, or a static field
	 * off a type name no local binds — its written type.
	 */
	private function accessType(node: QueryNode, scope: ArgumentScope): Null<WrittenType> {
		final name: Null<String> = node.name;
		final receiver: QueryNode = unwrap(node.children[0]);
		final rname: Null<String> = receiver.name;
		if (name == null || receiver.kind != _shape.identKind || rname == null) return null;
		if (rname == _shape.selfReferenceText) return ownField(name, scope.owner, true);
		if (!SourceText.isUpperInitial(rname) || bindingOf(receiver, scope) != null) return null;
		final keys: Array<String> = _graph.typeKeysOf(scope.file, rname);
		final type: Null<String> = keys.length == 1 ? keys[0] : null;
		final m: Null<MemberInfo> = type == null || !_graph.types.isStatic(type, name) ? null : _graph.types.memberOnChain(type, name);
		final written: Null<String> = m == null || !isField(m) ? null : m.typeSource;
		return written == null ? null : { text: written, file: null };
	}

	/**
	 * The core number arithmetic over `operands` yields (`RefShape.arithmeticKinds`): the integer type when every operand is
	 * one and `node`'s operator keeps it, the real type when every operand is a core number; null otherwise.
	 */
	private function arithmeticType(node: QueryNode, operands: Array<WrittenType>): Null<WrittenType> {
		final core: Null<CoreValueTypes> = _shape.coreValueTypes;
		if (core == null) return null;
		var integral: Bool = !(_shape.realArithmeticKinds ?? []).contains(node.kind);
		for (o in operands) {
			final name: Null<String> = coreName(o.text);
			if (name != core.integer && name != core.real) return null;
			if (name != core.integer) integral = false;
		}
		return { text: integral ? core.integer : core.real, file: null };
	}

	/**
	 * Whether `given` and `wanted`, written in one file, name the same type: the same plain type name, neither side's
	 * function (`callerId`, `calleeId`) nor its type holding a type parameter of that name.
	 */
	private function sameNamedType(given: String, wanted: String, callerId: String, calleeId: String): Bool {
		final a: String = ~/\s+/g.replace(given, '');
		if (a != ~/\s+/g.replace(wanted, '')) return false;
		return switch _plugin.typeSyntax(a)?.shape {
			case Nominal(path, args) if (args.length == 0):
				_graph.typeParamBoundsOf(callerId, path) == null && _graph.typeParamBoundsOf(calleeId, path) == null;
			case _: false;
		};
	}

	/** Whether `m` is a field: a member holding a value, no function. */
	private inline function isField(m: MemberInfo): Bool {
		return (_shape.fieldDeclKinds ?? []).contains(m.kind);
	}

}

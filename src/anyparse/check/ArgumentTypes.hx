package anyparse.check;

import anyparse.query.AncestorTable;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphTypes.HeldFile;
import anyparse.query.IndexScope;
import anyparse.query.MemberLookup.MemberReading;
import anyparse.query.NominalTypes;
import anyparse.query.OperatorOverloads.OperatorResult;
import anyparse.query.Refs;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeTerm.TypeEnd;
import anyparse.query.TypingService;
import anyparse.runtime.SortedOffsets;
import anyparse.runtime.Span;

using StringTools;

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
	final caller: String;
	final seen: Array<Int>;
}

/**
 * The written type of a call's argument, and how it meets the type of a parameter (`ArgumentFit`) — what `ArgumentSlots`
 * decides the binding of a call by, for `ArgumentValues`. The shapes are THE structural walk every typer shares
 * (`TypingService.typeWalk`); this is its resolution over the call graph (`HOST`), answering a written type: a literal's
 * core type, a local's or a parameter's annotation (a local written with none by its initializer), a field of the
 * enclosing type's chain read bare or off the self reference, a static field or an enum-abstract value read off a
 * type name (each the type `MemberLookup.memberRead` answers, written in the declaring file), arithmetic over
 * core numbers (`RefShape.coreValueTypes`, `arithmeticKinds`) and the type an abstract's operator overload yields
 * (`OperatorOverloads`). Every type is resolved in the run's resolution index where it holds the file writing it
 * (`heldFor`: the std and the libraries resolve there), else in the call graph's. Everything else is untyped.
 *
 * A positive whitelist for the fit: two core types (each one no indexed type of its name shadows) fit when they are the same
 * or one widens to the other and misfit otherwise; `null` fits a parameter a call may leave out; the same plain type
 * name written in one file, no type parameter on either side, fits; a core type and a plain name, or two plain names
 * (no type argument, each resolved where it is written) fit or misfit as the typing service casts the argument
 * (`Unification.casts`: a subclass fits, an unrelated class misfits, an abstract through its `from` / `to` clauses and
 * its `@:from` / `@:to` members). Every other pair — a type parameter, a generic type, an abstract the cast graph does not
 * model (`openfl.text.TextFormatAlign`, an abstract in one `#if` branch and a typedef in another) — may fit.
 */
@:nullSafety(Strict)
final class ArgumentTypes {

	/** The call graph's resolution of the shared walk, answering a written type; an arc it does not know answers null. */
	private static final HOST: TypingHost<WrittenType, ArgumentScope> = {
		peel: (node, s) -> s.types.unwrap(node),
		isAccess: (kind, s) -> kind == s.types._shape.fieldAccessKind,
		literal: (typeName, _) -> {text: typeName, file: null },
		ascribed: null,
		self: (_, _) -> null,
		binding: (ident, s) -> s.types.bindingOf(ident, s),
		bound: (from, s) -> {
			final written: Null<String> = s.types.typeSourcesOf(s.file)[from];
			written == null ? null : { text: written, file: s.file };
		},
		initializer: (_, use, s) -> NominalTypes.localInitializer(use, s.root, s.types._shape, s.types.typeSourcesOf(s.file)),
		loopElement: (_, _) -> null,
		parameter: null,
		unbound: (ident, s) -> s.types.ownField(ident.name, s.owner, false, s),
		access: (node, s) -> s.types.accessType(node, s),
		element: null,
		call: (_, _) -> null,
		construction: null,
		contextual: null,
		arithmetic: (node, operands, s) -> s.types.arithmeticType(node, operands, s),
		reading: s -> s.seen
	};

	/** File -> its declarations' written types, by binding offset (`TypeInfoProvider.declaredTypeSources`). */
	private final _typeSources: Map<String, Map<Int, String>> = [];

	/** File -> the offsets `typeSourcesOf` answers for, ascending (`annotationOf`). */
	private final _typeSourceOffsets: Map<String, Array<Int>> = [];

	/** File -> the index entry its written types are resolved in (`heldFor`), remembered per file, null for none. */
	private final _held: Map<String, Null<HeldFile>> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;

	/** What reads the written types of declarations; null for a plugin that reads none, which then knows no type. */
	private final _types: Null<TypeInfoProvider>;

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
			caller: callerId,
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
		if (a == null && p == null && given.file == wantedFile && sameNamedType(given.text, wanted, callerId, calleeId)) return Fits;
		return castFit(given, a, wanted, p, wantedFile, callerId, calleeId);
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
	 * The member record of the function declared at offset `from` of `file`, in the index its types resolve in (`heldFor`):
	 * what it declares beyond its body's parameters — its signature overloads. Null for a function no type of the file
	 * declares (a local function) and a file no index holds.
	 */
	public function memberAt(file: String, from: Int): Null<MemberInfo> {
		final held: Null<HeldFile> = heldFor(file);
		if (held == null) return null;
		for (t in held.info.types) for (m in t.members) if (m.declFrom == from) return m;
		return null;
	}

	/**
	 * The core type `text` names (`RefShape.coreValueTypes`), a `Null<…>` peeled, when no indexed type bears its name; null
	 * for any other type.
	 */
	public function coreName(text: String): Null<String> {
		final peeled: String = ~/\s+/g.replace(
			NominalTypes.unwrapNullable(text.trim(), _shape.memberTransparentWrapperTypeNames ?? [], _plugin.typeSyntax), ''
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

	/** Whether `m` is a field: a member holding a value, no function. */
	private inline function isField(m: MemberInfo): Bool {
		return (_shape.fieldDeclKinds ?? []).contains(m.kind);
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
	 * `onSelf`, off the self reference, in `scope`'s file: the type a read of it carries
	 * (`MemberLookup.memberRead`), written in the file of the declaration holding it — none for a field
	 * of a supertype whose type parameters the chain substitutes, with arguments it writes elsewhere.
	 */
	private function ownField(name: Null<String>, owner: Null<String>, onSelf: Bool, scope: ArgumentScope): Null<WrittenType> {
		final held: Null<HeldFile> = heldFor(scope.file);
		if (name == null || owner == null || held == null) return null;
		final decl: Null<ResolvedType> = held.index.refs.resolveTypeRef(owner, held.info);
		final read: Null<MemberReading> = decl == null ? null : held.index.typing.members.memberRead(decl, name, decl.type.typeParamNames);
		if (decl == null || read == null) return null;
		final own: Bool = AncestorTable.same(read.host, decl);
		if (!isField(read.member) || read.member.isStatic && !onSelf && !own) return null;
		// what the chain substitutes for a supertype's parameters is written elsewhere
		final written: Bool = own || read.text == read.member.typeSource || read.host.type.typeParamNames.length == 0;
		return { text: read.text, file: written ? read.host.file.file : null };
	}

	/**
	 * What the field access `node` reads: a field of the enclosing type's chain off the self reference, or, off a type name no
	 * local binds, a static field of the type it resolves to (statics are not inherited) — the type a read of it carries,
	 * written in the file of its declaration — or a value of that type written with no type, an enum-abstract value, of the
	 * type itself (`AbstractCasts.holdsUntypedValue`).
	 */
	private function accessType(node: QueryNode, scope: ArgumentScope): Null<WrittenType> {
		final name: Null<String> = node.name;
		final receiver: QueryNode = unwrap(node.children[0]);
		final rname: Null<String> = receiver.name;
		if (name == null || receiver.kind != _shape.identKind || rname == null) return null;
		if (rname == _shape.selfReferenceText) return ownField(name, scope.owner, true, scope);
		final held: Null<HeldFile> = heldFor(scope.file);
		if (!SourceText.isUpperInitial(rname) || bindingOf(receiver, scope) != null || held == null) return null;
		final decl: Null<ResolvedType> = held.index.refs.resolveTypeRef(rname, held.info, receiver.span?.from);
		if (decl == null) return null;
		final typing: TypingService = held.index.typing;
		if (typing.casts.holdsUntypedValue(decl, name)) return { text: decl.type.name, file: decl.file.file };
		final read: Null<MemberReading> = typing.members.memberRead(decl, name, []);
		if (read == null) return null;
		final member: MemberInfo = read.member;
		final own: Bool = AncestorTable.same(read.host, decl);
		return own && isField(member) && member.isStatic ? { text: read.text, file: decl.file.file } : null;
	}

	/**
	 * The type the operator `node` over `operands` yields: over core value types the type the language's own operator
	 * yields (`TypingService.coreOperatorType`), a compound assignment the type of its target
	 * (`TypingService.compoundKeepsTarget`); over two operands an abstract takes part in, the type its overload of a binary
	 * operator yields (`overloadType`); null otherwise.
	 */
	private function arithmeticType(node: QueryNode, operands: Array<WrittenType>, scope: ArgumentScope): Null<WrittenType> {
		final cores: Array<Null<String>> = [for (o in operands) coreName(o.text)];
		if (_shape.execution?.compoundAssignOperators?.exists(node.kind) == true)
			return TypingService.compoundKeepsTarget(node.kind, cores, _shape) ? operands[0] : null;
		final core: Null<String> = TypingService.coreOperatorType(node.kind, cores, _shape);
		return if (core != null)
			{ text: core, file: null }
		else if (operands.length == 2)
			overloadType(node.kind, operands, scope)
		else
			null;
	}

	/**
	 * The type an abstract's overload of the binary operator of kind `kind` yields over the two `operands`
	 * (`OperatorOverloads.binaryResult`), each operand's type resolved in one index, where it is written: written in the
	 * file of the abstract declaring the overload. Null where an operand's type is not resolved there, and where no overload
	 * is decided.
	 */
	private function overloadType(kind: String, operands: Array<WrittenType>, scope: ArgumentScope): Null<WrittenType> {
		final index: Null<SymbolIndex> = operandIndex(operands[0]) ?? operandIndex(operands[1]);
		if (index == null) return null;
		final left: Null<TypeEnd> = operandEnd(operands[0], index, scope.caller);
		final right: Null<TypeEnd> = operandEnd(operands[1], index, scope.caller);
		final result: Null<OperatorResult> = left == null || right == null ? null : index.typing.operators.binaryResult(kind, left, right);
		return result == null ? null : { text: result.text, file: result.host.file.file };
	}

	/** The index the type `w` is resolved in where it is written (`heldFor`); null for a type no file writes. */
	private function operandIndex(w: WrittenType): Null<SymbolIndex> {
		final file: Null<String> = w.file;
		return file == null ? null : heldFor(file)?.index;
	}

	/**
	 * The end the operand type `w` stands for in `index`, as an operator overload's parameter must EQUAL it (`type_eq
	 * EqStrict`, which sees through `Null<…>` there: `a - a` with `a: Null<U>` takes `U`'s overload, 4.3.7): a core value
	 * type by its name, else the plain name written in a file `index` holds (`endOf`); null for any other.
	 */
	private function operandEnd(w: WrittenType, index: SymbolIndex, functionId: String): Null<TypeEnd> {
		final core: Null<String> = coreName(w.text);
		if (core != null) return Core(core);
		final file: Null<String> = w.file;
		final held: Null<HeldFile> = file == null ? null : heldFor(file);
		return held == null || held.index != index ? null : endOf(w.text, held, functionId);
	}

	/**
	 * The index entry the types written in `file` are resolved in: the run's resolution index when it holds the file — the
	 * std and the libraries resolve there, the call graph's own index holds neither the std nor a library it has no body
	 * of — else the graph's entry (`CallGraphTypes.heldFile`); null for a file neither holds.
	 */
	private function heldFor(file: String): Null<HeldFile> {
		if (_held.exists(file)) return _held[file];
		// the host builds the resolution index once per run
		final wide: Null<SymbolIndex> = IndexScope.resolutionIndexOf(_plugin);
		final info: Null<FileInfo> = wide?.fileInfo(file);
		final held: Null<HeldFile> = wide != null && info != null ? { index: wide, info: info } : _graph.types.heldFile(file);
		_held[file] = held;
		return held;
	}

	/**
	 * How the argument type `given` meets the parameter type `wanted`, written in `wantedFile`, each side a core value type
	 * by its name (`givenCore`, `wantedCore`) or a type written as a plain name — no type argument, a `Null<…>` peeled
	 * (`tUnification.ml`: `Null<T>` unifies as `T` both ways), not a type parameter of its function (`callerId`,
	 * `calleeId`) — resolved in the file writing it, one index holding both: the typing service's answer on the argument's
	 * implicit cast (`Unification.casts`: a subclass fits, an unrelated class misfits, an abstract through its cast graph).
	 * `MayFit` for every other pair.
	 */
	private function castFit(
		given: WrittenType, givenCore: Null<String>, wanted: String, wantedCore: Null<String>, wantedFile: String, callerId: String,
		calleeId: String
	): ArgumentFit {
		final to: Null<HeldFile> = heldFor(wantedFile);
		if (to == null) return MayFit;
		final index: SymbolIndex = to.index;
		final w: Null<TypeEnd> = wantedCore != null ? Core(wantedCore) : endOf(wanted, to, calleeId);
		final g: Null<TypeEnd> = givenCore != null ? Core(givenCore) : givenEnd(given, index, callerId);
		return w == null || g == null ? MayFit : index.typing.unification.casts(g, w);
	}

	/** The end the argument type `given` stands for, when the file writing it is held by `index`; null otherwise. */
	private function givenEnd(given: WrittenType, index: SymbolIndex, callerId: String): Null<TypeEnd> {
		final file: Null<String> = given.file;
		final from: Null<HeldFile> = file == null ? null : heldFor(file);
		return from == null || from.index != index ? null : endOf(given.text, from, callerId);
	}

	/**
	 * The end the type `text`, written in `held`'s file by the function `functionId`, stands for: the dynamic type written
	 * bare, the declaration a plain name resolves to (`plainDecl`) as the typing service reads it (`AbstractCasts.declEnd`);
	 * null for any other type.
	 */
	private function endOf(text: String, held: HeldFile, functionId: String): Null<TypeEnd> {
		final peeled: String = ~/\s+/g.replace(
			NominalTypes.unwrapNullable(text.trim(), _shape.memberTransparentWrapperTypeNames ?? [], _plugin.typeSyntax), ''
		);
		if (peeled == _shape.rawDynamicTypeName) return Dyn;
		final decl: Null<ResolvedType> = plainDecl(text, held, functionId);
		return decl == null ? null : held.index.typing.casts.declEnd(decl);
	}

	/**
	 * The declaration the written type `text` names in `held`'s file, its `Null<…>` peeled, when it is a plain name written
	 * with no type argument and no type parameter of the function `functionId` or of its type; null otherwise.
	 */
	private function plainDecl(text: String, held: HeldFile, functionId: String): Null<ResolvedType> {
		final peeled: String = NominalTypes.memberLookupReceiverSource(
			text.trim(), _shape.memberTransparentWrapperTypeNames ?? [], _plugin.typeSyntax
		);
		return switch _plugin.typeSyntax(peeled)?.shape {
			case Nominal(path, args) if (args.length == 0 && _graph.typeParamBoundsOf(functionId, path) == null):
				held.index.refs.resolveTypeRef(path, held.info);
			case _: null;
		};
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

}

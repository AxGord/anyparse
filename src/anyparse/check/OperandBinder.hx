package anyparse.check;

import anyparse.query.CallGraphNames;
import anyparse.query.CasePatterns;
import anyparse.query.DeclaredNullity;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * What the declared type of an operand binds to, for ONE file — every type bound in the scope of the
 * file that WRITES it, never by its simple name. This is not a typer of its own: the shapes are walked
 * by THE structural walk every typer shares (`NominalTypes.typeWalk`), and this class is that walk's
 * BINDING host (`HOST`) — the resolution model whose currency is what a written type binds to
 * (`TypeNameBinding.Tier`), beside the index's written sources and the call graph's keyed ones:
 *
 *  - a read of a binding this file declares (a local, a parameter, a field, a `$name` fragment):
 *    its annotation, here;
 *  - a call to a function this file declares: its written return type, here, with the function's
 *    own type parameters in scope;
 *  - `recv.m` and `recv.m(…)`: the receiver's own declarations (typed the same way, or a type name
 *    for a static access), then `m` as each of them DECLARES it — its type or its return type, bound
 *    in the declaring file with the owner's and the method's type parameters shadowing;
 *  - a construction `new T(…)`: the type it writes, here.
 *
 * Everything else is `Unknown`: an inherited member, a receiver no rule above types, a member whose
 * type is not written. A built-in candidate among several drops out of a `Bound` answer, since it can
 * overload nothing.
 */
@:nullSafety(Strict)
final class OperandBinder {

	/** The binding resolution of the shared walk: each arc answered in this file's scope, an arc it does not know null. */
	private static final HOST: TypingHost<Tier, OperandBinder> = {
		peel: (node, _) -> node,
		isAccess: (kind, b) -> kind == b._shape.fieldAccessKind,
		literal: null,
		self: (_, _) -> null,
		binding: (ident, b) -> b.hitOf(ident)?.bindingSpan?.from,
		bound: (from, b) -> b._declared.writtenHeadTier(from, b._wrappers, b._builtins),
		initializer: (_, _, _) -> null,
		loopElement: (_, _) -> null,
		unbound: (_, _) -> null,
		access: (node, b) -> b.accessTier(node),
		element: null,
		call: (node, b) -> b.callTier(node),
		construction: (node, b) -> b.constructionTier(node),
		reading: b -> b._reading
	};

	/** The binding offsets whose unannotated type the walk is reading right now (`TypingHost.reading`). */
	private final _reading: Array<Int> = [];

	private final _file: String;
	private final _source: String;
	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _index: SymbolIndex;
	private final _declared: DeclaredNullity;
	private final _builtins: Array<String>;
	private final _wrappers: Array<String>;
	private final _identKinds: Array<String>;
	private final _fnKinds: Array<String>;

	private function new(
		file: String, source: String, tree: QueryNode, shape: RefShape, index: SymbolIndex, provider: TypeInfoProvider
	) {
		_file = file;
		_source = source;
		_tree = tree;
		_shape = shape;
		_index = index;
		_declared = DeclaredNullity.of(file, tree, source, shape, provider, index.typeSyntax, () -> index);
		_builtins = builtinNamesOf(shape);
		_wrappers = shape.memberTransparentWrapperTypeNames ?? [];
		_identKinds = [
			for (kind in [shape.identKind, shape.stringInterpIdentKind]) if (kind != null) kind
		];
		_fnKinds = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
	}

	/**
	 * What a type NAME written in this file — at offset `at` when known — binds to
	 * at the file's top level, tier by tier; `Unknown` when the file is not indexed.
	 */
	public function typeNameTier(name: String, ?at: Int): Tier {
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		return fi == null ? Unknown : _index.refs.names.tierOf(name, fi, at);
	}

	/** What the type `written` at offset `at` of this file binds to, with the type parameters in scope there. */
	public inline function writtenTier(written: Null<String>, at: Int): Tier {
		return _declared.headTier(written, at, _wrappers, _builtins);
	}

	/** What `operand`'s declared type binds to: the shared walk over this file's binding resolution (`HOST`). */
	public function tierOf(operand: QueryNode): Tier {
		return NominalTypes.typeWalk(operand, _shape, HOST, this) ?? Unknown;
	}

	/** `recv.m` read: the member as the receiver's declarations declare it. */
	private function accessTier(access: QueryNode): Tier {
		final name: Null<String> = access.name;
		return name == null || access.children.length != 1 ? Unknown : memberTier(access.children[0], name, false);
	}

	/** A call: to a function this file declares by its bare name, or to `recv.m(…)` as the receiver's declarations declare `m`. */
	private function callTier(call: QueryNode): Tier {
		final callee: QueryNode = call.children[0];
		if (_identKinds.contains(callee.kind)) return localCallTier(callee);
		final name: Null<String> = callee.name;
		return name == null || callee.kind != _shape.fieldAccessKind || callee.children.length != 1
			? Unknown
			: memberTier(callee.children[0], name, true);
	}

	/** A construction `new T(…)`: the type it writes, bound here. */
	private function constructionTier(node: QueryNode): Tier {
		final at: Null<Span> = node.span;
		return at == null ? Unknown : writtenTier(node.name, at.from);
	}

	/**
	 * The reference hit of an identifier read, or null for anything else — and null for a read a
	 * `case` capture may bind instead of the declaration the hit names (`capturedBetween`).
	 */
	private function hitOf(ident: QueryNode): Null<RefHit> {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null || !_identKinds.contains(ident.kind)) return null;
		final hit: Null<RefHit> = TypeResolver.resolveBindingHit(name, span, _tree, _shape);
		return hit == null || capturedBetween(name, span, hit.bindingSpan?.from) ? null : hit;
	}

	/**
	 * Whether a `case` branch holding the read at `at` may capture `name` in its pattern while the
	 * binding the reference walk found (`bindingFrom`) lies OUTSIDE that branch. The walk binds a decided
	 * capture inside its arm, so this answers true only for a pattern name `Refs` could not decide
	 * (`CasePatterns.scan` with no constants counts every name a capture MAY bind): its answer is then the
	 * outer declaration a capture would shadow, and over-counting only declines.
	 */
	private function capturedBetween(name: String, at: Span, bindingFrom: Null<Int>): Bool {
		final branchKind: Null<String> = _shape.caseBranchKind;
		if (branchKind == null) return false;
		final from: Int = bindingFrom ?? -1;
		function walk(node: QueryNode): Bool {
			final span: Null<Span> = node.span;
			if (span == null || at.from < span.from || at.to > span.to) return span == null && node.children.exists(walk);
			final inside: Bool = from >= span.from && from < span.to;
			if (node.kind == branchKind && !inside && CasePatterns.scan(node, _shape, []).idents.exists(ident -> ident.name == name))
				return true;
			return node.children.exists(walk);
		}
		return walk(_tree);
	}

	/** A call whose callee names a function this file declares: that function's written return type. */
	private function localCallTier(callee: QueryNode): Tier {
		final hit: Null<RefHit> = hitOf(callee);
		final from: Null<Int> = hit?.bindingSpan?.from;
		final fn: Null<QueryNode> = hit?.bindingNode;
		if (from == null || fn == null) return Unknown;
		final declaration: QueryNode = fn;
		final member: Null<MemberInfo> = _index.fileInfo(_file)?.types.flatMap(t -> t.members)
			.find(m -> m.declFrom == declaration.span?.from);
		if (member != null && !typedByItsReturn(member)) return Unknown;
		return _fnKinds.contains(declaration.kind)
			? _declared.headTier(
				CallGraphNames.returnSourceOf(declaration, _source, _shape.typeAnnotationKinds ?? []), from, _wrappers, _builtins
			)
			: Unknown;
	}

	/**
	 * `name` read (or, with `call`, called) on `receiver`: the member as every declaration of the
	 * receiver's type declares it DIRECTLY, each bound in its declaring file.
	 */
	private function memberTier(receiver: QueryNode, name: String, call: Bool): Tier {
		final owners: Null<Array<ResolvedType>> = receiverDecls(receiver);
		if (owners == null) return Unknown;
		final found: Array<ResolvedType> = [];
		for (owner in owners) {
			final members: Array<MemberInfo> = owner.type.members.filter(m -> m.name == name);
			final source: Null<String> = _index.sourceOf(owner.file.file);
			final ownParams: Array<String> = owner.type.typeParamNames;
			if (members.length == 0 || source == null || owner.type.typeParamArity != ownParams.length) return Unknown;
			for (m in members) {
				final written: Null<String> = call ? m.returnSource : m.typeSource;
				if (written == null || (call && !typedByItsReturn(m))) return Unknown;
				final params: Array<String> = call ? ownParams.concat(m.typeParamNames) : ownParams;
				switch DeclaredNullity.headTierIn(written, owner.file, m.declFrom, _index, params, _wrappers, _builtins) {
					case Bound(decls):
						for (d in decls) found.push(d);
					case Free:
					case Unknown:
						return Unknown;
				}
			}
		}
		return found.length == 0 ? Free : Bound(found);
	}

	/**
	 * Whether a call to `m` has the type its written return type names: not when `@:overload` offers
	 * other signatures to select, nor for a macro, whose written return is the `Expr` it builds rather
	 * than the type of the expression the call site receives.
	 */
	private static inline function typedByItsReturn(m: MemberInfo): Bool {
		return !m.hasOverloadMeta && !m.isMacro;
	}

	/**
	 * The declarations of the receiver's type: what an operand receiver binds to, or — for an
	 * upper-initial name no binding in this file claims — the type that name binds to, for a static
	 * access. Null when neither is proven, including a built-in receiver whose declaration the index
	 * does not hold.
	 */
	public function receiverDecls(receiver: QueryNode): Null<Array<ResolvedType>> {
		switch tierOf(receiver) {
			case Bound(decls):
				return decls;
			case Free:
				return null;
			case Unknown:
		}
		final name: Null<String> = receiver.name;
		final hit: Null<RefHit> = hitOf(receiver);
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		if (name == null || fi == null || !_identKinds.contains(receiver.kind) || !SourceText.isUpperInitial(name)) return null;
		if (hit != null && (hit.bindingSpan != null || hit.bindingNode != null)) return null;
		return switch _index.refs.names.tierOf(name, fi, receiver.span?.from) {
			case Bound(decls): decls;
			case _: null;
		};
	}

	/**
	 * THE way a rule obtains the binder of one file — the operator-overload gate (`OperatorSelection.typingFor`),
	 * `redundant-tostring` and `prefer-bind` alike: over `index`, the grammar's type information and its built-in type
	 * names. Null when the grammar carries no type information.
	 */
	public static function forFile(
		plugin: GrammarPlugin, file: String, source: String, tree: QueryNode, index: SymbolIndex
	): Null<OperandBinder> {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return provider == null ? null : new OperandBinder(file, source, tree, plugin.refShape(), index, provider);
	}

	/** The type names the grammar declares built in — a literal's type or a basic value type — each once. */
	public static function builtinNamesOf(shape: RefShape): Array<String> {
		final out: Array<String> = [for (name in shape.literalTypeNames ?? []) name];
		for (name in shape.nonNullableTypeNames ?? []) if (!out.contains(name)) out.push(name);
		return out;
	}

}

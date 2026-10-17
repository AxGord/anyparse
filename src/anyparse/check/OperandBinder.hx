package anyparse.check;

import anyparse.check.UsingScan.UsingHeader;
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
		self: (node, b) -> b.selfTier(node),
		binding: (ident, b) -> b.hitOf(ident)?.bindingSpan?.from,
		bound: (from, b) -> b._annotations.exists(from) ? b._declared.writtenHeadTier(from, b._wrappers, b._builtins) : null,
		initializer: (_, use, b) -> b.initializerOf(use),
		loopElement: (_, _) -> null,
		unbound: (ident, b) -> b.inheritedTier(ident, false),
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

	/** This file's written type annotations by binding offset (`TypeInfoProvider.declaredTypeSources`). */
	private final _annotations: Map<Int, String>;

	/** This file's `using` modules in declaration order, read on first demand; null when a `#if` guards one. */
	private final _usings: () -> Null<Array<String>>;

	private function new(
		file: String, source: String, tree: QueryNode, shape: RefShape, index: SymbolIndex, provider: TypeInfoProvider,
		usings: () -> Null<Array<String>>
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
		_annotations = provider.declaredTypeSources(source);
		_usings = usings;
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

	/** The expression initialising the local `use` reads, written with no type: the local holds ITS type (`NominalTypes.localInitializer`). */
	private function initializerOf(use: QueryNode): Null<QueryNode> {
		return NominalTypes.localInitializer(use, _tree, _shape, _annotations);
	}

	/**
	 * The self reference: the enclosing type itself — or, inside an abstract, the underlying type it writes, which 4.3.7
	 * types `this` as there. `Unknown` outside a type, and for an underlying type that is one of the abstract's own type
	 * parameters or is not written as a plain path.
	 */
	private function selfTier(node: QueryNode): Tier {
		final span: Null<Span> = node.span;
		final owner: Null<ResolvedType> = span == null ? null : enclosingDeclaration(span);
		if (owner == null) return Unknown;
		final t: TypeDeclInfo = owner.type;
		if (!(_shape.underlyingThisTypeKinds ?? []).contains(t.kind)) return Bound([owner]);
		final underlying: Null<String> = t.underlyingRaw;
		return underlying == null || t.typeParamNames.contains(underlying) ? Unknown : writtenTier(underlying, t.span.from);
	}

	/** The declaration of the type of this file holding `at`, or null outside every type. */
	private function enclosingDeclaration(at: Span): Null<ResolvedType> {
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		final found: Null<TypeDeclInfo> = fi?.types.find(t -> t.span.from <= at.from && at.to <= t.span.to);
		return fi == null || found == null ? null : { type: found, file: fi };
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

	/**
	 * A call whose callee is a bare name: a function this file declares (its written return type, here), or — bound by no
	 * declaration of this file — a method the enclosing type inherits (`inheritedTier`).
	 */
	private function localCallTier(callee: QueryNode): Tier {
		final hit: Null<RefHit> = hitOf(callee);
		final from: Null<Int> = hit?.bindingSpan?.from;
		final fn: Null<QueryNode> = hit?.bindingNode;
		if (!bindsHere(hit)) return inheritedTier(callee, true);
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
	 * `name` read (or, with `call`, called) on `receiver`: the member as every declaration of the receiver's type declares
	 * it — directly, or up its closure when every link of it resolves (`declarationOf`) — each bound in its declaring file.
	 * A receiver of ONE declaration whose closure provably declares no `name` is read through what the language binds
	 * there instead: a call through a `using` static extension (`extensionTier`), a read through an abstract's `@:op(a.b)`
	 * (`resolveTier`).
	 */
	private function memberTier(receiver: QueryNode, name: String, call: Bool): Tier {
		final owners: Null<Array<ResolvedType>> = receiverDecls(receiver);
		if (owners == null) return Unknown;
		if (owners.length == 1 && _index.members.declarationLacksMember(owners[0], name))
			return call ? extensionTier(owners[0], name) : resolveTier(owners[0], name);
		final found: Array<ResolvedType> = [];
		for (owner in owners) {
			final declared: Null<{ members: Array<MemberInfo>, host: ResolvedType }> = declarationOf(owner, name);
			if (declared == null) return Unknown;
			switch boundMembers(declared.members, declared.host, call) {
				case Bound(decls):
					for (d in decls) found.push(d);
				case Free:
				case Unknown:
					return Unknown;
			}
		}
		return found.length == 0 ? Free : Bound(found);
	}

	/**
	 * What `members` — the declarations of one member on `host` — give a read of it (or, with `call`, a call): each written
	 * type or return, bound where `host` declares it with its own and the method's type parameters shadowing. `Unknown`
	 * when one writes none, when `@:overload` or a macro makes the written return not the call's type, and when `host`'s
	 * file is not read.
	 */
	private function boundMembers(members: Array<MemberInfo>, host: ResolvedType, call: Bool): Tier {
		final ownParams: Array<String> = host.type.typeParamNames;
		if (members.length == 0 || _index.sourceOf(host.file.file) == null || host.type.typeParamArity != ownParams.length) return Unknown;
		final found: Array<ResolvedType> = [];
		for (m in members) {
			final written: Null<String> = call ? m.returnSource : m.typeSource;
			if (written == null || (call && !typedByItsReturn(m))) return Unknown;
			final params: Array<String> = call ? ownParams.concat(m.typeParamNames) : ownParams;
			switch DeclaredNullity.headTierIn(written, host.file, m.declFrom, _index, params, _wrappers, _builtins) {
				case Bound(decls):
					for (d in decls) found.push(d);
				case Free:
				case Unknown:
					return Unknown;
			}
		}
		return found.length == 0 ? Free : Bound(found);
	}

	/**
	 * Where `owner` declares `name`: its own members, else the nearest link of its closure that does — asked only of a
	 * closure that resolves link by link and brings no extensions (`MemberLookup.declarationFreeOfExtensionTypes`), since a
	 * covariant override on a link the index cannot read would be the declaration the compiler types the access by.
	 */
	private function declarationOf(owner: ResolvedType, name: String): Null<{ members: Array<MemberInfo>, host: ResolvedType }> {
		final own: Array<MemberInfo> = owner.type.members.filter(m -> m.name == name);
		return if (own.length > 0)
			{ members: own, host: owner }
		else if (_index.members.declarationFreeOfExtensionTypes(owner))
			_index.members.declaringMember(owner, name)
		else
			null;
	}

	/**
	 * An identifier no declaration of this file binds, read (or, with `call`, called): a member the enclosing type
	 * INHERITS, through an implicit `this` — 4.3.7 resolves a bare name to a field of the class before an import or a
	 * module-level value — bound where it is declared (`declarationOf`). `Unknown` for a name a `case` capture may bind,
	 * one the reference walk binds but this binder declines, and a supertype's static, which is not in scope bare.
	 */
	private function inheritedTier(ident: QueryNode, call: Bool): Tier {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null || !_identKinds.contains(ident.kind)) return Unknown;
		if (bindsHere(TypeResolver.resolveBindingHit(name, span, _tree, _shape)) || capturedBetween(name, span, null)) return Unknown;
		final owner: Null<ResolvedType> = enclosingDeclaration(span);
		final declared: Null<{ members: Array<MemberInfo>, host: ResolvedType }> = owner == null ? null : declarationOf(owner, name);
		return declared == null || declared.members.exists(m -> m.isStatic) ? Unknown : boundMembers(declared.members, declared.host, call);
	}

	/**
	 * `recv.method(…)` on a receiver of the one declaration `owner`, whose closure provably declares no `method`: the static
	 * extension the language binds there — from the LAST `using` of this file whose module declares a static `method`, which
	 * must take `owner` itself as its first parameter — its written return bound where it is declared. 4.3.7 binds a type's
	 * own `@:using` ahead of every `using` of the file and an extension declared on ANY type of a used module, so a closure
	 * bringing extensions, a guarded `using`, a module the index does not hold or declaring the name twice, and a first
	 * parameter that is not exactly `owner` (a supertype, a type parameter, a structure) are each `Unknown`.
	 */
	private function extensionTier(owner: ResolvedType, method: String): Tier {
		final usings: Null<Array<String>> = _usings();
		if (usings == null || !_index.members.declarationFreeOfExtensionTypes(owner)) return Unknown;
		var k: Int = usings.length;
		while (k-- > 0) {
			final hosts: Null<Array<ResolvedType>> = _index.values.usingHosts(usings[k]);
			if (hosts == null) return Unknown;
			final named: Array<{ host: ResolvedType, member: MemberInfo }> = [
				for (h in hosts) for (m in h.type.members) if (m.name == method) { host: h, member: m }
			];
			if (named.length == 0) continue;
			if (named.length != 1) return Unknown;
			final host: ResolvedType = named[0].host;
			final m: MemberInfo = named[0].member;
			final first: Null<String> = m.firstParamTypeSource;
			final params: Array<String> = host.type.typeParamNames.concat(m.typeParamNames);
			if (!m.isStatic || m.guarded || first == null || host.type.typeParamArity != host.type.typeParamNames.length) return Unknown;
			return switch DeclaredNullity.headTierIn(first, host.file, m.declFrom, _index, params, _wrappers, _builtins) {
				case Bound(decls) if (decls.length == 1 && sameDeclaration(decls[0], owner)): boundMembers([m], host, true);
				case _: Unknown;
			};
		}
		return Unknown;
	}

	/**
	 * `recv.name` read on a receiver of the one declaration `owner`, whose closure provably declares no `name`: an
	 * abstract's `@:op(a.b)` member, which 4.3.7 calls for a field the abstract does not declare — unless a static extension
	 * of that name is in scope, which it binds FIRST (`r.foo` under `using Ext` is the extension even beside a resolver), so
	 * every `using` this file sees, its own and the ambient chain's, must provably declare no static `name`. `Unknown` for
	 * every other owner: not an abstract, built by a macro, under a `#if`, declaring several resolvers, or bringing
	 * extensions of its own or forwarding its underlying type (`MemberLookup.declarationFreeOfExtensionTypes`).
	 */
	private function resolveTier(owner: ResolvedType, name: String): Tier {
		final t: TypeDeclInfo = owner.type;
		final fieldKind: Null<String> = _shape.fieldAccessKind;
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		final resolvers: Array<MemberInfo> = fieldKind == null ? [] : t.members.filter(m -> m.operatorOverloads.contains(fieldKind));
		if (
			fi == null || resolvers.length != 1 || !(_shape.underlyingThisTypeKinds ?? []).contains(t.kind) || t.hasBuild || t.hasAutoBuild
			|| t.guarded || !_index.members.declarationFreeOfExtensionTypes(owner)
		)
			return Unknown;
		final scope: Null<Array<ResolvedType>> = _index.values.usingDeclarations(fi);
		return scope == null || scope.exists(h -> h.type.members.exists(m -> m.name == name))
			? Unknown
			: boundMembers(resolvers, owner, true);
	}

	/** Whether `a` and `b` are the one declaration: the same file, the same type at the same offset. */
	private static inline function sameDeclaration(a: ResolvedType, b: ResolvedType): Bool {
		return a.file.file == b.file.file && a.type.name == b.type.name && a.type.span.from == b.type.span.from;
	}

	/** Whether the reference walk's `hit` binds its name to a declaration of this file — a hit may name nothing. */
	private static inline function bindsHere(hit: Null<RefHit>): Bool {
		return hit != null && (hit.bindingSpan != null || hit.bindingNode != null);
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
		if (bindsHere(hit)) return null;
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
		var read: Bool = false;
		var usings: Null<Array<String>> = null;
		function usingModules(): Null<Array<String>> {
			if (!read) {
				read = true;
				final header: UsingHeader = UsingScan.headerOf(tree, source, plugin);
				usings = header.guardedUsings.length > 0 ? null : UsingScan.usingModules(header);
			}
			return usings;
		}
		return provider == null ? null : new OperandBinder(file, source, tree, plugin.refShape(), index, provider, usingModules);
	}

	/** The type names the grammar declares built in — a literal's type or a basic value type — each once. */
	public static function builtinNamesOf(shape: RefShape): Array<String> {
		final out: Array<String> = [for (name in shape.literalTypeNames ?? []) name];
		for (name in shape.nonNullableTypeNames ?? []) if (!out.contains(name)) out.push(name);
		return out;
	}

}

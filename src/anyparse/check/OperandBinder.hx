package anyparse.check;

import anyparse.query.CallGraphNames;
import anyparse.query.CasePatterns;
import anyparse.query.DeclaredNullity;
import anyparse.query.ExpectedTypes;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeResolver;
import anyparse.query.TypeSyntax;
import anyparse.query.TypingService;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * What the declared type of an operand binds to, for ONE file — every type bound in the scope of the
 * file that WRITES it, never by its simple name. This is not a typer of its own: the shapes are walked
 * by THE structural walk every typer shares (`TypingService.typeWalk`), and this class is that walk's
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
 *  - a construction `new T(…)`: the type it writes, here;
 *  - a lambda's parameter written with no type: the parameter of the function type the lambda is
 *    expected to be, read by the expected-type engine every typer shares (`ExpectedTypes`, over
 *    `EXPECTATION`) — through a declaration's or an assigned binding's annotation, a function's written
 *    result, an anonymous structure's field and the parameter of a callee the call selects, where the
 *    callee is written and with the type parameters the call binds there (`OperandCallees`).
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
		parameter: (_, use, b) -> b.lambdaParamTier(use),
		unbound: (ident, b) -> b.inheritedTier(ident, false),
		access: (node, b) -> b.accessTier(node),
		element: null,
		call: (node, b) -> b.callTier(node),
		construction: (node, b) -> b.constructionTier(node),
		arithmetic: null,
		reading: b -> b._reading
	};

	/**
	 * The binder's answers to the expected-type engine (`ExpectedTypes`): each a type with where it is written — this file
	 * or the one declaring a callee, at an offset, so it binds with the type parameters in scope there, a type parameter the
	 * call binds read as what binds it (`locatedTier`). A declaration's annotation, an assigned binding's, a function's
	 * written result, the parameter of a callee the call selects (`argumentType`), an anonymous structure's field. No
	 * container element: the binder holds no proof that a written `Array` is the standard one whose element it would read.
	 */
	private static final EXPECTATION: ExpectationHost<Located, OperandBinder> = {
		declared: (holder, b) -> b.annotationOf(holder.span?.from),
		assigned: (target, b) -> b.annotationOf(b.hitOf(target)?.bindingSpan?.from),
		returned: (fn, b) -> b.returnOf(fn),
		argument: (call, at, _, b) -> b.argumentType(call, at),
		element: (_, _) -> null,
		field: (outer, name, b) -> b.anonField(outer, name),
		read: (written, b) -> b._index.typeSyntax(written.text),
		part: (of, text, _) -> {
			text: text,
			at: of.at,
			host: of.host,
			bindings: of.bindings
		}
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

	/** The typing service's expectation ladder (`TypingService.expectations`) an untyped lambda parameter is typed by. */
	private final _expectation: ExpectedTypes;

	/** This file's written type annotations by binding offset (`TypeInfoProvider.declaredTypeSources`). */
	private final _annotations: Map<Int, String>;

	/** This file's written return types by declaration offset (`CallGraphNames.returnSourcesOf`). */
	private final _returns: Map<Int, String>;

	private function new(
		file: String, source: String, tree: QueryNode, shape: RefShape, index: SymbolIndex, provider: TypeInfoProvider,
		returns: Map<Int, String>
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
		_expectation = index.typing.expectations;
		_annotations = provider.declaredTypeSources(source);
		_returns = returns;
	}

	/** What the type `written` at offset `at` of this file binds to, with the type parameters in scope there. */
	public inline function writtenTier(written: Null<String>, at: Int): Tier {
		return _declared.headTier(written, at, _wrappers, _builtins);
	}

	/**
	 * What a type NAME written in this file — at offset `at` when known — binds to
	 * at the file's top level, tier by tier; `Unknown` when the file is not indexed.
	 */
	public function typeNameTier(name: String, ?at: Int): Tier {
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		return fi == null ? Unknown : _index.refs.names.tierOf(name, fi, at);
	}

	/** What `operand`'s declared type binds to: the shared walk over this file's binding resolution (`HOST`). */
	public function tierOf(operand: QueryNode): Tier {
		return TypingService.typeWalk(operand, _shape, HOST, this) ?? Unknown;
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
	 * The expression initialising the unannotated local `use` reads: the local holds ITS type (`NominalTypes.localInitializer`).
	 */
	private inline function initializerOf(use: QueryNode): Null<QueryNode> {
		return NominalTypes.localInitializer(use, _tree, _shape, _annotations);
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
			return node.kind == branchKind && !inside && CasePatterns.scan(node, _shape, []).idents.exists(ident -> ident.name == name)
				|| node.children.exists(walk);
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
		final member: Null<MemberInfo> = memberAt(fn);
		return if (member != null && !typedByItsReturn(member))
			Unknown
		else if (_fnKinds.contains(fn.kind))
			_declared.headTier(CallGraphNames.returnSourceOf(fn, _returns), from, _wrappers, _builtins)
		else
			Unknown;
	}

	/** The member of this file whose declaration is the node `fn`, or null for a function no type of the file declares as one. */
	private function memberAt(fn: QueryNode): Null<MemberInfo> {
		final from: Null<Int> = fn.span?.from;
		return from == null ? null : _index.fileInfo(_file)?.types.flatMap(t -> t.members).find(m -> m.declFrom == from);
	}

	/**
	 * The lambda parameter `use` reads, written with no type: the parameter of the function type the lambda is expected to be
	 * (`ExpectedTypes.lambdaParamTypes` over `EXPECTATION`), bound where that type is written. Null for every other binding,
	 * and where the lambda's expected type is not proven.
	 */
	private function lambdaParamTier(use: QueryNode): Null<Tier> {
		final param: Null<QueryNode> = hitOf(use)?.bindingNode;
		if (param == null || !(_shape.paramKinds ?? []).contains(param.kind)) return null;
		final found: Null<Lineage> = ExpectedTypes.lineageOf(_tree, param);
		final depth: Int = found == null ? 0 : found.nodes.length;
		if (found == null || depth == 0 || !_expectation.isLambda(found.nodes[depth - 1])) return null;
		final lambda: QueryNode = found.nodes[depth - 1];
		final types: Null<Array<Located>> = _expectation.lambdaParamTypes(
			lambda, found.nodes.slice(0, depth - 1), found.indices.slice(0, depth - 1), EXPECTATION, this
		);
		final at: Int = lambda.children.filter(c -> (_shape.paramKinds ?? []).contains(c.kind)).indexOf(param);
		final written: Null<Located> = types == null || at < 0 ? null : types[at];
		return written == null ? null : locatedTier(written);
	}

	/**
	 * The parameter the argument `at` of the call or construction `call` binds: its written type where the callee declares it,
	 * the type parameters the call binds there (`calleeParams`) — every argument from a rest parameter's position on binding
	 * that parameter. Null where that parameter, or one before it, may be skipped (optional, or carrying a default value:
	 * 4.3.7 tries the lambda against it first), and for a callee `calleeParams` does not read.
	 */
	private function argumentType(call: QueryNode, at: Int): Null<Located> {
		final callee: Null<CalleeParams> = OperandCallees.calleeParams(this, call);
		if (callee == null) return null;
		final params: DeclaredParams = callee.params;
		final index: Int = at + callee.shift;
		// a rest parameter takes every argument from its position on
		final bound: Int = params.rest ? Std.int(Math.min(index, params.params.length - 1)) : index;
		final written: Null<String> = bound < params.params.length ? params.params[bound] : null;
		return written == null || bound >= params.skippableFrom ? null : {
			text: written,
			at: callee.at,
			host: callee.host,
			bindings: callee.bindings
		};
	}

	/** The annotation this file writes for the binding at `from`, at that offset; null for none. */
	private function annotationOf(from: Null<Int>): Null<Located> {
		final written: Null<String> = from == null ? null : _annotations[from];
		return from == null || written == null ? null : { text: written, at: from };
	}

	/** The result type the function or lambda `fn` of this file writes, at its declaration; null for none. */
	private function returnOf(fn: QueryNode): Null<Located> {
		final from: Null<Int> = fn.span?.from;
		final written: Null<String> = CallGraphNames.returnSourceOf(fn, _returns);
		return from == null || written == null ? null : { text: written, at: from };
	}

	/** The field `name` of `outer` when that is an anonymous structure (a `Null<…>` peeled), where `outer` is written. */
	private function anonField(outer: Located, name: String): Null<Located> {
		final peeled: String = NominalTypes.unwrapNullable(outer.text.trim(), _wrappers, _index.typeSyntax);
		final written: Null<String> = CallGraphNames.anonFieldTypeSource(_index.typeSyntax(peeled), name);
		return written == null ? null : {
			text: written,
			at: outer.at,
			host: outer.host,
			bindings: outer.bindings
		};
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
		if (owners.length == 1 && _index.typing.members.declarationLacksMember(owners[0], name))
			return call ? extensionTier(owners[0], name) : resolveTier(owners[0], name);
		final found: Array<ResolvedType> = [];
		for (owner in owners) {
			final declared: Null<HostedMembers> = declarationOf(owner, name);
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
	private function declarationOf(owner: ResolvedType, name: String): Null<HostedMembers> {
		final own: Array<MemberInfo> = owner.type.members.filter(m -> m.name == name);
		return if (own.length > 0)
			{ members: own, host: owner }
		else if (_index.typing.members.declarationFreeOfExtensionTypes(owner))
			_index.typing.members.declaringMember(owner, name)
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
		final declared: Null<HostedMembers> = owner == null ? null : declarationOf(owner, name);
		return declared == null || declared.members.exists(m -> m.isStatic) ? Unknown : boundMembers(declared.members, declared.host, call);
	}

	/**
	 * `recv.method(…)` on a receiver of the one declaration `owner`, whose closure provably declares no `method`: the static
	 * extension the typing service binds there (`StaticExtensions.binding`, which owns the compiler's order of the type's
	 * `@:using` and the file's `using`s and the unification of the receiver with each candidate's first parameter) — its
	 * written return bound where it is declared. `Unknown` wherever the service proves no binding.
	 */
	private function extensionTier(owner: ResolvedType, method: String): Tier {
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		final declared: Null<HostedMembers> = fi == null ? null : _index.typing.extensions.binding(fi, owner, method);
		return declared == null || declared.host.type.typeParamArity != declared.host.type.typeParamNames.length
			? Unknown
			: boundMembers(declared.members, declared.host, true);
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
			|| t.guarded || !_index.typing.members.declarationFreeOfExtensionTypes(owner) || _index.typing.extensions.maySupply(fi, name)
		)
			return Unknown;
		return boundMembers(resolvers, owner, true);
	}

	/** What the type `written` binds to where it is written (`Located`): a type parameter the call binds read as what binds it. */
	private function locatedTier(written: Located): Tier {
		final bound: Null<Located> = written.bindings?.get(written.text.trim());
		if (bound != null) return locatedTier(bound);
		final host: Null<WrittenHost> = written.host;
		return host == null
			? writtenTier(written.text, written.at)
			: DeclaredNullity.headTierIn(written.text, host.file, written.at, _index, host.params, _wrappers, _builtins);
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
		return provider == null
			? null
			: new OperandBinder(file, source, tree, plugin.refShape(), index, provider, CallGraphNames.returnSourcesOf(plugin, source));
	}

	/** The type names the grammar declares built in — a literal's type or a basic value type — each once. */
	public static function builtinNamesOf(shape: RefShape): Array<String> {
		final out: Array<String> = [for (name in shape.literalTypeNames ?? []) name];
		for (name in shape.nonNullableTypeNames ?? []) if (!out.contains(name)) out.push(name);
		return out;
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

}

/**
 * A type and where it is written: at `at` of the binder's file, or — `host` set — of the file declaring a callee, whose
 * type parameters in scope there `host` names; a type parameter `bindings` holds is the type the call binds it to.
 */
typedef Located = {
	final text: String;
	final at: Int;
	@:optional final host: WrittenHost;
	@:optional final bindings: Map<String, Located>;
}

/** The file of the index a type is written in, and the type parameters in scope where it is. */
typedef WrittenHost = {
	final file: FileInfo;
	final params: Array<String>;
}

/**
 * The parameter list a call selects (`OperandBinder.calleeParams`): where it is written (`at` of the binder's file, or of
 * `host`'s), the type parameters the call binds there, and how many parameters come before the first argument's (a static
 * extension's receiver).
 */
typedef CalleeParams = {
	final params: DeclaredParams;
	final at: Int;
	final host: Null<WrittenHost>;
	final shift: Int;
	final bindings: Map<String, Located>;
}

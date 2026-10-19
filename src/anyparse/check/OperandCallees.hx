package anyparse.check;

import anyparse.check.OperandBinder.CalleeParams;
import anyparse.check.OperandBinder.Located;
import anyparse.query.CallGraphNames;
import anyparse.query.DeclaredNullity;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.query.TypeSyntax;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The parameter list a call or a construction selects, for the operand binder (`OperandBinder.argumentType`, which hands
 * an untyped lambda the parameter its argument binds): where the callee declares it — the binder's file, or another the
 * index reads —, the type parameters the call binds there (the receiver's written type arguments, the ones `new` writes, a
 * std `Iterable` of the method's own over a std iterable argument), and how many parameters precede the first argument's.
 * A positive whitelist: a callee of one signature reached by one of the shapes `calleeParams` names; anything else — an
 * overload, a macro, a `#if` twin, a type parameter nothing binds, a receiver of several declarations — reads nothing.
 */
@:nullSafety(Strict)
@:access(anyparse.check.OperandBinder)
final class OperandCallees {

	/**
	 * Whether a call to `m`, a member of this file, selects the signature its declaration writes: the one declaration of the
	 * name in its type (a `#if` twin is another build's signature), carrying no `@:overload`. A macro's parameters are
	 * expressions and a type parameter binds to nothing in scope, so neither types a lambda by construction.
	 */
	private static function selectsItsSignature(binder: OperandBinder, m: MemberInfo): Bool {
		final owner: Null<TypeDeclInfo> = binder._index.fileInfo(binder._file)?.types.find(t -> t.members.contains(m));
		return owner != null && owner.members.filter(o -> o.name == m.name).length == 1 && !m.hasOverloadMeta;
	}

	/**
	 * The parameter list the call or construction `call` selects, where it is declared, with the type parameters the call
	 * binds there — for a callee of ONE signature (no `@:overload`, no macro, no `#if` twin): a bare call to a member of this
	 * file, to a local function, or to a member the enclosing type inherits; `recv.m(…)` on a receiver of one declaration —
	 * a static off a type name, an instance member off a value, a static extension the file's `using`s supply —; `new T(…)`.
	 * Null for every other callee.
	 */
	public static function calleeParams(binder: OperandBinder, call: QueryNode): Null<CalleeParams> {
		if (call.kind == binder._shape.newExprKind) return constructionParams(binder, call);
		if (call.kind != binder._shape.callKind || call.children.length == 0) return null;
		final callee: QueryNode = call.children[0];
		if (binder._identKinds.contains(callee.kind)) return bareCallParams(binder, callee);
		final name: Null<String> = callee.name;
		return name == null || callee.kind != binder._shape.fieldAccessKind || callee.children.length != 1
			? null
			: memberCallParams(binder, callee.children[0], name, call);
	}

	/**
	 * A bare call `f(…)`: a member this file declares whose signature every call selects, a local function, or — bound by no
	 * declaration of this file — an instance member the enclosing type inherits (a supertype's static is not in scope bare).
	 */
	private static function bareCallParams(binder: OperandBinder, ident: QueryNode): Null<CalleeParams> {
		final hit: Null<RefHit> = binder.hitOf(ident);
		final fn: Null<QueryNode> = hit?.bindingNode;
		if (OperandBinder.bindsHere(hit)) {
			if (fn == null) return null;
			final member: Null<MemberInfo> = binder._fnKinds.contains(fn.kind) ? binder.memberAt(fn) : null;
			final local: Bool = ShapeVocab.localFunctionScopeKinds(binder._shape).contains(fn.kind);
			return local || member != null && selectsItsSignature(binder, member) ? localParams(binder, fn) : null;
		}
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null) return null;
		final at: Span = span;
		if (OperandBinder.bindsHere(TypeResolver.resolveBindingHit(name, at, binder._tree, binder._shape))) return null;
		final owner: Null<ResolvedType> = binder.capturedBetween(name, at, null) ? null : binder.enclosingDeclaration(at);
		final declared: Null<HostedMembers> = owner == null ? null : binder.declarationOf(owner, name);
		return declared == null || declared.members.exists(m -> m.isStatic) ? null : memberParams(binder, declared, [], 0, []);
	}

	/** The parameters the function `fn` of this file writes, at its declaration, so its type parameters are in scope there. */
	private static function localParams(binder: OperandBinder, fn: QueryNode): Null<CalleeParams> {
		final from: Null<Int> = fn.span?.from;
		return from == null ? null : {
			params: CallGraphNames.paramsOf(fn, binder._annotations, binder._shape),
			at: from,
			host: null,
			shift: 0,
			bindings: []
		};
	}

	/**
	 * `recv.m(…)` on a receiver of one declaration: its member `m` — a static off a type name (its own type parameters bound by
	 * the arguments, `methodBindings`), an instance member off a value (the receiver's written type arguments bound to its
	 * type's, `ownerBindings`) — or, where the declaration's closure provably declares no `m`, the static extension the
	 * file's `using`s supply (`extensionParams`).
	 */
	private static function memberCallParams(
		binder: OperandBinder, receiver: QueryNode, name: String, call: QueryNode
	): Null<CalleeParams> {
		final value: Null<Array<ResolvedType>> = switch binder.tierOf(receiver) {
			case Bound(decls): decls;
			case _: null;
		};
		final owners: Null<Array<ResolvedType>> = value ?? binder.receiverDecls(receiver);
		if (owners == null || owners.length != 1) return null;
		final owner: ResolvedType = owners[0];
		final onType: Bool = value == null;
		if (binder._index.members.declarationLacksMember(owner, name))
			return onType ? null : extensionParams(binder, owner, receiver, name);
		final declared: Null<HostedMembers> = binder.declarationOf(owner, name);
		return if (declared == null || declared.members.exists(m -> m.isStatic != onType))
			null
		else if (onType)
			memberParams(binder, declared, [], 0, methodBindings(binder, declared, call.children.slice(1)))
		else
			memberParams(binder, declared, ownerBindings(binder, receiver, owner, declared.host), 0, []);
	}

	/**
	 * `new T(…)`: the constructor `T`'s closure declares, the type arguments `new` writes bound to `T`'s parameters when `T`
	 * declares it itself.
	 */
	private static function constructionParams(binder: OperandBinder, node: QueryNode): Null<CalleeParams> {
		final at: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (at == null || name == null) return null;
		final owners: Null<Array<ResolvedType>> = switch binder.writtenTier(name, at.from) {
			case Bound(decls) if (decls.length == 1): decls;
			case _: null;
		};
		if (owners == null) return null;
		final owner: ResolvedType = owners[0];
		final declared: Null<HostedMembers> = binder.declarationOf(owner, binder._shape.constructorName ?? 'new');
		if (declared == null || declared.members.exists(m -> m.isStatic)) return null;
		final args: Array<String> = [
			for (i in 0...node.typeArgCount) {
				final span: Null<Span> = node.children[i].span;
				span == null ? '' : binder._source.substring(span.from, span.to);
			}
		];
		final bindings: Map<String, Located> = OperandBinder.sameDeclaration(owner, declared.host)
			? bindAll(owner.type.typeParamNames, args, at.from)
			: [];
		return memberParams(binder, declared, bindings, 0, []);
	}

	/**
	 * The parameters of the one member `declared` holds, a function of one signature, where its type declares it: `bindings`
	 * binds its type's parameters (the method's own shadowing them), `own` the method's own; `shift` parameters come before
	 * the first argument's.
	 */
	private static function memberParams(
		binder: OperandBinder, declared: HostedMembers, bindings: Map<String, Located>, shift: Int, own: Map<String, Located>
	): Null<CalleeParams> {
		final host: ResolvedType = declared.host;
		if (
			declared.members.length != 1 || binder._index.sourceOf(host.file.file) == null
			|| host.type.typeParamArity != host.type.typeParamNames.length
		)
			return null;
		final m: MemberInfo = declared.members[0];
		if (!OperandBinder.typedByItsReturn(m) || m.isOverload || m.guarded || !binder._fnKinds.contains(m.kind)) return null;
		final kept: Map<String, Located> = [for (k => v in bindings) if (!m.typeParamNames.contains(k)) k => v];
		for (k => v in own) kept[k] = v;
		return {
			params: { params: m.paramTypeSources, skippableFrom: m.paramSkippableFrom, rest: m.paramRest },
			at: m.declFrom,
			host: host.file.file == binder._file ? null : { file: host.file, params: host.type.typeParamNames.concat(m.typeParamNames) },
			shift: shift,
			bindings: kept
		};
	}

	/**
	 * The type arguments the receiver `receiver` is written with — a binding this file declares with an annotation naming as
	 * many as `owner` has parameters — bound to `owner`'s parameters, when `host`, the type declaring the member called, is
	 * `owner` itself: what a supertype's parameters are is what `owner` extends it with, which this does not follow.
	 */
	private static function ownerBindings(
		binder: OperandBinder, receiver: QueryNode, owner: ResolvedType, host: ResolvedType
	): Map<String, Located> {
		final written: Null<Located> = writtenSourceOf(binder, receiver);
		final args: Null<Array<String>> = written == null
			? null
			: binder._index.typeSyntax(
				NominalTypes.unwrapNullable(StringTools.trim(written.text), binder._wrappers, binder._index.typeSyntax)
			)?.argumentTexts();
		return written == null || args == null || !OperandBinder.sameDeclaration(owner, host)
			? []
			: bindAll(owner.type.typeParamNames, args, written.at);
	}

	/**
	 * `recv.m(…)` through the static extension the file's `using`s supply (`ValueNameBinding.extensionDeclaration`, as
	 * `extensionTier` reads it): its parameters past the first, which takes the receiver — a first parameter written as
	 * `owner` itself, or as the std `Iterable` of one of the method's own type parameters over a receiver written as a std
	 * iterable (`iterableBinding`), which binds that parameter.
	 */
	private static function extensionParams(
		binder: OperandBinder, owner: ResolvedType, receiver: QueryNode, name: String
	): Null<CalleeParams> {
		final usings: Null<Array<String>> = binder._usings();
		if (usings == null || !binder._index.members.declarationFreeOfExtensionTypes(owner)) return null;
		final declared: Null<HostedMembers> = binder._index.values.extensionDeclaration(usings, name);
		if (declared == null || declared.members.length != 1) return null;
		final host: ResolvedType = declared.host;
		final m: MemberInfo = declared.members[0];
		final first: Null<String> = m.firstParamTypeSource;
		if (first == null || host.type.typeParamArity != host.type.typeParamNames.length) return null;
		final element: Null<Map<String, Located>> = iterableBinding(binder, first, host, m, writtenSourceOf(binder, receiver));
		final params: Array<String> = host.type.typeParamNames.concat(m.typeParamNames);
		final exact: Bool = switch DeclaredNullity.headTierIn(
			first, host.file, m.declFrom, binder._index, params, binder._wrappers, binder._builtins
		) {
			case Bound(decls):
				decls.length == 1 && OperandBinder.sameDeclaration(decls[0], owner);
			case _: false;
		};
		return element == null && !exact ? null : memberParams(binder, declared, [], 1, element ?? []);
	}

	/**
	 * What a static call binds its callee's own type parameters to: each written as the std `Iterable` of one of them, over an
	 * argument written as a std iterable (`iterableBinding`) — every such parameter agreeing. Empty for any other method.
	 */
	private static function methodBindings(binder: OperandBinder, declared: HostedMembers, args: Array<QueryNode>): Map<String, Located> {
		final out: Map<String, Located> = [];
		if (declared.members.length != 1) return out;
		final m: MemberInfo = declared.members[0];
		final dropped: Array<String> = [];
		for (i in 0...Std.int(Math.min(args.length, m.paramTypeSources.length))) {
			final written: Null<String> = m.paramTypeSources[i];
			final found: Null<Map<String, Located>> = written == null
				? null
				: iterableBinding(binder, written, declared.host, m, writtenSourceOf(binder, args[i]));
			if (found != null) for (k => v in found) {
				final known: Null<Located> = out[k];
				if (known != null && (known.text != v.text || known.at != v.at)) dropped.push(k);
				out[k] = v;
			}
		}
		for (k in dropped) out.remove(k);
		return out;
	}

	/**
	 * The type parameter of `m` (declared on `host`) a parameter written `written` binds when an argument written `given` is
	 * handed to it: `written` the std `Iterable` of one of `m`'s own type parameters (`RefShape.iterableTypeName`), `given` a
	 * std type that unifies with an `Iterable` (`RefShape.iterableElementTypeParams`: 4.3.7 types `Lambda.iter(xs, c -> …)`'s
	 * `c` as the element of an `Array`, a `List`, an `Iterable` and the value of a `Map` — and has no `iter` for a
	 * `haxe.ds.Vector`) — the parameter bound to that element, where `given` writes it. Null otherwise.
	 */
	private static function iterableBinding(
		binder: OperandBinder, written: String, host: ResolvedType, m: MemberInfo, given: Null<Located>
	): Null<Map<String, Located>> {
		final iterable: Null<String> = binder._shape.iterableTypeName;
		final elements: Map<String, Int> = binder._shape.iterableElementTypeParams ?? [];
		final param: Null<TypeSyntax> = binder._index.typeSyntax(StringTools.trim(written));
		if (iterable == null || given == null || param == null) return null;
		final element: Null<String> = switch param.shape {
			case Nominal(path, [arg]) if (
				stdNamed(binder, path, host.file.file, iterable) && m.typeParamNames.contains(StringTools.trim(arg.text))
			):
				StringTools.trim(arg.text);
			case _: null;
		};
		final peeled: String = NominalTypes.unwrapNullable(StringTools.trim(given.text), binder._wrappers, binder._index.typeSyntax);
		final arg: Null<TypeSyntax> = binder._index.typeSyntax(peeled);
		final args: Null<Array<String>> = arg?.argumentTexts();
		final path: Null<String> = arg == null ? null : NominalTypes.outerPathOf(peeled, [], binder._index.typeSyntax);
		if (element == null || args == null || path == null) return null;
		for (name => i in elements) if (i < args.length && stdNamed(binder, path, binder._file, name)) {
			final bound: Located = { text: args[i], at: given.at };
			return [element => bound];
		}
		return null;
	}

	/** Whether the type `path` written in `file` binds to the std declaration of the type named `name`. */
	private static function stdNamed(binder: OperandBinder, path: String, file: String, name: String): Bool {
		return binder._index.stdDeclarationOf(path, file)?.type.name == name;
	}

	/** The annotation of the binding the identifier `node` reads, where this file writes it; null for any other expression. */
	private static function writtenSourceOf(binder: OperandBinder, node: QueryNode): Null<Located> {
		final from: Null<Int> = binder.hitOf(node)?.bindingSpan?.from;
		return binder.annotationOf(from);
	}

	/** `names[i]` bound to `args[i]`, written in this file at `at`; empty when the counts differ. */
	private static function bindAll(names: Array<String>, args: Array<String>, at: Int): Map<String, Located> {
		final out: Map<String, Located> = [];
		if (names.length == args.length) for (i in 0...names.length) {
			final bound: Located = { text: args[i], at: at };
			out[names[i]] = bound;
		}
		return out;
	}

}

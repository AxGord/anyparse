package anyparse.check.scan;

import anyparse.check.scan.OperandBinder.CalleeParams;
import anyparse.check.scan.OperandBinder.Located;
import anyparse.query.CallGraphNames;
import anyparse.query.CallSelection;
import anyparse.query.CallSelection.CallArgument;
import anyparse.query.CallSignature;
import anyparse.query.CallSignature.ParamForm;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.NominalTypes;
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
@:access(anyparse.check.scan.OperandBinder)
final class OperandCallees {

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
		if (binder._identKinds.contains(callee.kind)) return bareCallParams(binder, callee, call.children.slice(1));
		final name: Null<String> = callee.name;
		return name == null || callee.kind != binder._shape.fieldAccessKind || callee.children.length != 1
			? null
			: memberCallParams(binder, callee.children[0], name, call);
	}

	/**
	 * Whether a call to `m`, a member of this file, selects a signature its declaration writes: the one declaration of the
	 * name in its type (a `#if` twin is another build's signature) — its own, or one of its `@:overload` annotations', which
	 * `memberParams` selects. A macro's parameters are expressions and a type parameter binds to nothing in scope, so neither
	 * types a lambda by construction.
	 */
	private static function selectsItsSignature(binder: OperandBinder, m: MemberInfo): Bool {
		final owner: Null<TypeDeclInfo> = binder._index.fileInfo(binder._file)?.types.find(t -> t.members.contains(m));
		return owner != null && owner.members.filter(o -> o.name == m.name).length == 1;
	}

	/**
	 * A bare call `f(…)`: a member this file declares whose signature every call selects, a local function, or — bound by no
	 * declaration of this file — an instance member the enclosing type inherits (a supertype's static is not in scope bare).
	 */
	private static function bareCallParams(binder: OperandBinder, ident: QueryNode, args: Array<QueryNode>): Null<CalleeParams> {
		final hit: Null<RefHit> = binder.hitOf(ident);
		final fn: Null<QueryNode> = hit?.bindingNode;
		if (OperandBinder.bindsHere(hit)) {
			if (fn == null) return null;
			final member: Null<MemberInfo> = binder._fnKinds.contains(fn.kind) ? binder.memberAt(fn) : null;
			final local: Bool = ShapeVocab.localFunctionScopeKinds(binder._shape).contains(fn.kind);
			if (local) return localParams(binder, fn);
			if (member == null || !selectsItsSignature(binder, member)) return null;
			return member.hasOverloadMeta ? ownMemberParams(binder, member, args) : localParams(binder, fn);
		}
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null) return null;
		final at: Span = span;
		if (OperandBinder.bindsHere(TypeResolver.resolveBindingHit(name, at, binder._tree, binder._shape))) return null;
		final owner: Null<ResolvedType> = binder.capturedBetween(name, at, null) ? null : binder.enclosingDeclaration(at);
		final declared: Null<HostedMembers> = owner == null ? null : binder.declarationOf(owner, name);
		return declared == null || declared.members.exists(m -> m.isStatic) ? null : memberParams(binder, declared, [], 0, [], args);
	}

	/** The parameters a bare call passing `args` selects of `m`, a member this file's type declares (`memberParams`). */
	private static function ownMemberParams(binder: OperandBinder, m: MemberInfo, args: Array<QueryNode>): Null<CalleeParams> {
		final fi: Null<FileInfo> = binder._index.fileInfo(binder._file);
		final owner: Null<TypeDeclInfo> = fi?.types.find(t -> t.members.contains(m));
		if (fi == null || owner == null) return null;
		// re-bound: a struct literal's field takes its declared type, not the narrowed one
		final file: FileInfo = fi;
		final type: TypeDeclInfo = owner;
		final host: ResolvedType = { file: file, type: type };
		return memberParams(binder, { members: [m], host: host }, [], 0, [], args);
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
		if (binder._index.typing.members.declarationLacksMember(owner, name))
			return onType ? null : extensionParams(binder, owner, receiver, name, call.children.slice(1));
		final declared: Null<HostedMembers> = binder.declarationOf(owner, name);
		if (declared == null || declared.members.exists(m -> m.isStatic != onType)) return null;
		final args: Array<QueryNode> = call.children.slice(1);
		return onType
			? memberParams(binder, declared, [], 0, methodBindings(binder, declared, args), args)
			: memberParams(binder, declared, ownerBindings(binder, receiver, owner, declared.host), 0, [], args);
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
		return memberParams(binder, declared, bindings, 0, [], node.children.slice(node.typeArgCount));
	}

	/**
	 * The parameters of the one member `declared` holds, a function, where its type declares it: those of the signature a call
	 * passing `args` selects (`selectedSignature`: its own unless it carries signature overloads), `bindings` binding its
	 * type's parameters (the method's own shadowing them), `own` the method's own — read against its own signature, so
	 * dropped for another one; `shift` parameters come before the first argument's.
	 */
	private static function memberParams(
		binder: OperandBinder, declared: HostedMembers, bindings: Map<String, Located>, shift: Int, own: Map<String, Located>,
		args: Array<QueryNode>
	): Null<CalleeParams> {
		final host: ResolvedType = declared.host;
		if (
			declared.members.length != 1 || binder._index.sourceOf(host.file.file) == null
			|| host.type.typeParamArity != host.type.typeParamNames.length
		)
			return null;
		final m: MemberInfo = declared.members[0];
		if (m.isMacro || m.isOverload || m.guarded || !binder._fnKinds.contains(m.kind)) return null;
		final signature: Null<CallSignature> = m.hasOverloadMeta ? selectedSignature(binder, declared, args, shift) : null;
		if (m.hasOverloadMeta && signature == null) return null;
		final written: Null<CallSignature> = signature == m.signatures[0] ? null : signature;
		final typeParams: Array<String> = written == null ? m.typeParamNames : written.typeParamNames;
		final kept: Map<String, Located> = [for (k => v in bindings) if (!typeParams.contains(k)) k => v];
		if (written == null) for (k => v in own) kept[k] = v;
		return {
			params: written == null
				? { params: m.paramTypeSources, skippableFrom: m.paramSkippableFrom, rest: m.paramRest }
				: declaredParamsOf(written),
			at: written == null ? m.declFrom : written.at,
			host: host.file.file == binder._file ? null : { file: host.file, params: host.type.typeParamNames.concat(typeParams) },
			shift: shift,
			bindings: kept
		};
	}

	/**
	 * The signature of the one member of `declared` a call passing `args` selects (`CallSelection`), as far as the number of
	 * arguments and their `null` literals decide it: an argument the binder types is a lambda, which the selected signature
	 * types, so no other argument's type is read either; `shift` arguments (a static extension's receiver) come first. Null
	 * when not decided.
	 */
	private static function selectedSignature(
		binder: OperandBinder, declared: HostedMembers, args: Array<QueryNode>, shift: Int
	): Null<CallSignature> {
		final calls: CallSelection = binder._index.typing.calls;
		final candidates: Null<CallCandidates> = calls.candidates(declared, declared.members[0].isStatic);
		final passed: Array<CallArgument> = [for (_ in 0...shift) Untyped].concat([
			for (a in args) a.kind == binder._shape.nullLiteralKind ? NullValue : Untyped
		]);
		return candidates == null ? null : calls.select(candidates, passed)?.signature;
	}

	/** `signature`'s parameters as a declaration lists them (`CallGraphNames.DeclaredParams`). */
	private static function declaredParamsOf(signature: CallSignature): DeclaredParams {
		final forms: Array<ParamForm> = [for (p in signature.params) p.form];
		var skippable: Int = 0;
		while (skippable < forms.length && forms[skippable] == Plain) skippable++;
		return {
			params: [for (p in signature.params) p.type],
			skippableFrom: skippable,
			rest: forms.length > 0 && forms[forms.length - 1] == Rest
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
			: binder._index.typeSyntax(NominalTypes.unwrapNullable(written.text.trim(), binder._wrappers, binder._index.typeSyntax))?.argumentTexts();
		return written == null || args == null || !OperandBinder.sameDeclaration(owner, host)
			? []
			: bindAll(owner.type.typeParamNames, args, written.at);
	}

	/**
	 * `recv.m(…)` through the static extension the typing service binds there (`StaticExtensions.binding`, as `extensionTier`
	 * reads it): its parameters past the first, which takes the receiver — with the method's own type parameter bound
	 * when the first parameter is the std `Iterable` of one over a receiver written as a std iterable (`iterableBinding`).
	 */
	private static function extensionParams(
		binder: OperandBinder, owner: ResolvedType, receiver: QueryNode, name: String, args: Array<QueryNode>
	): Null<CalleeParams> {
		final fi: Null<FileInfo> = binder._index.fileInfo(binder._file);
		final declared: Null<HostedMembers> = fi == null ? null : binder._index.typing.extensions.binding(fi, owner, name);
		if (declared == null) return null;
		final host: ResolvedType = declared.host;
		final m: MemberInfo = declared.members[0];
		final first: Null<String> = m.firstParamTypeSource;
		final element: Null<Map<String, Located>> = first == null
			? null
			: iterableBinding(binder, first, host, m, writtenSourceOf(binder, receiver));
		return memberParams(binder, declared, [], 1, element ?? [], args);
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
		final param: Null<TypeSyntax> = binder._index.typeSyntax(written.trim());
		if (iterable == null || given == null || param == null) return null;
		final element: Null<String> = switch param.shape {
			case Nominal(path, [arg]) if (
				stdNamed(binder, path, host.file.file, iterable) && m.typeParamNames.contains(StringTools.trim(arg.text))
			):
				StringTools.trim(arg.text);
			case _: null;
		};
		final peeled: String = NominalTypes.unwrapNullable(given.text.trim(), binder._wrappers, binder._index.typeSyntax);
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

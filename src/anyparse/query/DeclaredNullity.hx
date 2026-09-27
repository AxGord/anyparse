package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeNameBinding.Tier;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/** How far a declared type is known to exclude null. */
enum abstract Nullity(Int) {

	/** Proven by nothing: unresolved, disputed between candidates, `#if`-guarded, a type parameter, or `Null<…>` on the way. */
	final Unproven = 0;

	/**
	 * A declaration no value of which is null under null safety: a class, interface, enum or anonymous
	 * structure, directly or through aliases and abstracts.
	 */
	final NonNull = 1;

	/** A value type written by its own basic name (`Int`): non-null on a static target whatever the null safety. */
	final ValueType = 2;

}

/**
 * One file's answer to "does this binding's DECLARED type exclude null" — the positive rule behind
 * `TypeResolver.isProvablyNonNull` and every check that reads a written type as a null proof.
 *
 * A type proves nothing by its NAME: `typedef MaybeR = Null<R>` reads as a plain nominal and is
 * nullable. So a type counts only once it RESOLVES, through the `SymbolIndex` and in the scope of
 * the file that writes it, to a declaration known to exclude null — following typedef chains
 * (`aliasTargetRaw`) and abstracts (`underlyingRaw`) hop by hop, each hop in its declaring file's
 * scope and with that declaration's own type parameters shadowing. Everything else is `Unproven`: a
 * name the index does not hold (a library outside the resolution scope, no index at all), a type
 * parameter, `Dynamic` / `Any` / `Null` (`RefShape.nullableWrapperTypeNames`), a guarded
 * declaration, a `@:coreType` abstract other than the basic value types, a function type. Several
 * candidates prove only by agreement: every one of them must resolve non-null, so the answer holds
 * whichever the compiler picks.
 *
 * A basic value type (`RefShape.nonNullableTypeNames`) written by its OWN name answers `ValueType`,
 * the target-dependent fast path `TypeResolver` grants or withholds; reached through an alias or
 * an abstract it answers `NonNull`, so only null safety can vouch for it — an alias is where a
 * `Null<…>` hides, and the fast path is not widened past the spelling it was granted for.
 */
@:nullSafety(Strict)
final class DeclaredNullity {

	/** A bound on alias / abstract hops, so a cycle the `seen` list misses still terminates. */
	private static inline final MAX_HOPS: Int = 32;

	private final _file: String;
	private final _root: QueryNode;
	private final _source: String;
	private final _shape: RefShape;
	private final _declaredTypes: Map<Int, String>;
	private final _typeSources: Map<Int, String>;

	/** This file's type-parameter names per declaring span (`TypeInfoProvider.typeParamNames`). */
	private final _typeParams: Map<Int, Array<String>>;

	private final _typeSyntax: TypeSyntaxReader;

	/** Binding offsets of the properties read through a getter (`TypeInfoProvider.propertyAccessors`). */
	private final _accessors: Map<Int, Bool>;

	private final _index: () -> Null<SymbolIndex>;

	/** Declaration kinds whose values exclude null under null safety with no hop to follow. */
	private final _nominalKinds: Array<String>;

	/** Declaration kinds that ALIAS another type: typedefs, i.e. the aliasing kinds that are not abstracts. */
	private final _aliasKinds: Array<String>;

	public function new(
		file: String, root: QueryNode, source: String, shape: RefShape, declaredTypes: Map<Int, String>, typeSources: Map<Int, String>,
		typeParams: Map<Int, Array<String>>, accessors: Map<Int, Bool>, typeSyntax: TypeSyntaxReader, index: () -> Null<SymbolIndex>
	) {
		_file = file;
		_root = root;
		_source = source;
		_shape = shape;
		_declaredTypes = declaredTypes;
		_typeSources = typeSources;
		_typeParams = typeParams;
		_accessors = accessors;
		_typeSyntax = typeSyntax;
		_index = index;
		_nominalKinds = (shape.classDeclKinds ?? []).concat(shape.interfaceDeclKinds ?? []).concat(shape.runtimeTaggedTypeKinds ?? []);
		final abstractKinds: Array<String> = shape.underlyingThisTypeKinds ?? [];
		_aliasKinds = (shape.aliasingDeclKinds ?? []).filter(k -> !abstractKinds.contains(k));
	}

	/** The simple outer nominal the binding at `bindingFrom` is declared with, or null when it has none. */
	public inline function nominalAt(bindingFrom: Int): Null<String> {
		return _declaredTypes[bindingFrom];
	}

	/**
	 * Whether the binding at `bindingFrom` is a basic value type written by its own name AND holds a
	 * value from its first read: every binding but a FIELD with storage and no initialiser. On a
	 * dynamic target such a field reads null until something assigns it, whatever its value type —
	 * `var n:Int;` reads null on `--interp` and `undefined` on js, where a static target reads `0` —
	 * so the target-dependent fast path must not vouch for it. A property read through its getter
	 * returns what the getter returns, and a parameter or a local is assigned before it is read.
	 */
	public function isValueType(bindingFrom: Int): Bool {
		final typeName: Null<String> = _declaredTypes[bindingFrom];
		if (typeName == null || !(_shape.nonNullableTypeNames ?? []).contains(typeName)) return false;
		final typeChildKinds: Array<String> = _shape.declTypeChildKinds ?? [];
		final field: Null<QueryNode> = TypeResolver.innermostDeclCovering(_root, _shape.fieldDeclKinds ?? [], bindingFrom);
		return field == null || _accessors[bindingFrom] == true || !field.children.foreach(c -> typeChildKinds.contains(c.kind));
	}

	/**
	 * What the binding at `bindingFrom` is declared as: `ValueType` for a basic value type written by
	 * its own name, else the resolved verdict on its written type. A binding with no nominal
	 * annotation is `Unproven`. Says nothing about the binding's OWN syntax (an optional parameter, a
	 * `= null` initialiser) — `TypeResolver` asks those first.
	 */
	public function ofBinding(bindingFrom: Int): Nullity {
		final typeName: Null<String> = _declaredTypes[bindingFrom];
		if (typeName == null) return Unproven;
		if ((_shape.nonNullableTypeNames ?? []).contains(typeName)) return ValueType;
		final params: Null<Array<String>> = typeParamsAt(bindingFrom);
		return params == null ? Unproven : resolve(_typeSources[bindingFrom] ?? typeName, _file, params, 0, []);
	}

	/**
	 * What the head of the type the binding at `bindingFrom` is WRITTEN with binds to — `headTier` over
	 * its annotation; `Unknown` for a binding that carries none.
	 */
	public inline function writtenHeadTier(bindingFrom: Int, wrappers: Array<String>, builtins: Array<String>): Tier {
		return headTier(_typeSources[bindingFrom], bindingFrom, wrappers, builtins);
	}

	/**
	 * What the head of the type `written` at offset `at` of this file binds to, in this file's scope and
	 * in the compiler's resolution order, once any of `wrappers` is peeled off it (`Null<Tag>` -> `Tag`).
	 * `Unknown` for no type, a head that is not a plain nominal or is still a wrapper, a type parameter
	 * in scope at `at`, and a qualified path the index does not hold. `Free` only for one of `builtins`
	 * that no tier binds, so the compiler's own type is the one it names; any other name no tier binds
	 * is `Unknown`.
	 */
	public function headTier(written: Null<String>, at: Int, wrappers: Array<String>, builtins: Array<String>): Tier {
		final params: Null<Array<String>> = typeParamsAt(at);
		final index: Null<SymbolIndex> = _index();
		final fi: Null<SymbolIndex.FileInfo> = index?.fileInfo(_file);
		return written == null || params == null || index == null || fi == null
			? Unknown
			: headTierIn(written, fi, index, params, wrappers, builtins);
	}

	/**
	 * `headTier` for a type written in ANY indexed file `fi` — a member's declared type read where it is
	 * declared — with `params` the type parameters in scope there.
	 */
	public static function headTierIn(
		written: String, fi: SymbolIndex.FileInfo, index: SymbolIndex, params: Array<String>, wrappers: Array<String>,
		builtins: Array<String>
	): Tier {
		final head: Null<String> = headPathOf(NominalTypes.unwrapNullable(written.trim(), wrappers, index.typeSyntax), index.typeSyntax);
		if (head == null || wrappers.contains(head) || params.contains(head)) return Unknown;
		if (head.indexOf('.') >= 0) {
			final decls: Array<ResolvedType> = index.resolveTypeRefsFrom(head, fi.file);
			return decls.length == 0 ? Unknown : Bound(decls);
		}
		return switch TypeNameBinding.tierOf(head, fi, index) {
			case Free if (!builtins.contains(head)): Unknown;
			case tier: tier;
		};
	}

	/**
	 * The verdict on the RETURN type of method `method` as each of `owners` declares it DIRECTLY — the
	 * declarations the receiver's type BINDS to, never a simple name; none, or any that does not
	 * resolve non-null, is `Unproven`. Each is resolved from its WRITTEN return type in its declaring
	 * file, with the owner's and the method's own type parameters shadowing. An inherited method is not
	 * followed, and neither is one carrying `@:overload` (a call may select another signature) or a
	 * macro (its written return is not the call site's type).
	 */
	public function ofMemberReturn(owners: Array<ResolvedType>, method: String): Nullity {
		final index: Null<SymbolIndex> = _index();
		if (index == null || owners.exists(r -> !r.type.members.exists(m -> m.name == method))) return Unproven;
		var verdict: Nullity = Unproven;
		for (r in owners) for (m in r.type.members) if (m.name == method) {
			final returned: Null<String> = m.returnSource;
			final source: Null<String> = index.sourceOf(r.file.file);
			if (returned == null || source == null || m.hasOverloadMeta || m.isMacro) return Unproven;
			final params: Array<String> = r.type.typeParamNames.concat(m.typeParamNames);
			if (resolve(returned, r.file.file, params, 1, []) != NonNull) return Unproven;
			verdict = NonNull;
		}
		return verdict;
	}

	/**
	 * The verdict on the written type `typeSource` as seen from `fromFile` with `typeParams` in scope.
	 * `hops` counts the alias / abstract steps taken to reach it, which decides whether a basic value
	 * type is still `ValueType` (its own spelling at the binding) or only `NonNull`.
	 */
	private function resolve(typeSource: String, fromFile: String, typeParams: Array<String>, hops: Int, seen: Array<String>): Nullity {
		final head: Null<String> = headPathOf(typeSource, _typeSyntax);
		if (head == null || hops > MAX_HOPS || typeParams.contains(head)) return Unproven;
		final simple: String = head.substr(head.lastIndexOf('.') + 1);
		if ((_shape.nullableWrapperTypeNames ?? []).contains(simple)) return Unproven;
		if ((_shape.nonNullableTypeNames ?? []).contains(head)) return hops == 0 ? ValueType : NonNull;
		final index: Null<SymbolIndex> = _index();
		if (index == null) return Unproven;
		final candidates: Null<Array<ResolvedType>> = bindingOf(head, fromFile, index);
		return candidates != null && candidates.length > 0 && candidates.foreach(c -> ofDecl(c, hops, seen) == NonNull)
			? NonNull
			: Unproven;
	}

	/** The verdict on one resolved declaration: its kind decides, or the alias / underlying it hops to. */
	private function ofDecl(r: ResolvedType, hops: Int, seen: Array<String>): Nullity {
		final t: SymbolIndex.TypeDeclInfo = r.type;
		final key: String = '${r.file.file}#${t.name}';
		if (t.guarded || seen.contains(key)) return Unproven;
		if (_nominalKinds.contains(t.kind) || t.isAnonStruct) return NonNull;
		final next: Null<String> = _aliasKinds.contains(t.kind) ? t.aliasTargetRaw : t.underlyingRaw;
		return next == null ? Unproven : resolve(next, r.file.file, t.typeParamNames, hops + 1, seen.concat([key]));
	}

	/**
	 * The type-parameter names in scope at `bindingFrom`: every enclosing function's own list and every
	 * enclosing type's. Null when an enclosing generic type's names could not be read, since a missing
	 * name would let a parameter resolve to a same-named type.
	 */
	private function typeParamsAt(bindingFrom: Int): Null<Array<String>> {
		final fnKinds: Array<String> = _shape.functionKinds ?? [];
		final out: Array<String> = [];
		var readable: Bool = true;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && (bindingFrom < span.from || bindingFrom >= span.to)) return;
			final name: Null<String> = node.name;
			if (span != null && fnKinds.contains(node.kind)) for (p in _typeParams[span.from] ?? []) out.push(p);
			final decl: Null<RefactorSupport.TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (decl != null) {
				final params: Null<Array<String>> = typeDeclParams(decl.name);
				if (params == null)
					readable = false
				else
					for (p in params) out.push(p);
			}
			for (c in node.children) walk(c);
		}
		walk(_root);
		return readable ? out : null;
	}

	/** The type parameters of the type named `name` declared in this file, or null when the index cannot read them. */
	private function typeDeclParams(name: String): Null<Array<String>> {
		final index: Null<SymbolIndex> = _index();
		final r: Null<ResolvedType> = index?.refs.findDeclaredType(_file, name);
		return r?.type.typeParamNames;
	}

	/**
	 * The context for one parsed file, reading both declared-type maps off `typed`; a grammar with no
	 * `TypeInfoProvider` gets empty maps, so every binding is `Unproven`.
	 */
	public static function of(
		file: String, root: QueryNode, source: String, shape: RefShape, typed: Null<TypeInfoProvider>, typeSyntax: TypeSyntaxReader,
		index: () -> Null<SymbolIndex>
	): DeclaredNullity {
		return typed == null
			? new DeclaredNullity(file, root, source, shape, [], [], [], [], typeSyntax, index)
			: new DeclaredNullity(
				file, root, source, shape, typed.declaredTypes(source), typed.declaredTypeSources(source), typed.typeParamNames(source),
				typed.propertyAccessors(source), typeSyntax, index
			);
	}

	/**
	 * What `head`, written in `fromFile`, names: a dotted path resolves as a path, a simple name tier by
	 * tier in the compiler's own order (`TypeNameBinding`). Null when no tier provably answers.
	 */
	private static function bindingOf(head: String, fromFile: String, index: SymbolIndex): Null<Array<ResolvedType>> {
		if (head.indexOf('.') >= 0) return index.resolveTypeRefsFrom(head, fromFile);
		final fi: Null<SymbolIndex.FileInfo> = index.fileInfo(fromFile);
		return fi == null ? null : TypeNameBinding.bind(head, fi, index);
	}

	/**
	 * The head path of a written type (`pkg.Box<Int>` -> `pkg.Box`), or null when it is not a named type
	 * or one that holds a function type (`Array<Int -> Void>`) — the latter kept refused.
	 */
	private static function headPathOf(typeSource: String, typeSyntax: TypeSyntaxReader): Null<String> {
		final t: Null<TypeSyntax> = typeSyntax(typeSource);
		if (t == null || t.holdsFunction()) return null;
		return switch t.shape {
			case Nominal(path, _): path;
			case _: null;
		};
	}

}

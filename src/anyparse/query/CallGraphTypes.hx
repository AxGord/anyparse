package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;

/**
 * The type facts a `CallGraph` resolves against, seeded from a `SymbolIndex` that may be wider than the
 * files the graph holds (a resolution index covering libraries): the supertype and subtype tables, the
 * superclass apart from the interfaces, each type's static members and member records, the type
 * parameters and typedef targets a receiver must see through, and which member names are properties with
 * an accessor somewhere. Simple type names, like the graph itself: every table UNIONS the declarations of a
 * name, and `declarationCount` tells a consumer when a name is ambiguous. A member name declared more than once —
 * once per branch of a conditional region, an overload, by two types of one name — has ONE record joining them
 * (`joined`): what either declaration says runs code, runs; a type they spell differently is none.
 */
@:nullSafety(Strict)
final class CallGraphTypes {

	/** What each file's imports and `using`s bring into scope by simple name. */
	public final imports: CallGraphImports;

	/** Type name -> the names of its STATIC members — a bare call to one of those is not an implicit-`this` dispatch. */
	private final _staticMembers: Map<String, Array<String>> = [];

	private final _supers: Map<String, Array<String>> = [];
	private final _subs: Map<String, Array<String>> = [];

	/** Type name -> the supertypes its declarations name as INTERFACES (`implements`), apart from the superclass. */
	private final _interfaces: Map<String, Array<String>> = [];

	/** Type name -> member name -> the member's index record. */
	private final _members: Map<String, Map<String, MemberInfo>> = [];

	/** Member name -> the types declaring a property of that name with a getter or a setter. */
	private final _propertyOwners: Map<String, Array<String>> = [];

	/** Type name -> how many indexed declarations carry that simple name. */
	private final _declarations: Map<String, Int> = [];

	/** Type name -> the kinds its declarations project as. */
	private final _kinds: Map<String, Array<String>> = [];

	/** The typedefs that name an anonymous structure type. */
	private final _anonStructs: Map<String, Bool> = [];

	/** Typedef name -> the simple nominal it aliases. */
	private final _aliases: Map<String, String> = [];

	/** Every member name an indexed type declares as a STATIC function. */
	private final _staticFunctionNames: Map<String, Bool> = [];

	/** Every member name an indexed type declares as a FUNCTION. */
	private final _functionNames: Map<String, Bool> = [];

	/** The files whose declarations the tables hold. */
	private final _files: Map<String, Bool> = [];

	/** What each type's modifiers and metadata say: extern, built by a macro, constructed from a literal, forwarding. */
	public final meta: TypeMetaFacts = new TypeMetaFacts();

	/** The type parameters each type declares, and the arguments its supertypes are given. */
	public final generics: TypeParamTable = new TypeParamTable();

	/** The grammar's FIELD declaration kinds — a member of one of those, called, invokes the function value it holds. */
	private final _fieldKinds: Array<String>;

	private final _functionKinds: Array<String>;
	private final _interfaceKinds: Array<String>;

	/** Type names a function value can never be: the grammar's literal, non-nullable and array types. */
	private final _valueTypeNames: Array<String>;

	/** Declaration kinds that may alias another type, a function type included. */
	private final _aliasingKinds: Array<String>;

	/** `index` null yields the empty tables of a graph that resolves nothing. */
	public function new(index: Null<SymbolIndex>, shape: RefShape) {
		_fieldKinds = shape.fieldDeclKinds ?? [];
		_functionKinds = shape.functionKinds ?? [];
		_interfaceKinds = shape.interfaceDeclKinds ?? [];
		_valueTypeNames = [for (t in (shape.literalTypeNames ?? []).iterator()) t].concat(shape.nonNullableTypeNames ?? [])
			.concat(shape.arrayTypeNames ?? []);
		_aliasingKinds = shape.aliasingDeclKinds ?? [];
		imports = new CallGraphImports(
			shape.execution?.enumConstructorKinds ?? [], isStatic,
			type -> declarationCount(type) == 0 || meta.isExtern(type) || firstOnChain(type, t -> meta.isBuilt(t)) != null
		);
		if (index != null) merge(index);
	}

	/** The index's direct supertypes of `typeName`, interfaces included. */
	public inline function supertypesOf(typeName: String): Array<String> {
		return _supers[typeName] ?? [];
	}

	/** The index's direct subtypes of `typeName`. */
	public inline function subtypesOf(typeName: String): Array<String> {
		return _subs[typeName] ?? [];
	}

	/** Whether an indexed declaration of `typeName` is an interface. */
	public inline function isInterface(typeName: String): Bool {
		return (_kinds[typeName] ?? []).exists(k -> _interfaceKinds.contains(k));
	}

	/** How many indexed declarations carry the simple name `typeName` — more than one means a lookup by that name is ambiguous. */
	public inline function declarationCount(typeName: String): Int {
		return _declarations[typeName] ?? 0;
	}

	/** Whether the tables hold the declarations of `file`. */
	public inline function holdsFile(file: String): Bool {
		return _files.exists(CallGraphNames.normalizePath(file));
	}

	/** Whether any indexed type declares a STATIC function named `name`. */
	public inline function hasStaticFunctionNamed(name: String): Bool {
		return _staticFunctionNames.exists(name);
	}

	/** Whether any indexed type declares a function named `name`. */
	public inline function hasFunctionNamed(name: String): Bool {
		return _functionNames.exists(name);
	}

	/** Whether `typeName` declares `member` static. */
	public inline function isStatic(typeName: String, member: String): Bool {
		return (_staticMembers[typeName] ?? []).contains(member);
	}

	/** Whether any indexed type declares a property named `name` whose getter or setter runs code. */
	public inline function hasPropertyNamed(name: String): Bool {
		return _propertyOwners.exists(name);
	}

	/**
	 * Whether every type on `typeName`'s supertype chain (itself included) is indexed
	 * — a member none of them declares is then provably not a method of the type.
	 */
	public inline function chainFullyIndexed(typeName: String): Bool {
		return firstOnChain(typeName, t -> !_members.exists(t)) == null;
	}

	/** The type on `typeName`'s supertype chain (itself first) whose record declares `member`, or null. */
	public inline function declaringTypeOf(typeName: String, member: String): Null<String> {
		return firstOnChain(typeName, t -> _members[t]?.exists(member) == true);
	}

	/**
	 * Whether a value of the nominal `typeName` can never be a function — a method read through it yields
	 * no method: a literal, non-nullable or array type, a typedef of an anonymous structure, or a type every
	 * indexed declaration of which is a class, enum or interface (never one that may alias a function type).
	 */
	public function holdsNoFunction(typeName: String): Bool {
		if (_valueTypeNames.contains(typeName) || _anonStructs.exists(typeName)) return true;
		final kinds: Array<String> = _kinds[typeName] ?? [];
		return kinds.length > 0 && !kinds.exists(k -> _aliasingKinds.contains(k));
	}

	/**
	 * Fold the declarations of every file of `index` the tables do not hold yet — how a graph that grows past
	 * the index it was built with still learns the types of the files it adds.
	 */
	public function merge(index: SymbolIndex): Void {
		for (fi in index.allFiles()) {
			final key: String = CallGraphNames.normalizePath(fi.file);
			if (_files.exists(key)) continue;
			_files[key] = true;
			for (t in fi.types) record(t);
			imports.recordFile(fi, key);
		}
	}

	/**
	 * Take the member records of `fi`, a file whose declarations did not change, in place of the ones held: the
	 * same members, at the offsets the file's new text puts them. A name more than one declaration shares keeps
	 * its union untouched.
	 */
	public function refreshFile(fi: FileInfo): Void {
		for (t in fi.types) if (declarationCount(t.name) == 1) {
			final table: Map<String, MemberInfo> = _members[t.name] ?? [];
			final seen: Array<String> = [];
			for (m in t.members) {
				final held: Null<MemberInfo> = seen.contains(m.name) ? table[m.name] : null;
				table[m.name] = held == null ? m : joined(held, m);
				seen.push(m.name);
			}
			_members[t.name] = table;
		}
	}

	/**
	 * The SUPERCLASS of `typeName` — the one supertype a constructor chain and a `super` reference follow — or
	 * null when it extends nothing. An interface is never one, whatever order the header names them in.
	 */
	public function superclassOf(typeName: String): Null<String> {
		final interfaces: Array<String> = _interfaces[typeName] ?? [];
		for (s in supertypesOf(typeName)) if (!interfaces.contains(s) && !isInterface(s)) return s;
		return null;
	}

	/** `typeName` with every typedef alias hop followed (cycle-safe); `typeName` itself when it aliases nothing. */
	public function resolveAlias(typeName: String): String {
		var t: String = typeName;
		final seen: Array<String> = [];
		while (_aliases.exists(t) && !seen.contains(t)) {
			seen.push(t);
			t = _aliases[t] ?? t;
		}
		return t;
	}

	/** The first type on `typeName`'s supertype chain, breadth first from itself, that `test` accepts, or null (cycle-safe). */
	public function firstOnChain(typeName: String, test: String -> Bool): Null<String> {
		final queue: Array<String> = [typeName];
		final visited: Map<String, Bool> = [];
		var qi: Int = 0;
		while (qi < queue.length) {
			final t: String = queue[qi++];
			if (visited.exists(t)) continue;
			visited[t] = true;
			if (test(t)) return t;
			for (s in supertypesOf(t)) queue.push(s);
		}
		return null;
	}

	/** The record of `member` on `typeName` or the nearest supertype declaring it, or null when no indexed type does. */
	public function memberOnChain(typeName: String, member: String): Null<MemberInfo> {
		final owner: Null<String> = declaringTypeOf(typeName, member);
		return owner == null ? null : _members[owner]?.get(member);
	}

	/**
	 * The property `member` as `typeName`'s chain declares it — its record and the declaring type — or null
	 * when the nearest declaration carries no getter and no setter (a plain field, which runs no code) or no
	 * indexed type declares it.
	 */
	public function propertyOnChain(typeName: String, member: String): Null<{ info: MemberInfo, owner: String }> {
		final owner: Null<String> = declaringTypeOf(typeName, member);
		if (owner == null) return null;
		final info: Null<MemberInfo> = _members[owner]?.get(member);
		return info == null || !(info.hasGetter || info.hasSetter) ? null : { info: info, owner: owner };
	}

	/** Whether `typeName`'s chain declares `member` as a FIELD — a call to it invokes the function value it holds. */
	public function fieldOnChain(typeName: String, member: String): Bool {
		final info: Null<MemberInfo> = memberOnChain(typeName, member);
		return info != null && _fieldKinds.contains(info.kind);
	}

	/** Whether `typeName`'s chain declares `member` as a FUNCTION. */
	public function functionOnChain(typeName: String, member: String): Bool {
		final info: Null<MemberInfo> = memberOnChain(typeName, member);
		return info != null && _functionKinds.contains(info.kind);
	}

	/** Fold one declaration into the tables — a later declaration of the same simple name UNIONS with the earlier. */
	private function record(t: TypeDeclInfo): Void {
		// a typedef re-exporting a type of its own name is not a second declaration of it
		if (!CallGraphNames.selfAlias(t)) _declarations[t.name] = (_declarations[t.name] ?? 0) + 1;
		meta.record(t);
		if (t.isAnonStruct) _anonStructs[t.name] = true;
		unionInto(_kinds, t.name, [t.kind]);
		unionInto(_supers, t.name, t.supertypes);
		generics.record(t);
		unionInto(_interfaces, t.name, t.interfaces);
		final target: Null<String> = t.aliasTargetNominal;
		if (target != null && target != t.name) _aliases[t.name] = target;
		for (s in t.supertypes) unionInto(_subs, s, [t.name]);
		recordMembers(t);
	}

	/** Fold the members of one declaration into the member tables. */
	private function recordMembers(t: TypeDeclInfo): Void {
		final statics: Array<String> = _staticMembers[t.name] ?? [];
		final table: Map<String, MemberInfo> = _members[t.name] ?? [];
		for (m in t.members) {
			final held: Null<MemberInfo> = table[m.name];
			final record: MemberInfo = held == null ? m : joined(held, m);
			table[m.name] = record;
			// a member one declaration makes an instance one is dispatched on as one
			if (record.isStatic && !statics.contains(m.name)) statics.push(m.name);
			if (!record.isStatic) statics.remove(m.name);
			if (m.hasGetter || m.hasSetter) unionInto(_propertyOwners, m.name, [t.name]);
			if (_functionKinds.contains(m.kind)) _functionNames[m.name] = true;
			if (_functionKinds.contains(m.kind) && m.isStatic) _staticFunctionNames[m.name] = true;
		}
		_staticMembers[t.name] = statics;
		_members[t.name] = table;
	}

	/**
	 * The one record standing for two declarations `a` and `b` of a member name — one per branch of a conditional region,
	 * an overload, a declaration of another type of the same simple name — for a table keyed by that name. What makes a use
	 * of the member run code is either's: an accessor, a replaceable body, an implicit call, an overload, an extern body; a
	 * type or parameter the two spell differently is neither's (null), so nothing resolves through it; the member is an
	 * instance one and runs at run time when either declaration makes it so. A field in one declaration and a function in
	 * the other is a function the program may replace (`isDynamic`): a call of it runs the body or the value the field holds.
	 */
	private function joined(a: MemberInfo, b: MemberInfo): MemberInfo {
		// noqa: complexity
		final mixed: Bool = a.kind != b.kind && (_functionKinds.contains(a.kind) || _functionKinds.contains(b.kind));
		final arity: Int = a.paramTypeSources.length > b.paramTypeSources.length ? a.paramTypeSources.length : b.paramTypeSources.length;
		return {
			name: a.name,
			hasGetter: a.hasGetter || b.hasGetter,
			hasSetter: a.hasSetter || b.hasSetter,
			returnNominal: agreed(a.returnNominal, b.returnNominal),
			returnSource: agreed(a.returnSource, b.returnSource),
			hasOverloadMeta: a.hasOverloadMeta || b.hasOverloadMeta,
			typeSource: agreed(a.typeSource, b.typeSource),
			firstParamTypeSource: agreed(a.firstParamTypeSource, b.firstParamTypeSource),
			paramTypeSources: [for (i in 0...arity) agreed(paramAt(a, i), paramAt(b, i))],
			visibility: a.visibility,
			isOverride: a.isOverride || b.isOverride,
			kind: mixed && !_functionKinds.contains(a.kind) ? b.kind : a.kind,
			declFrom: a.declFrom,
			isStatic: a.isStatic && b.isStatic,
			isInline: a.isInline && b.isInline,
			isMacro: a.isMacro && b.isMacro,
			operatorOverloads: union(a.operatorOverloads, b.operatorOverloads),
			initializerKind: a.initializerSource == b.initializerSource ? agreed(a.initializerKind, b.initializerKind) : null,
			initializerSource: agreed(a.initializerSource, b.initializerSource),
			isImplicitConversion: a.isImplicitConversion || b.isImplicitConversion,
			isImplicitCall: a.isImplicitCall || b.isImplicitCall,
			implicitCallMetas: union(a.implicitCallMetas, b.implicitCallMetas),
			isDynamic: a.isDynamic || b.isDynamic || mixed,
			isExtern: a.isExtern || b.isExtern,
			isOverload: a.isOverload || b.isOverload,
			typeParamNames: union(a.typeParamNames, b.typeParamNames),
			metaNames: union(a.metaNames, b.metaNames),
			excludedFromExtensions: a.excludedFromExtensions && b.excludedFromExtensions,
			guarded: a.guarded || b.guarded
		};
	}

	/** `a` when `b` spells the same, else null: two declarations that type something differently type it as neither. */
	private static inline function agreed(a: Null<String>, b: Null<String>): Null<String> {
		return a == b ? a : null;
	}

	/** The written type of parameter `i` of `m`, null past its last one. */
	private static inline function paramAt(m: MemberInfo, i: Int): Null<String> {
		return i < m.paramTypeSources.length ? m.paramTypeSources[i] : null;
	}

	/** Every entry of `a`, then each of `b` it lacks. */
	private static function union(a: Array<String>, b: Array<String>): Array<String> {
		return a.concat([for (x in b) if (!a.contains(x)) x]);
	}

	public static function unionInto(map: Map<String, Array<String>>, key: String, values: Array<String>): Void {
		final list: Array<String> = map[key] ?? [];
		for (v in values) if (!list.contains(v)) list.push(v);
		map[key] = list;
	}

}

package anyparse.query;

import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The ONE answer the reach analysis gives to "can a value statically typed `T` be an object that carries `owner`'s
 * member?" — every relation-style decision in it asks here: whether an access through a typed receiver touches the
 * member, whether a reflective read by name does, which types' implicitly-called methods a value may run, what an
 * object handed to target code holds.
 *
 * A value typed `T` is at run time `T` or one of its subtypes, classes and interfaces alike, both `extends` and
 * `implements` (`declaredValueTypes`) — or any instance that left the type system (`ValueEscapes`), which an implicit
 * conversion from a catch-all or an unchecked cast may hand to a `T` position: together its VALUE TYPES
 * (`valueTypes`). A value relates to an owner when its value types meet the types that carry the owner's member. An
 * abstract (its value is its underlying one), a structure, a catch-all, a class value, a type parameter and a name not
 * declared exactly once answer "any"; so does a type whose subtypes cannot all be known — a file that did not parse
 * spells its name, or no oracle list declared complete says that the index holds every type the builds compile
 * (`classpathComplete`), so a subtype may live where nothing here can see.
 */
@:nullSafety(Strict)
final class ValueCarriers {

	/**
	 * Set when a question of the current walk met the classpath not known to be complete (`classpathComplete`): the
	 * configured builds may know it. Cleared by `startQuestion`.
	 */
	public var metIncomplete(default, null): Bool = false;

	/** Type -> whether every subtype of it is one the index lists (`complete`), settled on first need. */
	private final _completeByType: Map<String, Bool> = [];

	private final _scope: ReachProject;

	/** Whether the index holds every type the run's builds compile; asked once, on first need. */
	private final _complete: () -> Bool;

	/** The types whose instances may have escaped the type system (`ValueEscapes.escaped`), or null for any. */
	private final _escaped: () -> Null<Array<String>>;

	private var _completeMemo: Null<Bool> = null;

	public function new(scope: ReachProject, complete: () -> Bool, escaped: () -> Null<Array<String>>) {
		_scope = scope;
		_complete = complete;
		_escaped = escaped;
	}

	/** Start a new question: nothing met yet. */
	public function startQuestion(): Void {
		metIncomplete = false;
	}

	/** Drop what was settled over the project's text, which changed. */
	public function forget(): Void {
		_completeByType.clear();
	}

	/** Whether the index holds every type the run's builds compile, so a subtype it does not list does not exist. */
	public function classpathComplete(): Bool {
		final held: Null<Bool> = _completeMemo;
		final answer: Bool = held ?? _complete();
		_completeMemo = answer;
		if (!answer) metIncomplete = true;
		return answer;
	}

	/**
	 * The types a value statically typed `type` may be at run time — the nominal it names, an alias seen through, every
	 * subtype of it, and every type whose instances may have escaped the type system (`ValueEscapes`) — or null for
	 * "any" (see the type doc).
	 */
	public function valueTypes(type: String): Null<Array<String>> {
		final declared: Null<Array<String>> = declaredValueTypes(type);
		if (declared == null) return null;
		final escaped: Null<Array<String>> = _escaped();
		if (escaped == null) return null;
		final out: Array<String> = declared.copy();
		for (t in escaped) if (!out.contains(t)) out.push(t);
		return out;
	}

	/**
	 * The types a value of static type `type` may be while it never left the type system: the nominal it names, an alias
	 * seen through, and every subtype of it — or null for "any" (see the type doc). Also the types an object of `type`
	 * carries a member of.
	 */
	public function declaredValueTypes(type: String): Null<Array<String>> {
		final nominal: Null<String> = nominalOf(type);
		if (nominal == null) return null;
		final decl: Null<TypeDeclInfo> = declarationOf(nominal);
		if (decl == null || (_scope.shape.underlyingThisTypeKinds ?? []).contains(decl.kind) || !complete(nominal)) return null;
		final out: Array<String> = [nominal];
		for (s in _scope.index.subtypes.subtypeNames(nominal)) {
			if (!complete(s)) return null;
			if (!out.contains(s)) out.push(s);
		}
		return out;
	}

	/**
	 * Whether a position declared `type` keeps the nominal type of what it holds: a class, an interface or an enum the
	 * index declares once, an alias of one seen through, written with every type argument it declares, each of them a
	 * primitive or itself typed. A catch-all, a type parameter, a structure, a function type and an abstract (whose
	 * conversions may take in any value) do not, anywhere in it.
	 */
	public function typedNominal(type: String): Bool {
		final source: String = NominalTypes.unwrapNullable(StringTools.trim(type), _scope.shape.memberTransparentWrapperTypeNames ?? []);
		final nominal: Null<String> = nominalOf(source);
		final decl: Null<TypeDeclInfo> = nominal == null ? null : declarationOf(nominal);
		if (decl == null || (_scope.shape.underlyingThisTypeKinds ?? []).contains(decl.kind)) return false;
		// what the value holds is typed only when every argument is: `Array<Dynamic>` holds anything
		final args: Array<String> = NominalTypes.typeArgumentSourcesOf(source, _scope.plugin.typeSyntax) ?? [];
		if (args.length < decl.typeParamNames.length) return false;
		for (a in args) if (!primitive(a) && !typedNominal(a)) return false;
		return true;
	}

	/** Whether `type` is one of the language's primitive value types — a literal's, or one that cannot be null. */
	public function primitive(type: String): Bool {
		final nominal: Null<String> = NominalTypes.outerNominalOf(
			NominalTypes.unwrapNullable(StringTools.trim(type), _scope.shape.memberTransparentWrapperTypeNames ?? [])
		);
		if (nominal == null) return false;
		final names: Array<String> =
			[for (t in (_scope.shape.literalTypeNames ?? []).iterator()) t].concat(_scope.shape.nonNullableTypeNames ?? []);
		return names.contains(nominal);
	}


	/**
	 * Whether a value statically typed `type` (null: not known) may be an object that carries a member `owner` declares:
	 * `Carries` when the types it may be meet the types that carry the member, `CannotCarry` when both are known and
	 * disjoint, `MayCarry` for "any". An object of an escaped type may be in a position of any type (`valueTypes`).
	 */
	public function relation(type: Null<String>, owner: String): CarryRelation {
		final values: Null<Array<String>> = type == null ? null : valueTypes(type);
		final owners: Null<Array<String>> = declaredValueTypes(owner);
		if (values == null || owners == null) return MayCarry;
		return values.exists(t -> owners.contains(t)) ? Carries : CannotCarry;
	}

	/**
	 * The nominal type `type` names, a typedef alias of one seen through, or null for anything else: a structure, a
	 * function type, a catch-all, the class-value type, a name not declared exactly once.
	 */
	private function nominalOf(type: String): Null<String> {
		var t: Null<String> = NominalTypes.outerNominalOf(StringTools.trim(type));
		final seen: Array<String> = [];
		while (t != null) {
			final current: String = t;
			if (seen.contains(current) || (_scope.shape.catchAllTypeNames ?? []).contains(current)) return null;
			if (current == _scope.shape.execution?.classValueTypeName) return null;
			seen.push(current);
			final decl: Null<TypeDeclInfo> = declarationOf(current);
			if (decl == null || decl.isAnonStruct) return null;
			final isAlias: Bool = (_scope.shape.aliasingDeclKinds ?? []).contains(decl.kind)
				&& !(_scope.shape.underlyingThisTypeKinds ?? []).contains(decl.kind);
			if (!isAlias) return current;
			// a typedef: an alias of one nominal is seen through, any other body is a structure or a function type
			t = decl.aliasTargetNominal;
		}
		return null;
	}

	/** Whether every subtype of `type` is one the index lists: the classpath is complete and no unparsed file spells it. */
	private function complete(type: String): Bool {
		if (!classpathComplete()) return false;
		final held: Null<Bool> = _completeByType[type];
		if (held != null) return held;
		var answer: Bool = true;
		for (file in _scope.index.skippedFiles()) {
			final source: Null<String> = _scope.sources[file] ?? _scope.index.sourceOf(file);
			if (source == null || RawSourceScan.mentionsWord(source, type)) {
				answer = false;
				break;
			}
		}
		_completeByType[type] = answer;
		return answer;
	}

	/** The single indexed declaration of `type`, or null. */
	private function declarationOf(type: String): Null<TypeDeclInfo> {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		return site == null ? null : _scope.index.fileInfo(site.file)?.types.find(d -> d.name == type);
	}

}

/** How a value of one type relates to another type's member (`ValueCarriers.relation`). */
enum CarryRelation {

	/** Their value types meet: the value may be an object carrying the member. */
	Carries;

	/** Nothing can be told: the value may be anything. */
	MayCarry;

	/** Both value types are known and disjoint: the value never carries the member. */
	CannotCarry;

}

package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.query.CompilerFacts.TypeFact;

using Lambda;

/**
 * Whether a place whose static type says what it holds may hold a value of another type — an object where a `String`, an
 * `Int` or an array of them is written, an instance of one class where another is — as the compiler facts of every build
 * prove it: the one predicate behind each reading that takes a static type at its word (`NativeSiteReach.noObject`, the
 * typed calls and writes `FunctionValueTypes` reads).
 *
 * Only a value that left the type system (`FactsEscapes`) reaches a place of another type: an unchecked cast (`cast e`), a
 * value of a catch-all, a type parameter or a structure unified with the place's type, and a write by a name — reflection,
 * a field of a value of no class, target code — into a field of an escaped object. The facts record the first two as flows,
 * which the escapes read; the third lands a value at a typed field without any flow, so no reading of the flows can bound
 * what a place holds once anything escaped. What decides it is the build's target (`CompilerFacts.targets`): hxcpp CONVERTS
 * a value into a typed place (`converts`), as measured in its runtime — a core value type (`@:coreType @:notNull`: `Int`,
 * `Float`, `Bool`, `cpp.Char`) is a C++ scalar a `Dynamic` converts to (`Dynamic::operator int`, `include/Dynamic.h`); a
 * `String` is a value a `Dynamic` converts to by its `toString` (`String::String(const Dynamic &)`, `src/String.cpp`); a
 * program class and the built-in array are pointers a conversion checks, null for an instance of another class
 * (`ObjectPtr::CastPtr`, `_hx_isInstanceOf`, `include/hx/Object.h`), and an array of another element type is copied element
 * by element, each converted (`Array(const Array<SOURCE_> &)`, `include/Array.h`); a field set by its name converts as its
 * own assignment does. A `cpp.Star` is a C pointer to its argument. A nullable core value type is boxed as a `Dynamic`, and so
 * are a catch-all, a structure, a function type, a type parameter, an enum, an interface,
 * an extern class and any other abstract (read as what it may wrap): such a place
 * keeps what it is handed, as every place of every other target does (`keeps`).
 */
@:nullSafety(Strict)
final class UncheckedConversions {

	/** The nullable wrapper: a value of it is one of its argument, or null. */
	private static inline final NULLABLE: String = 'Null';

	/** The metadata of a type the compiler represents itself (`TypeFact.meta`). */
	private static inline final CORE_TYPE: String = ':coreType';

	/** The metadata of a type no value of which is null (`TypeFact.meta`). */
	private static inline final NOT_NULL: String = ':notNull';

	/** The target that converts a value into a typed place (`converts`). */
	private static inline final CONVERTING_TARGET: String = 'cpp';

	/** The language's string type, a value hxcpp converts into (`converts`). */
	private static inline final STRING: String = 'String';

	/** hxcpp's C pointer type: a `cpp.Star<T>` is a `T *`, whatever its declaration reads as (`converts`). */
	private static inline final POINTER: String = 'cpp.Star';

	private final _table: CompilerFacts;

	/** The primitive types' ids: a value of one is no object. */
	private final _inert: Array<String>;

	/** The built-in array's ids: a value of one holds its elements and runs no code of its own. */
	private final _arrays: Array<String>;

	/** Whether some build keeps what lands at a place of a type, by the type as the facts spell it (`keeps`). */
	private final _kept: Map<String, Bool> = [];

	public function new(table: CompilerFacts, inert: Array<String>, arrays: Array<String>) {
		_table = table;
		_inert = inert;
		_arrays = arrays;
	}

	/**
	 * Whether a value of the facts type `t` is never an object: by its type (`byType`), and at each place it is read through
	 * no value that left the type system may sit — none did (`escaped` false), or every build converts there (`keeps`).
	 */
	public function none(t: FactsType, escaped: Bool): Bool {
		return noneBy(t, place -> escaped && keeps(place), []);
	}

	/**
	 * Whether a value of the facts type `t` is never an object by its type alone: a primitive, a type the compiler represents
	 * itself no value of which is null (`Int`'s kind — `cpp.Char`), a nullable one of those, an alias of one, or the built-in
	 * array of one, whose own methods are target code running no code of the program's — whatever a value that left the type
	 * system may be where it is held.
	 */
	public function byType(t: FactsType): Bool {
		return noneBy(t, _ -> false, []);
	}

	/**
	 * Whether a value that left the type system may sit at a place typed by the class `id`, at any type arguments: some build
	 * keeps what lands there (see the type doc). A typed call or write naming `id` may then run on it.
	 */
	public function holdsForeign(id: String): Bool {
		return keeps(Named(id, []));
	}

	/**
	 * Whether a value of `t` is never an object by its type (see `byType`), no place it is read through holding a foreign one
	 * (`foreign`) — the place `t` types itself when `here`, not again for a nullable wrapper or an alias of it, which type the
	 * same place; `seen` holds the aliases already read through.
	 */
	private function noneBy(t: FactsType, foreign: FactsType -> Bool, seen: Array<String>, here: Bool = true): Bool {
		if (here && foreign(t)) return false;
		return switch t {
			case Named(NULLABLE, [inner]): noneBy(inner, foreign, seen, false);
			case Named(id, [element]) if (_arrays.contains(id)): noneBy(element, foreign, seen);
			case Named(id, args):
				final fact: Null<TypeFact> = _table.type(id);
				if (id.indexOf('.') < 0 && _inert.contains(id))
					true
				else if (fact == null || !fact.alike || seen.contains(id))
					false
				else if (fact.kind == 'typedef')
					fact.targets.length > 0 && fact.targets.foreach(target -> {
						final read: Null<FactsType> = FactsTypeTree.read(target);
						read != null
						&& noneBy(FactsEscapes.substitute(read, FactsEscapes.bindings(id, fact, args)), foreign, seen.concat([id]), false);
					})
				else
					coreValue(fact);
			case _: false;
		};
	}

	/** Whether some build keeps a value of any type put at a place typed `t` (see the type doc); read once per type. */
	private function keeps(t: FactsType): Bool {
		final text: String = FactsTypeTree.text(t);
		final held: Null<Bool> = _kept[text];
		if (held != null) return held;
		final answer: Bool = _table.targets.exists(target -> target != CONVERTING_TARGET) || !converts(t, []);
		_kept[text] = answer;
		return answer;
	}

	/**
	 * Whether hxcpp converts a value put at a place typed `t` into one of that type (see the type doc): a core value type, a
	 * `String`, a program class, the built-in array, a nullable one of the last three, a C pointer to one, an alias of one;
	 * `seen` holds the aliases already read through.
	 */
	private function converts(t: FactsType, seen: Array<String>): Bool {
		return switch t {
			// a nullable core value is boxed
			case Named(NULLABLE, [inner]):
				!coreValueType(inner, []) && converts(inner, seen);
			case Named(STRING, []): true;
			case Named(POINTER, [pointed]): converts(unwrap(pointed), seen);
			case Named(id, args):
				final fact: Null<TypeFact> = _table.type(id);
				if (fact == null || seen.contains(id) || !fact.alike)
					false
				else if (_arrays.contains(id))
					true
				else
					switch fact.kind {
						case 'class': !fact.isExtern;
						case 'abstract': coreValue(fact);
						case 'typedef': readThrough(fact.targets, id, fact, args, seen);
						case _: false;
					}
			case _: false;
		};
	}

	/** Whether `t` is a core value type, or an alias that may be one (`coreValue`); `seen` holds the aliases already read through. */
	private function coreValueType(t: FactsType, seen: Array<String>): Bool {
		return switch t {
			case Named(POINTER, _): false;
			case Named(id, args):
				final fact: Null<TypeFact> = _table.type(id);
				if (fact == null || seen.contains(id))
					false
				else if (fact.kind == 'typedef')
					fact.targets.exists(target -> {
						final read: Null<FactsType> = FactsTypeTree.read(target);
						read == null
						|| coreValueType(FactsEscapes.substitute(read, FactsEscapes.bindings(id, fact, args)), seen.concat([id]));
					})
				else
					coreValue(fact);
			case _: false;
		};
	}

	/** Whether every type `texts` spells, read as the declaration `fact` of `id` written with `args`, converts (`converts`). */
	private function readThrough(texts: Array<String>, id: String, fact: TypeFact, args: Array<FactsType>, seen: Array<String>): Bool {
		return texts.length > 0 && texts.foreach(text -> {
			final read: Null<FactsType> = FactsTypeTree.read(text);
			read != null && converts(FactsEscapes.substitute(read, FactsEscapes.bindings(id, fact, args)), seen.concat([id]));
		});
	}

	/** Whether the typed type `fact` is a core value type: one the compiler represents itself, no value of which is null. */
	private static inline function coreValue(fact: TypeFact): Bool {
		return fact.kind == 'abstract' && fact.meta.contains(CORE_TYPE) && fact.meta.contains(NOT_NULL);
	}

	/** `t` without the nullable wrappers around it. */
	private static function unwrap(t: FactsType): FactsType {
		return switch t {
			case Named(NULLABLE, [inner]): unwrap(inner);
			case _: t;
		};
	}

}

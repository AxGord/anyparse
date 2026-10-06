package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.query.CompilerFacts.NativeFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.FactsNativeReach.NativeHand;

using Lambda;

/**
 * What a native site the member-reach walk meets may do to the question's member, where the compiler facts are the truth
 * (`FactsView.truth`), under the one assumption `FactsEscapes` states for the project and the libraries alike: target code
 * reaches only the values handed to it. Handed are what a call of the site hands it (`NativeFact.handed`) and what its text
 * names (`FactsNativeReach`): a local or parameter, the object its method runs on, a static variable.
 *
 * The site is a blind spot (`Blind`) when its text is computed, when its text names the member or an accessor of it, and
 * when a value it reaches may be an object carrying the member: one of no value type (`noObject`), while an object of a type
 * carrying the member may have left the type system — target code is handed nothing that did not leave it
 * (`FactsEscapes`), and a value of any type may be such an object once it has (`ValueCarriers.valueTypes`). Any other site
 * enters the program, at most, through a positive list (`Hands`), the same for every target and for both kinds of site the
 * walk meets — a call carrying code (`__cpp__`, `Syntax.code`, a native identifier) and a call of an extern
 * (`MemberReach.externSite`): (a) what it is handed, read by type (`take`): a function value; an object, whose members it may
 * call by a name and whose function values it may call; the elements of a value of the built-in array, whose own methods run
 * no code of the program's; nothing through a value that is no object; (b) what its text names globally: a class of the
 * program (`FactsNativeReach.classesNamed`), whose statics and constructor it may run as Haxe code naming the class does, and
 * an instance of which it may then hold; (c) reflection by name: only on what it holds — its members by name, (a) — since it
 * makes a class from a name only inside the reflection whose calls the facts record (`FactsEscapes`). Anything the list
 * does not bound is any code (`types` null).
 */
@:nullSafety(Strict)
final class NativeSiteReach {

	/** The nullable wrapper: a value of it is one of its argument, or null. */
	private static inline final NULLABLE: String = 'Null';

	/** The metadata of a type the compiler represents itself (`TypeFact.meta`). */
	private static inline final CORE_TYPE: String = ':coreType';

	/** The metadata of a type no value of which is null (`TypeFact.meta`). */
	private static inline final NOT_NULL: String = ':notNull';

	private final _table: CompilerFacts;
	private final _native: FactsNativeReach;

	/** The primitive types' ids: a value of one is no object. */
	private final _inert: Array<String>;

	/** The built-in array's ids (`ExecutionShape.arrayTypeNames`): a value of one holds its elements and runs no code of its own. */
	private final _arrays: Array<String>;

	public function new(table: CompilerFacts, inert: Array<String>, arrays: Array<String>) {
		_table = table;
		_native = new FactsNativeReach(table);
		_inert = inert;
		_arrays = arrays;
	}

	/**
	 * What the target code at `x` may do to the member `names` spell — its own name and those of its accessors — when an
	 * object carrying it may have left the type system (`ownerEscaped`): see the type doc.
	 */
	public function judge(x: NativeFact, names: Array<String>, ownerEscaped: Bool): NativeVerdict {
		final code: Null<String> = x.code;
		final words: Array<String> = code == null ? [] : FactsNativeReach.targetNames(code);
		if (words.exists(n -> names.contains(n))) return Blind;
		final into: NativeHands = { types: [], values: false };
		final hand: NativeHand = {
			escape: text -> {
				final read: Null<FactsType> = FactsTypeTree.read(text);
				read != null && take(read, ownerEscaped, into);
			},
			escapeType: t -> take(t, ownerEscaped, into),
			refuse: reason -> false
		};
		if (!_native.siteEscapes(x, hand)) return Blind;
		return Hands(into.types, into.values, _native.classesNamed(words));
	}

	/**
	 * Note in `into` what target code handed a value of the facts type `t` may run with it (see the type doc): nothing for a
	 * value that is no object (`noObject`); for a function value, that value, and for an object, the function values it may
	 * hold (`NativeHands.values`) and its members by name — of the type its source spells (`ReachGraph.handedMemberIds` reads
	 * a function type, and an array's elements, from it), any (`types` null) when none does. False when the value may be an
	 * object carrying the member: one of any type once such an object left the type system (`ownerEscaped`).
	 */
	public function take(t: FactsType, ownerEscaped: Bool, into: NativeHands): Bool {
		if (noObject(t, [])) return true;
		if (ownerEscaped) return false;
		into.values = true;
		final types: Null<Array<String>> = into.types;
		final source: Null<String> = FactsView.simpleSource(FactsTypeTree.text(t));
		if (types == null) return true;
		if (source == null)
			into.types = null
		else if (!types.contains(source))
			types.push(source);
		return true;
	}

	/**
	 * Whether a value of the type `t` is never an object: a primitive (`_inert`), a type the compiler represents itself no value
	 * of which is null — `Int`'s kind, which a platform's own value types share (`cpp.Char`) — a nullable one of those, an
	 * alias of one, or the built-in array (`_arrays`) of one, whose own methods are target code running no code of the
	 * program's. `seen` holds the aliases already read through.
	 */
	private function noObject(t: FactsType, seen: Array<String>): Bool {
		return switch t {
			case Named(NULLABLE, [inner]): noObject(inner, seen);
			case Named(id, [element]) if (_arrays.contains(id)): noObject(element, seen);
			case Named(id, args):
				final fact: Null<TypeFact> = _table.type(id);
				if (id.indexOf('.') < 0 && _inert.contains(id))
					true
				else if (fact == null || !fact.alike || seen.contains(id))
					false
				else if (fact.kind == 'typedef')
					fact.targets.length > 0 && fact.targets.foreach(target -> {
						final read: Null<FactsType> = FactsTypeTree.read(target);
						read != null && noObject(FactsEscapes.substitute(read, FactsEscapes.bindings(id, fact, args)), seen.concat([id]));
					})
				else
					fact.kind == 'abstract' && fact.meta.contains(CORE_TYPE) && fact.meta.contains(NOT_NULL);
			case _: false;
		};
	}

}

/** What a native site may do to the question's member (`NativeSiteReach.judge`). */
enum NativeVerdict {

	/** It may reach the member: a blind spot. */
	Blind;

	/**
	 * It may run what the objects it is handed let target code run by a name — the types of those objects, as source spells
	 * them; null for objects of a type no source spells, empty for none — the function values it is handed or an object it
	 * is handed may hold (`values`), and what a class its text names lets code naming it run (`classes`, typed ids: its
	 * statics, its constructor, and an instance's members by name).
	 */
	Hands(types: Null<Array<String>>, values: Bool, classes: Array<String>);

}

/** What target code handed values may run with them (`NativeSiteReach.take`). */
typedef NativeHands = {

	/** The types of the objects it is handed, as source spells them; null for an object of a type no source spells. */
	var types: Null<Array<String>>;

	/** Whether it is handed a function value, or an object that may hold one. */
	var values: Bool;
}

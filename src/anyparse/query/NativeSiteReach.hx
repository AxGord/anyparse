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
 * runs, at most, what an object it reaches lets it run by a name and the function values it is handed (`Hands`).
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

	public function new(table: CompilerFacts, inert: Array<String>) {
		_table = table;
		_native = new FactsNativeReach(table);
		_inert = inert;
	}

	/**
	 * What the target code at `x` may do to the member `names` spell — its own name and those of its accessors — when an
	 * object carrying it may have left the type system (`ownerEscaped`): see the type doc.
	 */
	public function judge(x: NativeFact, names: Array<String>, ownerEscaped: Bool): NativeVerdict {
		final code: Null<String> = x.code;
		if (code != null && FactsNativeReach.targetNames(code).exists(n -> names.contains(n))) return Blind;
		final handed: Array<String> = [];
		var any: Bool = false;
		function take(t: FactsType, text: Null<String>): Bool {
			if (noObject(t, [])) return true;
			if (ownerEscaped) return false;
			final source: Null<String> = text == null ? null : FactsView.simpleSource(text);
			if (source == null)
				any = true
			else if (!handed.contains(source))
				handed.push(source);
			return true;
		}
		final hand: NativeHand = {
			escape: text -> {
				final read: Null<FactsType> = FactsTypeTree.read(text);
				read != null && take(read, text);
			},
			escapeType: t -> take(t, plainId(t)),
			refuse: reason -> false
		};
		if (!_native.siteEscapes(x, hand)) return Blind;
		return Hands(any ? null : handed);
	}

	/**
	 * Whether a value of the type `t` is never an object: a primitive (`_inert`), a type the compiler represents itself no value
	 * of which is null — `Int`'s kind, which a platform's own value types share (`cpp.Char`) — a nullable one of those, or an
	 * alias of one. `seen` holds the aliases already read through.
	 */
	private function noObject(t: FactsType, seen: Array<String>): Bool {
		return switch t {
			case Named(NULLABLE, [inner]): noObject(inner, seen);
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

	/** The id of the type `t` when it is one written with no argument, the text a facts type string spells it with; null otherwise. */
	private static function plainId(t: FactsType): Null<String> {
		return switch t {
			case Named(id, []): id;
			case _: null;
		};
	}

}

/** What a native site may do to the question's member (`NativeSiteReach.judge`). */
enum NativeVerdict {

	/** It may reach the member: a blind spot. */
	Blind;

	/**
	 * It may run what the objects it is handed let target code run by a name, and the function values it is handed: the
	 * types of those objects, as source spells them; null for objects of a type no source spells, empty for none.
	 */
	Hands(types: Null<Array<String>>);

}

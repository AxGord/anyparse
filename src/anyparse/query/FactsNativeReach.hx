package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.NativeFact;
import anyparse.query.CompilerFacts.TypeFact;

using Lambda;
using StringTools;

/**
 * What target-language code reaches, read off the compiler's facts, under the stated assumption `FactsEscapes` makes — one
 * for the project and the libraries alike: target code reaches only the values handed to it. Handed are the values a call of
 * it hands it (`NativeFact.handed`: its arguments, its `{0}` placeholders among them, a call's through a chain of names
 * untyped code leaves to the target included) and what its text names (`reach`): a local or parameter by its name — of the
 * function holding the code and of each one it is nested in; the object its method runs on by a spelling of `this`
 * (`THIS_SPELLINGS`) or by the name of a member of it (`memberNames`), which hxcpp reaches unqualified; a static variable by
 * its name beside its class's (`classNamed`), or alone in the code of its class or of one extending it. Every word of the
 * text counts, a string's or a comment's included, the names of such a chain among them, and a name a target mangled
 * (`MANGLED`) stands for the name behind it. Code whose text is computed names what is not known.
 *
 * The code is a native call's (`NativeFact`: `__cpp__`, `Syntax.code`, a native identifier) or a metadata's pasting it
 * into the output (`TypeFact.code`, `FieldDeclFact.code`): around a field's body (`@:functionCode`), in that field's
 * code, or outside any function (`@:cppFileCode`, `@:headerClassCode`, …), where it holds no value of the program's but
 * what it names. Each value reached goes to a reader (`NativeHand`) — the escapes (`FactsEscapes`), or what a native site
 * the member-reach walk meets may do to its member (`NativeSiteReach`) — which answers false when what it holds is not known
 * or is what the reader looks for.
 */
@:nullSafety(Strict)
final class FactsNativeReach {

	/** The names target code spells the object its method runs on by (`reach`), besides a member of it. */
	private static final THIS_SPELLINGS: Array<String> = ['this', '_hx_this', '__this', '__this__', 'self', '_gthis'];

	/** The prefix a target gives a Haxe name it cannot spell as it is (hxcpp's `_hx_new`): the name stands behind it. */
	private static inline final MANGLED: String = '_hx_';

	/** The kinds of a typed type whose statics and constructor code naming it may run (`classesNamed`). */
	private static final CLASS_KINDS: Array<String> = ['class', 'impl'];

	/** What separates a nested function's id from its parent's (`TypedFactsWalk`): `<parent id>@<offset>`. */
	private static inline final NESTED_ID: String = '@';

	/** What separates a further overload's index from its field's node id (`TypedFactsWalk`): `<field id>~<n>`. */
	private static inline final OVERLOAD_ID: String = '~';

	private final _table: CompilerFacts;

	/** Static variable name -> each declaration of one: its class and the types it is given (`reach`); built on first need. */
	private var _statics: Null<Map<String, Array<{ owner: String, types: Array<String> }>>> = null;

	/** Class id -> the names target code in its methods reaches a member of `this` by (`memberNames`), read once per class. */
	private final _members: Map<String, Array<String>> = [];

	/** The typed classes whose code target code may run by naming them (`classesNamed`); listed on first need. */
	private var _classes: Null<Array<String>> = null;

	public function new(table: CompilerFacts) {
		_table = table;
	}

	/** Hand what the target code the node `id` (`n`) holds reaches to `hand`; false when that is not known. */
	public function nodeEscapes(id: String, n: FactNode, hand: NativeHand): Bool {
		if (n.natives.length == 0) return true;
		final self: Null<String> = selfOf(id);
		final locals: Array<{ name: String, type: String }> = localsOf(id);
		for (x in n.natives) if (!handed(x, hand) || !reach(id, n.owner, self, locals, x.code, x.computed, hand)) return false;
		return true;
	}

	/**
	 * Hand what the target code at the native site `x` reaches to `hand`: what a call of it is handed, and what its text names
	 * in the code of the node holding it (`NativeFact.holder`). False when that is not known.
	 */
	public function siteEscapes(x: NativeFact, hand: NativeHand): Bool {
		final home: Null<String> = _table.node(x.holder)?.owner;
		if (home == null) return hand.refuse('the facts of `${x.holder}`, which holds target-language code, are lost');
		return handed(x, hand) && reach(x.holder, home, selfOf(x.holder), localsOf(x.holder), x.code, x.computed, hand);
	}

	/**
	 * Hand what the target code the metadata of the typed type `id` pastes into the output reaches to the escapes: around a
	 * field's body, in the code of that field's nodes, and outside any function. False when that is not known.
	 */
	public function metadataEscapes(id: String, hand: NativeHand): Bool {
		final fact: Null<TypeFact> = _table.type(id);
		if (fact == null) return true;
		for (code in fact.code) if (!reach(id, id, null, [], code, code == null, hand)) return false;
		for (f in fact.fields) if (f.code.length > 0) {
			final base: String = '$id.${f.name}';
			final ids: Array<String> = [base];
			for (count in f.overloads) for (i in 1...count + 1) if (!ids.contains('$base$OVERLOAD_ID$i')) ids.push('$base$OVERLOAD_ID$i');
			for (node in ids) {
				final self: Null<String> = f.isStatic ? null : id;
				final described: Bool = _table.node(node) != null;
				// a body no build typed declares parameters under names no fact keeps: the code may name any of them
				if (!described && !signatureParams(f, hand)) return false;
				final locals: Array<{ name: String, type: String }> = described ? localsOf(node) : [];
				for (code in f.code) if (!reach(node, id, self, locals, code, code == null, hand)) return false;
			}
		}
		return true;
	}

	/**
	 * Hand what target code at `where`, written in the code of the class `home`, reaches to the escapes (see the type doc):
	 * the values `locals` holds that its text names, the object its method runs on (`self`, the class declaring that method;
	 * null when it runs on none) where it names that, and the static variables it names. False when the code's text is
	 * computed (`computed`): what it names is not known.
	 */
	private function reach(
		where: String, home: String, self: Null<String>, locals: Array<{ name: String, type: String }>, code: Null<String>, computed: Bool,
		hand: NativeHand
	): Bool {
		if (computed) return hand.refuse('`$where` holds target-language code whose text is computed');
		if (code == null) return true;
		final names: Array<String> = targetNames(code);
		if (names.length == 0) return true;
		if (self != null) {
			final members: Array<String> = memberNames(self);
			if (names.exists(x -> THIS_SPELLINGS.contains(x) || members.contains(x)) && !hand.escapeType(Named(self, []))) return false;
		}
		for (l in locals) if (names.contains(l.name) && !hand.escape(l.type)) return false;
		final statics: Map<String, Array<{ owner: String, types: Array<String> }>> = staticsByName();
		for (x in names) for (s in statics[x] ?? []) {
			if ((hierarchyOf(home).contains(s.owner) || classNamed(s.owner, names)) && !s.types.foreach(hand.escape)) return false;
		}
		return true;
	}

	/**
	 * The classes of the program's code (`programClass`) target code spelling `words` (`targetNames`) names (`classNamed`):
	 * code that names a class reaches what the class holds globally — its statics, its constructor — as Haxe code naming it
	 * does.
	 */
	public function classesNamed(words: Array<String>): Array<String> {
		if (words.length == 0) return [];
		final listed: Array<String> = _classes ?? [for (id in _table.typeIds()) if (programClass(_table.type(id))) id];
		_classes = listed;
		return [for (id in listed) if (classNamed(id, words)) id];
	}

	/**
	 * Whether the typed type `fact` is a class of the program's code: a class or an abstract's implementation that is no
	 * extern — an extern's members are target code themselves, its `inline` ones spliced where Haxe code calls them.
	 */
	private static function programClass(fact: Null<TypeFact>): Bool {
		return fact != null && CLASS_KINDS.contains(fact.kind) && !fact.isExtern;
	}

	/** Hand the type of each value a call of the native site `x` hands its target code to `hand`. */
	private static function handed(x: NativeFact, hand: NativeHand): Bool {
		return x.handed.foreach(hand.escape);
	}

	/** Hand the type of every parameter of every type a build gave the method `f` to `hand`. */
	private function signatureParams(f: FieldDeclFact, hand: NativeHand): Bool {
		for (t in f.types) switch FactsTypeTree.read(t) {
			case Function(args, _):
				if (!args.foreach(a -> hand.escapeType(a.type))) return false;
			case _:
		}
		return true;
	}

	/**
	 * The class whose instance the code of the node `id` runs on: its outermost enclosing field's, which a nested function
	 * captures, unless that is static. Null for none.
	 */
	private function selfOf(id: String): Null<String> {
		final nested: Int = id.indexOf(NESTED_ID);
		final root: Null<FactNode> = _table.node(nested < 0 ? id : id.substr(0, nested));
		return root == null || root.isStatic ? null : root.owner;
	}

	/** The parameters and locals the code of the node `id` sees: its own, and those of each function it is nested in. */
	private function localsOf(id: String): Array<{ name: String, type: String }> {
		final out: Array<{ name: String, type: String }> = [];
		var current: String = id;
		while (true) {
			final n: Null<FactNode> = _table.node(current);
			if (n != null) {
				for (p in n.params) out.push(p);
				for (v in n.vars) out.push({ name: v.name, type: v.type });
			}
			final cut: Int = current.lastIndexOf(NESTED_ID);
			if (cut < 0) return out;
			current = current.substr(0, cut);
		}
	}

	/**
	 * The names target code in a method of the class `id` reaches a member of `this` by: the variables and methods it and
	 * the classes it extends declare, and every name the target code their metadata pastes into the class names.
	 */
	private function memberNames(id: String): Array<String> {
		final known: Null<Array<String>> = _members[id];
		if (known != null) return known;
		final out: Array<String> = [];
		for (c in hierarchyOf(id)) {
			final fact: Null<TypeFact> = _table.type(c);
			if (fact == null) continue;
			for (f in fact.fields) if (!f.isStatic && !out.contains(f.name)) out.push(f.name);
			for (code in fact.code) if (code != null) for (x in targetNames(code)) if (!out.contains(x)) out.push(x);
		}
		_members[id] = out;
		return out;
	}

	/** The typed class `id` and every class it extends, by their typed ids. */
	private function hierarchyOf(id: String): Array<String> {
		final out: Array<String> = [];
		var current: Null<String> = id;
		while (current != null && !out.contains(current)) {
			final c: String = current;
			out.push(c);
			final sup: Null<String> = _table.type(c)?.superClass;
			current = sup == null ? null : CompilerFacts.baseId(sup);
		}
		return out;
	}

	/** Every static variable the builds typed, by its name (`_statics`). */
	private function staticsByName(): Map<String, Array<{ owner: String, types: Array<String> }>> {
		final held: Null<Map<String, Array<{ owner: String, types: Array<String> }>>> = _statics;
		if (held != null) return held;
		final out: Map<String, Array<{ owner: String, types: Array<String> }>> = [];
		for (id in _table.typeIds()) {
			final fact: Null<TypeFact> = _table.type(id);
			if (fact != null) for (f in fact.fields) if (f.isStatic && f.kinds.exists(k -> k.startsWith('var('))) {
				final list: Array<{ owner: String, types: Array<String> }> = out[f.name] ?? [];
				list.push({ owner: id, types: f.types });
				out[f.name] = list;
			}
		}
		_statics = out;
		return out;
	}

	/**
	 * Whether target code naming `names` names the typed class `id`: a name holding its own (`Main`, hxcpp's `Main_obj`,
	 * js's `pack_Main`).
	 */
	private static function classNamed(id: String, names: Array<String>): Bool {
		final simple: String = id.substr(id.lastIndexOf('.') + 1);
		return names.exists(x -> x.indexOf(simple) >= 0);
	}

	/** The identifiers the target code `code` spells, and the Haxe name behind each one a target mangled (`MANGLED`). */
	public static function targetNames(code: String): Array<String> {
		final out: Array<String> = [];
		var start: Int = -1;
		for (i in 0...code.length + 1) {
			final c: Int = i < code.length ? StringTools.fastCodeAt(code, i) : 0;
			final word: Bool = c == '_'.code || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)
				|| (start >= 0 && c >= '0'.code && c <= '9'.code);
			if (word && start < 0) start = i;
			if (word || start < 0) continue;
			final name: String = code.substring(start, i);
			start = -1;
			if (!out.contains(name)) out.push(name);
			if (name.startsWith(MANGLED) && name.length > MANGLED.length && !out.contains(name.substr(MANGLED.length)))
				out.push(name.substr(MANGLED.length));
		}
		return out;
	}

}

/**
 * What a reader of target code does with what the code reaches (`FactsNativeReach`): each answers false when that is not
 * known, or when what is reached is what the reader looks for.
 */
typedef NativeHand = {

	/** A value of the type a type string spells, and what it holds, is reached. */
	final escape: (String) -> Bool;

	/** A value of a read type, and what it holds, is reached. */
	final escapeType: (FactsType) -> Bool;

	/** What the code reaches is not known, for the reason given. */
	final refuse: (String) -> Bool;
}

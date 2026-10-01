package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.TypeFact;

using Lambda;
using StringTools;

/**
 * What target-language code reaches, read off the compiler's facts for `FactsEscapes`, under its stated assumption — one
 * for the project and the libraries alike: target code reaches only the values handed to it. Handed are its arguments
 * (its `{0}` placeholders), which flow into `Dynamic` and so escape already, and what its text names (`reach`): a local or
 * parameter by its name — of the function holding the code and of each one it is nested in; the object its method runs on
 * by a spelling of `this` (`THIS_SPELLINGS`) or by the name of a member of it (`memberNames`), which hxcpp reaches
 * unqualified; a static variable by its name beside its class's (`classNamed`), or alone in the code of its class or of
 * one extending it. Every word of the text counts, a string's or a comment's included, and a name a target mangled
 * (`MANGLED`) stands for the name behind it. Code whose text is computed names what is not known.
 *
 * The code is a native call's (`NativeFact`: `__cpp__`, `Syntax.code`, a native identifier) or a metadata's pasting it
 * into the output (`TypeFact.code`, `FieldDeclFact.code`): around a field's body (`@:functionCode`), in that field's
 * code, or outside any function (`@:cppFileCode`, `@:headerClassCode`, …), where it holds no value of the program's but
 * what it names. Each value reached goes to the escapes' callbacks, which answer false when what it holds is not known.
 */
@:nullSafety(Strict)
final class FactsNativeReach {

	/** The names target code spells the object its method runs on by (`reach`), besides a member of it. */
	private static final THIS_SPELLINGS: Array<String> = ['this', '_hx_this', '__this', '__this__', 'self', '_gthis'];

	/** The prefix a target gives a Haxe name it cannot spell as it is (hxcpp's `_hx_new`): the name stands behind it. */
	private static inline final MANGLED: String = '_hx_';

	/** What separates a nested function's id from its parent's (`TypedFactsWalk`): `<parent id>@<offset>`. */
	private static inline final NESTED_ID: String = '@';

	/** What separates a further overload's index from its field's node id (`TypedFactsWalk`): `<field id>~<n>`. */
	private static inline final OVERLOAD_ID: String = '~';

	private final _table: CompilerFacts;

	/** Record the type a type string spells, and what a value of it holds, as escaped; false when that is not known. */
	private final _escape: (String) -> Bool;

	/** Record a read type, and what a value of it holds, as escaped; false when that is not known. */
	private final _escapeType: (FactsType) -> Bool;

	/** Record why the escapes are not known: false, for the caller to answer. */
	private final _refuse: (String) -> Bool;

	/** Static variable name -> each declaration of one: its class and the types it is given (`reach`); built on first need. */
	private var _statics: Null<Map<String, Array<{ owner: String, types: Array<String> }>>> = null;

	/** Class id -> the names target code in its methods reaches a member of `this` by (`memberNames`), read once per class. */
	private final _members: Map<String, Array<String>> = [];

	public function new(
		table: CompilerFacts, escape: (String) -> Bool, escapeType: (FactsType) -> Bool, refuse: (String) -> Bool
	) {
		_table = table;
		_escape = escape;
		_escapeType = escapeType;
		_refuse = refuse;
	}

	/** Hand what the target code the node `id` (`n`) holds reaches to the escapes; false when that is not known. */
	public function nodeEscapes(id: String, n: FactNode): Bool {
		if (n.natives.length == 0) return true;
		final self: Null<String> = selfOf(id);
		final locals: Array<{ name: String, type: String }> = localsOf(id);
		for (x in n.natives) if (!reach(id, n.owner, self, locals, x.code, x.computed)) return false;
		return true;
	}

	/**
	 * Hand what the target code the metadata of the typed type `id` pastes into the output reaches to the escapes: around a
	 * field's body, in the code of that field's nodes, and outside any function. False when that is not known.
	 */
	public function metadataEscapes(id: String): Bool {
		final fact: Null<TypeFact> = _table.type(id);
		if (fact == null) return true;
		for (code in fact.code) if (!reach(id, id, null, [], code, code == null)) return false;
		for (f in fact.fields) if (f.code.length > 0) {
			final base: String = '$id.${f.name}';
			final ids: Array<String> = [base];
			for (count in f.overloads) for (i in 1...count + 1) if (!ids.contains('$base$OVERLOAD_ID$i')) ids.push('$base$OVERLOAD_ID$i');
			for (node in ids) {
				final self: Null<String> = f.isStatic ? null : id;
				final described: Bool = _table.node(node) != null;
				// a body no build typed declares parameters under names no fact keeps: the code may name any of them
				if (!described && !signatureParams(f)) return false;
				final locals: Array<{ name: String, type: String }> = described ? localsOf(node) : [];
				for (code in f.code) if (!reach(node, id, self, locals, code, code == null)) return false;
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
		where: String, home: String, self: Null<String>, locals: Array<{ name: String, type: String }>, code: Null<String>, computed: Bool
	): Bool {
		if (computed) return _refuse('`$where` holds target-language code whose text is computed');
		if (code == null) return true;
		final names: Array<String> = targetNames(code);
		if (names.length == 0) return true;
		if (self != null) {
			final members: Array<String> = memberNames(self);
			if (names.exists(x -> THIS_SPELLINGS.contains(x) || members.contains(x)) && !_escapeType(Named(self, []))) return false;
		}
		for (l in locals) if (names.contains(l.name) && !_escape(l.type)) return false;
		final statics: Map<String, Array<{ owner: String, types: Array<String> }>> = staticsByName();
		for (x in names) for (s in statics[x] ?? []) {
			if ((hierarchyOf(home).contains(s.owner) || classNamed(s.owner, names)) && !s.types.foreach(_escape)) return false;
		}
		return true;
	}

	/** Hand the type of every parameter of every type a build gave the method `f` to the escapes. */
	private function signatureParams(f: FieldDeclFact): Bool {
		for (t in f.types) switch FactsTypeTree.read(t) {
			case Function(args, _):
				if (!args.foreach(a -> _escapeType(a.type))) return false;
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
	private static function targetNames(code: String): Array<String> {
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

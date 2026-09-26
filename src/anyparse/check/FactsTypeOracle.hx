package anyparse.check;

import anyparse.check.Check.OracleType;
import anyparse.check.Check.TypeOracle;
import anyparse.check.FactsTypeSpelling.TypeScope;
import anyparse.query.CompilerFacts;
import anyparse.query.TextMap;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * A `TypeOracle` over the compiler's typed facts (`CompilerFacts`): the type every oracle configuration gave a
 * declaration when it typed the code, read off the table the run already compiled — a local's `VarFact`, a function
 * node's parameters and signature, a type's declared field, the typed sites at an expression.
 *
 * It answers only a type every configuration that compiled the declaration AGREES on: two configurations naming two
 * types (`Null<X>` in one, `X` in another) decline, because one annotation would be wrong in the other build. It also
 * declines a type no source can write: an unknown (an unbound monomorph, or nesting past the facts' depth bound), a type
 * parameter of a declaration the site is not inside, and an abstract's statics or implementation class — and a local or
 * a return a `Dynamic` value flows into, whose type the compiler inferred from its uses. The type is then spelled as Haxe
 * source (`FactsTypeSpelling`), still fully qualified, for the check's own normaliser.
 *
 * Code no configuration compiled has no facts and declines. A file the run REWROTE after the compile is read at the text
 * the compile read and mapped onto the file as it is now (`TextMap`); a declaration whose own text changed declines, and
 * only a file whose compiled text is gone altogether goes to `fallback`, an oracle that reads the tree as it is now.
 */
@:nullSafety(Strict)
final class FactsTypeOracle implements TypeOracle {

	public static inline final DECLINE_FILE_NOT_COMPILED: String = 'no oracle configuration compiles this file';

	public static inline final DECLINE_CODE_NOT_COMPILED: String =
		'no oracle configuration compiles this code — a conditional branch every build leaves out';

	public static inline final DECLINE_REWRITTEN: String =
		'the run rewrote this file after the compiler typed it, so no fact names its text';

	public static inline final DECLINE_UNKNOWN: String = 'the compiler left its type unknown (an unbound monomorph)';

	public static inline final DECLINE_NO_FACT: String = 'the compiler recorded no type for it';

	public static inline final DECLINE_UNSPELLABLE: String =
		"its type is an abstract's statics or implementation class, which no source can spell";

	public static inline final DECLINE_PARAM_MISMATCH: String = "the compiler's parameter list does not match the declaration's";

	/** The node kinds that are a member function's own body (`TypedFactsProbe`). */
	private static final MEMBER_FUNCTION_KINDS: Array<String> = ['method', 'ctor'];

	public static inline final DECLINE_DYNAMIC_SOURCE: String =
		'a `Dynamic` value flows into it, so the type the compiler gave it was inferred from its uses, not from the value';

	public static inline final DECLINE_DECLARATION_REWRITTEN: String =
		"the run rewrote the declaration's own text after the compiler typed it, so no fact names it";

	private final _facts: CompilerFacts;
	private final _current: (String) -> Null<String>;
	private final _fallback: Null<() -> Null<TypeOracle>>;

	/** Table key -> where the facts of that file are read, settled on first need. */
	private final _sites: Map<String, Null<FactsSite>> = [];

	/** `_facts` read as the compile read each file (`CompilerFacts.asCompiled`), built on first need. */
	private var _asCompiled: Null<CompilerFacts> = null;

	/**
	 * The oracle over `facts`, reading a file's text as it is now through `current`. `fallback` answers for a file whose
	 * text changed since the compile when the facts cannot place it.
	 */
	public function new(facts: CompilerFacts, current: (String) -> Null<String>, ?fallback: () -> Null<TypeOracle>) {
		_facts = facts;
		_current = current;
		_fallback = fallback;
	}

	public function localType(file: String, decl: Span, name: String, nameEnd: Int): OracleType {
		return resolve(file, decl, o -> o.localType(file, decl, name, nameEnd), (site, at) -> {
			final nodes: Array<FactNode> = site.facts.nodesAround(site.file, at);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			final types: Array<String> = [];
			for (n in nodes)
				for (v in n.vars)
					if (v.name == name && v.at.file == site.key && within(v.at.span, at) && !types.contains(v.type)) types.push(v.type);
			// a `Dynamic` initializer binds nothing: the type was inferred from the local's uses, not from its value
			for (n in nodes)
				for (f in n.flows)
					if (f.via == 'var' && f.at.file == site.key && within(f.at.span, at) && dynamicSource(f.from))
						return Declined(DECLINE_DYNAMIC_SOURCE);
			return agreed(types, scopeOf(nodes[nodes.length - 1]), DECLINE_CODE_NOT_COMPILED);
		});
	}

	public function returnType(file: String, fn: Span, name: String, nameEnd: Int): OracleType {
		return resolve(file, fn, o -> o.returnType(file, fn, name, nameEnd), (site, at) -> {
			final nodes: Array<FactNode> = memberFunctions(site, at, name);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			final types: Array<String> = [];
			for (n in nodes) for (f in n.flows) if (f.via == 'ret' && dynamicSource(f.from)) return Declined(DECLINE_DYNAMIC_SOURCE);
			for (n in nodes) for (v in n.variants) {
				final result: Null<String> = resultOf(v.signature);
				if (result == null) return Declined(DECLINE_NO_FACT);
				if (!types.contains(result)) types.push(result);
			}
			return agreed(types, scopeOf(nodes[0]), DECLINE_NO_FACT);
		});
	}

	public function paramType(file: String, fn: Span, name: String, index: Int, param: String, nameEnd: Int): OracleType {
		return resolve(file, fn, o -> o.paramType(file, fn, name, index, param, nameEnd), (site, at) -> {
			final nodes: Array<FactNode> = memberFunctions(site, at, name);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			final types: Array<String> = [];
			for (n in nodes) for (v in n.variants) {
				if (index >= v.params.length || v.params[index].name != param) return Declined(DECLINE_PARAM_MISMATCH);
				if (!types.contains(v.params[index].type)) types.push(v.params[index].type);
			}
			return agreed(types, scopeOf(nodes[0]), DECLINE_NO_FACT);
		});
	}

	public function fieldType(file: String, field: Span, name: String, nameEnd: Int): OracleType {
		return resolve(file, field, o -> o.fieldType(file, field, name, nameEnd), (site, at) -> {
			var owner: Null<{ id: String, span: Span }> = null;
			for (t in typesIn(site)) if (within(at, t.span)) {
				final best: Null<{ id: String, span: Span }> = owner;
				if (best == null || within(t.span, best.span)) owner = t;
			}
			if (owner == null) return Declined(DECLINE_CODE_NOT_COMPILED);
			final types: Array<String> = site.facts.type(owner.id)?.fields.find(f -> f.name == name)?.types ?? [];
			return agreed(types, { owner: owner.id, method: null }, DECLINE_NO_FACT);
		});
	}

	public function expressionType(file: String, expr: Span): OracleType {
		return resolve(file, expr, o -> o.expressionType(file, expr), (site, at) -> {
			final nodes: Array<FactNode> = site.facts.nodesAround(site.file, at);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			final typed: Null<String> = site.facts.typeOfExpressionAt(site.file, at);
			final types: Array<String> = typed == null ? [] : [typed];
			// a value handed to a place of another type flows there at its own type: the facts' only record of many a value
			for (f in site.facts.flowsIn(site.file, at) ?? []) if (
				f.at.file == site.key && f.at.span.from == at.from && f.at.span.to == at.to && !types.contains(f.from)
			)
				types.push(f.from);
			return agreed(types, scopeOf(nodes[nodes.length - 1]), DECLINE_NO_FACT);
		});
	}

	/**
	 * The result half of a facts function type — `(Int,String)->Bool` yields `Bool` — or null for any other shape. Only
	 * parentheses are counted: neither a structure nor a type argument list can hold an unbalanced one.
	 */
	public static function resultOf(signature: String): Null<String> {
		if (!signature.startsWith('(')) return null;
		var depth: Int = 0;
		for (i in 0...signature.length) {
			final c: Int = signature.fastCodeAt(i);
			if (c == '('.code)
				depth++;
			else if (c == ')'.code && --depth == 0)
				return signature.substr(i + 1, 2) == '->' ? signature.substr(i + 3) : null;
		}
		return null;
	}

	/**
	 * `query` asked of where the facts of `file` are read, with `span` placed in the text they describe; `Declined` when the
	 * file has none, or when `span` lies in text the run rewrote since the compile. A file whose facts cannot be placed at
	 * all is asked of the fallback oracle through `ask`, when there is one.
	 */
	private function resolve(
		file: String, span: Span, ask: (TypeOracle) -> OracleType, query: (FactsSite, Span) -> OracleType
	): OracleType {
		if (!_facts.compiled(file)) return Declined(DECLINE_FILE_NOT_COMPILED);
		final site: Null<FactsSite> = siteOf(file);
		if (site == null) {
			final fallback: Null<() -> Null<TypeOracle>> = _fallback;
			final other: Null<TypeOracle> = fallback == null ? null : fallback();
			return other == null ? Declined(DECLINE_REWRITTEN) : ask(other);
		}
		final map: Null<TextMap> = site.map;
		if (map == null) return query(site, span);
		final from: Int = map.toBefore(span.from);
		final to: Int = map.toBefore(span.to);
		return from < 0 || to < from ? Declined(DECLINE_DECLARATION_REWRITTEN) : query(site, new Span(from, to));
	}

	/**
	 * Where the facts of `file` are read: the table itself when the text it describes is still at hand — mapped onto the
	 * file as it is now when the run changed it since — else the table as the compile read it (`asCompiled`), which a file
	 * the run rewrote answers at its original text; null when neither holds the text the compile read.
	 */
	private function siteOf(file: String): Null<FactsSite> {
		final key: String = _facts.keyOf(file);
		if (_sites.exists(key)) return _sites[key];
		final current: Null<String> = _current(file);
		var table: CompilerFacts = _facts;
		var text: Null<String> = _facts.sourceOf(key);
		if (text == null) {
			final compiled: CompilerFacts = _asCompiled ?? _facts.asCompiled();
			_asCompiled = compiled;
			table = compiled;
			text = compiled.sourceOf(key);
		}
		final site: Null<FactsSite> = text == null || current == null ? null : {
			facts: table,
			file: file,
			key: key,
			map: text == current ? null : TextMap.between(text, current),
			types: null
		};
		_sites[key] = site;
		return site;
	}

	/** Whether a value of the facts type `from` is `Dynamic` or holds it: assigning it binds no monomorph. */
	private static function dynamicSource(from: String): Bool {
		return from == 'Dynamic' || from.startsWith('Dynamic<') || from.startsWith('Null<Dynamic');
	}

	/** The one type all of `types` agree on, spelled; `none` when there is none, a decline naming them when several. */
	private static function agreed(types: Array<String>, scope: TypeScope, none: String): OracleType {
		if (types.length == 0) return Declined(none);
		if (types.length > 1) return Declined('the oracle configurations type it differently: ${types.join(' / ')}');
		return FactsTypeSpelling.spell(types[0], scope);
	}

	/**
	 * The typed bodies of the member function `name` inside `fn` of `file`: nested functions, inlined copies and macro-
	 * placed bodies are not the member's own. A `@:generic` class's per-argument copies are, and a type they disagree on
	 * declines.
	 */
	private function memberFunctions(site: FactsSite, fn: Span, name: String): Array<FactNode> {
		return [
			for (n in site.facts.nodesAround(site.file, fn, true))
				if (
					MEMBER_FUNCTION_KINDS.contains(n.kind) && !n.generated && n.inlinedFrom == null && within(n.at.span, fn)
					&& memberOf(n) == name
				)
					n
		];
	}

	/**
	 * The id and range of every type of `file` that owns a typed node there — a type whose members hold no code the
	 * compiler typed has no facts to agree on anyway. Read off the file's nodes rather than the type table, whose every
	 * position would read its own file.
	 */
	private static function typesIn(site: FactsSite): Array<{ id: String, span: Span }> {
		final held: Null<Array<{ id: String, span: Span }>> = site.types;
		if (held != null) return held;
		final out: Array<{ id: String, span: Span }> = [];
		for (n in site.facts.nodesIn(site.file)) if (!out.exists(t -> t.id == n.owner)) {
			final pos: Null<FactPos> = site.facts.typePosition(n.owner);
			if (pos != null && pos.file == site.key) out.push({ id: n.owner, span: pos.span });
		}
		site.types = out;
		return out;
	}

	/** The type parameters in scope inside the node `n`: its owner type's and its member's. */
	private static function scopeOf(n: FactNode): TypeScope {
		return { owner: n.owner, method: memberOf(n) };
	}

	/** The member a node belongs to: its id past the owner, before a nested function's offset or an overload's index. */
	private static function memberOf(n: FactNode): Null<String> {
		if (!n.id.startsWith(n.owner + '.')) return null;
		var member: String = n.id.substr(n.owner.length + 1);
		for (mark in ['@', '~', '#']) {
			final cut: Int = member.indexOf(mark);
			if (cut >= 0) member = member.substr(0, cut);
		}
		return member;
	}

	/** Whether `inner` lies within `outer`. */
	private static inline function within(inner: Span, outer: Span): Bool {
		return outer.from <= inner.from && inner.to <= outer.to;
	}

}

/** Where one file's facts are read: the table, the file and its key there, the map from its text now to the one they describe. */
private typedef FactsSite = {
	final facts: CompilerFacts;
	final file: String;
	final key: String;

	/** From the file's text now to the text `facts` describe; null when the two are the same. */
	final map: Null<TextMap>;

	/** The types `typesIn` read, once it has. */
	var types: Null<Array<{ id: String, span: Span }>>;
}

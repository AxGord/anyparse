package anyparse.check;

import anyparse.check.Check.OracleType;
import anyparse.check.Check.TypeOracle;
import anyparse.check.FactsTypeSpelling.TypeScope;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CompilerFacts;
import anyparse.query.EditJournal;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndexHost;
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
 * the compile read, and a declaration is placed there only through the edits the run recorded applying (`EditJournal`)
 * and only when the whole member holding it is text no edit touched: what the compiler inferred rests on all of it, so a
 * member an edit rewrote, reordered or moved declines, and so does every declaration of a file whose history was not
 * recorded. Only a file whose compiled text is gone altogether goes to `fallback`, an oracle reading the tree as it is now.
 *
 * Independently of how a declaration was placed, the member and the type holding it in the facts must be the ones
 * holding it in the file as it is now (`DECLINE_ELSEWHERE`).
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

	/** The nullable wrapper's own name: never the type of a value `typeIdAt` names. */
	private static inline final NULL_TYPE: String = 'Null';

	/** The suffix of an abstract's implementation class: its members are the abstract's. */
	private static inline final IMPL_SUFFIX: String = '_Impl_';

	/** The node kinds that are a member function's own body (`TypedFactsProbe`). */
	private static final MEMBER_FUNCTION_KINDS: Array<String> = ['method', 'ctor'];

	public static inline final DECLINE_DYNAMIC_SOURCE: String =
		'a `Dynamic` value flows into it, so the type the compiler gave it was inferred from its uses, not from the value';

	public static inline final DECLINE_SHIFTED: String =
		'it sits in a string after an escape sequence, where the compiler shifts the ranges of the interpolated code';

	public static inline final DECLINE_ELSEWHERE: String =
		'the facts place this code in another member or type than the file as it is now does';

	/** The kinds the facts give a type no operator overload can be declared on (`CompilerFacts.TypeFact`). */
	private static final PLAIN_KINDS: Array<String> = ['class', 'interface', 'enum'];

	/** The table this oracle reads. */
	public final facts: CompilerFacts;

	private final _current: (String) -> Null<String>;
	private final _journal: Null<EditJournal>;
	private final _plugin: GrammarPlugin;
	private final _fallback: Null<() -> Null<TypeOracle>>;

	/** Table key -> where the facts of that file are read, settled on first need. */
	private final _sites: Map<String, Null<FactsSite>> = [];

	/** `facts` read as the compile read each file (`CompilerFacts.asCompiled`), built on first need. */
	private var _asCompiled: Null<CompilerFacts> = null;

	/**
	 * The oracle over `facts`, reading a file's text as it is now through `current` and parsing it with `plugin`. `journal`
	 * holds the edits the run applied since the compile, null when it recorded none. `fallback` answers for a file whose
	 * compiled text is gone.
	 */
	public function new(
		facts: CompilerFacts, current: (String) -> Null<String>, journal: Null<EditJournal>, plugin: GrammarPlugin,
		?fallback: () -> Null<TypeOracle>
	) {
		this.facts = facts;
		_current = current;
		_journal = journal;
		_plugin = plugin;
		_fallback = fallback;
	}

	/**
	 * The compiler facts of the run `plugin` serves (`SymbolIndexHost.compilerFacts`), when every configuration contributed
	 * to them: a configuration missing from the table could type a declaration differently, and agreement is what a facts
	 * answer rests on. Null otherwise, or when the run reads none.
	 */
	public static function runFacts(plugin: GrammarPlugin): Null<CompilerFacts> {
		final facts: Null<CompilerFacts> = plugin is SymbolIndexHost ? (cast plugin: SymbolIndexHost).compilerFacts() : null;
		return facts == null || facts.dropped.length > 0 || facts.configurations.length == 0 ? null : facts;
	}

	/**
	 * The oracle a `Check.fix` of `file`, whose text is `source` now, asks over the run's facts (`runFacts`), placing a
	 * rewritten file through the run's edit journal; null when the run has no such facts. It has no fallback: a file whose
	 * compiled text is gone declines.
	 */
	public static function forFix(plugin: GrammarPlugin, file: String, source: String): Null<FactsTypeOracle> {
		final facts: Null<CompilerFacts> = runFacts(plugin);
		if (facts == null) return null;
		final journal: Null<EditJournal> = plugin is CachingGrammarPlugin ? (cast plugin: CachingGrammarPlugin).editJournal : null;
		return new FactsTypeOracle(facts, f -> f == file ? source : null, journal, plugin);
	}

	/**
	 * The id of the type every configuration gave the expression at `expr` (`valueType`) — a `Null<…>` unwrapped when
	 * `unwrapNull` (`FactsTypeText.unwrapNull`), type arguments dropped — when it names a type the facts hold; null
	 * otherwise: a declined answer, a type parameter, a function or structure type, or a `Null<…>` kept.
	 */
	public function typeIdAt(file: String, expr: Span, unwrapNull: Bool): Null<String> {
		final spelled: String = switch valueType(file, expr) {
			case Typed(type): type;
			case Declined(_): return null;
		};
		final id: String = CompilerFacts.baseId(unwrapNull ? FactsTypeText.unwrapNull(spelled) : spelled);
		return id == NULL_TYPE || facts.type(id) == null ? null : id;
	}

	public function localType(file: String, decl: Span, name: String, nameEnd: Int): OracleType {
		return resolve(file, decl, nameOf(name, nameEnd), o -> o.localType(file, decl, name, nameEnd), (site, at, here) -> {
			final nodes: Array<FactNode> = site.facts.nodesAround(site.file, at);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			if (!sameHome(site, nodes[nodes.length - 1], here)) return Declined(DECLINE_ELSEWHERE);
			final types: Array<String> = [];
			for (n in nodes)
				for (v in n.vars)
					if (v.name == name && v.at.file == site.key && within(at, v.at.span) && !types.contains(v.type)) types.push(v.type);
			// a `Dynamic` initializer binds nothing: the type was inferred from the local's uses, not from its value
			for (n in nodes)
				for (f in n.flows)
					if (f.via == 'var' && f.at.file == site.key && within(at, f.at.span) && dynamicSource(f.from))
						return Declined(DECLINE_DYNAMIC_SOURCE);
			return agreed(types, scopeOf(nodes[nodes.length - 1]), DECLINE_CODE_NOT_COMPILED);
		});
	}

	public function returnType(file: String, fn: Span, name: String, nameEnd: Int): OracleType {
		return resolve(file, fn, nameOf(name, nameEnd), o -> o.returnType(file, fn, name, nameEnd), (site, at, here) -> {
			final nodes: Array<FactNode> = memberFunctions(site, at, name);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			if (!nodes.foreach(n -> sameHome(site, n, here))) return Declined(DECLINE_ELSEWHERE);
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
		return resolve(file, fn, nameOf(param, nameEnd), o -> o.paramType(file, fn, name, index, param, nameEnd), (site, at, here) -> {
			final nodes: Array<FactNode> = memberFunctions(site, at, name);
			if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
			if (!nodes.foreach(n -> sameHome(site, n, here))) return Declined(DECLINE_ELSEWHERE);
			final types: Array<String> = [];
			for (n in nodes) for (v in n.variants) {
				if (index >= v.params.length || v.params[index].name != param) return Declined(DECLINE_PARAM_MISMATCH);
				if (!types.contains(v.params[index].type)) types.push(v.params[index].type);
			}
			return agreed(types, scopeOf(nodes[0]), DECLINE_NO_FACT);
		});
	}

	public function fieldType(file: String, field: Span, name: String, nameEnd: Int): OracleType {
		return resolve(file, field, nameOf(name, nameEnd), o -> o.fieldType(file, field, name, nameEnd), (site, at, here) -> {
			var owner: Null<{ id: String, span: Span }> = null;
			for (t in typesIn(site)) if (within(at, t.span)) {
				final best: Null<{ id: String, span: Span }> = owner;
				if (best == null || within(t.span, best.span)) owner = t;
			}
			if (owner == null) return Declined(DECLINE_CODE_NOT_COMPILED);
			if (here.member != name || !sameType(site, owner.id, here)) return Declined(DECLINE_ELSEWHERE);
			final types: Array<String> = site.facts.type(owner.id)?.fields.find(f -> f.name == name)?.types ?? [];
			return agreed(types, { owner: owner.id, method: null }, DECLINE_NO_FACT);
		});
	}

	public function expressionType(file: String, expr: Span): OracleType {
		return resolve(file, expr, expr, o -> o.expressionType(file, expr), typedAt.bind(true));
	}

	/**
	 * The simple name of the type every configuration gave the expression at `expr` of `source` — or at the parentheses
	 * directly around it, where the compiler records an operand it typed — when that type is a built-in scalar of the
	 * grammar or one no operator overload can be declared on (`PLAIN_KINDS`); null otherwise. A caller judging operators by
	 * SIMPLE name may meet another declaration of it, so an abstract is never named, whatever the name resolves to there.
	 */
	public function nonOverloadingName(file: String, source: String, expr: Null<Span>): Null<String> {
		if (expr == null) return null;
		final paren: Null<Span> = parenthesized(source, expr);
		final id: Null<String> = typeIdAt(file, expr, true) ?? (paren == null ? null : typeIdAt(file, paren, true));
		final declared: Null<TypeFact> = id == null ? null : facts.type(id);
		final shape: RefShape = _plugin.refShape();
		final builtins: Array<String> = [for (name in shape.literalTypeNames ?? []) name].concat(shape.nonNullableTypeNames ?? []);
		return id != null && (builtins.contains(id) || (declared != null && declared.alike && PLAIN_KINDS.contains(declared.kind)))
			? id.substr(id.lastIndexOf('.') + 1)
			: null;
	}

	/** The span of the parentheses directly around `at` in `source`, or null. */
	private static function parenthesized(source: String, at: Span): Null<Span> {
		var from: Int = at.from - 1;
		while (from >= 0 && source.isSpace(from)) from--;
		var to: Int = at.to;
		while (to < source.length && source.isSpace(to)) to++;
		return from >= 0 && to < source.length && source.fastCodeAt(from) == '('.code && source.fastCodeAt(to) == ')'.code
			? new Span(from, to + 1)
			: null;
	}

	/**
	 * The type the compiler gave the expression at `expr` ITSELF: what `expressionType` answers without the flows. A flow's
	 * source type is the value's before a conversion at that range, which a check-type `(e : T)` records at its own range:
	 * the type of the inner value, not of the expression.
	 */
	public function valueType(file: String, expr: Span): OracleType {
		return resolve(file, expr, expr, o -> o.expressionType(file, expr), typedAt.bind(false));
	}

	/**
	 * The type the facts of `site` give the expression at `at`, held in the member and type `here` — with `flows`, also
	 * the type a value flowing from that very range had (`expressionType`), else only the expression's own (`valueType`).
	 */
	private function typedAt(flows: Bool, site: FactsSite, at: Span, here: Home): OracleType {
		final nodes: Array<FactNode> = site.facts.nodesAround(site.file, at);
		if (nodes.length == 0) return Declined(DECLINE_CODE_NOT_COMPILED);
		if (escapedBefore(site, at)) return Declined(DECLINE_SHIFTED);
		if (!sameHome(site, nodes[nodes.length - 1], here)) return Declined(DECLINE_ELSEWHERE);
		final typed: Null<String> = site.facts.typeOfExpressionAt(site.file, at);
		final types: Array<String> = typed == null ? [] : [typed];
		// a value handed to a place of another type flows there at its own type: the facts' only record of many a value
		if (flows)
			for (f in site.facts.flowsIn(site.file, at) ?? [])
				if (f.at.file == site.key && f.at.span.from == at.from && f.at.span.to == at.to && !types.contains(f.from))
					types.push(f.from);
		return agreed(types, scopeOf(nodes[nodes.length - 1]), DECLINE_NO_FACT);
	}

	/**
	 * Whether `at` lies inside a string literal of the text `site` describes after an escape sequence of it: the compiler
	 * places the code of an interpolation hole there at a range shifted by the escapes before it, where it can name
	 * another expression exactly.
	 */
	private function escapedBefore(site: FactsSite, at: Span): Bool {
		final regions: Array<LexRegion> = site.regions ?? _plugin.lexicalRegions(site.text);
		site.regions = regions;
		final literal: Null<LexRegion> = LexicalRegions.regionAt(at.from, regions);
		return literal != null && literal.kind == StringLit && site.text.substring(literal.from, at.from).indexOf('\\') >= 0;
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
	 * `query` asked of where the facts of `file` are read, with `key` — the declaration's name token, or the expression —
	 * placed in the text they describe, and the member and type holding `span` now; `Declined` when the file has none, or
	 * when `key` lies in text the run rewrote since the compile. A file whose facts cannot be placed at all is asked of the
	 * fallback oracle through `ask`, when there is one.
	 */
	private function resolve(
		file: String, span: Span, key: Span, ask: (TypeOracle) -> OracleType, query: (FactsSite, Span, Home) -> OracleType
	): OracleType {
		if (!facts.compiled(file)) return Declined(DECLINE_FILE_NOT_COMPILED);
		final site: Null<FactsSite> = siteOf(file);
		if (site == null) {
			final fallback: Null<() -> Null<TypeOracle>> = _fallback;
			final other: Null<TypeOracle> = fallback == null ? null : fallback();
			return other == null ? Declined(DECLINE_REWRITTEN) : ask(other);
		}
		final here: Home = homeOf(site, span);
		if (site.text == site.current) return query(site, key, here);
		final journal: Null<EditJournal> = _journal;
		final member: Null<Span> = here.span;
		if (journal == null) return Declined(EditJournal.UNMAPPED_NO_HISTORY);
		if (member == null) return Declined(DECLINE_ELSEWHERE);
		// the WHOLE member is placed, not the declaration alone: what the compiler inferred there rests on all of its text
		return switch journal.back(site.text, site.current, member) {
			case Mapped(at) if (site.text.substring(at.from, at.to) == site.current.substring(member.from, member.to)):
				query(site, new Span(key.from + at.from - member.from, key.to + at.from - member.from), here);
			case Mapped(_): Declined(EditJournal.UNMAPPED_REWRITTEN);
			case Unmapped(reason): Declined(reason);
		};
	}

	/** The token of `name` ending at `nameEnd`. */
	private static inline function nameOf(name: String, nameEnd: Int): Span {
		return new Span(nameEnd - name.length, nameEnd);
	}

	/** The member and the type holding `span` in the file of `site` as it is now; null names where it lies in none. */
	private function homeOf(site: FactsSite, span: Span): Home {
		final shape: RefShape = _plugin.refShape();
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final types: Array<String> = shape.typeDeclKinds ?? [];
		var member: Null<String> = null;
		var memberSpan: Null<Span> = null;
		var type: Null<String> = null;
		function walk(node: QueryNode): Void {
			final at: Null<Span> = node.span;
			if (at != null && !(at.from <= span.from && span.to <= at.to)) return;
			if (at != null && members.contains(node.kind)) {
				member = node.name;
				memberSpan = at;
			}
			if (at != null && types.contains(node.kind)) {
				// a modified declaration (`final class`) wraps the named form it modifies
				type = node.name ?? node.children.find(c -> c.name != null)?.name;
				member = null;
				memberSpan = null;
			}
			for (c in node.children) walk(c);
		}
		final tree: Null<QueryNode> = try _plugin.parseFile(site.current) catch (exception: haxe.Exception) null;
		if (tree != null) walk(tree);
		return { member: member, type: type, span: memberSpan };
	}

	/**
	 * Whether the node `n` belongs to the member and the type `here` names: its member by `memberOf`, its owner by its simple
	 * name, an abstract's implementation class as the abstract and a `@:generic` copy as its generic class.
	 */
	private function sameHome(site: FactsSite, n: FactNode, here: Home): Bool {
		final member: Null<String> = here.member;
		return member != null && memberOf(n) == member && sameType(site, n.owner, here);
	}

	/** Whether the typed type `owner` is the type `here` names (see `sameHome`). */
	private static function sameType(site: FactsSite, owner: String, here: Home): Bool {
		final generic: Null<String> = site.facts.type(owner)?.genericOf;
		var id: String = generic == null ? owner : CompilerFacts.baseId(generic);
		id = id.substr(id.lastIndexOf('.') + 1);
		if (id.endsWith(IMPL_SUFFIX)) id = id.substr(0, id.length - IMPL_SUFFIX.length);
		return here.type != null && id == here.type;
	}

	/**
	 * Where the facts of `file` are read: the table itself when the text it describes is still at hand — mapped onto the
	 * file as it is now when the run changed it since — else the table as the compile read it (`asCompiled`), which a file
	 * the run rewrote answers at its original text; null when neither holds the text the compile read.
	 */
	private function siteOf(file: String): Null<FactsSite> {
		final key: String = facts.keyOf(file);
		if (_sites.exists(key)) return _sites[key];
		final current: Null<String> = _current(file);
		var table: CompilerFacts = facts;
		var text: Null<String> = facts.sourceOf(key);
		if (text == null) {
			final compiled: CompilerFacts = _asCompiled ?? facts.asCompiled();
			_asCompiled = compiled;
			table = compiled;
			text = compiled.sourceOf(key);
		}
		final site: Null<FactsSite> = text == null || current == null ? null : {
			facts: table,
			file: file,
			key: key,
			text: text,
			current: current,
			types: null,
			regions: null
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
	 * The typed bodies of the member function `name` of the type holding `at` (its name token, or one of its parameters'):
	 * nested functions, inlined copies and macro-placed bodies are not the member's own.
	 */
	private function memberFunctions(site: FactsSite, at: Span, name: String): Array<FactNode> {
		final owners: Array<String> = [for (t in typesIn(site)) if (within(at, t.span)) t.id];
		return [
			for (n in site.facts.nodesIn(site.file))
				if (
					MEMBER_FUNCTION_KINDS.contains(n.kind) && !n.generated && n.inlinedFrom == null && owners.contains(n.owner)
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

	/** The text `facts` describe. */
	final text: String;

	/** The file's text now. */
	final current: String;

	/** The types `typesIn` read, once it has. */
	var types: Null<Array<{ id: String, span: Span }>>;

	/** The lexical regions of `text`, once `escapedBefore` read them. */
	var regions: Null<Array<LexRegion>>;
}

/** The member and the type holding a span of a file as it is now, and the member's own span; null where it lies in none. */
private typedef Home = {
	final member: Null<String>;
	final type: Null<String>;
	final span: Null<Span>;
}

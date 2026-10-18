package anyparse.check;

import anyparse.check.ArgumentTypes.WrittenType;
import anyparse.query.ArgumentSlots;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphTypes.HeldFile;
import anyparse.query.GrammarPlugin;
import anyparse.query.Lit;
import anyparse.query.NodeShape;
import anyparse.query.QueryNode;
import anyparse.query.ShapeVocab;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.runtime.Span;

using Lambda;

/**
 * What a call hands the parameters of the function it calls, as far as `EdgeConditions` reads them: the TRACKED
 * parameters of a function, and the VALUATION a call gives them — one character per tracked parameter, standing for the
 * set of values it may hold there (`atomsOf`): `UNKNOWN`, `TRUE` / `FALSE`, `NULL`, `NON_NULL`, a string a guard of the
 * callee tests (`stringTested`), or several of these.
 *
 * A positive whitelist:
 * - A parameter is TRACKED when nothing in the body writes or shadows its name (no assignment, no increment, no other
 *   declaration of it, nested functions included) and the body reads it bare — as a condition, compared with `null`,
 *   tested by a string affix guard (`stringPredicate`), or handed to a call — and the function has exactly one
 *   declaration.
 * - A call (a static one only where it is called by its bare name or off its own type's name: a static extension call
 *   hands its receiver first) or a construction `new T(…)` binds its arguments to the parameters the way Haxe does
 *   (`ArgumentSlots`), each argument typed by the shared walk (`ArgumentTypes`); a parameter holds, over every way the
 *   call may bind, the value of the argument bound to it or — none bound, or a `null` bound to a parameter with a
 *   default (4.3.7: `f(s:String = 'a')` called `f(null)` holds `'a'`) — the callee's default.
 * - What an argument hands is known when it is a `Bool` literal, `null`, a `new` expression or an object, array or string
 *   literal (never null; the string itself where the callee's guard tests it), or a tracked parameter of the caller the
 *   caller's valuation knows (a `Bool` one negated through `!`); a default, when it is a `Bool`, string or number literal
 *   or `null`, and `null` for a `?p` with none.
 */
@:nullSafety(Strict)
final class ArgumentValues {

	public static inline final UNKNOWN: String = '?';
	public static inline final TRUE: String = 't';
	public static inline final FALSE: String = 'f';

	/** A parameter holding `null`. */
	public static inline final NULL: String = 'n';

	/** A parameter holding a value that is never null, of no known `Bool` or string value. */
	public static inline final NON_NULL: String = 'v';

	/** The prefix of the atom of a known string: `s:` and the string. */
	private static inline final STRING_ATOM: String = 's:';

	/** The code of the first character spelling a value of several atoms, or a string's (`spell`): the private-use plane. */
	private static inline final SET_BASE: Int = 0xE000;

	/** The highest code a string a guard may decide may hold: printable ASCII, whose ends every target compares alike. */
	private static inline final PRINTABLE_LAST: Int = 0x7E;

	/** The lowest such code. */
	private static inline final PRINTABLE_FIRST: Int = 0x20;

	/** Function id -> the names of its tracked parameters, in declaration order. */
	private final _tracked: Map<String, Array<String>> = [];

	/** Function id -> the tracked parameters a string affix guard of its body tests (`stringTested`). */
	private final _stringTested: Map<String, Array<String>> = [];

	/** The atoms of each value a private-use character spells, by the character's offset from `SET_BASE`. */
	private final _sets: Array<Array<String>> = [];

	/** The atoms of a value, joined by a newline -> the character spelling it. */
	private final _setChars: Map<String, String> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _shape: RefShape;
	private final _ifKinds: Array<String>;

	/** The kinds of a value built where it is written, never null: a construction, an object or array literal. */
	private final _builtKinds: Array<String>;

	/** The written types of the arguments and how they meet the parameters (`ArgumentTypes`). */
	private final _types: ArgumentTypes;

	public function new(graph: CallGraph, trees: FunctionTrees, plugin: GrammarPlugin) {
		_graph = graph;
		_trees = trees;
		_shape = plugin.refShape();
		_types = new ArgumentTypes(graph, trees, plugin);
		_ifKinds = ShapeVocab.conditionalKinds(_shape);
		_builtKinds = builtKindsOf(_shape);
	}

	/** The valuation of `id` that knows nothing: every tracked parameter unknown. */
	public function unknown(id: String): String {
		return [for (_ in tracked(id)) UNKNOWN].join('');
	}

	/** The valuation of `edge.to`'s tracked parameters a call made under the caller's `valuation` hands it. */
	public function bind(edge: CallEdge, valuation: String): String {
		final names: Array<String> = tracked(edge.to);
		if (names.length == 0) return '';
		final unknownValuation: String = unknown(edge.to);
		if (edge.kind != Call && edge.kind != Virtual && edge.kind != New || edge.spliced != null) return unknownValuation;
		final args: Null<Array<QueryNode>> = argumentsAt(edge);
		final callee: Null<QueryNode> = _trees.ofId(edge.to);
		if (args == null || callee == null) return unknownValuation;
		final params: Array<QueryNode> = [for (c in callee.children) if ((_shape.paramKinds ?? []).contains(c.kind)) c];
		final calleeFile: String = _graph.node(edge.to)?.file ?? '';
		final runs: Null<Array<Array<Int>>> = bindings(edge, args, params, calleeFile);
		if (runs == null || runs.length == 0) return unknownValuation;
		final callerNames: Array<String> = tracked(edge.from);
		final tested: Array<String> = stringTested(edge.to);
		final passed: Array<QueryNode> = args;
		final call: CallBinding = {
			edge: edge,
			args: passed,
			params: params,
			calleeFile: calleeFile,
			callerNames: callerNames,
			valuation: valuation
		};
		return [
			for (name in names) valueOver(runs, params.findIndex(p -> p.name == name), call, tested.contains(name))
		].join('');
	}

	/**
	 * The parameters of `id` a condition or a call of its body reads bare and nothing in it writes or shadows: what a
	 * valuation of `id` is over. Empty for a function of several declarations, or one the graph holds no body of.
	 */
	public function tracked(id: String): Array<String> {
		final known: Null<Array<String>> = _tracked[id];
		if (known != null) return known;
		final names: Array<String> = [];
		_tracked[id] = names;
		final fn: Null<QueryNode> = _trees.ofId(id);
		if (fn == null || _graph.declarationsOf(id).length != 1) return names;
		final paramKinds: Array<String> = _shape.paramKinds ?? [];
		final read: Array<String> = [];
		collectBareReads(fn, read);
		for (p in fn.children) {
			final name: Null<String> = p.name;
			if (paramKinds.contains(p.kind) && name != null && read.contains(name) && BareNames.stable(fn, p, _shape)) names.push(name);
		}
		return names;
	}

	/** The operand `cond` (an `==` / `!=`) compares with the `null` literal; null when neither side is that literal. */
	public function nullTested(cond: QueryNode): Null<QueryNode> {
		return NodeShape.nullComparedSide(cond, _shape.nullLiteralKind);
	}

	/**
	 * The atoms of the value the valuation character `value` spells — `TRUE`, `FALSE`, `NULL`, `NON_NULL`, a known string
	 * (`stringOf`) — or null for `UNKNOWN`, and for a character this valuation spells nothing with.
	 */
	public function atomsOf(value: String): Null<Array<String>> {
		if (value == TRUE || value == FALSE || value == NULL || value == NON_NULL) return [value];
		final at: Int = value.length == 1 ? value.charCodeAt(0) ?? 0 : 0;
		return at >= SET_BASE && at - SET_BASE < _sets.length ? _sets[at - SET_BASE] : null;
	}

	/**
	 * The string affix guard `cond` is in the body of `fnId`: a call of the suffix or prefix test (`RefShape.stringAffixTests`)
	 * on a tracked parameter written as the core string type, with one plain printable string literal, where the extension
	 * the callee's file binds the call to is provably that module's (`affixResolves`). Null for any other condition.
	 */
	public function stringPredicate(fnId: String, cond: QueryNode): Null<AffixTest> {
		final affix: Null<{ module: String, suffix: String, prefix: String }> = _shape.stringAffixTests;
		final receiver: Null<QueryNode> = affixReceiver(cond);
		final method: Null<String> = receiver == null ? null : cond.children[0].name;
		if (affix == null || receiver == null || method == null) return null;
		final text: Null<String> = plainText(cond.children[1]);
		final at: Int = receiver.kind == _shape.identKind ? tracked(fnId).indexOf(receiver.name ?? '') : -1;
		final fn: Null<QueryNode> = _trees.ofId(fnId);
		final file: Null<String> = _graph.node(fnId)?.file;
		if (text == null || at < 0 || fn == null || file == null) return null;
		final param: Null<QueryNode> = fn.children.find(c -> (_shape.paramKinds ?? []).contains(c.kind) && c.name == receiver.name);
		final written: Null<String> = param == null ? null : _types.annotationOf(param, file);
		final core: Null<String> = written == null ? null : _types.coreName(written);
		return core == null || core != stringTypeName() || !affixResolves(file, method, affix.module)
			? null
			: { param: at, suffix: method == affix.suffix, text: text };
	}

	/** Whether the atom `atom` holds `null`. */
	public static inline function isNullAtom(atom: String): Bool {
		return atom == NULL;
	}

	/** The string the atom `atom` holds, or null for an atom of no known string. */
	public static function stringOf(atom: String): Null<String> {
		return StringTools.startsWith(atom, STRING_ATOM) ? atom.substr(STRING_ATOM.length) : null;
	}

	/**
	 * Every way the call of `edge` may bind its `args` to `params` of the callee declared in `calleeFile`
	 * (`ArgumentSlots`), each argument typed where the caller writes it; null where there are too many to follow.
	 */
	private function bindings(
		edge: CallEdge, args: Array<QueryNode>, params: Array<QueryNode>, calleeFile: String
	): Null<Array<Array<Int>>> {
		final given: Array<Null<WrittenType>> = [for (a in args) _types.argumentType(a, edge.file, edge.from)];
		final slots: Array<SlotParam> = [
			for (p in params) { optional: skippable(p), rest: p.kind == _shape.restParamKind }
		];
		final wanted: Array<Null<String>> = [for (p in params) _types.annotationOf(p, calleeFile)];
		return ArgumentSlots.runs(
			slots, args.length, (a, p) -> _types.fit(args[a], given[a], wanted[p], calleeFile, slots[p].optional, edge.from, edge.to)
		);
	}

	/**
	 * The value parameter `at` of `call`'s callee holds over every way in `runs` the call binds it: spelled as one character
	 * (`spell`), keeping the strings it may hold where `keepStrings`. `UNKNOWN` for a rest parameter, and once one way's
	 * value is unknown.
	 */
	private function valueOver(runs: Array<Array<Int>>, at: Int, call: CallBinding, keepStrings: Bool): String {
		if (at < 0 || call.params[at].kind == _shape.restParamKind) return UNKNOWN;
		final param: QueryNode = call.params[at];
		final atoms: Array<String> = [];
		for (run in runs) {
			final bound: Int = run.indexOf(at);
			final arg: Null<QueryNode> = bound < 0 ? null : call.args[bound];
			// a `null` handed to a parameter with a default leaves it the default
			final value: String = arg == null || hasDefault(param) && _types.unwrap(arg).kind == _shape.nullLiteralKind
				? defaultOf(param, call.calleeFile, keepStrings)
				: valueOf(arg, call, keepStrings);
			final part: Null<Array<String>> = atomsOf(value);
			if (part == null) return UNKNOWN;
			for (a in part) if (!atoms.contains(a)) atoms.push(a);
		}
		return spell(atoms, keepStrings);
	}

	/**
	 * The character spelling a value of `atoms`: the atom's own for one of the base atoms, else one this valuation keeps for
	 * that set — a string atom read as `NON_NULL` unless `keepStrings`.
	 */
	private function spell(atoms: Array<String>, keepStrings: Bool): String {
		final kept: Array<String> = [];
		for (a in atoms) {
			final atom: String = keepStrings || stringOf(a) == null ? a : NON_NULL;
			if (!kept.contains(atom)) kept.push(atom);
		}
		if (kept.length == 0) return UNKNOWN;
		if (kept.length == 1 && stringOf(kept[0]) == null) return kept[0];
		kept.sort(Reflect.compare);
		final key: String = kept.join('\n');
		final known: Null<String> = _setChars[key];
		if (known != null) return known;
		final char: String = String.fromCharCode(SET_BASE + _sets.length);
		_sets.push(kept);
		_setChars[key] = char;
		return char;
	}

	/**
	 * The arguments the call or construction `edge` hands its target, in order: a call's after its callee — never a static
	 * extension's, which hands its receiver first (`receiverPassesNothing`) —, a `new`'s after the type arguments it names.
	 * Null when the site at exactly `edge`'s range is neither.
	 */
	private function argumentsAt(edge: CallEdge): Null<Array<QueryNode>> {
		final span: Null<Span> = edge.span;
		var node: Null<QueryNode> = _trees.ofEdge(edge);
		if (span == null) return null;
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to) {
				if (node.kind == _shape.callKind)
					return receiverPassesNothing(_graph, _shape, node, edge.to) ? node.children.slice(1) : null;
				if (node.kind == _shape.newExprKind && edge.kind == New) return node.children.slice(node.typeArgCount);
			}
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

	/**
	 * What the argument `arg` of `call` hands a parameter: a `Bool` literal, `null`, a value built where it is written (the
	 * string itself where `keepStrings`), or a tracked parameter of the caller its valuation knows.
	 */
	private function valueOf(arg: QueryNode, call: CallBinding, keepStrings: Bool): String {
		if (arg.kind == _shape.parenKind && arg.children.length == 1) return valueOf(arg.children[0], call, keepStrings);
		if (arg.kind == _shape.notKind && arg.children.length == 1) return negated(valueOf(arg.children[0], call, keepStrings));
		if (arg.kind == _shape.boolLitKind) return literal(arg, call.edge.file);
		if (arg.kind == _shape.nullLiteralKind) return NULL;
		if ((_shape.stringLiteralKinds ?? []).contains(arg.kind)) return stringValue(arg, keepStrings);
		// a value built where it is written is never null: a construction, an object or array literal
		if (_builtKinds.contains(arg.kind)) return NON_NULL;
		if (arg.kind == _shape.identKind) {
			final at: Int = call.callerNames.indexOf(arg.name ?? '');
			if (at >= 0) return call.valuation.charAt(at);
		}
		return UNKNOWN;
	}

	/** The value `!` of a value `value` makes: `TRUE` and `FALSE` swapped, `UNKNOWN` for one holding any other atom. */
	private function negated(value: String): String {
		final atoms: Null<Array<String>> = atomsOf(value);
		if (atoms == null || atoms.exists(a -> a != TRUE && a != FALSE)) return UNKNOWN;
		return spell([for (a in atoms) a == TRUE ? FALSE : TRUE], false);
	}

	/**
	 * What the parameter `param`, declared in `file`, holds when a call leaves it out: its `Bool`, string or number literal
	 * default or `null`, `null` for a `?p` with no default; unknown for any other default.
	 */
	private function defaultOf(param: QueryNode, file: String, keepStrings: Bool): String {
		final annotations: Array<String> = _shape.typeAnnotationKinds ?? [];
		final value: Null<QueryNode> = param.children.find(c -> !annotations.contains(c.kind));
		return if (value == null)
			param.kind == _shape.optionalParamKind ? NULL : UNKNOWN
		else if (value.kind == _shape.nullLiteralKind)
			NULL
		else if (value.kind == _shape.boolLitKind)
			literal(value, file)
		else if ((_shape.stringLiteralKinds ?? []).contains(value.kind))
			stringValue(value, keepStrings)
		else if ((_shape.numericLiteralKinds ?? []).contains(value.kind))
			NON_NULL
		else
			UNKNOWN;
	}

	/** The value of the string literal `node`: the string itself where `keepStrings` and its text is plain, else `NON_NULL`. */
	private function stringValue(node: QueryNode, keepStrings: Bool): String {
		final text: Null<String> = keepStrings ? plainText(node) : null;
		return text == null ? NON_NULL : spell([STRING_ATOM + text], true);
	}

	/**
	 * The text of `node` when it is a string literal of plain printable characters — no escape, no interpolation — the one
	 * every target holds alike; null otherwise.
	 */
	private function plainText(node: QueryNode): Null<String> {
		final text: Null<String> = Lit.plainStringValue(node, _shape);
		if (text == null) return null;
		for (i in 0...text.length) {
			final c: Int = text.charCodeAt(i) ?? 0;
			if (c < PRINTABLE_FIRST || c > PRINTABLE_LAST || c == '\\'.code || c == '$'.code) return null;
		}
		return text;
	}

	/** The parameters of `id`'s tracked ones a string affix guard of its body tests (`stringPredicate`). */
	private function stringTested(id: String): Array<String> {
		final known: Null<Array<String>> = _stringTested[id];
		if (known != null) return known;
		final names: Array<String> = [];
		_stringTested[id] = names;
		final fn: Null<QueryNode> = _trees.ofId(id);
		if (fn != null) collectAffixTests(fn, id, names);
		return names;
	}

	/** Adds the tracked parameter every string affix guard in `node`'s subtree tests. */
	private function collectAffixTests(node: QueryNode, id: String, into: Array<String>): Void {
		final test: Null<AffixTest> = stringPredicate(id, node);
		final name: Null<String> = test == null ? null : tracked(id)[test.param];
		if (name != null && !into.contains(name)) into.push(name);
		for (c in node.children) collectAffixTests(c, id, into);
	}

	/**
	 * Whether a call `recv.method(…)` on a string in `file` runs the static extension `module` declares: the `using` the
	 * file binds it to (`ValueNameBinding.bindingUsing`) is `module`'s, and that is the std one — a module the index cannot
	 * read where no indexed type bears its name, or one read from the std.
	 */
	private function affixResolves(file: String, method: String, module: String): Bool {
		final held: Null<HeldFile> = _graph.types.heldFile(file);
		if (held == null) return false;
		final bound: Null<{ path: String, hosts: Null<Array<ResolvedType>> }> = held.index.values.bindingUsing(held.info, method);
		if (bound == null || bound.path != module) return false;
		final hosts: Null<Array<ResolvedType>> = bound.hosts;
		return hosts == null ? _graph.types.declarationCount(module) == 0 : hosts.foreach(h -> StdResolver.isStdFile(h.file.file));
	}

	/** The name of the core string type: the type the grammar's string literals have. */
	private function stringTypeName(): Null<String> {
		final kinds: Array<String> = _shape.stringLiteralKinds ?? [];
		return kinds.length == 0 ? null : _shape.literalTypeNames?.get(kinds[0]);
	}

	/** `TRUE` / `FALSE` for the `Bool` literal `node` of `file`, by its text. */
	private function literal(node: QueryNode, file: String): String {
		final span: Null<Span> = node.span;
		final source: Null<String> = _graph.sourceOf(file);
		if (span == null || source == null) return UNKNOWN;
		final text: String = source.substring(span.from, span.to);
		return switch (text) {
			case 'true': TRUE;
			case 'false': FALSE;
			case _: UNKNOWN;
		};
	}

	/** Whether a parameter can be left out of a call: `?p`, or one with a default value. */
	private function skippable(param: QueryNode): Bool {
		return param.kind == _shape.optionalParamKind || hasDefault(param);
	}

	/** Whether the parameter `param` carries a default value. */
	private function hasDefault(param: QueryNode): Bool {
		final annotations: Array<String> = _shape.typeAnnotationKinds ?? [];
		return param.children.exists(c -> !annotations.contains(c.kind));
	}

	/**
	 * The names `node`'s subtree reads bare as a condition — of an `if`, a ternary, an operand of `&&` / `||`, the value
	 * of a `final` local, through parentheses and `!`, compared with `null` there, or the receiver of a string affix test
	 * there — or hands bare to a call.
	 */
	private function collectBareReads(node: QueryNode, into: Array<String>): Void {
		final kids: Array<QueryNode> = node.children;
		if (_ifKinds.contains(node.kind) && kids.length > 0) bareName(kids[0], into);
		if ((node.kind == _shape.logicalAndKind || node.kind == _shape.logicalOrKind) && kids.length == 2) {
			bareName(kids[0], into);
			bareName(kids[1], into);
		}
		if (node.kind == _shape.callKind) for (i in 1...kids.length) bareName(kids[i], into);
		// a `final` local bound to a condition is read as that condition (`EdgeConditions`)
		final finalLocal: Bool = (_shape.localDeclKinds ?? []).contains(node.kind)
			&& !(_shape.mutableLocalDeclKinds ?? []).contains(node.kind);
		if (finalLocal && kids.length > 0) bareName(kids[kids.length - 1], into);
		for (k in kids) collectBareReads(k, into);
	}

	/**
	 * Adds the identifier `expr` reads through parentheses and `!`, compares with `null`, or tests a string affix of
	 * (`RefShape.stringAffixTests`), if it is one.
	 */
	private function bareName(expr: QueryNode, into: Array<String>): Void {
		if ((expr.kind == _shape.parenKind || expr.kind == _shape.notKind) && expr.children.length == 1) {
			bareName(expr.children[0], into);
			return;
		}
		if (expr.kind == _shape.eqKind || expr.kind == _shape.notEqKind) {
			final tested: Null<QueryNode> = nullTested(expr);
			if (tested != null) bareName(tested, into);
			return;
		}
		final affix: Null<QueryNode> = affixReceiver(expr);
		if (affix != null) {
			bareName(affix, into);
			return;
		}
		final name: Null<String> = expr.name;
		if (expr.kind == _shape.identKind && name != null && !into.contains(name)) into.push(name);
	}

	/** The receiver of `expr` when it is a call of a string affix test by its name (`RefShape.stringAffixTests`); else null. */
	private function affixReceiver(expr: QueryNode): Null<QueryNode> {
		final affix: Null<{ module: String, suffix: String, prefix: String }> = _shape.stringAffixTests;
		final callee: Null<QueryNode> = expr.kind == _shape.callKind && expr.children.length == 2 ? expr.children[0] : null;
		final method: Null<String> = callee?.name;
		return affix == null || callee == null || callee.kind != _shape.fieldAccessKind || callee.children.length != 1
			|| method != affix.suffix && method != affix.prefix
			? null
			: callee.children[0];
	}

	/**
	 * Whether the call `call` of `target` hands it only its written arguments: an instance method, or a static one called
	 * by its bare name or off its own type's name — never a static extension, which takes the receiver first.
	 */
	public static function receiverPassesNothing(graph: CallGraph, shape: RefShape, call: QueryNode, target: String): Bool {
		final fn: Null<FnNode> = graph.node(target);
		final type: Null<String> = fn?.typeName;
		final name: Null<String> = fn?.name;
		if (fn == null || type == null || name == null) return false;
		if (!graph.types.isStatic(type, name)) return true;
		final callee: QueryNode = call.children[0];
		return callee.kind == shape.identKind || callee.kind == shape.fieldAccessKind && callee.children.length == 1
			&& callee.children[0].kind == shape.identKind && callee.children[0].name == type;
	}

	/** The kinds of a value built where it is written, never null: a construction, an object or array literal. */
	private static function builtKindsOf(shape: RefShape): Array<String> {
		return [
			for (k in [shape.newExprKind, shape.objectLiteralKind, shape.arrayLiteralKind]) if (k != null) k
		];
	}

}

/**
 * A string affix guard (`ArgumentValues.stringPredicate`): of the tracked parameter `param`, whether it ends (`suffix`) or
 * starts with `text`.
 */
typedef AffixTest = {
	final param: Int;
	final suffix: Bool;
	final text: String;
}

/** One call `ArgumentValues.bind` reads: its edge, arguments, the callee's parameters, and what the caller knows. */
private typedef CallBinding = {
	final edge: CallEdge;
	final args: Array<QueryNode>;
	final params: Array<QueryNode>;
	final calleeFile: String;
	final callerNames: Array<String>;
	final valuation: String;
}

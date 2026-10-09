package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;

/**
 * What a call hands the parameters of the function it calls, as far as `EdgeConditions` reads them: the TRACKED
 * parameters of a function, and the VALUATION a call gives them — one character per tracked parameter, `UNKNOWN`,
 * `TRUE` / `FALSE`, `NULL`, or `NON_NULL`.
 *
 * A positive whitelist:
 * - A parameter is TRACKED when nothing in the body writes or shadows its name (no assignment, no increment, no other
 *   declaration of it, nested functions included) and the body reads it bare — as a condition, compared with `null`, or
 *   handed to a call — and the function has exactly one declaration.
 * - What a call hands a tracked parameter is known when its argument is a `Bool` literal, `null`, a `new` expression or
 *   an object, array or string literal (never null),
 *   a tracked parameter of the caller the caller's valuation knows (a `Bool` one negated through `!`), or — the
 *   argument omitted — the callee's own default: a `Bool` literal or `null`, and `null` for a `?p` with none.
 * - Arguments map to parameters by position only where Haxe cannot skip one by type: each optional parameter (`?p`,
 *   `p = v`) the call reaches takes an argument whose type is written as the parameter's own (`Bool` for a `Bool`
 *   literal or a logical expression, `String` for a string literal, the annotation of a parameter or local declared
 *   once). A static callee is read only where it is called by its bare name or off its own type's name (a static
 *   extension call hands its receiver first).
 */
@:nullSafety(Strict)
final class ArgumentValues {

	public static inline final UNKNOWN: String = '?';
	public static inline final TRUE: String = 't';
	public static inline final FALSE: String = 'f';

	/** A parameter holding `null`. */
	public static inline final NULL: String = 'n';

	/** A parameter holding a value that is never null, of no known `Bool` value. */
	public static inline final NON_NULL: String = 'v';

	/** The written type of every `Bool`-valued expression shape `argumentType` knows. */
	private static inline final BOOL_TYPE: String = 'Bool';

	private static inline final STRING_TYPE: String = 'String';

	/** The types whose written name means the same type in every file. */
	private static final CORE_TYPES: Array<String> = [BOOL_TYPE, STRING_TYPE, 'Int', 'Float'];

	/** Function id -> the names of its tracked parameters, in declaration order. */
	private final _tracked: Map<String, Array<String>> = [];

	/** File -> its declarations' written types (`typeSourcesOf`). */
	private final _typeSources: Map<String, Map<Int, String>> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _shape: RefShape;
	private final _ifKinds: Array<String>;

	/** The kinds of a value built where it is written, never null: a construction, an object or array literal. */
	private final _builtKinds: Array<String>;

	/** What reads the written types of declarations; null for a plugin that reads none, which then knows no type. */
	private final _types: Null<TypeInfoProvider>;

	public function new(graph: CallGraph, trees: FunctionTrees, plugin: GrammarPlugin) {
		_graph = graph;
		_trees = trees;
		_shape = plugin.refShape();
		_types = plugin is TypeInfoProvider ? cast plugin : null;
		_ifKinds = conditionalKinds(_shape);
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
		if (edge.kind != Call && edge.kind != Virtual || edge.spliced != null) return unknownValuation;
		final call: Null<QueryNode> = callAt(edge);
		final callee: Null<QueryNode> = _trees.ofId(edge.to);
		if (call == null || callee == null || !receiverPassesNothing(call, edge.to)) return unknownValuation;
		final params: Array<QueryNode> = [for (c in callee.children) if ((_shape.paramKinds ?? []).contains(c.kind)) c];
		final args: Array<QueryNode> = call.children.slice(1);
		if (args.length > params.length || params.exists(p -> p.kind == _shape.restParamKind)) return unknownValuation;
		final caller: Null<QueryNode> = _trees.ofEdge(edge);
		final calleeFile: String = _graph.node(edge.to)?.file ?? '';
		if (caller == null || maySkip(args, params, edge.file, caller, calleeFile)) return unknownValuation;
		final callerNames: Array<String> = tracked(edge.from);
		inline function valueAt(at: Int): String {
			return if (at < 0)
				UNKNOWN
			else if (at < args.length)
				valueOf(args[at], edge.file, callerNames, valuation)
			else
				defaultOf(params[at], calleeFile);
		}
		return [for (name in names) valueAt(params.findIndex(p -> p.name == name))].join('');
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
		final kids: Array<QueryNode> = cond.children;
		if (kids.length != 2) return null;
		return if (kids[1].kind == _shape.nullLiteralKind)
			kids[0]
		else if (kids[0].kind == _shape.nullLiteralKind)
			kids[1]
		else
			null;
	}

	/** The call node of `edge`'s site in its function's body; null when there is none at exactly that range. */
	private function callAt(edge: CallEdge): Null<QueryNode> {
		final span: Null<Span> = edge.span;
		var node: Null<QueryNode> = _trees.ofEdge(edge);
		if (span == null) return null;
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to && node.kind == _shape.callKind) return node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

	/**
	 * Whether the call `call` of `target` hands it only its written arguments: an instance method, or a static one called
	 * by its bare name or off its own type's name — never a static extension, which takes the receiver first.
	 */
	private function receiverPassesNothing(call: QueryNode, target: String): Bool {
		final fn: Null<FnNode> = _graph.node(target);
		final type: Null<String> = fn?.typeName;
		final name: Null<String> = fn?.name;
		if (fn == null || type == null || name == null) return false;
		if (!_graph.types.isStatic(type, name)) return true;
		final callee: QueryNode = call.children[0];
		return callee.kind == _shape.identKind || callee.kind == _shape.fieldAccessKind && callee.children.length == 1
			&& callee.children[0].kind == _shape.identKind && callee.children[0].name == type;
	}

	/**
	 * What the argument `arg` hands a parameter: a `Bool` literal, `null`, a `new` value, or a tracked parameter of the
	 * caller its `valuation` knows.
	 */
	private function valueOf(arg: QueryNode, file: String, callerNames: Array<String>, valuation: String): String {
		if (arg.kind == _shape.parenKind && arg.children.length == 1) return valueOf(arg.children[0], file, callerNames, valuation);
		if (arg.kind == _shape.notKind && arg.children.length == 1) {
			final inner: String = valueOf(arg.children[0], file, callerNames, valuation);
			return switch (inner) {
				case TRUE: FALSE;
				case FALSE: TRUE;
				case _: UNKNOWN;
			};
		}
		if (arg.kind == _shape.boolLitKind) return literal(arg, file);
		if (arg.kind == _shape.nullLiteralKind) return NULL;
		// a value built where it is written is never null: a construction, an object, array or string literal
		if (_builtKinds.contains(arg.kind) || (_shape.stringLiteralKinds ?? []).contains(arg.kind)) return NON_NULL;
		if (arg.kind == _shape.identKind) {
			final at: Int = callerNames.indexOf(arg.name ?? '');
			if (at >= 0) return valuation.charAt(at);
		}
		return UNKNOWN;
	}

	/**
	 * What the parameter `param`, declared in `file`, holds when a call leaves it out: its `Bool` literal or `null`
	 * default, `null` for a `?p` with no default; unknown for any other default.
	 */
	private function defaultOf(param: QueryNode, file: String): String {
		final annotations: Array<String> = _shape.typeAnnotationKinds ?? [];
		final value: Null<QueryNode> = param.children.find(c -> !annotations.contains(c.kind));
		return if (value == null)
			param.kind == _shape.optionalParamKind ? NULL : UNKNOWN
		else if (value.kind == _shape.nullLiteralKind)
			NULL
		else if (value.kind == _shape.boolLitKind)
			literal(value, file)
		else
			UNKNOWN;
	}

	/**
	 * Whether Haxe may skip an optional parameter of `params` (declared in `calleeFile`) for one of `args` (written in the
	 * function `caller` of `file`), binding the arguments after it one place later: never with every parameter passed,
	 * and otherwise unless each optional parameter an argument reaches is written with that argument's own type.
	 */
	private function maySkip(
		args: Array<QueryNode>, params: Array<QueryNode>, file: String, caller: QueryNode, calleeFile: String
	): Bool {
		return args.length != params.length
			&& [for (i in 0...args.length) i].exists(i ->
				skippable(params[i]) && !sameWrittenType(args[i], file, caller, params[i], calleeFile)
			);
	}

	/**
	 * Whether the argument `arg` of a call in the function `caller` of `file` is written with the type the parameter
	 * `param` of `paramFile` is annotated with, so Haxe binds it there and skips nothing.
	 */
	private function sameWrittenType(arg: QueryNode, file: String, caller: QueryNode, param: QueryNode, paramFile: String): Bool {
		final wanted: Null<String> = annotationOf(param, paramFile);
		final given: Null<String> = argumentType(arg, file, caller);
		// one written type names one type within a file; across files only a core type's name is sure to
		return wanted != null && given != null && wanted == given && (file == paramFile || CORE_TYPES.contains(wanted));
	}

	/** The written type of `arg` in the function `caller` of `file`; null when no shape this reads says it. */
	private function argumentType(arg: QueryNode, file: String, caller: QueryNode): Null<String> {
		final kind: String = arg.kind;
		if (kind == _shape.parenKind && arg.children.length == 1) return argumentType(arg.children[0], file, caller);
		final logical: Array<Null<String>> = [_shape.boolLitKind, _shape.notKind, _shape.logicalAndKind, _shape.logicalOrKind];
		if (logical.contains(kind) || (_shape.equalityKinds ?? []).contains(kind) || (_shape.comparisonKinds ?? []).contains(kind))
			return BOOL_TYPE;
		if ((_shape.stringLiteralKinds ?? []).contains(kind)) return STRING_TYPE;
		final name: Null<String> = arg.name;
		if (kind != _shape.identKind || name == null) return null;
		final decls: Array<QueryNode> = [];
		BareNames.collectNamed(caller, name, _shape, decls);
		return decls.length == 1 ? annotationOf(decls[0], file) : null;
	}

	/**
	 * The type annotation of the declaration `decl` of `file` (a parameter, a local), as written without whitespace: the
	 * one the plugin records at the declaration's binding, the first one inside its range. Null when it has none.
	 */
	private function annotationOf(decl: QueryNode, file: String): Null<String> {
		final span: Null<Span> = decl.span;
		if (span == null) return null;
		final sources: Map<Int, String> = typeSourcesOf(file);
		var best: Int = -1;
		for (at in sources.keys()) if (at >= span.from && at < span.to && (best < 0 || at < best)) best = at;
		final written: Null<String> = best < 0 ? null : sources[best];
		return written == null ? null : ~/\s+/g.replace(written, '');
	}

	/** The written types of every annotated declaration of `file`, by binding offset (`TypeInfoProvider.declaredTypeSources`). */
	private function typeSourcesOf(file: String): Map<Int, String> {
		final known: Null<Map<Int, String>> = _typeSources[file];
		if (known != null) return known;
		final source: Null<String> = _graph.sourceOf(file);
		final read: Map<Int, String> = source == null || _types == null ? [] : _types.declaredTypeSources(source);
		_typeSources[file] = read;
		return read;
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
		final annotations: Array<String> = _shape.typeAnnotationKinds ?? [];
		return param.kind == _shape.optionalParamKind || param.children.exists(c -> !annotations.contains(c.kind));
	}

	/**
	 * The names `node`'s subtree reads bare as a condition — of an `if`, a ternary, an operand of `&&` / `||`, the value
	 * of a `final` local, through parentheses and `!`, or compared with `null` there — or hands bare to a call.
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

	/** Adds the identifier `expr` reads through parentheses and `!`, or compares with `null`, if it is one. */
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
		final name: Null<String> = expr.name;
		if (expr.kind == _shape.identKind && name != null && !into.contains(name)) into.push(name);
	}

	/** The kinds of an `if` statement, an `if` expression and a ternary: the constructs whose first child is a condition. */
	public static function conditionalKinds(shape: RefShape): Array<String> {
		return (shape.ifStatementKinds ?? []).concat(shape.ifExpressionKinds ?? [])
			.concat(shape.ternaryKind == null ? [] : [shape.ternaryKind]);
	}

	/** The kinds of a value built where it is written, never null: a construction, an object or array literal. */
	private static function builtKindsOf(shape: RefShape): Array<String> {
		return [
			for (k in [shape.newExprKind, shape.objectLiteralKind, shape.arrayLiteralKind]) if (k != null) k
		];
	}

}

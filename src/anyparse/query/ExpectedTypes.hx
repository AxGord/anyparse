package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

/**
 * THE expected-type engine: the type a value is EXPECTED to have where it is written, read off the written types around
 * it — and through it the type an untyped lambda parameter takes, which is the parameter of the function type the lambda
 * is expected to be. Every typer asks it (`docs/decisions.md`, "ONE expected-type engine"): the call graph from the
 * lineage its own walk keeps, the operand binder from the lineage `lineageOf` reads off the tree, each through its own
 * `ExpectationHost`.
 *
 * The engine owns the LADDER, the shapes an expectation passes through or is taken apart by, each proved on Haxe 4.3.7
 * (`$type` of an untyped lambda parameter in every one): parentheses, a ternary's or an `if`'s arms, a `switch` arm, the
 * value a block ends with, an array element, a map value, an object-literal field, a lambda's body (the result of the
 * function type the lambda is expected to be), a `return` (the enclosing function's written result, an untyped lambda's
 * from its own expectation), a declaration written with a type, an assignment, a call or construction argument. The host
 * owns what a declaration, an assignment target, a function's result, a callee's parameter, a container's element and a
 * nominal's field ARE in its currency `W`; a question it cannot answer soundly is a null answer, never a guess.
 */
@:nullSafety(Strict)
final class ExpectedTypes {

	private final _localDeclKinds: Array<String>;
	private final _fieldKinds: Array<String>;
	private final _assignKind: Null<String>;
	private final _returnKinds: Array<String>;
	private final _lambdaKinds: Array<String>;
	private final _fnKinds: Array<String>;
	private final _parenKind: Null<String>;
	private final _ternaryKind: Null<String>;
	private final _ifExprKinds: Array<String>;
	private final _switchKinds: Array<String>;
	private final _tryExprKinds: Array<String>;
	private final _caseBranchKind: Null<String>;
	private final _blockKinds: Array<String>;
	private final _arrayLiteralKind: Null<String>;
	private final _mapEntryKind: Null<String>;
	private final _objectFieldKind: Null<String>;
	private final _objectLiteralKind: Null<String>;
	private final _callKind: Null<String>;
	private final _newExprKind: Null<String>;
	private final _paramKinds: Array<String>;

	public function new(shape: RefShape) {
		_localDeclKinds = shape.localDeclKinds ?? [];
		_fieldKinds = shape.fieldDeclKinds ?? [];
		_assignKind = shape.assignKind;
		_returnKinds = shape.valueReturnKinds ?? [];
		_lambdaKinds = shape.lambdaKinds ?? [];
		// a local `inline function` is a function of its own like any local one, though the grammar gives it a kind apart
		_fnKinds = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		_parenKind = shape.parenKind;
		_ternaryKind = shape.ternaryKind;
		_ifExprKinds = shape.ifExpressionKinds ?? [];
		_switchKinds = shape.switchKinds ?? [];
		_tryExprKinds = shape.tryExpressionKinds ?? [];
		_caseBranchKind = shape.caseBranchKind;
		_blockKinds = [for (k in [shape.blockStmtKind, shape.exprStatementKind]) if (k != null) k];
		_arrayLiteralKind = shape.arrayLiteralKind;
		_mapEntryKind = shape.mapLiteralEntryKind;
		_objectFieldKind = shape.objectFieldKind;
		_objectLiteralKind = shape.objectLiteralKind;
		_callKind = shape.callKind;
		_newExprKind = shape.newExprKind;
		_paramKinds = shape.paramKinds ?? [];
	}

	/** Whether `node` is a lambda of the grammar — the node `lambdaParamTypes` types the parameters of. */
	public inline function isLambda(node: QueryNode): Bool {
		return _lambdaKinds.contains(node.kind);
	}

	/**
	 * Whether the type of `value` is the unification of sub-values each typed against what is expected of `value` — a
	 * ternary's, an `if`'s, a `switch`'s or a `try`'s arms, an array or map literal's elements — directly or through
	 * parentheses. Such a value may type where something is expected of it and fail where nothing is: 4.3.7 compiles
	 * `Std.isOfType(c ? 'x' : 2, String)` and rejects `(c ? 'x' : 2) is String`.
	 */
	public function unifiesUnderExpectation(value: QueryNode): Bool {
		final kind: String = value.kind;
		return kind == _parenKind && value.children.length == 1
			? unifiesUnderExpectation(value.children[0])
			: kind == _ternaryKind
				|| kind == _arrayLiteralKind
				|| _ifExprKinds.contains(kind)
				|| _switchKinds.contains(kind)
				|| _tryExprKinds.contains(kind);
	}

	/**
	 * The type the value at child `indices[level]` of `lineage[level]` is expected to have, in `host`'s currency: a
	 * declaration's annotation, an assignment's target, the enclosing function's return type (a lambda's from the function
	 * type it is typed as), the parameter of the call or constructor it is an argument of, the element of the array or the
	 * value of the map literal it sits in, the field of the object literal it initialises — through parentheses, ternary /
	 * `if` / `switch` arms and the value a block ends with. `lineage` holds the ancestors outermost first, `indices` the
	 * child index leading down from each. Null where nothing written says.
	 */
	public function expectedAt<W, C>(
		lineage: Array<QueryNode>, indices: Array<Int>, level: Int, host: ExpectationHost<W, C>, ctx: C
	): Null<W> {
		if (level < 0) return null;
		final holder: QueryNode = lineage[level];
		final index: Int = indices[level];
		final kind: String = holder.kind;
		final last: Bool = index == holder.children.length - 1;
		return if (passesThrough(kind, index, last))
			expectedAt(lineage, indices, level - 1, host, ctx)
		else if (_localDeclKinds.contains(kind) || _fieldKinds.contains(kind))
			host.declared(holder, ctx)
		else if (kind == _assignKind && index == 1)
			host.assigned(holder.children[0], ctx)
		else if (_returnKinds.contains(kind))
			returnExpectation(lineage, indices, level, host, ctx)
		else if (_lambdaKinds.contains(kind) && last)
			functionResult(expectedAt(lineage, indices, level - 1, host, ctx), host, ctx)
		else if ((kind == _callKind && index >= 1) || kind == _newExprKind)
			argumentExpectation(holder, index, host, ctx)
		else
			literalExpectation(lineage, indices, level, host, ctx);
	}

	/**
	 * The types the parameters of `lambda`, whose ancestors are `lineage` (`indices` as for `expectedAt`), take from the
	 * function type it is expected to be: one per parameter, in order, when that type (a `Null<…>` peeled) is a function
	 * type of the lambda's arity; null otherwise. A parameter written with a type keeps it — the caller reads only the
	 * answers for the ones written without.
	 */
	public function lambdaParamTypes<W, C>(
		lambda: QueryNode, lineage: Array<QueryNode>, indices: Array<Int>, host: ExpectationHost<W, C>, ctx: C
	): Null<Array<W>> {
		final count: Int = lambda.children.filter(c -> _paramKinds.contains(c.kind)).length;
		final expected: Null<W> = expectedAt(lineage, indices, lineage.length - 1, host, ctx);
		if (expected == null) return null;
		final read: Null<TypeSyntax> = host.read(expected, ctx);
		return switch (read?.wrapped(['Null']) ?? read)?.shape {
			case Function(ps, _, _) if (ps.length == count): [for (p in ps) host.part(expected, p.type.text, ctx)];
			case _: null;
		};
	}

	/**
	 * The type a `return` at `lineage[level]` is expected to have: the declared return type of the function or lambda
	 * enclosing it (`ExpectationHost.returned`), or for one declaring none that is a lambda the return type of the function
	 * type the lambda is itself expected to be, asked strictly further out.
	 */
	private function returnExpectation<W, C>(
		lineage: Array<QueryNode>, indices: Array<Int>, level: Int, host: ExpectationHost<W, C>, ctx: C
	): Null<W> {
		var at: Int = level - 1;
		while (at >= 0 && !(_fnKinds.contains(lineage[at].kind) || _lambdaKinds.contains(lineage[at].kind))) at--;
		if (at < 0) return null;
		final declared: Null<W> = host.returned(lineage[at], ctx);
		return declared != null || !_lambdaKinds.contains(lineage[at].kind)
			? declared
			: functionResult(expectedAt(lineage, indices, at - 1, host, ctx), host, ctx);
	}

	/** Whether the expectation of child `index` of a node of `kind` is the node's own: parentheses, an arm, a block's value. */
	private function passesThrough(kind: String, index: Int, last: Bool): Bool {
		return kind == _parenKind
			|| (kind == _ternaryKind && index >= 1)
			|| (_ifExprKinds.contains(kind) && index >= 1)
			|| (_switchKinds.contains(kind) && index >= 1)
			|| ((kind == _caseBranchKind || _blockKinds.contains(kind)) && last);
	}

	/** The parameter child `index` of the call or construction `holder` binds as an argument (`ExpectationHost.argument`). */
	private function argumentExpectation<W, C>(holder: QueryNode, index: Int, host: ExpectationHost<W, C>, ctx: C): Null<W> {
		// a `new` names its type's arguments among its children (`new Box<Int>(x)`): they are no arguments
		final args: Array<QueryNode> = holder.kind == _callKind ? holder.children.slice(1) : holder.children.slice(holder.typeArgCount);
		final at: Int = args.indexOf(holder.children[index]);
		return at < 0 ? null : host.argument(holder, at, args.length, ctx);
	}

	/**
	 * The expectation of the literal part `lineage[level]`: an array literal's element, a map literal's value (an entry inside
	 * an array literal), an object literal's field — each read off the literal's own expected type.
	 */
	private function literalExpectation<W, C>(
		lineage: Array<QueryNode>, indices: Array<Int>, level: Int, host: ExpectationHost<W, C>, ctx: C
	): Null<W> {
		final holder: QueryNode = lineage[level];
		final kind: String = holder.kind;
		if (kind == _arrayLiteralKind) return elementOf(expectedAt(lineage, indices, level - 1, host, ctx), host, ctx);
		if (kind == _mapEntryKind && indices[level] == 1 && parentIs(lineage, level, _arrayLiteralKind))
			return elementOf(expectedAt(lineage, indices, level - 2, host, ctx), host, ctx);
		final field: Null<String> = holder.name;
		final outer: Null<W> = kind == _objectFieldKind && parentIs(lineage, level, _objectLiteralKind)
			? expectedAt(lineage, indices, level - 2, host, ctx)
			: null;
		return outer == null || field == null ? null : host.field(outer, field, ctx);
	}

	/**
	 * The ancestors of `node` in `root`, outermost first, and the child index leading down from each — the lineage
	 * `expectedAt` reads, for a typer whose own walk keeps none. Null when `node` is not in `root`.
	 */
	public static function lineageOf(root: QueryNode, node: QueryNode): Null<Lineage> {
		final path: Null<Array<QueryNode>> = TreePath.pathTo(root, node);
		if (path == null) return null;
		final nodes: Array<QueryNode> = path.slice(0, path.length - 1);
		return { nodes: nodes, indices: [for (i in 0...nodes.length) nodes[i].children.indexOf(path[i + 1])] };
	}

	/** The element a container literal of the type `outer` holds; null for none. */
	private static inline function elementOf<W, C>(outer: Null<W>, host: ExpectationHost<W, C>, ctx: C): Null<W> {
		return outer == null ? null : host.element(outer, ctx);
	}

	/** Whether `lineage[level]` sits directly inside a node of `kind`. */
	private static inline function parentIs(lineage: Array<QueryNode>, level: Int, kind: Null<String>): Bool {
		return level > 0 && lineage[level - 1].kind == kind;
	}

	/** The result type of the function type `written`, as `host` spells a part of it; null for any other type. */
	private static function functionResult<W, C>(written: Null<W>, host: ExpectationHost<W, C>, ctx: C): Null<W> {
		if (written == null) return null;
		final result: Null<String> = CallGraphNames.functionReturnSource(host.read(written, ctx));
		return result == null ? null : host.part(written, result, ctx);
	}

}

/** The ancestors of a node, outermost first, and the child index leading down from each (`ExpectedTypes.lineageOf`). */
typedef Lineage = {
	final nodes: Array<QueryNode>;
	final indices: Array<Int>;
}

/**
 * What `ExpectedTypes` asks a typer, answering in the typer's own currency `W`: the call graph's keyed type source, the
 * operand binder's written type together with where it is written. `C` is what every question threads through (the call
 * graph's enclosing type). A question the typer cannot answer soundly answers null — the engine then expects nothing.
 */
typedef ExpectationHost<W, C> = {
	/** The type the declaration `holder` (a local or a field) is written with. */
	final declared: (holder:QueryNode, ctx:C) -> Null<W>;

	/** The type of the assignment target `target`. */
	final assigned: (target:QueryNode, ctx:C) -> Null<W>;

	/** The return type the function or lambda `fn` declares. */
	final returned: (fn:QueryNode, ctx:C) -> Null<W>;

	/**
	 * The type of the parameter the argument `at` of the call or construction `call`, passing `count` arguments, binds —
	 * the callee's parameter type at an argument position; null where an argument before it may have been skipped, and
	 * for a callee whose signature the typer cannot read as the one the call selects.
	 */
	final argument: (call:QueryNode, at:Int, count:Int, ctx:C) -> Null<W>;

	/** The element an array literal of type `container` holds (a map literal's value). */
	final element: (container:W, ctx:C) -> Null<W>;

	/** The type of the field `name` of an object literal of type `outer`. */
	final field: (outer:W, name:String, ctx:C) -> Null<W>;

	/** `written` as the grammar reads a type (`GrammarPlugin.typeSyntax`). */
	final read: (written:W, ctx:C) -> Null<TypeSyntax>;

	/** The part `text` of the type `of` — a function type's parameter or result — in the same currency. */
	final part: (of:W, text:String, ctx:C) -> W;
}

package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

/**
 * The typing service of one run scope: the ONE place a typing question is asked, over the declarations the
 * `SymbolIndex` read. Its questions split the way a compiler's typer splits them. SIGNATURE questions are answered from
 * the declarations alone, no body read (`members`: what a named type declares or inherits; `structural`: what it unifies
 * with). BODY questions walk an expression: `typeWalk` owns the shapes and a `TypingHost` answers each in its own currency,
 * and `expectations` gives the type a position expects. Every answer the service remembers lives in `cache`, keyed by the
 * declaration the question is about (`DeclarationKey`), never by a name a second declaration may share.
 *
 * A declaration's key is its position in its file, so one declaration is one key whichever `#if` configuration reads it:
 * the index reads every branch, and the thirteen compiler configurations of a project ask one service and share its
 * answers. Built once by the `SymbolIndex` it types and dropped with it, so nothing a run learns outlives the run.
 * The design, the cache keys and where the later typer steps plug in: `docs/typing-service.md`.
 */
@:nullSafety(Strict)
final class TypingService {

	/** Every remembered answer of the service's declaration-keyed questions. */
	public final cache: QueryCache = new QueryCache();

	/**
	 * SIGNATURE: which `#if` branches of a declaration some build the run declares compiles (step T6); every branch when the
	 * run knows none.
	 */
	public final builds: BuildBranches;

	/** SIGNATURE: each declaration's supertype links, alias target and the arguments its chain passes to an ancestor. */
	public final ancestors: AncestorTable;

	/** SIGNATURE: the cast graph of each abstract — its `from` / `to` clauses and conversion members (`abstractCast.ml`). */
	public final casts: AbstractCasts;

	/**
	 * SIGNATURE: whether a value of one type unifies with another (`tUnification.ml`), and whether an argument of one type
	 * is accepted where another is expected (`abstractCast.ml`).
	 */
	public final unification: Unification;

	/**
	 * SIGNATURE: the `@:op` overload an abstract selects for a binary operator over two operand types, and the type it
	 * yields (`operators.ml`).
	 */
	public final operators: OperatorOverloads;

	/** SIGNATURE: what a named type declares or inherits, and with what declared type, return type and visibility. */
	public final members: MemberLookup;

	/**
	 * SIGNATURE: the signature a call selects among those of the member it calls — its own and its overloads — over its
	 * arguments' types, and the type it returns (`callUnification.ml`, step T5).
	 */
	public final calls: CallSelection;

	/** SIGNATURE: unification with an anonymous structure, and membership of a builtin structural type. */
	public final structural: StructuralTypes;

	/**
	 * BODY: which static extension `recv.name` binds in a file on a receiver of a declaration, in the compiler's order of the
	 * receiver type's `@:using` and the file's `using` statements (`fields.ml`, step T3).
	 */
	public final extensions: StaticExtensions;

	/** BODY: the type a value is expected to have where the grammar `shape` writes it (`ExpectedTypes`). */
	public final expectations: ExpectedTypes;

	/**
	 * Built by the owning `SymbolIndex` over its immutable declaration tables, its grammar's `shape` and which branches the
	 * run's builds compile (`builds`).
	 */
	public function new(
		files: Array<FileInfo>, refs: TypeRefIndex, subtypes: SubtypeGraph, typeSyntax: TypeSyntaxReader, shape: RefShape,
		builds: BuildBranches
	) {
		this.builds = builds;
		ancestors = new AncestorTable(refs, cache, typeSyntax, shape.rawDynamicTypeName);
		casts = new AbstractCasts(refs, ancestors, cache, typeSyntax, shape, builds);
		unification = new Unification(ancestors, cache, refs, casts, shape);
		operators = new OperatorOverloads(casts, unification, shape);
		members = new MemberLookup(refs, cache, ancestors, typeSyntax, shape.optionalValueTypeName);
		calls = new CallSelection(casts, unification, ancestors, typeSyntax);
		structural = new StructuralTypes(files, refs, subtypes, members, typeSyntax, unification);
		extensions = new StaticExtensions(refs, cache, ancestors, members, structural);
		expectations = new ExpectedTypes(shape);
	}

	/**
	 * The type source `raw` carries, as `host` spells it — THE structural walk both resolution models share (`TypingHost`;
	 * `docs/decisions.md`, "ONE structural walk, TWO resolution models"). The walk owns the shapes: what a type passes
	 * through (`peel`), a literal, the self reference, an identifier (`identifierType`), a field access, an element read, a
	 * call and a construction; the host answers each in its own terms. Null for every other shape.
	 */
	public static function typeWalk<T, C>(raw: QueryNode, shape: RefShape, host: TypingHost<T, C>, ctx: C): Null<T> {
		final node: QueryNode = host.peel(raw, ctx);
		final name: Null<String> = node.name;
		final kind: String = node.kind;
		final literalType: Null<String> = shape.literalTypeNames?.get(kind);
		final literal: Null<(typeName:String, ctx:C) -> Null<T>> = host.literal;
		if (literalType != null) return literal == null ? null : literal(literalType, ctx);
		if ((kind == shape.identKind || kind == shape.stringInterpIdentKind) && name != null)
			return name == shape.selfReferenceText ? host.self(node, ctx) : identifierType(node, shape, host, ctx);
		if (host.isAccess(kind, ctx) && name != null && node.children.length > 0) return host.access(node, ctx);
		final element: Null<(container:T, ctx:C) -> Null<T>> = host.element;
		if (kind == shape.indexAccessKind && element != null && node.children.length > 0) {
			final container: Null<T> = typeWalk(node.children[0], shape, host, ctx);
			return container == null ? null : element(container, ctx);
		}
		if (kind == shape.callKind && node.children.length > 0) return host.call(node, ctx);
		final construction: Null<(node:QueryNode, ctx:C) -> Null<T>> = host.construction;
		return kind == shape.newExprKind && name != null && construction != null
			? construction(node, ctx)
			: arithmeticType(node, shape, host, ctx);
	}

	/**
	 * `typeWalk`'s identifier: the type its binding is written with; else — for a binding written with no type, under the
	 * host's ONE cycle guard (`reading`: `for (x in x)`, a local whose initializer reads itself) — the type of the
	 * expression initialising it, the element of the loop binding it or, for a lambda's parameter, the parameter of the
	 * function type the lambda is expected to be (`TypingHost.parameter`); for a name binding no value, what it names.
	 */
	private static function identifierType<T, C>(ident: QueryNode, shape: RefShape, host: TypingHost<T, C>, ctx: C): Null<T> {
		final from: Null<Int> = host.binding(ident, ctx);
		if (from == null) return host.unbound(ident, ctx);
		final written: Null<T> = host.bound(from, ctx);
		final reading: Array<Int> = host.reading(ctx);
		if (written != null || reading.contains(from)) return written;
		reading.push(from);
		final init: Null<QueryNode> = host.initializer(from, ident, ctx);
		final parameter: Null<(from:Int, use:QueryNode, ctx:C) -> Null<T>> = host.parameter;
		final held: Null<T> = init != null
			? typeWalk(init, shape, host, ctx)
			: host.loopElement(from, ctx) ?? (parameter == null ? null : parameter(from, ident, ctx));
		reading.pop();
		return held;
	}

	/** Whether `node` is arithmetic the walk types by its operands: a binary `RefShape.arithmeticKinds` operator, or the negation. */
	private static function isArithmetic(node: QueryNode, shape: RefShape): Bool {
		final kinds: Array<String> = shape.arithmeticKinds ?? [];
		return kinds.contains(node.kind) && node.children.length == 2 || node.kind == shape.negationKind && node.children.length == 1;
	}

	/**
	 * The type the arithmetic `node` yields (`TypingHost.arithmetic`) over its operands typed by the walk: null for anything
	 * but a binary `RefShape.arithmeticKinds` operator or the negation, for a host typing none, and when an operand is untyped.
	 */
	private static function arithmeticType<T, C>(node: QueryNode, shape: RefShape, host: TypingHost<T, C>, ctx: C): Null<T> {
		final arithmetic: Null<(node:QueryNode, operands:Array<T>, ctx:C) -> Null<T>> = host.arithmetic;
		if (arithmetic == null || !isArithmetic(node, shape)) return null;
		final operands: Array<T> = [];
		for (c in node.children) {
			final t: Null<T> = typeWalk(c, shape, host, ctx);
			if (t == null) return null;
			operands.push(t);
		}
		return arithmetic(node, operands, ctx);
	}

}

/**
 * The resolution `TypingService.typeWalk` asks for, answering in its own currency `T`. Two hosts answer a type SOURCE and
 * differ in how it is spelled: the call graph spells it as it keys types (`CallGraphKeys.keyedIn`), the index as it was
 * written, resolved in the file that wrote it. The third, `OperandBinder`, answers what that written type BINDS to where it
 * is written (a `TypeNameBinding.Tier`), the currency an operator-overload gate judges a declaration in. `C` is what a walk
 * threads through every question (the call graph's enclosing type). The walk owns the shapes; the host owns what a
 * binding, a member, a call ARE — `docs/decisions.md`, "ONE structural walk, TWO resolution models". An arc a host does
 * not know is a null function (the walk skips the shape) or a null answer, never a guess.
 */
typedef TypingHost<T, C> = {
	/** `node` with what a type passes through unchanged (parentheses) peeled off, or `node` itself. */
	final peel: (node:QueryNode, ctx:C) -> QueryNode;

	/** Whether `kind` is a field access the host types (`a.b`; a member-lookup host adds `a?.b`, `a!.b`). */
	final isAccess: (kind:String, ctx:C) -> Bool;

	/** The value of a literal whose type `RefShape.literalTypeNames` names `typeName`; null for a host typing none. */
	final literal: Null<(typeName:String, ctx:C) -> Null<T>>;

	/** What the self reference `node` denotes. */
	final self: (node:QueryNode, ctx:C) -> Null<T>;

	/** The binding offset of the value the identifier `ident` reads, or null when it binds none. */
	final binding: (ident:QueryNode, ctx:C) -> Null<Int>;

	/** The type the binding at `from` is written with, or the host otherwise holds for it; null when none. */
	final bound: (from:Int, ctx:C) -> Null<T>;

	/** The expression initialising the binding at `from`, written with no type, as read at `use`: the binding holds its type. */
	final initializer: (from:Int, use:QueryNode, ctx:C) -> Null<QueryNode>;

	/** The element the loop binder at `from` binds, read off what the loop iterates. */
	final loopElement: (from:Int, ctx:C) -> Null<T>;

	/**
	 * The type the lambda parameter at `from`, written with no type and read at `use`, takes from the function type the
	 * lambda is expected to be (`ExpectedTypes.lambdaParamTypes`); null for a host typing none.
	 */
	final parameter: Null<(from:Int, use:QueryNode, ctx:C) -> Null<T>>;

	/** What the identifier `ident`, which binds no value, names. */
	final unbound: (ident:QueryNode, ctx:C) -> Null<T>;

	/** What the field access `node` (an `isAccess` kind with a receiver) reads. */
	final access: (node:QueryNode, ctx:C) -> Null<T>;

	/** The element an index access into a value of type `container` reads; null for a host typing none. */
	final element: Null<(container:T, ctx:C) -> Null<T>>;

	/** What the call `node` returns. */
	final call: (node:QueryNode, ctx:C) -> Null<T>;

	/** What the construction `node` makes; null for a host typing none. */
	final construction: Null<(node:QueryNode, ctx:C) -> Null<T>>;

	/**
	 * What the arithmetic `node` — an operator of `RefShape.arithmeticKinds`, or the negation — yields over
	 * operands of the types `operands`, each typed by the walk; null for a host typing none.
	 */
	final arithmetic: Null<(node:QueryNode, operands:Array<T>, ctx:C) -> Null<T>>;

	/** The binding offsets whose unannotated type the walk is reading right now, against a cycle (`for (x in x)`). */
	final reading: (ctx:C) -> Array<Int>;
}

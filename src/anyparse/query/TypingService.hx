package anyparse.query;

import anyparse.query.GrammarPlugin.CoreValueTypes;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeNameBinding.Tier;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;

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
	 * The language's reading of an inference (`InferencePolicy`): a call's type parameters as the cells `Monomorphs` binds,
	 * a written type as a term, the arcs a unification reads a given type through.
	 */
	public final inference: InferencePolicy;

	/** The name -> declaration layer every name question of the service is answered through (`resolve`). */
	private final _refs: TypeRefIndex;

	/**
	 * Built by the owning `SymbolIndex` over its immutable declaration tables, its grammar's `shape` and which branches the
	 * run's builds compile (`builds`).
	 */
	public function new(
		files: Array<FileInfo>, refs: TypeRefIndex, subtypes: SubtypeGraph, typeSyntax: TypeSyntaxReader, shape: RefShape,
		builds: BuildBranches
	) {
		this.builds = builds;
		_refs = refs;
		ancestors = new AncestorTable(refs, cache, typeSyntax, shape.rawDynamicTypeName);
		casts = new AbstractCasts(refs, ancestors, cache, typeSyntax, shape, builds);
		unification = new Unification(ancestors, cache, refs, casts, shape);
		operators = new OperatorOverloads(casts, unification, shape);
		members = new MemberLookup(refs, cache, ancestors, typeSyntax, shape.optionalValueTypeName, builds);
		calls = new CallSelection(casts, unification, ancestors, typeSyntax);
		structural = new StructuralTypes(files, refs, subtypes, members, typeSyntax, unification);
		extensions = new StaticExtensions(refs, cache, ancestors, members, structural);
		expectations = new ExpectedTypes(shape);
		inference = new HaxeInferencePolicy(casts, refs, ancestors, structural, typeSyntax, shape);
	}

	/**
	 * BODY: the declaration the name `spelling`, written at offset `at` of `file` in a type position or read as a value
	 * (`position`), denotes — or `Unknown` when no tier of the resolution order provably names one declaration of the index:
	 * a type outside it, a tier nothing here reads, a name the compiler resolves to no type. THE question every rule and op
	 * asks of a written name; the order is `TypeNameBinding`'s (`tierOf`, `dottedTierOf`), and a value position takes the
	 * caller's word that the name's head binds no value (`resolveAt` asks it).
	 */
	public function resolve(file: FileInfo, spelling: String, at: Int, position: NamePosition): Resolution {
		final asValue: Bool = position == ValuePosition;
		final tier: Tier = if (spelling.indexOf('.') < 0)
			_refs.names.tierOf(spelling, file, at)
		else if (asValue && headMayReadMember(file, spelling, at))
			Tier.Unknown
		else
			_refs.names.dottedTierOf(spelling, file, asValue, at);
		final one: Null<ResolvedType> = switch tier {
			case Bound(decls): TypeRefIndex.oneDeclaration(decls);
			case Unknown, Free: null;
		};
		return one == null ? Resolution.Unknown : Declared(one);
	}

	/**
	 * Whether the head of `Head.member`, read as a value in `file` at `at`, may read `member` as a field: the type the bare head
	 * binds (`TypeNameBinding.tierOf`, the file's own types and imports included) declares or inherits a member of that name, or
	 * may (4.3.7: an imported `Mod`'s static `Sub` wins over a module `Mod` holding a type `Sub`), or what it binds is unread.
	 * False for any longer path, whose head is a package.
	 */
	private function headMayReadMember(file: FileInfo, spelling: String, at: Int): Bool {
		final dot: Int = spelling.indexOf('.');
		if (spelling.indexOf('.', dot + 1) >= 0) return false;
		final member: String = spelling.substr(dot + 1);
		return switch _refs.names.tierOf(spelling.substr(0, dot), file, at) {
			case Bound(decls): decls.exists(d -> !members.declarationLacksMember(d, member));
			case Unknown: true;
			case Free: false;
		};
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
		final carried: Null<T> = carriedType(node, shape, host, ctx);
		if (carried != null) return carried;
		if ((kind == shape.identKind || kind == shape.stringInterpIdentKind) && name != null)
			return name == shape.selfReferenceText ? host.self(node, ctx) : identifierType(node, shape, host, ctx);
		if (host.isAccess(kind, ctx) && name != null && node.children.length > 0) return host.access(node, ctx);
		final element: Null<(node:QueryNode, container:T, ctx:C) -> Null<T>> = host.element;
		if (kind != shape.indexAccessKind || element == null || node.children.length <= 0)
			return kind == shape.callKind && node.children.length > 0 ? host.call(node, ctx) : composedType(node, shape, host, ctx);
		final container: Null<T> = typeWalk(node.children[0], shape, host, ctx);
		return container == null ? null : element(node, container, ctx);
	}

	/**
	 * The core type the operator of node kind `kind` yields over operands of the core value types `operands`
	 * (`RefShape.coreValueTypes`; null for an operand of any other type), or null: a comparison or a logical operator
	 * (`booleanOperatorKinds`, `notKind`) the `boolean` type; arithmetic over core numbers the integer type when every
	 * operand is one and the operator keeps it (`arithmeticKinds` but `realArithmeticKinds`, the negation), else the real
	 * type; an arithmetic operator that concatenates (`ExecutionShape.concatenationKinds`) over the string type and another
	 * core value the string type (4.3.7 `$type`: `s + 1`, `1 + s`, `s + true` are `String`). No core value type overloads
	 * an operator, so the language's own operator is the one taken.
	 */
	public static function coreOperatorType(kind: String, operands: Array<Null<String>>, shape: RefShape): Null<String> {
		final core: Null<CoreValueTypes> = shape.coreValueTypes;
		if (core == null || operands.contains(null)) return null;
		if ((shape.booleanOperatorKinds ?? []).contains(kind) || kind == shape.notKind) return core.boolean;
		return (shape.arithmeticKinds ?? []).contains(kind) || kind == shape.negationKind
			? coreArithmeticType(kind, operands, core, shape)
			: null;
	}

	/**
	 * Whether the compound assignment of node kind `kind` (`ExecutionShape.compoundAssignOperators`: `a += b`) over operands
	 * of the core value types `operands` is of the type of what it assigns to: the operator it applies yields the target's
	 * core type (`coreOperatorType`; 4.3.7 `$type`: `i += 1` is `Int`, `n += 1` of a `Null<Int>` is `Null<Int>`). False for
	 * any other kind and operand.
	 */
	public static function compoundKeepsTarget(kind: String, operands: Array<Null<String>>, shape: RefShape): Bool {
		final applied: Null<String> = shape.execution?.compoundAssignOperators?.get(kind);
		return applied != null && operands.length == 2 && operands[0] != null && coreOperatorType(applied, operands, shape) == operands[0];
	}

	/**
	 * The type every string literal kind of the grammar is
	 * (`RefShape.stringLiteralKinds`, `literalTypeNames`); null when they disagree.
	 */
	public static function stringType(shape: RefShape): Null<String> {
		final names: Array<String> = [for (k in shape.stringLiteralKinds ?? []) shape.literalTypeNames?.get(k) ?? ''];
		return names.length == 0 || names.contains('') || names.filter(n -> n != names[0]).length > 0 ? null : names[0];
	}

	/**
	 * Whether `node` is an operator the walk types by its operands: a binary `RefShape.arithmeticKinds` or
	 * `booleanOperatorKinds` one, a compound assignment (`ExecutionShape.compoundAssignOperators`), the negation or the
	 * logical not.
	 */
	public static function isArithmetic(node: QueryNode, shape: RefShape): Bool {
		final kind: String = node.kind;
		final binary: Bool = (shape.arithmeticKinds ?? []).contains(kind)
			|| (shape.booleanOperatorKinds ?? []).contains(kind)
			|| shape.execution?.compoundAssignOperators?.exists(kind) == true;
		return binary && node.children.length == 2 || (kind == shape.negationKind || kind == shape.notKind) && node.children.length == 1;
	}

	/**
	 * `resolve` asked of the name written at offset `at` of the indexed `file`, read with `plugin`: a type reference
	 * (`TypeRefShape.typeRefKinds`) in a type position, an identifier or a path of field reads over one as a value — whose
	 * head must bind no value (`ValueDoors.bindsNoValue`). `Unknown` for any other node and a file the index does not hold.
	 */
	public static function resolveAt(index: SymbolIndex, plugin: GrammarPlugin, file: String, at: Int): Resolution {
		final fi: Null<FileInfo> = index.fileInfo(file);
		final source: Null<String> = index.sourceOf(file);
		if (fi == null || source == null) return Resolution.Unknown;
		final root: QueryNode = plugin.parseFileTypeRefs(source);
		final shape: RefShape = plugin.refShape();
		final node: Null<QueryNode> = innermostAt(root, at);
		final name: Null<String> = node?.name;
		if (node == null || name == null) return Resolution.Unknown;
		if (plugin.typeRefShape().typeRefKinds.contains(node.kind)) return index.typing.resolve(fi, name, at, TypePosition);
		final identKind: Null<String> = shape.identKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final path: Null<Array<String>> = identKind == null || fieldKind == null ? null : NominalTypes.pathOf(node, identKind, fieldKind);
		var head: QueryNode = node;
		while (head.kind != identKind && head.children.length == 1) head = head.children[0];
		final headSpan: Null<Span> = head.span;
		if (path == null || headSpan == null) return Resolution.Unknown;
		return ValueDoors.bindsNoValue(head, path[0], headSpan, fi, root, shape, file, index)
			? index.typing.resolve(fi, path.join('.'), at, ValuePosition)
			: Resolution.Unknown;
	}

	/**
	 * `typeWalk` of a value composed of others: a construction (`TypingHost.construction`), a value whose type depends on
	 * what its position expects (`TypingHost.contextual`), an operator over its operands (`arithmeticType`). Null for every
	 * other shape.
	 */
	private static function composedType<T, C>(node: QueryNode, shape: RefShape, host: TypingHost<T, C>, ctx: C): Null<T> {
		final kind: String = node.kind;
		final construction: Null<(node:QueryNode, ctx:C) -> Null<T>> = host.construction;
		if (kind == shape.newExprKind && node.name != null && construction != null) return construction(node, ctx);
		final contextual: Null<(node:QueryNode, ctx:C) -> Null<T>> = host.contextual;
		final dependent: Bool = kind == shape.arrayLiteralKind
			|| kind == shape.objectLiteralKind
			|| kind == shape.ternaryKind
			|| (shape.ifExpressionKinds ?? []).contains(kind);
		return dependent && contextual != null ? contextual(node, ctx) : arithmeticType(node, shape, host, ctx);
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

	/**
	 * The type a shape that is or writes its own type gives `node`: a literal (`RefShape.literalTypeNames`; an integer one
	 * only spelled as the integer type, `spellsAnotherType`), a text segment of an interpolating string the string type; an
	 * ascription `(e : T)`, the type it writes (`TypingHost.ascribed`). Null for any other shape, and for a host
	 * typing that one none.
	 */
	private static function carriedType<T, C>(node: QueryNode, shape: RefShape, host: TypingHost<T, C>, ctx: C): Null<T> {
		final literal: Null<(typeName:String, ctx:C) -> Null<T>> = host.literal;
		final ascribed: Null<(node:QueryNode, ctx:C) -> Null<T>> = host.ascribed;
		final literalType: Null<String> = shape.literalTypeNames?.get(node.kind) ?? (
			node.kind == shape.stringInterpTextKind ? interpolatingStringType(shape) : null
		);
		return if (literalType != null && literal != null && !spellsAnotherType(node, literalType, shape))
			literal(literalType, ctx)
		else if (node.kind == shape.checkTypeKind && node.children.length > 0 && ascribed != null)
			ascribed(node, ctx)
		else
			null;
	}

	/**
	 * Whether the literal `node`, which the grammar maps to the integer type (`CoreValueTypes.integer`), is one the compiler
	 * types as another: its text, `_` dropped, neither decimal digits nor `CoreValueTypes.hexLiteralPrefix` and hex digits (a
	 * suffix), or a decimal number past `CoreValueTypes.integerMax`. The walk gives such a literal no type.
	 */
	private static function spellsAnotherType(node: QueryNode, typeName: String, shape: RefShape): Bool {
		final core: Null<CoreValueTypes> = shape.coreValueTypes;
		if (core == null || typeName != core.integer) return false;
		var digits: String = (node.name ?? '').split('_').join('');
		final hex: Null<String> = core.hexLiteralPrefix;
		if (hex != null && digits.startsWith(hex)) return !~/^[0-9A-Fa-f]+$/.match(digits.substr(hex.length));
		if (!~/^[0-9]+$/.match(digits)) return true;
		final max: Null<String> = core.integerMax;
		while (digits.length > 1 && digits.charAt(0) == '0') digits = digits.substr(1);
		return max != null && (digits.length > max.length || digits.length == max.length && digits > max);
	}

	/**
	 * The type a text segment of an interpolating string carries (`RefShape.stringInterpTextKind`): the one
	 * `RefShape.literalTypeNames` gives every interpolating string literal kind, a piece of whose text it is. Null when
	 * they name none or disagree.
	 */
	private static function interpolatingStringType(shape: RefShape): Null<String> {
		final names: Array<String> = [
			for (k in shape.interpolatingStringKinds ?? []) shape.literalTypeNames?.get(k) ?? ''
		];
		return names.length == 0 || names.contains('') || names.filter(n -> n != names[0]).length > 0 ? null : names[0];
	}

	/**
	 * `coreOperatorType` of the arithmetic operator `kind` over the core value types `operands`: the string type for a
	 * concatenation with a string operand, the integer or real type over core numbers, null otherwise.
	 */
	private static function coreArithmeticType(
		kind: String, operands: Array<Null<String>>, core: CoreValueTypes, shape: RefShape
	): Null<String> {
		final text: Null<String> = stringType(shape);
		final concatenates: Bool = (shape.execution?.concatenationKinds ?? []).contains(kind) && operands.length == 2;
		if (text != null && concatenates && operands.contains(text)) return text;
		var integral: Bool = !(shape.realArithmeticKinds ?? []).contains(kind);
		for (o in operands) {
			if (o != core.integer && o != core.real) return null;
			if (o != core.integer) integral = false;
		}
		return integral ? core.integer : core.real;
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

	/** The deepest node of `node`'s tree whose span holds offset `at`, or null when none does. */
	private static function innermostAt(node: QueryNode, at: Int): Null<QueryNode> {
		final span: Null<Span> = node.span;
		if (span != null && (at < span.from || at >= span.to)) return null;
		for (c in node.children) {
			final inner: Null<QueryNode> = innermostAt(c, at);
			if (inner != null) return inner;
		}
		return span == null ? null : node;
	}

}

/** Where a name is written, as `TypingService.resolve` reads it. */
enum NamePosition {

	/** A type reference: an annotation, a type argument, a supertype, a construction's type. */
	TypePosition;

	/** An expression reading the name as a value, or as the head of a path of field reads (`Mod.Sub.f()`). */
	ValuePosition;

}

/** What a written name denotes (`TypingService.resolve`): the compiler's answer, or none — never another one. */
enum Resolution {

	/** The one declaration of the index the name denotes. */
	Declared(decl: ResolvedType);

	/** Nothing proves one declaration of the index: a type outside it, a tier nothing here reads, a name naming no type. */
	Unknown;

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

	/**
	 * The type the ascription `node` (`RefShape.checkTypeKind`, `(e : T)`) gives the value it holds: the type it writes,
	 * which the value is checked against; null for a host typing none.
	 */
	final ascribed: Null<(node:QueryNode, ctx:C) -> Null<T>>;

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

	/** The element the index access `node` into a value of type `container` reads; null for a host typing none. */
	final element: Null<(node:QueryNode, container:T, ctx:C) -> Null<T>>;

	/** What the call `node` returns. */
	final call: (node:QueryNode, ctx:C) -> Null<T>;

	/** What the construction `node` makes; null for a host typing none. */
	final construction: Null<(node:QueryNode, ctx:C) -> Null<T>>;

	/**
	 * What the value `node` whose type depends on what its position expects makes — an array or object literal
	 * (`RefShape.arrayLiteralKind`, `objectLiteralKind`), a conditional (`ternaryKind`, `ifExpressionKinds`); null for a host
	 * typing none.
	 */
	final contextual: Null<(node:QueryNode, ctx:C) -> Null<T>>;

	/**
	 * What the operator `node` — of `RefShape.arithmeticKinds` or `booleanOperatorKinds`, a compound assignment, the negation
	 * or the logical not — yields over operands of the types `operands`, each typed by the walk; null for a host typing none.
	 */
	final arithmetic: Null<(node:QueryNode, operands:Array<T>, ctx:C) -> Null<T>>;

	/** The binding offsets whose unannotated type the walk is reading right now, against a cycle (`for (x in x)`). */
	final reading: (ctx:C) -> Array<Int>;
}

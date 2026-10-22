package anyparse.query;

import anyparse.query.AbstractCasts.TypeEnd;
import anyparse.query.CallReturns.WrittenParameter;
import anyparse.query.ExpectedTypes.ExpectationHost;
import anyparse.query.GrammarPlugin.CoreValueTypes;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NominalTypes.IndexTyping;
import anyparse.query.NominalTypes.WrittenConstruction;
import anyparse.query.OperatorOverloads.OperatorResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;

/**
 * The index host's arcs over a value the walk composes of others (`NominalTypes`, `TypingService.typeWalk`): a
 * construction, an element read by index, an operator over its operands, an array or object literal, the element a loop
 * over an interval binds and an enum-abstract value read off its type — each the type Haxe 4.3.7 gives it, in the written
 * source currency, or null.
 */
@:nullSafety(Strict)
@:access(anyparse.query.NominalTypes)
final class ComposedValues {

	/**
	 * The type the construction `node` (`new T<…>(…)`) makes, for the index host: the type it writes, resolved where it is
	 * written, the trailing arguments it leaves out its defaults (`completedType`; 4.3.7 `$type`: `new Box<Int>()` is
	 * `Box<Int>`, `new Two<Int>()` of `Two<A, B = Item>` `Two<Int, Item>`) — where the file resolves the name to several
	 * declarations (a std type a target's `_std` copy re-declares), as written when every one of them takes exactly the
	 * arguments it writes. Null for a type parameter's name (a generic function's `new T()` makes what its call binds), a
	 * generic type written with no argument (`new Box(item)`, a `Box<Item>` nothing spells; `new Def()`, a monomorph the code
	 * binds later, defaults or none), a generic type a build macro may make another type of, and a name the file resolves to
	 * no declaration.
	 */
	public static function indexConstruction(node: QueryNode, c: IndexTyping): Null<String> {
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		final at: Null<Span> = node.span;
		final written: Null<WrittenConstruction> = NominalTypes.writtenConstruction(node, c.shape, c.chain.source);
		if (index == null || fi == null || at == null || written == null) return null;
		if (NominalTypes.writtenTypeParams(fi).contains(written.path) || !NominalTypes.answerableType(written.text, c.chain.typeSyntax))
			return null;
		final decls: Array<ResolvedType> = index.refs.resolveTypeRefAll(written.path, fi, at.from);
		final arity: Int = written.args.length;
		// a build macro may make each application of a generic type a type of its own (`@:genericBuild`)
		if (decls.length == 0 || decls.exists(d -> d.type.hasBuild && d.type.typeParamArity > 0)) return null;
		// written with no argument, a generic type's are monomorphs even where it declares defaults (4.3.7: `new Def()` of
		// `Def<T = Item>` is a `Def<?>` the code binds later); the defaults fill only the arguments a reference leaves out
		if (arity == 0 && decls.exists(d -> d.type.typeParamArity > 0)) return null;
		if (decls.length == 1) return NominalTypes.completedType(written.text, at.from, c);
		return decls.foreach(d -> d.type.typeParamArity == arity) ? written.text : null;
	}

	/**
	 * The element the index access `node` reads off a value of the type `container`, for the index host (`calls.ml`,
	 * `array_access`), a `Null<…>` around the container peeled (4.3.7 types `a[0]` of a `Null<Array<Int>>` as `Int`): an
	 * array's element (`RefShape.arrayTypeNames`, the std type no project type shadows), else what the read access of the
	 * abstract the container names takes returns (`OperatorOverloads.indexRead`), its type parameters bound to the
	 * container's arguments — every declaration the reading file may resolve the name to (a std type a target's `_std` copy
	 * re-declares), as the walk resolves a receiver's type, else every declaration of the name, agreeing. Null otherwise: a
	 * dynamic value's element is a monomorph.
	 */
	public static function indexElement(node: QueryNode, container: String, c: IndexTyping): Null<String> {
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		final syntax: TypeSyntaxReader = c.chain.typeSyntax;
		if (index == null || fi == null || !NominalTypes.answerableType(container, syntax)) return null;
		final peeled: String = NominalTypes.memberLookupReceiverSource(container, c.shape.memberTransparentWrapperTypeNames ?? [], syntax);
		final path: Null<String> = NominalTypes.outerPathOf(peeled, [], syntax);
		final args: Array<String> = NominalTypes.typeArgumentSourcesOf(peeled, syntax) ?? [];
		if (path == null) return null;
		final head: String = SourceText.lastSegment(path);
		if ((c.shape.arrayTypeNames ?? []).contains(head))
			return args.length == 1 && !NominalTypes.shadowedByNonStdType(index, head) ? args[0] : null;
		final key: Null<TypeEnd> = node.children.length == 2
			? coreEnd(TypingService.typeWalk(node.children[1], c.shape, NominalTypes.INDEX_HOST, c), c)
			: null;
		final meant: Array<ResolvedType> = index.refs.resolveTypeRefAll(path, fi, node.span?.from);
		final decls: Array<ResolvedType> = meant.length == 0 ? index.refs.resolvedDeclsNamed(head) : meant;
		var found: Null<String> = null;
		for (decl in decls) {
			final read: Null<MemberInfo> = index.typing.operators.indexRead(decl, key);
			final returned: Null<String> = read?.returnSource;
			final element: Null<String> = read == null || returned == null
				? null
				: index.typing.ancestors.boundType(decl, decl, args, returned, read.declFrom, read.typeParamNames);
			if (element == null || found != null && found != element) return null;
			found = element;
		}
		return found;
	}

	/**
	 * The type the operator `node` yields over operands of the types `operands`, for the index host: the language's own
	 * operator over core value types (`TypingService.coreOperatorType`, each operand's `Null<…>` peeled: 4.3.7 types `n + 1`
	 * of a `Null<Int>` as `Int`) — a compound assignment the type of its target (`TypingService.compoundKeepsTarget`) —,
	 * else what an abstract's overload of a binary operator yields (`OperatorOverloads.binaryResult`) over operands each
	 * naming one declaration. Null otherwise.
	 */
	public static function indexArithmetic(node: QueryNode, operands: Array<String>, c: IndexTyping): Null<String> {
		final index: Null<SymbolIndex> = c.index;
		if (index == null) return null;
		final cores: Array<Null<String>> = [for (o in operands) coreTypeOf(o, c)];
		if (c.shape.execution?.compoundAssignOperators?.exists(node.kind) == true)
			return TypingService.compoundKeepsTarget(node.kind, cores, c.shape) ? operands[0] : null;
		final core: Null<String> = TypingService.coreOperatorType(node.kind, cores, c.shape);
		return core ?? operatorOverload(node, operands, c)?.text;
	}

	/**
	 * The element a loop over the interval `interval` binds (`a...b`, `forLoop.ml`: an `IntIterator` over two values of the
	 * integer type binds the integer type), for the index host: the integer type when the walk types both bounds as it. Null
	 * otherwise.
	 */
	public static function intervalElement(interval: QueryNode, c: IndexTyping): Null<String> {
		final integer: Null<String> = c.shape.coreValueTypes?.integer;
		if (integer == null || interval.children.length != 2) return null;
		for (bound in interval.children) {
			final t: Null<String> = TypingService.typeWalk(bound, c.shape, NominalTypes.INDEX_HOST, c);
			if (t == null || coreTypeOf(t, c) != integer) return null;
		}
		return integer;
	}

	/**
	 * A value of an enum abstract read off its type's name (`E.A`, the path `path` of a root `root` binding no value), for the
	 * index host: the abstract as the path writes it, where every branch of it some build compiles declares `A` with no
	 * written type (`AbstractCasts.holdsUntypedValue`; 4.3.7 types `E.A` as `E`). Null otherwise.
	 */
	public static function enumAbstractValue(path: Array<String>, root: QueryNode, c: IndexTyping): Null<String> {
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		final at: Null<Span> = root.span;
		if (index == null || fi == null || at == null || path.length != 2 || !TypeResolver.receiverRootIsUnboundType(root, c.root, c.shape))
			return null;
		final decl: Null<ResolvedType> = index.refs.resolveTypeRef(path[0], fi, at.from);
		return decl != null && index.typing.casts.holdsUntypedValue(decl, path[1]) ? path[0] : null;
	}

	/**
	 * The type the value `node` whose type depends on what its position expects makes, for the index host (`typer.ml`
	 * `type_array_decl`, `type_object_decl`, `EIf`): where nothing is expected of it (`expectsNothing`, or an expectation of
	 * none), the type its parts give it (`partsType`, `branchesType`); where a type is expected of a literal (`ExpectedTypes`
	 * over `EXPECTATIONS`), the type that expectation picks (`expectedType`). Null where what is expected is not read, and
	 * for a conditional something is expected of (its type is the expected one, cast to).
	 */
	public static function indexContextual(node: QueryNode, c: IndexTyping): Null<String> {
		final conditional: Bool = node.kind == c.shape.ternaryKind || (c.shape.ifExpressionKinds ?? []).contains(node.kind);
		final expected: Null<Expectation> = expectsNothing(node, c) ? { text: '', file: null, free: true } : expectationOf(node, c);
		return if (expected == null)
			null
		else if (expected.free)
			conditional ? branchesType(node, c) : partsType(node, c)
		else if (conditional)
			null
		else
			expectedType(node, expected, c);
	}

	/**
	 * The `@:op` overload the binary operator `node` takes between operands of the types `operands`, as the index reads it
	 * (`OperatorOverloads.binaryResult`): null where it decides none, a core operation included.
	 */
	public static function operatorOverload(node: QueryNode, operands: Array<String>, c: IndexTyping): Null<OperatorResult> {
		final index: Null<SymbolIndex> = c.index;
		if (index == null || operands.length != 2) return null;
		final left: Null<TypeEnd> = operandEnd(operands[0], index, c);
		final right: Null<TypeEnd> = operandEnd(operands[1], index, c);
		return left == null || right == null ? null : index.typing.operators.binaryResult(node.kind, left, right);
	}

	/**
	 * What `ExpectedTypes` asks the index host of a literal's position: the written type expected of it, as the file writing
	 * it reads it, or none (`Expectation.free`, a value of its own). A position it does not read — an assignment, a `return`,
	 * an argument the signature does not decide — expects nothing it can tell, so null. Built per question, so no static of
	 * this class reads the index host back while the statics initialize.
	 */
	private static function expectationHost(): ExpectationHost<Expectation, IndexTyping> {
		return {
			declared: declaredExpectation,
			assigned: (_, _) -> null,
			returned: (_, _) -> null,
			argument: (call, at, _, c) -> argumentExpectation(call, at, c),
			element: elementExpectation,
			field: fieldExpectation,
			read: (written, c) -> written.free ? null : c.chain.typeSyntax(written.text),
			part: (of, text, _) -> {text: text, file: of.file, free: false }
		};
	}

	/**
	 * The type the conditional `node` (`c ? a : b`, `if (c) a else b`) makes as a value of its own (`unify_min` over its two
	 * branches, `unifiedType`); null for one with no `else` and a branch the walk does not type.
	 */
	private static function branchesType(node: QueryNode, c: IndexTyping): Null<String> {
		if (node.children.length != 3) return null;
		final branches: Array<String> = [];
		for (branch in node.children.slice(1)) {
			final t: Null<String> = TypingService.typeWalk(branch, c.shape, NominalTypes.INDEX_HOST, c);
			if (t == null) return null;
			branches.push(t);
		}
		return unifiedType(branches, c);
	}

	/**
	 * The type the literal `node` makes of its parts' types, each typed as a value of its own: an array of the one type every
	 * element has — over core numbers the real type when one is (`unify_min`) —, a structure of each field as its value types
	 * it. Null for an empty literal, a part the walk does not type, elements of several types and a field whose name is no
	 * identifier.
	 */
	private static function partsType(node: QueryNode, c: IndexTyping): Null<String> {
		final object: Bool = node.kind == c.shape.objectLiteralKind;
		// an empty literal's element is a monomorph, an empty object a structure of no field
		if (node.children.length == 0) return null;
		final names: Array<String> = [];
		final parts: Array<String> = [];
		for (child in node.children) {
			final name: Null<String> = object ? fieldName(child, c.shape) : '';
			final value: Null<QueryNode> = object ? child.children[0] : child;
			final t: Null<String> = name == null || value == null
				? null
				: TypingService.typeWalk(value, c.shape, NominalTypes.INDEX_HOST, c);
			if (name == null || t == null) return null;
			names.push(name);
			parts.push(t);
		}
		return object ? '{${[for (i in 0...names.length) '${names[i]}: ${parts[i]}'].join(', ')}}' : arrayOf(parts, c);
	}

	/**
	 * The type the literal `node` makes where the type `expected` is expected of it (`type_array_decl`,
	 * `type_object_decl`), a `Null<…>` around it peeled: under the dynamic type, an array of it, and an object of its parts'
	 * types (its fields typed as values); under an array type, that type; under a structure of plain fields
	 * (`structureFields`), the structure of the fields it writes, each of the type its value has there, and of the optional
	 * ones it leaves out (`expectedStructure`). Null under any other type, and for a comprehension.
	 */
	private static function expectedType(node: QueryNode, expected: Expectation, c: IndexTyping): Null<String> {
		final shape: RefShape = c.shape;
		final object: Bool = node.kind == shape.objectLiteralKind;
		final loops: Array<String> = (shape.iterationBindingKinds ?? []).concat([for (k in [shape.whileExprKind]) if (k != null) k]);
		if (!object && node.children.length == 1 && loops.contains(node.children[0].kind)) return null;
		// a literal of map entries is a map (`haxe.ds.Map`), whatever is expected of it
		if (!object && node.children.exists(e -> e.kind == shape.mapLiteralEntryKind)) return null;
		final syntax: TypeSyntaxReader = c.chain.typeSyntax;
		final peeled: String = NominalTypes.memberLookupReceiverSource(
			expected.text, shape.memberTransparentWrapperTypeNames ?? [], syntax
		);
		final array: Null<String> = (shape.arrayTypeNames ?? [])[0];
		final dyn: Null<String> = shape.rawDynamicTypeName;
		if (dyn != null && peeled.trim() == dyn) return if (object)
			partsType(node, c)
		else if (array == null)
			null
		else
			'$array<$dyn>';
		if (!object) return arrayElementOf(peeled, c) == null ? null : peeled;
		final fields: Null<Array<MemberInfo>> = structureFields(peeled, expected.file, c);
		// the fields' types are written in the file declaring the structure
		final host: Null<ResolvedType> = fields == null ? null : structureDecl(peeled, expected.file, c);
		return fields == null || host == null ? null : expectedStructure(node, fields, host.file, c);
	}

	/**
	 * The structure the object literal `node` makes against a structure of the plain `fields` (`type_object_decl`, as 4.3.7
	 * prints it): each field it writes of the type its value has there — the field's own type, a `Null<…>` apart, or the
	 * literal it is typed as —, each optional field it leaves out as the structure writes it. Null for a field it writes that
	 * the structure does not declare, one it leaves out that is not optional, and a value of another type (a cast the
	 * compiler makes there).
	 */
	private static function expectedStructure(node: QueryNode, fields: Array<MemberInfo>, file: FileInfo, c: IndexTyping): Null<String> {
		final shape: RefShape = c.shape;
		final written: Map<String, QueryNode> = [];
		for (child in node.children) {
			final name: Null<String> = fieldName(child, shape);
			if (name == null || !fields.exists(f -> f.name == name)) return null;
			written[name] = child.children[0];
		}
		final parts: Array<String> = [];
		for (f in fields) {
			final value: Null<QueryNode> = written[f.name];
			final fieldType: String = f.typeSource ?? '';
			if (value == null) {
				if (!f.optional) return null;
				parts.push('?${f.name}: $fieldType');
				continue;
			}
			// a written optional field holds the optional value's type (4.3.7: `?b: Int` written `b: 2` is `b: Null<Int>`)
			final declared: String = f.optional
				? NominalTypes.optionalValueType(fieldType, shape.optionalValueTypeName, c.chain.typeSyntax)
				: fieldType;
			final shown: Null<String> = writtenFieldType(value, declared, file, c);
			if (shown == null) return null;
			parts.push('${f.name}: $shown');
		}
		return '{${parts.join(', ')}}';
	}

	/**
	 * The type a structure field of the type `declared` holds where an object literal writes `value` for it, as 4.3.7 prints
	 * the literal (`type_fields`): the value's own type where it is spelled as the field's, and a literal typed against the
	 * field — under the dynamic type the field's, the literal cast to it; of one core value type, the nullable spelling of the
	 * two (`Int` written for `Null<Int>` and `Null<Int>` for an optional `Int` both hold a `Null<Int>`) — of one the language
	 * declares as a class (`String`), the value's, a class being nullable already —; the declared type where the compiler
	 * casts a value of another core type to it (`Int` written for `Float` or `Null<Float>`), and where a function literal is
	 * typed against a function type. A `T` written for a `Null<T>` keeps its type where a `T` may be null already (a class's,
	 * an enum's, a structure's: `nullableValue`), else holds the `Null<T>`. Null otherwise.
	 */
	private static function writtenFieldType(value: QueryNode, declared: String, file: FileInfo, c: IndexTyping): Null<String> {
		final shape: RefShape = c.shape;
		final bare: QueryNode = BoolExprShape.unwrapParens(value, shape.parenKind);
		final functions: Array<String> = (shape.lambdaKinds ?? []).concat([for (k in [shape.fnExprKind]) if (k != null) k]);
		if (functions.contains(bare.kind)) return c.chain.typeSyntax(declared)?.shape.match(Function(_, _, _)) == true ? declared : null;
		final typed: Null<String> = TypingService.typeWalk(value, shape, NominalTypes.INDEX_HOST, c);
		if (typed == null) return null;
		final literal: Bool = bare.kind == shape.objectLiteralKind || bare.kind == shape.arrayLiteralKind;
		if (literal) return spelled(declared, c) == shape.rawDynamicTypeName ? declared : typed;
		return ~/\s+/g.replace(typed, '') == ~/\s+/g.replace(declared, '') ? typed : heldType(typed, declared, file, c);
	}

	/** The type source `text`, its `Null<…>` wrappers peeled and its whitespace dropped: one spelling of one written type. */
	private static function spelled(text: String, c: IndexTyping): String {
		return ~/\s+/g.replace(
			NominalTypes.memberLookupReceiverSource(text, c.shape.memberTransparentWrapperTypeNames ?? [], c.chain.typeSyntax), ''
		);
	}

	/**
	 * The element type of the type source `text` when it is the std array type (`RefShape.arrayTypeNames`, no project type
	 * shadowing it) applied to one argument; null otherwise.
	 */
	private static function arrayElementOf(text: String, c: IndexTyping): Null<String> {
		return switch c.chain.typeSyntax(text)?.shape {
			case Nominal(path, [element]) if (
				(c.shape.arrayTypeNames ?? []).contains(path) && !NominalTypes.shadowedByNonStdType(c.index, path)
			):
				element.text;
			case _: null;
		};
	}

	/**
	 * The fields of the structure the type source `text`, written in `file`, names — a `typedef` of an anonymous structure,
	 * through plain alias hops, with no type parameter, no supertype, one `#if` branch, written in plain fields alone
	 * (`RefShape.plainStructureFieldKinds`) — in declaration order; null for any other type.
	 */
	private static function structureFields(text: String, file: Null<FileInfo>, c: IndexTyping): Null<Array<MemberInfo>> {
		final decl: Null<ResolvedType> = structureDecl(text, file, c);
		final plain: Array<String> = c.shape.plainStructureFieldKinds ?? [];
		if (decl == null || !decl.type.isAnonStruct || decl.type.typeParamArity > 0 || decl.type.supertypes.length > 0) return null;
		if (decl.type.branches.length > 1 || decl.type.members.length == 0) return null;
		final members: Array<MemberInfo> = decl.type.members;
		return members.foreach(m -> plain.contains(m.kind) && m.typeSource != null && !m.guarded) ? members : null;
	}

	/**
	 * The declaration the type source `text`, written in `file` with no type argument, resolves to there, through its plain
	 * `typedef` alias hops (`AncestorTable.aliasTarget`), each with no type parameter; null for any other type.
	 */
	private static function structureDecl(text: String, file: Null<FileInfo>, c: IndexTyping): Null<ResolvedType> {
		final index: Null<SymbolIndex> = c.index;
		final path: Null<String> = switch c.chain.typeSyntax(text)?.shape {
			case Nominal(path, args) if (args.length == 0): path;
			case _: null;
		};
		return index == null || file == null || path == null ? null : throughAliases(index.refs.resolveTypeRef(path, file), index);
	}

	/**
	 * What the declaration `holder` expects of its initializer: the type it is written with in this file, or — a local written
	 * with none, whose monomorph takes the initializer's type — none. Null for any other declaration written with none.
	 */
	private static function declaredExpectation(holder: QueryNode, c: IndexTyping): Null<Expectation> {
		final from: Int = holder.span?.from ?? -1;
		final written: Null<String> = c.chain.declaredTypeSources[from];
		final local: Bool = (c.shape.localDeclKinds ?? []).contains(holder.kind);
		return if (written != null)
			{ text: written, file: c.index?.fileInfo(c.file), free: false }
		else if (local && !c.declaredTypes.exists(from))
			{ text: '', file: null, free: true }
		else
			null;
	}

	/**
	 * What the argument `at` of the call `node` is expected to be: the type of the parameter it binds where the typing
	 * service selects the signature (`CallReturns.selectedParameter`) — the callee a bare call's enclosing type declares, a
	 * method of a value's type, a static of a type name — as the callee's file writes it. Null for any other call and callee.
	 */
	private static function argumentExpectation(node: QueryNode, at: Int, c: IndexTyping): Null<Expectation> {
		final index: Null<SymbolIndex> = c.index;
		final shape: RefShape = c.shape;
		final callee: Null<QueryNode> = node.kind == shape.callKind ? node.children[0] : null;
		final method: Null<String> = callee?.name;
		if (index == null || callee == null || method == null) return null;
		final receiver: Null<QueryNode> = callee.kind == shape.fieldAccessKind && callee.children.length == 1 ? callee.children[0] : null;
		final owner: Null<TypeDeclMatch> = callee.kind == shape.identKind ? NominalTypes.bareCallOwner(callee, c.root, shape) : null;
		final param: Null<WrittenParameter> = if (owner != null)
			CallReturns.selectedParameter(node, CallReturns.ownDeclaration(owner, index, c.file), method, null, at, c)
		else if (receiver != null)
			receiverParameter(node, receiver, method, at, index, c)
		else
			null;
		return param == null ? null : { text: param.text, file: param.file, free: false };
	}

	/**
	 * `argumentExpectation` of a call `<receiver>.method(…)`: on a value, every declaration of its type's name agreeing; on a
	 * type name, a static of the declaration the file writes.
	 */
	private static function receiverParameter(
		node: QueryNode, receiver: QueryNode, method: String, at: Int, index: SymbolIndex, c: IndexTyping
	): Null<WrittenParameter> {
		final typed: Null<String> = NominalTypes.expressionNominalWalk(
			receiver, c.root, c.shape, c.declaredTypes, index, c.file, c.chain, [], true
		);
		if (typed != null) return CallReturns.selectedParameter(node, index.refs.resolvedDeclsNamed(typed), method, false, at, c);
		final typeName: Null<String> = NominalTypes.staticReceiverName(receiver, c.root, c.shape, index);
		return typeName == null
			? null
			: CallReturns.selectedParameter(node, CallReturns.writtenDeclaration(typeName, receiver, index, c.file), method, true, at, c);
	}

	/**
	 * What an array literal of the expected type `container` expects of an element: none of a free one's, the dynamic type
	 * of the dynamic type's, an array type's element type; null for any other type.
	 */
	private static function elementExpectation(container: Expectation, c: IndexTyping): Null<Expectation> {
		if (container.free) return container;
		final peeled: String = NominalTypes.memberLookupReceiverSource(
			container.text, c.shape.memberTransparentWrapperTypeNames ?? [], c.chain.typeSyntax
		);
		final element: Null<String> = peeled.trim() == c.shape.rawDynamicTypeName ? peeled.trim() : arrayElementOf(peeled, c);
		return element == null ? null : { text: element, file: container.file, free: false };
	}

	/**
	 * What an object literal of the expected type `outer` expects of its field `name`: none of a free one's or the dynamic
	 * type's (each field a value of its own), a structure of plain fields' type of the field (`structureFields`); null for
	 * any other type and a field the structure does not declare.
	 */
	private static function fieldExpectation(outer: Expectation, name: String, c: IndexTyping): Null<Expectation> {
		if (outer.free) return outer;
		final peeled: String = NominalTypes.memberLookupReceiverSource(
			outer.text, c.shape.memberTransparentWrapperTypeNames ?? [], c.chain.typeSyntax
		);
		if (peeled.trim() == c.shape.rawDynamicTypeName) return { text: '', file: null, free: true };
		final field: Null<MemberInfo> = structureFields(peeled, outer.file, c)?.find(f -> f.name == name);
		final written: Null<String> = field?.typeSource;
		return written == null ? null : { text: written, file: outer.file, free: false };
	}

	/**
	 * What is expected of the literal `node` where it is written (`ExpectedTypes.expectedAt` over `EXPECTATIONS`): a type and
	 * the file writing it, or none (the literal a value of its own); null where the engine reads nothing.
	 */
	private static function expectationOf(node: QueryNode, c: IndexTyping): Null<Expectation> {
		final index: Null<SymbolIndex> = c.index;
		final path: Array<QueryNode> = TreePath.pathAround(c.root, node) ?? [];
		if (index == null || path.length < 2) return null;
		final lineage: Array<QueryNode> = path.slice(0, path.length - 1);
		final indices: Array<Int> = [for (i in 0...lineage.length) lineage[i].children.indexOf(path[i + 1])];
		return index.typing.expectations.expectedAt(lineage, indices, lineage.length - 1, expectationHost(), c);
	}

	/**
	 * The core value type (`RefShape.coreValueTypes`) the type source `text` names once its `Null<…>` wrappers are peeled,
	 * when no project type shadows the name; null for any other type.
	 */
	private static function coreTypeOf(text: String, c: IndexTyping): Null<String> {
		final syntax: TypeSyntaxReader = c.chain.typeSyntax;
		final peeled: String = NominalTypes.memberLookupReceiverSource(text, c.shape.memberTransparentWrapperTypeNames ?? [], syntax);
		final name: Null<String> = switch syntax(peeled)?.shape {
			case Nominal(path, args) if (args.length == 0): path;
			case _: null;
		};
		return name != null && (c.shape.coreValueTypes?.names ?? []).contains(name) && !NominalTypes.shadowedByNonStdType(c.index, name)
			? name
			: null;
	}

	/** `coreTypeOf` as an end of the cast graph; null for no type and any other type. */
	private static function coreEnd(text: Null<String>, c: IndexTyping): Null<TypeEnd> {
		final core: Null<String> = text == null ? null : coreTypeOf(text, c);
		return core == null ? null : Core(core);
	}

	/**
	 * The end an operand of the type source `text` stands for where an operator overload is selected: its core value type
	 * (`coreTypeOf`), else — its `Null<…>` peeled, written with no type argument — the one declaration the reading file
	 * resolves its name to, as the walk resolves a receiver's type, else the one declaration of its name, as the cast graph
	 * reads it (`AbstractCasts.declEnd`). Null for any other type, and for a name several declarations may mean.
	 */
	private static function operandEnd(text: String, index: SymbolIndex, c: IndexTyping): Null<TypeEnd> {
		final core: Null<TypeEnd> = coreEnd(text, c);
		if (core != null) return core;
		final peeled: String = NominalTypes.memberLookupReceiverSource(
			text, c.shape.memberTransparentWrapperTypeNames ?? [], c.chain.typeSyntax
		);
		final path: Null<String> = switch c.chain.typeSyntax(peeled)?.shape {
			case Nominal(path, args) if (args.length == 0): path;
			case _: null;
		};
		final fi: Null<FileInfo> = index.fileInfo(c.file);
		final meant: Array<ResolvedType> = path == null || fi == null ? [] : index.refs.resolveTypeRefAll(path, fi);
		final decls: Array<ResolvedType> = meant.length > 0 || path == null
			? meant
			: index.refs.resolvedDeclsNamed(SourceText.lastSegment(path));
		return decls.length == 1 ? index.typing.casts.declEnd(decls[0]) : null;
	}

	/** The name of the object-literal field `field`, holding one value, when it is an identifier; null otherwise. */
	private static function fieldName(field: QueryNode, shape: RefShape): Null<String> {
		final name: Null<String> = field.name;
		return field.kind == shape.objectFieldKind && field.children.length == 1 && name != null && SourceText.isIdentifier(name)
			? name
			: null;
	}

	/** The array type of the element types `parts` (`unifiedType`); null where they unify to no one type. */
	private static function arrayOf(parts: Array<String>, c: IndexTyping): Null<String> {
		final array: Null<String> = (c.shape.arrayTypeNames ?? [])[0];
		final element: Null<String> = unifiedType(parts, c);
		return array == null || element == null ? null : '$array<$element>';
	}

	/**
	 * The one type values of the types `parts` take together, as `unify_min` picks it where they agree: the type every one
	 * has; else, every one a core number or a nullable one, the real type when one is real, else the integer type, a
	 * nullable one making it nullable (4.3.7: `[n, 1]` of a `Null<Int>` is `Array<Null<Int>>`, `[n, 1.0]`
	 * `Array<Null<Float>>`). Null for several other types.
	 */
	private static function unifiedType(parts: Array<String>, c: IndexTyping): Null<String> {
		final core: Null<CoreValueTypes> = c.shape.coreValueTypes;
		final spelled: Array<String> = [for (p in parts) ~/\s+/g.replace(p, '')];
		if (core == null || parts.length == 0) return null;
		if (spelled.foreach(s -> s == spelled[0])) return parts[0];
		final numbers: Array<Null<String>> = [for (p in parts) coreTypeOf(p, c)];
		if (!numbers.foreach(n -> n == core.integer || n == core.real)) return null;
		final base: String = numbers.contains(core.real) ? core.real : core.integer;
		final wrapper: Null<String> = c.shape.optionalValueTypeName;
		final nullable: Bool = parts.exists(p -> NominalTypes.outerNominalOf(p, c.chain.typeSyntax) == wrapper);
		return if (!nullable)
			base
		else if (wrapper == null)
			null
		else
			'$wrapper<$base>';
	}

	/**
	 * Whether no type is expected of the literal `node` where it is written (`typer.ml` types it as a value of its own): the
	 * initializer of a local written with no type (its monomorph takes the literal's type), the iterable of a loop, the
	 * receiver of a field access, through parentheses, or a part of a literal no type is expected of.
	 */
	private static function expectsNothing(node: QueryNode, c: IndexTyping): Bool {
		final shape: RefShape = c.shape;
		final parent: Null<QueryNode> = parentOf(node, c.root);
		final kind: String = parent?.kind ?? '';
		return if (parent == null)
			false
		else if (kind == shape.parenKind || kind == shape.arrayLiteralKind)
			expectsNothing(parent, c)
		else if (kind == shape.objectFieldKind)
			parentOf(parent, c.root)?.kind == shape.objectLiteralKind && expectsNothing(parentOf(parent, c.root) ?? parent, c)
		else if ((shape.localDeclKinds ?? []).contains(kind))
			CtorFieldFold.declInitializer(parent, shape) == node && !annotatedAt(parent, c)
		else if ((shape.iterationBindingKinds ?? []).contains(kind))
			NominalTypes.iterationIterable(parent, shape.iterationValueBinderKinds ?? []) == node
		else
			(kind == shape.fieldAccessKind || kind == shape.nullSafeAccessKind) && parent.children[0] == node;
	}

	/** The node of `root` holding `node` as a child, searched only where its range lies; null for none. */
	private static function parentOf(node: QueryNode, root: QueryNode): Null<QueryNode> {
		final at: Null<Span> = node.span;
		return at == null ? null : TreePath.firstAround(root, at, n -> n.children.contains(node));
	}

	/** Whether the declaration `decl` is written with a type. */
	private static function annotatedAt(decl: QueryNode, c: IndexTyping): Bool {
		final from: Int = decl.span?.from ?? -1;
		return from < 0 || c.chain.declaredTypeSources.exists(from) || c.declaredTypes.exists(from);
	}

	/**
	 * Whether a value of the type `text`, written in `file`, may be null by itself (4.3.7 `is_nullable`), which decides what a
	 * written optional field of it holds: an object — of a class, an interface or an enum (`typeValueTypeNames`), a
	 * structure, the dynamic type, a core value type the language declares as a class, the built-in array — may (the field
	 * holds the value's type); a core value type the compiler represents itself and a function type may not (it holds
	 * `Null<T>`). Null for anything else, an abstract included: it is what it wraps unless it says `@:notNull`.
	 */
	private static function nullableValue(text: String, file: FileInfo, c: IndexTyping): Null<Bool> {
		final shape: RefShape = c.shape;
		final index: Null<SymbolIndex> = c.index;
		final path: Null<String> = switch c.chain.typeSyntax(text)?.shape {
			case Function(_, _, _): return false;
			case Structure(_): return true;
			case Nominal(path, _): path;
			case _: null;
		};
		if (path == null || index == null || path == shape.optionalValueTypeName) return null;
		if (path == shape.rawDynamicTypeName) return true;
		final classes: Array<String> = (shape.coreValueTypes?.classNames ?? []).concat(shape.arrayTypeNames ?? []);
		if ((shape.coreValueTypes?.names ?? []).contains(path) || classes.contains(path))
			return NominalTypes.shadowedByNonStdType(index, path) ? null : classes.contains(path);
		final decl: Null<ResolvedType> = throughAliases(index.refs.resolveTypeRef(path, file), index);
		final objects: Map<String, String> = shape.typeValueTypeNames ?? [];
		return decl != null && (decl.type.isAnonStruct || objects.exists(decl.type.kind)) ? true : null;
	}

	/**
	 * The type a field of the type `declared`, written in `file`, holds where a value of the type `typed`, spelled apart from
	 * it, is written for it (`writtenFieldType`): for a `Null<T>` field, a `T` value's own type where a `T` may be null
	 * already (`nullableValue`: `type_eq` takes the two as one), else the `Null<T>`; between core value types, the rules
	 * `writtenFieldType` names. Null otherwise.
	 */
	private static function heldType(typed: String, declared: String, file: FileInfo, c: IndexTyping): Null<String> {
		final shape: RefShape = c.shape;
		final cores: Array<String> = shape.coreValueTypes?.names ?? [];
		final given: String = spelled(typed, c);
		final wrapper: Null<String> = shape.optionalValueTypeName;
		final inner: String = wrapper == null ? declared : NominalTypes.memberLookupReceiverSource(declared, [wrapper], c.chain.typeSyntax);
		if (
			inner != declared && ~/\s+/g.replace(typed, '') == ~/\s+/g.replace(inner, '') && !cores.contains(given)
		) return switch nullableValue(inner, file, c) {
			case true: typed;
			case false: declared;
			case null: null;
		};
		final wanted: String = spelled(declared, c);
		final nullable: String -> Bool = t -> NominalTypes.outerNominalOf(t, c.chain.typeSyntax) == wrapper;
		final classes: Array<String> = shape.coreValueTypes?.classNames ?? [];
		return if (!cores.contains(given) || !cores.contains(wanted))
			null
		else if (given == wanted)
			nullable(typed) || classes.contains(given) ? typed : declared
		else if (nullable(typed))
			null
		else
			declared;
	}

	/**
	 * `decl` with the typedefs that name another declaration followed to it, stopping at a structure; null through a generic
	 * typedef, a cycle, or a target the index does not resolve.
	 */
	private static function throughAliases(decl: Null<ResolvedType>, index: SymbolIndex): Null<ResolvedType> {
		var at: Null<ResolvedType> = decl;
		final seen: Array<String> = [];
		while (at != null && at.type.aliasTargetRaw != null && !at.type.isAnonStruct) {
			if (at.type.typeParamArity > 0 || !index.refs.markSeen(at, seen)) return null;
			at = index.typing.ancestors.aliasTarget(at);
		}
		return at;
	}

}

/**
 * What the index host reads as expected of a literal (`ComposedValues.EXPECTATIONS`): the type `text` written in `file`, or
 * none (`free`: the literal is typed as a value of its own, `text` and `file` unread).
 */
typedef Expectation = {
	final text: String;
	final file: Null<FileInfo>;
	final free: Bool;
}

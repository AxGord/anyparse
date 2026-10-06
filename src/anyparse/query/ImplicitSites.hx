package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using Lambda;

/**
 * The places in code where the language runs a member IMPLICITLY — the positive, syntactic half of the question
 * which implicitly-called members a reach walk must admit. A member of one family runs only from a site of that
 * family: a string conversion (`ExecutionShape.concatenationKinds`, an interpolated expression), a `for … in` over a value
 * that is not an interval, an index access, an operator of a kind some member overloads (a compound assignment applies
 * its binary operator too, `ExecutionShape.compoundAssignOperators`), an object literal,
 * a `throw` (the exception wrapping the compiler adds converts what it throws). Each
 * site carries the static types of the operands the member would run on, as far as the declarations say; a null
 * type means "any", and costs the whole family.
 */
@:nullSafety(Strict)
final class ImplicitSites {

	/** File -> its sites, computed on first demand. */
	private final _byFile: Map<String, Array<ImplicitSite>> = [];

	/** File -> the declared types its bindings carry (`TypeInfoProvider.declaredTypes`), read on first demand. */
	private final _declared: Map<String, Map<Int, String>> = [];

	/** The operator kinds some indexed member overloads: only these can run a member. */
	private final _overloaded: Map<String, Bool> = [];

	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _index: SymbolIndex;

	public function new(plugin: GrammarPlugin, index: SymbolIndex) {
		_plugin = plugin;
		_shape = plugin.refShape();
		_index = index;
		for (fi in index.allFiles()) for (t in fi.types) for (m in t.members) for (k in m.operatorOverloads) _overloaded[k] = true;
	}

	/** Drop what was computed for `file`, whose text changed. */
	public function forget(file: String): Void {
		_byFile.remove(file);
		_declared.remove(file);
	}

	/**
	 * The static type of the expression `node` of `tree` (the text of `file` is `source`), as far as the declarations
	 * say: a literal's, the enclosing type for the self reference, a declared binding's or field path's, a call
	 * chain's declared return. Null when not known.
	 */
	public function typeOf(file: String, tree: QueryNode, source: String, node: QueryNode): Null<String> {
		final literal: Null<String> = (_shape.literalTypeNames ?? [])[node.kind];
		if (literal != null) return literal;
		if (node.kind == _shape.identKind && node.name == _shape.selfReferenceText) {
			final at: Null<Span> = node.span;
			return at == null ? null : MemberTouchScan.typeAt(tree, at.from);
		}
		return try NominalTypes.expressionTypeNominal(
			node, tree, _shape, declaredOf(file, source), _index, file, null, true
		) catch (exception: haxe.Exception) null;
	}

	/** The sites of `tree` (the text of `file` is `source`) inside `span`, in document order. */
	public function sitesIn(file: String, tree: QueryNode, source: String, span: Span): Array<ImplicitSite> {
		return [
			for (s in sitesOfFile(file, tree, source)) if (s.span.from >= span.from && s.span.to <= span.to) s
		];
	}

	private function declaredOf(file: String, source: String): Map<Int, String> {
		final held: Null<Map<Int, String>> = _declared[file];
		if (held != null) return held;
		final provider: Null<TypeInfoProvider> = _plugin is TypeInfoProvider ? cast _plugin : null;
		final read: Map<Int, String> = provider == null ? [] : provider.declaredTypes(source);
		_declared[file] = read;
		return read;
	}

	private function sitesOfFile(file: String, tree: QueryNode, source: String): Array<ImplicitSite> {
		// noqa: complexity
		final cached: Null<Array<ImplicitSite>> = _byFile[file];
		if (cached != null) return cached;
		final out: Array<ImplicitSite> = [];
		_byFile[file] = out;
		final concat: Array<String> = _shape.execution?.concatenationKinds ?? [];
		final interpolating: Array<String> = _shape.interpolatingStringKinds ?? [];
		final loops: Array<String> = _shape.iterationBindingKinds ?? [];
		final binders: Array<String> = _shape.iterationValueBinderKinds ?? [];
		final throws: Array<String> = _shape.throwKinds ?? [];
		function add(family: SiteFamily, node: QueryNode, operands: Array<QueryNode>): Void {
			final at: Null<Span> = node.span;
			if (at == null) return;
			final span: Span = at;
			out.push({
				family: family,
				span: span,
				types: [for (o in operands) typeOf(file, tree, source, o)],
				exact: false
			});
		}
		final functions: Array<String> = (_shape.functionKinds ?? []).concat(_shape.lambdaKinds ?? []);
		function walk(node: QueryNode, fn: Null<QueryNode>): Void {
			final kind: String = node.kind;
			if (concat.contains(kind)) add(Text, node, node.children);
			if (interpolating.contains(kind)) for (c in node.children) {
				final operand: Null<QueryNode> = interpolatedOperand(c);
				if (operand != null) add(Text, operand, [operand]);
			}
			if (loops.contains(kind)) {
				final iterable: Null<QueryNode> = NominalTypes.iterationIterable(node, binders);
				if (iterable != null && iterable.kind != _shape.intervalKind) add(Iteration, node, [iterable]);
			}
			if (kind == _shape.indexAccessKind && node.children.length > 0) add(Index, node, [node.children[0]]);
			if (_overloaded.exists(kind)) add(Operator(kind), node, node.children);
			// a compound assignment runs an overload of the operator it applies as well as its own
			final applied: Null<String> = (_shape.execution?.compoundAssignOperators ?? [])[kind];
			if (applied != null && _overloaded.exists(applied)) add(Operator(applied), node, node.children);
			if (kind == _shape.objectLiteralKind) add(Literal, node, []);
			// the exception wrapping the compiler adds after typing converts a thrown value to a string (`haxe.ValueException`)
			if (throws.contains(kind) && node.children.length > 0) add(Text, node, [node.children[0]]);
			// a value a build may convert to a string where it lands (`landings`): of the operand of an unchecked cast, any
			for (value in landings(file, tree, source, node, fn)) {
				final unchecked: Bool = value.kind == _shape.uncheckedCastKind && value.children.length > 0;
				final at: Null<Span> = value.span;
				if (at == null) continue;
				final span: Span = at;
				out.push({
					family: Text,
					span: span,
					types: [unchecked ? typeOf(file, tree, source, value.children[0]) : null],
					exact: false,
					landing: true
				});
			}
			final inner: Null<QueryNode> = functions.contains(kind) ? node : fn;
			for (c in node.children) walk(c, inner);
		}
		walk(tree, null);
		return out;
	}

	/**
	 * The values `node` — inside the function `fn` — puts at a place a build may convert them to a string at: hxcpp runs the
	 * `toString` of an object put at a `String` place (`UncheckedConversions`), which the syntax does not type. Only a value
	 * that left the type system can be an object there, so a value is one when the syntax reads it as an unchecked cast,
	 * untyped code, a value of a catch-all, of the built-in array (whose elements it does not type) or of no known type
	 * (`mayBeForeign`). A place is one a build may convert at (`mayConvertAt`) unless the syntax reads its declared type as
	 * one that converts no value to a string: an initialized declaration's (an unannotated one is typed as its value, and
	 * nothing lands at another type), an assignment's left side, the return type of a returned value's function (a lambda's
	 * is its caller's, unknown here; an unannotated one returns what it returns) and the parameter each argument of a call or
	 * a construction lands at, which the syntax does not read here.
	 */
	private function landings(file: String, tree: QueryNode, source: String, node: QueryNode, fn: Null<QueryNode>): Array<QueryNode> {
		// noqa: complexity
		final kind: String = node.kind;
		final out: Array<QueryNode> = [];
		function land(value: Null<QueryNode>, place: Null<String>): Void {
			if (value != null && mayBeForeign(file, tree, source, value) && mayConvertAt(place)) out.push(value);
		}
		final decls: Array<String> = (_shape.localDeclKinds ?? []).concat(_shape.fieldDeclKinds ?? []);
		final annotations: Array<String> = _shape.typeAnnotationKinds ?? [];
		if (decls.contains(kind) && node.children.length > 0) {
			final value: QueryNode = node.children[node.children.length - 1];
			final declared: Null<String> = declaredBefore(file, source, node, value);
			if (declared != null) land(value, declared);
		}
		if (kind == _shape.assignKind && node.children.length == 2) land(node.children[1], typeOf(file, tree, source, node.children[0]));
		if (kind == _shape.returnStatementKind && node.children.length > 0) {
			final written: Null<QueryNode> = fn == null || (_shape.lambdaKinds ?? []).contains(fn.kind)
				? null
				: fn.children.find(c -> annotations.contains(c.kind));
			if (fn == null || (_shape.lambdaKinds ?? []).contains(fn.kind))
				land(node.children[0], null)
			else if (written != null && written.name != null)
				land(node.children[0], written.name);
		}
		if (kind == _shape.callKind) for (i in 1...node.children.length) land(node.children[i], null);
		if (kind == _shape.newExprKind) for (arg in node.children) land(arg, null);
		return out;
	}

	/**
	 * Whether the syntax reads `value` as one that may be an object that left the type system: an unchecked cast, untyped
	 * code, or of a catch-all, of the built-in array, or of no known type (`landings`).
	 */
	private function mayBeForeign(file: String, tree: QueryNode, source: String, value: QueryNode): Bool {
		// noqa: complexity
		final kind: String = value.kind;
		if (kind == _shape.uncheckedCastKind || (_shape.untypedKinds ?? []).contains(kind)) return true;
		// a comparison or a negation is a boolean, an interpolated string a string
		if (
			(_shape.comparisonKinds ?? []).contains(kind) || kind == _shape.notKind
			|| (_shape.interpolatingStringKinds ?? []).contains(kind)
		)
			return false;
		if (kind == _shape.parenKind && value.children.length == 1) return mayBeForeign(file, tree, source, value.children[0]);
		if (kind == _shape.ternaryKind && value.children.length == 3)
			return mayBeForeign(file, tree, source, value.children[1]) || mayBeForeign(file, tree, source, value.children[2]);
		// a concatenation with a string is a string; of no string, of the type its operands give it
		final strings: Null<String> = (_shape.literalTypeNames ?? [])[(_shape.stringLiteralKinds ?? [])[0] ?? ''];
		if ((_shape.execution?.concatenationKinds ?? []).contains(kind))
			return !value.children.exists(c -> typeOf(file, tree, source, c) == strings)
				&& value.children.exists(c -> mayBeForeign(file, tree, source, c));
		final type: Null<String> = typeOf(file, tree, source, value);
		return type == null || (_shape.catchAllTypeNames ?? []).contains(type) || (_shape.arrayTypeNames ?? []).contains(type);
	}

	/**
	 * Whether a build may convert a value put at a place whose declared type the syntax reads as the simple name `place` (null:
	 * not known) to a string: unless it is a catch-all, which keeps what it is handed, a primitive other than the string type,
	 * or a class, an interface or an enum the index declares once other than the built-in array, a pointer whose conversion is
	 * checked (`landings`).
	 */
	private function mayConvertAt(place: Null<String>): Bool {
		if (place == null) return true;
		if ((_shape.catchAllTypeNames ?? []).contains(place) || (_shape.nonNullableTypeNames ?? []).contains(place)) return false;
		return (_shape.arrayTypeNames ?? []).contains(place) || !_index.resolvesToPlainNominal(place);
	}

	/**
	 * The simple name of the type the declaration `node` writes for the binding whose value is `value`
	 * (`TypeInfoProvider.declaredTypes`), or null when it writes none — or none nominal, which no value converts at.
	 */
	private function declaredBefore(file: String, source: String, node: QueryNode, value: QueryNode): Null<String> {
		final from: Int = node.span?.from ?? 0;
		final to: Int = value.span?.from ?? 0;
		for (at => type in declaredOf(file, source)) if (at >= from && at < to) return type;
		return null;
	}

	/**
	 * The expression an interpolated-string segment converts, or null for a text segment: an interpolated name is
	 * its own operand, a braced expression's operand is what the braces hold.
	 */
	private function interpolatedOperand(segment: QueryNode): Null<QueryNode> {
		if (segment.kind == _shape.stringInterpIdentKind) return segment;
		if ((_shape.stringInterpInertSegmentKinds ?? []).contains(segment.kind) || segment.children.length == 0) return null;
		return segment.children[0];
	}

}

/** Which implicit channel a site runs: the families of `ImplicitSites`. */
enum SiteFamily {

	/** A string conversion: the operands' `toString` may run. */
	Text;

	/** A `for … in` over a value that is not an interval: its iteration methods run. */
	Iteration;

	/** An index access: an index-access overload of the receiver's type runs. */
	Index;

	/** An operator of `kind`, which some member overloads. */
	Operator(kind: String);

	/** An object literal: a type built from a literal runs its constructor. */
	Literal;

}

/**
 * One implicit-call site: its family, its span, and the static type of each operand (null when not known). `exact`: every
 * operand is an object of exactly the class its type names — a construction, or a local holding only one — never a
 * subtype of it, nor an instance that left the type system (`ValueEscapes`).
 */
typedef ImplicitSite = {
	var family: SiteFamily;
	var span: Span;
	var types: Array<Null<String>>;
	var exact: Bool;

	/**
	 * For a site the compiler facts typed (`FactsView.sitesIn`), the typed type (`pack.Name`) of each operand, parallel to
	 * `types` — null where it names none: which of the types sharing a simple name each operand is. Absent elsewhere.
	 */
	var ?owners: Array<Null<String>>;

	/**
	 * Whether the site is a conversion only a build converting what lands at a typed place makes (`ImplicitSites.landings`,
	 * `UncheckedConversions.convertsSomewhere`); absent for one every build makes.
	 */
	var ?landing: Bool;
}

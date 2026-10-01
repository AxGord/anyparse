package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

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
		function walk(node: QueryNode): Void {
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
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
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
}

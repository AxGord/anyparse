package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.RefactorSupport;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;

/**
 * Flags a class / abstract / interface member that omits an explicit type — a
 * field with no `:Type`, a function parameter with no `:Type`, or a function with
 * no return type. Stating types everywhere is a documented project rule; the check
 * holds without a type-checker because the omission is purely syntactic.
 * A conservative autofix fills in a statically-certain initializer type; the rest stays report-only.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.fieldDeclKinds` are the field hosts; `RefShape.memberDeclKinds` minus
 * those are the function hosts. `RefShape.paramKinds` are parameters,
 * `RefShape.functionBodyKinds` the body markers — a function child that is neither
 * a parameter nor a body is its return type. Field / parameter type presence is
 * read from source: the type annotation is not projected as a node, but it sits
 * between the name and the initializer / default, so a `:` there means a type is
 * present. Enum-abstract values (a `RefShape.enumAbstractDeclKind` member's
 * fields) are exempt — their type is the abstract's underlying type. Any unset →
 * no-op.
 */
@:nullSafety(Strict)
final class ExplicitType implements Check {

	public function new() {}

	public function id(): String {
		return 'explicit-type';
	}

	public function description(): String {
		return 'a member field, parameter, or return type without an explicit type annotation';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		final params: Array<String> = shape.paramKinds ?? [];
		final bodies: Array<String> = shape.functionBodyKinds ?? [];
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		// Function hosts are the member kinds that are not fields; a missing fields
		// or functions set leaves the check with nothing useful to do.
		final functions: Array<String> = [for (k in memberKinds) if (!fields.contains(k)) k];
		if (fields.length == 0 || functions.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) {
				// checkstyle `Type.ignoreEnumAbstractValues` (default true) toggles the enum-abstract-value exemption.
				final ignoreEA: Bool = plugin.checkOverrides(entry.file)?.explicitTypeIgnoreEnumAbstract ?? true;
				final ea: Null<String> = ignoreEA ? enumAbstract : null;
				walk(violations, entry.file, entry.source, tree, null, fields, functions, params, bodies, ea);
			}
		}
		return violations;
	}

	/**
	 * Annotate a field / parameter whose initializer has a statically-certain type: a
	 * literal (`String` / `Bool` / `Int` / `Float`, negatives included), a `new T<...>()`
	 * with written type parameters, or a typed cast / check-type `(x : T)`. Everything
	 * uncertain — a bare `new T()` (possibly generic), a call, a field read, an array /
	 * map / ternary, a `[]`, or a missing return type — is left report-only: a wrong
	 * annotation breaks the build, so when uncertain the fix skips.
	 *
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final params: Array<String> = shape.paramKinds ?? [];
		final fixable: Array<String> = fields.concat(params);
		if (fixable.length == 0) return [];
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		final negKind: Null<String> = shape.negationKind;
		final newKind: Null<String> = shape.newExprKind;
		final castKinds: Array<String> = shape.typedCastKinds ?? [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, fixable, byKey);
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final castTargets: Map<Int, String> = provider != null ? provider.castTargetSources(source) : [];
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			// A field / parameter violation's span keys the node; a return-type violation's
			// span is the whole function, absent from the field/param index, so it is skipped.
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null || node.children.length == 0) continue;
			final typeSource: Null<String> = inferType(
				node.children[0], source, literalTypes, numeric, negKind, newKind, castKinds, castTargets
			);
			if (typeSource == null) continue;
			final at: Int = insertPoint(node, node.children[0], source);
			if (at >= 0) edits.push({ span: new Span(at, at), text: ':$typeSource' });
		}
		return edits;
	}

	/**
	 * Walk `node` carrying its `parentKind` (for the enum-abstract exemption). A
	 * field with no type annotation is flagged unless its container is an enum
	 * abstract; a function has each untyped parameter and its missing return type
	 * flagged.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, parentKind: Null<String>, fields: Array<String>,
		functions: Array<String>, params: Array<String>, bodies: Array<String>, enumAbstract: Null<String>
	): Void {
		if (fields.contains(node.kind)) {
			if (parentKind != enumAbstract && !hasTypeBeforeInit(node, source))
				push(out, file, node.span, 'field declared without an explicit type');
		} else if (functions.contains(node.kind))
			checkFunction(out, file, source, node, params, bodies);
		for (c in node.children) walk(out, file, source, c, node.kind, fields, functions, params, bodies, enumAbstract);
	}

	/**
	 * Flag each untyped parameter of `fn`, and `fn` itself when it has no return
	 * type — a child that is neither a parameter nor a body marker. A constructor
	 * (`new`) is exempt from the return-type rule: it has no return type.
	 * Flag each untyped parameter of `fn`, and `fn` itself when it has no return
	 * type. A constructor (`new`) is exempt from the return-type rule — it has no
	 * return type to declare.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, source: String, fn: QueryNode, params: Array<String>, bodies: Array<String>
	): Void {
		for (child in fn.children) if (params.contains(child.kind) && !hasTypeBeforeInit(child, source))
			push(out, file, child.span, 'parameter declared without an explicit type');
		if (fn.name != 'new' && !hasReturnType(fn, params, bodies))
			push(out, file, fn.span, 'function declared without an explicit return type');
	}

	/**
	 * Whether `fn` declares a return type. A generic constraint (`<T:C>`) and a
	 * return type project as the same kind of node, but a constraint sits before the
	 * parameters and the return type immediately before the body — so the return type
	 * is the child directly preceding the body marker, when that child is neither a
	 * parameter nor a body. (A constrained generic with no parameters and no return
	 * type is the one residual miss; it under-reports, never false-positives.)
	 */
	private static function hasReturnType(fn: QueryNode, params: Array<String>, bodies: Array<String>): Bool {
		final kids: Array<QueryNode> = fn.children;
		var bodyIndex: Int = -1;
		for (i in 0...kids.length) if (bodies.contains(kids[i].kind)) bodyIndex = i;
		if (bodyIndex <= 0) return false;
		final before: QueryNode = kids[bodyIndex - 1];
		return !params.contains(before.kind) && !bodies.contains(before.kind);
	}

	/**
	 * Whether a `:` type annotation precedes the declaration's initializer / default.
	 * The type sits between the name and the first child (the initializer / default
	 * value, when present) or the declaration's end; neither the keyword, the name,
	 * nor property accessors `(get, set)` contain a `:`, so a `:` in that prefix is
	 * the type. A node with no span cannot be judged and is treated as typed.
	 */
	private static function hasTypeBeforeInit(node: QueryNode, source: String): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return true;
		var cutoff: Int = span.to;
		if (node.children.length > 0) {
			final firstSpan: Null<Span> = node.children[0].span;
			if (firstSpan != null) cutoff = firstSpan.from;
		}
		return source.substring(span.from, cutoff).indexOf(':') >= 0;
	}

	private static function push(out: Array<Violation>, file: String, span: Null<Span>, message: String): Void {
		if (span != null) out.push({
			file: file,
			span: span,
			rule: 'explicit-type',
			severity: Severity.Warning,
			message: message
		});
	}


	/**
	 * The type source to annotate for `init` when its type is statically certain,
	 * else null. A literal maps through `literalTypes`; a `Neg` wrapping a numeric
	 * literal takes that literal's type; a `new T<...>()` with WRITTEN type
	 * parameters carries `T<...>` verbatim (a bare `new T()` — possibly generic —
	 * yields null); a typed cast / check-type takes its target type. Anything else
	 * (a call, a field read, an array / map / ternary) is null — report-only.
	 */
	private static function inferType(
		init: QueryNode, source: String, literalTypes: Map<String, String>, numeric: Array<String>, negKind: Null<String>,
		newKind: Null<String>, castKinds: Array<String>, castTargets: Map<Int, String>
	): Null<String> {
		final direct: Null<String> = literalTypes[init.kind];
		if (direct != null) return direct;
		if (negKind != null && init.kind == negKind && init.children.length == 1) {
			final inner: QueryNode = init.children[0];
			return numeric.contains(inner.kind) ? literalTypes[inner.kind] : null;
		}
		if (newKind != null && init.kind == newKind) return newTypeSource(init, source);
		final span: Null<Span> = init.span;
		return span != null && castKinds.contains(init.kind) ? TypeResolver.castTargetWithin(span, castTargets) : null;
	}

	/**
	 * The `T<...>` type source of a `new T<...>(...)` when it carries WRITTEN type
	 * parameters, else null (a bare `new T(...)` could be a generic used without
	 * parameters, whose bare `:T` annotation would not type-check). Scans from after
	 * `new` for the balanced `<...>`; a `>` preceded by `-` is the arrow `->` inside
	 * a function-type parameter, not an angle close. A constructor `(` reached before
	 * any `<` means no written type parameters.
	 */
	private static function newTypeSource(newNode: QueryNode, source: String): Null<String> {
		final span: Null<Span> = newNode.span;
		if (span == null) return null;
		final full: String = source.substring(span.from, span.to);
		var i: Int = 3;
		while (i < full.length && StringTools.isSpace(full, i)) i++;
		final typeStart: Int = i;
		var depth: Int = 0;
		while (i < full.length) {
			switch StringTools.fastCodeAt(full, i) {
				case '('.code if (depth == 0):
					return null;
				case '<'.code:
					depth++;
				case '>'.code if (StringTools.fastCodeAt(full, i - 1) != '-'.code):
					depth--;
					if (depth == 0) return full.substring(typeStart, i + 1);
				case _:
			}
			i++;
		}
		return null;
	}

	/**
	 * The offset right after the declaration's name — where a `:Type` annotation is
	 * inserted — found by walking back over whitespace from the assignment `=` that
	 * precedes the initializer. Returns -1 when no `=` is in the name-to-initializer
	 * prefix (a declaration with no initializer cannot be annotated by this fix).
	 */
	private static function insertPoint(node: QueryNode, init: QueryNode, source: String): Int {
		final span: Null<Span> = node.span;
		final initSpan: Null<Span> = init.span;
		if (span == null || initSpan == null) return -1;
		final prefix: String = source.substring(span.from, initSpan.from);
		final eq: Int = prefix.lastIndexOf('=');
		if (eq < 0) return -1;
		var pos: Int = span.from + eq;
		while (pos > span.from && StringTools.isSpace(source, pos - 1)) pos--;
		return pos;
	}

}

package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags `Std.string(x)` and rewrites it to string interpolation — `'$x'` for a simple
 * identifier, `'${expr}'` for any other interpolation-safe expression — `Severity.Info`
 * (a modernization cleanup matching the Haxe idiom: direct conversion, no reflection
 * overhead), with an autofix.
 *
 * Minimal safe subset: only a single-argument `Std.string(...)` call is touched. An
 * argument whose source contains a quote, a `$`, or a newline is left alone — wrapping it
 * in `'${ … }'` could break the string (an inner `'` would close it). String
 * concatenation around the call (`"a" + Std.string(x)`) is not merged into one
 * interpolated string here — only the `Std.string(x)` node itself is rewritten in place,
 * which stays correct (`"a" + '$x'`); the harder merge is a separate concern.
 *
 * ## Not equivalence-preserving for every argument
 *
 * `Std.string` accepts `Null<Dynamic>` and never rejects a nullable argument; the
 * interpolation form compiles to a `+`-concatenation that DOES, under
 * `@:nullSafety(Strict)`, reject a nullable operand — and field access never narrows
 * (a preceding `obj.field != null` guard does not make `obj.field` provably non-null to
 * the checker), so rewriting `Std.string(obj.field)` to `'${obj.field}'` can turn
 * working code into a null-safety compile error. A bare field access (`Std.string(o.f)`)
 * is therefore left alone unconditionally. A simple-identifier argument (a local /
 * parameter) is rewritten only when its resolved declaration is provably not itself
 * nullable — a known nominal type (unannotated / inferred locals are conservatively
 * skipped, their type being unknown) that is not `Null<…>` / `Dynamic` / `Any`, not an
 * optional parameter (`?p`), and not a default-null parameter (`p: T = null`). Any other
 * argument shape (a call, a binary expression, …) keeps the pre-existing
 * `interpolationSafe`-gated braced rewrite.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.callKind`, `fieldAccessKind`, and `identKind` (a missing optional
 * kind → no-op); the receiver `Std` and member `string` are matched on node names, not
 * kinds. The outermost matching call is flagged and not descended into, so a nested
 * `Std.string(Std.string(x))` yields one non-overlapping fix. The identifier-safety gate
 * degrades gracefully when `plugin` is not a `TypeInfoProvider` (no declared-type map,
 * treated as empty) — a simple identifier is then never proven safe and is left alone.
 */
@:nullSafety(Strict)
final class PreferInterpolation implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-interpolation';
	}

	public function description(): String {
		return "a Std.string(x) call replaceable with string interpolation ('$x')";
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final shape: RefShape = plugin.refShape();
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = provider == null ? [] : provider.declaredTypes(entry.source);
			walk(violations, entry.file, entry.source, tree, tree, seams, shape, declaredTypes);
		}
		return violations;
	}

	/** Rewrite each flagged `Std.string(arg)` to its interpolation. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [seams.callKind], (node, span) -> {
				final arg: Null<QueryNode> = matchArg(node, seams.callKind, seams.fieldAccessKind, seams.identKind);
				final replacement: Null<String> = arg == null ? null : render(arg, source, seams.identKind);
				return replacement == null ? null : { span: span, text: replacement };
			});
	}

	/**
	 * Walk `node`; flag the outermost `Std.string(...)` call and STOP — a nested one
	 * inside the argument would yield an overlapping fix, and is caught on the next
	 * `--fix` iteration.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, root: QueryNode, node: QueryNode, seams: Seams, shape: RefShape,
		declaredTypes: Map<Int, String>
	): Void {
		final arg: Null<QueryNode> = matchArg(node, seams.callKind, seams.fieldAccessKind, seams.identKind);
		if (arg != null && isSafeArg(arg, root, seams.fieldAccessKind, seams.identKind, shape, declaredTypes)
			&& render(arg, source, seams.identKind) != null) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'prefer-interpolation',
					severity: Severity.Info,
					message: 'this Std.string() call can be string interpolation'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, root, c, seams, shape, declaredTypes);
	}

	/**
	 * If `call` is a single-argument `Std.string(arg)`, its argument node; else null.
	 * Purely structural — the caller separately gates safety (`isSafeArg`, `run`-side
	 * only) and renders the replacement (`render`).
	 */
	private static function matchArg(call: QueryNode, callKind: String, fieldAccessKind: String, identKind: String): Null<QueryNode> {
		if (call.kind != callKind || call.children.length != 2) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != fieldAccessKind || callee.name != 'string' || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		if (receiver.kind != identKind || receiver.name != 'Std') return null;
		return call.children[1];
	}

	/**
	 * Whether `arg` is safe to rewrite into an interpolation under
	 * `@:nullSafety(Strict)` — `Std.string` accepts a nullable value; the
	 * interpolation's underlying `+`-concatenation does not, so an argument that
	 * is not provably non-null must be left alone.
	 *
	 * A bare field access (`fieldAccessKind`) never narrows and is always refused,
	 * guard or not. A simple identifier (`identKind`) is safe only when it resolves
	 * (via the scope resolver) to a local / parameter declaration with a KNOWN
	 * nominal type — an unresolved binding or an unannotated/inferred declaration
	 * (absent from `declaredTypes`) keeps the conservative default — that is not an
	 * optional parameter (`?p`), not a default-null parameter (`p: T = null`), and
	 * not one of `RefShape.nullableWrapperTypeNames` (`Null<…>` / `Dynamic` / `Any`).
	 * Any other argument shape (a call, a binary expression, …) is left to the
	 * pre-existing `interpolationSafe`-gated braced rewrite, unaffected by this gate.
	 */
	private static function isSafeArg(
		arg: QueryNode, root: QueryNode, fieldAccessKind: String, identKind: String, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		if (arg.kind == fieldAccessKind) return false;
		if (arg.kind != identKind) return true;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(arg, root, shape);
		if (bindingFrom == null) return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && TypeResolver.bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final nullLiteralKind: Null<String> = shape.nullLiteralKind;
		if (paramKinds != null && nullLiteralKind != null
			&& TypeResolver.bindingIsDefaultNullParam(root, bindingFrom, paramKinds, nullLiteralKind)) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		return !nullableWrapperTypeNames.contains(typeName);
	}

	/**
	 * The interpolation text for an already-approved `arg` (`'$x'` for a simple
	 * identifier, `'${expr}'` for an interpolation-safe expression); else null.
	 */
	private static function render(arg: QueryNode, source: String, identKind: String): Null<String> {
		final argName: Null<String> = arg.name;
		if (arg.kind == identKind && argName != null) return "'$" + argName + "'";
		final span: Null<Span> = arg.span;
		if (span == null) return null;
		final src: String = source.substring(span.from, span.to);
		return !interpolationSafe(src) ? null : "'${" + src + "}'";
	}

	/** Whether `src` can sit inside a single-quoted `'${ … }'` without breaking the string. */
	private static function interpolationSafe(src: String): Bool {
		for (i in 0...src.length) {
			final c: Int = StringTools.fastCodeAt(src, i);
			// A single-quote, double-quote, dollar, or newline in the argument source would
			// close or re-interpolate the wrapping '${ … }', making the rewrite unsafe.
			if (c == "'".code || c == '"'.code || c == "$".code || c == '\n'.code || c == '\r'.code) return false;
		}
		return true;
	}


	/** Resolve the call / field-access / ident seam kinds, or null when a required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final identKind: String = shape.identKind;
		return { callKind: callKind, fieldAccessKind: fieldAccessKind, identKind: identKind };
	}

}

/** The resolved seams `PreferInterpolation` reads in both `run` and `fix`. */
private typedef Seams = {
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
};

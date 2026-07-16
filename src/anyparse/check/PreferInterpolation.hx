package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags `Std.string(x)` and rewrites it to string interpolation — `'$x'` for a simple
 * identifier, `'${expr}'` for any other interpolation-safe expression (`Std.string(o.f)`
 * → `'${o.f}'`). `Severity.Info` (a modernization cleanup matching the Haxe idiom: direct
 * conversion, no reflection overhead), with an autofix.
 *
 * Minimal safe subset: only a single-argument `Std.string(...)` call is touched. An
 * argument whose source contains a quote, a `$`, or a newline is left alone — wrapping it
 * in `'${ … }'` could break the string (an inner `'` would close it). String
 * concatenation around the call (`"a" + Std.string(x)`) is not merged into one
 * interpolated string here — only the `Std.string(x)` node itself is rewritten in place,
 * which stays correct (`"a" + '$x'`); the harder merge is a separate concern.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.callKind`, `fieldAccessKind`, and `identKind` (a missing optional
 * kind → no-op); the receiver `Std` and member `string` are matched on node names, not
 * kinds. The outermost matching call is flagged and not descended into, so a nested
 * `Std.string(Std.string(x))` yields one non-overlapping fix.
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
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, seams.callKind, seams.fieldAccessKind, seams.identKind);
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
				final replacement: Null<String> = match(node, source, seams.callKind, seams.fieldAccessKind, seams.identKind);
				return replacement == null ? null : { span: span, text: replacement };
			});
	}

	/**
	 * Walk `node`; flag the outermost `Std.string(...)` call and STOP — a nested one
	 * inside the argument would yield an overlapping fix, and is caught on the next
	 * `--fix` iteration.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, callKind: String, fieldAccessKind: String, identKind: String
	): Void {
		if (node.kind == callKind && match(node, source, callKind, fieldAccessKind, identKind) != null) {
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
		for (c in node.children) walk(out, file, source, c, callKind, fieldAccessKind, identKind);
	}

	/**
	 * If `call` is a single-argument `Std.string(arg)`, return the interpolation that
	 * replaces it (`'$x'` for a simple identifier, `'${expr}'` for an interpolation-safe
	 * expression); else null.
	 */
	private static function match(
		call: QueryNode, source: String, callKind: String, fieldAccessKind: String, identKind: String
	): Null<String> {
		if (call.kind != callKind || call.children.length != 2) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != fieldAccessKind || callee.name != 'string' || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		if (receiver.kind != identKind || receiver.name != 'Std') return null;
		final arg: QueryNode = call.children[1];
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

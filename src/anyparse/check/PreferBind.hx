package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a zero-parameter arrow lambda whose whole body is a single call —
 * `() -> f(a, b)` — and rewrites it to a partial application, `f.bind(a, b)`.
 * The wrapper lambda is noise when every argument is already known at the point
 * the callback is created. `Severity.Info` (a modernization matching the Haxe
 * idiom), with an autofix.
 *
 * Only a `() -> callee(args)` form with at least one argument is touched: a lambda
 * carrying parameters (`x -> f(x)`, `(x, y) -> f(x)`) keeps them as separate
 * `Required` / `Optional` children and is left alone (binding would leave them
 * unbound), and a block body (`() -> { … }`) is not a single call. A zero-argument
 * `() -> f()` is out of scope — `f.bind()` adds nothing, and the lambda may instead
 * collapse to a bare `f`, a different rewrite.
 *
 * Note the timing shift: `.bind` evaluates the callee and arguments at bind time,
 * whereas the lambda evaluates them at call time. For the common case (a stable
 * callee and value arguments) this is equivalent; the `Info` severity reflects that
 * it is a cleanup, not a guaranteed-identical transform.
 *
 * ## Grammar-agnostic
 *
 * The lambda kind comes from `RefShape.parenLambdaKind` and the call kind from
 * `callKind` (either unset → no-op). The outermost matching lambda is flagged and
 * not descended into, so a nested `() -> f(() -> g(1))` yields one non-overlapping
 * fix per `--fix` iteration.
 */
@:nullSafety(Strict)
final class PreferBind implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-bind';
	}

	public function description(): String {
		return 'a () -> f(a, b) wrapper lambda replaceable with f.bind(a, b)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, seams.lambdaKind, seams.callKind);
		}
		return violations;
	}

	/** Rewrite each flagged `() -> callee(args)` to `callee.bind(args)`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [seams.lambdaKind], (node, span) -> {
				final replacement: Null<String> = rewrite(node, source, seams.lambdaKind, seams.callKind);
				return replacement == null ? null : { span: span, text: replacement };
			});
	}

	private static function walk(out: Array<Violation>, file: String, node: QueryNode, lambdaKind: String, callKind: String): Void {
		if (bindableCall(node, lambdaKind, callKind) != null) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'prefer-bind',
					severity: Severity.Info,
					message: 'this () -> f(...) wrapper lambda can be f.bind(...)'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, c, lambdaKind, callKind);
	}

	/** The wrapped call when `node` is a bindable `() -> callee(arg, …)` lambda; else null. */
	private static function bindableCall(node: QueryNode, lambdaKind: String, callKind: String): Null<QueryNode> {
		if (node.kind != lambdaKind || node.children.length != 1) return null;
		final call: QueryNode = node.children[0];
		// callee + at least one argument; a parameter-bearing lambda has Required/Optional
		// children, so children.length != 1 excludes it.
		return call.kind == callKind && call.children.length >= 2 ? call : null;
	}

	/** `callee.bind(arg, …)` built from the lambda's wrapped call, or null if it is not bindable. */
	private static function rewrite(node: QueryNode, source: String, lambdaKind: String, callKind: String): Null<String> {
		final call: Null<QueryNode> = bindableCall(node, lambdaKind, callKind);
		if (call == null) return null;
		final calleeSpan: Null<Span> = call.children[0].span;
		if (calleeSpan == null) return null;
		final callee: String = source.substring(calleeSpan.from, calleeSpan.to);
		final args: Array<String> = [];
		for (i in 1...call.children.length) {
			final argSpan: Null<Span> = call.children[i].span;
			if (argSpan == null) return null;
			args.push(source.substring(argSpan.from, argSpan.to));
		}
		return '$callee.bind(' + args.join(', ') + ')';
	}


	/** Resolve the lambda / call seam kinds, or null when either is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final lambdaKind: Null<String> = shape.parenLambdaKind;
		if (lambdaKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		return callKind == null ? null : { lambdaKind: lambdaKind, callKind: callKind };
	}

}

/** The resolved seams `PreferBind` reads in both `run` and `fix`. */
private typedef Seams = {
	final lambdaKind: String;
	final callKind: String;
};

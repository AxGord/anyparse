package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
		final shape: RefShape = plugin.refShape();
		final lambdaKind: Null<String> = shape.parenLambdaKind;
		final callKind: Null<String> = shape.callKind;
		if (lambdaKind == null || callKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, lambdaKind, callKind);
		}
		return violations;
	}

	/** Rewrite each flagged `() -> callee(args)` to `callee.bind(args)`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final lambdaKind: Null<String> = shape.parenLambdaKind;
		final callKind: Null<String> = shape.callKind;
		if (lambdaKind == null || callKind == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexLambdas(tree, lambdaKind, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final replacement: Null<String> = rewrite(node, source, lambdaKind, callKind);
			if (replacement == null) continue;
			edits.push({ span: span, text: replacement });
		}
		return edits;
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

	/** Index every lambda node by its `from:to` span key (for `fix` to re-find a flagged node). */
	private static function indexLambdas(node: QueryNode, lambdaKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == lambdaKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexLambdas(c, lambdaKind, out);
	}

}

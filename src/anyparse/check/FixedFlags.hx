package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;

/**
 * The parameters of a function that decide two or more of its `if`s and that nothing in it writes — a flag fixed for the
 * whole run (TM's `FolderWatcher.rename(…, flush)`: `if (flush) lock(); … if (flush) unlock();`). A hold's window is
 * traced once per value of each such flag (`LockWindow.trace`), each `if` on one taking the branch its value picks:
 * every run fixes each flag to one value, so the union of the traces covers every run, and a take and a give guarded by
 * the same flag no longer leave a path that takes without giving back.
 */
@:nullSafety(Strict)
final class FixedFlags {

	/** At most this many flags are split on: each doubles the traces. */
	public static inline final MAX_FLAGS: Int = 3;

	/** The fixed flags of the function node `fn` (see the class doc), at most `MAX_FLAGS`, in parameter order. */
	public static function of(fn: QueryNode, shape: RefShape, ifKinds: Array<String>): Array<String> {
		final params: Array<String> = [
			for (c in fn.children) if ((shape.paramKinds ?? []).contains(c.kind) && c.name != null) c.name ?? ''
		];
		if (params.length == 0) return [];
		final tests: Map<String, Int> = [];
		final written: Array<String> = [];
		scan(fn, shape, ifKinds, params, tests, written);
		final out: Array<String> = [for (p in params) if ((tests[p] ?? 0) >= 2 && !written.contains(p)) p];
		return out.slice(0, MAX_FLAGS);
	}

	/**
	 * The value the `if` condition `cond` has under `values` (each fixed flag's), when it is a bare flag or its negation;
	 * null otherwise.
	 */
	public static function decide(cond: QueryNode, values: Map<String, Bool>, shape: RefShape): Null<Bool> {
		final flag: Null<String> = flagOf(cond, shape);
		if (flag != null) return values[flag];
		final inner: Null<QueryNode> = cond.kind == shape.notKind && cond.children.length == 1 ? cond.children[0] : null;
		final negated: Null<String> = inner == null ? null : flagOf(inner, shape);
		final value: Null<Bool> = negated == null ? null : values[negated];
		return value == null ? null : !value;
	}

	/** The name `node` reads bare, through parentheses; null for anything else. */
	private static function flagOf(node: QueryNode, shape: RefShape): Null<String> {
		if (node.kind == shape.parenKind && node.children.length == 1) return flagOf(node.children[0], shape);
		return node.kind == shape.identKind ? node.name : null;
	}

	/** Counts in `tests` the `if`s each of `params` decides under `node`, and lists in `written` those any assignment writes. */
	private static function scan(
		node: QueryNode, shape: RefShape, ifKinds: Array<String>, params: Array<String>, tests: Map<String, Int>, written: Array<String>
	): Void {
		final kids: Array<QueryNode> = node.children;
		if (ifKinds.contains(node.kind) && kids.length >= 2) {
			final cond: QueryNode = kids[0];
			final read: Null<String> = flagOf(cond.kind == shape.notKind && cond.children.length == 1 ? cond.children[0] : cond, shape);
			if (read != null && params.contains(read)) tests[read] = (tests[read] ?? 0) + 1;
		}
		final writes: Bool = shape.writeParentKinds.contains(node.kind);
		final target: Null<String> = writes && kids.length > 0 ? flagOf(kids[0], shape) : null;
		if (target != null && !written.contains(target)) written.push(target);
		for (k in kids) scan(k, shape, ifKinds, params, tests, written);
	}

}

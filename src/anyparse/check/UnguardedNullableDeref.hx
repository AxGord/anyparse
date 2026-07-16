package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.NullableSource.NullableSourceCfg;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;
import anyparse.check.NullFlow.NullFacts;

/**
 * Flags a dereference whose receiver is a local **bound from a nullable source** and
 * not null-checked on the path reaching the access — a possible NPE. The
 * flow-sensitive (mechanism-A) sibling of the point-wise `possible-null-dereference`
 * (mechanism B): where B sees only a deref of the nullable EXPRESSION itself
 * (`m[k].f`), this catches the binding-then-use B is structurally blind to —
 * `final u = m[k]; doStuff(); u.name;`.
 *
 * ## How it works
 *
 * A `NullFlow` walk seeds a `MaybeNull` fact whenever a local is assigned a nullable
 * source (`NullableSource.describe` over the file's `declaredTypes` / `returnTypes` —
 * a `Map`-family index or `.get`, or a `Null<T>`-returning call). The length-guarded collection accessors (`Array` / `List` `pop` / `shift` / `first` / `last`) are excluded from the seed — their dominant `while (c.length > 0) c.pop()` idiom is safe by a guard flow cannot model, so seeding them would be a systematic false positive; the point-wise `possible-null-dereference` still flags them at `Info`. The fact is narrowed away by the same guards the engine already models — an
 * `if (u != null)` arm, an early `if (u == null) return;`, an `&&` right side, a
 * non-null reassignment, a `??=`, a `switch` branch after a `case null:`, a `case _ if (u != null):` guard, and a `nullAssertionCalls` helper (`Assert.notNull(u)`) — so a guarded deref is a safe miss. Only a function
 * unit's own names (parameters / locals) are tracked, so a field / static / `this` receiver is never reported. Residual false positives remain where the non-null guarantee lives in a value / relational invariant the name-keyed flow cannot see — an `m.exists(k)` guard before `m[k]`, a key just written (`m[k] = v; var u = m[k];`), a key drawn from `m.keys()`, or an alias (`var v = u; if (v != null) u.f;`); these are report-only Warning residuals, suppressible via `// noqa` or `apqlint.json`.
 *
 * Four receiver forms are covered, exactly as `null-dereference`: a field / method
 * access (`u.f` / `u.m()`, `fieldAccessKind`), a force-unwrap (`u!.f`,
 * `forceFieldAccessKind`), an index (`u[i]`, `indexAccessKind`), and a bare call
 * (`u()`, `callKind` with a plain-identifier callee). The null-safe `u?.f` short-circuits
 * and is never flagged.
 *
 * ## Partition — no double flag
 *
 * The three null-deref checks are disjoint by the receiver's flow state / shape:
 * `null-dereference` fires on a `Null`-by-flow ident, `possible-null-dereference` on a
 * nullable-source EXPRESSION receiver, and this one on a `MaybeNull`-bound IDENT
 * receiver — mutually exclusive states and forms.
 *
 * `Severity.Warning` — flow removes the guard-blindness false-positive class, so this
 * earns the stronger signal the point-wise `Info` twin cannot. Report-only: a possible
 * null dereference has no single mechanical fix.
 */
@:nullSafety(Strict)
final class UnguardedNullableDeref implements Check {

	public function new() {}

	public function id(): String {
		return 'unguarded-nullable-deref';
	}

	public function description(): String {
		return
			'a dereference of a local bound from a nullable source (map[key] / Map.get, Null<T>-returning call) with no null check on the path — a possible NPE';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return [];
		final ident: String = identKind;
		// Field-shaped receivers must be the node's sole child; index / call receivers
		// are the first of several (index expression / call arguments follow).
		final soleChildKinds: Array<String> = [for (k in [shape.fieldAccessKind, shape.forceFieldAccessKind]) if (k != null) k];
		final firstChildKinds: Array<String> = [for (k in [shape.indexAccessKind, shape.callKind]) if (k != null) k];
		if (soleChildKinds.length == 0 && firstChildKinds.length == 0) return [];
		final cfg: Null<NullableSourceCfg> = NullableSource.build(shape, shape.nullableFlowExcludedCalls ?? []);
		if (cfg == null) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final cfgValue: NullableSourceCfg = cfg;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final ctx: Ctx = { ident: ident, soleChildKinds: soleChildKinds, firstChildKinds: firstChildKinds };
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final returnTypes: Map<Int, String> = typed.returnTypes(entry.source);
			final seed: (QueryNode) -> Bool = rhs ->
				NullableSource.describe(rhs, root, declaredTypes, returnTypes, cfgValue, index) != null;
			NullFlow.analyze(tree, shape, entry.source, (node, facts) -> checkDeref(violations, entry.file, node, facts, ctx), seed);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Flag `node` when it is a covered deref form (`ctx.soleChildKinds` sole-child / `ctx.firstChildKinds` first-child) whose receiver is a `MaybeNull`-bound plain identifier. */
	private static function checkDeref(out: Array<Violation>, file: String, node: QueryNode, facts: NullFacts, ctx: Ctx): Void {
		final sole: Bool = ctx.soleChildKinds.contains(node.kind) && node.children.length == 1;
		final first: Bool = ctx.firstChildKinds.contains(node.kind) && node.children.length >= 1;
		if (!sole && !first) return;
		final receiver: QueryNode = node.children[0];
		final span: Null<Span> = node.span;
		if (receiver.kind != ctx.ident || span == null) return;
		final name: Null<String> = receiver.name;
		if (name == null) return;
		if (facts.isMaybeNull(name)) out.push({
			file: file,
			span: span,
			rule: 'unguarded-nullable-deref',
			severity: Severity.Warning,
			message: 'possible null dereference — this receiver was bound from a nullable source and is not null-checked on this path'
		});
	}

}

/** Resolved per-run deref-shape constants threaded to `checkDeref`. */
private typedef Ctx = {
	var ident: String;
	var soleChildKinds: Array<String>;
	var firstChildKinds: Array<String>;
};

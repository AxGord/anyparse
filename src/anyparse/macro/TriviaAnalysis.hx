package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Expr;

/**
 * Phase-3 analysis pass run between `ShapeBuilder` and `Lowering`.
 *
 * Two jobs:
 *
 *  1. **Direct detection** — scan every `ShapeNode` tree and mark Star
 *     nodes whose grammar-source field/ctor-arg carried the `@:trivia`
 *     meta, AND auto-mark Star args of `@:postfix(open, close)` enum
 *     branches (the postfix Star-suffix shape, e.g. `Call(operand, args)`)
 *     even without an explicit `@:trivia` — `Lowering`'s postfix-loop
 *     and `WriterLowering.lowerPostfixStar` route through dedicated
 *     paths that don't trigger `triviaSepStarExpr`'s over-break, so the
 *     auto-mark is safe and avoids the writer-side multi-line predicate
 *     regression parked in 2026-05-01. Stored as `trivia.starCollects = true`
 *     on the Star node itself, consulted later by Lowering when
 *     generating Trivia-mode Star-element parse loops.
 *
 *  2. **Transitive closure** — a rule is "trivia-bearing" if it
 *     directly contains a Star with `@:trivia`, OR any of its Ref
 *     children/ctor args point at another trivia-bearing rule. We
 *     compute this as a fixed-point over the rule graph: start from
 *     direct-bearers, iterate marking dependents until no new rule
 *     flips. Result is stored as `trivia.bearing = true` on each
 *     qualifying rule's root node. Plain-mode codegen ignores this;
 *     Trivia-mode codegen synthesizes paired `*T` types for each
 *     bearing rule and routes parser dispatch through them.
 *
 * Runs unconditionally (both Plain and Trivia modes) so the analysis
 * is always available for diagnostics and so adding `@:trivia` to a
 * grammar field never requires a parallel toggle elsewhere.
 */
class TriviaAnalysis {

	public static function run(result:ShapeBuilder.ShapeResult):Void {
		for (name => node in result.rules) markStarsWithTrivia(node);
		// ω-postfix-starsuffix-trivia: postfix Star-suffix branches
		// (e.g. `@:postfix('(', ')') @:sep(',') Call(operand, args)`)
		// auto-mark their args' Star with `trivia.starCollects = true`
		// without an explicit `@:trivia`. The synth wraps each elem in
		// `Trivial<elemT>`, the parser per-element captures trailing
		// comments via `lowerPostfixLoop`'s trivia branch, the writer
		// reads `.node`/`.trailingComment` per arg in `lowerPostfixStar`.
		// `@:trivia` is intentionally NOT used — it would route the
		// writer through `triviaSepStarExpr` whose multi-line predicate
		// over-breaks call-arg lists (parked 2026-05-01,
		// `feedback_trivia_not_freebie.md`). The dedicated
		// `lowerPostfixStar` writer path is unaffected.
		for (name => node in result.rules) markPostfixStarSuffix(node);
		final directlyBearing:Map<String, Bool> = [];
		for (name => node in result.rules) directlyBearing[name] = hasAnyTriviaStar(node);
		final bearing:Map<String, Bool> = [];
		for (name => flag in directlyBearing) if (flag) bearing[name] = true;
		var changed:Bool = true;
		while (changed) {
			changed = false;
			for (name => node in result.rules) {
				if (bearing.exists(name)) continue;
				for (ref in collectRefs(node)) if (bearing.exists(ref)) {
					bearing[name] = true;
					changed = true;
					break;
				}
			}
		}
		for (name => node in result.rules) node.annotations.set('trivia.bearing', bearing.exists(name));
	}

	private static function markStarsWithTrivia(node:ShapeNode):Void {
		// Struct-field case: `@:trivia var decls:Array<HxDecl>`.
		// `shapeField` attaches the field-level meta directly to the Star
		// node (the `Array<T>` result of `shapeFieldType`), so detection
		// is a direct meta read on the Star itself.
		if (node.kind == Star && hasTrivia(node.annotations.get('base.meta'))) {
			node.annotations.set('trivia.starCollects', true);
		}
		// Enum-branch case: `@:trivia BlockStmt(stmts:Array<HxStatement>)`.
		// `shapeEnum` attaches the ctor-level meta to the Seq branch and
		// passes `null` for per-arg meta, so the @:trivia is NOT on the
		// Star. When a trivia-bearing branch has exactly one Star child,
		// the @:trivia is unambiguously about that Star — mark it here.
		// Multiple Stars on the same branch would need a named-arg form
		// (`@:trivia(stmts)`), which no current grammar requires.
		if (node.kind == Seq && hasTrivia(node.annotations.get('base.meta'))) {
			final stars:Array<ShapeNode> = [for (c in node.children) if (c.kind == Star) c];
			if (stars.length == 1) stars[0].annotations.set('trivia.starCollects', true);
		}
		for (child in node.children) markStarsWithTrivia(child);
	}

	private static function markPostfixStarSuffix(node:ShapeNode):Void {
		// Postfix branches live as Seq children of the rule's Alt root.
		// Detect: branch.base.meta has `:postfix` with 2 args (open, close)
		// AND children = [Ref operand, Star args]. Mark the Star.
		if (node.kind == Seq && hasPostfixPair(node.annotations.get('base.meta'))
			&& node.children.length == 2
			&& node.children[0].kind == Ref
			&& node.children[1].kind == Star) {
			node.children[1].annotations.set('trivia.starCollects', true);
		}
		for (child in node.children) markPostfixStarSuffix(child);
	}

	private static function hasPostfixPair(meta:Null<Metadata>):Bool {
		if (meta == null) return false;
		for (e in meta) if (e.name == ':postfix' && e.params.length == 2) return true;
		return false;
	}

	private static function hasTrivia(meta:Null<Metadata>):Bool {
		if (meta == null) return false;
		for (e in meta) if (e.name == ':trivia') return true;
		return false;
	}

	private static function hasAnyTriviaStar(node:ShapeNode):Bool {
		if (node.kind == Star && node.annotations.get('trivia.starCollects') == true) return true;
		for (child in node.children) if (hasAnyTriviaStar(child)) return true;
		return false;
	}

	private static function collectRefs(node:ShapeNode):Array<String> {
		final out:Array<String> = [];
		collectRefsInto(node, out);
		return out;
	}

	private static function collectRefsInto(node:ShapeNode, out:Array<String>):Void {
		if (node.kind == Ref) {
			final r:Null<String> = node.annotations.get('base.ref');
			if (r != null && out.indexOf(r) == -1) out.push(r);
		}
		for (child in node.children) collectRefsInto(child, out);
	}
}
#end

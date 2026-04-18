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
 *     meta. Stored as `trivia.starCollects = true` on the Star node
 *     itself, consulted later by Lowering when generating Trivia-mode
 *     Star-element parse loops.
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

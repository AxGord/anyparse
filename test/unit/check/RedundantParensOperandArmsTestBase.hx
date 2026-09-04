package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.RedundantParens;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.QueryNode;
import anyparse.query.format.Text;
import utest.Assert;
import utest.Test;

/**
 * Fixture scaffolding shared by the `redundant-parens` OPERAND-arm test parts: the
 * per-arm `LintConfig` builders, a violation run, the fix / convergence drivers, and
 * the TREE-EQUIVALENCE oracle every asserted drop is checked against — both the
 * before and the after source are parsed, every paren node is spliced out of each,
 * and the two shapes must render identically, so a drop that re-associates fails.
 */
class RedundantParensOperandArmsTestBase extends Test {

	/** Pass budget for `converged` — generous; the deepest fixture here settles in two. */
	private static inline final MAX_PASSES: Int = 8;

	private inline function atoms(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true}}}');
	}

	private inline function sameOperatorLeft(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"sameOperatorLeft": true}}}');
	}

	private inline function comparisonOperands(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"comparisonOperands": true}}}');
	}

	/** An explicit EMPTY project config — hermetic, unlike falling through to a discovered `apqlint.json`. */
	private inline function none(): (String) -> LintConfig {
		return configured('{}');
	}

	private inline function additiveOperands(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"additiveOperands": true}}}');
	}

	/** `body` as the sole statement of a method — the shortest host for a statement-level fixture. */
	private inline function inFn(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	/** `fixed(before)` must equal `after`, and the two must parse to the same paren-free shape. */
	private function assertDrop(before: String, after: String, resolve: (String) -> LintConfig): Void {
		Assert.equals(after, fixed(before, resolve));
		Assert.equals(bareTree(before), bareTree(after), 'paren drop preserved the tree shape');
	}

	private function violations(src: String, ?resolve: (String) -> LintConfig): Array<Violation> {
		final check: RedundantParens = new RedundantParens();
		if (resolve != null) check.setConfigResolver(resolve);
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` with every edit ONE pass of the check's own `fix` produces applied. */
	private function fixed(src: String, ?resolve: (String) -> LintConfig): String {
		final check: RedundantParens = new RedundantParens();
		if (resolve != null) check.setConfigResolver(resolve);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return CanonicalEdit.applyEdits(src, check.fix(src, vs, plugin));
	}

	/** `src` fixed repeatedly until it stops changing — what `lint --fix` does over passes. */
	private function converged(src: String, resolve: (String) -> LintConfig): String {
		var out: String = src;
		for (_ in 0...MAX_PASSES) {
			final next: String = fixed(out, resolve);
			if (next == out) return out;
			out = next;
		}
		Assert.fail('fix did not converge within $MAX_PASSES passes');
		return out;
	}

	/** `src` parsed with every parenthesis node spliced out — the shape a redundant pair must not change. */
	private function bareTree(src: String): String {
		return Text.render(stripParens(new HaxeQueryPlugin().parseFile(src)));
	}

	private function stripParens(node: QueryNode): QueryNode {
		final bare: QueryNode = BoolExprShape.unwrapParens(node, 'ParenExpr');
		return new QueryNode(bare.kind, bare.name, [for (c in bare.children) stripParens(c)]);
	}

	private function configured(json: String): (String) -> LintConfig {
		final config: LintConfig = LintConfig.parse(json);
		return _ -> config;
	}

}

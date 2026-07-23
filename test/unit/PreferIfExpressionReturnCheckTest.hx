package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferIfExpressionReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-if-expression-return` check: an `if / else if / … / else` CHAIN whose every
 * branch is a valued `return` is flagged `Info`, and `fix` collapses it to
 * `return if (c1) a else if (c2) b … else n;`. Disjoint from `prefer-ternary-return`
 * (which handles the if/return + fall-through-return shape): only a chain with at least
 * one `else if` terminating in a plain `else`, of single valued-`return` branches,
 * qualifies. A bare `return;` in any branch disqualifies.
 */
class PreferIfExpressionReturnCheckTest extends Test {

	public function testBasicChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-if-expression-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else-if return chain can be a single if-expression return', vs[0].message);
	}

	public function testFixThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFixFourBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse if (c) return 3;\n\t\telse return 4;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else if (c) 3 else 4;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	/** A chain with no terminal `else` is not collapsible. */
	public function testNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) return 2;')).length);
	}

	/** A bare `return;` is a distinct node kind (no value) — it disqualifies the chain. */
	public function testBareReturnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) return;\n\t\telse return 3;')).length);
	}

	public function testNonReturnBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) g();\n\t\telse return 3;')).length);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tg();\n\t\t\treturn 1;\n\t\t} else if (b) return 2;\n\t\telse return 3;')).length);
	}

	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) /* keep */ return 2;\n\t\telse return 3;')).length);
	}

	/** End-to-end through the canonical writer: the emitted file holds the collapsed return, valid Haxe (canonicalize re-parses it). */
	public function testFixOutputCollapsesChain(): Void {
		final out: String = applyFixOnce(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.isTrue(out.indexOf('return if (a) 1 else if (b) 2 else 3;') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-if-expression-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-if-expression-return'));
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferIfExpressionReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferIfExpressionReturn = new PreferIfExpressionReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}

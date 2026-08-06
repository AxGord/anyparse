package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferFinal;
import anyparse.check.Severity;
import anyparse.check.SplitVarDeclaration;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * The `split-var-declaration` check: a local declaration binding several variables in one
 * statement is flagged `Info`, and `fix` rebuilds it as one declaration per statement --
 * keyword, per-declarator `:type` and initializer preserved verbatim. The right-recursive
 * `VarMore` chain is pinned by the three-declarator fixture (the data-loss regression class).
 * A single declarator, a comma inside a generic type, a comment or a `#if` directive inside
 * the statement, the local-metadata form and a declaration that is the bare body of an
 * `if` / `while` / `case` are all safe misses. The composition pins are the point of the
 * rule: `prefer-final` reports NOTHING on the multi-declarator shape and picks the
 * never-reassigned binding up only after the split, in process and at the real `lint --fix`
 * fixed point.
 */
class SplitVarDeclarationCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var a = 1, b = 2;'));
		Assert.equals(1, vs.length);
		Assert.equals('split-var-declaration', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this declaration binds 2 variables; split it into one declaration per statement', vs[0].message);
	}

	public function testFixTwoDeclarators(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var a = 1, b = 2;'));
		Assert.equals(1, es.length);
		Assert.equals('var a = 1;\n\t\tvar b = 2;', es[0].text);
	}

	/**
	 * REGRESSION PIN for the right-recursive chain: `VarMore c` is a CHILD of `VarMore b`,
	 * not a sibling, so a walk that reads only the first continuation drops `c` entirely.
	 */
	public function testFixThreeDeclaratorsKeepsTheLast(): Void {
		final vs: Array<Violation> = violations(wrap('var a = 1, b = 2, c = 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('this declaration binds 3 variables; split it into one declaration per statement', vs[0].message);
		final es: Array<{ span: Span, text: String }> = edits(wrap('var a = 1, b = 2, c = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('var a = 1;\n\t\tvar b = 2;\n\t\tvar c = 3;', es[0].text);
	}

	/** The declaration keyword is copied onto every emitted statement, `final` included. */
	public function testFixFinalKeepsKeyword(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x = 1, y = 2;'));
		Assert.equals(1, es.length);
		Assert.equals('final x = 1;\n\t\tfinal y = 2;', es[0].text);
	}

	/** Per-declarator `:type` annotations are part of the declarator slice, so they survive verbatim. */
	public function testFixKeepsPerDeclaratorTypes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("var a:Int = 1, b:String = 'x';"));
		Assert.equals(1, es.length);
		Assert.equals("var a:Int = 1;\n\t\tvar b:String = 'x';", es[0].text);
	}

	public function testFixNoInitializers(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var p, q;'));
		Assert.equals(1, es.length);
		Assert.equals('var p;\n\t\tvar q;', es[0].text);
	}

	public function testFixMixedInitializedAndBare(): Void {
		final trailing: Array<{ span: Span, text: String }> = edits(wrap('var a = 1, b;'));
		Assert.equals(1, trailing.length);
		Assert.equals('var a = 1;\n\t\tvar b;', trailing[0].text);
		final leading: Array<{ span: Span, text: String }> = edits(wrap('var a, b = 2;'));
		Assert.equals(1, leading.length);
		Assert.equals('var a;\n\t\tvar b = 2;', leading[0].text);
	}

	/** A comma inside a generic type is not a declarator separator -- the gate asks the AST, not the text. */
	public function testGenericTypeCommaNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Map<Int, String> = null;')).length);
	}

	public function testSingleDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a = 1;')).length);
	}

	/** A comment inside the statement sits in a region the rebuild does not copy. */
	public function testCommentInsideStatementNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a = 1, /* c */ b = 2;')).length);
	}

	/**
	 * A comment AFTER the `;` is outside the replaced span, so the statement still splits and
	 * the comment stays where the edit leaves it -- on the line of the LAST emitted declaration.
	 */
	public function testTrailingCommentSurvivesFix(): Void {
		final src: String = wrap('var a = 1, b = 2; // note');
		Assert.equals(1, violations(src).length);
		final out: String = applyFixOnce(src);
		Assert.isTrue(out.indexOf('var b = 2; // note') != -1, out);
	}

	/** A `#if` inside the declarator list is a shape the slice arithmetic cannot model. */
	public function testCondDirectiveInsideStatementNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a = 1, b = #if js 2 #else 3 #end;')).length);
	}

	public function testBareIfBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (c) var a = 1, b = 2;')).length);
	}

	public function testBareWhileBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('while (c) var a = 1, b = 2;')).length);
	}

	public function testBareCaseBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: var a = 1, b = 2;\n\t\t}')).length);
	}

	/** The local-metadata form projects as `ExprStmt > MetaExpr > VarExpr`, which is never a candidate. */
	public function testLocalMetadataFormNotFlagged(): Void {
		Assert.equals(0, violations(wrap('@:foo var a = 1, b = 2;')).length);
	}

	/**
	 * TRAP-3 PIN for the CondBranch convention: a statement inside a `#if` region is only a
	 * direct child of a `blockKinds()` node in the BRANCH-AWARE projection. This test fails
	 * if the check reads `CheckScan.parseOrNull` instead of `parseBranchAwareOrNull`.
	 */
	public function testInsideConditionalBlockFlagged(): Void {
		Assert.equals(1, violations(wrap('#if js\n\t\tvar a = 1, b = 2;\n\t\t#end')).length);
	}

	/** End-to-end through the canonical writer: the two declarations land on separate lines. */
	public function testFixOutputSplitsLines(): Void {
		final out: String = applyFixOnce(wrap('var a = 1, b = 2;'));
		Assert.equals(-1, out.indexOf('var a = 1, b = 2;'));
		Assert.isTrue(out.indexOf('var a = 1;\n') != -1, out);
		Assert.isTrue(out.indexOf('var b = 2;') != -1, out);
	}

	/**
	 * COMPOSITION, in process: `prefer-final` skips every multi-declarator statement wholesale,
	 * so the never-reassigned `uid` is invisible to it until this rule puts the bindings on
	 * their own statements. `a` is reassigned by `a++` and stays a `var`.
	 */
	public function testComposesWithPreferFinalInProcess(): Void {
		final src: String = wrap('var uid:StringBuf = new StringBuf(), a:Int = 8;\n\t\tuid.add(a);\n\t\ta++;');
		Assert.equals(0, preferFinalViolations(src).length, 'prefer-final is blind to the multi-declarator shape');
		final split: String = applyFixOnce(src);
		final after: Array<Violation> = preferFinalViolations(split);
		Assert.equals(1, after.length, split);
		Assert.equals('local \'uid\' is never reassigned; use final', after[0].message);
		final upgraded: String = applyPreferFinal(split);
		Assert.isTrue(upgraded.indexOf('final uid:StringBuf = new StringBuf();') != -1, upgraded);
		Assert.isTrue(upgraded.indexOf('var a:Int = 8;') != -1, upgraded);
	}

	/**
	 * COMPOSITION, at the REAL fixed point: ONE `apq lint --fix` invocation splits the
	 * declaration and then upgrades the never-reassigned binding, because the `--fix` driver
	 * loops until nothing changes. The fixture is byte-canonical under default writer opts
	 * (trailing newline included) so the first-pass canonical gate admits it.
	 */
	public function testComposesWithPreferFinalAtCliFixedPoint(): Void {
		#if (sys || nodejs)
		final src: String =
			'package p;\n\nclass C {\n\tpublic function f():String {\n\t\tvar uid:StringBuf = new StringBuf(), a:Int = 8;\n\t\tuid.add(a);\n\t\ta++;\n\t\treturn uid.toString();\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixsplitvar', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run([
			'lint',
			'--rule',
			'split-var-declaration',
			'--rule',
			'prefer-final',
			'--fix',
			path
		]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('final uid:StringBuf = new StringBuf();') != -1, 'split then finalized in one invocation: $out');
		Assert.isTrue(out.indexOf('var a:Int = 8;') != -1, 'the reassigned binding stays a var on its own line: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('split-var-declaration'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('split-var-declaration'));
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new SplitVarDeclaration().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: SplitVarDeclaration = new SplitVarDeclaration();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return canonical(src, edits(src));
	}

	private function preferFinalViolations(src: String): Array<Violation> {
		return new PreferFinal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyPreferFinal(src: String): String {
		final check: PreferFinal = new PreferFinal();
		return canonical(src, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()));
	}

	private function canonical(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}

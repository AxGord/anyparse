package unit;

import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.Linter;
import anyparse.check.PreferInterpolation;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-interpolation` check: a single-argument `Std.string(x)` is flagged `Info`
 * and rewritten to string interpolation — `'$x'` for a simple identifier whose declared
 * type is provably not itself nullable, `'${expr}'` for any other interpolation-safe
 * expression. A non-`Std` receiver, a wrong arity, and an argument whose source carries a
 * quote (which `'${ … }'` cannot wrap safely) are left alone. A nested
 * `Std.string(Std.string(x))` is flagged once (outermost only).
 *
 * `Std.string` accepts a nullable value; the interpolation form does not under
 * `@:nullSafety(Strict)` (field access never narrows), so a bare field-access argument
 * (`Std.string(o.f)`) is left alone in the default safe mode — oracle-relaxed mode
 * (`setOracleRelaxed`) admits it through the RiskyFix typecheck-and-revert pipeline.
 * See the `testFieldAccess*` /
 * `testUnannotatedLocalNotFlagged` / `testNullTypedLocalNotFlagged` /
 * `testDynamicTypedLocalNotFlagged` / `test*ParamNotFlagged` gate tests below.
 */
class PreferInterpolationCheckTest extends Test {

	public function testSimpleIdentFlagged(): Void {
		final vs: Array<Violation> = violations(body('var name: Int = 1;\n\t\tvar y = Std.string(name);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this Std.string() call can be string interpolation', vs[0].message);
	}

	public function testFieldAccessNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(o.f)')).length);
	}

	public function testNonStdReceiverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Foo.string(x)')).length);
	}

	public function testWrongArityNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(a, b)')).length);
	}

	public function testQuoteArgNotFlagged(): Void {
		Assert.equals(0, violations(wrap("Std.string(c == 'a')")).length);
	}

	/**
	 * A BACKSLASH in the argument source is refused for the reason
	 * `HaxeStringFoldSupport.interpolationBlockSafe` already states: the compiler
	 * decodes a literal's escapes before it reads the interpolation inside it, so an
	 * escape moved into `'${ … }'` is re-read one level up. `Std.string(~/\x24/)` is the
	 * regex for a literal `$`; `'${~/\x24/}'` decodes to `'${~/$/}'`, the end-of-input
	 * anchor — compile-and-run shows `~/\x24/` becoming `~/$/`, a silent value change
	 * this check shipped. A regex literal is the only argument shape that reaches here
	 * with a backslash; a string one is already refused by the quote test above.
	 */
	public function testEscapeBearingArgNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(~/\\x24/)')).length);
		Assert.equals(0, violations(wrap('Std.string(~/\\x7D/)')).length);
	}

	public function testNestedFlaggedOnce(): Void {
		Assert.equals(1, violations(wrap('Std.string(Std.string(x))')).length);
	}

	public function testFixSimpleIdent(): Void {
		Assert.equals("'$name'", fixText(body('var name: Int = 1;\n\t\tvar y = Std.string(name);')));
	}

	public function testFixFieldAccessNoEdit(): Void {
		Assert.equals('<0 edits>', fixText(wrap('Std.string(o.f)')));
	}

	public function testFixNested(): Void {
		Assert.equals("'${Std.string(x)}'", fixText(wrap('Std.string(Std.string(x))')));
	}

	public function testFieldAccessInNullCheckedBranchNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(obj: Holder):Void {\n\t\tif (obj.field != null) {\n'
			+ '\t\t\tvar s: String = Std.string(obj.field);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNullTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var n: Null<Int> = null;\n\t\tvar s: String = Std.string(n);')).length);
	}

	public function testDynamicTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var d: Dynamic = 1;\n\t\tvar s: String = Std.string(d);')).length);
	}

	public function testOptionalParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(?p: Int):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDefaultNullParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p: Int = null):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var u = make();\n\t\tvar s: String = Std.string(u);')).length);
	}

	public function testNonNullLocalStillFlagged(): Void {
		final vs: Array<Violation> = violations(body('var localNonNull: Int = 1;\n\t\tvar s: String = Std.string(localNonNull);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
	}

	public function testFixNonNullLocal(): Void {
		Assert.equals("'$localNonNull'", fixText(body('var localNonNull: Int = 1;\n\t\tvar s: String = Std.string(localNonNull);')));
	}

	public function testNonNullParamStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p: Int):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testStringTypedLocalStillFlagged(): Void {
		Assert.equals(1, violations(body('var s: String = "a";\n\t\tvar r: String = Std.string(s);')).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-interpolation'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-interpolation'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * A `Std.string(x)` that is a DIRECT operand of a string concatenation belongs to
	 * `fold-adjacent-string-literals`, which owns the whole chain and peels the wrapper
	 * off itself. Exactly ONE rule reports the site: this one stays silent, and the
	 * fold rule's single finding is asserted alongside so the fixture pins the
	 * hand-off rather than the absence of any finding at all.
	 */
	public function testStdStringDirectConcatOperandLeftToFold(): Void {
		final src: String = "class C {\n\tfunction f(x:Int):Void {\n\t\tvar y = 'a' + Std.string(x) + 'b';\n\t}\n}";
		Assert.equals(0, violations(src).length);
		Assert.equals(1, foldViolations(src).length);
	}

	/**
	 * A `+` chain with NO string literal in it is not one `fold-adjacent-string-literals`
	 * reports — merging it would turn arithmetic into text — so the hand-off must not
	 * defer to it there. Both shapes were flagged by NOBODY while the gate read the
	 * parent node's KIND instead of asking that rule what it claims.
	 */
	public function testStdStringInLiteralFreeChainStillFlagged(): Void {
		final pair: String = 'class C {\n\tfunction f(a:Int, b:Int):Void {\n\t\tvar y = Std.string(a) + Std.string(b);\n\t}\n}';
		Assert.equals(2, violations(pair).length);
		Assert.equals(0, foldViolations(pair).length);
		final numeric: String = 'class C {\n\tfunction f(a:Int):Void {\n\t\tvar z = Std.string(a) + 1;\n\t}\n}';
		Assert.equals(1, violations(numeric).length);
		Assert.equals(0, foldViolations(numeric).length);
	}

	/**
	 * An ANNOTATION argument is the same hole spelled differently: the fold rule skips
	 * `metaKinds` wholesale, so it claims no chain inside one however many literals
	 * that chain carries.
	 */
	public function testStdStringInMetadataChainStillFlagged(): Void {
		final src: String = "class C {\n\t@:meta('a' + Std.string(g()) + 'b')\n\tvar y:Int = 0;\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, foldViolations(src).length);
	}

	/** Outside a concatenation the call is still this rule's. */
	public function testStdStringOutsideConcatStillFlagged(): Void {
		Assert.equals(1, violations(body('var x: Int = 1;\n\t\tvar y = Std.string(x);')).length);
	}

	/**
	 * A `Std.string(x)` NESTED inside a string literal's `${...}` interpolation block
	 * (here a ternary branch — the branches must stay String-typed, so the wrapper
	 * cannot merely be peeled) is this rule's too: the rewrite nests an interpolated
	 * string inside the block (`'$x'`), which the real compiler lexes fine via
	 * brace/quote balancing — compile-and-run verified, byte-identical output.
	 */
	public function testStdStringInInterpolationBlockTernaryFlagged(): Void {
		final src: String = "class C {\n\tfunction f(x:Int, cond:Bool):Void {\n\t\tvar s = '${cond ? Std.string(x) : 'NULL'}';\n\t}\n}";
		Assert.equals(1, violations(src).length);
	}

	public function testFixStdStringInInterpolationBlockTernary(): Void {
		final src: String = "class C {\n\tfunction f(x:Int, cond:Bool):Void {\n\t\tvar s = '${cond ? Std.string(x) : 'NULL'}';\n\t}\n}";
		Assert.equals("'$x'", fixText(src));
	}

	/**
	 * A `Std.string(x)` that IS the entire interpolation block's expression needs no
	 * nested string at all — the block already stringifies its expression, so the
	 * wrapper is peeled: `'v=${Std.string(x)}'` -> `'v=${x}'`. A pure text motion
	 * within the block (the argument source stays in the same escape context), so
	 * it needs no `interpolationSafe` gate.
	 */
	public function testStdStringWholeInterpolationBlockPeeled(): Void {
		final src: String = "class C {\n\tfunction f(x:Int):Void {\n\t\tvar s = 'v=${Std.string(x)}';\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals('x', fixText(src));
	}

	/**
	 * The null-safety gate holds inside interpolation blocks exactly as outside them.
	 * The relaxed count on the SAME fixture proves the site is a reachable candidate,
	 * so the safe-mode 0 pins the gate itself — not a descent that never got there.
	 */
	public function testFieldAccessInInterpolationBlockNotFlaggedSafeMode(): Void {
		final src: String =
			"class C {\n\tfunction f(o:Holder, cond:Bool):Void {\n\t\tvar s = '${cond ? Std.string(o.f) : 'NULL'}';\n\t}\n}";
		Assert.equals(0, violations(src).length);
		Assert.equals(1, relaxedViolations(src).length);
	}

	/**
	 * A `+` chain INSIDE an interpolation block is one `fold-adjacent-string-literals`
	 * would claim but never visits (its walk stops at string literals), so the hand-off
	 * is suppressed there — this rule keeps the call, or it would be flagged by nobody.
	 */
	public function testStdStringInChainInsideInterpolationBlockStillFlagged(): Void {
		final src: String = "class C {\n\tfunction f(x:Int):Void {\n\t\tvar s = '${'a' + Std.string(x)}';\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, foldViolations(src).length);
	}

	/**
	 * A safe-mode finding on an INNER call whose enclosing `Std.string` was refused by
	 * the gate (bare field-access argument): the fix-side re-scan runs relaxed, which
	 * moves the outermost-only stop to the OUTER call — it must keep collecting nested
	 * matches, or the reported violation's span never appears in the lookup and the
	 * finding is silently unfixable.
	 */
	public function testFixInnerCallUnderGateRefusedOuter(): Void {
		final src: String = 'class C {\n\tfunction f(id:Int):Void {\n\t\tvar s: String = Std.string(user(Std.string(id)).name);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals("'$id'", fixText(src));
	}

	/**
	 * A comment between the call's parentheses sits OUTSIDE the argument span, and both
	 * rewrites replace the WHOLE call span — flagging would silently delete it. Left
	 * alone, the same refusal `redundant-tostring` makes.
	 */
	public function testCommentInsideCallNotFlagged(): Void {
		Assert.equals(0, violations(body('var x: Int = 1;\n\t\tvar y = Std.string(/* why */ x);')).length);
		final peel: String = "class C {\n\tfunction f(x:Int):Void {\n\t\tvar s = 'v=${Std.string(/* why */ x)}';\n\t}\n}";
		Assert.equals(0, violations(peel).length);
	}

	/**
	 * Oracle-relaxed mode (`setOracleRelaxed`) drops the `isSafeArg` gate: a bare
	 * field-access argument and an unproven (unannotated) identifier become
	 * candidates — applied only through the RiskyFix typecheck-and-revert pipeline,
	 * which is what makes the relaxation sound.
	 */
	public function testOracleRelaxedFieldAccessFlagged(): Void {
		Assert.equals(1, relaxedViolations(wrap('Std.string(o.f)')).length);
		Assert.equals(1, relaxedViolations(body('var u = make();\n\t\tvar s: String = Std.string(u);')).length);
	}

	/** The TM CloudDatabaseMigrationV1ToV2:217 shape end-to-end: relaxed run + fix. */
	public function testOracleRelaxedFieldAccessInInterpolationBlockFixed(): Void {
		final src: String = 'class C {\n\tfunction f(e:Entry):Void {\n\t\t'
			+ "var s = '${!e.folder && e.cloudId != -1 ? Std.string(e.cloudId) : 'NULL'},';\n\t}\n}";
		final check: PreferInterpolation = new PreferInterpolation();
		check.setOracleRelaxed(true);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		Assert.equals("'${e.cloudId}'", edits[0].text);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	/** A class fixture whose method body is `stmts` — for gate tests that declare their own typed locals. */
	private function body(stmts: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$stmts\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferInterpolation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** What `fold-adjacent-string-literals` reports for `src` — the other half of every hand-off fixture. */
	private function foldViolations(src: String): Array<Violation> {
		return new FoldStringLiterals().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The check's findings for `src` with the oracle-relaxed candidate set enabled. */
	private function relaxedViolations(src: String): Array<Violation> {
		final check: PreferInterpolation = new PreferInterpolation();
		check.setOracleRelaxed(true);
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferInterpolation = new PreferInterpolation();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<${edits.length} edits>';
	}

}

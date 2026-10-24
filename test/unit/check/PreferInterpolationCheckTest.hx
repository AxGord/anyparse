package unit.check;

import anyparse.check.FoldStringLiterals;
import anyparse.check.MacroGate;
import anyparse.check.PreferInterpolation;
import anyparse.check.Severity;
import anyparse.query.cli.command.LintCommand;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `prefer-interpolation` check: a single-argument `Std.string(x)` is flagged `Info` and rewritten to string interpolation
 * — `'$x'` for a simple identifier, `'${expr}'` for any other interpolation-safe expression — only when the argument's type is
 * PROVEN one the concatenation prints as `Std.string` does and never null: a basic type or an enum abstract over one with no
 * implicit call. A non-`Std` receiver, a wrong arity, an argument whose source carries a quote, and an argument of an unproven,
 * nullable, `Dynamic`, class or converting-abstract type are left alone, in the report and in the fix alike.
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
		Assert.equals(1, violations(body('var y: Int = 1;\n\t\tvar x = Std.string(Std.string(y));')).length);
	}

	public function testFixSimpleIdent(): Void {
		Assert.equals("'$name'", fixText(body('var name: Int = 1;\n\t\tvar y = Std.string(name);')));
	}

	public function testFixFieldAccessNoEdit(): Void {
		Assert.equals('<0 edits>', fixText(wrap('Std.string(o.f)')));
	}

	/** The outer call's argument is a call whose type this fixture proves nothing about, so the proven inner one is rewritten. */
	public function testFixNested(): Void {
		Assert.equals("'$y'", fixText(body('var y: Int = 1;\n\t\tvar x = Std.string(Std.string(y));')));
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
		final src: String = "class C {\n\t@:meta('a' + Std.string(1 + 2) + 'b')\n\tvar y:Int = 0;\n}";
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
	 * The gate holds inside interpolation blocks exactly as outside them. The same shape on a field of a proven `Int` is
	 * flagged, so the 0 on the untyped receiver pins the gate itself — not a descent that never got there.
	 */
	public function testFieldAccessInInterpolationBlockNeedsAProvenType(): Void {
		final unknown: String =
			"class C {\n\tfunction f(o:Holder, cond:Bool):Void {\n\t\tvar s = '${cond ? Std.string(o.f) : 'NULL'}';\n\t}\n}";
		Assert.equals(0, violations(unknown).length);
		final typed: String = 'class Holder {\n\tpublic var f:Int = 0;\n\n\tpublic function new() {}\n}\n\n'
			+ "class C {\n\tfunction f(o:Holder, cond:Bool):Void {\n\t\tvar s = '${cond ? Std.string(o.f) : 'NULL'}';\n\t}\n}";
		Assert.equals(1, violations(typed).length);
		Assert.equals("'${o.f}'", fixText(typed));
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
	 * A `${ … }` block holding nothing but a constant that prints alike on every target is plain text written as a runtime
	 * conversion: `fold-adjacent-string-literals` used to leave `'${0} ${i + 1}'` behind for `0 + ' ' + (i + 1)`, and this
	 * is the rule that cleans such a literal up. The fix re-renders the whole literal.
	 */
	@:pin('control')
	@:killer('M-FOLD-CONSTANT-AS-EXPRESSION')
	@:killer('M-INTERP-CONSTANT-BLOCK-IGNORED')
	public function testInterpolatedConstantBecomesText(): Void {
		final src: String = "class C {\n\tfunction f(i:Int):Void {\n\t\tvar s = '${0} ${i + 1}';\n\t}\n}";
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this interpolated constant can be plain text', vs[0]?.message);
		Assert.equals("'0 ${i + 1}'", fixText(src));
	}

	/** Every constant kind the seam answers, each spelled as the value it prints: hex as decimal, `-0` as `0`, separators dropped. */
	@:pin('control')
	@:killer('M-CONSTANT-NEGATIVE-ZERO-SIGNED')
	public function testEveryInterpolatedConstantKindBecomesItsPrintedText(): Void {
		Assert.equals(
			"'16|-1|-16|0|null|true|false|1000'", fixText(wrap("'${0x10}|${-1}|${-0x10}|${-0}|${null}|${true}|${false}|${1_000}'"))
		);
	}

	/**
	 * A `$name` directly in front of the spliced text would read a longer name (`'$x0'` is `x0`), so the re-render braces
	 * it — the renderer decides that, not this rule.
	 */
	@:pin('control')
	@:killer('M-INTERP-CONSTANT-BLOCK-IGNORED')
	public function testConstantAfterAShorthandReadBracesTheRead(): Void {
		Assert.equals("'${x}0'", fixText(body("var x: Int = 1;\n\t\tvar s = '$x${0}';")));
	}

	/**
	 * A `Float` prints differently per target (`1.0` is `1` on js, `1.0` on python), `0xFFFFFFFF` wraps to `-1`, and a
	 * decimal past `2147483647` types as `Float`: none of them is text on every target, so each keeps its block.
	 */
	@:pin('control')
	@:killer('M-CONSTANT-DECIMAL-RANGE-UNCHECKED')
	@:killer('M-CONSTANT-FLOAT-ADMITTED')
	@:killer('M-CONSTANT-HEX-RANGE-UNCHECKED')
	public function testTargetDependentConstantsKeepTheirBlock(): Void {
		Assert.equals(0, violations(wrap("'${1.5}|${1.0}'")).length);
		Assert.equals(0, violations(wrap("'${0xFFFFFFFF}|${0x80000000}'")).length);
		Assert.equals(0, violations(wrap("'${2147483648}'")).length);
		Assert.equals("'2147483647|2147483647'", fixText(wrap("'${2147483647}|${0x7FFFFFFF}'")));
	}

	/** An annotation argument is read as syntax, so its interpolated constant stays as written. */
	@:pin('control')
	@:killer('M-INTERP-CONSTANT-IN-META')
	public function testInterpolatedConstantInAnnotationNotFlagged(): Void {
		Assert.equals(0, violations("class C {\n\t@:m('${0}')\n\tfunction f():Void {}\n}").length);
	}

	/**
	 * A macro reads its arguments as SYNTAX, and one keyed by a literal's text (the client's `Lang.t('text')`) sees every rewrite of
	 * this rule as a different key: both the constant fix and the `${Std.string(x)}` peel stay report-only there, refused by
	 * the same `MacroGate` `fold-adjacent-string-literals` asks. The same shapes outside the macro call are still fixed.
	 */
	@:pin('control')
	@:killer('M-INTERP-MACRO-ARGUMENT-REWRITTEN')
	public function testMacroArgumentIsReportedButNotFixed(): Void {
		final src: String = 'class L { public static macro function t(e: haxe.macro.Expr) { return e; } }\n'
			+ "class C {\n\tfunction f(x:Int):Void {\n\t\tvar a = L.t('${0} a');\n\t\tvar b = L.t('v=${Std.string(x)}');\n\t}\n}";
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		for (v in vs) Assert.isTrue(v.message.endsWith(MacroGate.SYNTAX_REFUSAL), 'the macro gate refuses it: ${v.message}');
		Assert.equals('<0 edits>', fixText(src));
		Assert.equals("'0 a'", fixText(wrap("'${0} a'")));
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	/** A class fixture whose method body is `stmts` — for gate tests that declare their own typed locals. */
	private function body(stmts: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$stmts\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violationsIn(new PreferInterpolation(), CheckFixture.withStd(src));
	}

	/** What `fold-adjacent-string-literals` reports for `src` — the other half of every hand-off fixture. */
	private function foldViolations(src: String): Array<Violation> {
		return CheckFixture.violations(new FoldStringLiterals(), src);
	}

	private function fixText(src: String): String {
		final check: PreferInterpolation = new PreferInterpolation();
		final edits: Array<{ span: Span, text: String }> = CheckFixture.edits(check, src);
		return edits.length == 1 ? edits[0].text : '<${edits.length} edits>';
	}

	@:pin('control')
	@:killer('M-INTERP-NULLITY-SKIPPED')
	public function testTypedefOfNullArgumentNotFlagged(): Void {
		// `'$x'` rejects a nullable operand under Strict where `Std.string(x)` accepts it.
		Assert.equals(
			0,
			violations(
				'typedef MaybeR = Null<R>; class R {} '
				+ '@:nullSafety(Strict) class C { function f(x:MaybeR) { var r: String = Std.string(x); } }'
			).length
		);
	}

	/**
	 * A field of a loop binder over an untyped iterator is `Dynamic`; once compared with null, the null-safety checker reads
	 * `'${row.x}'` as nullable and rejects it where `Std.string(row.x)` compiles. The report never proposes it, and the fix
	 * pass asks the same question: the rule runs in the unverified loop with the report's own gate, never a wider one.
	 */
	@:pin('control')
	@:killer('M-INTERP-REPORT-GATE-BYPASSED')
	public function testDynamicFieldOfLoopBinderIsProposedByNeitherMode(): Void {
		final src: String = 'import sys.db.ResultSet;\n@:nullSafety\nclass C {\n\tstatic function f(s:String):Bool\n'
			+ '\t\treturn s.length > 0;\n\n\tstatic function g(rows:ResultSet):Bool {\n\t\tfor (row in rows)\n'
			+ '\t\t\tif (row.x != null && f(Std.string(row.x)))\n\t\t\t\treturn true;\n\t\treturn false;\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(0, LintCommand.partitionChecks([new PreferInterpolation()], true).risky.length);
		Assert.equals(1, LintCommand.partitionChecks([new PreferInterpolation()], true).safe.length);
	}

	/** A call whose type no declaration proves plain is declined: `Dynamic` here, nullable to the null-safety checker. */
	@:pin('control')
	@:killer('M-INTERP-NULLITY-SKIPPED')
	public function testUnprovenCallArgumentNotFlagged(): Void {
		final src: String = '@:nullSafety(Strict) class C {\n\tstatic function d():Dynamic return null;\n\n'
			+ '\tfunction f():Void {\n\t\tvar s: String = Std.string(d());\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * An abstract's `@:to String` conversion runs in a concatenation and not in `Std.string`: `'${b}'` prints `B2` where
	 * `Std.string(b)` prints `2`. A value change with or without null safety, so only an enum abstract free of conversions
	 * over a basic type passes.
	 */
	@:pin('control')
	@:killer('M-INTERP-ENUM-CONVERSION-IGNORED')
	public function testConversionAbstractArgumentNotFlagged(): Void {
		final plain: String = "abstract B(Int) from Int {\n\t@:to function toS():String\n\t\treturn 'B' + this;\n}\n\n"
			+ 'class C {\n\tfunction f(b:B):Void {\n\t\tvar s: String = Std.string(b);\n\t}\n}';
		Assert.equals(0, violations(plain).length);
		final enumTo: String = "enum abstract H(Int) {\n\tvar Three = 3;\n\n\t@:to function toS():String\n\t\treturn 'H' + this;\n}\n\n"
			+ 'class C {\n\tfunction f(h:H):Void {\n\t\tvar s: String = Std.string(h);\n\t}\n}';
		Assert.equals(0, violations(enumTo).length);
	}

	/** An enum abstract over a basic type, with no conversion of its own, prints its underlying value either way. */
	public function testPlainEnumAbstractArgumentFlagged(): Void {
		final src: String = 'enum abstract E(Int) to Int {\n\tvar One = 1;\n}\n\n'
			+ 'class C {\n\tfunction f(e:E):Void {\n\t\tvar s: String = Std.string(e);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * Outside the basic types and the enum abstracts over them the list is closed: a class, a plain abstract and an enum
	 * abstract over `Dynamic` are declined, whatever they would print.
	 */
	@:pin('control')
	@:killer('M-INTERP-ABSTRACT-KIND-UNCHECKED')
	@:killer('M-INTERP-UNDERLYING-UNCHECKED')
	public function testTypesOutsideTheListNotFlagged(): Void {
		final use: String = '\n\nclass C {\n\tfunction f(v:V):Void {\n\t\tvar s: String = Std.string(v);\n\t}\n}';
		Assert.equals(0, violations('class V {}$use').length);
		Assert.equals(0, violations('abstract V(Int) from Int {}$use').length);
		Assert.equals(0, violations('enum abstract V(Dynamic) {\n\tvar One = 1;\n}$use').length);
	}

	/** Arithmetic over proven `Int` operands is an `Int`. */
	public function testIntArithmeticArgumentFlagged(): Void {
		Assert.equals(1, violations(body('var i: Int = 1;\n\t\tvar s: String = Std.string(i + 1);')).length);
	}

}

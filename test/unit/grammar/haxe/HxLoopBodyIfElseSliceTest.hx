package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * omega-loop-body-if-else-next: `sameLine.loopBodyIfElseNext` breaks a `for` / `while` header away from a body that is
 * an `if` WITH an `else`, so the two halves of that `if` sit one indent step under the loop head instead of leaving the
 * `else` at the loop's own indent, where it reads as a branch of the loop.
 *
 * The gate is the CHILD's shape, not a sibling field: `if` without `else` keeps gluing, because
 * `for (xs) if (c) f(x);` is a deliberate project idiom. That is the whole difference from `fitLineIfWithElse`, which
 * one storey down asks whether the `if` BEING placed has an `else` of its own.
 *
 * Every fixture is asserted on BOTH knob states off a config pair that differs in nothing but the knob, so a diff
 * is attributable to the knob rather than to a second config key. Both configs come from real project `hxformat.json`s,
 * because the glue this slice changes only exists under `forBody` / `whileBody: fitLine`: `PROJECT_CONFIG` pairs that
 * with `singleStatementBraces: "remove"` and `fitLineBodyGlue: true`, `REPORTED_CONFIG` with `"symmetric"` braces --
 * the combination the S157 report came from, where the then-branch keeps the braces that put a `}` on the header line.
 */
@:nullSafety(Strict)
final class HxLoopBodyIfElseSliceTest extends Test {

	/** A real project `hxformat.json`, minified. */
	private static final PROJECT_CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,'
		+ '"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAn' + 'ywhereInFile":1,"afterBlocks":"remove","afterLeftCurly":"remove",'
		+ '"beforeRightCurly":"remove","classEmptyLines":{"beginType":1,"endType":1},'
		+ '"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,'
		+ '"endType":1},"uniformStatementBlanks":"collapse","aroundMultilineFields":1},'
		+ '"wrapping":{"comprehensionCuddledOpen":true,"methodChainCuddledLinks":true,"trailin'
		+ 'gComma":"remove","arrayMatrixWrap":"matrixWrapNoAlign",'
		+ '"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"'
		+ 'conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],'
		+ '"type":"noWrap"}]},"maxLineLength":140,"anonType":{"defaultWrap":"ignore","rules":[{"co'
		+ 'nditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},'
		+ '"callParameter":{"defaultWrap":"fillLineWithLeadingBreak",' + '"rules":[{"conditions":[{"cond":"excee'
		+ 'dsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= '
		+ 'n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},'
		+ '"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= '
		+ 'n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond' + '":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine' + '","location":"beforeLast"}]},'
		+ '"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},'
		+ '"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"excee'
		+ 'dsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","locat'
		+ 'ion":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},'
		+ '"objectLiteral":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLine'
		+ 'Length","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength",'
		+ '"value":1}],"type":"packedOrOnePerLine"}]},"arrayWrap":{"defaultWrap":"ignore",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],'
		+ '"type":"packedOrOnePerLine"}]}},"whitespace":{"addLineCommentSpace":false,'
		+ '"normalizeLineCommentIndent":true,"commaPolicy":"after","ifPolicy":"around",'
		+ '"forPolicy":"around","whilePolicy":"around","switchPolicy":"around",'
		+ '"catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none",'
		+ '"functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around",'
		+ '"openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{'
		+ '"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before",'
		+ '"arrowBodyOpenPad":true,"arrowBodyReflow":true},"anonTyp' + 'eBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"'
		+ 'blockBraces":{"openingPolicy":"around","closingPolicy":"before"},'
		+ '"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"singleStatementBraces":"remove"},"parenConfig":{"callParens":{"openingPolicy":"none",'
		+ '"closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none",'
		+ '"closingPolicy":"none"},"conditionParens":{"openingPolicy":"before",'
		+ '"closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none",'
		+ '"closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before",'
		+ '"closingPolicy":"after"},"expressionParens":{"openingPolicy":"none",'
		+ '"closingPolicy":"none"},"switchSubjectParens":"remove"}},"lineEnds":{"emptyCurly":"'
		+ 'noBreak"},"comments":{"blockCommentStyle":"javadoc"},"sameLine":{"caseBody":"fitLine",'
		+ '"expressionCase":"fitLine","ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine",'
		+ '"functionBody":"fitLine","expressionIf":"next","expressionIfFit":true,'
		+ '"expressionIfArrowBodyReflow":true,"elseIfCommentReflow":true,"fitLineBodyGlue":true,'
		+ '"conditionalExprFit":true,"comprehensionFor":"fitLine"}}';

	/** The project config with the knob ON. */
	private static final PROJECT_ON: String = withKnob(PROJECT_CONFIG, true);

	/** The same config with the knob OFF - the pre-slice layout. */
	private static final PROJECT_OFF: String = withKnob(PROJECT_CONFIG, false);

	/** A `for` whose body is a bare `if`/`else` pair, glued: the `else` sits at the `for`'s own indent. */
	private static final FOR_IF_ELSE_GLUED: String = 'class C {\n\n\tfunction apply(values:Dynamic):Void {\n'
		+ '\t\tfor (field in values.fields()) if (_groups.exists(field))\n\t\t\t_groups[field].value = values.field(field);\n'
		+ '\t\telse\n\t\t\ttrace(field);\n\t}\n\n}';

	/** The same `for` with the whole `if`/`else` one step under the header - the `else` now lines up with its `if`. */
	private static final FOR_IF_ELSE_NEXT: String = 'class C {\n\n\tfunction apply(values:Dynamic):Void {\n'
		+ '\t\tfor (field in values.fields())\n\t\t\tif (_groups.exists(field))\n'
		+ '\t\t\t\t_groups[field].value = values.field(field);\n\t\t\telse\n\t\t\t\ttrace(field);\n\t}\n\n}';

	/** A `while` whose body is a BLOCK-bodied `if`/`else`, glued to the header. */
	private static final WHILE_IF_ELSE_GLUED: String = 'class C {\n\n\tfunction fit():Void {\n'
		+ '\t\twhile (true) if (Math.abs(upper - lower) > 2) {\n\t\t\tmid = Std.int((lower + upper) / 2);\n'
		+ '\t\t\tlowerCount = numLines;\n\t\t} else {\n\t\t\tremoved = upper;\n\t\t\tbreak;\n\t\t}\n\t}\n\n}';

	/** The same `while` with the `if`/`else` under the header. */
	private static final WHILE_IF_ELSE_NEXT: String = 'class C {\n\n\tfunction fit():Void {\n'
		+ '\t\twhile (true)\n\t\t\tif (Math.abs(upper - lower) > 2) {\n\t\t\t\tmid = Std.int((lower + upper) / 2);\n'
		+ '\t\t\t\tlowerCount = numLines;\n\t\t\t} else {\n\t\t\t\tremoved = upper;\n\t\t\t\tbreak;\n\t\t\t}\n\t}\n\n}';

	/** The project idiom: a guard `if` with NO `else`, statement body. Must keep gluing under both knob states. */
	private static final FOR_GUARD_STMT: String =
		'class C {\n\n\tfunction apply(xs:Array<Int>):Void {\n\t\tfor (x in xs) if (isWanted(x)) collect(x);\n\t}\n\n}';

	/** The same idiom with a braced body. Must keep gluing too. */
	private static final FOR_GUARD_BLOCK: String = 'class C {\n\n\tfunction apply(xs:Array<Int>):Void {\n'
		+ '\t\tfor (x in xs) if (isWanted(x)) {\n\t\t\tcollect(x);\n\t\t\tnotify(x);\n\t\t}\n\t}\n\n}';

	/** A `while` whose body is a guard `if` with no `else` - the idiom again, on the other loop. */
	private static final WHILE_GUARD_STMT: String =
		'class C {\n\n\tfunction drain():Void {\n\t\twhile (hasNext()) if (isWanted(peek())) collect(take());\n\t}\n\n}';

	/** A loop body that is not an `if` at all - nothing about it changes. */
	private static final FOR_PLAIN_BODY: String =
		'class C {\n\n\tfunction total(xs:Array<Int>):Void {\n\t\tfor (x in xs) sum += x;\n\t}\n\n}';

	/** An `if`/`else` that is NOT a loop body - the knob is scoped to `forBody` / `whileBody` and must not reach it. */
	private static final PLAIN_IF_ELSE: String =
		'class C {\n\n\tfunction pick(flag:Bool):Void {\n\t\tif (flag)\n\t\t\ttakeFirst();\n\t\telse\n\t\t\ttakeSecond();\n\t}\n\n}';

	/**
	 * The SECOND config instance: the `hxformat.json` of the tree the S157 site was reported from, reduced to the keys
	 * that decide this shape. It differs from `PROJECT_CONFIG` in the one key that produces the reported bytes:
	 * `singleStatementBraces` is `"symmetric"`, not `"remove"`, so a single-statement then-branch keeps the braces its
	 * `else` sibling has - which is what leaves a `}` on the header's own line and the `else` at the LOOP's indent.
	 *
	 * At S157 the reduction was measured byte-identical to that file's full 8027-byte form on all twelve fixtures below,
	 * in both knob states. It drops the `wrapping` rule sets, the `comments` section and most of `whitespace`, so a
	 * fixture added later that carries a wrapped call, an object literal or an interior comment can diverge with nothing
	 * here to notice it.
	 */
	private static final REPORTED_CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,'
		+ '"alignInlineSwitchCaseBody":true},"wrapping":{"maxLineLength":140},"whitespace":{"typeHintColonPolicy":"after",'
		+ '"ifPolicy":"around","forPolicy":"around","whilePolicy":"around","binopPolicy":"around","intervalPolicy":"around",'
		+ '"commaPolicy":"after","bracesConfig":{"singleStatementBraces":"symmetric","blockBraces":{"openingPolicy":"around",'
		+ '"closingPolicy":"before"}},"parenConfig":{"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"callParens":{"openingPolicy":"none",'
		+ '"closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine",'
		+ '"whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next"},"emptyLines":{"maxAnywhereInFile":2,'
		+ '"afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1}}}';

	/** The reported config with the knob ON. */
	private static final REPORTED_ON: String = withKnob(REPORTED_CONFIG, true);

	/** The reported config with the knob OFF. */
	private static final REPORTED_OFF: String = withKnob(REPORTED_CONFIG, false);

	/** The reported site verbatim: a braced `if`/`else` glued to the `for`, so `} else {` sits at the loop's indent. */
	private static final REPORTED_GLUED: String = 'class C {\n\n\tfunction args(): Dynamic {\n'
		+ '\t\tfinal a: Array<String> = getArgs();\n\t\tvar skip: Bool = true;\n\t\tfor (i in 0...a.Length) if (skip) {\n'
		+ '\t\t\tskip = false;\n\t\t} else {\n\t\t\tuse(a[i]);\n\t\t}\n\t\treturn null;\n\t}\n\n}';

	/** The bytes the report asks for: the `for` header alone, the whole `if`/`else` one indent step under it. */
	private static final REPORTED_NEXT: String = 'class C {\n\n\tfunction args(): Dynamic {\n'
		+ '\t\tfinal a: Array<String> = getArgs();\n\t\tvar skip: Bool = true;\n\t\tfor (i in 0...a.Length)\n'
		+ '\t\t\tif (skip) {\n\t\t\t\tskip = false;\n\t\t\t} else {\n\t\t\t\tuse(a[i]);\n\t\t\t}\n\t\treturn null;\n\t}\n\n}';

	/**
	 * The shape the reporter's own layout rule REQUIRES to stay glued, in the same braced spelling the reported site has:
	 * a `for` whose body is an `if` with NO `else`, once with a two-statement body and once with a single-statement one.
	 */
	private static final REPORTED_GUARD: String = 'class G {\n\n\tfunction apply(xs: Array<Int>): Void {\n'
		+ '\t\tfor (x in xs) if (isWanted(x)) {\n\t\t\tcollect(x);\n\t\t\tnotify(x);\n\t\t}\n'
		+ '\t\tfor (y in xs) if (isWanted(y)) {\n\t\t\tcollect(y);\n\t\t}\n\t}\n\n}';

	/** The `do ... while` twin of the reported shape: the body glues to `do`, so the `else` sits at the `do`'s indent. */
	private static final DO_WHILE_GLUED: String = 'class W {\n\n\tfunction f(): Void {\n\t\tdo if (skip) {\n'
		+ '\t\t\tskip = false;\n\t\t} else {\n\t\t\tuse(skip);\n\t\t} while (skip);\n\t}\n\n}';

	/** The same `do ... while` with the whole `if`/`else` one indent step under the `do`. */
	private static final DO_WHILE_NEXT: String = 'class W {\n\n\tfunction f(): Void {\n\t\tdo\n\t\t\tif (skip) {\n'
		+ '\t\t\t\tskip = false;\n\t\t\t} else {\n\t\t\t\tuse(skip);\n\t\t\t} while (skip);\n\t}\n\n}';

	/** The guard idiom on `do ... while`: an `if` with NO `else`, so the key must leave it glued to the `do`. */
	private static final DO_WHILE_GUARD: String = 'class W {\n\n\tfunction f(): Void {\n\t\tdo if (isWanted(x)) {\n'
		+ '\t\t\tcollect(x);\n\t\t\tnotify(x);\n\t\t} while (skip);\n\t}\n\n}';

	/** The reported `for` site: with the knob on, the `else` moves under its own `if`. */
	@:pin('control')
	@:killer('M-LOOPIF-NEVER')
	public function testForIfElseBreaksUnderHeader(): Void {
		Assert.equals(FOR_IF_ELSE_NEXT, triviaWrite(FOR_IF_ELSE_GLUED, PROJECT_ON));
		Assert.equals(FOR_IF_ELSE_GLUED, triviaWrite(FOR_IF_ELSE_GLUED, PROJECT_OFF));
	}

	/** The reported `while` site: a block-bodied `if`/`else` takes the same break. */
	@:pin('control')
	@:killer('M-LOOPIF-NEVER')
	public function testWhileIfElseBreaksUnderHeader(): Void {
		Assert.equals(WHILE_IF_ELSE_NEXT, triviaWrite(WHILE_IF_ELSE_GLUED, PROJECT_ON));
		Assert.equals(WHILE_IF_ELSE_GLUED, triviaWrite(WHILE_IF_ELSE_GLUED, PROJECT_OFF));
	}

	/** Already broken: writing the target shape again reproduces it, so one `fmt` pass is a fixed point. */
	@:pin('control')
	@:killer('M-LOOPIF-NEVER')
	public function testBrokenShapeIsIdempotent(): Void {
		Assert.equals(FOR_IF_ELSE_NEXT, triviaWrite(FOR_IF_ELSE_NEXT, PROJECT_ON));
		Assert.equals(WHILE_IF_ELSE_NEXT, triviaWrite(WHILE_IF_ELSE_NEXT, PROJECT_ON));
	}

	/** The project idiom is the population the gate exists to spare: no `else`, so the body stays on the header line. */
	@:pin('control')
	@:killer('M-LOOPIF-ALWAYS')
	public function testGuardIfWithoutElseStaysGlued(): Void {
		Assert.equals(FOR_GUARD_STMT, triviaWrite(FOR_GUARD_STMT, PROJECT_ON));
		Assert.equals(FOR_GUARD_STMT, triviaWrite(FOR_GUARD_STMT, PROJECT_OFF));
		Assert.equals(FOR_GUARD_BLOCK, triviaWrite(FOR_GUARD_BLOCK, PROJECT_ON));
		Assert.equals(FOR_GUARD_BLOCK, triviaWrite(FOR_GUARD_BLOCK, PROJECT_OFF));
		Assert.equals(WHILE_GUARD_STMT, triviaWrite(WHILE_GUARD_STMT, PROJECT_ON));
		Assert.equals(WHILE_GUARD_STMT, triviaWrite(WHILE_GUARD_STMT, PROJECT_OFF));
	}

	/** A non-`if` loop body and an `if`/`else` outside a loop are both outside the gate. */
	@:pin('control')
	@:killer('M-LOOPIF-ALWAYS')
	public function testNonLoopAndNonIfBodiesUnchanged(): Void {
		Assert.equals(FOR_PLAIN_BODY, triviaWrite(FOR_PLAIN_BODY, PROJECT_ON));
		Assert.equals(FOR_PLAIN_BODY, triviaWrite(FOR_PLAIN_BODY, PROJECT_OFF));
		Assert.equals(PLAIN_IF_ELSE, triviaWrite(PLAIN_IF_ELSE, PROJECT_ON));
		Assert.equals(PLAIN_IF_ELSE, triviaWrite(PLAIN_IF_ELSE, PROJECT_OFF));
	}

	/**
	 * The reported site, on the config it was reported from: the knob moves the whole `if`/`else` under the header and
	 * changes nothing else, and leaves the site alone while it is off.
	 */
	@:pin('control')
	@:killer('M-LOOPIF-NEVER')
	public function testReportedSiteBreaksUnderHeader(): Void {
		Assert.equals(REPORTED_NEXT, triviaWrite(REPORTED_GLUED, REPORTED_ON));
		Assert.equals(REPORTED_GLUED, triviaWrite(REPORTED_GLUED, REPORTED_OFF));
		Assert.equals(REPORTED_NEXT, triviaWrite(REPORTED_NEXT, REPORTED_ON));
	}

	/**
	 * The braced guard `if` - no `else` - is the population the gate spares, and the reported config's `"symmetric"`
	 * braces are what make it look like the reported site. Both spellings stay glued under both knob states.
	 */
	@:pin('control')
	@:killer('M-LOOPIF-ALWAYS')
	public function testReportedConfigGuardStaysGlued(): Void {
		Assert.equals(REPORTED_GUARD, triviaWrite(REPORTED_GUARD, REPORTED_ON));
		Assert.equals(REPORTED_GUARD, triviaWrite(REPORTED_GUARD, REPORTED_OFF));
	}

	/**
	 * The knob is the ONLY way to hold the broken-out shape: with it off the writer RE-JOINS a site written the way the
	 * report asks for, because `forBody: fitLine` glues any body whose first line fits. So the two forms are NOT both
	 * fixed points, and hand-editing the site does not survive one `fmt` pass. Neither arm can flip this: the flag gates the shape
	 * probe, so an off knob answers the same either way. Hence the `guard` role rather than a killable one.
	 */
	@:pin('guard')
	public function testKnobOffRejoinsAHandBrokenSite(): Void {
		Assert.equals(REPORTED_GLUED, triviaWrite(REPORTED_NEXT, REPORTED_OFF));
		Assert.equals(FOR_IF_ELSE_GLUED, triviaWrite(FOR_IF_ELSE_NEXT, PROJECT_OFF));
	}

	/**
	 * The whole 4x2 placement table on the reported site, in one pin. S157 shipped the key gated on the `FitLine`
	 * LAYOUT, so `same` and `keep` produced the reported defect and the key documented for them was silent; S159 moved
	 * the gate onto the policy VALUE, upstream of every layout, and all four placements answer it.
	 *
	 * Off (or absent, which is the same `false`) every placement keeps the bytes it had before the key existed:
	 * `fitLine` / `same` glue whatever the source did, `keep` reproduces the glued source, `next` breaks every body.
	 * On, all four produce ONE shape - the `next` bytes.
	 */
	@:pin('control')
	@:killer('M-LOOPIF-POLICY-BLIND')
	public function testEveryPlacementObeysTheKey(): Void {
		for (placement in ['fitLine', 'same', 'keep', 'next']) {
			Assert.equals(REPORTED_NEXT, triviaWrite(REPORTED_GLUED, withPlacement(REPORTED_ON, placement)), 'on/$placement');
			Assert.equals(
				placement == 'next' ? REPORTED_NEXT : REPORTED_GLUED, triviaWrite(REPORTED_GLUED, withPlacement(REPORTED_OFF, placement)),
				'off/$placement'
			);
		}
	}

	/**
	 * `keep` is the placement that reads the source, and the key has to win over it without taking the reading away: off, both
	 * source forms come back verbatim; on, both land on the broken-out one.
	 *
	 * Only the third assertion can fail under an arm - it is the table pin's `on/keep` cell again. The one that earns this pin
	 * its own place is the SECOND: `keep` reproducing a hand-broken source is the only proof in this file that `"keep"` reaches
	 * `BodyPolicy.Keep` at all rather than degrading to `Same`, which is what `HxFormatBodyPolicy` claimed until S159 read the
	 * loader.
	 */
	@:pin('control')
	@:killer('M-LOOPIF-KEEP-BLIND')
	public function testKeepPlacementObeysTheKeyAndStillReadsTheSource(): Void {
		final keepOn: String = withPlacement(REPORTED_ON, 'keep');
		final keepOff: String = withPlacement(REPORTED_OFF, 'keep');
		Assert.equals(REPORTED_GLUED, triviaWrite(REPORTED_GLUED, keepOff));
		Assert.equals(REPORTED_NEXT, triviaWrite(REPORTED_NEXT, keepOff));
		Assert.equals(REPORTED_NEXT, triviaWrite(REPORTED_GLUED, keepOn));
		Assert.equals(REPORTED_NEXT, triviaWrite(REPORTED_NEXT, keepOn));
	}

	/**
	 * The guard idiom - an `if` with NO `else` - is the population the key exists to spare, and widening the key from
	 * one layout to the policy value must not widen the SHAPE it acts on. It stays glued under every placement that
	 * glues at all; `next` is left out because it breaks every loop body by construction, which is the cost this key
	 * exists to avoid.
	 */
	@:pin('control')
	@:killer('M-LOOPIF-ALWAYS')
	public function testGuardStaysGluedUnderEveryPlacement(): Void {
		for (placement in ['fitLine', 'same', 'keep']) {
			Assert.equals(REPORTED_GUARD, triviaWrite(REPORTED_GUARD, withPlacement(REPORTED_ON, placement)), 'on/$placement');
			Assert.equals(REPORTED_GUARD, triviaWrite(REPORTED_GUARD, withPlacement(REPORTED_OFF, placement)), 'off/$placement');
			Assert.equals(DO_WHILE_GUARD, triviaWrite(DO_WHILE_GUARD, doWhileConfig(placement, true)), 'do-on/$placement');
			Assert.equals(DO_WHILE_GUARD, triviaWrite(DO_WHILE_GUARD, doWhileConfig(placement, false)), 'do-off/$placement');
		}
	}

	/**
	 * `do ... while` glues an `if`/`else` to its keyword under every placement but `next`, and until S159 the key did
	 * not reach it: it is wired on `HxDoWhileStmt.body`, whose value is an `HxDoWhileBody`, so the `if` arrives as
	 * `ExprBody(IfExpr(...))` where the `for` / `while` twin has a bare `IfStmt(...)`. The one-level unwrap in
	 * `LoopBodyShape.isIfWithElse` is what closes it, and this pin is S157's `guard` record turned into a control.
	 */
	@:pin('control')
	@:killer('M-LOOPIF-NOWRAP')
	public function testDoWhileIfElseBreaksUnderHeader(): Void {
		for (placement in ['fitLine', 'same', 'keep', 'next']) {
			Assert.equals(DO_WHILE_NEXT, triviaWrite(DO_WHILE_GLUED, doWhileConfig(placement, true)), 'on/$placement');
			Assert.equals(
				placement == 'next' ? DO_WHILE_NEXT : DO_WHILE_GLUED, triviaWrite(DO_WHILE_GLUED, doWhileConfig(placement, false)),
				'off/$placement'
			);
			Assert.equals(DO_WHILE_NEXT, triviaWrite(DO_WHILE_NEXT, doWhileConfig(placement, true)), 'idempotent/$placement');
		}
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/**
	 * Splice the one key under test into a config's `sameLine` section, so a fixture pair differs in nothing else.
	 */
	private static function withKnob(source: String, knobOn: Bool): String {
		return source.replace('"sameLine":{', '"sameLine":{"loopBodyIfElseNext":${knobOn ? 'true' : 'false'},');
	}

	/**
	 * Move `REPORTED_CONFIG`'s loop-body placement off `fitLine`, both loops at once, so a cell of the table differs
	 * from its neighbour in the placement alone.
	 */
	private static function withPlacement(source: String, placement: String): String {
		return source.replace('"forBody":"fitLine","whileBody":"fitLine"', '"forBody":"$placement","whileBody":"$placement"');
	}

	/**
	 * `doWhileBody` is absent from every config in this file and from the reporting tree's own, so the do-while table
	 * has to add it: the default `Next` already breaks the body and there is nothing to decline.
	 */
	private static function doWhileConfig(placement: String, knobOn: Bool): String {
		return withKnob(REPORTED_CONFIG.replace('"sameLine":{', '"sameLine":{"doWhileBody":"$placement",'), knobOn);
	}

}

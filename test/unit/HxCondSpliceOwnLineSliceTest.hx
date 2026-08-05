package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice F1 -- the OWN-LINE gate on word-like postfix operators
 * (`Lowering.buildPostfixOpMatchExpr`, the only word-like postfix op being
 * `HxExpr.CondSpliceTail`'s `#if`).
 *
 * A `#if` sitting on its own line after a complete operand is ambiguous:
 * it is either an infix SPLICE TAIL continuing that operand, or a
 * SCOPE-level conditional region (statement / param-list / array-element)
 * that belongs to its own production. The gate used to reject the newline
 * unconditionally, which kept every scope-level region safe but also
 * skip-parsed the two legitimate splice tails.
 *
 * Both directions are pinned here, because the rejection half is a
 * REGRESSION GUARD: an earlier attempt at this slice relaxed the gate on
 * the operand's trailing byte alone and silently re-broke four live
 * shapes (two dogfood trees, two haxe-formatter fixtures) that the unit
 * suite alone did not notice.
 */
@:nullSafety(Strict)
final class HxCondSpliceOwnLineSliceTest extends HxTestHelpers {

	/**
	 * The dogfood project's own wrapping profile, reduced to the two knobs
	 * the chain-wrap consequence needs: a 140-column budget and cuddled
	 * method-chain links.
	 */
	private static final WIDTH_140_CHAIN_CONFIG: String =
		'{"wrapping": {"maxLineLength": 140, "methodChainCuddledLinks": true}, "indentation": {"character": "tab", "tabWidth": 4}}';

	/**
	 * `lime/system/ThreadPool.hx:1029` -- an own-line `#if` whose fragment
	 * opens with the infix `-`. Skip-parse before this slice.
	 */
	public function testOwnLineInfixSpliceTailParsesAsSpliceTail(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function get_idleThreads():Int {\n\t\treturn __idleThreads\n'
			+ '\t\t#if lime_threads - __queuedExitEvents #end;\n\t} }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case ReturnStmt(value):
				switch value {
					case CondSpliceTail(_, _):
						Assert.pass();
					case null, _:
						Assert.fail('expected ReturnStmt(CondSpliceTail), got $value');
				}
			case null, _:
				Assert.fail('expected ReturnStmt, got ${body[0]}');
		}
	}

	/**
	 * `std/js/Boot.hx:151` -- the same gap, in an `if` CONDITION operand,
	 * with an own-line comment between the operand and the `#if` and a
	 * parenthesised preprocessor condition followed by the infix `&&`.
	 * The condition-atom skip in `spliceFragmentIsInfix` is what sees
	 * past `(js_es >= 6)` to the `&&`.
	 */
	public function testOwnLineInfixSpliceTailInConditionOperandParses(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f(cc, cl) {\n\t\tif (intf != null\n' + '\t\t\t// ES6 classes inherit statics\n'
			+ '\t\t\t#if (js_es >= 6) && (cc.__super__ == null) #end\n\t\t) {\n\t\t\tg();\n\t\t}\n\t} }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected IfStmt, got ${body[0]}');
		}
	}

	/**
	 * REGRESSION GUARD -- the original dogfood catch recorded in the gate's
	 * own comment, live at `TM-Haxe4/src/video/GpuDirectPipeline.hx:52`: a
	 * `@:privateAccess { ... }` block statement followed by an own-line
	 * `#if debug ... #end` and then more statements. Swallowing the region
	 * as a splice tail makes the whole function body fail on `h();`.
	 */
	public function testOwnLineStatementConditionalAfterMetaBlockStaysStructured(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f() {\n\t\t@:privateAccess {\n\t\t\tg();\n\t\t}\n'
			+ '\t\t#if debug\n\t\tfinal t1:Float = Sys.time();\n\t\t#end\n\t\th();\n\t} }'
		);
		Assert.equals(3, body.length);
		switch body[1] {
			case Conditional(inner):
				Assert.equals(1, inner.body.length);
			case null, _:
				Assert.fail('expected structured Conditional, got ${body[1]}');
		}
	}

	public function testOwnLineStatementConditionalAfterMetaBlockRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t@:privateAccess {\n\t\t\tg();\n\t\t}\n'
			+ '\t\t#if debug\n\t\tfinal t1:Float = Sys.time();\n\t\t#end\n\t\th();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD -- `pony/ui/xml/HeapsXmlUi.hx:202`: a `switch`
	 * assignment (block-ended, no `;` of its own before the region's line)
	 * followed by an own-line dangling-if `CondSpliceStmt`. Both halves of
	 * the gate reject here: the operand ends with `}` and the fragment
	 * opens with the `if` keyword.
	 */
	public function testOwnLineStatementSpliceAfterSwitchStaysStatementScoped(): Void {
		final src: String = 'class C {\n\tfunction f(obj, attrs) {\n\t\tvar obj = switch name {\n\t\t\tcase _:\n'
			+ '\t\t\t\tcustomUIElement(name);\n\t\t}\n\t\t#if (haxe_ver >= 4.10)\n\t\tif (Std.isOfType(obj, Node))\n'
			+ '\t\t#else\n\t\tif (Std.is(obj, Node))\n\t\t#end\n\t\tsetNodeAttrs(cast obj, attrs);\n\t\tobj.name = attrs.name;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD -- `whitespace/issue_582_type_hints_conditionals`.
	 * The operand is a parameter DEFAULT VALUE, so it does not end with
	 * `}`; only the infix test keeps the region on `HxConditionalParam`.
	 * The fragment opens with the list separator `,`.
	 */
	public function testOwnLineParamListConditionalStaysParamScoped(): Void {
		final src: String = 'extern class TouchEvent extends Event {\n' + '\tpublic function new(isTouchPointCanceled:Bool = false\n'
			+ '\t\t#if air, commandKey:Bool = false, ?timestamp:Float #end);\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD -- `wrapping/issue_207_array_wrapping_with_conditionals`.
	 * The operand is the previous array element, and the fragment opens
	 * with a metadata `@`.
	 */
	public function testOwnLineArrayElementConditionalStaysElementScoped(): Void {
		final src: String = 'class Main {\n\tpublic static function main() {\n\t\tvar argHandler = hxargs.Args.generate([\n'
			+ '\t\t\t@doc("check")\n\t\t\t["--check"] => function() mode = Check,\n\n'
			+ '\t\t\t#if debug\n\t\t\t@doc("stability")\n\t\t\t["--check-stability"] => function() mode = CheckStability,\n'
			+ '\t\t\t#end\n\n'
			+ '\t\t\t#if debug\n\t\t\t@doc("stability")\n\t\t\t["--check-stability"] => function() mode = CheckStability,\n'
			+ '\t\t\t#end\n\t\t]);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD -- `dogfood utils/CleanExit.hx:36`: a bare-body
	 * expression `try` whose catch body is a `{}` block, followed by an
	 * own-line `#if cpp ... #else ... #end` statement region.
	 *
	 * The gap-scan half of the gate (`hasNewlineIn(_preWsPos, ctx.pos)`) is
	 * BLIND here in Trivia mode: `HxTryCatchExpr.catches` is a
	 * `@:trivia @:tryparse` Star whose no-match iteration already consumed
	 * the `\n` and stashed the signal into `ctx.pendingTrivia`, so the
	 * postfix loop saves `_preWsPos` PAST the newline and reads the region
	 * as a SAME-LINE splice tail. The stash is the second newline source --
	 * same mechanism the `captureChainNewline` chain-newline capture already
	 * reads (`Lowering.chainNlValue`).
	 */
	public function testOwnLineStatementConditionalAfterBareBodyTryRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(code:Int) {\n\t\ttry a() catch (_:Exception) {}\n'
			+ '\t\t#if cpp\n\t\tb(code);\n\t\t#else\n\t\tc(code);\n\t\t#end\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The consequence of the mis-parse above, at the WRITER level: with the
	 * region bound as a `CondSpliceTail` postfix, its whole raw fragment
	 * joins the operand's rest-stack, so the width probe on the try body's
	 * method chain sees ~200 columns and breaks a chain that fits on one
	 * line. The neighbouring `stdout` statement (identical length, no
	 * region after it) stays flat -- the asymmetry is the tell.
	 */
	public function testOwnLineConditionalAfterTryDoesNotForceChainWrap(): Void {
		final src: String = 'class C {\n\tpublic static function exit(code:Int):Void {\n'
			+ '\t\ttry Sys.stdout().flush() catch (_:Exception) {}\n\t\ttry Sys.stderr().flush() catch (_:Exception) {}\n'
			+ '\t\t#if cpp\n\t\t// skips C++ static destructors and atexit handlers, unlike the libc\n'
			+ '\t\t// exit() route that Sys.exit takes on every hxcpp target\n'
			+ '\t\tuntyped __cpp__("std::_Exit({0})", code);\n\t\t#else\n\t\tSys.exit(code);\n\t\t#end\n\t}\n}';
		Assert.equals(src, triviaWrite(src, WIDTH_140_CHAIN_CONFIG));
	}

	/**
	 * REGRESSION GUARD, the other direction: a SAME-LINE `#if` after a
	 * block-ended operand is still a splice tail. The gate only ever
	 * consults the operand's trailing byte and the fragment shape when the
	 * gap actually contains a newline.
	 */
	public function testSameLineSpliceTailAfterBlockStillBinds(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f() { return {a: 1} #if x + 1 #end; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ReturnStmt(value):
				switch value {
					case CondSpliceTail(_, _):
						Assert.pass();
					case null, _:
						Assert.fail('expected ReturnStmt(CondSpliceTail), got $value');
				}
			case null, _:
				Assert.fail('expected ReturnStmt, got ${body[0]}');
		}
	}

	/**
	 * An own-line region with an EMPTY fragment (`#end` right after the
	 * condition) is never a splice tail: nothing continues the operand.
	 * Pins the `#` byte being outside the infix set.
	 */
	public function testOwnLineEmptyRegionIsNotASpliceTail(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f() {\n\t\tg();\n\t\t#if debug\n\t\th();\n\t\t#end\n\t} }');
		Assert.equals(2, body.length);
		switch body[1] {
			case Conditional(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected structured Conditional, got ${body[1]}');
		}
	}

	private function parseBody(source: String): Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

	private inline function triviaWrite(src: String, ?json: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json ?? '{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}

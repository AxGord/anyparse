package unit.grammar.haxe;

import anyparse.format.SameLinePolicy;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A brace-less value `try` that does not fit breaks at its seams — body on its own indented line,
 * `catch` at the statement's indent, the same shape a value `if` takes under
 * `sameLine.expressionIf: next` — whatever the call or array inside it looks like; one that fits stays on one
 * line. `sameLine.expressionTryOverflow: same` keeps the body on the `try` line and breaks before `catch` only.
 */
final class HxTryOverflowLayoutTest extends Test {

	private static final CONFIG: String = '{"wrapping":{"maxLineLength":140}}';
	private static final CONFIG_A: String = '{"wrapping":{"maxLineLength":140},"sameLine":{"expressionTryOverflow":"same"}}';
	private static final CONFIG_KEEP_ARRAY: String = '{"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWrap":"onePerLine"}}}';
	private static final CONFIG_IF_FIT: String =
		'{"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWrap":"onePerLine"}},"sameLine":{"ifBody":"fitLine","expressionIf":"next"}}';
	private static final CALL_2: String = 'PackageDocumentCarry.carry(documents, members[0].keys)';
	private static final CALL_1: String = 'PackageDocumentCarry.carry(documentsdocumentsdocumentsdocumentsdocuments)';
	private static final CATCH: String = 'catch (exception:Exception)';
	private static final BODY: String = "return Left([new MoveRefusal('document', 'carry', exception.message, 'aaaaaaaaaaaaaaaaaaaaa')])";
	private static final LEFT: String = "Left([new MoveRefusal('document', 'carry', exception.message, 'aaaaaaaaaaaaaaaaaaaaa')])";

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-TRY-FIT-BODY-HARD')
	public function testATwoArgumentCallBreaksAtTheSeams(): Void {
		final src: String = inClass('final carried: CarriedDocuments = try $CALL_2 $CATCH $BODY;');
		contains(
			HxWriteFixture.triviaWrite(src, CONFIG), expectLines(['final carried:CarriedDocuments = try', '\t$CALL_2', CATCH, '\t$BODY;'])
		);
	}

	@:pin('control')
	@:killer('M-TRY-FIT-SEP-HARD')
	public function testAOneArgumentCallTakesTheSameShape(): Void {
		final src: String = inClass('final carried: CarriedDocuments = try $CALL_1 $CATCH $BODY;');
		contains(
			HxWriteFixture.triviaWrite(src, CONFIG), expectLines(['final carried:CarriedDocuments = try', '\t$CALL_1', CATCH, '\t$BODY;'])
		);
	}

	@:pin('guard')
	public function testAStatementBelowATryLaysOutAsOutsideATry(): Void {
		final cells: Array<String> = [for (c in ['a', 'b', 'c', 'd', 'e']) c.lpad('x', 16)];
		final stmt: String = 'if (foo([${cells.join(', ')}])) x();';
		final src: String = inClass([
			'final a: Int = try run(function() { $stmt }) catch (e: Any) null;',
			'final b: Int = try { $stmt 1; } catch (e: Any) { $stmt 2; };',
			'final c: Int = try g() catch (e: Any) run(() -> { $stmt });',
			'final outside: Int = run(function() { $stmt });'
		].join('\n'));
		final out: String = HxWriteFixture.triviaWrite(src, CONFIG_IF_FIT);
		Assert.equals(5, out.split('\t\t\t\t${cells.join(',\n\t\t\t\t')}\n\t\t\t]))\n\t\t\t\tx();').length - 1, out);
	}

	@:pin('control')
	@:killer('M-TRY-FIT-SEP-HARD')
	public function testEachCatchClauseTakesItsOwnLines(): Void {
		final src: String = inClass('final y: Int = try $CALL_2 catch (a: Exception) $LEFT catch (b: Any) $LEFT;');
		contains(HxWriteFixture.triviaWrite(src, CONFIG), expectLines([
			'final y:Int = try',
			'\t$CALL_2',
			'catch (a:Exception)',
			'\t$LEFT',
			'catch (b:Any)',
			'\t$LEFT;'
		]));
	}

	@:pin('control')
	@:killer('M-TRY-FIT-GROUP-NONE')
	public function testAFittingTryStaysOnOneLine(): Void {
		final src: String = inClass('final fits: Int = try g(a, b) catch (e: Any) 0;');
		contains(HxWriteFixture.triviaWrite(src, CONFIG), '\t\tfinal fits:Int = try g(a, b) catch (e:Any) 0;');
	}

	@:pin('control')
	@:killer('M-TRY-FIT-STAR-BOUNDARY')
	public function testAFittingTryInACallArgumentStaysOnOneLine(): Void {
		final src: String = inClass('foo(try g(a) catch (e: Any) null, 1);');
		contains(HxWriteFixture.triviaWrite(src, CONFIG), '\t\tfoo(try g(a) catch (e:Any) null, 1);');
	}

	@:pin('control')
	@:killer('M-TRY-FIT-COMMENT-INSIDE')
	public function testAClosingLineCommentDoesNotBreakAFittingTry(): Void {
		final src: String = inClass('try g(a) catch (e: Any) {} // c');
		contains(HxWriteFixture.triviaWrite(src, CONFIG), '\t\ttry g(a) catch (e:Any) {} // c');
	}

	@:pin('control')
	@:killer('M-TRY-OVERFLOW-KEY')
	public function testTheKeyKeepsTheBodyOnTheTryLine(): Void {
		Assert.equals(SameLinePolicy.Same, HxWriteOptionsKit.strictJson(CONFIG_A).expressionTryOverflow);
		final src: String = inClass('final carried: CarriedDocuments = try $CALL_2 $CATCH $BODY;');
		contains(HxWriteFixture.triviaWrite(src, CONFIG_A), '\t\tfinal carried:CarriedDocuments = try $CALL_2\n');
	}

	@:pin('control')
	@:killer('M-TRY-A-TAIL-NEST')
	public function testTheKeyIndentsEachCatchOnce(): Void {
		final src: String = inClass('final carried: CarriedDocuments = try $CALL_2 $CATCH $BODY catch (b: Any) $LEFT;');
		contains(HxWriteFixture.triviaWrite(src, CONFIG_A), '\n\t\t\t$CATCH $BODY\n\t\t\tcatch (b:Any) $LEFT;');
	}

	@:pin('guard')
	public function testABracedTryKeepsItsShape(): Void {
		final src: String = inClass('final x: Int = try { g(); } catch (e: Any) { h(); };');
		contains(HxWriteFixture.triviaWrite(src, CONFIG), 'try {\n\t\t\tg();\n\t\t} catch (e:Any) {\n\t\t\th();\n\t\t}');
	}

	@:pin('guard')
	public function testAStatementTryStaysOnItsLadder(): Void {
		final src: String = inClass('try $CALL_2 $CATCH trace($LEFT);');
		contains(HxWriteFixture.triviaWrite(src, CONFIG), expectLines(['try', '\t$CALL_2', CATCH, '\ttrace($LEFT);']));
	}

	@:pin('guard')
	public function testTheLayoutIsAFixedPoint(): Void {
		for (config in [CONFIG, CONFIG_A]) {
			final once: String = HxWriteFixture.triviaWrite(
				inClass('final y: Int = try $CALL_2 catch (a: Exception) $LEFT catch (b: Any) $LEFT;'), config
			);
			Assert.equals(once, HxWriteFixture.triviaWrite(once, config));
		}
	}

	@:pin('guard')
	public function testThePlainWriterBreaksAtTheSeams(): Void {
		final src: String = inClass('final carried: CarriedDocuments = try $CALL_2 $CATCH $BODY;');
		final out: String = HxWriteFixture.plainWrite(src, CONFIG);
		contains(out, '$CATCH\n');
		Assert.equals(out, HxWriteFixture.plainWrite(out, CONFIG));
	}

	@:pin('guard')
	public function testAWideArrayIsAFixedPointInOnePass(): Void {
		final wide: String = '[' + [for (i in 0...9) 'xxxxxxxxxxxxxx$i'].join(', ') + ']';
		for (stmt in [
			'final a: Int = try run($wide) catch (e: Any) null;',
			'final a: Int = try run(first, $wide) catch (e: Any) null;',
			'final a: Int = try run(first) catch (e: Any) return Left($wide);'
		]) {
			final once: String = HxWriteFixture.triviaWrite(inClass(stmt), CONFIG_KEEP_ARRAY);
			contains(once, 'try\n\t\t\trun(');
			contains(once, '\t\tcatch (e:Any)\n');
			Assert.equals(once, HxWriteFixture.triviaWrite(once, CONFIG_KEEP_ARRAY));
		}
	}

	@:pin('control')
	@:killer('M-TRY-LIST-BODY')
	public function testAnArrayCatchBodyTakesItsOwnLine(): Void {
		final name: String = filler(120);
		contains(
			HxWriteFixture.triviaWrite(inClass('final v: Dynamic = try $name() catch (e:Any) [];'), CONFIG),
			expectLines(['final v:Dynamic = try', '\t$name()', 'catch (e:Any)', '\t[];'])
		);
	}

	@:pin('control')
	@:killer('M-TRY-LIST-SEP')
	public function testAnArrayTryBodyTakesItsOwnLine(): Void {
		final name: String = filler(120);
		contains(
			HxWriteFixture.triviaWrite(inClass('final v: Dynamic = try [] catch (e:Any) $name();'), CONFIG),
			expectLines(['final v:Dynamic = try', '\t[]', 'catch (e:Any)', '\t$name();'])
		);
	}

	@:pin('control')
	@:killer('M-TRY-LIST-SEP-PLAIN')
	public function testThePlainWriterPutsAnArrayTryBodyOnItsOwnLine(): Void {
		final name: String = filler(120);
		contains(
			HxWriteFixture.plainWrite(inClass('final v: Dynamic = try [] catch (e:Any) $name();'), CONFIG),
			expectLines(['final v:Dynamic = try', '\t[]', 'catch (e:Any)', '\t$name();'])
		);
	}

	@:pin('control')
	@:killer('M-TRY-LIST-NEXT-GLUE')
	public function testExpressionTryNextKeepsAnArrayBodyGlued(): Void {
		final config: String = '{"wrapping":{"maxLineLength":140},"sameLine":{"expressionTry":"next"}}';
		contains(HxWriteFixture.triviaWrite(inClass('final v: Dynamic = try x() catch (e:Any) [];'), config), 'catch (e:Any) [];');
	}

	@:pin('control')
	@:killer('M-TRY-A-TAIL-NEST-NEXT')
	public function testTheKeyDoesNotReachExpressionTryNext(): Void {
		final src: String = inClass('final y: Int = try $CALL_2 catch (a:Exception) { h(); } catch (b:Any) $LEFT;');
		final next: String = HxWriteFixture.triviaWrite(src, '{"wrapping":{"maxLineLength":140},"sameLine":{"expressionTry":"next"}}');
		Assert.equals(
			next,
			HxWriteFixture.triviaWrite(
				src, '{"wrapping":{"maxLineLength":140},"sameLine":{"expressionTry":"next","expressionTryOverflow":"same"}}'
			)
		);
	}

	@:pin('control')
	@:killer('M-TRY-FIT-REST-DEFER')
	public function testAnOverflowingTryInACallArgumentBreaksTheCallFirst(): Void {
		final name: String = filler(100);
		final out: String = HxWriteFixture.triviaWrite(inClass('foo(try $name() catch (e:Any) null, 1);'), CONFIG);
		contains(out, 'try $name() catch (e:Any) null,\n\t\t\t1);');
		Assert.isTrue(out.indexOf('try\n') == -1, out);
	}

	@:pin('control')
	@:killer('M-TRY-FIT-REST-DEFER')
	public function testAnOverflowingTryInATernaryArmBreaksTheTernaryFirst(): Void {
		final name: String = filler(98);
		contains(
			HxWriteFixture.triviaWrite(inClass('final t: Int = condition ? try $name() catch (e:Any) null : otherValueOtherValue;'), CONFIG),
			'\t\t\t? try $name() catch (e:Any) null\n\t\t\t: otherValueOtherValue;'
		);
	}

	@:pin('control')
	@:killer('M-TRY-FIT-GROUP-PLAIN')
	public function testTheRestOfTheLineCountsAtTheBoundary(): Void {
		final atLimit: String = inClass('final b:Int = try ${filler(95)}() catch (e:Any) 0;');
		contains(HxWriteFixture.triviaWrite(atLimit, CONFIG), 'final b:Int = try ${filler(95)}() catch (e:Any) 0;');
		final pastLimit: String = inClass('final b:Int = try ${filler(96)}() catch (e:Any) 0;');
		contains(
			HxWriteFixture.triviaWrite(pastLimit, CONFIG), expectLines(['final b:Int = try', '\t${filler(96)}()', 'catch (e:Any)', '\t0;'])
		);
	}

	private static function filler(length: Int): String {
		return [for (_ in 0...length) 'a'].join('');
	}

	private static function inClass(stmt: String): String {
		return 'class A {\n\tfunction f():Void {\n\t\t$stmt\n\t}\n}\n';
	}

	private static function expectLines(lines: Array<String>): String {
		return '\t\t' + lines.join('\n\t\t');
	}

	private static function contains(out: String, needle: String): Void {
		Assert.isTrue(out.indexOf(needle) != -1, 'expected\n$needle\nin:\n$out');
	}

}

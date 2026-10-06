package unit.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.Violation;
import anyparse.check.DefaultRepeatedArgument;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `default-repeated-argument` check: a parameter with no default that at least two call sites
 * hand the same `static inline` constant. Every fixture declares BOTH the callee and the constant —
 * the rule resolves against the files it is handed and refuses what it cannot see, so a fixture
 * missing either would pass for the wrong reason.
 */
class DefaultRepeatedArgumentCheckTest extends Test {

	private static final CONST: String = 'class K {\n\tpublic static inline final T:Int = 3000;\n\tpublic static final PLAIN:Int = 7;\n}\n';

	public function testTwoAgreeingStaticSitesFlagged(): Void {
		final vs: Array<Violation> = violations(
			'${CONST}class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n'
			+ 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('default-repeated-argument', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** One site is a single caller, and whether it is the only one that will ever exist is not a scope question. */
	public function testSingleSiteNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'${CONST}class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n'
				+ 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t}\n}'
			).length
		);
	}

	/** A site passing something else keeps its argument and does not stop the finding. */
	public function testDisagreeingSiteDoesNotBlock(): Void {
		final src: String = '${CONST}class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n'
			+ 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t\tS.d(9);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		// The fix drops two arguments and writes one default — the third site is untouched.
		Assert.equals(3, editCount(src));
	}

	/**
	 * Haxe accepts only a compile-time constant as a default, and a plain `static final` is not one
	 * (`Default argument value should be constant`). The `inline` twin differs by that modifier.
	 */
	public function testNonInlineConstantNotFlagged(): Void {
		final tail: String = 'class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n'
			+ 'class U {\n\tfunction f():Void {\n\t\tS.d(K.%);\n\t\tS.d(K.%);\n\t}\n}';
		Assert.equals(0, violations(CONST + tail.replace('%', 'PLAIN')).length);
		Assert.equals(1, violations(CONST + tail.replace('%', 'T')).length);
	}

	/**
	 * Visibility is checked from the DECLARATION: a bare constant is the CALLER's own member, so it
	 * only works as a default when caller and callee share a type. The same-type twin is flagged.
	 */
	public function testBareConstantFromAnotherTypeNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n'
				+ 'class U {\n\tstatic inline final T:Int = 1;\n\tfunction f():Void {\n\t\td(T);\n\t\td(T);\n\t}\n}'
			).length
		);
		Assert.equals(
			1,
			violations(
				'class S {\n\tstatic inline final T:Int = 1;\n\tstatic function d(ms:Int):Bool return true;\n'
				+ '\tfunction f():Void {\n\t\td(T);\n\t\td(T);\n\t}\n}'
			).length
		);
	}

	/**
	 * Dropping the argument of a NON-trailing parameter would leave Haxe's type-directed skipping to
	 * decide what the remaining arguments mean. Both fixtures call with the constant LAST, so only the
	 * later parameter's default differs.
	 */
	public function testNonTrailingParameterNotFlagged(): Void {
		final call: String = 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t}\n}';
		Assert.equals(0, violations('${CONST}class S {\n\tpublic static function d(ms:Int, o:Int):Bool return true;\n}\n$call').length);
		Assert.equals(1, violations('${CONST}class S {\n\tpublic static function d(ms:Int, o:Int = 0):Bool return true;\n}\n$call').length);
	}

	/**
	 * Haxe binds arguments by POSITION, so only a TRAILING argument can be dropped: cutting `K.T` out of
	 * `S.d(K.T, 1)` leaves `S.d(1)`, which hands `1` to `ms`. Both types are `Int`, so it compiles and
	 * silently changes what the call means. The twin passes the constant last and is flagged.
	 */
	@:pin('control')
	@:killer('M-DRA-MIDDLE-ARGUMENT')
	public function testMiddleArgumentNeverDropped(): Void {
		final head: String = '${CONST}class S {\n\tpublic static function d(ms:Int, o:Int = 0):Bool return true;\n}\n';
		Assert.equals(0, violations('${head}class U {\n\tfunction f():Void {\n\t\tS.d(K.T, 1);\n\t\tS.d(K.T, 2);\n\t}\n}').length);
		Assert.equals(1, violations('${head}class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t}\n}').length);
	}

	/**
	 * The TM shape, across fix passes. Pass one defaults `step` and drops the trailing `COARSE_STEP`; the
	 * next pass must not then default `bottom` from the two `WIDE_*` calls, whose `WIDE_BOTTOM` is
	 * followed by an explicit `WIDE_STEP` — dropping it bound `WIDE_STEP` to `bottom`. Every later pass
	 * may only take a trailing argument off the shortened calls.
	 */
	public function testFixPassesNeverShiftArguments(): Void {
		final wide: String = 'samples(WIDE_LEFT, WIDE_TOP, WIDE_RIGHT, WIDE_BOTTOM, WIDE_STEP)';
		final fixed: String = fixToFixpoint(
			'class G {\n\tstatic inline final W:Float = 800;\n\tstatic inline final H:Float = 600;\n\tstatic inline final COARSE_STEP:Float = 8;\n'
			+ '\tstatic inline final WIDE_LEFT:Float = -1;\n\tstatic inline final WIDE_TOP:Float = -2;\n\tstatic inline final WIDE_RIGHT:Float = 9;\n'
			+ '\tstatic inline final WIDE_BOTTOM:Float = 7;\n\tstatic inline final WIDE_STEP:Float = 4;\n'
			+ '\tstatic function samples(left:Float, top:Float, right:Float, bottom:Float, step:Float):Int return 0;\n'
			+ '\tfunction f():Void {\n\t\tsamples(0, 0, W, H, COARSE_STEP);\n\t\tsamples(0, 0, W, H, COARSE_STEP);\n'
			+ '\t\tsamples(0, 0, W, H, COARSE_STEP);\n\t\t$wide;\n\t\t$wide;\n\t}\n}'
		);
		Assert.equals(2, fixed.split(wide).length - 1);
		Assert.isTrue(fixed.contains('step:Float = COARSE_STEP'));
		Assert.isFalse(fixed.contains('bottom:Float = WIDE_BOTTOM'));
	}

	/**
	 * Argument `j` is parameter `j` only across the leading run of REQUIRED parameters: past an optional
	 * one Haxe may have skipped a slot by type. In `S.d(1, K.T)` against `(?s:String, x:Int, y:Int = 9)`
	 * the `1` skips `s` and `K.T` lands on `y`, so defaulting `x` and dropping `K.T` would turn `y` into
	 * `9`. The twin differs only in the `?`.
	 */
	@:pin('control')
	@:killer('M-DRA-SKIPPED-SLOT')
	public function testArgumentPastAnOptionalParameterNotCounted(): Void {
		final call: String = 'class U {\n\tfunction f():Void {\n\t\tS.d(%, K.T);\n\t\tS.d(%, K.T);\n\t}\n}';
		final decl: String = '${CONST}class S {\n\tpublic static function d(%s:String, x:Int, y:Int = 9):Bool return true;\n}\n';
		Assert.equals(0, violations(decl.replace('%', '?') + call.replace('%', '1')).length);
		Assert.equals(1, violations(decl.replace('%', '') + call.replace('%', '"a"')).length);
	}

	/** A rest parameter takes the arguments after the dropped one, so `S.d(K.T, 1)` must keep its `K.T`. */
	public function testArgumentBeforeRestNotDropped(): Void {
		final head: String = '${CONST}class S {\n\tpublic static function d(ms:Int, ...r:Int):Bool return true;\n}\n';
		Assert.equals(0, violations('${head}class U {\n\tfunction f():Void {\n\t\tS.d(K.T, 1);\n\t\tS.d(K.T, 1);\n\t}\n}').length);
		Assert.equals(1, violations('${head}class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t}\n}').length);
	}

	/**
	 * Adding a default changes the function's TYPE — `(Int) -> Bool` becomes `(?Int) -> Bool`, and the
	 * two do not unify — so any use of the name as a value refuses the whole finding.
	 */
	public function testFunctionUsedAsValueNotFlagged(): Void {
		final head: String = '${CONST}class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n'
			+ 'class U {\n\tfunction g(h:(Int)->Bool):Void {}\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n';
		Assert.equals(0, violations('${head}\t\tg(S.d);\n\t}\n}').length);
		Assert.equals(1, violations('$head\t}\n}').length);
	}

	/**
	 * A name declared by two types may be an interface member or an override: a default on one leaves
	 * the other's signature alone, so a call typed by it would lose an argument it still needs.
	 */
	public function testMemberNameDeclaredTwiceNotFlagged(): Void {
		final head: String = '${CONST}class S {\n\tpublic static function d(ms:Int):Bool return true;\n}\n';
		final call: String = 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t}\n}';
		Assert.equals(0, violations('${head}class T2 {\n\tpublic function d(ms:Int):Bool return true;\n}\n$call').length);
		Assert.equals(1, violations(head + call).length);
	}

	/** An INSTANCE call resolves through the receiver's own declared type. */
	public function testInstanceReceiverResolved(): Void {
		Assert.equals(
			1,
			violations(
				'${CONST}class S {\n\tpublic function new() {}\n\tpublic function d(ms:Int):Bool return true;\n}\n'
				+ 'class U {\n\tfinal s:S = new S();\n\tfunction f():Void {\n\t\ts.d(K.T);\n\t\ts.d(K.T);\n\t}\n}'
			).length
		);
	}

	/** An UNANNOTATED receiver names no type, so the callee stays unresolved — the library-call guard. */
	public function testUnannotatedReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'${CONST}class S {\n\tpublic function d(ms:Int):Bool return true;\n}\n'
				+ 'class U {\n\tfunction f(s):Void {\n\t\ts.d(K.T);\n\t\ts.d(K.T);\n\t}\n}'
			).length
		);
	}

	/**
	 * A call that leaves a defaulted parameter out still binds its leading REQUIRED arguments by
	 * position, so its trailing constant counts. The full-arity calls carry `"y"` after the constant and
	 * are refused — their `K.T` is not trailing.
	 */
	public function testShortCallTrailingArgumentCounted(): Void {
		final tail: String = 'class U {\n\tfunction f():Void {\n\t\tS.d(%);\n\t\tS.d(%);\n\t}\n}';
		final head: String = '${CONST}class S {\n\tpublic static function d(ms:Int, o:String = "x"):Bool return true;\n}\n';
		Assert.equals(1, violations(head + tail.replace('%', 'K.T')).length);
		Assert.equals(0, violations(head + tail.replace('%', 'K.T, "y"')).length);
	}

	/** A parameter that ALREADY has a default is not this rule's business, however often it is overridden. */
	public function testAlreadyDefaultedParameterNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'${CONST}class S {\n\tpublic static function d(ms:Int = 0):Bool return true;\n}\n'
				+ 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T);\n\t\tS.d(K.T);\n\t}\n}'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new DefaultRepeatedArgument().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` after applying the cross-file fix pass after pass until a pass finds nothing — the `--fix` loop. */
	private function fixToFixpoint(src: String): String {
		var text: String = src;
		for (_ in 0...8) {
			final check: DefaultRepeatedArgument = new DefaultRepeatedArgument();
			final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: text }];
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final edits: Array<{ span: Span, text: String }> = [];
			for (group in check.crossFileFix(files, check.run(files, plugin), plugin))
				for (slice in group)
					for (e in slice.edits) edits.push(e);
			if (edits.length == 0) return text;
			text = CanonicalEdit.applyEdits(text, edits);
		}
		return text;
	}

	/** How many edits the cross-file fix would make for `src` — one default plus one per agreeing site. */
	private function editCount(src: String): Int {
		final check: DefaultRepeatedArgument = new DefaultRepeatedArgument();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final groups: Array<Array<CrossFileEdits>> = check.crossFileFix(files, check.run(files, plugin), plugin);
		var count: Int = 0;
		for (group in groups) for (slice in group) count += slice.edits.length;
		return count;
	}

}

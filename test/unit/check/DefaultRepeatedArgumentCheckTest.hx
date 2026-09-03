package unit.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.Violation;
import anyparse.check.DefaultRepeatedArgument;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
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
	 * decide what the remaining arguments mean. The twin differs only in the later parameter's default.
	 */
	public function testNonTrailingParameterNotFlagged(): Void {
		final call: String = 'class U {\n\tfunction f():Void {\n\t\tS.d(K.T, 1);\n\t\tS.d(K.T, 2);\n\t}\n}';
		Assert.equals(0, violations('${CONST}class S {\n\tpublic static function d(ms:Int, o:Int):Bool return true;\n}\n$call').length);
		Assert.equals(1, violations('${CONST}class S {\n\tpublic static function d(ms:Int, o:Int = 0):Bool return true;\n}\n$call').length);
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
	 * A call that does not fill every slot may have bound its values by Haxe's type-directed
	 * SKIPPING, so argument index and parameter index need not agree — such a call is not counted.
	 * The full-arity twin is flagged.
	 */
	public function testPartialArgumentListNotCounted(): Void {
		final tail: String = 'class U {\n\tfunction f():Void {\n\t\tS.d(%);\n\t\tS.d(%);\n\t}\n}';
		final head: String = '${CONST}class S {\n\tpublic static function d(ms:Int, o:String = "x"):Bool return true;\n}\n';
		Assert.equals(0, violations(head + tail.replace('%', 'K.T')).length);
		Assert.equals(1, violations(head + tail.replace('%', 'K.T, "y"')).length);
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

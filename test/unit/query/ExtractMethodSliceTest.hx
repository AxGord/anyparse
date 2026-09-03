package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractMethod;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * `ExtractMethod.extractMethod` — extract a run of statements into a local
 * function (closure), WRITER-FORMATTED.
 *
 * The extracted function + the replacing call are laid out by the
 * grammar's writer (the whole file is re-emitted through
 * `RefactorSupport.canonicalize`), so each accepted test asserts the EXACT
 * canonical output. The source must already be writer-canonical unless
 * `reformat` is passed. Refusal cases assert `Err`; every `Ok` is
 * additionally re-parsed.
 *
 * Coordinates are the positions `apq refs` prints (the op reads each
 * column in the same 1-based convention as `extract-var`).
 * START points at the first token of the first statement; END points
 * within the last statement of the run.
 */
class ExtractMethodSliceTest extends Test {

	/**
	 * A local declared in the range and READ after it (`return b`) becomes
	 * the call's return value, bound at the call site; a read-only outer
	 * local (`a`) is captured, needing no parameter.
	 */
	public function testExtractWithReturnValue(): Void {
		final source: String =
			'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\tvar b = a + 2;\n\t\ttrace(b);\n\t\treturn b;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\tfunction helper() {\n\t\t\tvar b = a + 2;\n'
			+ '\t\t\ttrace(b);\n\t\t\treturn b;\n\t\t}\n\t\tfinal b = helper();\n\t\treturn b;\n\t}\n}\n';
		assertExtract(source, 4, 3, 5, 3, 'helper', true, expected);
	}

	/**
	 * A range that defines no local used after it produces a call with no
	 * return value; both referenced locals (`a`, `b`) are captured.
	 */
	public function testExtractNoReturnValue(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = 1;\n\t\tvar b = 2;\n\t\ttrace(a);\n\t\ttrace(b);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = 1;\n\t\tvar b = 2;\n\t\tfunction helper() {\n'
			+ '\t\t\ttrace(a);\n\t\t\ttrace(b);\n\t\t}\n\t\thelper();\n\t}\n}\n';
		assertExtract(source, 5, 3, 6, 3, 'helper', true, expected);
	}

	/**
	 * On an already-canonical source the canonical gate passes WITHOUT
	 * `reformat`, and the result equals the `reformat` output.
	 */
	public function testCanonicalGatePassesWithoutReformat(): Void {
		final source: String =
			'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\tvar b = a + 2;\n\t\ttrace(b);\n\t\treturn b;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\tfunction helper() {\n\t\t\tvar b = a + 2;\n'
			+ '\t\t\ttrace(b);\n\t\t\treturn b;\n\t\t}\n\t\tfinal b = helper();\n\t\treturn b;\n\t}\n}\n';
		assertExtract(source, 4, 3, 5, 3, 'helper', false, expected);
	}

	/** `reformat` canonicalises a non-canonical (4-space) source as it extracts. */
	public function testReformatProceedsOnNonCanonical(): Void {
		final source: String = 'class C {\n    function f():Void {\n        var a = 1;\n        trace(a);\n    }\n}\n';
		final expected: String =
			'class C {\n\tfunction f():Void {\n\t\tvar a = 1;\n\t\tfunction helper() {\n\t\t\ttrace(a);\n\t\t}\n\t\thelper();\n\t}\n}\n';
		assertExtract(source, 4, 9, 4, 9, 'helper', true, expected);
	}

	/** A non-canonical source without `reformat` is refused by the gate. */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'class C {\n    function f():Void {\n        var a = 1;\n        trace(a);\n    }\n}\n';
		assertRefused(source, 4, 9, 4, 9, 'helper', false);
	}

	/** A range containing a `return` cannot be wrapped in a closure. */
	public function testRefuseReturnInRange(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\tif (a > 0) return a;\n\t\treturn 0;\n\t}\n}\n';
		assertRefused(source, 4, 3, 4, 3, 'helper', true);
	}

	/** An outer local mutated in the range and read after it is refused. */
	public function testRefuseOuterLocalMutated(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar sum = 0;\n\t\tsum += 5;\n\t\treturn sum;\n\t}\n}\n';
		assertRefused(source, 4, 3, 4, 3, 'helper', true);
	}

	/**
	 * Two locals defined in the range and used after it are returned as an
	 * anonymous struct `{a: a, b: b}`, destructured back into the original
	 * names at the call site so the later `return a + b` stays valid. The
	 * struct temporary takes a fresh `_<name>Result` name.
	 */
	public function testExtractTwoValueStructReturn(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\tvar b = 2;\n\t\treturn a + b;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\tfunction helper() {\n\t\t\tvar a = 1;\n\t\t\tvar b = 2;\n'
			+ '\t\t\treturn {a: a, b: b};\n\t\t}\n\t\tfinal _helperResult = helper();\n\t\tfinal a = _helperResult.a;\n'
			+ '\t\tfinal b = _helperResult.b;\n\t\treturn a + b;\n\t}\n}\n';
		assertExtract(source, 3, 3, 4, 3, 'helper', true, expected);
	}

	/**
	 * In a multi-value extraction, a returned local that is REASSIGNED after
	 * the range is rebound with `var` at the call site while a read-only one
	 * stays `final` — the per-variable binding choice.
	 */
	public function testExtractStructReturnWrittenAfter(): Void {
		final source: String =
			'class C {\n\tfunction f():Void {\n\t\tvar a = 1;\n\t\tvar b = 2;\n\t\ta = 5;\n\t\ttrace(a);\n\t\ttrace(b);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfunction helper() {\n\t\t\tvar a = 1;\n\t\t\tvar b = 2;\n'
			+ '\t\t\treturn {a: a, b: b};\n\t\t}\n\t\tfinal _helperResult = helper();\n\t\tvar a = _helperResult.a;\n'
			+ '\t\tfinal b = _helperResult.b;\n\t\ta = 5;\n\t\ttrace(a);\n\t\ttrace(b);\n\t}\n}\n';
		assertExtract(source, 3, 3, 4, 3, 'helper', true, expected);
	}

	/** A range whose ends are not children of one block is refused. */
	public function testRefuseCrossBlockRange(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) {\n\t\t\ttrace(1);\n\t\t}\n\t\ttrace(2);\n\t}\n}\n';
		assertRefused(source, 4, 4, 6, 3, 'helper', true);
	}

	/**
	 * A same-named local in a LATER function must NOT count as a use of a
	 * range local after the range: extracting `f`'s `var b` adds no return
	 * even though `g` (textually after) also has a `b` it reads — the
	 * after-the-range check binds to the specific declaration.
	 */
	public function testReturnDetectionBindsToDeclaration(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = 1;\n\t\ttrace(b);\n\t}\n\n\tfunction g():Void {\n'
			+ '\t\tvar b = 2;\n\t\ttrace(b);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfunction helper() {\n\t\t\tvar b = 1;\n\t\t\ttrace(b);\n\t\t}\n'
			+ '\t\thelper();\n\t}\n\n\tfunction g():Void {\n\t\tvar b = 2;\n\t\ttrace(b);\n\t}\n}\n';
		assertExtract(source, 3, 3, 4, 3, 'helper', true, expected);
	}

	/** A START not on a statement's first token is refused. */
	public function testRefuseCursorNotOnStatement(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar a = 1;\n\t\treturn a;\n\t}\n}\n';
		assertRefused(source, 3, 6, 3, 6, 'helper', true);
	}

	/**
	 * A local the range declares whose name is declared TWICE in the enclosing block extracts:
	 * `ScopeFrame` binds the trailing read to the SECOND declaration, which is the one the range
	 * carries, so the escape analysis sees it and hands the value back through the return slot.
	 */
	public function testSameBlockRedeclarationExtractsWithReturnValue(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\tvar v = 9;\n\t\ttrace(v);\n\t\ttrace(v);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\tfunction helper() {\n\t\t\tvar v = 9;\n'
			+ '\t\t\ttrace(v);\n\t\t\treturn v;\n\t\t}\n\t\tfinal v = helper();\n\t\ttrace(v);\n\t}\n}\n';
		assertExtract(source, 4, 3, 5, 3, 'helper', true, expected);
	}

	/**
	 * A local `function` the range declares extracts the same way: the `g()` after the second
	 * declaration binds to that declaration, so it moves into the closure with it and the `g()`
	 * between the two keeps calling the first body. Reached only because the guard sweeps the
	 * block-scoped DECLARATION vocabulary rather than `LOCAL_DECL_KINDS`, which knows `var` /
	 * `final` alone.
	 */
	public function testSameBlockLocalFunctionRedeclarationExtracts(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g()\n\t\t\ttrace(1);\n\t\tg();\n'
			+ '\t\tfunction g()\n\t\t\ttrace(2);\n\t\tg();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g()\n\t\t\ttrace(1);\n\t\tg();\n'
			+ '\t\tfunction helper() {\n\t\t\tfunction g()\n\t\t\t\ttrace(2);\n\t\t\tg();\n\t\t}\n\t\thelper();\n\t}\n}\n';
		assertExtract(source, 6, 3, 8, 3, 'helper', true, expected);
	}

	/**
	 * The re-declaration shape that stays refused: the name the range binds is also declared on
	 * two mutually exclusive conditional-compilation arms, so a read past the `#end` belongs to
	 * exactly one of them and "is the extracted local read after the range" holds for one build
	 * configuration and not the other. The same shape `rename` refuses on.
	 */
	public function testRefuseExclusiveCondArmRedeclaration(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\t#if js\n\t\tvar v = 2;\n'
			+ '\t\t#else\n\t\tvar v = 3;\n\t\t#end\n\t\treturn v;\n\t}\n}\n';
		assertRefusedWith(source, 3, 3, 4, 3, 'helper', true, 'declaration at 8:3 on a conditional-compilation arm');
	}

	/**
	 * The one-arm half of the same ambiguity, which is what the escape analysis actually gets wrong
	 * here: `return v` binds to the arm's declaration, so the range's own `v` reads as dead after
	 * the range and no return slot is emitted — correct under `-D js`, and a dangling `v` in every
	 * other configuration. Measured: with the guard comparing arms only, this extraction wrote a
	 * file `--interp` rejected with `Unknown identifier : v`.
	 */
	public function testRefuseCondArmPlusPrecedingSibling(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\t#if js\n\t\tvar v = 2;\n'
			+ '\t\ttrace(v);\n\t\t#end\n\t\treturn v;\n\t}\n}\n';
		assertRefusedWith(source, 3, 3, 4, 3, 'helper', true, 'declaration at 6:3 on a conditional-compilation arm');
	}

	/**
	 * A local function declared ONCE still extracts — the guard is about the REdeclaration, not
	 * about the kind. The whole declaration and its call move into the closure and the
	 * surrounding statements stay where they were.
	 */
	public function testSingleLocalFunctionStillExtracts(): Void {
		final source: String =
			'class C {\n\tfunction f():Void {\n\t\ttrace(0);\n\t\tfunction g()\n\t\t\ttrace(1);\n\t\tg();\n\t\ttrace(2);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ttrace(0);\n\t\tfunction helper() {\n'
			+ '\t\t\tfunction g()\n\t\t\t\ttrace(1);\n\t\t\tg();\n\t\t}\n\t\thelper();\n\t\ttrace(2);\n\t}\n}\n';
		assertExtract(source, 4, 3, 6, 3, 'helper', true, expected);
	}

	/**
	 * A `for` binder is self-scoped, so the sibling loop that binds `i` too is not a
	 * redeclaration and must not block extracting the range that holds the first loop. The
	 * extracted closure keeps its own `i`; the sibling loop stays outside it, unchanged.
	 */
	public function testSiblingLoopBindersStillExtract(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfor (i in 0...3)\n\t\t\ttrace(i);\n\t\ttrace(0);\n'
			+ '\t\tfor (i in 0...2)\n\t\t\ttrace(i);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfunction helper() {\n\t\t\tfor (i in 0...3)\n'
			+ '\t\t\t\ttrace(i);\n\t\t\ttrace(0);\n\t\t}\n\t\thelper();\n\t\tfor (i in 0...2)\n\t\t\ttrace(i);\n\t}\n}\n';
		assertExtract(source, 3, 3, 5, 3, 'helper', true, expected);
	}

	/**
	 * A redeclaration in a NESTED block is ordinary shadowing — a distinct binding
	 * that expires at that block's `}`, which the resolver binds correctly — so the
	 * guard must not fire: `v` IS read after the range, so the closure still
	 * returns it, and the nested `var v = 5` is left untouched.
	 */
	public function testNestedBlockRedeclarationStillExtracts(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ttrace(0);\n\t\tvar v = 9;\n\t\ttrace(v);\n\t\ttrace(v);\n'
			+ '\t\t{\n\t\t\tvar v = 5;\n\t\t\ttrace(v);\n\t\t}\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ttrace(0);\n\t\tfunction helper() {\n\t\t\tvar v = 9;\n'
			+ '\t\t\ttrace(v);\n\t\t\treturn v;\n\t\t}\n\t\tfinal v = helper();\n\t\ttrace(v);\n\t\t{\n\t\t\tvar v = 5;\n'
			+ '\t\t\ttrace(v);\n\t\t}\n\t}\n}\n';
		assertExtract(source, 4, 3, 5, 3, 'helper', true, expected);
	}

	/**
	 * The guard is keyed on the names the RANGE declares: a block that redeclares
	 * an unrelated `u` must not block extracting a range that declares only `w`,
	 * and the redeclared `u` stays put around the new call.
	 */
	public function testUnrelatedRedeclarationStillExtracts(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar u = 1;\n\t\ttrace(u);\n\t\tvar u = 2;\n\t\tvar w = 9;\n'
			+ '\t\ttrace(w);\n\t\ttrace(u);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar u = 1;\n\t\ttrace(u);\n\t\tvar u = 2;\n'
			+ '\t\tfunction helper() {\n\t\t\tvar w = 9;\n\t\t\ttrace(w);\n\t\t}\n\t\thelper();\n\t\ttrace(u);\n\t}\n}\n';
		assertExtract(source, 6, 3, 7, 3, 'helper', true, expected);
	}

	private function assertExtract(
		source: String, startLine: Int, startCol: Int, endLine: Int, endCol: Int, name: String, reformat: Bool, expected: String
	): Void {
		final result: EditResult = extractOf(source, startLine, startCol, endLine, endCol, name, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(
		source: String, startLine: Int, startCol: Int, endLine: Int, endCol: Int, name: String, reformat: Bool
	): Void {
		final result: EditResult = extractOf(source, startLine, startCol, endLine, endCol, name, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertRefusedWith(
		source: String, startLine: Int, startCol: Int, endLine: Int, endCol: Int, name: String, reformat: Bool, needle: String
	): Void {
		final result: EditResult = extractOf(source, startLine, startCol, endLine, endCol, name, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(needle) != -1, message);
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('extract-method output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function extractOf(
		source: String, startLine: Int, startCol: Int, endLine: Int, endCol: Int, name: String, reformat: Bool
	): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return ExtractMethod.extractMethod(source, startLine, startCol, endLine, endCol, name, reformat, plugin, shape);
	}

}

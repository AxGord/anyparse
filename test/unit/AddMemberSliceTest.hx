package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddMember;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `AddMember.addMember` — append a member to a type body, WRITER-FORMATTED.
 *
 * The member is laid out by the grammar's writer (not inserted as-is): the
 * whole file is re-emitted through `writeRoundTrip`, so the result is
 * canonical and the raw `memberText` spacing is normalised. Each test
 * asserts the EXACT canonical output. The source must already be writer-
 * canonical (its own writer output) — a non-canonical file is refused
 * unless `reformat` is passed. Refusal cases assert `Err`; every `Ok` is
 * additionally re-parsed.
 */
class AddMemberSliceTest extends Test {

	/** Append a method to a class that already has a member. */
	public function testAppendToClassWithMembers(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tpublic function g():Void {}\n}\n';
		assertAdd(source, 'C', 'public function g():Void {}', expected);
	}

	/**
	 * The core win: a member with ugly hand-spacing comes out CANONICALLY
	 * formatted (the writer normalises it), not spliced verbatim.
	 */
	public function testUglyMemberIsCanonicalised(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tpublic function g(a:Int, b:Int):Int {\n\t\treturn a + b;\n\t}\n}\n';
		assertAdd(source, 'C', 'public    function  g(a:Int,b:Int):Int{return a+b;}', expected);
	}

	/** Append to an empty class. */
	public function testAppendToEmptyClass(): Void {
		final source: String = 'class C {}\n';
		final expected: String = 'class C {\n\tvar y:Int;\n}\n';
		assertAdd(source, 'C', 'var y:Int;', expected);
	}

	/**
	 * Append to a `final class` — the closing `}` is located via the inner
	 * `ClassForm` name node (the outer `FinalDecl` span swallows the
	 * trailing newline), so the member lands inside the body.
	 */
	public function testAppendToFinalClass(): Void {
		final source: String = 'final class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'final class C {\n\tvar x:Int;\n\n\tpublic function g():Void {}\n}\n';
		assertAdd(source, 'C', 'public function g():Void {}', expected);
	}

	/** Append a constructor to an `enum`. */
	public function testAppendToEnum(): Void {
		final source: String = 'enum E {\n\tA;\n}\n';
		final expected: String = 'enum E {\n\tA;\n\n\tB(x:Int);\n}\n';
		assertAdd(source, 'E', 'B(x:Int);', expected);
	}

	/**
	 * Append to a `typedef` anon body — the closing `}` is found by
	 * scanning back over the trailing newline that the `TypedefDecl` span
	 * swallows (same trivia-swallow as `final class`).
	 */
	public function testAppendToTypedefAnon(): Void {
		final source: String = 'typedef T = {\n\tvar x:Int;\n}\n';
		final expected: String = 'typedef T = {\n\tvar x:Int;\n\n\tvar y:Int;\n}\n';
		assertAdd(source, 'T', 'var y:Int;', expected);
	}

	/** Refuse an unknown type name. */
	public function testRefuseUnknownType(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		assertRefused(source, 'Nope', 'var z:Int;');
	}

	/** Refuse an ambiguous type name (two decls share it). */
	public function testRefuseAmbiguousType(): Void {
		final source: String = 'class C {}\n\nclass C {}\n';
		assertRefused(source, 'C', 'var z:Int;');
	}

	/** Refuse a malformed member — the whole-file re-emit fails to parse. */
	public function testRefuseMalformedMember(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		assertRefused(source, 'C', '@@@ not haxe');
	}

	/**
	 * Refuse a NON-canonical file (4-space indent) without `--reformat` —
	 * the whole-file rewrite would otherwise reflow unrelated formatting.
	 */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'class C {\n    var x:Int;\n}\n';
		assertRefused(source, 'C', 'var y:Int;');
	}

	/** `reformat` proceeds on a non-canonical file, canonicalising it. */
	public function testReformatProceedsOnNonCanonical(): Void {
		final source: String = 'class C {\n    var x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tvar y:Int;\n}\n';
		assertAdd(source, 'C', 'var y:Int;', expected, true);
	}

	private function assertAdd(source: String, typeName: String, memberText: String, expected: String, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, typeName, memberText, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, typeName: String, memberText: String, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, typeName, memberText, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('add-member output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function addOf(source: String, typeName: String, memberText: String, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddMember.addMember(source, typeName, memberText, reformat, plugin);
	}

	/**
	 * Append to a `final class` that is NOT the last decl: a following
	 * doc-commented `typedef` is swallowed into the outer `FinalDecl` span,
	 * so the closing brace comes from the inner `ClassForm` (`nameNode`),
	 * not `fullSpan` — `testAppendToFinalClass` passes only because its
	 * final class is the last decl.
	 */
	public function testAppendToNonLastFinalClass(): Void {
		final source: String = 'final class C {\n\tvar x:Int;\n}\n\n/**\n * Doc.\n */\ntypedef T = {\n\tvar y:Int;\n}\n';
		final expected: String = 'final class C {\n\tvar x:Int;\n\n\tpublic function g():Void {}\n}\n\n/**\n * Doc.\n */\n'
			+ 'typedef T = {\n' + '\tvar y:Int;\n' + '}\n';
		assertAdd(source, 'C', 'public function g():Void {}', expected);
	}

}

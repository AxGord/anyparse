package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RemoveElement;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `RemoveElement.removeElement` — remove the sibling element a cursor points
 * at, the structural inverse of `AddElement`. A comma-list element takes one
 * separating comma with it; a self-terminated element (statement / case /
 * member / import) takes its whole physical line so no blank line is left.
 * The whole file is re-emitted through `RefactorSupport.canonicalize`, so
 * each accepted test asserts the EXACT canonical output and re-parses it.
 * Coordinates are the positions `apq refs` prints (first token of the
 * element to remove).
 */
class RemoveElementSliceTest extends Test {

	/** Remove a middle comma-list element — one comma goes with it. */
	public function testRemoveArrayMiddle(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2, 3];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 3];\n\t}\n}\n';
		assertRemove(source, 3, 15, true, expected);
	}

	/** Remove the first element — its trailing comma goes with it. */
	public function testRemoveArrayFirst(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2, 3];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [2, 3];\n\t}\n}\n';
		assertRemove(source, 3, 12, true, expected);
	}

	/** Remove the last element — its leading comma goes with it. */
	public function testRemoveArrayLast(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2, 3];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2];\n\t}\n}\n';
		assertRemove(source, 3, 18, true, expected);
	}

	/** Remove the sole element of a single-element list — leaves it empty. */
	public function testRemoveArraySingle(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [];\n\t}\n}\n';
		assertRemove(source, 3, 12, true, expected);
	}

	/** Remove a call argument (comma list). */
	public function testRemoveCallArgument(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, y);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x);\n\t}\n}\n';
		assertRemove(source, 3, 10, true, expected);
	}

	/** Remove a statement — its whole line goes, no blank line is left. */
	public function testRemoveStatement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t\tc();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, true, expected);
	}

	/** Remove a `case` from a switch. */
	public function testRemoveSwitchCase(): Void {
		final source: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t}\n\t}\n}\n';
		assertRemove(source, 5, 4, true, expected);
	}

	/** Remove a member with modifiers — the whole `public function …` group goes. */
	public function testRemoveModifiedMember(): Void {
		final source: String = 'class C {\n\tvar a:Int;\n\tpublic function f():Void {}\n}\n';
		final expected: String = 'class C {\n\tvar a:Int;\n}\n';
		assertRemove(source, 3, 2, true, expected);
	}

	/** On a canonical source the gate passes WITHOUT reformat. */
	public function testCanonicalGatePassesWithoutReformat(): Void {
		final source: String = 'class C {\n\tvar a:Int;\n\tvar b:Int;\n}\n';
		final expected: String = 'class C {\n\tvar a:Int;\n}\n';
		assertRemove(source, 3, 2, false, expected);
	}

	/** A non-canonical source without reformat is refused by the gate. */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'class C {\n    var a:Int;\n    var b:Int;\n}\n';
		assertRefused(source, 3, 5, false);
	}

	/** A position not on an element's first token is refused. */
	public function testRefuseNotOnElementStart(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}\n';
		assertRefused(source, 3, 1, true);
	}

	private function assertRemove(source: String, line: Int, col: Int, reformat: Bool, expected: String): Void {
		final result: EditResult = removeOf(source, line, col, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int, reformat: Bool): Void {
		switch removeOf(source, line, col, reformat) {
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
			Assert.fail('remove-element output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function removeOf(source: String, line: Int, col: Int, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return RemoveElement.removeElement(source, line, col, reformat, plugin);
	}

	/** remove-element tolerates a cursor INSIDE an element's identifier, not only on its first character (was an exact-position trap). */
	public function testRemoveTolerantWithinIdent(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [abc, def];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [def];\n\t}\n}\n';
		assertRemove(source, 3, 13, true, expected);
	}

}

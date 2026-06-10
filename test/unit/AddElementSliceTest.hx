package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddElement;
import anyparse.query.AddElement.InsertSide;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `AddElement.addElement` — insert a sibling element (statement / `case` /
 * comma-list element) next to an existing one, WRITER-FORMATTED.
 *
 * The element is spliced with the slot's separator (a newline for
 * self-terminated statement / case lists, a `,` for comma lists) and the
 * whole file is re-emitted through `RefactorSupport.canonicalize`, so each
 * accepted test asserts the EXACT canonical output. The source must be
 * writer-canonical unless `reformat` is passed. Refusal cases assert
 * `Err`; every `Ok` is additionally re-parsed.
 *
 * Coordinates are the positions `apq refs` prints; `line:col` points at
 * the FIRST TOKEN of an existing sibling element.
 */
class AddElementSliceTest extends Test {

	/** Insert a statement AFTER another in a block (self-terminated, newline). */
	public function testInsertStatementAfter():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		final expected:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t\tb();\n\t}\n}\n';
		assertAdd(source, 3, 2, After, 'c();', true, expected);
	}

	/** Insert a statement BEFORE another in a block. */
	public function testInsertStatementBefore():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		final expected:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t\tb();\n\t}\n}\n';
		assertAdd(source, 4, 2, Before, 'c();', true, expected);
	}

	/** Insert a `case` into a switch (self-delimited by the next `case`). */
	public function testInsertSwitchCaseAfter():Void {
		final source:String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}\n';
		final expected:String =
			'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 2: c();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}\n';
		assertAdd(source, 4, 3, After, 'case 2: c();', true, expected);
	}

	/** Insert an array element (comma list — separator detected by adjacency). */
	public function testInsertArrayElementAfter():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2];\n\t}\n}\n';
		final expected:String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 3, 2];\n\t}\n}\n';
		assertAdd(source, 3, 11, After, '3', true, expected);
	}

	/** Insert a call argument (comma list). */
	public function testInsertCallArgumentAfter():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, y);\n\t}\n}\n';
		final expected:String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, z, y);\n\t}\n}\n';
		assertAdd(source, 3, 6, After, 'z', true, expected);
	}

	/**
	 * Insert an object field into a SINGLE-field object literal — the
	 * adjacency check finds no comma, so the comma separator comes from the
	 * `ObjectLit` parent kind. The generality test: a one-element comma
	 * list still gets a `,`.
	 */
	public function testInsertObjectFieldSingleField():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\tvar o = {a: 1};\n\t}\n}\n';
		final expected:String = 'class C {\n\tfunction f():Void {\n\t\tvar o = {a: 1, b: 2};\n\t}\n}\n';
		assertAdd(source, 3, 11, After, 'b: 2', true, expected);
	}

	/** On a canonical source the gate passes WITHOUT reformat. */
	public function testCanonicalGatePassesWithoutReformat():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		final expected:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t\tb();\n\t}\n}\n';
		assertAdd(source, 3, 2, After, 'c();', false, expected);
	}

	/** A non-canonical source without reformat is refused by the gate. */
	public function testRefuseNonCanonicalWithoutReformat():Void {
		final source:String = 'class C {\n    function f():Void {\n        a();\n    }\n}\n';
		assertRefused(source, 3, 8, After, 'b();', false);
	}

	/** A position not on an element's first token is refused. */
	public function testRefuseNotOnElementStart():Void {
		final source:String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}\n';
		assertRefused(source, 3, 0, After, 'b();', true);
	}

	private function assertAdd(source:String, line:Int, col:Int, side:InsertSide, code:String, reformat:Bool, expected:String):Void {
		final result:EditResult = addOf(source, line, col, side, code, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message): Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source:String, line:Int, col:Int, side:InsertSide, code:String, reformat:Bool):Void {
		final result:EditResult = addOf(source, line, col, side, code, reformat);
		switch result {
			case Ok(text): Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_): Assert.pass();
		}
	}

	private function assertReparses(text:String):Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception:Exception) {
			Assert.fail('add-element output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function addOf(source:String, line:Int, col:Int, side:InsertSide, code:String, reformat:Bool):EditResult {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddElement.addElement(source, line, col, side, code, reformat, plugin);
	}
}

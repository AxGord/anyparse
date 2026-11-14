package unit.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.RemoveElement;

/**
 * Deleting an element takes the comment that trails it on its own line: `b(); // t` is one unit,
 * so the `// t` never survives as an own-line comment over the next sibling. A leading own-line
 * comment of the NEXT sibling stays with that sibling.
 */
class RemoveTrailingCommentSliceTest extends Test {

	@:pin('control')
	@:killer('M-CUT-TRAILING-COMMENT-KEPT')
	public function testMiddleStatementTakesItsTrailingComment(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-CUT-TRAILING-COMMENT-KEPT')
	public function testStatementAfterBareOneTakesItsTrailingComment(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-CUT-TRAILING-COMMENT-KEPT')
	public function testTrailingBlockCommentLeavesToo(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb(); /* t2 */\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t}\n}\n');
	}

	@:pin('guard')
	public function testNextStatementsLeadingCommentStays(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb(); // t2\n\t\t// lead c\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\t// lead c\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-CUT-TRAILING-COMMENT-KEPT')
	public function testDocCommentOfTheRemovedStatementLeavesToo(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\t/** doc b */\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 5, 3, 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-CUT-TRAILING-COMMENT-KEPT')
	public function testMemberTakesItsTrailingComment(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n\tvar y:Int; // ty\n\tvar z:Int;\n}\n';
		assertRemove(source, 3, 2, 'class C {\n\tvar x:Int;\n\tvar z:Int;\n}\n');
	}

	@:pin('control')
	@:killer('M-CUT-TRAILING-COMMENT-KEPT')
	public function testSwitchCaseTakesItsTrailingComment(): Void {
		final source: String =
			'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 1: b(); // c1\n\t\t}\n\t}\n}\n';
		assertRemove(source, 5, 4, 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t}\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-COMMA-CUT-COMMENT-KEPT')
	public function testListElementTakesTheCommentAfterItsComma(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1, // one\n\t\t\t2\n\t\t];\n\t}\n}\n';
		assertRemove(source, 4, 4, 'class C {\n\tfunction f():Void {\n\t\tvar a = [2];\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-CLOSING-COMMENT-TAKEN-BEFORE-CODE')
	public function testBlockCommentBeforeCodeOnTheLineStays(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb(); /* n */ c();\n\t\td();\n\t}\n}\n';
		switch RemoveElement.removeElement(source, 4, 3, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('/* n */') >= 0, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	@:pin('guard')
	public function testLeadingOwnLineCommentOfTheRemovedStatementLeavesToo(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\t// lead b\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, 'class C {\n\tfunction f():Void {\n\t\tc();\n\t}\n}\n');
	}

	/** The last element cuts back to its leading comma and takes only its own note: the previous element's note stays with it. */
	@:pin('guard')
	public function testLastListElementTakesOnlyItsOwnNote(): Void {
		final source: String =
			'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1, // one\n\t\t\t2, // two\n\t\t\t3 // three\n\t\t];\n\t}\n}\n';
		assertRemove(source, 6, 4, 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1, // one\n\t\t\t2 // two\n\t\t];\n\t}\n}\n');
	}

	/** Every comment that closes the line goes, not only the first. */
	@:pin('control')
	@:killer('M-CLOSING-COMMENTS-ONLY-FIRST')
	public function testEveryCommentClosingTheLineLeaves(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb(); /* a */ // b\n\t\tc();\n\t}\n}\n';
		switch RemoveElement.removeElement(source, 4, 3, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals('class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t}\n}\n', text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRemove(source: String, line: Int, col: Int, expected: String): Void {
		switch RemoveElement.removeElement(source, line, col, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}

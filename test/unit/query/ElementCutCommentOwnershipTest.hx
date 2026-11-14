package unit.query;

import anyparse.query.RemoveElement;
import anyparse.query.RemoveImport;
import anyparse.query.RemoveMember;
import anyparse.query.ReplaceNode;

/**
 * Deleting a statement takes the own-line `//` note directly above it, and a whole-element
 * replace by the empty text is a deletion that takes the same bytes.
 */
class ElementCutCommentOwnershipTest extends Test {

	@:pin('control')
	@:killer('M-CUT-LEAD-NOTE-KEPT')
	public function testLeadNoteGoesWithTheRemovedStatement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\t// lead b\n\t\tb();\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 4, 3, 'class C {\n\tfunction f():Void {\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-NOTE-RUN-CROSSES-BLANK-LINE')
	public function testLeadNoteSeparatedByBlankLineStays(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\t// lead b\n\n\t\tb();\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 5, 3, 'class C {\n\tfunction f():Void {\n\t\t// lead b\n\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-REPLACE-EMPTY-BYPASSES-CUT')
	public function testEmptyReplaceDeletesLikeRemove(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertReplace(source, '', 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tc();\n\t}\n}\n');
	}

	@:pin('guard')
	public function testNonEmptyReplaceIsUnchanged(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertReplace(source, 'd();', 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\td(); // t2\n\t\tc();\n\t}\n}\n');
	}

	@:pin('guard')
	public function testEveryStackedNoteAboveGoesWithTheStatement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\t// one\n\t\t// two\n\t\tb();\n\t\tc();\n\t}\n}\n';
		assertRemove(source, 6, 3, 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-REPLACE-EMPTY-BYPASSES-CUT')
	public function testEmptyReplaceOfTheCallDeletesItsStatement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tb(); // t2\n\t\tc();\n\t}\n}\n';
		assertReplace(source, '', 'class C {\n\tfunction f():Void {\n\t\ta(); // t1\n\t\tc();\n\t}\n}\n', ByKindPosition(4, 3, 'Call'));
	}

	@:pin('control')
	@:killer('M-NOTE-SCOPE-ALL-ELEMENTS')
	public function testBannerAboveARemovedMemberStays(): Void {
		final source: String = 'class C {\n\t// ---- fields ----\n\tvar a:Int;\n\tvar b:Int;\n}\n';
		switch RemoveMember.removeMember(source, 'C', 'a', false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals('class C {\n\t// ---- fields ----\n\tvar b:Int;\n}\n', text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	@:pin('control')
	@:killer('M-NOTE-SCOPE-ALL-ELEMENTS')
	public function testGroupHeaderAboveARemovedImportStays(): Void {
		final source: String = 'package p;\n\n// collections\nimport haxe.ds.StringMap;\nimport haxe.ds.IntMap;\n\nclass C {}\n';
		switch RemoveImport.removeImport(source, 'haxe.ds.StringMap', false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals('package p;\n\n// collections\nimport haxe.ds.IntMap;\n\nclass C {}\n', text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	@:pin('control')
	@:killer('M-REPLACE-EMPTY-CLIMBS-TO-ANY-PARENT')
	public function testEmptyReplaceOfASubExpressionDoesNotDeleteItsStatement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tx++;\n\t\tc();\n\t}\n}\n';
		switch ReplaceNode.replaceNode(source, ByPosition(4, 3), '', false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok: $text');
			case Err(message):
				Assert.stringContains('does not parse', message);
		}
	}

	private function assertReplace(source: String, newSource: String, expected: String, ?target: ReplaceTarget): Void {
		switch ReplaceNode.replaceNode(source, target ?? ByKindPosition(4, 3, 'ExprStmt'), newSource, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
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

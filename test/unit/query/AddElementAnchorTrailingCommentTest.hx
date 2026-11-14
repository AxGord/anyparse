package unit.query;

import anyparse.query.AddElement;
import anyparse.query.CanonicalEdit.EditResult;

/**
 * `AddElement.addElement` on an anchor that ends with a trailing comment: the comment closes the
 * anchor's line and belongs to the anchor, so `--after` lands past it and `--before` leaves it alone.
 */
class AddElementAnchorTrailingCommentTest extends Test {

	@:pin('control')
	@:killer('M-ADD-AFTER-ANCHOR-COMMENT')
	public function testAfterKeepsLineComment(): Void {
		check(
			'class C {\n\tvar a:Bool; // noqa\n\tvar b:Int;\n}\n', 2, After,
			'class C {\n\tvar a:Bool; // noqa\n\tvar x:Int;\n\tvar b:Int;\n}\n'
		);
	}

	@:pin('control')
	@:killer('M-ADD-AFTER-ANCHOR-COMMENT')
	public function testAfterKeepsBlockComment(): Void {
		check(
			'class C {\n\tvar a:Bool; /* noqa */\n\tvar b:Int;\n}\n', 2, After,
			'class C {\n\tvar a:Bool; /* noqa */\n\tvar x:Int;\n\tvar b:Int;\n}\n'
		);
	}

	@:pin('guard')
	public function testBeforeKeepsLineComment(): Void {
		check(
			'class C {\n\tvar a:Bool;\n\tvar b:Int; // noqa\n}\n', 3, Before,
			'class C {\n\tvar a:Bool;\n\tvar x:Int;\n\tvar b:Int; // noqa\n}\n'
		);
	}

	@:pin('guard')
	public function testBeforeKeepsBlockComment(): Void {
		check(
			'class C {\n\tvar a:Bool;\n\tvar b:Int; /* noqa */\n}\n', 3, Before,
			'class C {\n\tvar a:Bool;\n\tvar x:Int;\n\tvar b:Int; /* noqa */\n}\n'
		);
	}

	private static function check(source: String, line: Int, side: InsertSide, expected: String): Void {
		final result: EditResult = AddElement.addElement(source, line, 2, side, 'var x:Int;', false, new HaxeQueryPlugin());
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}

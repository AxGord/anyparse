package unit.query;

import anyparse.query.AddElement;
import anyparse.query.CanonicalEdit.EditResult;

/**
 * `AddElement.addElement` keeps a payload's trailing blank line: the inserted
 * element and the neighbour it runs into stay separated by the blank line the
 * payload carried, and a payload without one adds none.
 */
class AddElementPayloadBlankTest extends Test {

	private static final SPACED: String = 'class A {\n\tpublic var a:Int;\n\n\tpublic var b:Int;\n}\n';
	private static final TIGHT: String = 'class A {\n\tpublic var a:Int;\n\tpublic var b:Int;\n}\n';

	/** A payload ending in a blank line, inserted BEFORE a member that follows a blank line. */
	@:pin('control')
	@:killer('M-ADD-PAYLOAD-TRAILING-BLANK')
	public function testInsertBeforeKeepsPayloadTrailingBlank(): Void {
		assertAdd(
			SPACED, 4, Before, 'public var x:Int;\n\n', 'class A {\n\tpublic var a:Int;\n\n\tpublic var x:Int;\n\n\tpublic var b:Int;\n}\n'
		);
	}

	/** The same payload inserted AFTER a member keeps the blank line before the member that follows. */
	@:pin('control')
	@:killer('M-ADD-PAYLOAD-TRAILING-BLANK')
	public function testInsertAfterKeepsPayloadTrailingBlank(): Void {
		assertAdd(
			TIGHT, 2, After, 'public var x:Int;\n\n', 'class A {\n\tpublic var a:Int;\n\tpublic var x:Int;\n\n\tpublic var b:Int;\n}\n'
		);
	}

	/** A payload ending in a blank line, inserted BEFORE a member in a list with no blank lines. */
	@:pin('control')
	@:killer('M-ADD-PAYLOAD-TRAILING-BLANK')
	public function testInsertBeforeBlankInTightList(): Void {
		assertAdd(
			TIGHT, 3, Before, 'public var x:Int;\n\n', 'class A {\n\tpublic var a:Int;\n\tpublic var x:Int;\n\n\tpublic var b:Int;\n}\n'
		);
	}

	/** A payload with no trailing blank line adds none. */
	public function testInsertBeforeWithoutTrailingBlankAddsNone(): Void {
		assertAdd(TIGHT, 3, Before, 'public var x:Int;', 'class A {\n\tpublic var a:Int;\n\tpublic var x:Int;\n\tpublic var b:Int;\n}\n');
	}

	private function assertAdd(source: String, line: Int, side: InsertSide, payload: String, expected: String): Void {
		final result: EditResult = AddElement.addElement(source, line, 2, side, payload, false, new HaxeQueryPlugin());
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}

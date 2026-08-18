package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RemoveElement;
import anyparse.query.RemoveImport;
import anyparse.query.RemoveMember;

/**
 * A removed declaration takes its documentation with it.
 *
 * `remove-member` folded a member's modifier / `@:meta` run into the deletion
 * but stopped there, so a doc'd member left its doc block behind and that block
 * silently became the documentation of whatever declaration followed. With
 * SEVERAL removals the leftovers stack and `fragmented-doc-comment` reports
 * them; with ONE there is no stack, nothing reports, and the next declaration
 * simply acquires a wrong doc — the case these tests pin first.
 *
 * The doc region is `RefactorSupport.docExtendedSpan`, the same one `set-doc`
 * replaces and `move-member` carries; the fix is that the remove ops now use
 * it by default instead of only under an opt-in flag.
 */
class RemoveMemberDocSliceTest extends Test {

	/** The victim's doc goes; the neighbour's own doc stays. */
	public function testDocGoesWithTheMember(): Void {
		final text: String = okMember(
			'class C {\n\t/** Doc of drop. */\n\tpublic function drop():Void {}\n\n'
			+ '\t/** Doc of keep. */\n\tpublic function keep():Void {}\n}\n',
			'C', 'drop'
		);
		Assert.isTrue(text.indexOf('Doc of drop') == -1, text);
		Assert.isTrue(text.indexOf('Doc of keep') >= 0, text);
		Assert.equals(1, blockOpeners(text), text);
	}

	/**
	 * THE SILENT CASE — one removal, an UNdocumented neighbour. No stack forms, so
	 * `fragmented-doc-comment` never fires and the leftover simply becomes `keep`'s
	 * doc. Nothing but this assertion catches it.
	 */
	public function testSingleRemovalLeavesNoOrphanDoc(): Void {
		final text: String = okMember(
			'class C {\n\t/** Doc of drop. */\n\tpublic function drop():Void {}\n\n\tpublic function keep():Void {}\n}\n', 'C', 'drop'
		);
		Assert.equals(0, blockOpeners(text), text);
		Assert.isTrue(text.indexOf('keep') >= 0, text);
	}

	/** A member with NO doc leaves the neighbouring documentation exactly where it was. */
	public function testMemberWithoutADocIsANoOpOnComments(): Void {
		final text: String = okMember(
			'class C {\n\tpublic function drop():Void {}\n\n\t/** Doc of keep. */\n\tpublic function keep():Void {}\n}\n', 'C', 'drop'
		);
		Assert.isTrue(text.indexOf('/** Doc of keep. */\n\tpublic function keep') >= 0, text);
	}

	/**
	 * A block comment that TRAILS the previous declaration on its own line is not the
	 * victim's doc, however adjacent it looks — the reader attributes it by the line it
	 * sits on, and so does the op.
	 */
	public function testPreviousDeclarationsTrailingCommentIsNotStolen(): Void {
		final text: String = okMember('class C {\n\tvar keep:Int; /** about keep */\n\n\tvar drop:Int;\n}\n', 'C', 'drop');
		Assert.isTrue(text.indexOf('about keep') >= 0, text);
		Assert.isTrue(text.indexOf('drop') == -1, text);
	}

	/** The doc sits above the `@:meta` / modifier run; the whole group goes together. */
	public function testDocAboveTheMetaAndModifierGroupGoesWithTheMember(): Void {
		final text: String = okMember(
			'class C {\n\t/** Doc of drop. */\n\t@:keep\n\tpublic static inline function drop():Void {}\n\n\tvar keep:Int;\n}\n', 'C',
			'drop'
		);
		Assert.equals(0, blockOpeners(text), text);
		Assert.isTrue(text.indexOf('@:keep') == -1, text);
		Assert.isTrue(text.indexOf('keep:Int') >= 0, text);
	}

	/** A doc INSIDE the `#if` region goes with the member, and the emptied region goes too. */
	public function testGuardedMemberTakesItsDocAndItsRegion(): Void {
		final text: String = okMember(
			'class C {\n\tvar keep:Int;\n\t#if !mobile\n\t/** Doc of drop. */\n\tpublic function drop():Void {}\n\t#end\n}\n', 'C', 'drop'
		);
		Assert.equals(0, blockOpeners(text), text);
		Assert.isTrue(text.indexOf('#if') == -1, text);
		Assert.isTrue(text.indexOf('keep') >= 0, text);
	}

	/** A doc written ABOVE the guard documents the guarded member, so it goes with it. */
	public function testDocAboveTheGuardGoesWithTheMember(): Void {
		final text: String = okMember(
			'class C {\n\tvar keep:Int;\n\n\t/** Doc of drop. */\n\t#if !mobile\n\tpublic function drop():Void {}\n\t#end\n}\n', 'C',
			'drop'
		);
		Assert.equals(0, blockOpeners(text), text);
		Assert.isTrue(text.indexOf('#if') == -1, text);
	}

	/** A region with a surviving branch keeps its directives, and only the victim's doc goes. */
	public function testGuardedMemberInABranchPairTakesOnlyItsOwnDoc(): Void {
		final text: String = okMember(
			'class C {\n\t#if mobile\n\t/** Doc of drop. */\n\tpublic function drop():Void {}\n\t#else\n'
			+ '\t/** Doc of keep. */\n\tpublic function keep():Void {}\n\t#end\n}\n',
			'C', 'drop'
		);
		Assert.isTrue(text.indexOf('Doc of drop') == -1, text);
		Assert.isTrue(text.indexOf('Doc of keep') >= 0, text);
		Assert.isTrue(text.indexOf('#if mobile') >= 0, text);
	}

	/** A plain non-doc block comment above the doc is not documentation — it stays. */
	public function testPlainBlockCommentAboveTheDocSurvives(): Void {
		final text: String = okMember(
			'class C {\n\t/* section marker */\n\t/** Doc of drop. */\n\tvar drop:Int;\n\n\tvar keep:Int;\n}\n', 'C', 'drop'
		);
		Assert.isTrue(text.indexOf('section marker') >= 0, text);
		Assert.isTrue(text.indexOf('Doc of drop') == -1, text);
	}

	/** A stacked run of doc blocks above the member is all of its documentation — all of it goes. */
	public function testStackedDocRunAboveTheMemberAllGoes(): Void {
		final text: String = okMember('class C {\n\t/** First. */\n\t/** Second. */\n\tvar drop:Int;\n\n\tvar keep:Int;\n}\n', 'C', 'drop');
		Assert.equals(0, blockOpeners(text), text);
		Assert.isTrue(text.indexOf('keep') >= 0, text);
	}

	/** `withDoc = false` is the opt-out (`--keep-doc`): the doc is deliberately left. */
	public function testKeepDocOptOutLeavesTheDoc(): Void {
		final source: String = 'class C {\n\t/** Doc of drop. */\n\tvar drop:Int;\n\n\tvar keep:Int;\n}\n';
		switch RemoveMember.removeMember(source, 'C', 'drop', true, new HaxeQueryPlugin(), false) {
			case Ok(text):
				Assert.isTrue(text.indexOf('Doc of drop') >= 0, text);
				Assert.isTrue(text.indexOf('drop:Int') == -1, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** The cursor-addressed sibling behaves the same — one rule, not two. */
	public function testRemoveElementTakesTheDoc(): Void {
		final source: String = 'class C {\n\t/** Doc of drop. */\n\tvar drop:Int;\n\n\tvar keep:Int;\n}\n';
		switch RemoveElement.removeElement(source, 3, 2, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(0, blockOpeners(text), text);
				Assert.isTrue(text.indexOf('keep') >= 0, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** An import's own explanatory block goes with it; the surviving import keeps its own. */
	public function testRemoveImportTakesItsLeadingComment(): Void {
		final source: String =
			'package p;\n\n/** Only for the js target. */\nimport js.Browser;\n\n/** The other one. */\nimport a.A;\n\nclass C {}\n';
		switch RemoveImport.removeImport(source, 'js.Browser', true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('Only for the js target') == -1, text);
				Assert.isTrue(text.indexOf('The other one') >= 0, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** The number of block-comment openers left in `text`. */
	private function blockOpeners(text: String): Int {
		var count: Int = 0;
		for (i in 0...text.length - 1) if (text.charAt(i) == '/' && text.charAt(i + 1) == '*') count++;
		return count;
	}

	private function okMember(source: String, typeName: String, memberName: String): String {
		switch RemoveMember.removeMember(source, typeName, memberName, true, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

}

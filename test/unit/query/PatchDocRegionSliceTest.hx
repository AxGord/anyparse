package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Patch;
import anyparse.query.ReplaceNode;
import utest.Assert;
import utest.Test;

/**
 * `Patch.patchNode`'s doc guard where the documented declaration is not a plain sibling: the
 * first declaration of a conditional-compilation region a doc block sits above, and a documented
 * last member whose deletion leaves the block above the closing brace.
 */
class PatchDocRegionSliceTest extends Test {

	private static final ABOVE_REGION: String = 'class D {\n\t/**\n\t * About b.\n\t */\n\t#if foo\n\tpublic var b:Int;\n\t#end\n}\n';
	private static final LAST_DOCUMENTED: String =
		'class F {\n\tpublic var a:Int;\n\n\t/**\n\t * About b.\n\t */\n\tpublic var b:Int;\n}\n';

	/**
	 * Deleting the documented declaration above a conditional region hands its doc to the region's
	 * first declaration. The owner after the edit is the region, which has no name of its own, and
	 * the guard used to skip it.
	 *
	 * CONTROL for the conditional-region owner. KILLED by arm `M-PATCH-DOC-REGION-OWNER-UNREAD`.
	 */
	@:pin('control')
	@:killer('M-PATCH-DOC-REGION-OWNER-UNREAD')
	public function testDeletingTheDocumentedOneAboveARegionRefused(): Void {
		final source: String = 'class C {\n\t/**\n\t * About a.\n\t */\n\tpublic var a:Int;\n\n\t#if foo\n\tpublic var b:Int;\n\t#end\n}\n';
		assertRefused(source, 'C', '\tpublic var a:Int;\n\n', '', 'moves the `/**` block above `a` onto `b`');
	}

	/**
	 * Inserting a declaration between a doc block and the conditional region it documents moves the
	 * doc onto the insertion. The owner BEFORE the edit is the region, so nothing was watched.
	 *
	 * CONTROL for the conditional-region owner. KILLED by arm `M-PATCH-DOC-REGION-OWNER-UNREAD`.
	 */
	@:pin('control')
	@:killer('M-PATCH-DOC-REGION-OWNER-UNREAD')
	public function testInsertingAboveADocumentedRegionRefused(): Void {
		assertRefused(
			ABOVE_REGION, 'D', '#if foo\n\tpublic var b:Int;', 'public var z:Int;\n\n\t#if foo\n\tpublic var b:Int;',
			'moves the `/**` block above `b` onto `z`'
		);
	}

	/** Renaming the region's documented declaration in place keeps the doc where it belongs. */
	public function testRenamingInsideADocumentedRegionApplies(): Void {
		assertApplied(
			ABOVE_REGION, 'D', 'public var b:Int;', 'public var bb:Int;',
			'class D {\n\t/**\n\t * About b.\n\t */\n\t#if foo\n\tpublic var bb:Int;\n\t#end\n}\n'
		);
	}

	/**
	 * Deleting the LAST documented member without its doc leaves the block above the closing brace,
	 * documenting nothing — no declaration follows it to take it, so no transfer test fired.
	 *
	 * CONTROL for the orphaned block. KILLED by arm `M-PATCH-DOC-ORPHAN-UNCHECKED`.
	 */
	@:pin('control')
	@:killer('M-PATCH-DOC-ORPHAN-UNCHECKED')
	public function testDeletingTheLastDocumentedMemberAloneRefused(): Void {
		assertRefused(LAST_DOCUMENTED, 'F', 'public var b:Int;', '', 'leaves the `/**` block above `b` documenting nothing');
	}

	/** The remedy: the same deletion with the doc inside the fragment takes the doc with it. */
	public function testDeletingTheLastDocumentedMemberWithItsDocApplies(): Void {
		assertApplied(
			LAST_DOCUMENTED, 'F', '\n\n\t/**\n\t * About b.\n\t */\n\tpublic var b:Int;', '', 'class F {\n\tpublic var a:Int;\n}\n'
		);
	}

	private function assertRefused(source: String, type: String, oldText: String, newText: String, needle: String): Void {
		switch Patch.patchNode(source, BySelector('ClassDecl:$type'), oldText, newText, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains(needle, message);
		}
	}

	private function assertApplied(source: String, type: String, oldText: String, newText: String, expected: String): Void {
		switch Patch.patchNode(source, BySelector('ClassDecl:$type'), oldText, newText, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}

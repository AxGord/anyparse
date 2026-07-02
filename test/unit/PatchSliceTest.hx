package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Patch;
import anyparse.query.ReplaceNode.ReplaceTarget;

/**
 * `Patch.patchNode` — replace ONE unique fragment inside an addressed node,
 * the surgical counterpart of `ReplaceNode` for small edits. The fragment is
 * matched byte-exact first, then line-wise with indentation ignored (a
 * multi-line fragment copied from the DEDENTED `apq source --select` output);
 * either way it must occur exactly once within the resolved node's source.
 * Each `Ok` asserts the exact canonical output; refusals assert `Err`.
 */
class PatchSliceTest extends Test {

	public function testPatchWithinLine(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		final expected: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 2;\n' + '\t}\n' + '}\n';
		assertPatch(source, BySelector('FnMember:f'), 'return 1;', 'return 2;', expected);
	}

	public function testPatchDedentedMultiline(): Void {
		// The old fragment is flush-left, as `apq source --select` prints it —
		// the raw file lines carry two tabs; the line-wise match ignores that.
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\tvar a:Int = 1;\n' + '\t\treturn a;\n' + '\t}\n' + '}\n';
		final expected: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\tvar a:Int = 2;\n' + '\t\treturn a + 1;\n' + '\t}\n' + '}\n';
		assertPatch(source, BySelector('FnMember:f'), 'var a:Int = 1;\nreturn a;', 'var a:Int = 2;\nreturn a + 1;', expected);
	}

	public function testPatchByPosition(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		final expected: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 3;\n' + '\t}\n' + '}\n';
		// Line 2 col 11 is the `f` method-name token.
		final fnNameCol: Int = 11;
		assertPatch(source, ByPosition(2, fnNameCol), 'return 1;', 'return 3;', expected);
	}

	public function testDeleteFragment(): Void {
		// An empty new fragment deletes the old one; the emptied line survives as
		// blank trivia (removing a whole statement is `remove-element`'s job).
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\ttrace(1);\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		final expected: String = 'class C {\n' + '\tfunction f():Int {\n' + '\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertPatch(source, BySelector('FnMember:f'), 'trace(1);', '', expected);
	}

	public function testNotFoundRefused(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertRefused(source, BySelector('FnMember:f'), 'return 9;', 'return 2;');
	}

	public function testAmbiguousRefused(): Void {
		// `1;` occurs in both statements — the fragment must be widened.
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\ttrace(1);\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertRefused(source, BySelector('FnMember:f'), '1', '2');
	}

	public function testAmbiguousDedentedRefused(): Void {
		// Two identical trimmed lines — the line-wise fallback must also refuse.
		final source: String = 'class C {\n' + '\tfunction f():Void {\n' + '\t\ttrace(1);\n' + '\t\ttrace(1);\n' + '\t}\n' + '}\n';
		assertRefused(source, BySelector('FnMember:f'), 'trace(1);', 'trace(2);');
	}

	public function testIdenticalRefused(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertRefused(source, BySelector('FnMember:f'), 'return 1;', 'return 1;');
	}

	public function testEmptyOldRefused(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertRefused(source, BySelector('FnMember:f'), '', 'return 2;');
	}

	public function testUnparseableResultRefused(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertRefused(source, BySelector('FnMember:f'), 'return 1;', 'return ((;');
	}

	public function testFragmentOutsideNodeNotSeen(): Void {
		// The same fragment exists in g(), but the search region is f() only —
		// the patch is unambiguous and touches only f's occurrence.
		final source: String = 'class C {\n'
			+ '\tfunction f():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '\n' + '\tfunction g():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		final expected: String = 'class C {\n'
			+ '\tfunction f():Int {\n' + '\t\treturn 2;\n' + '\t}\n' + '\n' + '\tfunction g():Int {\n' + '\t\treturn 1;\n' + '\t}\n' + '}\n';
		assertPatch(source, BySelector('FnMember:f'), 'return 1;', 'return 2;', expected);
	}

	private function assertPatch(source: String, target: ReplaceTarget, oldText: String, newText: String, expected: String): Void {
		switch Patch.patchNode(source, target, oldText, newText, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, target: ReplaceTarget, oldText: String, newText: String): Void {
		switch Patch.patchNode(source, target, oldText, newText, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

}

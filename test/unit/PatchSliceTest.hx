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
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\treturn 2;\n\t}\n}\n';
		assertPatch(source, BySelector('FnMember:f'), 'return 1;', 'return 2;', expected);
	}

	public function testPatchDedentedMultiline(): Void {
		// The old fragment is flush-left, as `apq source --select` prints it —
		// the raw file lines carry two tabs; the line-wise match ignores that.
		final source: String = 'class C {\n\tfunction f():Int {\n\t\tvar a:Int = 1;\n\t\treturn a;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\tvar a:Int = 2;\n\t\treturn a + 1;\n\t}\n}\n';
		assertPatch(source, BySelector('FnMember:f'), 'var a:Int = 1;\nreturn a;', 'var a:Int = 2;\nreturn a + 1;', expected);
	}

	public function testPatchByPosition(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\treturn 3;\n\t}\n}\n';
		// Line 2 col 11 is the `f` method-name token.
		final fnNameCol: Int = 11;
		assertPatch(source, ByPosition(2, fnNameCol), 'return 1;', 'return 3;', expected);
	}

	public function testDeleteFragment(): Void {
		// An empty new fragment deletes the old one; the emptied line survives as
		// blank trivia (removing a whole statement is `remove-element`'s job).
		final source: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(1);\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\n\t\treturn 1;\n\t}\n}\n';
		assertPatch(source, BySelector('FnMember:f'), 'trace(1);', '', expected);
	}

	public function testNotFoundRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), 'return 9;', 'return 2;');
	}

	public function testAmbiguousRefused(): Void {
		// `1;` occurs in both statements — the fragment must be widened.
		final source: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(1);\n\t\treturn 1;\n\t}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), '1', '2');
	}

	public function testAmbiguousDedentedRefused(): Void {
		// Two identical trimmed lines — the line-wise fallback must also refuse.
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ttrace(1);\n\t\ttrace(1);\n\t}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), 'trace(1);', 'trace(2);');
	}

	public function testIdenticalRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), 'return 1;', 'return 1;');
	}

	public function testEmptyOldRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), '', 'return 2;');
	}

	public function testUnparseableResultRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), 'return 1;', 'return ((;');
	}

	public function testFragmentOutsideNodeNotSeen(): Void {
		// The same fragment exists in g(), but the search region is f() only —
		// the patch is unambiguous and touches only f's occurrence.
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n\n\tfunction g():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\treturn 2;\n\t}\n\n\tfunction g():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertPatch(source, BySelector('FnMember:f'), 'return 1;', 'return 2;', expected);
	}

	public function testTwoPairsApplied(): Void {
		// Both pairs land in one writer round-trip, matched against the ORIGINAL text.
		final source: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(1);\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(2);\n\t\treturn 3;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'trace(1);', newText: 'trace(2);' },
			{ oldText: 'return 1;', newText: 'return 3;' }
		];
		switch Patch.patchNodeMany(source, BySelector('FnMember:f'), pairs, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	public function testOverlappingPairsRefused(): Void {
		// The second pair's range sits inside the first one's — must refuse.
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1 + 2;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'return 1 + 2;', newText: 'return 9;' },
			{ oldText: '1 + 2', newText: '3' }
		];
		assertManyRefused(source, pairs);
	}

	public function testDuplicateOldPairsRefused(): Void {
		// Two pairs matching the SAME range overlap by definition.
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'return 1;', newText: 'return 2;' },
			{ oldText: 'return 1;', newText: 'return 3;' }
		];
		assertManyRefused(source, pairs);
	}

	public function testSecondPairNotFoundRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'return 1;', newText: 'return 2;' },
			{ oldText: 'missing();', newText: 'present();' }
		];
		assertManyRefused(source, pairs);
	}

	/**
	 * `--all` — the opt-in for a fan-out the caller means. Without it a repeated
	 * fragment is refused (the default discipline: an edit whose extent the
	 * caller cannot see is the one that lands somewhere unintended); with it
	 * every occurrence in the resolved node is rewritten.
	 */
	public function testAllRewritesEveryOccurrence(): Void {
		final source: String = 'class C {\n\tfunction a():Int {\n\t\treturn 1;\n\t}\n\n\tfunction b():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction a():Int {\n\t\treturn 2;\n\t}\n\n\tfunction b():Int {\n\t\treturn 2;\n\t}\n}\n';
		switch Patch.patchNode(source, BySelector('ClassDecl:C'), 'return 1;', 'return 2;', false, new HaxeQueryPlugin(), null, true) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
		// The same call without `--all` must still refuse — the flag is the only
		// thing that lifts the uniqueness gate.
		switch Patch.patchNode(source, BySelector('ClassDecl:C'), 'return 1;', 'return 2;', false, new HaxeQueryPlugin()) {
			case Ok(_):
				Assert.fail('expected Err for a repeated fragment without --all');
			case Err(message):
				Assert.isTrue(message.indexOf('--all') != -1, 'the refusal should point at --all, got: $message');
		}
	}

	public function testModuleTypedefRegionStopsAtNextDeclDoc(): Void {
		// A `@:trailOpt(';')` decl written without the `;` parses with a span running
		// on to the next declaration, so the searchable region used to include the
		// NEIGHBOUR's doc comment — patching a fragment of it rewrote a node nobody
		// addressed. The region is trimmed to the bytes the typedef owns, so the
		// fragment is simply not found.
		final source: String = '/** typedef doc */\ntypedef T = {\n\tfinal a:Int;\n}\n\n/** class doc */\nclass C {}\n';
		assertRefused(source, BySelector('TypedefDecl:T'), 'class doc', 'HIJACKED');
	}

	/**
	 * A doc-comment interior is writer-VERBATIM: `apq fmt` re-emits it byte for byte and
	 * calls the file canonical, no lint rule reads a continuation prefix, so an extra space
	 * in front of a ` * ` is a corruption nothing in this project can see. The line-wise arm
	 * used to splice at the first matched line's first NON-WHITESPACE byte, which left the
	 * source's own `\t ` standing and added the replacement's own ` ` on top of it — the
	 * first line of every such patch came out one column too deep and the run stayed green.
	 */
	public function testDocCommentInteriorKeepsItsIndent(): Void {
		final source: String = 'class C {\n\t/**\n\t * one\n\t * two\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\t/**\n\t * ONE\n\t * TWO\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), ' * one\n * two', ' * ONE\n * TWO', expected);
	}

	/**
	 * The same fragment run to the block's CLOSER. The old range stopped at the last matched
	 * line's last non-whitespace byte, so the closing marker lost its indentation — and the
	 * closer's indent is the base the writer re-indents the whole interior against, so every
	 * line of the block ABOVE the patch gained a level too. The whole-line range keeps it.
	 */
	public function testDocCommentPatchThroughTheCloserLeavesTheBlockAlone(): Void {
		final source: String = 'class C {\n\t/**\n\t * one\n\t * two\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\t/**\n\t * one\n\t * TWO\n\t * THREE\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), ' * two\n * three\n */', ' * TWO\n * THREE\n */', expected);
	}

	/**
	 * A multi-line STRING literal is the other writer-verbatim region, and there the
	 * indentation is not layout but the program's data: the same defect silently changed the
	 * value of the string.
	 */
	public function testMultilineStringInteriorKeepsItsIndent(): Void {
		final source: String = 'class C {\n\tstatic var s:String = "alpha\n\t\tbeta\n\t\tgamma";\n}\n';
		final expected: String = 'class C {\n\tstatic var s:String = "alpha\n\t\tBETA\n\t\tGAMMA";\n}\n';
		assertPatch(source, BySelector('VarMember:s'), 'beta\n\tgamma";', '\tBETA\n\tGAMMA";', expected);
	}

	/**
	 * The BYTE-EXACT arm is untouched by the re-basing: it matched the caller's own bytes,
	 * mid-line, and splices them back unchanged. Here the fragment's first line carries one
	 * tab where the file has two — the second tab stays in front of the splice point, which
	 * is what byte-exact matching means and NOT something to re-base away.
	 */
	public function testByteExactFragmentSplicedVerbatim(): Void {
		final source: String = 'class C {\n\tstatic var s:String = "alpha\n\t\tbeta\n\t\tgamma";\n}\n';
		final expected: String = 'class C {\n\tstatic var s:String = "alpha\n\t\tBETA\n\t\tGAMMA";\n}\n';
		assertPatch(source, BySelector('VarMember:s'), '\tbeta\n\t\tgamma";', '\tBETA\n\t\tGAMMA";', expected);
	}

	/**
	 * The replacement's OWN relative shape survives — a line the caller indented deeper than
	 * its neighbours stays deeper. Re-basing shifts the whole run by one amount; it never
	 * flattens the block to a single indent.
	 */
	public function testReplacementKeepsItsOwnRelativeShape(): Void {
		final source: String = 'class C {\n\t/**\n\t * one\n\t * two\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String =
			'class C {\n\t/**\n\t * ONE\n\t *   indented note\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), ' * one\n * two', ' * ONE\n *   indented note', expected);
	}

	/**
	 * A caller who copied the old fragment DEDENTED but wrote the replacement at the file's
	 * own indentation gets the first line where the matched line was, not one level deeper:
	 * the re-base reads the REPLACEMENT's first-line indentation, so a fragment already as
	 * deep as the site it landed on is left alone.
	 */
	public function testReplacementAlreadyAtSiteIndentIsNotShiftedAgain(): Void {
		final source: String = 'class C {\n\t/**\n\t * one\n\t * two\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\t/**\n\t * ONE\n\t * TWO\n\t * three\n\t */\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), ' * one\n * two', '\t * ONE\n\t * TWO', expected);
	}

	private function assertManyRefused(source: String, pairs: Array<{ oldText: String, newText: String }>): Void {
		switch Patch.patchNodeMany(source, BySelector('FnMember:f'), pairs, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
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

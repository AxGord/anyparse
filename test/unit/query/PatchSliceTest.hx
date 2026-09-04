package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.Patch;
import anyparse.query.ReplaceNode.ReplaceTarget;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `Patch.patchNode` — replace ONE unique fragment inside an addressed node,
 * the surgical counterpart of `ReplaceNode` for small edits. The fragment is
 * matched byte-exact first, then line-wise with indentation ignored (a
 * multi-line fragment copied from the DEDENTED `apq source --select` output);
 * either way it must occur exactly once within the resolved node's source.
 * Each `Ok` asserts the exact canonical output; refusals assert `Err`.
 */
class PatchSliceTest extends Test {

	/** A method holding a multi-line string literal — the shape whose interior lines are not whole lines of the node. */
	private static final MID_LINE_SOURCE: String = 'class C {\n\tfunction f():String {\n\t\treturn \'alpha\n\tbeta\n\tgamma\';\n\t}\n}\n';

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

	/**
	 * A payload that keeps the documented declaration and puts a NEW one ahead of it splices
	 * between a `/**` block and what it documents — the doc silently transfers to the insertion
	 * and the declaration is left bare, with `wrote <file>` reported and every gate green. It is
	 * refused instead. The fixture puts the doc on the SECOND member so the refusal cannot come
	 * from the class's own doc slot.
	 */
	public function testInsertAheadOfADocumentedMemberRefused(): Void {
		final source: String = 'class C {\n\tfunction a() {}\n\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		switch Patch.patchNode(
			source, BySelector('ClassDecl:C'), 'function b() {}', 'function c() {}\n\n\tfunction b() {}', false, new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				// The two NAMES are what makes this the doc-attachment guard and not some other
				// refusal: the doc moved off `b` and onto the inserted `c`.
				Assert.stringContains('moves the `/**` block above `b` onto `c`', message);
		}
	}

	/**
	 * The refusal's own remedy: widening the old fragment upward over the doc block makes the
	 * doc part of the match, so it travels with the declaration and the insertion lands above
	 * the whole unit. This is the control that keeps the refusal from being a dead end.
	 */
	public function testInsertAheadOfTheDocBlockAccepted(): Void {
		final source: String = 'class C {\n\tfunction a() {}\n\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		final expected: String = 'class C {\n\tfunction a() {}\n\n\tfunction c() {}\n\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		assertPatch(
			source, BySelector('ClassDecl:C'), '/**\n * About b.\n */\nfunction b() {}',
			'function c() {}\n\n/**\n * About b.\n */\nfunction b() {}', expected
		);
	}

	/**
	 * An ordinary in-place edit under a doc does NOT repeat the fragment's opening line ahead of
	 * itself, so the guard stays out of its way. Green at base by construction — the guard did
	 * not exist — and it is what pins the refusal to the insert-ahead shape alone.
	 */
	public function testInPlaceEditUnderADocAccepted(): Void {
		final source: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction b():Int {\n\t\treturn 1;\n\t}\n}\n';
		final expected: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction b():Int {\n\t\treturn 2;\n\t}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), 'return 1;', 'return 2;', expected);
	}

	/**
	 * A plain `/* ... *\/` banner above a member is NOT that member's documentation, so inserting
	 * after it is legitimate and is not refused. Green at base by construction; the discriminator
	 * against the fixture above is the doc opener alone.
	 */
	public function testInsertAfterAPlainBannerAccepted(): Void {
		final source: String = 'class C {\n\tfunction a() {}\n\n\t/* ---- section ---- */\n\tfunction b() {}\n}\n';
		final expected: String = 'class C {\n\tfunction a() {}\n\n\t/* ---- section ---- */\n\tfunction c() {}\n\n\tfunction b() {}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), 'function b() {}', 'function c() {}\n\n\tfunction b() {}', expected);
	}

	/**
	 * RENAMING a documented declaration was refused by the doc-attachment guard, which is the
	 * single most ordinary edit a documented member ever gets: the doc's owner NAME changes by
	 * construction, and the guard read any name change as the doc having moved onto something
	 * else. The discriminator is what happened to the OLD name — a transfer leaves the original
	 * declaration standing beside the insertion, a rename removes it from the container.
	 */
	public function testRenamingADocumentedMemberAccepted(): Void {
		final source: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		final expected: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction bee() {}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), 'function b() {}', 'function bee() {}', expected);
	}

	/** The same at module level, where the doc's owner is a type and the container is the module. */
	public function testRenamingADocumentedTypeAccepted(): Void {
		final source: String = '/**\n * About T.\n */\nclass T {}\n';
		final expected: String = '/**\n * About T.\n */\nclass U {}\n';
		assertPatch(source, BySelector('ClassDecl:T'), 'class T {}', 'class U {}', expected);
	}

	/**
	 * The survival test is scoped to the doc owner's own SIBLINGS, not to the file: a second
	 * type in the same module declaring the same member name is not evidence that anything was
	 * orphaned. A file-wide survival test — the obvious cheaper spelling — refuses this and
	 * nothing else.
	 */
	public function testRenamingADocumentedMemberWhoseNameASiblingTypeAlsoUsesAccepted(): Void {
		final source: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n\nclass D {\n\tfunction b() {}\n}\n';
		final expected: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction bee() {}\n}\n\nclass D {\n\tfunction b() {}\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), 'function b() {}', 'function bee() {}', expected);
	}

	/**
	 * The COMPOUND payload, and the hole the name test alone leaves: insert a declaration above
	 * the documented member AND rename that member in one call. The old name is gone, so the
	 * transfer/rename discriminator reads it as a rename — and lets S23's theft through at rc 0,
	 * doc sitting above the insertion, file parsing, every gate green. Found by review of the
	 * relaxation, not by any pin the relaxation shipped with; the two pure shapes it was mutated
	 * against cannot see it. The container-GREW signal is what refuses it, and dropping that
	 * disjunct flips exactly this test.
	 *
	 * GREEN at base by construction — the base guard refused every name change — so this is a
	 * regression pin for the pass that introduced it, not for the defect the slice set out to fix.
	 */
	public function testInsertAheadOfADocumentedMemberThatIsAlsoRenamedRefused(): Void {
		final source: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		switch Patch.patchNode(
			source, BySelector('ClassDecl:C'), 'function b() {}', 'function c() {}\n\n\tfunction bee() {}', false, new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains('moves the `/**` block above `b` onto `c`', message);
		}
	}

	/**
	 * The conservative edge of that second signal, pinned so a later attempt to make the guard
	 * precise has to flip a test rather than a user's file: renaming the documented declaration
	 * while ALSO adding an unrelated one to the same container is refused, even though nothing
	 * was orphaned. The refusal's own remedy — widen the fragment over the doc block — still
	 * applies, which is what makes over-refusing here the safe side.
	 */
	public function testRenamePlusAnUnrelatedInsertInTheSameContainerRefused(): Void {
		final source: String = 'class C {\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		switch Patch.patchNode(
			source, BySelector('ClassDecl:C'), 'function b() {}', 'function bee() {}\n\n\tfunction extra() {}', false,
			new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains('moves the `/**` block above `b` onto `bee`', message);
		}
	}

	/**
	 * The hole the container-GREW signal leaves, and why the name test stays beside it: a payload
	 * that inserts a declaration above the documented member AND deletes a different one keeps the
	 * count level, so growth sees nothing — but the original name survives, so `siblingDeclares`
	 * refuses. Dropping the name test and keeping only growth flips exactly this.
	 */
	public function testInsertAheadOfADocumentedMemberWhileDeletingAnotherRefused(): Void {
		final source: String = 'class C {\n\tfunction a() {}\n\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'function a() {}\n\n', newText: '' },
			{ oldText: 'function b() {}', newText: 'function c() {}\n\n\tfunction b() {}' }
		];
		switch Patch.patchNodeMany(source, BySelector('ClassDecl:C'), pairs, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains('moves the `/**` block above `b` onto `c`', message);
		}
	}

	/**
	 * The growth signal counts DECLARATIONS, not children: a modifier keyword projects its own
	 * sibling, so a payload that renames the documented member and adds `public` to a neighbour
	 * grows `parent.children` by one while declaring nothing new. Counting raw children instead
	 * refuses this, which is a false refusal on an edit that orphans nothing.
	 */
	public function testRenamePlusAModifierAddedToASiblingAccepted(): Void {
		final source: String = 'class C {\n\tfunction a() {}\n\n\t/**\n\t * About b.\n\t */\n\tfunction b() {}\n}\n';
		final expected: String = 'class C {\n\tpublic function a() {}\n\n\t/**\n\t * About b.\n\t */\n\tfunction bee() {}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'function a() {}', newText: 'public function a() {}' },
			{ oldText: 'function b() {}', newText: 'function bee() {}' }
		];
		switch Patch.patchNodeMany(source, BySelector('ClassDecl:C'), pairs, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
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

	/**
	 * A pair the caller SEQUENCED — wrote against the text the previous pair produces
	 * — can never match, because every pair is located against the ORIGINAL node. The
	 * standing remedy ("copy it verbatim from `apq source --select`") is wrong advice
	 * there: the bytes ARE right, the reference text is not. This is the shape that
	 * made a 9-pair call refuse while the same pairs applied one call at a time.
	 */
	public function testSequencedPairRefusalNamesTheOriginalTextRule(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'return 1;', newText: 'return 2;' },
			{ oldText: 'return 2;', newText: 'return 3;' }
		];
		final message: String = refusalMessage(source, pairs);
		Assert.isTrue(message.indexOf('EARLIER PAIRS') != -1, 'the refusal must name the earlier pairs, got: $message');
		Assert.isTrue(
			message.indexOf('located against the ORIGINAL node') != -1, 'the refusal must state the locating rule, got: $message'
		);
		Assert.isTrue(message.indexOf('does not occur in the original') != -1, 'it must say what the original holds, got: $message');
	}

	/**
	 * A pair that is merely AMBIGUOUS in the original — it occurs twice there and an
	 * earlier pair happens to overwrite one of them — is NOT a sequencing mistake, and
	 * the repeated arm already carries the remedy that resolves the whole call in one
	 * go: widen THIS pair, or pass --all. Superseding that message with the sequencing
	 * one took the working instruction away and offered two that do not apply, so the
	 * remedy is kept and only the missing fact is appended.
	 */
	public function testAmbiguousPairKeepsTheWidenRemedy(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = 1;\n\t\tvar b = 1;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'var a = 1;', newText: 'var a = 9;' },
			{ oldText: '= 1;', newText: '= 8;' }
		];
		final message: String = refusalMessage(source, pairs);
		Assert.isTrue(message.indexOf('occurs 2 times') != -1, 'it must count the original occurrences, got: $message');
		Assert.isTrue(message.indexOf('--all') != -1, 'the widen/--all remedy must survive, got: $message');
		Assert.isTrue(message.indexOf('An earlier pair does leave exactly one') != -1, 'it must add the earlier-pair fact, got: $message');
		Assert.isTrue(message.indexOf('EARLIER PAIRS') == -1, 'an ambiguous pair is not a sequencing mistake, got: $message');
		// And the remedy it keeps is the one that works: widening pair 2 lands both in ONE call.
		final widened: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'var a = 1;', newText: 'var a = 9;' },
			{ oldText: 'var b = 1;', newText: 'var b = 8;' }
		];
		switch Patch.patchNodeMany(source, BySelector('FnMember:f'), widened, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals('class C {\n\tfunction f():Void {\n\t\tvar a = 9;\n\t\tvar b = 8;\n\t}\n}\n', text);
			case Err(message2):
				Assert.fail('widening the ambiguous pair must resolve the call, got Err: $message2');
		}
	}

	/**
	 * Every multi-pair refusal says the whole payload was discarded. Naming one pair
	 * and stopping reads as "the others landed", and a caller who believes that goes
	 * on to build on an edit the file never received.
	 */
	public function testMultiPairRefusalSaysNothingWasApplied(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [
			{ oldText: 'return 1;', newText: 'return 2;' },
			{ oldText: 'missing();', newText: 'present();' }
		];
		final message: String = refusalMessage(source, pairs);
		Assert.isTrue(message.indexOf('pair 2:') != -1, 'the refusal must name the offending pair, got: $message');
		Assert.isTrue(message.indexOf('Nothing was applied') != -1, 'the refusal must say nothing landed, got: $message');
		Assert.isTrue(message.indexOf('all-or-nothing') != -1, 'the refusal must state the transaction rule, got: $message');
	}

	/** A single-pair call has no other pairs to discard — its refusal stays as it was. */
	public function testSinglePairRefusalStaysUnqualified(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final pairs: Array<{ oldText: String, newText: String }> = [{ oldText: 'missing();', newText: 'present();' }];
		final message: String = refusalMessage(source, pairs);
		Assert.isTrue(message.indexOf('all-or-nothing') == -1, 'a single-pair refusal must not talk about pairs, got: $message');
		Assert.isTrue(message.indexOf('pair 1:') == -1, 'a single-pair refusal must not carry a pair label, got: $message');
	}

	/**
	 * The CLI half of the contract, the half a caller composes with: a refused patch
	 * exits NON-ZERO and leaves the file byte-identical. That is the signal that
	 * survives a caller who reads neither stream — and the one the reported
	 * "printed nothing and applied nothing" call actually had.
	 */
	public function testCliRefusalExitsNonZeroAndLeavesTheFileAlone(): Void {
		#if (sys || nodejs)
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final fixture: String = CliFixture.write('apq_patch_refuse', source);
		final payload: String = CliFixture.writeAs(
			'apq_patch_payload', 'txt', 'return 1;\n====\nreturn 2;\n====\nreturn 2;\n====\nreturn 3;\n'
		);
		Assert.equals(1, Cli.run(['patch', fixture, '--select', 'FnMember:f', '--from-file', payload, '--write']));
		Assert.equals(source, sys.io.File.getContent(fixture), 'a refused multi-pair patch must leave the file byte-identical');
		sys.FileSystem.deleteFile(fixture);
		sys.FileSystem.deleteFile(payload);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Print-only mode is the one `patch` invocation that legitimately applies nothing
	 * and exits 0 — so the file must come back untouched. What used to make it
	 * indistinguishable from a silent no-op was the reporting, not this: `--write`
	 * announces itself on stderr and a preview announced nothing there at all.
	 */
	public function testCliPreviewLeavesTheFileUntouched(): Void {
		#if (sys || nodejs)
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n';
		final fixture: String = CliFixture.write('apq_patch_preview', source);
		final payload: String = CliFixture.writeAs('apq_patch_payload', 'txt', 'return 1;\n====\nreturn 2;\n');
		Assert.equals(0, Cli.run(['patch', fixture, '--select', 'FnMember:f', '--from-file', payload]));
		Assert.equals(source, sys.io.File.getContent(fixture), 'a preview must not write the file');
		sys.FileSystem.deleteFile(fixture);
		sys.FileSystem.deleteFile(payload);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The reporting half, and the only assertion in this project that reads a mutation
	 * op's STDERR. That stream is the whole fix: `--write` announced itself there and a
	 * preview announced nothing at all, so a caller keeping stderr and dropping stdout —
	 * the documented way to run these ops quietly — saw the same silence either way.
	 * `Cli.run` writes it to the real fd 2, which an in-process test cannot read, so the
	 * CLI runs as a child process here.
	 *
	 * Skipped, saying so, when the engine has not been built: `haxe test-js.hxml` alone
	 * is enough to run the suite, and a missing `bin/apq.js` is not a failing contract.
	 */
	public function testCliPreviewAndWriteBothAnnounceThemselvesOnStderr(): Void {
		#if nodejs
		final engine: String = 'bin/apq.js';
		if (!sys.FileSystem.exists(engine)) {
			Assert.pass('bin/apq.js is not built — the stderr contract needs the CLI as a process');
			return;
		}
		final source: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(1);\n\t\treturn 1;\n\t}\n}\n';
		final payload: String = CliFixture.writeAs(
			'apq_patch_stderr_payload', 'txt', 'trace(1);\n====\ntrace(2);\n====\nreturn 1;\n====\nreturn 3;\n'
		);
		final preview: String = patchStderr(CliFixture.write('apq_patch_stderr', source), payload, false, 0);
		Assert.isTrue(preview.indexOf('NOT written') != -1, 'a preview must say so on stderr, got: $preview');
		Assert.isTrue(preview.indexOf('2 fragment pairs applied') != -1, 'a multi-pair preview must name the count, got: $preview');
		final applied: String = patchStderr(CliFixture.write('apq_patch_stderr', source), payload, true, 0);
		Assert.isTrue(applied.indexOf('wrote') != -1, 'a write must say so on stderr, got: $applied');
		Assert.isTrue(applied.indexOf('2 fragment pairs applied') != -1, 'a multi-pair write must name the count, got: $applied');
		// A refusal is the third outcome, and the one that must never be mistaken for either.
		final refusedPayload: String = CliFixture.writeAs(
			'apq_patch_stderr_payload', 'txt', 'trace(1);\n====\ntrace(2);\n====\ntrace(2);\n====\ntrace(3);\n'
		);
		final refused: String = patchStderr(CliFixture.write('apq_patch_stderr', source), refusedPayload, true, 1);
		Assert.isTrue(refused.indexOf('all-or-nothing') != -1, 'a refusal must say nothing landed, got: $refused');
		sys.FileSystem.deleteFile(payload);
		sys.FileSystem.deleteFile(refusedPayload);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * A fragment that starts MID-LINE is invisible to both arms — the byte-exact one
	 * is a substring search and the dedent-tolerant one compares trimmed WHOLE lines —
	 * and the standing refusal sent the caller to `apq source --select`, whose output is
	 * DEDENTED and therefore the one form that cannot match. The refusal now names the
	 * line the fragment anchors inside and the widening that fixes it.
	 */
	public function testMidLineFragmentRefusalNamesTheAnchorLine(): Void {
		final message: String = refusalMessage(MID_LINE_SOURCE, [{ oldText: 'alpha\nbeta', newText: 'ALPHA\nBETA' }]);
		Assert.isTrue(
			message.indexOf('return \'alpha') != -1 && message.indexOf('WHOLE lines') != -1,
			'the refusal must name the anchor line and the whole-line rule, got: $message'
		);
	}

	/**
	 * The MIRROR shape, and the one the campaign actually tripped over: a fragment whose
	 * LAST line stops mid-line. Both arms miss it for the same reason as its sibling above,
	 * but until S68 only the START had a probe, so this one fell through to "copy it
	 * verbatim from `apq source --select`" — advice describing a fragment that WAS copied
	 * verbatim, merely not to the end of its line. The refusal now names the line the
	 * fragment stops inside.
	 */
	public function testFragmentEndingMidLineRefusalNamesTheHeadLine(): Void {
		final message: String = refusalMessage(MID_LINE_SOURCE, [{ oldText: 'return \'alpha\nbet', newText: 'return \'ALPHA\nBET' }]);
		Assert.isTrue(
			message.indexOf('HEAD of "beta"') != -1 && message.indexOf('WHOLE lines') != -1,
			'the refusal must name the line the fragment stops inside and the whole-line rule, got: $message'
		);
	}

	/**
	 * The measured LIMIT of both probes, written down because reasoning got it wrong: a fragment
	 * truncated at BOTH ends reaches NEITHER. Each probe allows a partial line at ONE end and
	 * requires every other line to match whole, so `alpha\nbet` fails the anchor arm on its last
	 * line and the tail arm on its first, and the generic remedy is what is left. Widening either
	 * probe to both ends at once would have to guess which end the caller meant.
	 */
	public function testFragmentTruncatedAtBothEndsReachesNeitherProbe(): Void {
		final message: String = refusalMessage(MID_LINE_SOURCE, [{ oldText: 'alpha\nbet', newText: 'ALPHA\nBET' }]);
		Assert.isTrue(message.indexOf('copy it verbatim') != -1, message);
		Assert.isTrue(message.indexOf('TAIL of') == -1 && message.indexOf('HEAD of') == -1, message);
	}

	/** CONTROL, green at base BY CONSTRUCTION: the byte-exact arm still reaches a mid-line fragment. */
	public function testMidLineFragmentByteExactStillApplies(): Void {
		assertPatch(
			MID_LINE_SOURCE, BySelector('FnMember:f'), 'alpha\n\tbeta', 'ALPHA\n\tBETA',
			'class C {\n\tfunction f():String {\n\t\treturn \'ALPHA\n\tBETA\n\tgamma\';\n\t}\n}\n'
		);
	}

	/**
	 * CONTROL, green at base BY CONSTRUCTION — and the witness that disproves the
	 * reported symptom: a WHOLE-LINE fragment matches flush-left, so indentation is
	 * not part of the match on the first line or any other. Widening the mid-line
	 * fragment above by the eight characters of its `return '` prefix is the whole
	 * difference. The string LITERAL's value changes here (`\t` before `beta` becomes
	 * `\t\t`) because the replacement is written flush-left and `rebased` re-bases it
	 * onto the matched line's indentation — the caller's own doing, not a defect.
	 */
	public function testWholeLineFragmentIsIndentationInsensitive(): Void {
		assertPatch(
			MID_LINE_SOURCE, BySelector('FnMember:f'), 'return \'alpha\nbeta', 'return \'ALPHA\nBETA',
			'class C {\n\tfunction f():String {\n\t\treturn \'ALPHA\n\t\tBETA\n\tgamma\';\n\t}\n}\n'
		);
	}

	/**
	 * CONTROL, green at base BY CONSTRUCTION: a fragment that anchors nowhere keeps the
	 * verbatim-copy remedy. The first line IS a mid-line tail (`alpha` of `return 'alpha`),
	 * so the tail gate passes and only the continuation check rejects — a fragment sharing
	 * no text with the source would be turned away by both gates at once and would pin
	 * neither.
	 */
	public function testAbsentFragmentKeepsTheVerbatimRemedy(): Void {
		final message: String = refusalMessage(MID_LINE_SOURCE, [{ oldText: 'alpha\nBETA', newText: 'X\nY' }]);
		Assert.isTrue(
			message.indexOf('copy it verbatim') != -1 && message.indexOf('TAIL of') == -1,
			'an unanchored fragment must keep the generic remedy, got: $message'
		);
	}

	/**
	 * The same guard, with the anchor on the SECOND annotation of a run. It reads the
	 * RUN start, not the addressed element's — and once `declGroupSpan` stopped walking
	 * forward off an annotation, the shared call answered the second annotation's own
	 * offset, so the guard looked for a `/**` directly above it, found the FIRST
	 * annotation, and let the doc-stealing insert through at rc 0. The single-annotation
	 * fixture above cannot see that: there the run start and the element start coincide.
	 */
	public function testInsertAheadOfADocumentedTwoAnnotationRunRefused(): Void {
		final source: String = '/**\n * About C.\n */\n@:keep\n@:access(foo.Bar)\nclass C {\n\tfunction f() {}\n}\n';
		switch Patch.patchNode(
			source, BySelector('ClassDecl:C'), '@:access(foo.Bar)\nclass C {', 'class D {}\n\n@:access(foo.Bar)\nclass C {', false,
			new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains('moves the `/**` block above `C` onto `D`', message);
		}
	}

	/**
	 * A doc-comment payload written with a SPACE gutter into a TAB-indented site
	 * applies — the writer owns a comment line's leading whitespace and converts it.
	 *
	 * Green at base BY CONSTRUCTION would be wrong here: this is RED at base. The
	 * verbatim-splice postcondition compared the pre-writer replacement against the
	 * post-writer result and demanded ONE shared shift across the run, so every payload
	 * the writer re-guttered read as the per-line corruption the check exists to catch —
	 * measured on the base build, 302 of 343 leading-whitespace combinations over this
	 * very shape were refused. Killed by arm M3.
	 */
	public function testDocPayloadWithASpaceGutterApplies(): Void {
		final source: String = 'class C {\n\n\t/**\n\t * Old.\n\t */\n\tfunction f():Void {}\n\n}\n';
		final expected: String = 'class C {\n\n\t/**\n\t * New.\n\t */\n\tfunction f():Void {}\n\n}\n';
		assertPatch(source, BySelector('ClassDecl:C'), ' /**\n * Old.\n */', ' /**\n * New.\n */', expected);
	}

	/**
	 * A code sample INSIDE a doc keeps its own indentation through the widened
	 * acceptance — everything a caller can still lose in a comment sits after the ` * `
	 * gutter, where `trim()` keeps it and the run match compares it byte for byte.
	 *
	 * RED at base for the same reason as the test above, and it carries the second half
	 * of the claim: killed by arm M3, which puts a comment back through the shape check.
	 */
	public function testDocCodeSampleIndentationSurvives(): Void {
		final source: String = 'class C {\n\n\t/**\n\t * Example:\n\t *     final x = 1;\n\t */\n\tfunction f():Void {}\n\n}\n';
		final expected: String = 'class C {\n\n\t/**\n\t * Example:\n\t *         final deeper = 1;\n\t */\n\tfunction f():Void {}\n\n}\n';
		// The payload's gutter is the DEDENTED `apq source --select` form, so the writer
		// re-guttering it is what arm M3 turns back into a refusal — and the assertion is
		// the code sample's own indentation, in the same string, so neither half can pass
		// alone.
		assertPatch(
			source, BySelector('ClassDecl:C'), ' /**\n * Example:\n *     final x = 1;\n */',
			' /**\n * Example:\n *         final deeper = 1;\n */', expected
		);
	}

	/**
	 * THE COUNTER-EXAMPLE the widened acceptance must not swallow: inside a STRING
	 * literal the writer is byte-verbatim, indentation IS the program's data, and a
	 * replacement whose lines shift by DIFFERENT amounts is still refused.
	 *
	 * The fragment is written with leading spaces so the byte-exact arm misses it and
	 * the dedent-tolerant arm — the only one whose indentation this op synthesises —
	 * owns the match. Killed by arm M5.
	 */
	public function testStringLiteralPerLineIndentStillRefused(): Void {
		final source: String = 'class C {\n\tfunction f():String {\n\t\treturn \'\n  a\n  b\';\n\t}\n}\n';
		switch Patch.patchNode(
			source, BySelector('FnMember:f'), "        return '\n    a\n    b';", "        return '\n        a\n    c';", false,
			new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains('string or regex literal, where indentation is content', message);
		}
	}

	/** The refusal text for `pairs`, or a failure when the call unexpectedly succeeded. */
	private function refusalMessage(source: String, pairs: Array<{ oldText: String, newText: String }>): String {
		switch Patch.patchNodeMany(source, BySelector('FnMember:f'), pairs, false, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
				return '';
			case Err(message):
				return message;
		}
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

	#if nodejs
	/** Run `apq patch` as a child process on `fixture`, assert its exit code, return its stderr. */
	private function patchStderr(fixture: String, payload: String, write: Bool, expectedExit: Int): String {
		final args: Array<String> = [
			'bin/apq.js',
			'patch',
			fixture,
			'--lang',
			'haxe',
			'--select',
			'FnMember:f',
			'--from-file',
			payload
		];
		if (write) args.push('--write');
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync(
			'node', args, cast { encoding: 'utf8' }
		);
		Assert.equals(expectedExit, run.status);
		final err: Null<String> = run.stderr == null ? null : Std.string(run.stderr);
		sys.FileSystem.deleteFile(fixture);
		return err ?? '';
	}
	#end

}

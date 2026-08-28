package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.Patch;
import anyparse.query.ReplaceNode.ReplaceTarget;
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

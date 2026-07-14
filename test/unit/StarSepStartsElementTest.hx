package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;

// Importing MiniBlockStrict first ensures its `@:build` macro defines
// the sibling Parser/Writer markers below before they are referenced.
import unit.miniblockstrict.MiniBlockStrict;
import unit.miniblockstrict.MiniBlockStrictParser;
import unit.miniblockstrict.MiniBlockStrictWriter;

/**
 * Session 9 pilot for the BlockBody Star `sepStartsElement` flag
 * ([[project-blockbody-star-tail-relax-debt]]). Companion to
 * `StarBlockEndedTest`, which pins the permissive-sep semantics on
 * `MiniBlock`. This pilot pins the strict-sep semantics on
 * `MiniBlockStrict`:
 *
 *  - `;` is a valid element body (`EmptyAtom`), so byte-ambiguity
 *    matters: under `sepStartsElement`, when block-ended is TRUE the
 *    sep byte at pos ALWAYS belongs to the next element, NEVER a
 *    separator.
 *  - Pre-Session-9 (permissive-sep) the same input would consume the
 *    sep byte greedily and lose the EmptyAtom — these tests would
 *    have failed.
 *
 * Once HxFnBlock.stmts opts into `sepStartsElement` the same
 * mechanism unblocks `HxControlFlowSliceTest.testEmptyStatementDoubled`
 * and `testEmptyStatementAfterBlock`.
 */
@:nullSafety(Strict)
class StarSepStartsElementTest extends Test {

	public function new(): Void {
		super();
	}

	// ---- Parser: positive cases pinning the new semantic ----

	public function testParseSingleEmptyAtom(): Void {
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{;}');
		switch ast {
			case Block([EmptyAtom]):
				Assert.pass();
			case _:
				Assert.fail('expected Block([EmptyAtom]), got $ast');
		}
	}

	public function testParseTwoEmptyAtoms(): Void {
		// `;;` — pre-Session-9 the 2nd `;` was greedily consumed as
		// sep, losing the EmptyAtom. Under `sepStartsElement` it is
		// the body of a fresh EmptyAtom.
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{;;}');
		switch ast {
			case Block([EmptyAtom, EmptyAtom]):
				Assert.pass();
			case _:
				Assert.fail('expected Block([EmptyAtom, EmptyAtom]), got $ast');
		}
	}

	public function testParseThreeEmptyAtoms(): Void {
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{;;;}');
		switch ast {
			case Block([EmptyAtom, EmptyAtom, EmptyAtom]):
				Assert.pass();
			case _:
				Assert.fail('expected Block of 3 EmptyAtoms, got $ast');
		}
	}

	public function testParseBlockThenEmptyThenAtom(): Void {
		// Strict variant of `StarBlockEndedTest.testParseBlockEndedWithSep`:
		// permissive pilot gives 2 elements (`Block`, `Atom`) by treating
		// the inner `;` as separator. Strict pilot gives 3 (`Block`,
		// `EmptyAtom`, `Atom`) because `;` is always element body when
		// block-ended.
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{{a};b}');
		switch ast {
			case Block([Block([Atom(a)]), EmptyAtom, Atom(b)]):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Block([Atom(a)]), EmptyAtom, Atom(b)]), got $ast');
		}
	}

	public function testParseAtomThenEmpty(): Void {
		// `{a;;}` — `a` is not block-ended, so the 1st `;` is the
		// mandatory separator; the 2nd `;` becomes EmptyAtom body.
		// Tail-relax doesn't trigger (no trailing `;` at the close
		// position — the 2nd `;` was already claimed as element body).
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{a;;}');
		switch ast {
			case Block([Atom(a), EmptyAtom]):
				Assert.equals('a', (a: String));
			case _:
				Assert.fail('expected Block([Atom(a), EmptyAtom]), got $ast');
		}
	}

	public function testParseBlockEndedAtomNoSepGap(): Void {
		// Companion to `StarBlockEndedTest.testParseBlockEndedNoSep`:
		// after `{a}` block-ended is TRUE, then `b` (not `;`) starts
		// the next element directly. No separator at the gap, so the
		// `sepStartsElement` policy doesn't fire — block-ended branch
		// still parses `b` correctly.
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{{a}b}');
		switch ast {
			case Block([Block([Atom(a)]), Atom(b)]):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Block([Atom]), Atom]), got $ast');
		}
	}

	public function testParsePredicateOnlyEndsImplicitly(): Void {
		// `Atom('end')` ends implicitly via the predicate. With
		// `sepStartsElement` flag set, the byte at pos that follows
		// `end` belongs to the next element, never a separator. So
		// `{end;b}` parses as 3 elements: Atom('end'), EmptyAtom,
		// Atom('b'). Permissive variant would have given 2.
		final ast: MiniBlockStrict = MiniBlockStrictParser.parse('{end;b}');
		switch ast {
			case Block([Atom(a), EmptyAtom, Atom(b)]):
				Assert.equals('end', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Atom(end), EmptyAtom, Atom(b)]), got $ast');
		}
	}

	// ---- Parser: negative cases ----

	public function testParseAtomsWithoutSepThrows(): Void {
		// Same negative as the permissive pilot: between two non-
		// block-ended Atoms, sep is mandatory.
		Assert.raises(MiniBlockStrictParser.parse.bind('{a b}'), Exception);
	}

	// ---- Writer: shape assertions ----

	public function testWriterTwoEmptyAtoms(): Void {
		// Two `;` bodies in a row — writer emits both `;` characters
		// back-to-back (no extra sep between them because EmptyAtom
		// ends with `;`, so block-ended is TRUE on the 1st element).
		final out: String = MiniBlockStrictWriter.write(Block([EmptyAtom, EmptyAtom]));
		Assert.isTrue(out.indexOf(';;') >= 0, 'expected `;;` in output, got <$out>');
	}

	public function testWriterAtomThenEmpty(): Void {
		// `Atom('a')` is NOT block-ended → sep `;` between Atom and
		// EmptyAtom is emitted. EmptyAtom body is `;`. Total `;`
		// count: 2.
		final out: String = MiniBlockStrictWriter.write(Block([Atom('a'), EmptyAtom]));
		final firstSep: Int = out.indexOf(';');
		Assert.isTrue(firstSep > 0, 'expected sep `;` after Atom, got <$out>');
	}

	// ---- Round-trip ----

	public function testRoundTripDoubleEmpty(): Void {
		roundTrip(Block([EmptyAtom, EmptyAtom]));
	}

	public function testRoundTripAtomThenEmpty(): Void {
		roundTrip(Block([Atom('a'), EmptyAtom]));
	}

	public function testRoundTripBlockEmptyAtom(): Void {
		roundTrip(Block([Block([Atom('a')]), EmptyAtom, Atom('b')]));
	}

	public function testRoundTripEndPredicateEmpty(): Void {
		roundTrip(Block([Atom('end'), EmptyAtom, Atom('b')]));
	}

	public function testRoundTripSingleAtom(): Void {
		roundTrip(Atom('solo'));
	}

	// ---- Helpers ----

	private function roundTrip(ast: MiniBlockStrict): Void {
		final written: String = MiniBlockStrictWriter.write(ast);
		var reparsed: MiniBlockStrict;
		try {
			reparsed = MiniBlockStrictParser.parse(written);
		} catch (exception: Exception) {
			Assert.fail('parse failed for <$written>: ${exception.message}');
			return;
		}
		Assert.isTrue(equals(ast, reparsed), 'round-trip mismatch: original=$ast, written=<$written>, reparsed=$reparsed');
	}

	private static function equals(a: MiniBlockStrict, b: MiniBlockStrict): Bool {
		return switch [a, b] {
			case [Atom(sa), Atom(sb)]: (sa: String) == (sb: String);
			case [EmptyAtom, EmptyAtom]: true;
			case [Block(la), Block(lb)]:
				if (la.length != lb.length)
					false;
				else {
					var ok: Bool = true;
					for (i in 0...la.length) if (!equals(la[i], lb[i])) {
						ok = false;
						break;
					}
					ok;
				}
			case _: false;
		};
	}

}

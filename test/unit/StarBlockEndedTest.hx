package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;

// Importing MiniBlock first ensures its `@:build` macro defines the
// sibling Parser/Writer markers below before they are referenced.
import unit.miniblock.MiniBlock;
import unit.miniblock.MiniBlockParser;
import unit.miniblock.MiniBlockWriter;

/**
 * Session 2 pilot for the BlockBody Star tail-relax refactor
 * ([[project-blockbody-star-tail-relax-debt]]).
 *
 * Exercises the new `@:sep(';', tailRelax, blockEnded)` Star primitive
 * on a minimal grammar (`MiniBlock`) without touching `HxStatement` /
 * the Haxe BlockBody migration. Pilot covers:
 *
 *  1. Tail-relax — trailing `;` before `}` allowed.
 *  2. Block-ended exemption — between two elements, `;` may be
 *     omitted when the prior element ends with `}`.
 *  3. Negative case — between two `Atom`s the sep is mandatory.
 *  4. Round-trip — `parse(write(ast)) == ast` for nested mixes.
 *  5. Writer shape — sep present between atoms, suppressed after a
 *     block.
 *
 * The pilot validates the mechanism end-to-end; the HxStatement
 * migration that deletes per-stmt `@:trailOpt(';')` and the
 * `stmtExprNoSemi` carve-outs is Session 3+ work.
 */
@:nullSafety(Strict)
class StarBlockEndedTest extends Test {

	public function new(): Void {
		super();
	}

	// ---- Parser: positive cases ----

	public function testParseAtom(): Void {
		// Top-level can be a bare Atom too — the grammar root is the
		// enum itself, not the Block ctor.
		final ast: MiniBlock = MiniBlockParser.parse('foo');
		assertAtom(ast, 'foo');
	}

	public function testParseEmptyBlock(): Void {
		final ast: MiniBlock = MiniBlockParser.parse('{}');
		switch ast {
			case Block(items):
				Assert.equals(0, items.length);
			case _:
				Assert.fail('expected empty Block, got $ast');
		}
	}

	public function testParseSingleAtomBlock(): Void {
		final ast: MiniBlock = MiniBlockParser.parse('{a}');
		switch ast {
			case Block(items):
				Assert.equals(1, items.length);
				assertAtom(items[0], 'a');
			case _:
				Assert.fail('expected Block, got $ast');
		}
	}

	public function testParseMultipleAtoms(): Void {
		final ast: MiniBlock = MiniBlockParser.parse('{a;b;c}');
		assertBlockOfAtoms(ast, ['a', 'b', 'c']);
	}

	public function testParseMultipleAtomsSpaced(): Void {
		// @:ws skips whitespace before every terminal, so spacing
		// between elements is irrelevant to the parser.
		final ast: MiniBlock = MiniBlockParser.parse('{ a ; b ; c }');
		assertBlockOfAtoms(ast, ['a', 'b', 'c']);
	}

	public function testParseTrailingSep(): Void {
		// Tail-relax: trailing `;` before `}` is tolerated.
		final ast: MiniBlock = MiniBlockParser.parse('{a;b;c;}');
		assertBlockOfAtoms(ast, ['a', 'b', 'c']);
	}

	public function testParseBlockEndedNoSep(): Void {
		// Block-ended exemption: after `{a}` (ends with `}`), the next
		// element follows directly with no `;`.
		final ast: MiniBlock = MiniBlockParser.parse('{{a} b}');
		switch ast {
			case Block([Block([Atom(a)]), Atom(b)]):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Block([Atom]), Atom]), got $ast');
		}
	}

	public function testParseBlockEndedWithSep(): Void {
		// Block-ended exemption is permissive, not mandatory — the
		// explicit `;` is still consumed normally and yields the same
		// AST as the no-sep form above.
		final ast: MiniBlock = MiniBlockParser.parse('{{a};b}');
		switch ast {
			case Block([Block([Atom(a)]), Atom(b)]):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Block([Atom]), Atom]), got $ast');
		}
	}

	public function testParseBlockEndedChainedNoSep(): Void {
		// Three blocks in a row, no `;` between any pair — every prior
		// element ends with `}`, so exemption applies to each gap.
		final ast: MiniBlock = MiniBlockParser.parse('{{a} {b} {c}}');
		switch ast {
			case Block([Block([Atom(a)]), Block([Atom(b)]), Block([Atom(c)])]):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
				Assert.equals('c', (c: String));
			case _:
				Assert.fail('expected three nested Blocks, got $ast');
		}
	}

	public function testParseAtomThenBlockNeedsSep(): Void {
		// Atom-then-Block still needs the sep: `a` does NOT end with
		// `}`, so the gap between `a` and `{b}` requires `;`.
		final ast: MiniBlock = MiniBlockParser.parse('{a; {b}}');
		switch ast {
			case Block([Atom(a), Block([Atom(b)])]):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Atom, Block([Atom])]), got $ast');
		}
	}

	public function testParsePredicateOnlyExemption(): Void {
		// Session 7 (b2) predicate-only path: `end` doesn't end with
		// `}`/`;` byte-wise, so the byte-check alone would reject
		// `{end b}`. `MiniBlockFormat.endsImplicitly` returns true on
		// `Atom('end')`, which is the SOLE reason the sep between
		// `end` and `b` may be elided. Companion to the existing
		// negative `testParseAtomsWithoutSepThrows` (`{a b}` rejected
		// because neither byte-check nor predicate accept `Atom('a')`).
		final ast: MiniBlock = MiniBlockParser.parse('{end b}');
		switch ast {
			case Block([Atom(a), Atom(b)]):
				Assert.equals('end', (a: String));
				Assert.equals('b', (b: String));
			case _:
				Assert.fail('expected Block([Atom(end), Atom(b)]), got $ast');
		}
	}

	// ---- Parser: negative cases ----

	public function testParseAtomsWithoutSepThrows(): Void {
		// `{a b}`: atom `a` doesn't end with `}`, block-ended
		// exemption doesn't apply, and there's no `;` either —
		// parser must reject.
		Assert.raises(MiniBlockParser.parse.bind('{a b}'), Exception);
	}

	public function testParseAtomTrailingNoSepThrows(): Void {
		// `{a b c}`: same reason as above, with multiple atoms.
		Assert.raises(MiniBlockParser.parse.bind('{a b c}'), Exception);
	}

	// ---- Writer: shape assertions ----

	public function testWriterEmptyBlock(): Void {
		final out: String = MiniBlockWriter.write(Block([]));
		Assert.equals('{}', out);
	}

	public function testWriterAtomsHaveSep(): Void {
		// Between two atoms the sep IS emitted (atom doesn't end
		// with `}`).
		final out: String = MiniBlockWriter.write(Block([Atom('a'), Atom('b')]));
		Assert.isTrue(out.indexOf(';') >= 0, 'expected sep `;` between atoms, got <$out>');
	}

	public function testWriterNoSepAfterBlock(): Void {
		// Between a Block and an Atom the sep is SUPPRESSED — Block
		// ends with `}`, block-ended exemption suppresses sep emit.
		final out: String = MiniBlockWriter.write(Block([Block([Atom('a')]), Atom('b')]));
		// No `;` between the inner `}` and the outer `b`. The only
		// possible `;` site is between elements of the outer Block;
		// inner Block has only one element, so no inner sep either.
		Assert.equals(-1, out.indexOf(';'), 'expected no sep `;` after inner block, got <$out>');
	}

	// ---- Round-trip ----

	public function testRoundTripAtomsOnly(): Void {
		roundTrip(Block([Atom('a'), Atom('b'), Atom('c')]));
	}

	public function testRoundTripMixed(): Void {
		roundTrip(Block([Block([Atom('a')]), Atom('b')]));
	}

	public function testRoundTripAllBlocks(): Void {
		roundTrip(Block([Block([Atom('a')]), Block([Atom('b')]), Block([Atom('c')])]));
	}

	public function testRoundTripNested(): Void {
		roundTrip(Block([
			Atom('outer'),
			Block([
				Atom('inner1'),
				Block([Atom('deep')]),
				Atom('inner2'),
			]),
			Atom('tail'),
		]));
	}

	public function testRoundTripEmpty(): Void {
		roundTrip(Block([]));
	}

	public function testRoundTripSingleAtom(): Void {
		roundTrip(Atom('solo'));
	}

	// ---- Helpers ----

	private function roundTrip(ast: MiniBlock): Void {
		final written: String = MiniBlockWriter.write(ast);
		var reparsed: MiniBlock;
		try {
			reparsed = MiniBlockParser.parse(written);
		} catch (exception: Exception) {
			Assert.fail('parse failed for <$written>: ${exception.message}');
			return;
		}
		Assert.isTrue(equals(ast, reparsed), 'round-trip mismatch: original=$ast, written=<$written>, reparsed=$reparsed');
	}

	private function assertAtom(node: MiniBlock, expected: String): Void {
		switch node {
			case Atom(s):
				Assert.equals(expected, (s: String));
			case _:
				Assert.fail('expected Atom($expected), got $node');
		}
	}

	private function assertBlockOfAtoms(node: MiniBlock, expected: Array<String>): Void {
		switch node {
			case Block(items):
				Assert.equals(expected.length, items.length);
				for (i in 0...items.length) assertAtom(items[i], expected[i]);
			case _:
				Assert.fail('expected Block of atoms, got $node');
		}
	}

	private static function equals(a: MiniBlock, b: MiniBlock): Bool {
		return switch [a, b] {
			case [Atom(sa), Atom(sb)]: (sa: String) == (sb: String);
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

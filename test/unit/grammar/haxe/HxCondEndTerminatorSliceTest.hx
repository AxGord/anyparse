package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * `@:fmt(trailOptKeepIf)`: the `;` after a statement-position `#if … #end` region that is the
 * body of an `if` / `else` / `while` / `for`.
 *
 * Those bodies carry a `@:trailOpt(';')` slot the writer never re-emits, on the premise that a
 * statement owns its own terminator. A `#if` region breaks the premise: its last branch may end
 * unterminated (`else #if d b() #else c() #end;`), and Haxe expands the region at token level, so
 * the `;` after `#end` IS the statement's terminator. Dropping it emits `Missing ;` at the next
 * statement. The slot is kept from source presence only for a region body; the redundant `;`
 * after a braced body still goes.
 */
@:nullSafety(Strict)
final class HxCondEndTerminatorSliceTest extends Test {

	private static final DEFAULT: String = '{}';
	private static final REMOVE: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } } }';

	public function new(): Void {
		super();
	}

	/** The reported shape: an `else` body that is an unterminated region. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-OFF')
	public function testElseBodyKeepsSemiAfterEnd(): Void {
		final src: String = wrap('if (x) a() else #if d b() #else c() #end;');
		final out: String = wrap('if (x)\n\t\t\ta()\n\t\telse\n\t\t\t#if d b() #else c() #end;');
		Assert.equals(out, HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	/** The then-body slot, with no `else` to absorb the terminator. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-OFF')
	public function testThenBodyKeepsSemiAfterEnd(): Void {
		final src: String = wrap('if (x) #if d b() #else c() #end;');
		final out: String = wrap('if (x)\n\t\t\t#if d b() #else c() #end;');
		Assert.equals(out, HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	/** The loop bodies share the slot and the meta. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-OFF')
	public function testLoopBodiesKeepSemiAfterEnd(): Void {
		final whileSrc: String = wrap('while (x) #if d b() #else c() #end;');
		Assert.equals(wrap('while (x)\n\t\t\t#if d b() #else c() #end;'), HxWriteFixture.triviaWrite(whileSrc, DEFAULT));
		final forSrc: String = wrap('for (i in xs) #if d b() #else c() #end;');
		Assert.equals(wrap('for (i in xs)\n\t\t\t#if d b() #else c() #end;'), HxWriteFixture.triviaWrite(forSrc, DEFAULT));
	}

	/** The tail of an `else if` chain, with an `#elseif` inside the region, under brace removal. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-OFF')
	public function testElseIfChainTailKeepsSemiUnderRemove(): Void {
		final src: String = wrap('if (x) a() else if (y) b() else #if d b() #elseif e a() #else c() #end;');
		final out: String = HxWriteFixture.triviaWrite(src, REMOVE);
		Assert.isTrue(StringTools.endsWith(out, '#else c() #end;\n\t}\n}'), 'expected `#end;` in: <$out>');
	}

	/** Source presence decides: a region whose branches carry their own `;` gains none after `#end`. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-PRESENCE-BLIND')
	public function testTerminatedRegionGainsNoSemi(): Void {
		final src: String = wrap('if (x) a() else #if d b(); #else c(); #end');
		final out: String = wrap('if (x)\n\t\t\ta()\n\t\telse\n\t\t\t#if d b(); #else c(); #end');
		Assert.equals(out, HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	/** The redundant `;` after a braced body still goes, so de-bracing cannot produce `;;`. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-UNGATED')
	public function testRedundantSemiAfterBlockStillDropped(): Void {
		final src: String = wrap('for (i in xs) { a(); };');
		final out: String = HxWriteFixture.triviaWrite(src, REMOVE);
		Assert.isTrue(out.indexOf('a();;') == -1, 'did not expect `;;` in: <$out>');
		Assert.isTrue(out.indexOf('a();') != -1, 'expected the body in: <$out>');
	}

	/**
	 * The last statement of a block: the `;` after `#end` is the block Star's trailing separator,
	 * which the writer drops after a `stmtNoSemi` element unless `@:fmt(trailSepKeepIf)` names it.
	 */
	@:pin('control')
	@:killer('M-TRAILSEP-KEEP-OFF')
	public function testBlockTailKeepsSemiAfterEnd(): Void {
		final fnBody: String = wrap('#if d b() #else c() #end;');
		Assert.equals(fnBody, HxWriteFixture.triviaWrite(fnBody, DEFAULT));
		final ifBlock: String = wrap('if (x) {\n\t\t\t#if d b() #else c() #end;\n\t\t}');
		Assert.equals(ifBlock, HxWriteFixture.triviaWrite(ifBlock, DEFAULT));
		final doBlock: String = wrap('do {\n\t\t\t#if d b() #else c() #end;\n\t\t} while (x);');
		Assert.equals(doBlock, HxWriteFixture.triviaWrite(doBlock, DEFAULT));
		final lambda: String = wrap('var q = () -> {\n\t\t\t#if d b() #else c() #end;\n\t\t};');
		Assert.equals(lambda, HxWriteFixture.triviaWrite(lambda, DEFAULT));
	}

	/** Every other `stmtNoSemi` tail still loses its redundant `;`. */
	@:pin('control')
	@:killer('M-TRAILSEP-KEEP-ALL')
	public function testBlockTailStillDropsSemiAfterSwitch(): Void {
		final src: String = wrap('switch x {\n\t\t\tcase _:\n\t\t};');
		Assert.equals(wrap('switch x {\n\t\t\tcase _:\n\t\t}'), HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	private static function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

}

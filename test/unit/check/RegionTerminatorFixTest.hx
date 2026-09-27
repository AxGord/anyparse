package unit.check;

import anyparse.check.Check;
import anyparse.check.CollapsibleIf;
import anyparse.check.EmptyStatement;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.PreferSwitch;
import anyparse.check.RedundantElse;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * `RegionTerminator` through every fix that moves, swaps or deletes around an if / loop body: a
 * statement-position `#if` region whose last branch ends unterminated (`#if d p() #else q() #end;`)
 * is closed by the `;` after its `#end`, which the parent's span owns. A fix that moves the region
 * without it emits `Missing ;` at the next statement; `empty-statement` deleting it does the same.
 */
@:nullSafety(Strict)
final class RegionTerminatorFixTest extends Test {

	private static inline final REGION: String = '#if d p() #else q() #end';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-REGION-TERM-OFF')
	public function testCollapsibleIfCarriesTheTerminator(): Void {
		final out: String = fixed(new CollapsibleIf(), wrap('if (a) {\n\t\t\tif (b) $REGION;\n\t\t}'));
		Assert.equals(wrap('if (a && b) $REGION;'), out);
	}

	@:pin('control')
	@:killer('M-REGION-TERM-OFF')
	public function testInvertSwapsTheTerminatorWithTheRegion(): Void {
		Assert.equals(wrap('if (a) $REGION; else p();'), fixed(new InvertNegatedIfElse(), wrap('if (!a) p(); else $REGION;')));
		Assert.equals(wrap('if (a) r(); else $REGION;'), fixed(new InvertNegatedIfElse(), wrap('if (!a) $REGION; else r();')));
	}

	/** A then-region closed only by the `else` cannot be proved to need no terminator in the tail slot. */
	@:pin('control')
	@:killer('M-INVERT-REGION-UNGUARDED')
	public function testInvertRefusesAnUnterminatedThenRegion(): Void {
		final src: String = wrap('if (!a) $REGION else r();');
		Assert.equals(src, fixed(new InvertNegatedIfElse(), src));
	}

	@:pin('control')
	@:killer('M-REGION-TERM-OFF')
	public function testRedundantElseCarriesTheTerminator(): Void {
		final out: String = fixed(new RedundantElse(), wrap('if (a) return; else $REGION;'));
		Assert.equals(wrap('if (a) return;\n$REGION;'), out);
	}

	/**
	 * `prefer-switch` needs no ownership: it appends a terminator to every body that does not end
	 * in one, so a region arrives terminated either way. Pinned so that stays true.
	 */
	@:pin('guard')
	public function testPreferSwitchDoesNotDoubleTheTerminator(): Void {
		final out: String = fixed(new PreferSwitch(), wrap('if (x == 1) $REGION; else if (x == 2) p(); else $REGION;'));
		Assert.isTrue(out.indexOf('switch') != -1, 'expected a switch in: <$out>');
		Assert.isTrue(out.indexOf('#end;;') == -1, 'did not expect `;;` in: <$out>');
	}

	@:pin('control')
	@:killer('M-REGION-TERM-OFF')
	public function testEmptyStatementKeepsARegionTerminator(): Void {
		Assert.equals(0, new EmptyStatement().run([{ file: 'C.hx', source: wrap('$REGION;\n\t\tp();') }], new HaxeQueryPlugin()).length);
		Assert.equals(1, new EmptyStatement().run([{ file: 'C.hx', source: wrap('p();;') }], new HaxeQueryPlugin()).length);
	}

	private static function fixed(check: Check, src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CheckFixture.applyEdits(src, check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin));
	}

	private static function wrap(body: String): String {
		return 'class C {\n\tfunction f(x:Int):Void {\n\t\t$body\n\t}\n}';
	}

}

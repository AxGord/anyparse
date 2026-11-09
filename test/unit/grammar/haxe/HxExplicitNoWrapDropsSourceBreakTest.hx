package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/** An explicit `defaultWrap` of `noWrap` lays a list out without reading the source's line breaks. */
final class HxExplicitNoWrapDropsSourceBreakTest extends Test {

	private static final FLAT: String = 'class C {\n\tvar o = {a: 1, b: 2};\n\tvar m = [1 => 2, 3 => 4];\n\tvar x:{a:Int, b:Int};\n}';
	private static final BROKEN: String = 'class C {\n\tvar o = {\n\t\ta: 1,\n\t\tb: 2\n\t};\n\tvar m = [\n\t\t1 => 2,\n\t\t3 => 4\n\t];\n'
		+ '\tvar x:{\n\t\ta:Int,\n\t\tb:Int\n\t};\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-EXPLICIT-NOWRAP-READS-SOURCE')
	public function testNoWrapOverDefaultRulesIsFlat(): Void {
		Assert.equals(FLAT, HxWriteFixture.triviaWrite(BROKEN, config('noWrap', '')));
	}

	@:pin('control')
	@:killer('M-EXPLICIT-NOWRAP-READS-SOURCE')
	public function testNoWrapWithAnEmptyCascadeIsFlat(): Void {
		Assert.equals(FLAT, HxWriteFixture.triviaWrite(BROKEN, config('noWrap', ',"rules":[]')));
	}

	@:pin('guard')
	public function testOnePerLineStillKeepsASourceBreak(): Void {
		Assert.equals(BROKEN, HxWriteFixture.triviaWrite(BROKEN, config('onePerLine', '')));
	}

	@:pin('control')
	@:killer('M-EXPLICIT-NOWRAP-TYPEDEF-BODY')
	public function testATypedefBodyIsFlat(): Void {
		Assert.equals(
			'typedef T = {a:Int, b:Int}', HxWriteFixture.triviaWrite('typedef T = {\n\ta:Int,\n\tb:Int\n}', config('noWrap', ''))
		);
		Assert.equals(
			'typedef U = {var a:Int; var b:Int;}',
			HxWriteFixture.triviaWrite('typedef U = {\n\tvar a:Int;\n\tvar b:Int;\n}', config('noWrap', ''))
		);
	}

	private static function config(mode: String, rest: String): String {
		final section: String = '{"defaultWrap":"$mode"$rest}';
		return '{"wrapping":{"objectLiteral":$section,"mapWrap":$section,"anonType":$section}}';
	}

}

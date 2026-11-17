package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A call whose arguments break only past the limit (`exceedsMaxLineLength` noWrap over a leading-break default)
 * stays flat while its line, what follows the call on it included, is at most `maxLineLength` wide, and opens its
 * parens one column past it.
 */
@:nullSafety(Strict)
final class CallParenProbeExactWidthTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
		+ '"value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	@:pin('guard')
	public function testCallLineEndingAtTheLimitStaysFlat(): Void {
		final flat: String = statement('final v:Int = compute(${letters(108)});');
		Assert.equals(flat, write(flat));
	}

	@:pin('guard')
	public function testCallLineOnePastTheLimitWithItsSemicolonOpens(): Void {
		final arg: String = letters(109);
		Assert.equals(statement('final v:Int = compute(\n\t\t\t$arg\n\t\t);'), write(statement('final v:Int = compute($arg);')));
	}

	private static function letters(n: Int): String {
		return [ for (_ in 0...n) 'a' ].join('');
	}

	private static function statement(s: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$s\n\t}\n}';
	}

	private static function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}

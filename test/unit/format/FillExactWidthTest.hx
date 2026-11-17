package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A fill layout (`fillLine`, `fillLineWithLeadingBreak`) keeps an item on its row while the row, separator or closing
 * delimiters included, is at most `maxLineLength` wide: a row of exactly the limit fits, one column more breaks. The
 * first row, a middle row ending in its `,`, the last row and a last row carrying a kept trailing `,` all measure alike.
 */
@:nullSafety(Strict)
final class FillExactWidthTest extends Test {

	private static final FILL: String = config('fillLine', '');
	private static final FILL_TRAILING: String = config('fillLine', '"trailingCommas": {"arrayLiteralDefault": "yes"}, ');
	private static final PARAMS_TRAILING: String = config(
		'fillLine', '"trailingCommas": {"functionParameterDefault": "yes"}, ', 'functionSignature'
	);
	private static final LEAD: String = config('fillLineWithLeadingBreak', '');
	private static final LEAD_TRAILING: String = config('fillLineWithLeadingBreak', '"trailingCommas": {"arrayLiteralDefault": "yes"}, ');

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-FILL-SEP-HEAD-FORK')
	public function testFillFirstRowEndsAtTheLimit(): Void {
		Assert.equals(fill([[x(16)].concat(xs(6)), [x(3)]]), write(FILL, [x(16)].concat(xs(6)).concat([x(3)])));
		Assert.equals(fill([[x(17)].concat(xs(6)), [x(3)]]), write(FILL, [x(17)].concat(xs(6)).concat([x(3)])));
	}

	@:pin('control')
	@:killer('M-FILL-SEP-HEAD-SLACK')
	public function testFillFirstRowPastTheLimitBreaks(): Void {
		Assert.equals(fill([[x(18)].concat(xs(5)), [x(10), x(3)]]), write(FILL, [x(18)].concat(xs(6)).concat([x(3)])));
	}

	@:pin('control')
	@:killer('M-FILL-SEP-HEAD-FORK')
	public function testFillMiddleRowEndsAtTheLimit(): Void {
		Assert.equals(fill([xs(7), xs(8).concat([x(16)]), [x(3)]]), write(FILL, xs(15).concat([x(16), x(3)])));
		Assert.equals(fill([xs(7), xs(8).concat([x(17)]), [x(3)]]), write(FILL, xs(15).concat([x(17), x(3)])));
	}

	@:pin('control')
	@:killer('M-FILL-SEP-HEAD-SLACK')
	public function testFillMiddleRowPastTheLimitBreaks(): Void {
		Assert.equals(fill([xs(7), xs(8), [x(18), x(3)]]), write(FILL, xs(15).concat([x(18), x(3)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-FORK')
	public function testFillLastRowEndsAtTheLimit(): Void {
		Assert.equals(fill([xs(7), xs(8).concat([x(15)])]), write(FILL, xs(15).concat([x(15)])));
		Assert.equals(fill([xs(7), xs(8).concat([x(16)])]), write(FILL, xs(15).concat([x(16)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-SLACK')
	public function testFillLastRowPastTheLimitBreaks(): Void {
		Assert.equals(fill([xs(7), xs(8), [x(17)]]), write(FILL, xs(15).concat([x(17)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-FORK')
	public function testFillTrailingCommaRowEndsAtTheLimit(): Void {
		Assert.equals(fill([xs(7), xs(8).concat([x(14)])], true), write(FILL_TRAILING, xs(15).concat([x(14)])));
		Assert.equals(fill([xs(7), xs(8).concat([x(15)])], true), write(FILL_TRAILING, xs(15).concat([x(15)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-SLACK')
	public function testFillTrailingCommaRowPastTheLimitBreaks(): Void {
		Assert.equals(fill([xs(7), xs(8), [x(16)]], true), write(FILL_TRAILING, xs(15).concat([x(16)])));
	}

	/** A parameter list measures its last row by the producer's tail reserve: the kept trailing `,` and the `)`. */
	@:pin('control')
	@:killer('M-FILL-TRAILING-TAIL-RESERVE')
	public function testFillTrailingCommaParamsPastTheLimitBreaks(): Void {
		final params: Array<String> = [ for (_ in 0...14) param(10) ];
		Assert.equals(
			lambda([params.slice(0, 7), params.slice(7), [param(11)]]),
			HxWriteFixture.triviaWrite(lambda([params.concat([param(11)])]), PARAMS_TRAILING)
		);
	}

	@:pin('control')
	@:killer('M-FILL-SEP-HEAD-FORK')
	public function testLeadingBreakMiddleRowEndsAtTheLimit(): Void {
		Assert.equals(lead([xs(8).concat([x(16)]), [x(3)]], false), write(LEAD, xs(8).concat([x(16), x(3)])));
		Assert.equals(lead([xs(8).concat([x(17)]), [x(3)]], false), write(LEAD, xs(8).concat([x(17), x(3)])));
	}

	@:pin('control')
	@:killer('M-FILL-SEP-HEAD-SLACK')
	public function testLeadingBreakMiddleRowPastTheLimitBreaks(): Void {
		Assert.equals(lead([xs(8), [x(18), x(3)]], false), write(LEAD, xs(8).concat([x(18), x(3)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-FORK')
	public function testLeadingBreakLastRowEndsAtTheLimit(): Void {
		Assert.equals(lead([xs(8).concat([x(17)])], false), write(LEAD, xs(8).concat([x(17)])));
		Assert.equals(lead([xs(8).concat([x(18)])], false), write(LEAD, xs(8).concat([x(18)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-SLACK')
	public function testLeadingBreakLastRowPastTheLimitBreaks(): Void {
		Assert.equals(lead([xs(8), [x(19)]], false), write(LEAD, xs(8).concat([x(19)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-FORK')
	public function testLeadingBreakTrailingCommaRowEndsAtTheLimit(): Void {
		Assert.equals(lead([xs(8).concat([x(16)])], true), write(LEAD_TRAILING, xs(8).concat([x(16)])));
		Assert.equals(lead([xs(8).concat([x(17)])], true), write(LEAD_TRAILING, xs(8).concat([x(17)])));
	}

	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-SLACK')
	public function testLeadingBreakTrailingCommaRowPastTheLimitBreaks(): Void {
		Assert.equals(lead([xs(8), [x(18)]], true), write(LEAD_TRAILING, xs(8).concat([x(18)])));
	}

	@:pin('guard')
	public function testRowAtTheLimitIsAFixedPoint(): Void {
		final fillAtLimit: String = fill([xs(7), xs(8).concat([x(17)]), [x(3)]]);
		final leadAtLimit: String = lead([xs(8).concat([x(18)])], false);
		Assert.equals(fillAtLimit, HxWriteFixture.triviaWrite(fillAtLimit, FILL));
		Assert.equals(leadAtLimit, HxWriteFixture.triviaWrite(leadAtLimit, LEAD));
	}

	private static function config(mode: String, extra: String, section: String = 'arrayWrap'): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, $extra"wrapping": {"maxLineLength": 140, '
			+ '"trailingComma": "keep", "arrayMatrixWrap": "noMatrixWrap", "$section": {"defaultWrap": "noWrap", "rules": '
			+ '[{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "$mode"}]}}}';
	}

	/** A string literal of `n` letters. */
	private static function x(n: Int): String {
		return "'" + [ for (_ in 0...n) 'x' ].join('') + "'";
	}

	/** `n` ten-letter string literals. */
	private static function xs(n: Int): Array<String> {
		return [ for (_ in 0...n) x(10) ];
	}

	private static function write(config: String, items: Array<String>): String {
		return HxWriteFixture.triviaWrite(field('[' + items.join(', ') + '];'), config);
	}

	private static function field(value: String): String {
		return 'class C {\n\tstatic final v:Array<String> = $value\n}';
	}

	/** A parameter `x…x:Int` of `n` letters. */
	private static function param(n: Int): String {
		return [ for (_ in 0...n) 'x' ].join('') + ':Int';
	}

	/** An arrow lambda whose parameters, each row joined by `, `, end in a trailing `,`. */
	private static function lambda(rows: Array<Array<String>>): String {
		return 'class C {\n\tstatic final v = (' + rows.map(row -> row.join(', ')).join(',\n\t\t\t') + ',) -> 1;\n}';
	}

	private static function fill(rows: Array<Array<String>>, trailing: Bool = false): String {
		return field('[' + rows.map(row -> row.join(', ')).join(',\n\t\t') + (trailing ? ',' : '') + '];');
	}

	private static function lead(rows: Array<Array<String>>, trailing: Bool): String {
		return field('[\n\t\t' + rows.map(row -> row.join(', ')).join(',\n\t\t') + (trailing ? ',' : '') + '\n\t];');
	}

}

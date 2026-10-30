package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A line comment among arguments lays the list out one argument per line wherever the arguments are written: a
 * `new` argument led by an own-line comment, as a call's is, and the arguments of a method-chain segment call,
 * where an after-separator comment rides its separator (`a, // c`) and an own-line one keeps its line. One pass
 * under every `callParameter` and `methodChain` `defaultWrap`.
 */
@:nullSafety(Strict)
final class HxArgLineCommentLayoutTest extends Test {

	private static final MODES: Array<String> = [
		'noWrap',
		'keep',
		'onePerLine',
		'onePerLineAfterFirst',
		'fillLine',
		'fillLineWithLeadingBreak'
	];
	private static final NEW_LEAD: Array<String> = [
		'final o = new Foo(',
		'\tfirst,',
		'\t// lead',
		'\tsecond,',
		'\tthird',
		');'
	];
	private static final CHAIN_ARGS: Array<String> = [
		'x.m(',
		'\ta, // after the separator',
		'\tb',
		').n();',
		'x.m(',
		'\ta,',
		'\t// own line',
		'\tb',
		').n();'
	];

	public function new(): Void {
		super();
	}

	/** A `new` argument led by an own-line comment puts the list one argument per line. */
	@:pin('control')
	@:killer('M-NEW-LEAD-COMMENT-INLINED')
	public function testNewArgumentLedByACommentIsOnePerLine(): Void {
		Assert.equals(fn(NEW_LEAD), write(fn(NEW_LEAD), '{}'));
	}

	/** A segment call keeps an after-separator comment after its comma and an own-line comment on its line. */
	@:pin('control')
	@:killer('M-CHAIN-ARGS-CASCADE-ONLY')
	public function testChainSegmentArgumentCommentsKeepTheirPlace(): Void {
		Assert.equals(fn(CHAIN_ARGS), write(fn(CHAIN_ARGS), '{}'));
	}

	/** Both forms are one pass under every argument and chain `defaultWrap`. */
	public function testOnePassUnderEveryDefaultWrap(): Void {
		for (mode in MODES) {
			final config: String = '{"wrapping": {"callParameter": {"defaultWrap": "$mode", "rules": []}, '
				+ '"methodChain": {"defaultWrap": "$mode", "rules": []}}}';
			final once: String = write(fn(NEW_LEAD.concat(CHAIN_ARGS)), config);
			Assert.equals(once, write(once, config), mode);
			Assert.isTrue(once.indexOf('a, // after the separator') >= 0, mode);
		}
	}

	private function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/** A one-function class whose body is `lines`, each at the body's indent. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + [for (line in lines) '\t\t$line\n'].join('') + '\t}\n}';
	}

}

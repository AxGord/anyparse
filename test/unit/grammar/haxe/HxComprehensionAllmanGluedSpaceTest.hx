package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A comprehension body that its Allman placement breaks is measured, in the first write, without the space the glued
 * placement leaves in front of it.
 *
 * `BodyAllman.gluedLayout` keeps the glued placement's `OptSpace(' ')` ahead of the body, and the hardline the Allman
 * side opens with drops it at render. The layout a list is offered for that break (`BodyAllman.tailBreak`) kept the space
 * too, so a first line measured on it — the cuddled `[for (…)` head of a comprehension — counted one column the output
 * never has: at exactly the limit the first write opened the bracket, and the next write, reading the Allman body from
 * its source with no space before it, cuddled it. The read-back layout now drops the space when the body is wholly the
 * decision, as the next write does; a body that only ends in one (a nested `for`) keeps the space before it.
 */
@:nullSafety(Strict)
final class HxComprehensionAllmanGluedSpaceTest extends Test {

	/** Columns a tab occupies under every config here. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `maxLineLength` of the compiled defaults. */
	private static inline final LIMIT_DEFAULT: Int = 160;

	/** `maxLineLength` of `CFG_CUDDLED`. */
	private static inline final LIMIT_CUDDLED: Int = 140;

	/** The widest `k` the sweeps write. */
	private static inline final MAX_K: Int = 120;

	/**
	 * Past these widths a token no break can split reaches the limit, on main as well: the inner comprehension's
	 * iterable, the long iterator's last argument, the nested `for`'s string.
	 */
	private static inline final MAX_K_INNER: Int = 112;

	private static inline final MAX_K_LONG_ITERATOR: Int = 103;

	private static inline final MAX_K_NESTED_FOR: Int = 119;

	/** The one width where main's fixed point of the long iterator is a column past the limit too (141 at 140). */
	private static inline final LONG_ITERATOR_SKEW: Int = 43;

	/** The compiled defaults, 160 columns. */
	private static final CFG_DEFAULT: String = '{}';

	/** A comprehension's open bracket cuddles its `for`, at 140 columns. */
	private static final CFG_CUDDLED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "comprehensionCuddledOpen": true}}';

	public function new(): Void {
		super();
	}

	/** One write is a fixed point within the limit across the width where the cuddled head reaches the limit exactly. */
	@:pin('control')
	@:killer('M-ALLMAN-GLUED-SPACE-KEPT')
	public function testOneWriteIsAFixedPointAtTheLimit(): Void {
		for (k in 1...MAX_K + 1) {
			assertOneWriteWithinLimit(fieldHead(k), CFG_CUDDLED, LIMIT_CUDDLED, k);
			assertOneWriteWithinLimit(longIterator(k), CFG_DEFAULT, LIMIT_DEFAULT, k);
		}
		for (k in 1...MAX_K_INNER + 1) assertOneWriteWithinLimit(innerComprehension(k), CFG_CUDDLED, LIMIT_CUDDLED, k);
		for (k in 1...MAX_K_LONG_ITERATOR + 1) {
			final slack: Int = k == LONG_ITERATOR_SKEW ? 1 : 0;
			assertOneWriteWithinLimit(longIterator(k), CFG_CUDDLED, LIMIT_CUDDLED + slack, k);
		}
	}

	/** A body that is a nested `for` keeps the space in front of it: only a body wholly the decision loses it. */
	@:pin('control')
	@:killer('M-ALLMAN-GLUED-SPACE-UNGUARDED')
	public function testANestedForKeepsItsSpace(): Void {
		for (k in 1...MAX_K_NESTED_FOR + 1) assertOneWriteWithinLimit(nestedFor(k), CFG_CUDDLED, LIMIT_CUDDLED, k);
	}

	private static function assertOneWriteWithinLimit(src: String, config: String, limit: Int, k: Int): Void {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k config=$config\n$src');
		var widest: Int = 0;
		for (line in once.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > widest) widest = width;
		}
		Assert.isTrue(widest <= limit, 'k=$k config=$config: a $widest-column line\n$once');
	}

	private static function fieldHead(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tfinal x = {\n\t\t\ttypes' + ''.lpad('k', k) + ': [for (entry in collectionOfThings) '
			+ '{alpha: entry.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, beta: entry.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}]\n\t\t};\n\t}\n}';
	}

	private static function innerComprehension(k: Int): String {
		return statement(
			'var y = [for (a in xs) [for (b in a' + ''.lpad('k', k)
			+ ') {alpha: b.aaaaaaaaaaaaaaaaaaaaaaaaa, beta: b.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb}]];'
		);
	}

	private static function longIterator(k: Int): String {
		return statement(
			'var y = [for (entry in someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree' + ''.lpad('k', k)
			+ ')) {alpha: entry.aaaaaaaaaaaaaaaa, beta: entry.bbbbbbbbbbbbbbbbbbbb}];'
		);
	}

	private static function nestedFor(k: Int): String {
		return statement(
			'var y = [for (a in xs) for (b in ys) {alpha: a.aaaaaaaaaaaaaaaaaa, beta: b.bbbbbbbbbbbbbbbbbbbbbb, k: \'' + ''.lpad('k', k)
			+ '\'}];'
		);
	}

	private static function statement(s: String): String {
		return 'class M {\n\tfunction f() {\n\t\t' + s + '\n\t}\n}';
	}

}

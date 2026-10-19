package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A comment that followed a list's trailing separator is written where the next parse will read it once the writer drops
 * that separator.
 *
 * `[for (t in xs) {lit}, // note]` keeps the comment on the ELEMENT: the parser reads the `,` first and the comment after
 * it. `wrapping.trailingComma: remove` drops the `,`, so the next parse meets `{lit} // note` and the literal's own close
 * capture takes the comment — it now sits inside the element, the element is multi-line, and the list lays out by the
 * multi-line-item rules (a comprehension cuddles its `for`, a ternary breaks at its operators). The first write laid the
 * list out with the comment outside the element, so a second write changed it. The writer now moves the comment of a
 * dropped separator to the slot the parser fills for that element's tail — the same tree a source without the comma
 * parses to — and leaves it on the element when the tail captures nothing (a paren, a field access, an index).
 */
@:nullSafety(Strict)
final class HxDroppedSepCommentTest extends Test {

	/** The number of list hosts `source` builds. */
	private static inline final HOSTS: Int = 4;

	/** The line comment every list ends with. */
	private static inline final NOTE: String = '// note';

	/** The trailing comma is dropped, a comprehension cuddles its `for`. */
	private static final CFG_REMOVE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"trailingComma": "remove", "comprehensionCuddledOpen": true}}';

	/** The compiled defaults: the source's trailing comma is kept. */
	private static final CFG_KEEP: String = '{}';

	/** Element tails whose close literal captures a same-line comment that follows it. */
	private static final CAPTURING_TAILS: Array<String> = [
		'{alpha: t.a, kind: k}',
		'foo(t, b)',
		'[t, b]',
		'new Foo(t)',
		'function() {return 1;}',
		't ? {a: 1} : {b: 2}',
		'if (c) {a: 1} else [b]',
		'if (c) {a: 1}',
		't + {a: 1}',
		'-foo(t)',
		'@:m {a: 1}',
		'for (u in t) {a: u}'
	];

	/** Element tails ending in a token no capture follows: the comment stays on the element. */
	private static final PLAIN_TAILS: Array<String> = ['(t + b)', '({a: 1})', 't.aaaa', 'xs[foo(t)]', 'i++', 'foo(t).bar', '"s"'];

	/** Tails whose own last construct already holds a comment, or that end in a `;` the source wrote. */
	private static final OCCUPIED_TAILS: Array<String> = ['{a: 1} /* x */', '[b] /* x */', 'foo(t) /* x */'];

	public function new(): Void {
		super();
	}

	/** Dropping the separator writes the tree the comma-less source parses to, and one write is a fixed point. */
	@:pin('control')
	@:killer('M-DROPPED-SEP-UNREHOMED')
	@:killer('M-TAIL-ABSENT-FIELD-STOPS')
	@:killer('M-TAIL-ARRAY-SLOT-UNREAD')
	@:killer('M-TAIL-CALL-SLOT-UNREAD')
	@:killer('M-TAIL-INFIX-UNREAD')
	@:killer('M-TAIL-OPERAND-UNREAD')
	@:killer('M-TAIL-PREFIX-UNREAD')
	@:killer('M-TAIL-TERNARY-UNREAD')
	public function testADroppedSeparatorsCommentIsWrittenWhereTheNextParseReadsIt(): Void {
		for (tail in CAPTURING_TAILS) for (host in 0...HOSTS) assertDroppedLikeAbsent(tail, host);
	}

	/** A tail that captures nothing keeps the comment on the element, after its last token, as the next parse does. */
	@:pin('control')
	@:killer('M-TAIL-ONLY-KNOWN-METAS')
	public function testATailThatCapturesNothingKeepsTheCommentOnTheElement(): Void {
		for (tail in PLAIN_TAILS) for (host in 0...HOSTS) {
			final once: String = assertDroppedLikeAbsent(tail, host);
			Assert.isTrue(once.indexOf('$tail $NOTE') >= 0, 'host=$host tail=$tail\n$once');
		}
	}

	/** A slot that already holds a comment, or a written `;` after the body, leaves the dropped separator's comment outside. */
	@:pin('control')
	@:killer('M-TAIL-SLOT-OVERWRITTEN')
	@:killer('M-TAIL-ALT-SLOT-OVERWRITTEN')
	@:killer('M-TAIL-WRITTEN-SEMICOLON-IGNORED')
	public function testAnOccupiedTailKeepsBothComments(): Void {
		for (tail in OCCUPIED_TAILS) for (host in 0...HOSTS) {
			final once: String = assertOneWriteIsAFixedPoint(source(tail, host, true, NOTE), CFG_REMOVE, tail);
			Assert.isTrue(once.indexOf('/* x */ $NOTE') >= 0, 'host=$host tail=$tail\n$once');
		}
		final semicolon: String = statement('var v = [\n\t\t\tfor (t in xs) {a: t, b: c ? {a: 1} : {b: 2}};, $NOTE\n\t\t];');
		final once: String = assertOneWriteIsAFixedPoint(semicolon, CFG_REMOVE, 'semicolon');
		Assert.isTrue(once.indexOf('}; $NOTE') >= 0, once);
	}

	/** A kept separator keeps the comment after it. */
	@:pin('control')
	@:killer('M-DROPPED-SEP-KEPT-REHOMED')
	public function testAKeptSeparatorKeepsTheCommentAfterIt(): Void {
		for (tail in CAPTURING_TAILS) {
			final once: String = assertOneWriteIsAFixedPoint(source(tail, 0, true, NOTE), CFG_KEEP, tail);
			Assert.isTrue(once.indexOf(', $NOTE') >= 0, '$tail\n$once');
		}
	}

	/** A block comment after a dropped separator stays on the element, where the first write already settles it. */
	@:pin('control')
	@:killer('M-DROPPED-SEP-BLOCK-REHOMED')
	public function testABlockCommentStaysOnTheElement(): Void {
		Assert.equals(
			statement('var v = [\n\t\t\taaaa,\n\t\t\tt ? {a: 1} : {b: 2} /* note */\n\t\t];'),
			assertOneWriteIsAFixedPoint(source('t ? {a: 1} : {b: 2}', 1, true, '/* note */'), CFG_REMOVE, 'block')
		);
	}

	private static function assertDroppedLikeAbsent(tail: String, host: Int): String {
		final dropped: String = assertOneWriteIsAFixedPoint(source(tail, host, true, NOTE), CFG_REMOVE, 'host=$host tail=$tail');
		Assert.equals(HxWriteFixture.triviaWrite(source(tail, host, false, NOTE), CFG_REMOVE), dropped, 'host=$host tail=$tail');
		return dropped;
	}

	private static function assertOneWriteIsAFixedPoint(src: String, config: String, what: String): String {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), '$what (second write)');
		return once;
	}

	/**
	 * `tail` as the last element of a list followed by `comment`, with or without the trailing comma: a comprehension body
	 * (0), an array element (1), an object field's value (2), a `new` argument (3).
	 */
	private static function source(tail: String, host: Int, comma: Bool, comment: String): String {
		final sep: String = comma ? ',' : '';
		return statement( switch host {
			case 0: 'var v = [\n\t\t\tfor (t in xs) $tail$sep $comment\n\t\t];';
			case 1: 'var v = [\n\t\t\taaaa, $tail$sep $comment\n\t\t];';
			case 2: 'var v = {\n\t\t\tfirst: aaaa, a: $tail$sep $comment\n\t\t};';
			case _: 'var v = new Foo(\n\t\t\taaaa, $tail$sep $comment\n\t\t);';
		});
	}

	private static function statement(s: String): String {
		return 'class M {\n\tfunction f() {\n\t\t$s\n\t}\n}';
	}

}

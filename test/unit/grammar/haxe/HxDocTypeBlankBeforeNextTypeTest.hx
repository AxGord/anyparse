package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A top-level type whose leading doc comment makes the next doc-commented type count as multiline gets
 * the blank before that next type even when the previous type carries a doc comment of its own: the
 * previous type's leading trivia never vetoes the before-rule.
 */
@:nullSafety(Strict)
final class HxDocTypeBlankBeforeNextTypeTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-DOC-TYPE-PREV-VETO-TRIVIA')
	public function testDocTypedefThenDocClass(): Void {
		final out: String = format(
			'/** D1. */\ntypedef Host = {\n\tfinal before:String;\n\tfinal after:String;\n}\n/** Doc. */\nclass C {}\n'
		);
		Assert.isTrue(out.indexOf('}\n\n/** Doc. */\nclass C {}') != -1, 'expected one blank before the second doc comment in: <$out>');
	}

	@:pin('control')
	@:killer('M-DOC-TYPE-PREV-VETO-TRIVIA')
	public function testDocClassThenDocClass(): Void {
		final out: String = format('/** D1. */\nclass A {}\n/** D2. */\nclass B {}\n');
		Assert.isTrue(
			out.indexOf('class A {}\n\n/** D2. */\nclass B {}') != -1, 'expected one blank before the second doc comment in: <$out>'
		);
	}

	public function testPlainTypedefThenDocClass(): Void {
		final out: String = format('typedef Host = {\n\tfinal before:String;\n}\n/** Doc. */\nclass C {}\n');
		Assert.isTrue(out.indexOf('}\n\n/** Doc. */\nclass C {}') != -1, 'expected one blank before the doc comment in: <$out>');
	}

	public function testMetaOnlyTypeThenDocClass(): Void {
		final out: String = format('@:meta\nclass A {}\n/** D. */\nclass B {}\n');
		Assert.isTrue(out.indexOf('class A {}\n\n/** D. */\nclass B {}') != -1, 'expected one blank before the doc comment in: <$out>');
	}

	public function testDocTypeThenPlainTypeStaysSourceDriven(): Void {
		final out: String = format('/** D1. */\nclass A {}\nclass B {}\n');
		Assert.isTrue(out.indexOf('class A {}\nclass B {}') != -1, 'expected no inserted blank before a single-line plain type in: <$out>');
	}

	public function testIdempotent(): Void {
		final src: String = '/** D1. */\ntypedef Host = {\n\tfinal before:String;\n}\n/** D2. */\nclass A {}\n/** D3. */\nclass B {}\n';
		final once: String = format(src);
		Assert.equals(once, format(once));
	}

	private inline function format(src: String): String {
		return HxWriteFixture.triviaWrite(src, '{}');
	}

}

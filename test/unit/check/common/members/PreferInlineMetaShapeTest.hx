package unit.check.common.members;

import anyparse.check.common.members.PreferInline;
import anyparse.query.GrammarPlugin;

/**
 * `prefer-inline` reads which modifier-run nodes are annotations from the grammar's `MetaShape`, not from a Haxe kind
 * table: under a grammar that spells annotations as other kinds, an `@:keep` method is still recognized as pinned and is
 * not offered `inline`, where a method with no annotation still is.
 */
@:nullSafety(Strict)
class PreferInlineMetaShapeTest extends Test {

	public function testPlainMethodIsOfferedInlineUnderTheRenamedGrammar(): Void {
		Assert.equals(1, findings('class C {\n\tfunction one():Int return 1;\n}', new RenamedAnnotationPlugin()));
	}

	@:pin('control') @:killer('M-METAKINDS-PREFER-INLINE')
	public function testRenamedKeepAnnotationPinsTheMethod(): Void {
		Assert.equals(0, findings('class C {\n\t@:keep function one():Int return 1;\n}', new RenamedAnnotationPlugin()));
	}

	@:pin('control') @:killer('M-METAKINDS-PREFER-INLINE-CLASS-RUN')
	public function testRenamedClassAnnotationBlocksTheClass(): Void {
		Assert.equals(0, findings('@:nativeGen class C {\n\tfunction one():Int return 1;\n}', new RenamedAnnotationPlugin()));
	}

	/** How many methods `prefer-inline` offers `inline` in `source` under `plugin`. */
	private static function findings(source: String, plugin: GrammarPlugin): Int {
		return CheckFixture.violations(new PreferInline(), source, plugin).length;
	}

}

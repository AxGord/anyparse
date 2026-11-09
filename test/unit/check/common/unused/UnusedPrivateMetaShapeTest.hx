package unit.check.common.unused;

import anyparse.check.common.unused.UnusedPrivate;
import anyparse.query.GrammarPlugin;

/**
 * `unused-private` reads which modifier-run nodes are annotations from the grammar's `MetaShape`, not from a Haxe kind
 * table: a grammar that spells annotations under other kinds, and writes them behind the modifiers they belong to, still
 * has its private empty constructor found.
 */
@:nullSafety(Strict)
class UnusedPrivateMetaShapeTest extends Test {

	/** A utility class whose only private member is the constructor, an annotation written beside its `private`. */
	private static final SOURCE: String =
		'package pkg;\n\nclass D {\n\n\tpublic static final K: Int = 1;\n\n\t@:foo private function new() {}\n\n}\n';

	public function testHaxeGrammarFindsThePrivateConstructor(): Void {
		Assert.equals(1, constructorFindings(new HaxeQueryPlugin()));
	}

	@:pin('control') @:killer('M-METAKINDS-UNUSED-PRIVATE-CTOR')
	public function testRenamedAnnotationKindsStillFindThePrivateConstructor(): Void {
		Assert.equals(1, constructorFindings(new RenamedAnnotationPlugin()));
	}

	/** How many `unused private constructor` findings `unused-private` reports over `SOURCE` under `plugin`. */
	private static function constructorFindings(plugin: GrammarPlugin): Int {
		return CheckFixture.violations(new UnusedPrivate(), SOURCE, plugin).filter(v -> v.message.indexOf('constructor') >= 0).length;
	}

}

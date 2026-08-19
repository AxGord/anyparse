package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.format.Text;

using StringTools;

/**
 * The default query projection carries an anonymous structure's field TYPES.
 *
 * Before this slice `{ xml:Xml, text:String }` and `{ xml:Int, text:Int }`
 * rendered the byte-identical `(Anon (Required xml) (Required text))`: the
 * `type` slot of an anon field body was dropped like every other type
 * annotation, so nothing reading `parseFile` — `ast`, `search`, `rewrite`, or
 * any rule keyed on the tree — could tell two structurally DIFFERENT anon
 * types apart once their field names matched. A deduplicating rule keyed on
 * that tree would have merged them.
 *
 * The `type` slot of `HxAnonFieldBody` now carries `@:queryTypeRef`, which
 * makes the walker project it through the SAME `_typeRefs` path
 * `parseFileTypeRefs` uses — one projection, not two. Every other type
 * annotation (var / member / parameter / return) stays dropped from the
 * default tree, which is what keeps `ast` lean.
 */
@:nullSafety(Strict)
class HxAnonFieldTypeProjectionTest extends Test {

	private static inline final XML_TEXT: String = 'class C { function f():{ xml:Xml, text:String } return null; }';
	private static inline final INT_INT: String = 'class C { function f():{ xml:Int, text:Int } return null; }';

	private static function ast(source: String): String return Text.render(new HaxeQueryPlugin().parseFile(source));

	/** The defect itself: same field names, different field types, one S-expr. */
	public function testFieldTypesDiscriminateTwoAnonShapes(): Void {
		final a: String = ast(XML_TEXT);
		final b: String = ast(INT_INT);
		Assert.notEquals(a, b, 'two anon types differing only in field TYPES must not render identically: $a');
		Assert.isTrue(a.contains('(Required xml (TypeRef Xml))'), 'field type must project as a child of its field, got: $a');
		Assert.isTrue(a.contains('(Required text (TypeRef String))'), 'field type must project as a child of its field, got: $a');
	}

	/** Optionality was already distinguished and must stay so, now alongside the type. */
	public function testOptionalMarkerSurvivesBesideTheType(): Void {
		final dump: String = ast('class C { function f():{ ?text:String, xml:Xml } return null; }');
		Assert.isTrue(dump.contains('(Optional text (TypeRef String))'), 'optional field keeps its own kind, got: $dump');
		Assert.isTrue(dump.contains('(Required xml (TypeRef Xml))'), 'required field keeps its own kind, got: $dump');
	}

	/** A parameterised field type projects head + each parameter, in source order. */
	public function testParameterisedFieldTypeProjectsEveryNominal(): Void {
		final dump: String = ast('class C { var v:{ p:Map<A, B> }; }');
		Assert.isTrue(dump.contains('(Required p (TypeRef Map) (TypeRef A) (TypeRef B))'), 'got: $dump');
	}

	/** A nested anon still descends as a declaration host rather than flattening to type refs. */
	public function testNestedAnonStillDescends(): Void {
		final dump: String = ast('class C { function g():{ a:{ b:Int }, c:Array<Int> } return null; }');
		Assert.isTrue(dump.contains('(Required a (Anon (Required b (TypeRef Int))))'), 'got: $dump');
		Assert.isTrue(dump.contains('(Required c (TypeRef Array) (TypeRef Int))'), 'got: $dump');
	}

	/**
	 * The rest of the default tree stays lean: var / member / parameter and
	 * return annotations are still dropped, so only the anon-field slot moved.
	 */
	public function testOtherTypeAnnotationsStayDropped(): Void {
		final dump: String = ast('class C { var a:Int; function f(p:haxe.io.Bytes):Null<Bar> return null; }');
		Assert.isFalse(dump.contains('TypeRef'), 'no type annotation outside an anon field may project, got: $dump');
	}

}

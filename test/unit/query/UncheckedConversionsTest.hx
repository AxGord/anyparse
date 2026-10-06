package unit.query;

import anyparse.check.FactsTypeTree;
import anyparse.query.CompilerFacts;
import anyparse.query.UncheckedConversions;
import utest.Assert;
import utest.Test;

/**
 * `UncheckedConversions` over hand-written facts files: which places hold only values of their own type because every build's
 * target converts a value put there (hxcpp), and which keep whatever a value that left the type system brings.
 */
@:nullSafety(Strict)
class UncheckedConversionsTest extends Test {

	/** The types the questions read: core values, the string and array types, aliases, classes. */
	private static final TYPES: Array<String> = [
		'{"k":"type","id":"Int","f":"A.hx","p":[0,1],"kind":"abstract","pack":"","meta":[":coreType",":notNull"]}',
		'{"k":"type","id":"cpp.Char","f":"A.hx","p":[0,1],"kind":"abstract","pack":"cpp","meta":[":coreType",":notNull"]}',
		'{"k":"type","id":"String","f":"A.hx","p":[0,1],"kind":"class","pack":"","ext":true}',
		'{"k":"type","id":"Array","f":"A.hx","p":[0,1],"kind":"class","pack":"","ext":true,"params":["T"]}',
		'{"k":"type","id":"cpp.Star","f":"A.hx","p":[0,1],"kind":"typedef","pack":"cpp","params":["T"],"target":"Null<$$cpp.Star.T>"}',
		'{"k":"type","id":"Count","f":"A.hx","p":[0,1],"kind":"typedef","pack":"","target":"Int"}',
		'{"k":"type","id":"MaybeCount","f":"A.hx","p":[0,1],"kind":"typedef","pack":"","target":"Null<Count>"}',
		'{"k":"type","id":"Foo","f":"A.hx","p":[0,1],"kind":"class","pack":""}',
		'{"k":"type","id":"FooAlias","f":"A.hx","p":[0,1],"kind":"typedef","pack":"","target":"Foo"}',
		'{"k":"type","id":"Peer","f":"A.hx","p":[0,1],"kind":"class","pack":"","ext":true}',
		'{"k":"type","id":"IFoo","f":"A.hx","p":[0,1],"kind":"interface","pack":""}',
		'{"k":"type","id":"Meters","f":"A.hx","p":[0,1],"kind":"abstract","pack":"","under":"Int"}'
	];

	@:pin('control') @:killer('M-UNCHECKED-TARGET') @:killer('M-UNCHECKED-ESCAPED') @:killer('M-UNCHECKED-BOXED')
	@:killer('M-UNCHECKED-STRING') @:killer('M-UNCHECKED-ARRAY') @:killer('M-UNCHECKED-POINTER') @:killer('M-UNCHECKED-ALIAS')
	@:killer('M-UNCHECKED-ALIAS-PLACE') @:killer('M-UNCHECKED-BOXED-ALIAS') @:killer('M-NATIVE-SITE-INERT') @:killer('M-NATIVE-SITE-CORE-TYPE')
	@:killer('M-NATIVE-SITE-ALIAS') @:killer('M-NATIVE-SITE-ARRAY-ELEMENTS')
	public function testAValueThatLeftTheTypeSystemSitsOnlyWhereSomeBuildKeepsIt(): Void {
		// hxcpp converts into a scalar, a string, an array, a C pointer to scalars and an alias of one: no object sits there,
		// whatever escaped. A nullable scalar is boxed — directly or behind an alias — and so is an array of them: once any object
		// escaped one may sit there, and none does while nothing escaped. Every place of another target keeps what it is handed
		final cpp: UncheckedConversions = conversions(['cpp']);
		for (t in [
			'Int',
			'String',
			'Array<Int>',
			'Null<Array<Int>>',
			'cpp.Char',
			'cpp.Star<cpp.Char>',
			'Count',
			'Array<String>'
		]) Assert.isTrue(cpp.none(read(t), true), '$t holds an object on hxcpp');
		for (t in ['Null<Int>', 'Null<Count>', 'MaybeCount', 'Array<Null<Int>>']) {
			Assert.isFalse(cpp.none(read(t), true), '$t is boxed on hxcpp');
			Assert.isTrue(cpp.none(read(t), false), '$t holds an object though nothing escaped');
		}
		final mixed: UncheckedConversions = conversions(['cpp', 'js']);
		Assert.isFalse(mixed.none(read('Int'), true));
		Assert.isTrue(mixed.none(read('Int'), false));
		Assert.isTrue(mixed.byType(read('Int')));
		Assert.isFalse(conversions([null]).none(read('Int'), true));
	}

	@:pin('control') @:killer('M-UNCHECKED-CLASS-EXTERN') @:killer('M-UNCHECKED-ALIKE')
	public function testAnInstanceOfAnotherClassSitsOnlyWhereSomeBuildKeepsIt(): Void {
		// hxcpp checks a conversion into a program class, and nulls an instance of another: an alias of one too. An interface,
		// an extern class and a non-core abstract keep what they are handed, as every place of another target does, and so does
		// a class the builds type unalike
		final cpp: UncheckedConversions = conversions(['cpp']);
		Assert.isFalse(cpp.holdsForeign('Foo'));
		Assert.isFalse(cpp.holdsForeign('FooAlias'));
		Assert.isTrue(cpp.holdsForeign('IFoo'));
		Assert.isTrue(cpp.holdsForeign('Peer'));
		Assert.isTrue(cpp.holdsForeign('Meters'));
		Assert.isTrue(conversions(['js']).holdsForeign('Foo'));
		final unalike: UncheckedConversions = new UncheckedConversions(CompilerFacts.build([
			{ name: 'one', text: dump('cpp', TYPES), file: path -> path },
			{
				name: 'two',
				text: dump('cpp', ['{"k":"type","id":"Foo","f":"A.hx","p":[0,1],"kind":"interface","pack":""}']),
				file: path -> path
			}
		], file -> null, file -> file), INERT, ARRAYS);
		Assert.isTrue(unalike.holdsForeign('Foo'));
	}

	@:pin('control') @:killer('M-FACTS-TARGET-RECORD')
	public function testAFactsFileSaysTheTargetItsBuildGeneratesCodeFor(): Void {
		// the record the producer writes second, read per configuration; a file without one says nothing
		final table: CompilerFacts = CompilerFacts.build([
			{ name: 'one', text: dump('cpp', []), file: path -> path },
			{ name: 'two', text: dump(null, []), file: path -> path }
		], file -> null, file -> file);
		Assert.same(['cpp', null], table.targets);
	}

	private static final INERT: Array<String> = ['Int', 'Float', 'Bool', 'String', 'Void'];

	private static final ARRAYS: Array<String> = ['Array'];

	/** The conversions of one build per target of `targets`, each holding `TYPES`; a null target writes no target record. */
	private static function conversions(targets: Array<Null<String>>): UncheckedConversions {
		final dumps: Array<FactsDump> = [
			for (i in 0...targets.length) { name: 'b$i', text: dump(targets[i], TYPES), file: path -> path }
		];
		return new UncheckedConversions(CompilerFacts.build(dumps, file -> null, file -> file), INERT, ARRAYS);
	}

	/** A facts file of a build for `target` holding `records`; null writes no target record. */
	private static function dump(target: Null<String>, records: Array<String>): String {
		final head: String = '{"k":"facts","v":1,"inline":true}\n' + (target == null ? '' : '{"k":"target","n":"$target"}\n');
		return head + [for (r in records) r + '\n'].join('') + '{"k":"end","nodes":0,"types":${records.length}}\n';
	}

	/** The facts type `text` spells. */
	private static function read(text: String): FactsType {
		final t: Null<FactsType> = FactsTypeTree.read(text);
		if (t == null) throw 'not a facts type: $text';
		return t;
	}

}

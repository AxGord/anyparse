package unit.check.haxe.expressions;

import anyparse.check.haxe.expressions.PreferCopyMethod;
import anyparse.query.CanonicalEdit;

using StringTools;

/**
 * `prefer-copy-method` with no `types` entry: a type whose constructor only stores its parameters into fields and whose
 * method returns `new T(...)` over those fields is proven a copy by its own source, and `new T(p.x, p.y)` becomes `p.clone()`.
 * Every deviation, in the constructor, the copy method or the type, leaves the construction alone.
 */
class CopyPairInferenceTest extends Test {

	private static inline final BARE: String = '{"rules":{"prefer-copy-method":{"enabled":true}}}';
	private static inline final FIELDS: String = 'public var x:Int;\n\tpublic var y:Int;\n\tpublic var z:Int;';
	private static inline final STORES: String = 'public function new(x:Int, y:Int) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t}';

	/** The repro: a constructor of plain stores and a copy method over the same fields, with no configuration at all. */
	@:pin('control')
	@:killer('M-INFER-USED')
	public function testSourceProvesTheCopy(): Void {
		final lib: Array<{ file: String, source: String }> = [type('Point2', STORES, copyOf('Point2', 'x, this.y'))];
		Assert.equals(1, count('Point2', lib));
		Assert.equals(holder('Point2', 'var c = p.clone();'), fixed('Point2', lib));
		final reversed: String = 'public function new(x:Int, y:Int) {\n\t\tthis.y = y;\n\t\tthis.x = x;\n\t}';
		Assert.equals(1, count('Point2', [type('Point2', reversed, copyOf('Point2', 'x, y'))]));
	}

	@:pin('guard')
	public function testConstructorDoingMoreIsSilent(): Void {
		final ctor: String = 'public function new(x:Int, y:Int) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t\ttrace(x);\n\t}';
		Assert.equals(0, count('Busy', [type('Busy', ctor, copyOf('Busy', 'x, y'))]));
	}

	@:pin('control')
	@:killer('M-INFER-CTOR-COUNT')
	public function testParameterStoredTwiceIsSilent(): Void {
		final ctor: String = 'public function new(x:Int, y:Int) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t\tthis.z = x;\n\t}';
		final lib: Array<{ file: String, source: String }> = [type('Twice', ctor, copyOf('Twice', 'z, y'))];
		Assert.equals(0, count('Twice', lib));
		Assert.equals(0, count('Twice', lib, 'z', 'y'));
	}

	@:pin('control')
	@:killer('M-INFER-FIELD-ONCE')
	public function testTwoParametersInOneFieldIsSilent(): Void {
		final ctor: String = 'public function new(x:Int, y:Int) {\n\t\tthis.x = x;\n\t\tthis.x = y;\n\t}';
		Assert.equals(0, count('Same', [type('Same', ctor, copyOf('Same', 'x, x'))], 'x', 'x'));
	}

	@:pin('control')
	@:killer('M-INFER-FIELD-TYPE')
	public function testFieldOfAnotherTypeIsSilent(): Void {
		final members: String = 'public var x:Float;\n\tpublic var y:Int;\n\t$STORES\n\t${copyOf('Wide', 'x, y')}';
		Assert.equals(0, count('Wide', [{ file: 'lib/Wide.hx', source: 'package lib;\nclass Wide {\n\t$members\n}' }]));
	}

	@:pin('control')
	@:killer('M-INFER-FIELD-ACCESSOR')
	public function testStoreThroughSetterIsSilent(): Void {
		final members: String = 'public var x(default, set):Int;\n\tpublic var y:Int;\n\tfunction set_x(v:Int):Int return x = v;\n\t'
			+ '$STORES\n'
			+ '\t${copyOf('Setter', 'x, y')}';
		Assert.equals(0, count('Setter', [{ file: 'lib/Setter.hx', source: 'package lib;\nclass Setter {\n\t$members\n}' }]));
	}

	/** The copy method reads the fields the constructor stores, in its parameter order: another order is another value. */
	@:pin('control')
	@:killer('M-INFER-COPY-FIELDS')
	public function testCopyOfOtherFieldsIsSilent(): Void {
		final lib: Array<{ file: String, source: String }> = [type('Swap', STORES, copyOf('Swap', 'y, x'))];
		Assert.equals(0, count('Swap', lib));
		Assert.equals(0, count('Swap', lib, 'y', 'x'));
	}

	@:pin('control')
	@:killer('M-INFER-COPY-ONE-STATEMENT')
	public function testCopyDoingMoreIsSilent(): Void {
		final copy: String = 'public function clone():More {\n\t\treturn new More(x, y);\n\t\ttrace(1);\n\t}';
		Assert.equals(0, count('More', [type('More', STORES, copy)]));
	}

	@:pin('control')
	@:killer('M-INFER-COPY-NEW-TYPE')
	public function testCopyBuildingAnotherTypeIsSilent(): Void {
		final copy: String = 'public function clone() {\n\t\treturn new Other(x, y);\n\t}';
		Assert.equals(0, count('Mimic', [type('Mimic', STORES, copy)]));
	}

	@:pin('control')
	@:killer('M-INFER-GENERIC')
	public function testGenericTypeIsSilent(): Void {
		final members: String = '$FIELDS\n\t$STORES\n\t${copyOf('Box<T>', 'x, y')}';
		final lib: Array<{ file: String, source: String }> =
			[{ file: 'lib/Box.hx', source: 'package lib;\nclass Box<T> {\n\t$members\n}' }];
		Assert.equals(0, count('Box', lib, 'x', 'y', 'Box<Int>'));
	}

	@:pin('control')
	@:killer('M-INFER-CTOR-PLAIN')
	public function testDefaultedParameterIsSilent(): Void {
		final ctor: String = 'public function new(x:Int, y:Int = 0) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t}';
		Assert.equals(0, count('Lax', [type('Lax', ctor, copyOf('Lax', 'x, y'))]));
	}

	/** Two proven copy methods leave no one name to rewrite to. */
	@:pin('control')
	@:killer('M-INFER-ONE-COPY')
	public function testTwoProvenCopiesAreSilent(): Void {
		final copies: String = copyOf('Twin', 'x, y') + '\n\t' + copyOf('Twin', 'x, y').replace('clone', 'copy');
		Assert.equals(0, count('Twin', [type('Twin', STORES, copies)]));
	}

	/** A type the project configured is read from its entry alone: a site that entry does not name is not inferred. */
	@:pin('control')
	@:killer('M-INFER-CONFIG-WINS')
	public function testConfiguredTypeIsNotInferred(): Void {
		final json: String = '{"rules":{"prefer-copy-method":{"enabled":true,"types":{"lib.Point2":{"fields":["y","x"],"copy":"clone"}}}}}';
		final lib: Array<{ file: String, source: String }> = [type('Point2', STORES, copyOf('Point2', 'x, y'))];
		Assert.equals(0, count('Point2', lib, 'x', 'y', null, json));
		Assert.equals(1, count('Point2', lib, 'y', 'x', null, json));
	}

	/** The fields a copy takes are the ones the constructor stores, in its parameter order, whatever the parameters are called. */
	@:pin('control')
	@:killer('M-INFER-SITE-FIELDS')
	public function testCrossedStoresFollowParameterOrder(): Void {
		final ctor: String = 'public function new(a:Int, b:Int) {\n\t\tthis.x = b;\n\t\tthis.y = a;\n\t}';
		final lib: Array<{ file: String, source: String }> = [type('Crossed', ctor, copyOf('Crossed', 'y, x'))];
		Assert.equals(1, count('Crossed', lib, 'y', 'x'));
		Assert.equals(0, count('Crossed', lib, 'x', 'y'));
	}

	/** A subtype's `clone` yields the subtype while `new T` yields exactly `T`, however the copy was proven. */
	@:pin('control')
	@:killer('M-COPYM-OVERRIDE')
	public function testOverriddenInferredCopyIsSilent(): Void {
		final lib: Array<{ file: String, source: String }> = [
			type('Open', STORES, copyOf('Open', 'x, y')),
			{
				file: 'lib/Soft.hx',
				source: 'package lib;\nclass Soft extends Open {\n\toverride public function clone():Open return new Soft(x, y);\n}'
			}
		];
		Assert.equals(0, count('Open', lib));
	}

	/** A type the resolution index does not hold has no source to prove. */
	@:pin('guard')
	public function testTypeOutsideTheIndexIsSilent(): Void {
		Assert.equals(0, count('Point2', []));
	}

	/** Every constructor statement stores a parameter: a store of anything else, here a constant, is no part of a plain copy. */
	@:pin('control')
	@:killer('M-INFER-CTOR-COUNT')
	public function testConstructorStoringANonParameterIsSilent(): Void {
		final ctor: String = 'public function new(x:Int, y:Int) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t\tthis.z = Q;\n\t}';
		Assert.equals(0, count('Konst', [type('Konst', ctor, copyOf('Konst', 'x, y'))]));
	}

	private function copyOf(name: String, args: String): String {
		return 'public function clone():$name {\n\t\treturn new ${name.split('<')[0]}($args);\n\t}';
	}

	private function type(name: String, ctor: String, copy: String): { file: String, source: String } {
		return { file: 'lib/$name.hx', source: 'package lib;\nclass $name {\n\t$FIELDS\n\t$ctor\n\t$copy\n}' };
	}

	private function holder(name: String, statement: String, ?written: String): String {
		return 'import lib.$name;\n\nclass C {\n\n\tfunction f(p:${written ?? name}):Void {\n\t\t$statement\n\t}\n}';
	}

	private function site(name: String, a: String, b: String, ?written: String): String {
		return holder(name, 'var c = new $name(p.$a, p.$b);', written);
	}

	private function count(
		name: String, lib: Array<{ file: String, source: String }>, a: String = 'x', b: String = 'y', ?written: String, ?json: String
	): Int {
		final config: String = json ?? BARE;
		return CheckFixture.violationsIn(
			new PreferCopyMethod(), lib.concat([{ file: 'C.hx', source: site(name, a, b, written) }]), null, _ -> LintConfig.parse(config)
		)
			.filter(v -> v.file == 'C.hx')
			.length;
	}

	private function fixed(name: String, lib: Array<{ file: String, source: String }>): String {
		final source: String = site(name, 'x', 'y');
		return CanonicalEdit.applyEdits(
			source,
			CheckFixture.fixRun(
				new PreferCopyMethod(), lib.concat([{ file: 'C.hx', source: source }]), 'C.hx', null, _ -> LintConfig.parse(BARE)
			)
				.edits
		);
	}

}

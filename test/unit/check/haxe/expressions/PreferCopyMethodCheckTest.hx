package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.PreferCopyMethod;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-copy-method` check: `new T(v.a, v.b)` over a configured pair is flagged `Info` and rewritten to `v.clone()`
 * when `v` is exactly `T`, everything read is pure and no subtype overrides the copy method; every other shape stays silent.
 */
class PreferCopyMethodCheckTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"prefer-copy-method":{"enabled":true,"types":{'
		+ '"lib.Point":{"fields":["x","y"],"copy":"clone"},'
		+ '"lib.Rigid":{"fields":["x","y"],"copy":"clone"},'
		+ '"lib.Sealed":{"fields":["x","y"],"copy":"clone"},'
		+ '"lib.Lazy":{"fields":["x","y"],"copy":"clone"},'
		+ '"lib.Selfish":{"fields":["x","y"],"copy":"clone"}}}}}';

	public function testHandCopyBecomesCopyMethod(): Void {
		final src: String = holder('var c = new Point(p.x, p.y);');
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.equals('prefer-copy-method', found[0].rule);
		Assert.equals(Severity.Info, found[0].severity);
		Assert.equals(holder('var c = p.clone();'), fixed(src));
	}

	public function testFieldPathReceiverIsCopied(): Void {
		Assert.equals(holder('var c = h.p.clone();'), fixed(holder('var c = new Point(h.p.x, h.p.y);')));
	}

	public function testUnoverriddenSubtypeIsCopied(): Void {
		Assert.equals(holder('var c = p.clone();'), fixed(holder('var c = new Point(p.x, p.y);')));
	}

	/**
	 * A final type has no subtype to override the copy method, so an unrelated type whose ancestry the index cannot resolve
	 * does not stop it; a non-final type stays refused for the same input.
	 */
	@:pin('control')
	@:killer('M-COPYM-FINAL')
	public function testFinalClassIsCopiedBesideAnUnresolvedOverride(): Void {
		final stray: Array<{ file: String, source: String }> = [{
			file: 'lib/Stray.hx',
			source: 'package lib;\nclass Stray extends ext.Shape {\n\toverride public function clone():Stray return null;\n}'
		}];
		Assert.equals(holder('var c = e.clone();'), fixed(holder('var c = new Sealed(e.x, e.y);'), stray));
		Assert.equals(0, violations(holder('var c = new Point(p.x, p.y);'), 'C.hx', stray).length);
	}

	/** A simple name that two declarations share cannot tell the configured type from the other one a receiver may be. */
	@:pin('control')
	@:killer('M-COPYM-ONE-DECL')
	public function testSimpleNameDeclaredTwiceIsSilent(): Void {
		final twin: Array<{ file: String, source: String }> = [{
			file: 'other/Point.hx',
			source: 'package other;\nclass Point {\n\tpublic var x:Int;\n\tpublic var y:Int;\n'
				+ '\tpublic function clone():Point return null;\n}'
		}];
		for (statement in [
			'var o: other.Point = null;\n\t\tvar c = new Point(o.x, o.y);',
			'var c = new Point(p.x, p.y);'
		]) Assert.equals(0, violations(holder(statement), 'C.hx', twin).length, statement);
	}

	/** A reordered, missing, extra or computed argument is no copy of the configured fields. */
	@:pin('control')
	@:killer('M-COPYM-ANY-ORDER')
	public function testOtherArgumentsAreSilent(): Void {
		for (statement in [
			'var c = new Point(p.y, p.x);',
			'var c = new Point(p.x);',
			'var c = new Point(p.x, p.y, p.x);',
			'var c = new Point(p.x, p.y + 1);',
			'var c = new Point(p.x, 0);',
			'var c = new Point(p.x, p.x);'
		]) Assert.equals(0, violations(holder(statement)).length, statement);
	}

	/** Two values are two reads of two receivers: the one copy would take both fields from one of them. */
	@:pin('control')
	@:killer('M-COPYM-ANY-RECEIVER')
	public function testDifferentReceiversAreSilent(): Void {
		Assert.equals(0, violations(holder('var c = new Point(a.x, b.y);')).length);
	}

	/** `new Point(s.x, s.y)` converts a position; only a value of exactly the configured type is copied. */
	@:pin('control')
	@:killer('M-COPYM-ANY-TYPE')
	public function testReceiverOfAnotherTypeIsSilent(): Void {
		for (statement in [
			'var c = new Point(s.x, s.y);',
			'var c = new Point(d.x, d.y);',
			'var c = new Point(q.x, q.y);',
			'var c = new Point(n.x, n.y);'
		]) Assert.equals(0, violations(holder(statement)).length, statement);
	}

	/** The constructor must name the configured type itself: another type built from the same fields is no copy of it. */
	@:pin('control')
	@:killer('M-COPYM-NAMES-PAIR')
	public function testConstructionOfAnotherTypeIsSilent(): Void {
		Assert.equals(0, violations(holder('var c = new Sprite(p.x, p.y);')).length);
	}

	/** The receiver and every field are read once on the left and not at all on the right: a call or a getter would be dropped. */
	@:pin('control')
	@:killer('M-COPYM-IMPURE')
	public function testImpureReadIsSilent(): Void {
		for (statement in ['var c = new Point(g().x, g().y);', 'var c = new Lazy(l.x, l.y);'])
			Assert.equals(0, violations(holder(statement)).length, statement);
	}

	/** A subtype's `clone` yields the subtype while `new T` yields exactly `T`. */
	@:pin('control')
	@:killer('M-COPYM-OVERRIDE')
	public function testOverriddenCopyMethodIsSilent(): Void {
		Assert.equals(0, violations(holder('var c = new Rigid(r.x, r.y);')).length);
	}

	/** Inside the copy method of that name the rewrite would call itself. */
	@:pin('control')
	@:killer('M-COPYM-SELF-CALL')
	public function testInsideTheCopyMethodIsSilent(): Void {
		Assert.equals(0, violations(holder('var c = 1;'), 'lib/Selfish.hx').length);
	}

	@:pin('control')
	@:killer('M-COPYM-COMMENT')
	public function testCommentInTheCopyIsSilent(): Void {
		Assert.equals(0, violations(holder('var c = new Point(p.x, /* y */ p.y);')).length);
	}

	/** A type the index cannot place, or a copy method that is not one public instance method, stops the rule on the file. */
	@:pin('control')
	@:killer('M-COPYM-ANY-COPY')
	public function testUnusableConfigurationIsAnError(): Void {
		final src: String = holder('var c = new Point(p.x, p.y);');
		for (types => reason in [
			'{"lib.Gone":{"fields":["x"],"copy":"clone"}}' => 'names no type',
			'{"lib.Twin":{"fields":["x"],"copy":"clone"}}' => 'ambiguous',
			'{"lib.Secret":{"fields":["x"],"copy":"clone"}}' => 'private type',
			'{"lib.Params":{"fields":["x"],"copy":"clone"}}' => 'has no one public instance method clone()',
			'{"lib.Static":{"fields":["x"],"copy":"clone"}}' => 'has no one public instance method clone()',
			'{"lib.Foreign":{"fields":["x"],"copy":"clone"}}' => 'has no one public instance method clone()',
			'{"lib.Point":{"fields":["x"],"copy":"duplicate"}}' => 'has no one public instance method duplicate()',
			'{"lib.Point":{"fields":[],"copy":"clone"}}' => 'needs fields',
			'{"lib.Point":{"fields":["x"]}}' => 'needs fields',
			'{"lib.Point":{"fields":["x"],"copy":"clone","extra":1}}' => '"extra" is not',
			'{"lib.Point":3}' => 'is not an object',
			'3' => 'is not an object'
		]) {
			final json: String = '{"rules":{"prefer-copy-method":{"enabled":true,"types":$types}}}';
			final all: Array<Violation> = CheckFixture.violationsIn(new PreferCopyMethod(), files(src), null, _ -> LintConfig.parse(json));
			Assert.isTrue(all.length > 0, types);
			for (v in all) {
				Assert.equals(Severity.Error, v.severity, types);
				Assert.isNull(v.span, types);
			}
			Assert.isTrue(all.filter(v -> v.message.indexOf(reason) >= 0).length > 0, '$types: ${all.map(v -> v.message)}');
		}
	}

	public function testInertWithoutAnOption(): Void {
		final json: String = '{"rules":{"prefer-copy-method":{"enabled":true}}}';
		Assert.equals(
			0,
			CheckFixture.violationsIn(
				new PreferCopyMethod(), files(holder('var c = new Point(p.x, p.y);')), null, _ -> LintConfig.parse(json)
			)
				.length
		);
	}

	public function testRegisteredDefaultOff(): Void {
		Assert.notNull(Linter.byId('prefer-copy-method'));
		Assert.isTrue(Std.isOfType(new PreferCopyMethod(), DefaultOff));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** The rule reads the project's `types` and no other option, through the resolver the linter hands it. */
	public function testReadsOnlyTheTypesOption(): Void {
		final rule: PreferCopyMethod = new PreferCopyMethod();
		Assert.same(['types'], rule.acceptedOptions());
		rule.setConfigResolver(_ -> LintConfig.parse(CONFIG));
		final found: Array<Violation> = CheckFixture.violationsIn(
			rule, files(holder('var c = new Point(p.x, p.y);')), null, _ -> LintConfig.parse(CONFIG)
		);
		Assert.equals(1, found.filter(v -> v.file == 'C.hx').length);
	}

	private function holder(statement: String): String {
		return 'import lib.Point;\nimport lib.Point3;\nimport lib.Rigid;\nimport lib.Sealed;\nimport lib.Lazy;\nimport lib.Sprite;\n'
			+ 'import lib.Holder;\n\nclass C {\n\n\tfunction f(p:Point, a:Point, b:Point, q:Point3, r:Rigid, e:Sealed, l:Lazy, s:Sprite, '
			+ 'h:Holder, d:Dynamic, n:Null<Point>):Void {\n\t\t$statement\n\t}\n\n\tfunction g():Point return null;\n}';
	}

	private function files(source: String, ?extra: Array<{ file: String, source: String }>): Array<{ file: String, source: String }> {
		return (extra ?? []).concat([
			{ file: 'C.hx', source: source },
			{
				file: 'lib/Point.hx',
				source: 'package lib;\nclass Point {\n\tpublic var x:Int;\n\tpublic var y:Int;\n\tpublic function new(x:Int, y:Int) {}\n'
				+ '\tpublic function clone():Point return new Point(x, y);\n}'
			},
			{ file: 'lib/Point3.hx', source: 'package lib;\nclass Point3 extends Point {\n\tpublic var z:Int;\n}' },
			{
				file: 'lib/Rigid.hx',
				source: 'package lib;\nclass Rigid {\n\tpublic var x:Int;\n\tpublic var y:Int;\n\tpublic function new(x:Int, y:Int) {}\n'
				+ '\tpublic function clone():Rigid return new Rigid(x, y);\n}'
			},
			{
				file: 'lib/Soft.hx',
				source: 'package lib;\nclass Soft extends Rigid {\n\toverride public function clone():Rigid return new Soft(x, y);\n}'
			},
			{
				file: 'lib/Sealed.hx',
				source: 'package lib;\nfinal class Sealed {\n\tpublic var x:Int;\n\tpublic var y:Int;\n'
				+ '\tpublic function new(x:Int, y:Int) {}\n\tpublic function clone():Sealed return new Sealed(x, y);\n}'
			},
			{
				file: 'lib/Lazy.hx',
				source: 'package lib;\nclass Lazy {\n\tpublic var x(get, never):Int;\n\tpublic var y:Int;\n\tpublic function new(y:Int) '
				+ '{}\n\tfunction get_x():Int return 1;\n\tpublic function clone():Lazy return new Lazy(y);\n}'
			},
			{
				file: 'lib/Selfish.hx',
				source: 'package lib;\nclass Selfish {\n\tpublic var x:Int;\n\tpublic var y:Int;\n\tpublic function new(x:Int, y:Int) {}\n'
				+ '\tpublic function clone():Selfish return new Selfish(this.x, this.y);\n}'
			},
			{
				file: 'lib/Sprite.hx',
				source: 'package lib;\nclass Sprite {\n\tpublic var x:Int;\n\tpublic var y:Int;\n\tpublic function new(x:Int, y:Int) {}\n}'
			},
			{ file: 'lib/Holder.hx', source: 'package lib;\nclass Holder {\n\tpublic var p:Point;\n}' },
			{ file: 'lib/Params.hx', source: 'package lib;\nclass Params {\n\tpublic function clone(deep:Bool):Params return this;\n}' },
			{ file: 'lib/Static.hx', source: 'package lib;\nclass Static {\n\tpublic static function clone():Static return null;\n}' },
			{ file: 'lib/Foreign.hx', source: 'package lib;\nclass Foreign {\n\tpublic function clone():Int return 1;\n}' },
			{ file: 'lib/Secret.hx', source: 'package lib;\nprivate class Secret {\n\tpublic function clone():Secret return this;\n}' },
			{ file: 'lib/Twin.hx', source: 'package lib;\nclass Twin {\n\tpublic static var one:Int = 1;\n}' },
			{ file: 'lib/other/Twin.hx', source: 'package lib;\nclass Twin {\n\tpublic static var two:Int = 2;\n}' }
		]);
	}

	private function violations(source: String, file: String = 'C.hx', ?extra: Array<{ file: String, source: String }>): Array<Violation> {
		return CheckFixture.violationsIn(new PreferCopyMethod(), files(source, extra), null, _ -> LintConfig.parse(CONFIG))
			.filter(v -> v.file == file);
	}

	private function fixed(source: String, ?extra: Array<{ file: String, source: String }>): String {
		return CanonicalEdit.applyEdits(
			source, CheckFixture.fixRun(new PreferCopyMethod(), files(source, extra), 'C.hx', null, _ -> LintConfig.parse(CONFIG)).edits
		);
	}

}

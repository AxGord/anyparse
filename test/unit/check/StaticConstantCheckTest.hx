package unit.check;

import anyparse.check.Check;
import anyparse.check.InlineConstant;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.StaticConstant;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import utest.Assert;
import utest.Test;

/**
 * The `static-constant` check: an instance `final` initialized to a compile-time literal is one
 * value stored once per instance, and `static final` says it once.
 *
 * The fixtures pin the two halves the rule lives or dies by. The INITIALIZER gate is a positive
 * criterion, so the refusals below are not a blacklist being spot-checked — an array literal, a
 * constructor call and a call inside string INTERPOLATION each fail the same proof, and the
 * interpolation case is the one no type-based reading catches. The REACHABILITY gates cover the
 * measured Haxe semantics: a subtype's unqualified read of a private static does not resolve, and
 * `this.NAME` / `obj.NAME` do not compile against one.
 */
class StaticConstantCheckTest extends Test {

	@:pin('control') @:killer('M-BUILDMACRO-TRUE')
	public function testScalarInstanceFinalFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C {\n\tprivate final _minScale:Float = 0.5;\n\tfunction f():Float return _minScale;\n}');
		Assert.equals(1, vs.length);
		Assert.equals('static-constant', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('_minScale') >= 0);
	}

	/** The fix inserts `static` before `final`, leaving the visibility keyword in front of it. */
	public function testFixInsertsStaticKeyword(): Void {
		Assert.equals(
			'class C {\n\tprivate static final _minScale:Float = 0.5;\n\tfunction f():Float return _minScale;\n}',
			applyFix('class C {\n\tprivate final _minScale:Float = 0.5;\n\tfunction f():Float return _minScale;\n}')
		);
	}

	/**
	 * THE catastrophe the naive "never reassigned" gate lets through. `_lists` is never reassigned —
	 * every occurrence classifies as a READ — because the mutation goes through `push`; promoting it
	 * would share one list across every instance.
	 */
	public function testMutatedArrayInitializerRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tprivate final _lists:Array<Int> = [];\n\tfunction f():Void {\n\t\t_lists.push(1);\n\t\t_lists.pop();\n\t}\n}'
			).length
		);
	}

	/** Same proof, no mutation in sight: an object initializer is per-instance identity whatever the body does with it. */
	public function testConstructorCallInitializerRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate final _bg:Sprite = new Sprite();\n\tfunction f():Sprite return _bg;\n}').length);
	}

	/**
	 * THE trap inside the literal criterion, visible only in the initializer TEXT: a CALL inside
	 * string interpolation makes the value differ per instance exactly as a call in value position
	 * does, and sharing one would collapse every instance's identity onto the first.
	 */
	public function testInterpolatedStringInitializerRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tprivate final _closeAction:String = \'$${UUID.uuid()}: close\';\n'
				+ '\tfunction f():String return _closeAction;\n}'
			).length
		);
	}

	/** The `$name` form of the same hazard — a bare interpolation is not a plain literal either. */
	public function testSimpleInterpolationRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate final _k:String = \'a$${sep}b\';\n\tfunction f():String return _k;\n}').length);
	}

	public function testPlainSingleQuotedStringFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tprivate final _k:String = \'close\';\n\tfunction f():String return _k;\n}').length);
	}

	public function testNegatedNumberFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tprivate final _dx:Float = -1.5;\n\tfunction f():Float return _dx;\n}').length);
	}

	public function testBoolFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tprivate final _allowMove:Bool = true;\n\tfunction f():Bool return _allowMove;\n}').length
		);
	}

	/**
	 * THE hole a green unit suite could not see and a real-tree typecheck did: an INSTANCE `final`
	 * with a declaration initializer is still writable in the CONSTRUCTOR, so the literal is a
	 * DEFAULT and not the value. Measured — the two constructions print 5 and 9 — while the `static`
	 * form rejects the same write with `This expression cannot be accessed for writing`.
	 */
	public function testConstructorReassignedFinalRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tprivate final _n:Int = 5;\n\tpublic function new(f:Bool) {\n\t\tif (f) _n = 9;\n\t}\n}').length
		);
	}

	/** The same shape with the constructor write removed — the one-variable twin that proves the gate above is what refuses. */
	public function testUnwrittenFinalWithConstructorFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tprivate final _n:Int = 5;\n\tpublic function new(f:Bool) {\n\t\tif (f) g();\n\t}\n}').length
		);
	}

	/** A `var` is shared MUTABLE state once static — only `final` qualifies. */
	public function testMutableFieldRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate var _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	public function testAlreadyStaticRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate static final _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	/** A public field's readers are every file in the project; rewriting them is the cross-file edit `fix` cannot make. */
	public function testPublicFieldRefused(): Void {
		Assert.equals(0, violations('class C {\n\tpublic final n:Int = 5;\n\tfunction f():Int return n;\n}').length);
	}

	/** `this.NAME` is `Cannot access static field NAME from a class instance` — measured. */
	public function testThisQualifiedReadRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return this._n;\n}').length);
	}

	/** So is `obj.NAME`, reachable for a private member on a same-type instance. */
	public function testInstanceQualifiedReadRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate final _n:Int = 5;\n\tfunction f(o:C):Int return o._n;\n}').length);
	}

	/** A subtype's UNQUALIFIED read of a private static is `Unknown identifier` — measured; the fix would have to reach the subtype's file. */
	public function testSubtypeReadRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class Base {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}',
				'class Sub extends Base {\n\tfunction g():Int return _n;\n}'
			).length
		);
	}

	/** The gate is a MENTION, not the mere existence of a subtype — a subtype that never names the field leaves it promotable. */
	public function testSubtypeNotMentioningFieldFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class Base {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}',
				'class Sub extends Base {\n\tfunction g():Int return 1;\n}'
			).length
		);
	}

	/** `Reflect.field(instance, "_n")` returns the value for an instance field and null for a static one — measured. */
	public function testReflectedNameRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}',
				'class R {\n\tfunction g(o:Dynamic):Dynamic return Reflect.field(o, \'_n\');\n}'
			).length
		);
	}

	/**
	 * The same gate for a COMPUTED key. `literalOf` answers null for an interpolated literal, so a
	 * scan over plain literals alone reads `'${p}_counter'` as no mention of `_counter` — and the
	 * promotion then moves off the instance a field `Reflect.field` still reads there.
	 */
	public function testInterpolatedReflectedNameRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tprivate final _counter:Int = 5;\n\tfunction f():Int return _counter;\n}',
				'class R {\n\tfunction g(o:Dynamic, p:String):Dynamic return Reflect.field(o, \'$${p}_counter\');\n}'
			).length
		);
	}

	/** The discriminating half: a fragment no member name contains leaves the promotion alone. */
	public function testInterpolatedFragmentNamingSomethingElseStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tprivate final _counter:Int = 5;\n\tfunction f():Int return _counter;\n}',
				'class R {\n\tfunction g(o:Dynamic, p:String):Dynamic return Reflect.field(o, \'$${p}_other\');\n}'
			).length
		);
	}

	public function testKeepMetaRefused(): Void {
		Assert.equals(0, violations('class C {\n\t@:keep private final _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	public function testRttiClassRefused(): Void {
		Assert.equals(0, violations('@:rtti\nclass C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	/** An initialized `final` under `@:structInit` is an OPTIONAL CONSTRUCTOR ARGUMENT — promoting it deletes a name every `{ … }` literal may pass. */
	public function testStructInitClassRefused(): Void {
		Assert.equals(0, violations('@:structInit\nclass C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	/** A build macro can inject a `this.NAME` read no text scan can see. */
	public function testBuildMacroFileRefused(): Void {
		Assert.equals(0, violations('@:build(M.b())\nclass C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	/** An `enum abstract` value is not an instance field; the crude "scalar final" census reads it as one. */
	public function testEnumAbstractValueRefused(): Void {
		Assert.equals(0, violations('enum abstract E(Int) {\n\tfinal A = 1;\n\tfinal B = 2;\n}').length);
	}

	public function testNoInitializerRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate final _n:Int;\n\tpublic function new() _n = 5;\n}').length);
	}

	/** Deliberately out of scope: a reference that folds at compile time is sound but has no measured yield (see the class doc). */
	public function testConstantReferenceInitializerRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tprivate static inline final K:Int = 5;\n\tprivate final _n:Int = K;\n\tfunction f():Int return _n;\n}')
				.length
		);
	}

	public function testCallInitializerRefused(): Void {
		Assert.equals(0, violations('class C {\n\tprivate final _n:Int = seed();\n\tfunction f():Int return _n;\n}').length);
	}

	/** An `@:allow` in the file hands the privates to a type no bounded scan can enumerate. */
	public function testAllowGrantRefused(): Void {
		Assert.equals(0, violations('@:allow(D)\nclass C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}').length);
	}

	/**
	 * …but only a REAL one. The gate was `source.indexOf('@:allow') >= 0`, so a file merely TALKING
	 * about the tag — its own doc comment, a fixture literal — silently lost every finding this rule
	 * and five others would have made. Measured on anyparse itself: 22 of its 1501 files tripped the
	 * raw scan and `apq meta '@:allow' src test` finds ZERO real grants, so every one of them was this.
	 *
	 * The arms have to be a PAIR: the negative one alone stays green under the raw scan, which is
	 * exactly how the defect survived. String and comment are separate arms because the masking runs
	 * over the whole lexical region set, comments and literals alike — a comment-only fixture would
	 * leave the literal half unpinned.
	 */
	public function testAPhantomAllowInACommentOrALiteralIsNotAGrant(): Void {
		Assert.equals(
			1,
			violations('// One day, consider @:allow(D) here.\nclass C {\n\tprivate final _n:Int = 5;\n\tfunction f():Int return _n;\n}')
				.length,
			'a comment mentioning the tag is not metadata'
		);
		Assert.equals(
			1, violations("class C {\n\tprivate final _n:Int = 5;\n\tfunction f():String return '@:allow(D) $_n';\n}").length,
			'nor is a string literal spelling it'
		);
	}

	/**
	 * The composition the rule is designed for: `static-constant` promotes the field, and
	 * `inline-constant` — whose input is exactly this rule's output — then makes it inline. Asserted
	 * on one string so neither half can satisfy it alone.
	 */
	public function testComposesWithInlineConstant(): Void {
		final promoted: String = applyFix('class C {\n\tprivate final _minScale:Float = 0.5;\n\tfunction f():Float return _minScale;\n}');
		final check: InlineConstant = new InlineConstant();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: promoted }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(
			'class C {\n\tprivate static inline final _minScale:Float = 0.5;\n\tfunction f():Float return _minScale;\n}',
			CanonicalEdit.applyEdits(promoted, check.fix(promoted, check.run(files, plugin), plugin))
		);
	}

	public function testRegisteredAsDefaultOffBuiltin(): Void {
		final check: Null<Check> = Linter.byId('static-constant');
		Assert.notNull(check);
		Assert.isTrue(check is DefaultOff);
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('static-constant'));
	}

	private function violations(src: String, ?other: String): Array<Violation> {
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		if (other != null) files.push({ file: 'Other.hx', source: other });
		return new StaticConstant().run(files, new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: StaticConstant = new StaticConstant();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CanonicalEdit.applyEdits(src, check.fix(src, check.run(files, plugin), plugin));
	}

}

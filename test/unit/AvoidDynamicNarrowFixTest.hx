package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.AvoidDynamic;
import anyparse.check.Check.Violation;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `avoid-dynamic` usage-inference autofix (D3). It narrows a WHOLE-type
 * `Dynamic` LOCAL to the single named type every write source (initializer
 * included) provably carries, corroborated by an exact-type sink or typed
 * reassignment, with the type resolving to a provably plain nominal (class /
 * interface / enum — not an abstract or typedef). Every other shape skips:
 * member access, `is`, cast, operator, `?.` / `!.` / index, null flows,
 * heterogeneous / untyped writes or sinks, call-argument / return / ternary
 * seams (the abstract-`@:from` hole), unresolvable types, and every non-Local
 * violation position. The two adversarial-review repros (abstract `@:to`
 * dispatch change; struct-field mis-attribution) are pinned as tests.
 */
class AvoidDynamicNarrowFixTest extends Test {

	/** In-file decl making `Foo` a provably plain nominal for the index gate. */
	private static final FOO: String = '\nclass Foo {}';

	private static final FOO_BAR: String = '\nclass Foo {}\nclass Bar {}';

	// ---- FIRES: sound narrowings ----

	public function testTypedSinkPassThrough(): Void {
		Assert.equals('Foo', narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t}\n}$FOO'));
	}

	public function testAssignSinkPassThrough(): Void {
		// `b = x` where b is a Foo parameter: the assignment sink corroborates the type.
		Assert.equals('Foo', narrow('class C {\n\tfunction f(a:Foo, b:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tb = x;\n\t}\n}$FOO'));
	}

	public function testTypedReassignNarrows(): Void {
		// Init AND reassignment both typed Foo: the value provably always holds a Foo.
		Assert.equals(
			'Foo',
			narrow('class C {\n\tfunction f(a:Foo, b:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tx = b;\n\t\tvar y:Foo = x;\n\t}\n}$FOO')
		);
	}

	public function testFinalLocalNarrows(): Void {
		Assert.equals('Foo', narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tfinal x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t}\n}$FOO'));
	}

	public function testNewInitNarrows(): Void {
		Assert.equals('Foo', narrow('class C {\n\tfunction f():Void {\n\t\tvar x:Dynamic = new Foo();\n\t\tvar y:Foo = x;\n\t}\n}$FOO'));
	}

	// ---- SKIPS: dynamic-signal uses ----

	public function testMemberAccessSkipped(): Void {
		// `x.bar()` — instance member vs using-extension vs getter is undecidable here → skip.
		Assert.isNull(
			narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tx.bar();\n\t\tvar y:Foo = x;\n\t}\n}$FOO')
		);
	}

	public function testUsingExtensionMemberSkipped(): Void {
		// `x.trim()` under `using StringTools` is a String-obligation, NOT a "any type with trim" — skip.
		Assert.isNull(
			narrow(
				'using StringTools;\nclass C {\n\tfunction f(s:String):Void {\n\t\tvar x:Dynamic = s;\n\t\tx.trim();\n\t\tvar y:String = x;\n\t}\n}'
			)
		);
	}

	public function testIsCheckSkipped(): Void {
		Assert.isNull(
			narrow(
				'class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tif (x is Foo) return;\n\t\tvar y:Foo = x;\n\t}\n}$FOO'
			)
		);
	}

	public function testOperatorSkipped(): Void {
		Assert.isNull(narrow('class C {\n\tfunction f(a:Int):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Int = x + a;\n\t}\n}'));
	}

	public function testNullComparisonSkipped(): Void {
		Assert.isNull(
			narrow(
				'class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tif (x == null) return;\n\t\tvar y:Foo = x;\n\t}\n}$FOO'
			)
		);
	}

	public function testNullAssignmentSkipped(): Void {
		Assert.isNull(
			narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tx = null;\n\t\tvar y:Foo = x;\n\t}\n}$FOO')
		);
	}

	public function testCastSkipped(): Void {
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y = cast(x, Foo);\n\t}\n}$FOO'));
	}

	public function testSafeNavSkipped(): Void {
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y = x?.bar;\n\t}\n}$FOO'));
	}

	public function testIndexAccessSkipped(): Void {
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y = x[0];\n\t}\n}$FOO'));
	}

	// ---- SKIPS: typed seams of unknown expected type (the abstract-@:from hole) ----

	public function testCallArgSkipped(): Void {
		// A call argument hands the value to a parameter whose type may be an abstract with
		// an implicit @:from — Dynamic passes raw, a narrowed type converts. Skip.
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tg(x);\n\t\tvar y:Foo = x;\n\t}\n}$FOO'));
	}

	public function testStdStringArgSkipped(): Void {
		Assert.isNull(
			narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tStd.string(x);\n\t\tvar y:Foo = x;\n\t}\n}$FOO')
		);
	}

	public function testReturnUseSkipped(): Void {
		Assert.isNull(
			narrow('class C {\n\tfunction f(a:Foo):Dynamic {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t\treturn x;\n\t}\n}$FOO')
		);
	}

	public function testTernaryBranchSkipped(): Void {
		Assert.isNull(
			narrow(
				'class C {\n\tfunction f(a:Foo, c:Bool):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t\tvar r = c ? x : a;\n\t}\n}$FOO'
			)
		);
	}

	public function testUntypedSinkSkipped(): Void {
		// `var y = x` — the target's inferred type would silently change from Dynamic to T. Skip.
		Assert.isNull(
			narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y = x;\n\t\tvar z:Foo = x;\n\t}\n}$FOO')
		);
	}

	// ---- SKIPS: write-source / type-resolution gates ----

	public function testUntypedInitSkipped(): Void {
		// The initializer is an untyped call — the value is NOT provably one type, even with a typed sink.
		Assert.isNull(narrow('class C {\n\tfunction f():Void {\n\t\tvar x:Dynamic = g();\n\t\tvar y:Foo = x;\n\t}\n}$FOO'));
	}

	public function testBoundaryLocalSkipped(): Void {
		// A Reflect boundary local: init untyped → not provably one type → skip (genuine dynamic value).
		Assert.isNull(
			narrow('class C {\n\tfunction f(o:Foo):Void {\n\t\tvar x:Dynamic = Reflect.field(o, \'k\');\n\t\tvar y:Foo = x;\n\t}\n}$FOO')
		);
	}

	public function testStdIsOfTypeGuardSkipped(): Void {
		// The dogfood FP: `Std.isOfType(raw, Array)` guards a genuinely heterogeneous value. Skip.
		Assert.isNull(
			narrow(
				'class C {\n\tfunction f(o:Foo):Void {\n\t\tvar raw:Dynamic = Reflect.field(o, \'k\');\n\t\tif (Std.isOfType(raw, Array)) {\n\t\t\tvar arr:Array<Dynamic> = raw;\n\t\t}\n\t}\n}$FOO'
			)
		);
	}

	public function testHeterogeneousSinksSkipped(): Void {
		Assert.isNull(
			narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t\tvar z:Bar = x;\n\t}\n}$FOO_BAR')
		);
	}

	public function testInitializerOnlyNoUseSkipped(): Void {
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t}\n}$FOO'));
	}

	public function testNoInitializerSkipped(): Void {
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic;\n\t\tx = a;\n\t\tvar y:Foo = x;\n\t}\n}$FOO'));
	}

	public function testUnresolvedTypeSkipped(): Void {
		// `Foo` is not declared in the file set — not provably a plain nominal → skip.
		Assert.isNull(narrow('class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t}\n}'));
	}

	public function testAbstractTypeSkipped(): Void {
		// Reviewer repro: an abstract's @:to fires on the STATIC type — narrowing to it
		// compiles but changes runtime dispatch. The plain-nominal gate refuses abstracts.
		Assert.isNull(
			narrow(
				'class C {\n\tfunction f(a:Money):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Money = x;\n\t}\n}'
				+ '\nabstract Money(Int) from Int {}'
			)
		);
	}

	public function testTypedefTypeSkipped(): Void {
		// A typedef may alias an abstract or Dynamic — not provably plain → skip.
		Assert.isNull(
			narrow(
				'class C {\n\tfunction f(a:Alias):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Alias = x;\n\t}\n}'
				+ '\ntypedef Alias = Dynamic;'
			)
		);
	}

	// ---- Positions the local fix never touches ----

	public function testTypeArgumentNotEdited(): Void {
		Assert.equals(0, edits('class C {\n\tfunction f():Void {\n\t\tvar m:Map<String, Dynamic> = g();\n\t}\n}').length);
	}

	public function testFieldNotEdited(): Void {
		Assert.equals(0, edits('class C {\n\tvar f:Dynamic;\n}').length);
	}

	public function testParameterNotEdited(): Void {
		Assert.equals(0, edits('class C {\n\tfunction f(p:Dynamic):Void {}\n}').length);
	}

	public function testReturnNotEdited(): Void {
		Assert.equals(0, edits('class C {\n\tfunction f():Dynamic { return null; }\n}').length);
	}

	public function testStructFieldInLocalAnnotationNotEdited(): Void {
		// Reviewer repro: a class-notation struct FIELD inside a local's anon-type annotation
		// passes the char test (`:` before, `;` after) but is a Field-position violation the
		// local's inference must never rewrite — the child-containment gate rejects it.
		final src: String = 'class C {\n\tfunction f(a:Foo):Void {\n\t\tvar o:{ var x:Dynamic; var k:Int; } = a;\n\t\to = a;\n\t}\n}$FOO';
		Assert.equals(0, edits(src).length);
	}

	// ---- Applied-edit integrity ----

	public function testAppliedEditReplacesTokenOnly(): Void {
		final src: String = 'class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t}\n}$FOO';
		final out: String = apply(src, edits(src));
		Assert.isTrue(out.indexOf('var x:Foo = a;') != -1, 'the Dynamic token is replaced by the inferred type');
		Assert.isTrue(out.indexOf('Dynamic') == -1, 'no Dynamic remains');
	}

	public function testIdempotent(): Void {
		final src: String = 'class C {\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t}\n}$FOO';
		final out: String = apply(src, edits(src));
		// Re-running produces no further local-Dynamic edit (nothing left to narrow).
		Assert.equals(0, edits(out).length);
	}

	public function testMixedViolationsEditsOnlyLocal(): Void {
		// A file with a field Dynamic AND a narrowable local: only the local is edited.
		final src: String = 'class C {\n\tvar keep:Dynamic;\n\tfunction f(a:Foo):Void {\n\t\tvar x:Dynamic = a;\n\t\tvar y:Foo = x;\n\t}\n}$FOO';
		final e: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, e.length);
		final out: String = apply(src, e);
		Assert.isTrue(out.indexOf('var keep:Dynamic;') != -1, 'the field Dynamic is untouched');
		Assert.isTrue(out.indexOf('var x:Foo = a;') != -1, 'the local is narrowed');
	}

	// ---- helpers ----

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: AvoidDynamic = new AvoidDynamic();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return check.fix(src, vs, plugin);
	}

	private function narrow(src: String): Null<String> {
		final e: Array<{ span: Span, text: String }> = edits(src);
		return e.length == 0 ? null : e[0].text;
	}

	private function apply(src: String, e: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = e.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (ed in sorted) out = out.substring(0, ed.span.from) + ed.text + out.substring(ed.span.to);
		return out;
	}

}

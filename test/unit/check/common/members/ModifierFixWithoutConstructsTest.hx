package unit.check.common.members;

import anyparse.check.Check;
import anyparse.check.common.expressions.PreferFinal;
import anyparse.check.common.members.InlineConstant;
import anyparse.check.common.members.PreferInline;
import anyparse.check.common.members.StaticConstant;
import anyparse.check.common.members.TrivialGetter;
import anyparse.query.CtorFieldFold;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * The fixes that put a modifier on a declaration or turn `var` into `final` ask the grammar's `Constructs` for the edit; a
 * grammar that builds none, or refuses the modifier, gets no edit from them instead of text the rule spelled itself.
 */
@:nullSafety(Strict)
class ModifierFixWithoutConstructsTest extends Test {

	private static final CASES: Array<{ name: String, rule: Check, source: String }> = [
		{ name: 'inline-constant', rule: new InlineConstant(), source: 'class C { static final A:Int = 5; }' },
		{ name: 'prefer-inline', rule: new PreferInline(), source: 'class C { function get_date():String return _field.text; }' },
		{
			name: 'static-constant',
			rule: new StaticConstant(),
			source: 'class C {\n\tprivate final _min:Float = 0.5;\n\tfunction f():Float return _min;\n}'
		},
		{
			name: 'trivial-getter',
			rule: new TrivialGetter(),
			source: 'class C {\n\tpublic var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n'
				+ '\tfunction f():Void { if ((_active = true)) trace(1); }\n}'
		},
		{ name: 'prefer-final', rule: new PreferFinal(), source: 'class C { function f():Void { var x = 0; trace(x); } }' }
	];

	/** Under the real grammar each rule's fix writes an edit; under a grammar with no constructs, or one that refuses modifiers, none. */
	@:pin('control')
	@:killer('M-INLINE-CONSTANT-FIX-SPELLED')
	@:killer('M-PREFER-INLINE-FIX-SPELLED')
	@:killer('M-STATIC-CONSTANT-FIX-SPELLED')
	@:killer('M-TRIVIAL-GETTER-INLINE-FIX-SPELLED')
	@:killer('M-PREFER-FINAL-FIX-SPELLED')
	public function testAFixWritesNothingWhereTheGrammarBuildsNoModifier(): Void {
		for (entry in CASES) {
			final found: Array<Violation> = CheckFixture.violations(entry.rule, entry.source);
			final id: String = entry.name;
			Assert.equals(1, found.length, '$id flags its fixture');
			Assert.isTrue(CheckFixture.fixOf(entry.rule, entry.source, found).length > 0, '$id fixes its fixture');
			for (plugin in refusing()) Assert.equals(0, CheckFixture.fixOf(entry.rule, entry.source, found, plugin).length, id);
		}
	}

	/** The keyword swap `CtorFieldFold` shares between the final-field rules is an edit only where the grammar builds it. */
	@:pin('control')
	@:killer('M-CTOR-FIELD-FOLD-KEYWORD-SPELLED')
	public function testTheKeywordSwapNeedsTheGrammar(): Void {
		final source: String = 'class C { var x = 1; }';
		final spans: Array<Null<Span>> = [new Span(source.indexOf('var'), source.length - 2)];
		Assert.equals(1, CtorFieldFold.varKeywordToFinalEdits(source, spans, new HaxeQueryPlugin()).length);
		for (plugin in refusing()) Assert.equals(0, CtorFieldFold.varKeywordToFinalEdits(source, spans, plugin).length);
	}

	private static function refusing(): Array<GrammarPlugin> {
		return [
			new RefusingConstructsPlugin(_ -> null),
			new RefusingConstructsPlugin(c -> new RefusingConstructs(c, [], [], true))
		];
	}

}

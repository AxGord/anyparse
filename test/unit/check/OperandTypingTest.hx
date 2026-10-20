package unit.check;

import anyparse.check.Check;
import anyparse.check.DoubleNegation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.JoinStringAppend;
import anyparse.check.PreferIfExpressionChain;
import anyparse.check.PreferSwitch;
import anyparse.check.PreferSwitchExpression;
import anyparse.check.PreferTernaryAssignment;
import anyparse.check.PreferTernaryExpression;
import anyparse.check.PreferTernaryReturn;
import anyparse.check.ReturnReassignTernary;
import anyparse.check.SimplifyNegatedCompound;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import unit.CheckFixture;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * ONE operand typing answers every rule that asks whether an operator is the language's own (`OperatorSelection`).
 * The same operand, reached by each arc the shared walk types (`TypingService.typeWalk` over `OperandBinder`) — a written
 * annotation, an unannotated local's initializer, the self reference, an inherited member read bare, a static
 * extension's result, an abstract's `@:op(a.b)` field — must get the SAME answer from every negation form (an `if`
 * statement, a value `if`, a ternary, the four ternary builders and `!!`), from the `==` users (`!(a == b)`, the switch
 * rules, the chain rule that defers to them) and from the `+` users (the fold, the append join): accepted when the type
 * it reaches is a built-in, refused when it is the overloading abstract, refused (the fold: reported without a fix)
 * when nothing types it (a receiver of a type the index does not hold).
 *
 * The refusal tests below pin each arc's fail-closed edge with an operand whose typing the compiler resolves
 * differently from the obvious reading; each was compiled and run on Haxe 4.3.7 `--interp`.
 */
class OperandTypingTest extends Test {

	/** Every typing route an operand is reached by, in the order the matrix walks them. */
	private static final ROUTES: Array<String> = ['Annotated', 'Local', 'Self', 'Inherited', 'Extension', 'Resolve', 'Unread'];

	/** The overloading abstracts: `!` on `Flag`, `==` on `Num`, `+` and `+=` on `Dir`. */
	private static final DECLS: Array<{ file: String, source: String }> = [
		{
			file: 'Flag.hx',
			source: 'abstract Flag(Bool) from Bool to Bool {\n\t@:op(!A) public inline function inv():Bool\n\t\treturn this;\n}\n'
		},
		{
			file: 'Num.hx',
			source: 'abstract Num(Int) from Int to Int {\n\t@:op(A == B) public inline function eq(b:Num):Bool\n'
				+ '\t\treturn this == cast b;\n}\n'
		},
		{
			file: 'Dir.hx',
			source: 'abstract Dir(String) from String to String {\n\t@:op(A + B) public inline function add(a:String):Dir\n\t\treturn cast '
				+ 'this + \'/\' + a;\n\n\t@:op(A += B) public inline function app(a:String):Dir\n\t\treturn cast this + \'/\' + a;\n}\n'
		},
		{ file: 'Str.hx', source: 'class Str {\n\tpublic function new() {}\n}\n' },
		{ file: 'Holder.hx', source: 'class Holder {\n\tpublic function new() {}\n}\n' }
	];

	/** `ext` on a `Str`, answering the built-in `Bool`. */
	private static final TOOLS: { file: String, source: String } = {
		file: 'Tools.hx',
		source: 'class Tools {\n\tpublic static function ext(s:Str):Bool {\n\t\treturn true;\n\t}\n}\n'
	};

	/** `ext` on a `Str`, answering the overloading `Flag`. */
	private static final FLAG_TOOLS: { file: String, source: String } = {
		file: 'FlagTools.hx',
		source: 'class FlagTools {\n\tpublic static function ext(s:Str):Flag {\n\t\treturn true;\n\t}\n}\n'
	};

	/** A supertype declaring `open():Bool`. */
	private static final OPEN: { file: String, source: String } = {
		file: 'Opener.hx',
		source: 'class Opener {\n\tpublic function new() {}\n\n\tpublic function open():Bool {\n\t\treturn true;\n\t}\n}\n'
	};

	/** A class whose `on` is the overloading `Flag`. */
	private static final FLAG_ON: { file: String, source: String } = {
		file: 'FlagOn.hx',
		source: 'class FlagOn {\n\tpublic var on:Flag;\n\n\tpublic function new() {}\n}\n'
	};

	/** The negation family over a `Bool` operand — accepted — and a `Flag` one — refused. */
	@:pin('control')
	@:killer('M-BINDER-INITIALIZER-CUT', 'M-BINDER-SELF-CUT', 'M-BINDER-INHERITED-CUT', 'M-BINDER-EXTENSION-CUT')
	@:killer('M-BINDER-RESOLVE-CUT')
	public function testEveryNegationFormAnswersTheSameOnTheSameOperand(): Void {
		final shapes: Array<Shape> = [
			{ name: 'ins', body: 'if (!@) x++;\n\t\telse x--;\n\t\treturn x;' },
			{ name: 'ternary', body: 'return !@ ? 1 : 2;' },
			{ name: 'value', body: 'var y = if (!@) 1 else 2;\n\t\treturn y;' },
			{ name: 'guard', body: 'if (!@) return 1;\n\t\treturn 2;' },
			{ name: 'reassign', body: 'var r = 1;\n\t\tif (!@) r = 2;\n\t\treturn r;' },
			{ name: 'assign', body: 'if (!@) x = 1;\n\t\telse x = 2;\n\t\treturn x;' },
			{ name: 'double', body: 'final d:Bool = !!@;\n\t\treturn x;' }
		];
		final asks: Array<Ask> = [
			{ check: new InvertNegatedIfElse(), shape: 'ins', read: Reports },
			{ check: new InvertNegatedIfElse(), shape: 'ternary', read: Reports },
			{ check: new InvertNegatedIfElse(), shape: 'value', read: Reports },
			{ check: new PreferTernaryReturn(), shape: 'guard', read: Positive },
			{ check: new ReturnReassignTernary(), shape: 'reassign', read: Positive },
			{ check: new PreferTernaryAssignment(), shape: 'assign', read: Positive },
			{ check: new PreferTernaryExpression(), shape: 'value', read: Positive },
			{ check: new DoubleNegation(), shape: 'double', read: Reports }
		];
		matrix('Bool', 'Flag', shapes, asks, false);
	}

	/** The `==` family over an `Int` operand and a `Num` one, the operand held by an unannotated local. */
	@:pin('control') @:killer('M-BINDER-INITIALIZER-CUT')
	public function testEveryEqualityUserAnswersTheSameOnTheSameOperand(): Void {
		final shapes: Array<Shape> = [
			{ name: 'negated', body: 'final k = @;\n\t\tfinal b:Bool = !(k == 1);\n\t\treturn x;' },
			{ name: 'chain', body: 'final k = @;\n\t\tif (k == 1) x = 1; else if (k == 2) x = 2; else x = 3;\n\t\treturn x;' },
			{ name: 'ternaries', body: 'final k = @;\n\t\treturn k == 1 ? 1 : k == 2 ? 2 : 3;' }
		];
		final asks: Array<Ask> = [
			{ check: new SimplifyNegatedCompound(), shape: 'negated', read: Reports },
			{ check: new PreferSwitch(), shape: 'chain', read: Reports },
			{ check: new PreferSwitchExpression(), shape: 'ternaries', read: Reports },
			{ check: new PreferIfExpressionChain(), shape: 'ternaries', read: Silent }
		];
		matrix('Int', 'Num', shapes, asks, false);
	}

	/** The `+` family over a `String` operand and a `Dir` one: the fold merges, the join fuses the appends. */
	@:pin('control') @:killer('M-BINDER-INITIALIZER-CUT', 'M-BINDER-EXTENSION-CUT', 'M-BINDER-RESOLVE-CUT')
	public function testEveryConcatenationUserAnswersTheSameOnTheSameOperand(): Void {
		final shapes: Array<Shape> = [
			{ name: 'fold', body: 'final s2:String = @ + \'a\' + \'b\';\n\t\treturn x;' },
			{ name: 'join', body: 'var r2 = @;\n\t\tr2 += \'a\';\n\t\tr2 += \'b\';\n\t\treturn x;' }
		];
		final asks: Array<Ask> = [
			{ check: new FoldStringLiterals(), shape: 'fold', read: Fixable },
			{ check: new JoinStringAppend(), shape: 'join', read: Reports }
		];
		matrix('String', 'Dir', shapes, asks, true);
	}

	/**
	 * A supertype's static is not in scope bare: `flag` read in a subclass of `Base` (which declares `static var flag:Bool`)
	 * is the `Flag` that `import Other.flag` names — 4.3.7 picks the import.
	 */
	@:pin('control') @:killer('M-BINDER-INHERITED-STATIC')
	public function testASupertypeStaticReadBareIsNotTheSupertypes(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Base.hx', source: 'class Base {\n\tpublic static var flag:Bool = true;\n\n\tpublic function new() {}\n}\n' },
			{ file: 'Other.hx', source: 'class Other {\n\tpublic static var flag:Flag = true;\n}\n' },
			use('import Other.flag;\n\n', ' extends Base', '!flag')
		];
		Assert.isFalse(inverts(files));
		Assert.isTrue(inverts([OPEN, use('', ' extends Opener', '!open()')]));
	}

	/**
	 * An inherited member is read only up a closure every link of which resolves: past `far.Mid`, which the index does not
	 * hold, a covariant override of `ok` may sit, and it is the declaration the compiler types `ok()` by.
	 */
	@:pin('control') @:killer('M-BINDER-CLOSURE-UNRESOLVED')
	public function testAnInheritedMemberPastAnUnreadSupertypeIsUnproven(): Void {
		final ok: { file: String, source: String } = { file: 'Ok.hx', source: 'interface Ok {\n\tfunction ok():Bool;\n}\n' };
		// written qualified, with no import: an unindexed import would leave every simple name of the file unproven itself
		Assert.isFalse(inverts([ok, use('', ' extends far.Mid implements Ok', '!ok()')]));
		Assert.isTrue(inverts([ok, OPEN, use('', ' extends Opener implements Ok', '!ok()')]));
	}

	/** A receiver type's own `@:using` binds ahead of every `using` of the file (4.3.7): `s.ext()` is `FlagTools.ext`. */
	@:pin('control') @:killer('M-BINDER-EXTENSION-ATUSING')
	public function testTheReceiversOwnUsingOutranksTheFiles(): Void {
		final str: { file: String, source: String } = {
			file: 'Str.hx',
			source: '@:using(FlagTools)\nclass Str {\n\tpublic function new() {}\n}\n'
		};
		Assert.isFalse(inverts([str, TOOLS, FLAG_TOOLS, use('using Tools;\n\n', '', '!s.ext()')]));
		Assert.isTrue(inverts([TOOLS, FLAG_TOOLS, use('using Tools;\n\n', '', '!s.ext()')]));
	}

	/** Of two `using`s declaring the extension, the LAST one binds it (4.3.7). */
	@:pin('control') @:killer('M-BINDER-EXTENSION-LAST-USING')
	public function testTheLastUsingDeclaringTheExtensionWins(): Void {
		Assert.isTrue(inverts([TOOLS, FLAG_TOOLS, use('using FlagTools;\nusing Tools;\n\n', '', '!s.ext()')]));
		Assert.isFalse(inverts([TOOLS, FLAG_TOOLS, use('using Tools;\nusing FlagTools;\n\n', '', '!s.ext()')]));
	}

	/**
	 * The last `using` declares an `ext` of ANOTHER first parameter: the compiler passes it over for the earlier
	 * `FlagTools.ext`, and a first parameter that is not the receiver's own declaration proves nothing either way.
	 */
	@:pin('control') @:killer('M-BINDER-EXTENSION-FIRST-PARAM')
	public function testAnExtensionOfAnotherFirstParameterIsUnproven(): Void {
		final others: { file: String, source: String } = {
			file: 'OtherTools.hx',
			source: 'class OtherTools {\n\tpublic static function ext(h:Holder):Bool {\n\t\treturn true;\n\t}\n}\n'
		};
		Assert.isFalse(inverts([
			FLAG_TOOLS,
			others,
			use('using FlagTools;\nusing OtherTools;\n\n', '', '!s.ext()')
		]));
	}

	/**
	 * A later `using` the index does not hold may declare the extension: nothing earlier is read past it. The receiver type
	 * is written qualified (`p.Box`), which an unindexed module cannot rebind, so it is the `using` alone that refuses.
	 */
	@:pin('control') @:killer('M-BINDER-EXTENSION-UNINDEXED')
	public function testAnUnreadLaterUsingLeavesTheExtensionUnproven(): Void {
		final box: { file: String, source: String } = {
			file: 'p/Box.hx',
			source: 'package p;\n\nclass Box {\n\tpublic function new() {}\n}\n'
		};
		final tools: { file: String, source: String } = {
			file: 'BoxTools.hx',
			source: 'class BoxTools {\n\tpublic static function ext(b:p.Box):Bool {\n\t\treturn true;\n\t}\n}\n'
		};
		final source: String = 'class Use {\n\tfunction f(b:p.Box, x:Int):Int {\n\t\treturn !b.ext() ? 1 : 2;\n\t}\n}\n';
		Assert.isTrue(inverts([box, tools, { file: 'Use.hx', source: 'using BoxTools;\n\n$source' }]));
		Assert.isFalse(inverts([
			box,
			tools,
			{ file: 'Use.hx', source: 'using BoxTools;\nusing far.More;\n\n$source' }
		]));
	}

	/** `using Mod` brings the statics of every type of the module (4.3.7), not only of `Mod` itself. */
	@:pin('control') @:killer('M-USING-HOSTS-MODULE')
	public function testEveryTypeOfAUsedModuleBringsItsExtensions(): Void {
		final mod: { file: String, source: String } = {
			file: 'Mod.hx',
			source: 'class Mod {}\n\nclass FlagExt {\n\tpublic static function ext(s:Str):Flag {\n\t\treturn true;\n\t}\n}\n'
		};
		Assert.isFalse(inverts([TOOLS, mod, use('using Tools;\nusing Mod;\n\n', '', '!s.ext()')]));
	}

	/** `using` an alias brings the statics of the type it names (4.3.7: `typedef AliasTools = FlagTools` binds `FlagTools.ext`). */
	@:pin('control') @:killer('M-USING-HOSTS-ALIAS')
	public function testAUsedAliasLeavesTheExtensionUnproven(): Void {
		final alias: { file: String, source: String } = { file: 'AliasTools.hx', source: 'typedef AliasTools = FlagTools;\n' };
		Assert.isFalse(inverts([
			TOOLS,
			FLAG_TOOLS,
			alias,
			use('using Tools;\nusing AliasTools;\n\n', '', '!s.ext()')
		]));
	}

	/** A `#if`-guarded `using` declaring the extension binds it in the builds that define the flag (4.3.7). */
	@:pin('control') @:killer('M-BINDER-EXTENSION-GUARDED-USING')
	public function testAGuardedUsingLeavesTheExtensionUnproven(): Void {
		Assert.isFalse(inverts([
			TOOLS,
			FLAG_TOOLS,
			// the guarded `using` is the later one, and in a build defining `foo` it binds `Tools.ext` ahead of `FlagTools.ext`
			use('using FlagTools;\n#if foo\nusing Tools;\n#end\n\n', '', '!s.ext()')
		]));
	}

	/**
	 * A static extension of the field's name binds ahead of the abstract's `@:op(a.b)` (4.3.7: `r.foo` under `using Ext` is
	 * the extension even beside a resolver), from the file's own `using` and from the ambient `import.hx` alike.
	 */
	@:pin('control') @:killer('M-BINDER-RESOLVE-USING-SHADOW', 'M-USING-DECLS-AMBIENT')
	public function testAStaticOfTheFieldsNameOutranksTheResolver(): Void {
		final has: { file: String, source: String } = {
			file: 'Has.hx',
			source: 'abstract Has(Str) {\n\t@:op(a.b) function resolve(name:String):Bool {\n\t\treturn true;\n\t}\n}\n'
		};
		final shadow: { file: String, source: String } = {
			file: 'HasTools.hx',
			source: 'class HasTools {\n\tpublic static function any(h:Has):Flag {\n\t\treturn true;\n\t}\n}\n'
		};
		Assert.isTrue(inverts([has, shadow, use('', '', '!h.any')]));
		Assert.isFalse(inverts([has, shadow, use('using HasTools;\n\n', '', '!h.any')]));
		#if (sys || nodejs)
		// The ambient chain is read from DISK beside the module, so this fixture is a real tree.
		final root: String = CliFixture.writeTree('apq_operand_resolve', [{ name: 'import.hx', source: 'using HasTools;\n' }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final tree: Array<{ file: String, source: String }> = [has, shadow, use(
				'', '', '!h.any'
			)].concat(DECLS).map(f -> {file: '$root/${f.file}', source: f.source });
			for (f in tree) sys.io.File.saveContent(f.file, f.source);
			Assert.isFalse(inverts(tree, '$root/'));
		});
		#end
	}

	/**
	 * A fix decides with the operator table of the WHOLE run, not of the one file it rewrites — the report index it is
	 * handed (`OperatorSelection.of`'s `report`): a fold the run left report-only for an operand nothing types stays unfixed
	 * although its own file declares no overload, and the chain rule rewrites the ternary chain over `Num` that the switch
	 * rule refuses, in `fix` as in `run`.
	 */
	@:pin('control') @:killer('M-FOLD-FIX-REPORT-INDEX', 'M-PIEC-FIX-REPORT-INDEX', 'M-PIEC-RUN-SELECTION')
	public function testAFixAsksTheRunsOperatorTable(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final fold: FixRun = CheckFixture.fixRun(
			new FoldStringLiterals(), [use('import far.Mystery;\n\n', '', 'm.gv + \'a\' + \'b\' == \'\'')].concat(DECLS), 'Use.hx', plugin
		);
		Assert.equals(1, fold.violations.length);
		Assert.equals(0, fold.edits.length);
		final chain: FixRun = CheckFixture.fixRun(new PreferIfExpressionChain(), [
			{ file: 'Use.hx', source: 'class Use {\n\tfunction f(k:Num):Int {\n\t\treturn k == 1 ? 1 : k == 2 ? 2 : 3;\n\t}\n}\n' }
		].concat(DECLS), 'Use.hx', plugin);
		Assert.equals(1, chain.edits.length);
	}

	/**
	 * An untyped lambda parameter takes the parameter of the function type the lambda is expected to be (`ExpectedTypes`):
	 * the client's `forEachChild(child -> … !child.folder …)` shape — an abstract's member taking `(child:Use)->Void`, called bare,
	 * and a property read through an inline getter. `Bool` inverts, `Flag` does not; 4.3.7 types `child` as `Use`.
	 */
	@:pin('control') @:killer('M-BINDER-LAMBDA-PARAM-CUT', 'M-WALK-LAMBDA-PARAM-CUT', 'M-BINDER-ARGUMENT-CUT')
	public function testAnUntypedLambdaParameterTakesTheCalleesParameterType(): Void {
		final ab: String = 'abstract Use(Holder) {\n\tpublic var on(get, never):Bool;\n\n\tpublic var flag(get, never):Flag;\n\n'
			+ '\tinline function get_on():Bool\n\t\treturn true;\n\n\tinline function get_flag():Flag\n\t\treturn true;\n\n'
			+ '\tpublic inline function forEachChild(callback:(child:Use)->Void):Void {}\n\n\tpublic function f():Void {\n'
			+ '\t\tforEachChild(child -> trace(!child.@ ? 1 : 2));\n\t}\n}\n';
		Assert.isTrue(inverts([{ file: 'Use.hx', source: ab.replace('@', 'on') }]));
		Assert.isFalse(inverts([{ file: 'Use.hx', source: ab.replace('@', 'flag') }]));
	}

	/**
	 * Every rung of the expectation ladder carries the expected function type down to the lambda, each proved on 4.3.7
	 * (`$type(c)` is `Use` in every one): a call argument, parentheses, a ternary's and an `if`'s arm, a `switch` arm and the
	 * value its block ends with, a declaration written with a type, an assignment, a `return`, a lambda's body, an untyped
	 * lambda's `return`, an object-literal field, a `Null<…>` function type and a rest parameter.
	 */
	@:pin('control')
	@:killer('M-BINDER-LAMBDA-PARAM-CUT', 'M-BINDER-ANNOTATION-CUT', 'M-BINDER-RETURN-CUT', 'M-BINDER-FIELD-CUT', 'M-BINDER-ARGUMENT-CUT')
	@:killer('M-GRAPH-LITERAL-ARGUMENT', 'M-GRAPH-LITERAL-ARMS', 'M-GRAPH-LITERAL-RETURN', 'M-GRAPH-LITERAL-LAMBDA',
		'M-GRAPH-LITERAL-FIELD')
	@:killer('M-TS-LAMBDA-NULL', 'M-BINDER-ARGUMENT-REST')
	public function testEveryExpectationTypesTheLambdaParameter(): Void {
		final shapes: Array<{ name: String, members: String, body: String }> = [
			{ name: 'argument', members: '', body: 'each(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'paren', members: '', body: 'each((c -> trace(!c.on ? 1 : 2)));' },
			{ name: 'ternary', members: '', body: 'each(x > 0 ? c -> trace(!c.on ? 1 : 2) : c -> trace(0));' },
			{ name: 'if', members: '', body: 'each(if (x > 0) c -> trace(!c.on ? 1 : 2) else c -> trace(0));' },
			{
				name: 'switch',
				members: '',
				body: 'each(switch x {\n\t\t\tcase 0: {\n\t\t\t\t\ttrace(x);\n\t\t\t\t\tc -> trace(!c.on ? 1 : 2);\n\t\t\t\t}\n'
					+ '\t\t\tcase _: c -> trace(0);\n\t\t});'
			},
			{ name: 'declaration', members: '', body: 'final g:(c:Use)->Void = c -> trace(!c.on ? 1 : 2);' },
			{ name: 'assignment', members: '', body: 'var g:(c:Use)->Void = null;\n\t\tg = c -> trace(!c.on ? 1 : 2);' },
			{ name: 'return', members: '\tfunction mk():(c:Use)->Int {\n\t\treturn c -> !c.on ? 1 : 2;\n\t}\n\n', body: '' },
			{ name: 'body', members: '', body: 'final g:(a:Int)->((c:Use)->Int) = a -> c -> !c.on ? 1 : 2;' },
			{
				name: 'lambda return',
				members: '',
				body: 'final g:(a:Int)->((c:Use)->Int) = a -> {\n\t\t\treturn c -> !c.on ? 1 : 2;\n\t\t};'
			},
			{ name: 'field', members: '', body: 'final s:{ cb:(c:Use)->Int } = { cb: c -> !c.on ? 1 : 2 };' },
			{ name: 'nullable', members: '', body: 'final g:Null<(c:Use)->Int> = c -> !c.on ? 1 : 2;' },
			{ name: 'rest', members: '', body: 'rest(c -> trace(0), c -> trace(!c.on ? 1 : 2));' }
		];
		for (s in shapes) Assert.isTrue(inverts([lambdaUse(s.members, s.body)]), s.name);
		// the overloading `Flag` read through the same rung is refused: the parameter is TYPED, not merely accepted
		Assert.isFalse(inverts([lambdaUse('', 'each(c -> trace(!c.flag ? 1 : 2));')]));
	}

	/**
	 * A parameter before the one a lambda would bind may be skipped — optional, or carrying a default value — and 4.3.7 tries
	 * the lambda against it first: `opt(?a:(c:Use)->Int, cb:(c:FlagOn)->Void)` called with a `Void` lambda reports `c` as
	 * `Use`, then binds it to `cb` as `FlagOn`, whose `on` is the overloading `Flag`. Unproven; a required one before it is not
	 * skipped.
	 */
	@:pin('control') @:killer('M-BINDER-ARGUMENT-SKIPPABLE', 'M-TS-SKIP-DEFAULT')
	public function testALambdaAfterASkippableParameterIsUnproven(): Void {
		final opt: String = '\tfunction opt(?a:(c:Use)->Int, cb:(c:FlagOn)->Void):Void {}\n\n';
		Assert.isFalse(inverts([FLAG_ON, lambdaUse(opt, 'opt(c -> trace(!c.on ? 1 : 2));')]));
		final deflt: String = '\tfunction deflt(a:(c:Use)->Int = null, cb:(c:FlagOn)->Void):Void {}\n\n';
		Assert.isFalse(inverts([FLAG_ON, lambdaUse(deflt, 'deflt(c -> trace(!c.on ? 1 : 2));')]));
		Assert.isTrue(inverts([
			lambdaUse('\tfunction req(a:Int, cb:(c:Use)->Void):Void {}\n\n', 'req(1, c -> trace(!c.on ? 1 : 2));')
		]));
	}

	/**
	 * A callee whose written signature the call may not select types no lambda: an `@:overload` (4.3.7 retypes the lambda
	 * against the next signature when the first fails — `Foo has no field m`, then `Bar`), and a name a `#if` declares twice,
	 * each build its own signature.
	 */
	@:pin('control') @:killer('M-BINDER-ARGUMENT-OVERLOAD', 'M-BINDER-ARGUMENT-TWIN')
	public function testACalleeWhoseSignatureTheCallMayNotSelectIsUnproven(): Void {
		final overloaded: String = '\t@:overload(function(cb:(c:FlagOn)->Void):Void {})\n\tfunction one(cb:(c:Use)->Int):Void {}\n\n';
		Assert.isFalse(inverts([FLAG_ON, lambdaUse(overloaded, 'one(c -> trace(!c.on ? 1 : 2));')]));
		final flagged: String = '\tfunction two(cb:(c:FlagOn)->Void):Void {}\n';
		final plain: String = '\tfunction two(cb:(c:Use)->Void):Void {}\n';
		// either build's signature may be the one a reader picks: both orders are unproven
		for (twins in [
			'\t#if foo\n$flagged\t#else\n$plain\t#end\n\n',
			'\t#if foo\n$plain\t#else\n$flagged\t#end\n\n'
		]) Assert.isFalse(inverts([FLAG_ON, lambdaUse(twins, 'two(c -> trace(!c.on ? 1 : 2));')]));
	}

	/**
	 * An `@:overload` member's call whose arguments' count leaves one signature that may compile selects it (the code
	 * compiles; 4.3.7 `unify_field_call`), and its parameter types the lambda: `three(1, c -> …)` takes `(a:Int, cb:(c:Use)
	 * -> Void)` — the own `(cb:(c:FlagOn) -> Void)` takes one argument — so `c` is `Use`; `three(c -> …)` takes the own one,
	 * where `c.on` is the overloading `Flag`. Off another file's value alike (`b.over(1, c -> …)`).
	 */
	@:pin('control') @:killer('M-BINDER-OVERLOAD-SELECTED') @:killer('M-BINDER-OVERLOAD-OWN-BARE') @:killer('M-BINDER-CALLEE-OVERLOAD')
	public function testAnOverloadTheArgumentCountSelectsTypesTheLambda(): Void {
		final three: String = '\t@:overload(function(a:Int, cb:(c:Use)->Void):Void {})\n\tfunction three(cb:(c:FlagOn)->Void):Void {}\n\n';
		Assert.isTrue(inverts([FLAG_ON, lambdaUse(three, 'three(1, c -> trace(!c.on ? 1 : 2));')]), 'the annotation');
		Assert.isFalse(inverts([FLAG_ON, lambdaUse(three, 'three(c -> trace(!c.on ? 1 : 2));')]), 'the own signature');
		final box: { file: String, source: String } = {
			file: 'Box.hx',
			source: 'class Box {\n\tpublic function new() {}\n\n'
				+ '\t@:overload(function(a:Int, cb:(c:Use)->Void):Void {})\n\tpublic function over(cb:(c:FlagOn)->Void):Void {}\n}\n'
		};
		Assert.isTrue(inverts([
			FLAG_ON,
			box,
			lambdaUse('', 'final b:Box = new Box();\n\t\tb.over(1, c -> trace(!c.on ? 1 : 2));')
		]), 'off a value');
	}

	/**
	 * A callee's type parameter types no lambda: `gen(new FlagOn(), c -> …)` binds `T` to `FlagOn` (4.3.7), whose `on` is the
	 * overloading `Flag` — never the class `T` the module also declares. A `Dynamic` parameter is no function type.
	 */
	@:pin('control') @:killer('M-BINDER-ARGUMENT-SCOPE')
	public function testACalleesTypeParameterTypesNoLambda(): Void {
		final t: { file: String, source: String } = {
			file: 'T.hx',
			source: 'class T {\n\tpublic var on:Bool;\n\n\tpublic function new() {}\n}\n'
		};
		final gen: String = '\tfunction gen<T>(x:T, cb:(c:T)->Void):Void {}\n\n';
		Assert.isFalse(inverts([t, FLAG_ON, lambdaUse(gen, 'gen(new FlagOn(), c -> trace(!c.on ? 1 : 2));')]));
		Assert.isFalse(inverts([
			lambdaUse('\tfunction dyn(cb:Dynamic):Void {}\n\n', 'dyn(c -> trace(!c.on ? 1 : 2));')
		]));
	}

	/**
	 * Each route's operand under each ask, as one table: every route reaching the built-in type answers what the
	 * annotated one does, which accepts; every one reaching the overloading type answers what ITS annotated one does,
	 * which refuses; the unread route refuses for both — and the fold, whose layout finding stands without the proof,
	 * reports it without a fix (`foldUnproven`).
	 */
	private function matrix(builtin: String, overloading: String, shapes: Array<Shape>, asks: Array<Ask>, foldUnproven: Bool): Void {
		final files: Array<{ file: String, source: String }> = DECLS.concat(helpers(builtin)).concat(helpers(overloading));
		for (t in [builtin, overloading]) for (route in ROUTES) files.push(useFile(route, t, shapes));
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		for (ask in asks) {
			final found: Array<Violation> = CheckFixture.violationsIn(ask.check, files, plugin);
			for (t in [builtin, overloading]) for (route in ROUTES) {
				final file: String = '${useName(route, t)}.hx';
				final source: String = files.find(f -> f.file == file)?.source ?? '';
				final at: Span = bodyOf(source, ask.shape);
				final mine: Array<Violation> = found.filter(v -> v.file == file && v.span != null && within(v.span, at));
				final answer: String = switch ask.read {
					case Reports: mine.length > 0 ? 'accepted' : 'refused';
					case Silent: mine.length > 0 ? 'refused' : 'accepted';
					case Fixable: if (mine.length == 0)
						'refused'
					else if (mine.exists(v -> v.message.indexOf('overloads') >= 0))
						'unproven'
					else
						'accepted';
					case Positive: positive(ask.check, files, found.filter(v -> v.file == file), file, at, plugin);
				};
				final expected: String = if (route == 'Unread')
					(ask.read == Fixable && foldUnproven ? 'unproven' : 'refused')
				else if (t == builtin)
					'accepted'
				else
					'refused';
				Assert.equals(expected, answer, '${ask.check.id()} on the ${ask.shape} shape, $route route, $t operand');
			}
		}
	}

	private static inline function within(inner: Span, outer: Span): Bool {
		return inner.from >= outer.from && inner.to <= outer.to;
	}

	private static inline function useName(route: String, t: String): String {
		return 'Use$route$t';
	}

	/**
	 * Whether `invert-negated-if-else` inverts the negated ternary of `Use.hx` (under `prefix`) over `files` and the
	 * overloading abstracts — the probe every refusal test reads, since the inversion is accepted exactly when the operand
	 * proves the built-in `!`. A `DECLS` file `files` redeclares is left out.
	 */
	private static function inverts(files: Array<{ file: String, source: String }>, prefix: String = ''): Bool {
		final run: Array<{ file: String, source: String }> = files.copy();
		for (d in DECLS) if (!run.exists(f -> f.file == '$prefix${d.file}')) run.push({ file: '$prefix${d.file}', source: d.source });
		return CheckFixture.violationsIn(new InvertNegatedIfElse(), run, new HaxeQueryPlugin()).exists(v -> v.file == '${prefix}Use.hx');
	}

	/** `Use.hx`: `head` above the class, `parent` after its name, and one function returning `cond ? 1 : 2`. */
	private static function use(head: String, parent: String, cond: String): { file: String, source: String } {
		return {
			file: 'Use.hx',
			source: '${head}class Use$parent {\n\tfunction f(s:Str, h:Has, x:Int):Int {\n\t\treturn $cond ? 1 : 2;\n\t}\n}\n'
		};
	}

	/**
	 * `Use.hx` for the lambda-parameter tests: `on` reads the built-in `Bool` through an inline getter, `flag` the overloading
	 * `Flag`; `each` takes `(c:Use)->Void`, `rest` any number of them; `members` beside them, and `body` in one function.
	 */
	private static function lambdaUse(members: String, body: String): { file: String, source: String } {
		return {
			file: 'Use.hx',
			source: 'class Use {\n\tpublic var on(get, never):Bool;\n\n\tpublic var flag:Flag;\n\n\tpublic function new() {}\n\n'
				+ '\tinline function get_on():Bool\n\t\treturn true;\n\n\tfunction each(cb:(c:Use)->Void):Void {}\n\n'
				+ '\tfunction rest(...cbs:(c:Use)->Void):Void {}\n\n$members\tfunction f(x:Int):Int {\n\t\t$body\n\t\treturn x;\n\t}\n}\n'
		};
	}

	/** A builder's verdict: `accepted` when its one edit in `at` writes the condition positive, `refused` when it keeps the `!`. */
	private static function positive(
		check: Check, files: Array<{ file: String, source: String }>, found: Array<Violation>, file: String, at: Span,
		plugin: GrammarPlugin
	): String {
		final edits: Array<FixEdit> = CheckFixture.fixIn(check, files, found, file, plugin).filter(e -> within(e.span, at));
		return if (edits.length != 1)
			'no edit (${edits.length})'
		else if (edits[0].text.indexOf('!') >= 0)
			'refused'
		else
			'accepted';
	}

	/** The span of the body of the shape function `shape` in `source`. */
	private static function bodyOf(source: String, shape: String): Span {
		final from: Int = source.indexOf('function $shape(');
		final next: Int = source.indexOf('\n\tfunction ', from + 1);
		return new Span(from, next < 0 ? source.length : next);
	}

	/** The route's helper types for `t`: a supertype holding a `t` field, a static extension and a resolver answering `t`. */
	private static function helpers(t: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'Base$t.hx', source: 'class Base$t {\n\tpublic var gv:$t;\n\n\tpublic function new() {}\n}\n' },
			{ file: 'Tools$t.hx', source: 'class Tools$t {\n\tpublic static function ext(s:Str):$t {\n\t\treturn null;\n\t}\n}\n' },
			{
				file: 'Has$t.hx',
				source: 'abstract Has$t(Str) {\n\t@:op(a.b) function resolve(name:String):$t {\n\t\treturn null;\n\t}\n}\n'
			}
		];
	}

	/** One class per route and type, a function per shape, the shape's `@` replaced by the route's operand. */
	private static function useFile(route: String, t: String, shapes: Array<Shape>): { file: String, source: String } {
		final operand: String = switch route {
			case 'Annotated': 'v';
			case 'Local': 'w';
			case 'Self': 'this.fv';
			case 'Inherited': 'gv';
			case 'Extension': 's.ext()';
			case 'Resolve': 'h.any';
			case _: 'm.gv';
		};
		final head: String = switch route {
			case 'Extension': 'using Tools$t;\n\n';
			case 'Unread': 'import far.Mystery;\n\n';
			case _: '';
		};
		final parent: String = route == 'Inherited' ? ' extends Base$t' : '';
		var out: String =
			'${head}class ${useName(route, t)}$parent {\n\tpublic var fv:$t;\n\n\tfunction mk():$t {\n\t\treturn null;\n\t}\n';
		for (shape in shapes) {
			final body: String = shape.body.replace('@', operand);
			final prefixed: String = route == 'Local' ? 'final w = mk();\n\t\t$body' : body;
			out += '\n\tfunction ${shape.name}(v:$t, s:Str, h:Has$t, m:Mystery, x:Int):Int {\n\t\t$prefixed\n\t}\n';
		}
		return { file: '${useName(route, t)}.hx', source: '$out}\n' };
	}

	/**
	 * A callee declared in ANOTHER file types the lambda as one of this file does — each shape compiled on Haxe 4.3.7, whose
	 * `$type` of `c` is `Use` in every one (`v-N48-hx/b1`): an instance member off a value, a static off its type, a
	 * constructor, a member the enclosing type inherits, a local function, a generic type's member and constructor with the
	 * type arguments the receiver's annotation or the `new` writes.
	 */
	@:pin('control')
	@:killer('M-BINDER-CALLEE-MEMBER-OFF', 'M-BINDER-CALLEE-NEW-OFF', 'M-BINDER-CALLEE-INHERITED-OFF', 'M-BINDER-CALLEE-LOCAL-OFF')
	@:killer('M-BINDER-OWNER-BINDINGS-OFF', 'M-BINDER-LOCATED-HOST-OFF')
	public function testALambdaTakesTheParameterOfACalleeDeclaredElsewhere(): Void {
		final other: { file: String, source: String } = {
			file: 'Other.hx',
			source: 'class Other {\n\tpublic function new() {}\n\n\tpublic function each(cb:(c:Use)->Void):Void {}\n\n'
				+ '\tpublic static function stat(cb:(c:Use)->Void):Void {}\n\n\tpublic function priv(cb:(c:Item)->Void):Void {}\n}\n\n'
				+ 'private class Item {\n\tpublic var on(get, never):Bool;\n\n\tinline function get_on():Bool\n\t\treturn true;\n}\n'
		};
		final maker: { file: String, source: String } = {
			file: 'Maker.hx',
			source: 'class Maker {\n\tpublic function new(cb:(c:Use)->Void) {}\n}\n'
		};
		final box: { file: String, source: String } = {
			file: 'Box.hx',
			source: 'class Box<T> {\n\tpublic function new(?cb:(c:T)->Void) {}\n\n\tpublic function each(cb:(c:T)->Void):Void {}\n}\n'
		};
		final holder: { file: String, source: String } = {
			file: 'Holder.hx',
			source: 'class Holder<T> {\n\tpublic function new(cb:(c:T)->Void) {}\n}\n'
		};
		final uses: Array<{ name: String, body: String }> = [
			{ name: 'member', body: 'final o:Other = new Other();\n\t\to.each(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'static', body: 'Other.stat(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'where the callee writes it', body: 'final o:Other = new Other();\n\t\to.priv(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'new', body: 'new Maker(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'local', body: 'function loc(cb:(c:Use)->Void):Void {}\n\t\tloc(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'generic member', body: 'final b:Box<Use> = new Box();\n\t\tb.each(c -> trace(!c.on ? 1 : 2));' },
			{ name: 'generic new', body: 'new Holder<Use>(c -> trace(!c.on ? 1 : 2));' }
		];
		for (u in uses) Assert.isTrue(inverts([other, maker, box, holder, lambdaUse('', u.body)]), u.name);
		final base: { file: String, source: String } = {
			file: 'Base.hx',
			source: 'class Base {\n\tpublic function new() {}\n\n\tpublic function inherited(cb:(c:Use)->Void):Void {}\n}\n'
		};
		final sub: { file: String, source: String } = {
			file: 'Use.hx',
			source: 'class Use extends Base {\n\tpublic var on(get, never):Bool;\n\n\tinline function get_on():Bool\n\t\treturn true;\n\n'
				+ '\tfunction f():Void {\n\t\tinherited(c -> trace(!c.on ? 1 : 2));\n\t}\n}\n'
		};
		Assert.isTrue(inverts([base, sub]), 'inherited');
	}

	/**
	 * What the call does not bind stays unproven: a type parameter the method declares itself, shadowing the type's (4.3.7:
	 * `Unknown<0>`), a receiver written with no type arguments, a member `@:overload` offers another signature of.
	 */
	@:pin('control') @:killer('M-BINDER-METHOD-SHADOWS-OFF', 'M-BINDER-ARGUMENT-OVERLOAD')
	public function testWhatTheCallDoesNotBindStaysUnproven(): Void {
		final box: { file: String, source: String } = {
			file: 'Box.hx',
			source: 'class Box<T> {\n\tpublic function new() {}\n\n\tpublic function each(cb:(c:T)->Void):Void {}\n\n'
				+ '\tpublic function shadow<T>(cb:(c:T)->Void):Void {}\n\n'
				+ '\t@:overload(function(cb:(c:Int)->Void):Void {})\n\tpublic function over(cb:(c:T)->Void):Void {}\n}\n'
		};
		Assert.isFalse(inverts([
			box,
			lambdaUse('', 'final b:Box<Use> = new Box();\n\t\tb.shadow(c -> trace(!c.on ? 1 : 2));')
		]), 'shadow');
		Assert.isFalse(inverts([
			box,
			lambdaUse('', 'final b = new Box();\n\t\tb.each(c -> trace(!c.on ? 1 : 2));')
		]), 'unwritten');
		Assert.isFalse(inverts([
			box,
			lambdaUse('', 'final b:Box<Use> = new Box();\n\t\tb.over(c -> trace(!c.on ? 1 : 2));')
		]), 'overload');
	}

	/**
	 * A std `Iterable` of the method's own type parameter binds it to the element of a std iterable handed to it — the
	 * receiver of `using Lambda`'s `xs.iter(…)`, the argument of `Lambda.iter(xs, …)` (4.3.7: `c` is `Use` for an `Array`,
	 * a `List`, an `Iterable` and the value of a `Map`; a `haxe.ds.Vector` is no `Iterable`).
	 */
	@:pin('control') @:killer('M-BINDER-ITERABLE-OFF', 'M-BINDER-ITERABLE-ANY-TYPE')
	public function testAStdIterableBindsTheElementOfWhatIsHandedToIt(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no installed Haxe std on this machine');
			return;
		}
		final std: Array<{ file: String, source: String }> = [
			{
				file: QueryTestHelpers.stdPath('Lambda.hx'),
				source: 'class Lambda {\n\tpublic static function iter<A>(it:Iterable<A>, f:(a:A)->Void):Void {}\n}\n'
			},
			{ file: QueryTestHelpers.stdPath('StdTypes.hx'), source: 'typedef Iterable<T> = {\n\tfunction iterator():Iterator<T>;\n}\n' },
			// the std `Array` declares `iterator()`, which is what makes it an `Iterable` for the extension's first parameter
			{
				file: QueryTestHelpers.stdPath('Array.hx'),
				source: 'extern class Array<T> {\n\tfunction new():Void;\n\n\tfunction iterator():Iterator<T>;\n}\n'
			},
			{
				file: QueryTestHelpers.stdPath('haxe/ds/Vector.hx'),
				source: 'package haxe.ds;\n\nextern class Vector<T> {\n\tfunction new(n:Int):Void;\n}\n'
			}
		];
		function lambdaFile(body: String): { file: String, source: String } {
			final f: { file: String, source: String } = lambdaUse('', body);
			return { file: f.file, source: 'using Lambda;\n\n' + f.source };
		}
		Assert.isTrue(inverts(std.concat([lambdaFile('final xs:Array<Use> = [];\n\t\txs.iter(c -> trace(!c.on ? 1 : 2));')])), 'extension');
		Assert.isTrue(inverts(std.concat([
			lambdaFile('final xs:Array<Use> = [];\n\t\tLambda.iter(xs, c -> trace(!c.on ? 1 : 2));')
		])), 'static');
		Assert.isFalse(inverts(std.concat([
			lambdaFile('final v:haxe.ds.Vector<Use> = new haxe.ds.Vector(1);\n\t\tLambda.iter(v, c -> trace(!c.on ? 1 : 2));')
		])), 'a Vector is no Iterable');
		#else
		Assert.pass('non-sys target');
		#end
	}

}

/** One operand position: a function body whose `@` the route's operand replaces. */
private typedef Shape = {
	final name: String;
	final body: String;
};

/** What a rule answers about a shape, read the way its finding means it. */
private enum Read {

	/** A finding in the shape accepts the operand. */
	Reports;

	/** A finding in the shape REFUSES it: the rule defers a chain the switch rules claim. */
	Silent;

	/** The fold: a finding with a fix accepts, one carrying the operator gate's refusal is unproven, none refuses. */
	Fixable;

	/** A ternary builder: an edit that writes the condition positive accepts, one keeping the `!` refuses. */
	Positive;

}

/** One rule asked about one shape. */
private typedef Ask = {
	final check: Check;
	final shape: String;
	final read: Read;
};

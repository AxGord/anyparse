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
 * The same operand, reached by each arc the shared walk types (`NominalTypes.typeWalk` over `OperandBinder`) — a written
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
			use('using Tools;\n#if foo\nusing FlagTools;\n#end\n\n', '', '!s.ext()')
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

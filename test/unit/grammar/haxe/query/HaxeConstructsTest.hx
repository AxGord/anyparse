package unit.grammar.haxe.query;

import anyparse.check.Check.FixEdit;
import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.grammar.mermaid.MermaidQueryPlugin;
import anyparse.query.Constructs;
import anyparse.query.ElementSpan;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `HaxeConstructs`: each construct comes back as the Haxe text of exactly what was asked for, and a result that does not
 * parse back to that construct is refused rather than handed to an edit.
 */
@:nullSafety(Strict)
class HaxeConstructsTest extends Test {

	/** A member built from parts reads as the declaration a hand would write, modifiers in the order given. */
	@:pin('control')
	@:killer('M-NODES-MODIFIER-PUBLIC')
	public function testMembersAreSpelledFromTheirParts(): Void {
		final build: Constructs = constructs();
		final item: Built = sure(build.typeRef('Item'));
		final int: Built = sure(build.typeRef('Int'));
		final key: Built = sure(build.lambda(['a'], copied(build, 'a.x')));
		final value: Built = sure(build.call(sure(build.qualified(sure(build.typeRef('Cmp')), 'asc')), [key]));
		final comparator: Built = sure(build.functionType([item, item], int));
		Assert.equals(
			'private static final byX:(Item, Item) -> Int = Cmp.asc(a -> a.x);',
			build.member([Private, Static], Constant, 'byX', comparator, value)?.text
		);
		final body: Built = sure(build.returning(copied(build, 'a.x - b.x')));
		Assert.equals(
			'public static function byX(a:Item, b:Item):Int\n\treturn a.x - b.x;',
			build.member([Public, Static], Method([{ name: 'a', type: item }, { name: 'b', type: item }]), 'byX', int, body)?.text
		);
		Assert.equals('var count;', build.member([], Variable, 'count', null, null)?.text);
		Assert.equals(Member, build.member([], Variable, 'count', null, null)?.kind);
		final call: String = 'Cmp.ints(a.k, b.k)';
		Assert.equals(
			'Order.ints(a.k, b.k)',
			build.substituted(call, new Span(0, call.length), new Span(0, 3), sure(build.typeRef('Order')), Expression)?.text,
			'a receiver respelled inside a copied call'
		);
	}

	/** Imports, modifier sets and statements are constructs of their own kinds. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-WORD-PUBLIC')
	public function testDeclarationsOfEachKind(): Void {
		final build: Constructs = constructs();
		Assert.equals('import a.b.C;', build.importOf('a.b.C')?.text);
		Assert.equals('using a.b.D;', build.usingOf('a.b.D')?.text);
		Assert.equals(Import, build.usingOf('a.b.D')?.kind);
		Assert.equals('override public inline', build.modifiers([Override, Public, Inline])?.text);
		Assert.equals(Statement, build.returning(copied(build, 'x'))?.kind);
	}

	/** A callee that would otherwise regroup the call around its own last part is parenthesized, so the call stays a call. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-ANY-ROOT')
	public function testACalleeIsParenthesizedOnlyWhenItWouldRegroup(): Void {
		final build: Constructs = constructs();
		final arg: Built = copied(build, 'a');
		Assert.equals('(x -> x)(a)', build.call(sure(build.lambda(['x'], copied(build, 'x'))), [arg])?.text);
		Assert.equals('f.g(a)', build.call(copied(build, 'f.g'), [arg])?.text);
		Assert.equals('(a + b).length', build.qualified(copied(build, 'a + b'), 'length')?.text);
	}

	/** Whatever does not parse back to exactly the construct asked for is refused. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-UNCHECKED')
	@:killer('M-CONSTRUCTS-MEMBER-COUNT')
	public function testWhatDoesNotParseToTheAskedKindIsRefused(): Void {
		final build: Constructs = constructs();
		final source: String = 'a; b';
		Assert.isNull(build.copied(source, new Span(0, source.length), Expression), 'two statements are no expression');
		Assert.isNull(build.typeRef('Array<Int'), 'an unclosed type');
		Assert.isNull(build.importOf('a.b; class X {}'), 'an import followed by a type');
		Assert.isNull(build.member([], Variable, 'x = 1; var y', null, null), 'a name that smuggles a second member');
		Assert.isNull(build.qualified(sure(build.typeRef('Array<Int>')), 'x'), 'a type with parameters reached as a value');
		Assert.isNull(build.call(sure(build.returning(copied(build, 'x'))), []), 'a statement called');
		Assert.isNull(build.modifiers([]), 'an empty modifier set');
	}

	/** A grammar with no construct builder answers null. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-JSON')
	public function testGrammarsWithoutConstructsAnswerNull(): Void {
		Assert.isNull(new JsonQueryPlugin().constructs());
		Assert.isNull(new MermaidQueryPlugin().constructs());
	}

	/** A wildcard and an aliased path, in either alias keyword, are the import declarations they spell. */
	public function testWildcardAndAliasedImportsAreBuilt(): Void {
		final build: Constructs = constructs();
		Assert.equals('import a.b.*;', build.importOf('a.b.*')?.text);
		Assert.equals('import a.b.C as D;', build.importOf('a.b.C as D')?.text);
		Assert.equals('import a.b.C in D;', build.importOf('a.b.C in D')?.text);
		Assert.isNull(build.importOf('a.b.C as'), 'an alias with no name');
	}

	/** A modifier lands in the grammar's canonical order among the ones the declaration carries, whatever order they stand in. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-MODIFIER-ORDER')
	public function testAModifierIsPlacedInCanonicalOrder(): Void {
		Assert.equals(
			'class A { private static inline final X = 1; }', withModifier('class A { private static final X = 1; }', 'final', Inline)
		);
		Assert.equals('class A { public static function f() {} }', withModifier('class A { static function f() {} }', 'function', Public));
		Assert.equals(
			'class A { override public function f() {} }', withModifier('class A { override function f() {} }', 'function', Public)
		);
		Assert.equals('class A { static function f() {} }', withModifier('class A { function f() {} }', 'function', Static));
		Assert.equals('class A { @:keep public function f() {} }', withModifier('class A { @:keep function f() {} }', 'function', Public));
	}

	/** A visibility the declaration already carries is replaced, never doubled, and a modifier it already carries adds nothing. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-MODIFIER-VISIBILITY')
	public function testAVisibilityIsReplacedAndACarriedModifierAddsNothing(): Void {
		Assert.equals('class A { public function f() {} }', withModifier('class A { private function f() {} }', 'function', Public));
		Assert.equals('class A { private function f() {} }', withModifier('class A { public function f() {} }', 'function', Private));
		Assert.equals('class A { public function f() {} }', withModifier('class A { public function f() {} }', 'function', Public));
	}

	/** A variable declaration's keyword becomes the constant one, and only where a variable declaration starts. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-CONSTANT-KEYWORD')
	public function testAVariableDeclarationBecomesAConstantOne(): Void {
		final source: String = 'class A { var x = 1; }';
		final edit: Null<FixEdit> = constructs().asConstant(source, source.indexOf('var'));
		Assert.equals('class A { final x = 1; }', edit == null ? null : apply(source, edit));
		Assert.isNull(constructs().asConstant(source, source.indexOf('x')), 'not at a keyword');
		Assert.isNull(constructs().asConstant('class A { final x = 1; }', 10), 'a constant is not a variable');
	}

	/** A guard leaves by the statement it is given and refuses one that does not leave; a conditional runs any statement. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-GUARD-ANY-EXIT')
	public function testAGuardLeavesAndAConditionalRuns(): Void {
		final build: Constructs = constructs();
		final failed: Built = copied(build, '!ok');
		Assert.equals('return;', build.returningNothing()?.text);
		Assert.equals('continue;', build.continuing()?.text);
		Assert.equals('if (!ok) return;', build.guard(failed, sure(build.returningNothing()))?.text);
		Assert.equals('if (!ok) continue;', build.guard(failed, sure(build.continuing()))?.text);
		Assert.equals('if (!ok) throw e;', build.guard(failed, statement(build, 'throw e;'))?.text);
		Assert.equals(
			'if (!(p /* keep */ && q)) return;', build.guard(copied(build, '!(p /* keep */ && q)'), sure(build.returningNothing()))?.text,
			'a comment in the condition rides along'
		);
		Assert.isNull(build.guard(failed, statement(build, 'f();')), 'a statement that does not leave is no guard');
		Assert.equals('if (c) f();', build.conditional(copied(build, 'c'), statement(build, 'f();'))?.text);
		Assert.equals(Statement, build.conditional(copied(build, 'c'), statement(build, 'f();'))?.kind);
	}

	/** An assignment, a compound one and a local declaration are built of their parts, each a statement of its own. */
	@:pin('control')
	@:killer('M-NODES-REMAINDER-AS-ADD')
	public function testAssignmentsAndLocalsAreBuiltOfTheirParts(): Void {
		final build: Constructs = constructs();
		final x: Built = copied(build, 'x');
		final n: Built = copied(build, 'n');
		Assert.equals('x = find(a);', build.assignment(x, copied(build, 'find(a)'))?.text);
		Assert.equals('x %= n;', build.compoundAssignment(x, Remainder, n)?.text);
		Assert.equals('x += n;', build.compoundAssignment(x, Add, n)?.text);
		Assert.equals('x -= n;', build.compoundAssignment(x, Subtract, n)?.text);
		Assert.equals('x *= n;', build.compoundAssignment(x, Multiply, n)?.text);
		Assert.equals('x /= n;', build.compoundAssignment(x, Divide, n)?.text);
		Assert.equals('final h = core;', build.local(Constant, 'h', null, copied(build, 'core'))?.text);
		Assert.equals('var x:Int = 1;', build.local(Variable, 'x', build.typeRef('Int'), copied(build, '1'))?.text);
		Assert.equals('var x;', build.local(Variable, 'x', null, null)?.text);
		Assert.isNull(build.local(Method([]), 'x', null, null), 'a local method is no local value');
		Assert.isNull(build.local(Variable, 'x = 1; var y', null, null), 'a name that smuggles a second declaration');
	}

	/** A loop binds the names it is given and nothing else, over a range or any iterable, by element or by key and value. */
	@:pin('control')
	@:killer('M-CONSTRUCTS-BINDER-UNCHECKED')
	public function testLoopsBindTheirNames(): Void {
		final build: Constructs = constructs();
		final body: Built = sure(build.block([statement(build, 'f(i);')]));
		Assert.equals(
			'for (i in 0...n) {\n\tf(i);\n}', build.forEach('i', sure(build.range(copied(build, '0'), copied(build, 'n'))), body)?.text
		);
		Assert.equals('for (x in xs) f(x);', build.forEach('x', copied(build, 'xs'), statement(build, 'f(x);'))?.text);
		Assert.equals('for (k => v in m) f(k, v);', build.forEachPair('k', 'v', copied(build, 'm'), statement(build, 'f(k, v);'))?.text);
		Assert.isNull(build.forEach('x in a) if (b', copied(build, 'xs'), body), 'a binder carrying code of its own');
		Assert.isNull(build.forEachPair('k', 'v in a) if (b', copied(build, 'm'), body), 'a value binder carrying code of its own');
	}

	/**
	 * A block holds the statements of its parts and a run joins them a line each, keeping the comments of a copied run, and
	 * neither takes a join that regroups its parts or a comment closing a run that something follows.
	 */
	@:pin('control')
	@:killer('M-NODES-RUN-GLUED')
	@:killer('M-CONSTRUCTS-SEQUENCE-UNCOUNTED')
	@:killer('M-CONSTRUCTS-SEQUENCE-OWN-LAYOUT-SPLIT')
	@:killer('M-PARSEBACK-RUN-LAYOUT-TRIMMED')
	public function testBlocksAndRunsKeepTheirStatementsApart(): Void {
		final build: Constructs = constructs();
		final explained: Built = run(build, '\n\t\t// explain\n\t\tlog(a);\n\t\treturn true;\n\t');
		Assert.equals('\n\t\t// explain\n\t\tlog(a);\n\t\treturn true;', explained.text, 'a copied run keeps the layout opening it');
		Assert.equals('{}', build.block([])?.text);
		Assert.equals('{\n\t// explain\n\tlog(a);\n\treturn true;\n}', build.block([explained])?.text);
		Assert.equals('{\n\tlog(a);\n\t// end\n}', build.block([run(build, 'log(a);\n// end')])?.text);
		Assert.isNull(build.block([run(build, 'log(a);\n// end'), statement(build, 'f();')]), 'a comment closing a run before another');
		final guard: Built = sure(build.guard(copied(build, '!ok'), sure(build.returningNothing())));
		final joined: Null<Built> = build.sequence([guard, explained]);
		Assert.equals('if (!ok) return;\n\t\t// explain\n\t\tlog(a);\n\t\treturn true;', joined?.text);
		Assert.equals(Statements, joined?.kind);
		final opened: Built = run(build, ' // why\n\tf();');
		Assert.equals('if (!ok) return; // why\n\tf();', build.sequence([guard, opened])?.text, 'the comment of the line it opened on');
		Assert.equals('{\n\t// why\n\tf();\n}', build.block([opened])?.text);
		Assert.equals('if (!ok) return;\n\n\tf();', build.sequence([guard, run(build, '\n\n\tf();')])?.text, 'a blank line opening it');
		Assert.equals('if (!ok) return;\nf();', build.sequence([guard, statement(build, 'f();')])?.text);
		Assert.equals('// only', build.copied('// only', new Span(0, 7), Statements)?.text, 'a run of comments alone');
		Assert.isNull(build.sequence([run(build, 'x = 1'), statement(build, '-y;')]), 'a join that regroups two statements into one');
		Assert.isNull(build.copied(' \n ', new Span(0, 3), Statements), 'an empty run');
		Assert.isNull(build.sequence([]), 'a run of nothing');
	}

	/** A range, an array and a boolean are expressions; a range operand that would regroup it is parenthesized. */
	@:pin('control')
	@:killer('M-NODES-BOOLEAN-NEGATED')
	public function testLiteralsAreExpressions(): Void {
		final build: Constructs = constructs();
		Assert.equals('0...n + 1', build.range(copied(build, '0'), copied(build, 'n + 1'))?.text);
		Assert.equals('(a ? b : c)...n', build.range(copied(build, 'a ? b : c'), copied(build, 'n'))?.text);
		Assert.equals('[a, b]', build.arrayOf([copied(build, 'a'), copied(build, 'b')])?.text);
		Assert.equals('[]', build.arrayOf([])?.text);
		Assert.equals('true', build.boolean(true)?.text);
		Assert.equals('false', build.boolean(false)?.text);
		Assert.equals(Expression, build.boolean(true)?.kind);
	}

	/** A part of the wrong kind is refused by every statement and literal construct. */
	@:pin('guard')
	public function testAPartOfTheWrongKindIsRefused(): Void {
		final build: Constructs = constructs();
		final stmt: Built = statement(build, 'f();');
		final expr: Built = copied(build, 'c');
		Assert.isNull(build.guard(stmt, sure(build.returningNothing())), 'a statement as a condition');
		Assert.isNull(build.conditional(expr, expr), 'an expression as a body');
		Assert.isNull(build.assignment(stmt, expr), 'a statement as a target');
		Assert.isNull(build.compoundAssignment(expr, Add, stmt), 'a statement as a value');
		Assert.isNull(build.local(Variable, 'x', expr, null), 'an expression as a type');
		Assert.isNull(build.forEach('x', stmt, stmt), 'a statement as an iterable');
		Assert.isNull(build.block([expr]), 'an expression in a block');
		Assert.isNull(build.sequence([expr]), 'an expression in a run');
		Assert.isNull(build.range(stmt, expr), 'a statement as a bound');
		Assert.isNull(build.arrayOf([stmt]), 'a statement as an item');
	}

	private static function constructs(): Constructs {
		return sure(new HaxeQueryPlugin().constructs());
	}

	private static function copied(build: Constructs, source: String): Built {
		return sure(build.copied(source, new Span(0, source.length), Expression));
	}

	private static function statement(build: Constructs, source: String): Built {
		return sure(build.copied(source, new Span(0, source.length), Statement));
	}

	private static function run(build: Constructs, source: String): Built {
		return sure(build.copied(source, new Span(0, source.length), Statements));
	}

	private static function sure<T>(value: Null<T>): T {
		if (value == null) throw 'the construct was refused';
		return value;
	}

	private static function withModifier(source: String, memberKeyword: String, modifier: Modifier): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final edit: Null<FixEdit> = sure(plugin.constructs())
			.withModifier(ElementSpan.declarationHeadAt(tree, source.indexOf(memberKeyword)), modifier);
		return edit == null ? source : apply(source, edit);
	}

	private static function apply(source: String, edit: FixEdit): String {
		return source.substring(0, edit.span.from) + edit.text + source.substring(edit.span.to);
	}

}

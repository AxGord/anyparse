package unit.grammar.haxe.query;

import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.grammar.mermaid.MermaidQueryPlugin;
import anyparse.query.Constructs;
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
	@:killer('M-CONSTRUCTS-WORD-PUBLIC')
	public function testMembersAreSpelledFromTheirParts(): Void {
		final build: Constructs = constructs();
		final item: Built = sure(build.typeRef('Item'));
		final int: Built = sure(build.typeRef('Int'));
		final key: Built = sure(build.lambda(['a'], copied(build, 'a.x')));
		final value: Built = sure(build.call(sure(build.qualified(sure(build.typeRef('Cmp')), 'asc')), [key]));
		final comparator: Built = sure(build.functionType([item, item], int));
		Assert.equals(
			'private static final byX: (Item, Item) -> Int = Cmp.asc(a -> a.x);',
			build.member([Private, Static], Constant, 'byX', comparator, value)?.text
		);
		final body: Built = sure(build.returning(copied(build, 'a.x - b.x')));
		Assert.equals(
			'public static function byX(a: Item, b: Item): Int return a.x - b.x;',
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

	private static function constructs(): Constructs {
		return sure(new HaxeQueryPlugin().constructs());
	}

	private static function copied(build: Constructs, source: String): Built {
		return sure(build.copied(source, new Span(0, source.length), Expression));
	}

	private static function sure<T>(value: Null<T>): T {
		if (value == null) throw 'the construct was refused';
		return value;
	}

}

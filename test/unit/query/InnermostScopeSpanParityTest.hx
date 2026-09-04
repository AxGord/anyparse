package unit.query;

import anyparse.check.BindingScope;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Rename;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The project declares the same walk TWICE — `BindingScope.innermostSpanOfKinds` and
 * `Rename.innermostOfKinds` — and `BindingScope`'s own doc says folding them "would change one
 * caller's answer for co-starting nodes". That sentence was a claim with no fixture behind it.
 * This class supplies the fixture, and the measurement that decides whether the claim reaches
 * either module's real callers.
 *
 * Two differences exist, and only one of them is reachable:
 *
 * - `exclude`. `BindingScope` drops the node occupying exactly the excluded span, which is how a
 *   lookup made FROM a local-function declaration reaches the ENCLOSING body instead of the
 *   declaration's own frame. `Rename`'s walk has no such parameter. This one is real, exercised
 *   on every call `BindingScope` makes, and pinned by name below.
 * - The tie-break between CO-STARTING matches. `BindingScope` keeps the first match with a
 *   strictly greater `span.from`, so among two nodes sharing a start it answers the OUTER one;
 *   `Rename` keeps the last match in walk order, so it answers the INNER one. The claim is
 *   correct — `testCoStartingNodesAreTheOneShapeTheTwoWalksDisagreeOn` shows it on real bytes —
 *   but it needs two nodes of the queried kinds to share a start, and
 *   `testNoTwoScopeNodesShareASpanStart` measures that the Haxe grammar's own `scopeKinds`
 *   vocabulary never produces such a pair. So the difference is unreachable through the
 *   callers either module actually has.
 *
 * The two are therefore kept separate on the strength of `exclude` alone, and this class is what
 * says so out loud instead of a doc sentence nothing checks.
 */
class InnermostScopeSpanParityTest extends Test {

	/** The character opening a method body — a literal kept out of interpolation, which cannot nest a brace. */
	private static inline final BODY_OPEN: String = '{';

	/**
	 * Every scope-opening spelling the Haxe grammar has, in one class: a type body, a method, a
	 * block statement, a local function, an inline local function, an anonymous and a named
	 * function expression, all three lambda spellings, both loop forms and a catch clause.
	 */
	private static final SCOPE_ZOO: String = 'class C {\n\tfunction f(p:Int):Void {\n\t\t{ var inBlock:Int = p; trace(inBlock); }\n'
		+ '\t\tfunction local(a:Int):Int return a;\n\t\tinline function localInline(b:Int):Int return b;\n'
		+ '\t\tvar anon = function(c:Int):Int return c;\n\t\tvar named = function nn(d:Int):Int return '
		+ 'd;\n\t\tvar thin = e -> e + 1;\n\t\tvar thinParen = (g:Int) -> g + 1;\n'
		+ '\t\tvar paren = (h:Int) -> { return h; };\n\t\tfor (i in [1]) trace(i);\n\t\tvar comp = [for ('
		+ 'j in [1]) j];\n\t\ttry trace(local(localInline(anon(named(thin(thinParen(paren(comp[0])))))))) '
		+ 'catch (ex:String) trace(ex);\n\t}\n}';

	/** A local function declaration whose own frame is what the `exclude` parameter drops. */
	private static final LOCAL_FN: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g():Void trace(1);\n\t\tg();\n\t}\n}';

	/**
	 * At EVERY offset of the scope zoo, with `exclude` null, the two walks return the same span.
	 * The loop is over every byte rather than over sampled positions on purpose: a tie-break that
	 * fired anywhere in the fixture would land on some offset, and a hand-picked set of offsets is
	 * exactly what would miss it.
	 */
	@:access(anyparse.check.BindingScope)
	@:access(anyparse.query.Rename)
	public function testTheTwoWalksAgreeWhereverExcludeIsNull(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SCOPE_ZOO);
		final kinds: Array<String> = plugin.refShape().scopeKinds;
		var compared: Int = 0;
		for (pos in 0...SCOPE_ZOO.length) {
			final byBindingScope: Null<Span> = BindingScope.innermostSpanOfKinds(tree, kinds, pos, null);
			final byRename: Null<Span> = Rename.innermostOfKinds(tree, pos, kinds)?.span;
			Assert.equals(describe(byBindingScope), describe(byRename), 'the two walks disagree at offset $pos');
			if (byBindingScope != null) compared++;
		}
		Assert.isTrue(compared > 0, 'the fixture must put at least one offset inside a scope');
	}

	/**
	 * `exclude` is the one difference the callers actually exercise: asked from a local function's
	 * own declaration offset, `Rename`'s walk answers that function's frame while `BindingScope`
	 * answers the body it is declared in — which is the frame the NAME `g` binds into. Both halves
	 * are asserted in one comparison so neither can be satisfied alone.
	 */
	@:access(anyparse.query.Rename)
	public function testOnlyBindingScopeDropsTheFrameDeclaredAtThePosition(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(LOCAL_FN);
		final shape: RefShape = plugin.refShape();
		final declFrom: Int = LOCAL_FN.indexOf('function g');
		Assert.isTrue(declFrom > 0, 'the fixture must declare a local function');
		final own: Null<Span> = Rename.innermostOfKinds(tree, declFrom, shape.scopeKinds)?.span;
		final enclosing: Null<Span> = BindingScope.enclosingScopeSpan(tree, shape.scopeKinds, declFrom, shape);
		final bodyOpen: Int = LOCAL_FN.indexOf(BODY_OPEN, LOCAL_FN.indexOf('function f'));
		Assert.equals(
			'Rename=$declFrom BindingScope=$bodyOpen',
			'Rename=${own == null ? -1 : own.from} BindingScope=${enclosing == null ? -1 : enclosing.from}'
		);
	}

	/**
	 * The tie-break IS observable — on a kind pair that co-starts. A bare `e -> e + 1` spells its
	 * parameter as a `Required` node whose span starts exactly where the `ThinArrow` does, so a
	 * lookup over both kinds at that offset has two matches sharing a start: `BindingScope`
	 * answers the outer lambda, `Rename` the inner parameter. This is the fixture the doc sentence
	 * never had.
	 */
	@:access(anyparse.check.BindingScope)
	@:access(anyparse.query.Rename)
	public function testCoStartingNodesAreTheOneShapeTheTwoWalksDisagreeOn(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar thin = e -> e + 1;\n\t}\n}';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final kinds: Array<String> = ['ThinArrow', 'Required'];
		final at: Int = source.indexOf('e -> e');
		final outer: Null<Span> = BindingScope.innermostSpanOfKinds(tree, kinds, at, null);
		final inner: Null<Span> = Rename.innermostOfKinds(tree, at, kinds)?.span;
		Assert.equals('ThinArrow', describeKind(tree, outer), 'BindingScope keeps the OUTER of two co-starting matches');
		Assert.equals('Required', describeKind(tree, inner), 'Rename keeps the INNER of two co-starting matches');
	}

	/**
	 * …and the grammar's own `scopeKinds` vocabulary never puts two of its nodes at the same
	 * start, which is why the tie-break above cannot reach either module's real callers. A
	 * grammar change that breaks this is exactly the moment the two walks stop being
	 * interchangeable, and it fails here rather than silently moving one caller's answer.
	 */
	public function testNoTwoScopeNodesShareASpanStart(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SCOPE_ZOO);
		final kinds: Array<String> = plugin.refShape().scopeKinds;
		final starts: Array<Int> = [];
		final collisions: Array<String> = [];
		collectScopeStarts(tree, kinds, starts, collisions);
		Assert.equals('', collisions.join(', '), 'two scope nodes share a span start');
		Assert.isTrue(starts.length > 5, 'the fixture must open several scopes');
	}

	/** Accumulate every `kinds` node's `span.from`, recording a kind pair for each repeat. */
	private static function collectScopeStarts(node: QueryNode, kinds: Array<String>, starts: Array<Int>, collisions: Array<String>): Void {
		final span: Null<Span> = node.span;
		if (span != null && kinds.contains(node.kind)) {
			if (starts.contains(span.from)) collisions.push('${node.kind}@${span.from}');
			starts.push(span.from);
		}
		for (c in node.children) collectScopeStarts(c, kinds, starts, collisions);
	}

	/** `span` as `from-to`, or `none`. */
	private static function describe(span: Null<Span>): String {
		return span == null ? 'none' : '${span.from}-${span.to}';
	}

	/** The kind of the node whose span is exactly `span`, or `none`. */
	private static function describeKind(tree: QueryNode, span: Null<Span>): String {
		if (span == null) return 'none';
		final s: Span = span;
		final hit: Null<QueryNode> = nodeAtSpan(tree, s);
		return hit == null ? 'none' : hit.kind;
	}

	/** The first node in pre-order whose span equals `span`. */
	private static function nodeAtSpan(node: QueryNode, span: Span): Null<QueryNode> {
		final own: Null<Span> = node.span;
		if (own != null && own.from == span.from && own.to == span.to) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = nodeAtSpan(c, span);
			if (hit != null) return hit;
		}
		return null;
	}

}

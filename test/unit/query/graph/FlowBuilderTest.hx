package unit.query.graph;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.ShapeVocab;
import anyparse.query.graph.FlowBuilder;
import anyparse.query.graph.FlowGraph;

/**
 * `FlowBuilder` — the control-flow chart of one function body: consecutive declarations folded into one node, an `if`
 * leaving by `yes` and `no`, a loop by `body` and `done` with `break` and `continue` as edges, a `switch` by one edge per
 * arm, a `try` reaching its catches, `return` and `throw` ending a path, and what follows them left undrawn.
 */
@:nullSafety(Strict)
class FlowBuilderTest extends Test {

	/** A run of declarations is one node and a run of plain statements another; a declaration after statements starts a new node. */
	@:killer('M-FLOW-RUN-UNFOLDED')
	@:pin('control')
	public function testRunsOfOneKindFoldIntoOneNode(): Void {
		Assert.equals(
			'n0 start start|n1 declarations var a1 = 1 / var b = 2|n2 steps trace(a) / trace(b)|n3 declarations final c = 3|n4 end end'
			+ ' # n0>n1 n1>n2 n2>n3 n3>n4',
			render('var a1 = 1; var b = 2; trace(a); trace(b); final c = 3;')
		);
	}

	/** A run past three statements names three and counts the rest. */
	public function testALongRunCountsTheRest(): Void {
		Assert.equals(
			'n1 declarations var a1 = 1 / var b = 2 / var c = 3 / … +2 more',
			nodes('var a1 = 1; var b = 2; var c = 3; var d = 4; var e = 5;')[1]
		);
	}

	/** An `if` with an `else` leaves by `yes` and `no` and both ends meet at the next statement. */
	@:killer('M-FLOW-NO-EDGE-LOST')
	@:pin('control')
	public function testIfJoinsItsBranches(): Void {
		Assert.equals(
			'n0 start start|n1 decision a > 0|n2 steps trace(1)|n3 steps trace(2)|n4 steps trace(3)|n5 end end'
			+ ' # n0>n1 n1-yes>n2 n1-no>n3 n2>n4 n3>n4 n4>n5',
			render('if (a > 0) { trace(1); } else { trace(2); } trace(3);')
		);
	}

	/** An `if` without an `else` that returns leaves the `no` edge to the next statement, and the `return` to the end. */
	public function testAnEarlyReturnLeavesOnlyTheOtherBranch(): Void {
		Assert.equals(
			'n0 start start|n1 decision a < 0|n2 return return 0|n3 steps trace(a)|n4 end end # n0>n1 n1-yes>n2 n1-no>n3 n3>n4 n2>n4',
			render('if (a < 0) return 0; trace(a);')
		);
	}

	/** A loop leaves by `body` and `done`; its body returns to the header, `continue` too, and `break` goes on past the loop. */
	@:killer('M-FLOW-LOOP-JUMPS-LOST')
	@:pin('control')
	public function testLoopJumpsAreEdges(): Void {
		Assert.equals(
			'n0 start start|n1 loop while (a > 0)|n2 decision a == 5|n3 break break|n4 decision a == 3|n5 continue continue'
			+ '|n6 steps a--|n7 steps trace(a)|n8 end end'
			+ ' # n0>n1 n1-body>n2 n2-yes>n3 n2-no>n4 n4-yes>n5 n5>n1 n4-no>n6 n6>n1 n1-done>n7 n3>n7 n7>n8',
			render('while (a > 0) { if (a == 5) break; if (a == 3) continue; a--; } trace(a);')
		);
	}

	/** A `do … while` runs its body first and tests after it, the test leading back by `again` and on by `done`. */
	public function testDoWhileTestsAfterItsBody(): Void {
		Assert.equals(
			'n0 start start|n1 loop do|n2 steps a--|n3 decision while a > 0|n4 steps trace(a)|n5 end end'
			+ ' # n0>n1 n1>n2 n2>n3 n3-again>n1 n3-done>n4 n4>n5',
			render('do { a--; } while (a > 0); trace(a);')
		);
	}

	/** A `switch` leaves by one edge per arm, labelled by the arm's own text with its guard; an empty arm goes straight on. */
	@:killer('M-FLOW-SWITCH-ARM-LABEL')
	@:pin('control')
	public function testSwitchArmsAreLabelledEdges(): Void {
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 steps trace(1)|n3 steps trace(2)|n4 steps trace(4)|n5 end end'
			+ ' # n0>n1 n1-case 1>n2 n1-case 2, 3 if (a > 0)>n3 n2>n4 n3>n4 n1-default>n4 n4>n5',
			render('switch (a) { case 1: trace(1); case 2, 3 if (a > 0): trace(2); default: } trace(4);')
		);
	}

	/**
	 * A `throw` in a `try` reaches the catch and not the end; a `throw`
	 * past it reaches the end; the `try` reaches its catch by `error`.
	 */
	@:killer('M-FLOW-THROW-SKIPS-CATCH')
	@:pin('control')
	public function testThrowReachesTheCatchOfItsTry(): Void {
		Assert.equals(
			"n0 start start|n1 try try|n2 catch catch (e: String)|n3 throw throw 'x'|n4 steps trace(e)|n5 throw throw 'y'|n6 end end"
			+ ' # n0>n1 n1-error>n2 n1>n3 n3>n2 n2>n4 n4>n5 n5>n6',
			render("try { throw 'x'; } catch (e: String) { trace(e); } throw 'y';")
		);
	}

	/** A statement after a `return` is not drawn. */
	public function testDeadCodeIsNotDrawn(): Void {
		Assert.equals('n0 start start|n1 return return 1|n2 end end # n0>n1 n1>n2', render('return 1; trace(2);'));
	}

	/** A declaration with no body has no chart. */
	public function testABodylessDeclarationHasNoChart(): Void {
		final source: String = 'interface I { function g(): Void; }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final fn: Null<QueryNode> = find(plugin.parseFile(source), ShapeVocab.functionLikeKinds(shape));
		Assert.notNull(fn);
		Assert.isNull(fn == null ? null : FlowBuilder.build(fn, 'I.g', shape, source, plugin.lexicalRegions(source)));
	}

	/**
	 * A switch with no catch-all arm leaves by `no match` too, so the code
	 * after it is reached; `default` and `case _` leave by their arm alone.
	 */
	@:killer('M-FLOW-SWITCH-NO-MATCH-LOST')
	@:pin('control')
	public function testASwitchWithoutACatchAllMayMatchNothing(): Void {
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 return return 1|n3 return return 2|n4 return return 3|n5 end end'
			+ ' # n0>n1 n1-case 1>n2 n1-case 2>n3 n1-no match>n4 n2>n5 n3>n5 n4>n5',
			render('switch (a) { case 1: return 1; case 2: return 2; } return 3;')
		);
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 steps trace(1)|n3 steps trace(2)|n4 end end'
			+ ' # n0>n1 n1-case 1>n2 n2>n3 n1-no match>n3 n3>n4',
			render('switch (a) { case 1: trace(1); } trace(2);')
		);
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 steps trace(1) / trace(2)|n3 end end # n0>n1 n1-case _>n2 n2>n3',
			render('switch (a) { case _: trace(1); } trace(2);')
		);
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 return return 1|n3 end end # n0>n1 n1-default>n2 n2>n3',
			render('switch (a) { default: return 1; } return 2;')
		);
	}

	/** A body written as one expression, or after `untyped`, is walked like a block: its `return` and `if` are drawn. */
	@:killer('M-FLOW-BODY-CHILDREN')
	@:pin('control')
	public function testEveryBodyKindIsWalked(): Void {
		Assert.equals(
			'n0 start start|n1 return return 1|n2 end end # n0>n1 n1>n2', renderIn('class C { static function f(a: Int): Int return 1; }')
		);
		Assert.equals(
			'n0 start start|n1 decision a > 0|n2 return return 1|n3 return return 2|n4 end end # n0>n1 n1-yes>n2 n1-no>n3 n2>n4 n3>n4',
			renderIn('class C { static function f(a: Int) if (a > 0) return 1; else return 2; }')
		);
		Assert.equals(
			'n0 start start|n1 decision a > 0|n2 return return 1|n3 return return 2|n4 end end # n0>n1 n1-yes>n2 n1-no>n3 n2>n4 n3>n4',
			renderIn('class C { static function f(a: Int) untyped { if (a > 0) return 1; return 2; } }')
		);
	}

	/**
	 * A body under conditional compilation holds alternatives, so it is
	 * ONE plain statement and no `#else` body is run after the `#if` one.
	 */
	@:killer('M-FLOW-COND-BODY-SEQUENCED')
	@:pin('control')
	public function testAConditionalBodyIsOnePlainStatement(): Void {
		Assert.equals(
			'n0 start start|n1 steps #if js { a(); } #else { b(); } #end|n2 end end # n0>n1 n1>n2',
			renderIn('class C { static function f() #if js { a(); } #else { b(); } #end }')
		);
		Assert.equals(
			'n0 start start|n1 steps #if js { return 1; } #else { return 2; } #end|n2 end end # n0>n1 n1>n2',
			renderIn('class C { static function f() #if js { return 1; } #else { return 2; } #end }')
		);
	}

	/** An arm under conditional compilation is no arm node, and still leaves the switch by an edge of its own text. */
	@:killer('M-FLOW-COND-ARM-DROPPED')
	@:pin('control')
	public function testAConditionalArmIsNotDropped(): Void {
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 return return 1|n3 steps #if js case 2: return 2; #end|n4 return return 0|n5 end end'
			+ ' # n0>n1 n1-case 1>n2 n1-#if js case 2: return 2; #end>n3 n1-default>n4 n3>n5 n2>n5 n4>n5',
			render('switch (a) { case 1: return 1; #if js case 2: return 2; #end default: return 0; }')
		);
	}

	/** A `throw`, `break` or `continue` written without its semicolon is read as the exit it is. */
	@:killer('M-FLOW-EXPR-EXIT-UNWRAPPED')
	@:pin('control')
	public function testExpressionFormExitsAreRead(): Void {
		Assert.equals(
			"n0 start start|n1 decision a > 0|n2 throw throw 'a'|n3 steps trace(1) / trace(2)|n4 end end"
			+ ' # n0>n1 n1-yes>n2 n1-no>n3 n3>n4 n2>n4',
			render("if (a > 0) throw 'a' else trace(1); trace(2);")
		);
		Assert.equals(
			'n0 start start|n1 loop for (x in xs)|n2 decision x > 0|n3 break break|n4 continue continue|n5 steps trace(3)|n6 end end'
			+ ' # n0>n1 n1-body>n2 n2-yes>n3 n2-no>n4 n4>n1 n1-done>n5 n3>n5 n5>n6',
			render('for (x in xs) if (x > 0) break else continue; trace(3);')
		);
	}

	/** A `do … while` whose body always leaves has no test and no tail; a `continue` in the body reaches the test. */
	@:killer('M-FLOW-DO-TEST-DEAD')
	@:pin('control')
	public function testADoLoopOnlyDrawsATestItsBodyReaches(): Void {
		Assert.equals(
			'n0 start start|n1 loop do|n2 return return 1|n3 end end # n0>n1 n1>n2 n2>n3',
			render('do { return 1; } while (a > 0); trace(2);')
		);
		Assert.equals(
			'n0 start start|n1 loop do|n2 decision a > 0|n3 continue continue|n4 return return 1|n5 decision while a < 5|n6 steps '
			+ 'trace(2)|n7 end end # n0>n1 n1>n2 n2-yes>n3 n2-no>n4 n3>n5 n5-again>n1 n5-done>n6 n6>n7 n4>n7',
			render('do { if (a > 0) continue; return 1; } while (a < 5); trace(2);')
		);
	}

	/** A comment in an arm, a loop header or a statement is no part of the label. */
	@:killer('M-FLOW-COMMENT-IN-LABEL')
	@:pin('control')
	public function testCommentsStayOutOfLabels(): Void {
		Assert.equals(
			'n0 start start|n1 switch switch a|n2 return return 3|n3 loop while (a > 0)|n4 steps a--|n5 end end'
			+ ' # n0>n1 n1-case []>n2 n1-default>n3 n3-body>n4 n4>n3 n3-done>n5 n2>n5',
			render('switch (a) { case []: // note\n return 3; default: }\n while (a > 0 /* note */) // note\n a--;')
		);
	}

	/** The chart of the function whose body is `body`; empty when the body is not drawn. */
	private static function chart(body: String): FlowGraph {
		return chartIn('class C { static function f(a: Int, xs: Array<Int>): Int { $body } }');
	}

	/** The chart of the first function in `source`. */
	private static function chartIn(source: String): FlowGraph {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final fn: Null<QueryNode> = find(plugin.parseFile(source), ShapeVocab.functionLikeKinds(shape));
		final built: Null<FlowGraph> = fn == null ? null : FlowBuilder.build(fn, 'C.f', shape, source, plugin.lexicalRegions(source));
		return built ?? new FlowGraph('none');
	}

	/** The chart of `body` as `<node>|<node> # <edge> <edge>`, a node `<id> <kind> <label>` and an edge `<from>[-<label>]><to>`. */
	private static function render(body: String): String {
		return describe(chart(body));
	}

	private static function renderIn(source: String): String {
		return describe(chartIn(source));
	}

	private static function describe(g: FlowGraph): String {
		final edges: Array<String> = g.edges().map(e -> '${e.from}${e.label == null ? '' : '-' + e.label}>${e.to}');
		return '${nodeLines(g).join('|')} # ${edges.join(' ')}';
	}

	private static function nodeLines(g: FlowGraph): Array<String> {
		return g.nodes().map(n -> '${n.id} ${n.kind} ${n.label.split('\n').join(' / ')}');
	}

	private static function nodes(body: String): Array<String> {
		return nodeLines(chart(body));
	}

	private static function find(node: QueryNode, kinds: Array<String>): Null<QueryNode> {
		if (kinds.contains(node.kind)) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = find(c, kinds);
			if (found != null) return found;
		}
		return null;
	}

}

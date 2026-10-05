package anyparse.check;

import anyparse.check.AssignmentTreeHoist.LvalueRef;
import anyparse.check.AssignmentTreeHoist.TreeSeams;
import anyparse.check.AssignmentTreeHoist.UnitValue;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SourceText;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

/**
 * A single-variable mutable declaration whose initializer is the implicit `else` of the
 * ELSE-LESS assignment chain that IMMEDIATELY follows it:
 *
 * ```haxe
 * var lineArray:Array<GridLine> = null;
 * if (id == 'h') lineArray = vertical;
 * else if (id == 'v') lineArray = horizontal;
 * // ->
 * var lineArray:Array<GridLine> = if (id == 'h') vertical else if (id == 'v') horizontal else null;
 * ```
 *
 * The DECL arm of `prefer-if-expression-assignment` (two or more branches, or one branch that is
 * a nested `switch` / `if` construct) and of `prefer-ternary-assignment` (one plain-assignment
 * branch: `var x:T = c ? a : init;`). This class is the ONE predicate both arms ask, so the two
 * cannot drift apart; `ownedByTernary` splits the sites between them. The `var` keyword is kept:
 * the `var` -> `final` upgrade is `prefer-final`'s, as for `prefer-try-expression-assignment`.
 *
 * Every gate is a POSITIVE condition the site must meet:
 *
 * - the declaration is a single-declarator (`var a, b;` refused) mutable local
 *   (`mutableLocalDeclKinds`) WITH an initializer and an explicit `:Type` annotation
 *   (`TypeInfoProvider.declaredTypeSources`). The annotation is load-bearing, measured with the
 *   compiler: an annotated declaration types every branch value against the written type, exactly
 *   as the `x = v;` it replaces did, while an unannotated one is typed from the if-expression's
 *   unified type instead of from its first write — `var x = 1; if (c) x = (1:UInt);` is `Int`
 *   where `var x = c ? (1:UInt) : 1;` is `UInt`, and `var x = null; if (c) x = a; else if (d)
 *   x = b;` (`B extends A`) compiles as `Null<A>` where the collapsed form does not compile at
 *   all (`A should be Null<Null<B>>`);
 * - the initializer is RELOCATABLE (`MemberKinds.isMovableLiteral`: a constant literal, `null`,
 *   or a negated number). It used to evaluate BEFORE every condition and now evaluates after them,
 *   on the fallback path only, so it must read nothing a condition could change and do nothing a
 *   condition could observe. A field read, a local, a call or an allocation is refused — a
 *   condition calling a method that writes that field is all it takes;
 * - the declaration and the chain are ADJACENT statements of one statement list
 *   (`ControlFlowSupport.blockKinds`) — a statement between would be reordered, and a
 *   conditional-compilation region between them is a `Conditional` sibling, so it splits the pair;
 * - the chain has NO final `else` (`IfExpressionChain.collectElseLess`; one that has one is the
 *   rules' ordinary arm) and every branch is a hoistable unit (`AssignmentTreeHoist`) assigning
 *   the BARE declared identifier with a plain `=` — the same unit, else-less and comment rules as
 *   the rules' ordinary arm (`AssignmentTreeHoist.fallbackChainValue`);
 * - every occurrence of the name inside the chain is one of those assignments' own l-values
 *   (`Refs`, scope-resolved): after the collapse the chain IS the initializer, so a read in a
 *   condition or a value, a capture by a closure, a nested write or a same-named binding would
 *   all name a variable that does not exist yet;
 * - the copied declaration prefix carries no dangling line comment, and no comment sits in a
 *   region the rebuild drops (each rule's own comment handling).
 *
 * The parse is the PLAIN projection, as for the rules' ordinary arm: a pair inside one `#if`
 * branch is a safe miss rather than a reach through the region.
 */
@:nullSafety(Strict)
final class DeclFallbackChain {

	/** Bundle the kinds the decl arm reads, or null when one is unset (the arm is then a no-op). */
	public static function readSeams(plugin: GrammarPlugin, tree: Null<TreeSeams>): Null<DeclSeams> {
		final shape: RefShape = plugin.refShape();
		final mutableKinds: Null<Array<String>> = shape.mutableLocalDeclKinds;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final ifKinds: Null<Array<String>> = tree?.ifKinds;
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		// Split, not `||`-chained: strict null-safety narrows a later `||` operand by the FIRST operand only.
		if (tree == null || ifKinds == null || mutableKinds == null) return null;
		if (ifKinds.length == 0 || mutableKinds.length == 0) return null;
		return support == null || typed == null ? null : {
			tree: tree,
			ifKinds: ifKinds,
			mutableKinds: mutableKinds,
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			blockKinds: support.blockKinds(),
			typed: typed,
			shape: shape
		};
	}

	/** Every declaration + else-less chain pair under `tree` that meets the gates, in document order. */
	public static function collect(
		tree: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: DeclSeams
	): Array<DeclChain> {
		final types: Map<Int, String> = s.typed.declaredTypeSources(source);
		final out: Array<DeclChain> = [];
		function walk(node: QueryNode): Void {
			if (s.blockKinds.contains(node.kind)) {
				final kids: Array<QueryNode> = node.children;
				for (i in 1...kids.length) {
					final m: Null<DeclChain> = match(kids[i - 1], kids[i], source, types, comments, s);
					if (m != null) out.push(m);
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** Whether `prefer-ternary-assignment` owns `m`: ONE branch, a plain assignment — two values, the initializer's included. */
	public static function ownedByTernary(m: DeclChain, s: DeclSeams): Bool {
		return m.branches.length == 1 && AssignmentTreeHoist.plainAssign(m.branches[0].stmt, s.tree) != null;
	}

	/** The pair `decl` + `head` when it meets every gate of the class doc, else null. */
	private static function match(
		decl: QueryNode, head: QueryNode, source: String, types: Map<Int, String>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: DeclSeams
	): Null<DeclChain> {
		if (!s.mutableKinds.contains(decl.kind) || decl.children.length != 1 || !s.ifKinds.contains(head.kind)) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final headSpan: Null<Span> = head.span;
		if (name == null || declSpan == null || headSpan == null) return null;
		if (SourceText.isMultiDeclarator(decl, s.continuationKinds) || !types.exists(declSpan.from)) return null;
		final init: QueryNode = decl.children[0];
		if (!MemberKinds.isMovableLiteral(init, s.shape)) return null;
		final branches: Null<Array<{ cond: QueryNode, stmt: QueryNode }>> = IfExpressionChain.collectElseLess(
			head, s.ifKinds, s.tree.blockStmtKind
		);
		if (branches == null) return null;
		final ref: LvalueRef = { lvalue: null };
		final probe: Null<UnitValue> = AssignmentTreeHoist.fallbackChainValue(branches, init, ref, source, s.tree);
		final lvalue: Null<QueryNode> = ref.lvalue;
		if (probe == null || lvalue == null) return null;
		if (lvalue.kind != s.tree.identKind || lvalue.name != name) return null;
		// Each leaf's l-value is the bare name (above), one hit apiece, so any further hit is another occurrence: a read, a
		// capture, a nested write, a shadowing declaration.
		if (Refs.find(name, head, s.shape).length != probe.leafCount) return null;
		final prefix: Null<{ text: String, keptTo: Int }> = AssignmentTreeHoist.declPrefix(declSpan, init, source);
		if (prefix == null) return null;
		// The prefix is copied in front of ` = <value>;`, so a line comment ending it would swallow the value.
		if (TryExpressionShape.danglingLineComment(source, new Span(declSpan.from, declSpan.from + prefix.text.length), comments))
			return null;
		return {
			declSpan: declSpan,
			init: init,
			branches: branches,
			prefix: prefix,
			region: new Span(declSpan.from, headSpan.to),
			probe: probe
		};
	}

}

/** The kinds `DeclFallbackChain` reads. */
typedef DeclSeams = {
	var tree: TreeSeams;
	var ifKinds: Array<String>;
	var mutableKinds: Array<String>;
	var continuationKinds: Array<String>;
	var blockKinds: Array<String>;
	var typed: TypeInfoProvider;
	var shape: RefShape;
}

/**
 * A matched pair: the declaration's span (the finding key), its relocated initializer, the chain's
 * branches, the declaration prefix (`var x:T`, and where its copied source ends), the replaced
 * region (the declaration through the chain), and the first-pass if-expression value.
 */
typedef DeclChain = {
	var declSpan: Span;
	var init: QueryNode;
	var branches: Array<{ cond: QueryNode, stmt: QueryNode }>;
	var prefix: { text: String, keptTo: Int };
	var region: Span;
	var probe: UnitValue;
}

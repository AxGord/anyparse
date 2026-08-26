package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * Slice 2C probe — verifies `HaxeQueryPlugin.parsePattern` correctly:
 *  - parses the pattern via the try-fallback decl/stmt/expr cascade,
 *  - reclassifies `$X` / `$_` placeholders as `kind='Metavar'`
 *    QueryNodes with the bare name extracted,
 *  - reports the correct `category` per the wrapping that succeeded.
 *
 * Exercises Q4-Q7 from `docs/cli-query-phase0-queries.md` plus a few
 * variants that stress wildcard independence and metavar reuse.
 */
class PatternParseProbe extends Test {

	public function testQ4ConditionalNullGuardedCall(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("if ($x != null) return $x.$f($_)");
		Assert.equals(PatternCategory.Stmt, pattern.category);
		Assert.equals('IfStmt', pattern.root.kind);
		final names: Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('x'), 'pattern must bind $$x — got ${names.join(',')}');
		Assert.isTrue(names.contains('f'), 'pattern must bind $$f');
		Assert.isTrue(names.contains('_'), 'pattern must include a wildcard');
		// `$x` reuses must produce two Metavar nodes with name `x`.
		final xs: Int = countMetavarByName(pattern.root, 'x');
		Assert.equals(2, xs, '$$x must appear twice in pattern AST — got $xs');
	}

	public function testQ6ThrowNewException(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("throw new $E($_)");
		Assert.equals(PatternCategory.Stmt, pattern.category);
		final names: Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('E'), 'pattern must bind $$E — got ${names.join(',')}');
		Assert.isTrue(names.contains('_'), 'pattern must include wildcard arg');
	}

	public function testLiteralOnlyPatternHasNoMetavars(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern('return null');
		final names: Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.equals(0, names.length, 'literal-only pattern must have no metavars — got ${names.join(',')}');
	}

	public function testDollarInsideStringNotSubstituted(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("var $name = 'hello $x'");
		// `$name` outside quotes IS a metavar; `$x` inside single-quoted
		// string is Haxe interp — must NOT be reclassified.
		final names: Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('name'), 'outside-string $$name must be a metavar');
		Assert.isFalse(names.contains('x'), 'inside-string $$x must NOT be a metavar — got ${names.join(',')}');
	}

	public function testStmtPatternWithTrailingSemicolon(): Void {
		// `return $_;` — a statement pattern written the natural way, with
		// its closing `;`. Before the trim fix `wrapAsStmt` produced `…;;`
		// (no empty-statement production in the Haxe grammar) so every
		// cascade attempt failed and the misleading decl error leaked.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("return $_;");
		Assert.equals(PatternCategory.Stmt, pattern.category);
		Assert.equals('ReturnStmt', pattern.root.kind);
		final names: Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('_'), 'pattern must include the wildcard — got ${names.join(',')}');
	}

	public function testStmtPatternWithoutSemicolonStillParses(): Void {
		// Regression guard: the trim must not break the already-working
		// no-trailing-`;` form.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("return $_");
		Assert.equals(PatternCategory.Stmt, pattern.category);
		Assert.equals('ReturnStmt', pattern.root.kind);
	}

	public function testExprPatternWithTrailingSemicolon(): Void {
		// `trace($_);` — a call written as a statement. The Stmt attempt
		// parses it but its first statement is a synthetic `ExprStmt`
		// wrapper; per the S1 fix the Stmt extractor rejects a bare
		// `ExprStmt` so the cascade falls to the Expr attempt. The pattern
		// is therefore an Expr rooted at the bare `Call` — matchable at
		// every subtree (incl. argument / sub-expression position), not
		// only statement position.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("trace($_);");
		Assert.equals(PatternCategory.Expr, pattern.category);
		Assert.equals('Call', pattern.root.kind);
		final names: Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('_'), 'pattern must include the wildcard arg — got ${names.join(',')}');
	}

	public function testBareExpressionPatternIsNotStmtWrapped(): Void {
		// S1 red-green: a bare expression pattern (`$x + $x`) must NOT
		// resolve to an `ExprStmt`-rooted Stmt pattern. The synthetic
		// `ExprStmt` wrapper only unifies in statement position, so real
		// `+` expressions in var-init / argument / sub-expression position
		// (the common case) are invisible to `apq search`. The Stmt
		// extractor rejects the bare `ExprStmt` and the cascade falls to
		// the Expr attempt: category Expr, root the bare `Add`, which
		// `Matcher.walk` then finds at every subtree.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("$x + $x");
		Assert.equals(PatternCategory.Expr, pattern.category);
		Assert.equals('Add', pattern.root.kind);
		final xs: Int = countMetavarByName(pattern.root, 'x');
		Assert.equals(2, xs, '$$x must appear twice in pattern AST — got $xs');
	}

	public function testRealStatementPatternStaysStmt(): Void {
		// S1 regression guard: the bare-`ExprStmt` rejection must NOT
		// affect non-expression statements. `if`/`return` are not
		// `ExprStmt`, so they still resolve via the Stmt attempt.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final ifPat: Pattern = plugin.parsePattern("if ($_) return $_");
		Assert.equals(PatternCategory.Stmt, ifPat.category);
		Assert.equals('IfStmt', ifPat.root.kind);
		final retPat: Pattern = plugin.parsePattern("return $_;");
		Assert.equals(PatternCategory.Stmt, retPat.category);
		Assert.equals('ReturnStmt', retPat.root.kind);
	}

	public function testInvalidPatternRaisesClearError(): Void {
		// `switch $_ { $_ }` is not valid Haxe in any position (a switch
		// body needs `case`). The cascade must still reject it, but with
		// an actionable message — not the leaked decl-attempt internal
		// `expected HxDecl at 0`.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parsePattern("switch $_ { $_ }");
			Assert.fail('invalid pattern must throw');
		} catch (exception: Exception) {
			final message: String = exception.message;
			Assert.isTrue(message.indexOf('not valid') >= 0, 'clear message expected — got: $message');
			Assert.isTrue(message.indexOf('expected HxDecl') < 0, 'must not leak parser-internal error — got: $message');
		}
	}

	public function testArgumentlessNewKeepsItsConstructorKind(): Void {
		// A metavar in a NAME slot must not swallow its own node when that node is
		// childless. `new $x()` used to reclassify wholesale into a lone `Metavar`,
		// which matches EVERY node: `final $n:$t = new $x();` and the shapeless
		// `final $n = $v;` both returned 7781 hits over TM's src.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("new $x()");
		Assert.equals('NewExpr', pattern.root.kind, 'argumentless new must keep its kind - got ${pattern.root.kind}');
		Assert.equals("$x", pattern.root.name);
	}

	public function testDeclarationWithArgumentlessNewKeepsTheNewConstraint(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("final $n = new $x();");
		Assert.equals('VarForm', pattern.root.kind);
		Assert.equals(1, pattern.root.children.length);
		Assert.equals('NewExpr', pattern.root.children[0].kind, 'the initializer must stay a NewExpr constraint');
	}

	public function testTypeAnnotationMetavarIsKeptInThePattern(): Void {
		// A declared type IS in the model - it rides `QueryNode.type`, a slot rather than a
		// child. The pattern rebuilds in `Metavar.reclassify` / `PatternStar.reclassify` used
		// to drop the slot, so `:$t` vanished and the search answered a WIDER question than
		// written; `ignoredMetavars` faithfully reported the loss. Both are fixed: the slot
		// survives the rebuild, `$t` binds the annotation, and nothing is reported ignored.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final annotated: Pattern = plugin.parsePattern("final $n:$t = $v;");
		Assert.equals('', annotated.ignoredMetavars.join(','), ':$$t is part of the pattern, not dropped');
		final slot: Null<QueryNode> = annotated.root.type;
		Assert.notNull(slot, 'the annotation must reach the pattern root as its type slot');
		Assert.equals("$t", slot == null ? '<null>' : slot.name);
		final plain: Pattern = plugin.parsePattern("final $n = $v;");
		Assert.equals('', plain.ignoredMetavars.join(','), 'a pattern that keeps every metavar reports none');
	}

	/** `...` reclassifies into its own `Star` kind node - not a `Metavar`, since it does not bind. */
	public function testEllipsisBecomesAStarNode(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern('g(...)');
		final children: Array<QueryNode> = pattern.root.children;
		Assert.equals('Call', pattern.root.kind);
		Assert.equals(2, children.length);
		Assert.equals(PatternStar.KIND, children[1].kind);
		Assert.isNull(children[1].name, 'a star carries no name - nothing can reference it');
		Assert.isFalse(pattern.isDegenerate(), 'a starred call still carries the callee as shape');
	}

	/** A star in a type-argument slot is the same node - the grammar projects `new Map<X>()` type args as `Named` siblings. */
	public function testEllipsisInATypeArgumentSlotIsAlsoAStar(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern("new $T<...>()");
		Assert.equals('NewExpr', pattern.root.kind);
		Assert.equals("$T", pattern.root.name);
		Assert.equals(1, pattern.root.children.length);
		Assert.equals(PatternStar.KIND, pattern.root.children[0].kind);
	}

	/** A bare `...` is the whole-tree wildcard, which is not a pattern - it is refused, not silently matched. */
	public function testBareEllipsisIsRefused(): Void {
		Assert.isTrue(refused('...'), 'a bare ellipsis must be refused');
		Assert.isTrue(refused('new ...()'), 'an ellipsis in a NAME slot must be refused');
	}

	/**
	 * Two stars in ONE child list is refused. The matcher anchors a prefix from
	 * the left and a suffix from the right around exactly one star; a second one
	 * needs backtracking, and for the position that motivates it
	 * (`new $T<...>(...)`) it would be a lie anyway - `NewExpr` flattens type
	 * args and value args into one list, so the two stars could not be told
	 * apart and the pattern would mean exactly the same as `new $T(...)`.
	 */
	public function testTwoEllipsesInOneChildListAreRefused(): Void {
		Assert.isTrue(refused('h(..., 1, ...)'), 'two stars in one argument list must be refused');
		Assert.isTrue(refused("new $T<...>(...)"), 'type-arg star + value-arg star land in ONE NewExpr child list');
	}

	/** Two stars in DIFFERENT child lists are fine - each list anchors independently. */
	public function testTwoEllipsesInDifferentChildListsAreAccepted(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern('h(..., k(...))');
		Assert.equals('Call', pattern.root.kind);
	}

	/** A star is not a metavariable: it never appears in `ignoredMetavars`, and it never shows up as a `$` name. */
	public function testStarIsNotReportedAsAnIgnoredMetavar(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals('', plugin.parsePattern('g(...)').ignoredMetavars.join(','));
		Assert.equals('', plugin.parsePattern("final $n:$t = g(...);").ignoredMetavars.join(','));
	}

	/** True when `parsePattern` refuses `source` outright. */
	private static function refused(source: String): Bool {
		try {
			new HaxeQueryPlugin().parsePattern(source);
			return false;
		} catch (_: Exception)
			return true;
	}

	private static function collectMetavarNames(node: QueryNode, into: Array<String>): Void {
		if (node.kind == Metavar.KIND) {
			final n: Null<String> = node.name;
			if (n != null) into.push(n);
		}
		final n2: Null<String> = node.name;
		if (n2 != null && node.kind != Metavar.KIND && StringTools.startsWith(n2, '$')) into.push(n2.substring(1));
		for (c in node.children) collectMetavarNames(c, into);
	}

	private static function countMetavarByName(node: QueryNode, target: String): Int {
		var count: Int = 0;
		if (node.kind == Metavar.KIND && node.name == target) count++;
		if (node.kind != Metavar.KIND && node.name == '$$$target') count++;
		for (c in node.children) count += countMetavarByName(c, target);
		return count;
	}

}

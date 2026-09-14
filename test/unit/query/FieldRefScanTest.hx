package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.BinderScan;
import anyparse.query.FieldRefScan;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

/**
 * `FieldRefScan` — the by-name recognizers the backing-field rewrites share, pinned against the
 * grammar's own declarations.
 *
 * Every pin here works the same way, and it is the way a DERIVATION has to be pinned: the fixture
 * is a SECOND instance of the declaration, never the declaration itself. Two kinds of second
 * instance are used, because a derivation needs both.
 *
 * The PARSER supplies the first: `FN_SCOPE_SPELLINGS`, `BINDER_SPELLINGS` and `WRITE_SPELLINGS`
 * are tables of SOURCE, and what each row projects is the grammar's answer rather than this
 * file's. Each of the three fixtures then asserts its table COVERS the vocabulary it is pinning,
 * so a grammar gaining a spelling names the kind instead of silently classifying one fewer.
 *
 * A HANDED shape supplies the second: `testTheScopeAndBinderVocabulariesFollowTheShapeTheyAreHanded`
 * names kinds no grammar projects, which is the only half a frozen list of this grammar's own ctor
 * names would fail. Every source-driven fixture above passes against a frozen list, so without that
 * one, "derived" and "copied" are indistinguishable here.
 *
 * The pin this class opened with compared `FieldRefScan.FN_SCOPE_KINDS` against
 * `MemberKinds.nestedFunctionKinds` plus `functionKinds` minus the local and module-level ones. That
 * was the right pin for a hand copy and is a TAUTOLOGY for the derivation, which is now that exact
 * expression — the reason it was replaced rather than kept.
 */
class FieldRefScanTest extends Test {

	/** The Haxe grammar's own vocabulary — the declaration every fixture here is asked against. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	/** The one name every `BINDER_SPELLINGS` row binds, so the rows differ only in the SPELLING. */
	private static final BOUND: String = 'p';

	/**
	 * One real Haxe spelling per function-scope kind — the SECOND instance the derivation is
	 * pinned against, parsed by the grammar rather than read off the same shape fields. One row is
	 * grammar-only: `() => 1` (`ParenLambdaExpr`) parses under the tolerant grammar but Haxe
	 * refuses it (`Unexpected =>`) — the same dead-vocabulary position `&&=` / `||=` hold in
	 * `WRITE_SPELLINGS`; the row stays because the PROJECTION is what the pin compares against.
	 */
	private static final FN_SCOPE_SPELLINGS: Array<{ kind: String, code: String }> = [
		{ kind: 'FnMember', code: 'function m() {}' },
		{ kind: 'FinalModifiedMember', code: 'final function m() {}' },
		{ kind: 'LocalFnStmt', code: 'function m() { function h() {} }' },
		{ kind: 'LocalInlineFnStmt', code: 'function m() { inline function h() {} }' },
		{ kind: 'FnExpr', code: 'function m() { var f = function() {}; }' },
		{ kind: 'NamedFnExpr', code: 'function m() { var f = function g() {}; }' },
		{ kind: 'ThinParenLambdaExpr', code: 'function m() { var f = () -> 1; }' },
		{ kind: 'ParenLambdaExpr', code: 'function m() { var f = () => 1; }' },
		{ kind: 'ThinArrow', code: 'function m() { var f = a -> 1; }' }
	];

	/**
	 * One real Haxe spelling per BINDER kind, each binding the same name — the second instance
	 * `BinderScan.binderKinds` is pinned against. Written as a method body, so the fixture can ask
	 * the whole-subtree question `functionBindsName` rather than the per-node one.
	 */
	private static final BINDER_SPELLINGS: Array<{ kind: String, code: String }> = [
		{ kind: 'Required', code: 'function m(p:Int) {}' },
		{ kind: 'Optional', code: 'function m(?p:Int) {}' },
		{ kind: 'Rest', code: 'function m(...p:Int) {}' },
		{ kind: 'VarStmt', code: 'var p = 1;' },
		{ kind: 'FinalStmt', code: 'final p = 1;' },
		{ kind: 'VarMore', code: 'var a = 1, p = 2;' },
		{ kind: 'VarExpr', code: '@:nullSafety(Off) var p = 1;' },
		{ kind: 'FinalExpr', code: '@:nullSafety(Off) final p = 1;' },
		{ kind: 'StaticVarStmt', code: 'static var p = 1;' },
		{ kind: 'StaticFinalStmt', code: 'static final p = 1;' },
		{ kind: 'LocalFnStmt', code: 'function p() {}' },
		{ kind: 'LocalInlineFnStmt', code: 'inline function p() {}' },
		{ kind: 'NamedFnExpr', code: 'var f = function p() {};' },
		{ kind: 'CatchClause', code: 'try {} catch (p:Dynamic) {}' },
		{ kind: 'ForStmt', code: 'for (p in xs) {}' },
		{ kind: 'ForExpr', code: 'var a = [for (p in xs) p];' },
		{ kind: 'KeyValueBinder', code: 'for (k => p in xs) {}' },
		{ kind: 'Capture', code: 'switch v { case var p: p; }' }
	];

	/**
	 * Every write operator `FieldRefScan.isWriteNodeKind` names, paired with a real Haxe
	 * spelling of it. The SECOND instance of that list — parsed by the grammar rather than
	 * read off the same array — is what makes the pin below discriminate.
	 */
	private static final WRITE_SPELLINGS: Array<{ kind: String, code: String }> = [
		{ kind: 'Assign', code: '_x = 1' },
		{ kind: 'NullCoalAssign', code: '_x ??= 1' },
		{ kind: 'AddAssign', code: '_x += 1' },
		{ kind: 'SubAssign', code: '_x -= 1' },
		{ kind: 'MulAssign', code: '_x *= 1' },
		{ kind: 'DivAssign', code: '_x /= 1' },
		{ kind: 'ModAssign', code: '_x %= 1' },
		{ kind: 'BitAndAssign', code: '_x &= 1' },
		{ kind: 'BitOrAssign', code: '_x |= 1' },
		{ kind: 'BitXorAssign', code: '_x ^= 1' },
		{ kind: 'ShlAssign', code: '_x <<= 1' },
		{ kind: 'ShrAssign', code: '_x >>= 1' },
		{ kind: 'UShrAssign', code: '_x >>>= 1' },
		{ kind: 'PreIncr', code: '++_x' },
		{ kind: 'PostIncr', code: '_x++' },
		{ kind: 'PreDecr', code: '--_x' },
		{ kind: 'PostDecr', code: '_x--' }
	];

	/**
	 * `isFnScope` answers true for every function-scope spelling the LANGUAGE has, reached by
	 * parsing real source rather than by reading the vocabulary back.
	 *
	 * The pin this replaces compared `FN_SCOPE_KINDS` against
	 * `MemberKinds.nestedFunctionKinds(shape)` plus `functionKinds` minus the local and
	 * module-level ones — the exact expression `FieldRefScan.fnScopeKinds` is now derived by, so
	 * that comparison became a tautology the moment the hand copy went away. The discriminating
	 * second instance has to come from somewhere else, and here it is the PARSER: each row names a
	 * spelling, the grammar decides what it projects, and the table has to cover the derivation.
	 *
	 * The module-level row is the exclusion the derivation encodes: `function m() {}` at module
	 * level opens a scope and is NOT one this walk may treat as re-qualifiable, because the
	 * rewrite it enables is `this.` / `C.` and neither is spellable there.
	 *
	 * CONTROL for the scope derivation. KILLED by arm `M-FN-SCOPE-KINDS-DROPS-METHODS`, which
	 * takes the METHOD half back out and leaves the function VALUES.
	 */
	@:pin('control')
	@:killer('M-FN-SCOPE-KINDS-DROPS-METHODS')
	@:access(anyparse.query.FieldRefScan)
	public function testEveryFunctionScopeSpellingIsRecognisedFromSource(): Void {
		for (spelling in FN_SCOPE_SPELLINGS) {
			final node: Null<QueryNode> = firstOfKind(parse(spelling.code), spelling.kind);
			Assert.notNull(node, 'the grammar must project ${spelling.code} as a ${spelling.kind}');
			if (node != null) Assert.isTrue(FieldRefScan.isFnScope(node, SHAPE), '${spelling.kind} must open a function scope');
		}
		final moduleFn: Null<QueryNode> = firstOfKind(new HaxeQueryPlugin().parseFile('function m() {}\n'), 'FnDecl');
		Assert.notNull(moduleFn, 'the grammar must project a module-level function');
		if (moduleFn != null)
			Assert.isFalse(
				FieldRefScan.isFnScope(moduleFn, SHAPE),
				'a module-level function declaration cannot be re-qualified with `this.` / `C.`, so it is not a scope here'
			);
		final covered: Array<String> = [for (spelling in FN_SCOPE_SPELLINGS) spelling.kind];
		final uncovered: Array<String> = FieldRefScan.fnScopeKinds(SHAPE).filter(kind -> !covered.contains(kind));
		Assert.equals('', uncovered.join(', '), 'function-scope kind(s) no spelling reaches: [${uncovered.join(', ')}]');
	}

	/**
	 * `functionBindsName` finds every binding spelling the LANGUAGE has, again from real source.
	 *
	 * The names this used to spell in a private switch are now
	 * `BinderScan.binderKinds`, derived from `RefShape` fields. Same discipline as above:
	 * the rows are SOURCE, the grammar decides what each projects, and the coverage assertion
	 * fails when the derivation gains a kind no row reaches.
	 *
	 * MISSING a binder is the wrong-rewrite direction — a bare backing-field reference silently
	 * re-binds to it — which is why this is asked of every spelling and not of a sample.
	 *
	 * CONTROL for the binder derivation. KILLED by arm `M-BINDER-KINDS-PARAMS-ONLY`.
	 */
	@:pin('control')
	@:killer('M-BINDER-KINDS-PARAMS-ONLY')
	public function testEveryBinderSpellingIsFoundFromSource(): Void {
		for (spelling in BINDER_SPELLINGS) {
			final tree: QueryNode = parse('function m2() { ${spelling.code} }');
			Assert.notNull(firstOfKind(tree, spelling.kind), 'the grammar must project ${spelling.code} as a ${spelling.kind}');
			Assert.isTrue(FieldRefScan.functionBindsName(tree, BOUND, SHAPE), '${spelling.kind} must bind $BOUND in ${spelling.code}');
		}
		Assert.isFalse(
			FieldRefScan.functionBindsName(parse('function m2() { return other; }'), BOUND, SHAPE), 'a name nothing declares is not bound'
		);
		final covered: Array<String> = [for (spelling in BINDER_SPELLINGS) spelling.kind];
		final uncovered: Array<String> = BinderScan.binderKinds(SHAPE).filter(kind -> !covered.contains(kind));
		Assert.equals('', uncovered.join(', '), 'binder kind(s) no spelling reaches: [${uncovered.join(', ')}]');
	}

	/**
	 * Both vocabularies follow the shape they are HANDED — the half every fixture above also
	 * satisfies with a FROZEN list of this grammar's own ctor names, and therefore the only one
	 * that separates a derivation from a copy.
	 *
	 * The probe shape names kinds no grammar projects, so a frozen answer gets every assertion
	 * wrong at once. The negative row is the contract the derivation encodes and a union would
	 * lose: a module-level function declaration is in `functionKinds` and in
	 * `moduleValueDeclKinds`, and the second is what excludes it.
	 *
	 * CONTROL for the derivation itself. KILLED by arm `M-FN-SCOPE-KINDS-FROZEN`, which freezes
	 * the answer to this grammar's own names — invisible to both fixtures above.
	 */
	@:pin('control')
	@:killer('M-FN-SCOPE-KINDS-FROZEN')
	@:access(anyparse.query.FieldRefScan)
	public function testTheScopeAndBinderVocabulariesFollowTheShapeTheyAreHanded(): Void {
		final probe: RefShape = new HaxeQueryPlugin().refShape();
		probe.lambdaKinds = ['NoSuchLambda'];
		probe.fnExprKind = 'NoSuchFnExpr';
		probe.namedFnExprKind = 'NoSuchNamedFn';
		probe.localFunctionKinds = ['NoSuchLocalFn'];
		probe.inlineFunctionKinds = ['NoSuchInlineFn'];
		probe.functionKinds = ['NoSuchLocalFn', 'NoSuchMethod', 'NoSuchModuleFn'];
		probe.moduleValueDeclKinds = ['NoSuchModuleFn'];
		final scopes: Array<String> = FieldRefScan.fnScopeKinds(probe);
		Assert.same([
			'NoSuchLambda',
			'NoSuchFnExpr',
			'NoSuchNamedFn',
			'NoSuchLocalFn',
			'NoSuchInlineFn',
			'NoSuchMethod'
		], scopes, 'the scope vocabulary must be the handed one: $scopes');
		Assert.isFalse(
			scopes.contains('NoSuchModuleFn'),
			'a module-level VALUE declaration is not a scope a shadowed reference can be re-qualified from'
		);
		final binders: Array<String> = BinderScan.binderKinds(probe);
		Assert.isTrue(binders.contains('NoSuchLocalFn'), 'a declared local-function kind must reach the binder vocabulary: $binders');
		Assert.isTrue(binders.contains('NoSuchInlineFn'), 'and so must the inline spelling: $binders');
		Assert.isFalse(binders.contains('LocalFnStmt'), 'while nothing of the real grammar leaks into a handed vocabulary: $binders');
	}

	/**
	 * `writeTargetField` sees the write target of every operator `isWriteNodeKind` names.
	 *
	 * The two used to carry SEPARATE copies of the same sixteen-kind list, one in each function,
	 * and nothing compared them: a kind added to one and forgotten in the other would have made
	 * the collapse silently treat a write as a read (`hasExternalRead`) or drop it from the
	 * bypass census (`collectExternalWrites`) — a wrong rewrite, not a missed one. `writeTargetField`
	 * now asks `isWriteNodeKind`, and this pin is the second half: each kind is reached from REAL
	 * source, so the shared list still has to be right rather than merely consistent.
	 */
	public function testWriteTargetFieldSeesEveryWriteOperatorSpelling(): Void {
		for (spelling in WRITE_SPELLINGS) {
			final node: QueryNode = firstWriteNode(spelling.code);
			Assert.equals(spelling.kind, node.kind, 'the grammar must spell ${spelling.code} as ${spelling.kind}');
			Assert.isTrue(FieldRefScan.isWriteNodeKind(node.kind, SHAPE), '${spelling.kind} must be a write node kind');
			Assert.equals('_x', FieldRefScan.writeTargetField(node, SHAPE), 'writeTargetField must see the target of ${spelling.code}');
		}
		final declared: Array<String> = SHAPE.writeParentKinds;
		final covered: Array<String> = [for (spelling in WRITE_SPELLINGS) spelling.kind];
		// `BoolAndAssign` / `BoolOrAssign` are the documented exception: the grammar parses `&&=`
		// and `||=` and Haxe refuses them, so no row can reach them from real source. Every
		// OTHER declared write kind must have one, which is what fails when a grammar gains an
		// operator this fixture has not been taught.
		final unreachable: Array<String> = ['BoolAndAssign', 'BoolOrAssign'];
		final uncovered: Array<String> = declared.filter(kind -> !covered.contains(kind) && !unreachable.contains(kind));
		Assert.equals('', uncovered.join(', '), 'declared write kind(s) no spelling reaches: [${uncovered.join(', ')}]');
	}

	/** A receiver other than `this` is not provably the field, in a read or in a write position. */
	public function testForeignReceiverIsNotTheField(): Void {
		Assert.equals('_x', FieldRefScan.writeTargetField(firstWriteNode('this._x = 1'), SHAPE));
		Assert.equals(null, FieldRefScan.writeTargetField(firstWriteNode('other._x = 1'), SHAPE));
		Assert.isFalse(FieldRefScan.mentionsField(firstWriteNode('other._x = 1'), '_x', SHAPE));
	}

	/**
	 * `code` as the single statement of a method body, and the expression that statement holds.
	 *
	 * Located as "the `ExprStmt`'s only child", NOT as "the first node `isWriteNodeKind` accepts":
	 * a locator that asked the predicate under test would stop FINDING the node the moment the
	 * predicate lost a kind, and the pin would die by exception instead of by its own assertion.
	 */
	private static function firstWriteNode(code: String): QueryNode {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile('class C {\n\tfunction m():Void {\n\t\t$code;\n\t}\n}');
		final stmt: Null<QueryNode> = firstOfKind(tree, 'ExprStmt');
		if (stmt == null || stmt.children.length != 1) throw 'no single-expression statement parsed out of "$code"';
		return stmt.children[0];
	}

	/** `member` as the single member of a class, parsed. */
	private static function parse(member: String): QueryNode {
		return new HaxeQueryPlugin().parseFile('class C {\n\t$member\n}');
	}

	/** The first node of `kind` in pre-order, or null. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

}

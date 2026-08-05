package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ComparisonToBoolean;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `comparison-to-boolean` check: a comparison against a boolean literal
 * (`x == true`, `x != false`, `true == x`) is flagged `Info` when the operand is
 * provably non-null Bool, and `fix` then rewrites it. Two proofs. STRUCTURAL: a
 * boolean-operator result, or a bare identifier whose declared type proves non-null
 * Bool — a `Null<Bool>` / optional-param / unannotated identifier stays silent (its
 * `== true` may be load-bearing under strict null-safety), and the arm sits behind a
 * blanket veto on an operand reaching a `?.` access / a call / `Map.get` result.
 * RESOLVED-TYPE: a field access whose receiver type resolves and whose member's
 * declared type is a non-nullable Bool, the receiver resolving through `cast(e, T)`
 * too. That arm refuses what the `SymbolIndex` cannot answer soundly — an
 * anonymous-structure receiver, a simple-name homonym, a `#if`-guarded member.
 * Comparisons inside macro reification are skipped.
 */
class ComparisonToBooleanCheckTest extends Test {

	public function testEqTrueFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x == true;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('comparison-to-boolean', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('comparison against a boolean literal', vs[0].message);
	}

	public function testNeqFalseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x != false;\n\t}\n}').length);
	}

	public function testLiteralOnLeftFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = true == x;\n\t}\n}').length);
	}

	/**
	 * A `Null<Bool>` local's `== true` is load-bearing under strict null-safety
	 * (three-state check) — the declared-type gate keeps it silent.
	 */
	public function testNullableBoolIdentSkipped(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tfinal x:Null<Bool> = g();\n\t\tvar b = x == true;\n\t}\n}').length
		);
	}

	/** An unannotated / unresolvable identifier cannot be verified non-null — silent. */
	public function testUnannotatedIdentSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = x == true;\n\t}\n}').length);
	}

	/** An optional `?x:Bool` param is nullable despite the Bool annotation — silent. */
	public function testOptionalBoolParamSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(?x:Bool):Void {\n\t\tvar b = x == true;\n\t}\n}').length);
	}

	/** A declared non-null `Bool` local is a genuine redundancy — flagged. */
	public function testDeclaredBoolLocalFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tfinal x:Bool = a > c;\n\t\tvar b = x == true;\n\t}\n}').length);
	}

	public function testBooleanExprOperandFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = (a > c) == true;\n\t}\n}').length);
	}

	public function testNullSafeOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj?.ready() == true;\n\t}\n}').length);
	}

	public function testNullSafeFieldSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj?.flag == false;\n\t}\n}').length);
	}

	public function testNoBooleanLiteralNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = x == c;\n\t}\n}').length);
	}

	public function testBothBooleanLiteralsFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar b = true == true;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('comparison-to-boolean', vs[0].rule);
		Assert.equals('constant boolean comparison', vs[0].message);
	}

	public function testFixRewritesComparisonOperand(): Void {
		Assert.equals(wrap('var b = x < y;'), applyFix(wrap('var b = x < y == true;')));
	}

	public function testFixRewritesParenAndOperand(): Void {
		Assert.equals(wrap('var b = (a && c);'), applyFix(wrap('var b = (a && c) != false;')));
	}

	public function testFixRewritesNotOperand(): Void {
		Assert.equals(wrap('var b = !flag;'), applyFix(wrap('var b = !flag == true;')));
	}

	public function testFixLiteralOnLeftBoolOp(): Void {
		Assert.equals(wrap('var b = (a && c);'), applyFix(wrap('var b = true == (a && c);')));
	}

	public function testFixLeavesBareIdentifier(): Void {
		// An unannotated / unresolvable identifier cannot be proven non-null Bool, so it is
		// neither reported nor stripped — unlike a declared-Bool ident, which fix now rewrites.
		final src: String = wrap('var b = x == true;');
		Assert.equals(src, applyFix(src));
	}

	public function testFixParenthesizedNegation(): Void {
		Assert.equals(wrap('var b = !(a > c);'), applyFix(wrap('var b = (a > c) == false;')));
	}

	public function testFixWrapsBareComparisonNegation(): Void {
		// `a < c` is neither a bare identifier nor parenthesized, so `!` must wrap it.
		Assert.equals(wrap('var b = !(a < c);'), applyFix(wrap('var b = a < c == false;')));
	}

	public function testFixLeavesNullableOperand(): Void {
		final src: String = wrap('var b = obj.flag == true;');
		Assert.equals(src, applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('comparison-to-boolean'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('comparison-to-boolean'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testCallOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = map.get(k) == true;\n\t}\n}').length);
	}

	public function testFieldAccessOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj.flag == true;\n\t}\n}').length);
	}

	public function testMacroReificationSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar e = macro x == true;\n\t}\n}').length);
	}

	/**
	 * An array element (`ps[i]`) is neither a boolean-operator result nor a bare identifier with a
	 * declared non-null Bool type, so it is not provably non-null Bool — its `== true` may be
	 * load-bearing (a `Null<Bool>` / `Dynamic` element under strict null-safety). It stays silent,
	 * matching `fix`, which refuses to strip a non-boolean-operator operand.
	 */
	public function testArrayAccessOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(ps:Array<Dynamic>):Void {\n\t\tvar b = ps[5] == true;\n\t}\n}').length);
	}

	/** A declared non-null Bool local is provably Bool — `== true` collapses to the operand. */
	public function testFixStripsDeclaredBoolLocal(): Void {
		Assert.equals(wrap('final x:Bool = a > c;\n\t\tvar b = x;'), applyFix(wrap('final x:Bool = a > c;\n\t\tvar b = x == true;')));
	}

	/**
	 * A non-null Bool parameter: `!= true` collapses to its negation.
	 */
	public function testFixNegatesDeclaredBoolParam(): Void {
		Assert.equals(
			'class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = !x;\n\t}\n}',
			applyFix('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x != true;\n\t}\n}')
		);
	}

	/** A `(get, set):Bool` property resolves to a non-null Bool field — `== false` collapses to `!flag`. */
	public function testFixStripsBoolProperty(): Void {
		Assert.equals(
			'class C {\n\tpublic var flag(get, set):Bool;\n\tfunction f():Void {\n\t\tvar b = !flag;\n\t}\n}',
			applyFix('class C {\n\tpublic var flag(get, set):Bool;\n\tfunction f():Void {\n\t\tvar b = flag == false;\n\t}\n}')
		);
	}

	/**
	 * A field access whose member resolves to a plain `Bool` is provably non-null, so the
	 * `nullableOperandKinds` blanket veto is bypassed by the resolved-type proof.
	 */
	public function testFieldAccessBoolMemberFlagged(): Void {
		Assert.equals(1, violations(typed('public var flag:Bool;', 'var b = o.flag == true;')).length);
	}

	/** The same shape's autofix strips the literal, leaving the field read. */
	public function testFixStripsFieldAccessBoolMember(): Void {
		Assert.equals(
			typed('public var flag:Bool;', 'var b = o.flag;'), applyFix(typed('public var flag:Bool;', 'var b = o.flag == true;'))
		);
	}

	/** A `Null<Bool>` member's `== true` is load-bearing — no proof, so it stays silent. */
	public function testNullableBoolMemberSkipped(): Void {
		Assert.equals(0, violations(typed('public var flag:Null<Bool>;', 'var b = o.flag == true;')).length);
	}

	/**
	 * A `#if`-GUARDED member declaration is refused: the index is branch-blind and its
	 * inheritance walk is first-wins, so whichever branch is written first would decide the
	 * proof. Written `Bool`-first here, the shape that would otherwise be flagged.
	 */
	public function testGuardedMemberDeclarationSkipped(): Void {
		// ONE guarded declaration, so only the `guarded` clause can refuse it — a two-branch
		// fixture would also trip the written-type-disagreement clause and prove nothing here.
		Assert.equals(0, violations(typed('#if js\n\tpublic var flag:Bool;\n\t#end', 'var b = o.flag == true;')).length);
	}


	/**
	 * A receiver type whose SIMPLE NAME is declared in two files is refused CONSERVATIVELY: the
	 * index keys types by simple name, and its package-blind arms can answer from the homonym
	 * rather than from the type actually in scope. Here the in-scope root `T` would in fact resolve
	 * correctly — the refusal is the price of not having to prove which arm answered.
	 */
	public function testHomonymReceiverTypeSkipped(): Void {
		// `p.T` declares NOTHING directly and inherits `flag:Null<Bool>`, so only the
		// declared-in-one-file refusal stands between the root `T`'s own `flag:Bool` and the proof.
		final other: String = 'package p;\n\nclass Base {\n\tpublic var flag:Null<Bool>;\n}\n\nclass T extends Base {}';
		final src: String = typed('public var flag:Bool;', 'var b = o.flag == true;');
		Assert.equals(0, violationsAcross([{ file: 'C.hx', source: src }, { file: 'p/T.hx', source: other }]).length);
	}

	/** An EXTERN class's `Bool` property resolves like any other member — flagged, and `== false` negates it. */
	public function testExternBoolPropertyFlagged(): Void {
		Assert.equals(1, violations(externFixture('var b = o.visible == false;')).length);
		Assert.equals(externFixture('var b = !o.visible;'), applyFix(externFixture('var b = o.visible == false;')));
	}

	/** The receiver type resolves THROUGH `cast(e, T)` to T's own member. */
	public function testTypedCastReceiverMemberFlagged(): Void {
		final types: String = 'class T {\n\tpublic var flag:Bool;\n}';
		Assert.equals(1, violations(castFixture(types, 'cast(o, T).flag == true')).length);
		Assert.equals(castFixture(types, 'cast(o, T).flag'), applyFix(castFixture(types, 'cast(o, T).flag == true')));
	}

	/** The cast target's INHERITED member resolves too — the `cast(object, DisplayObjectContainer).mouseEnabled` shape. */
	public function testTypedCastInheritedMemberFlagged(): Void {
		final types: String = 'class B {\n\tpublic var flag:Bool;\n}\n\nclass T extends B {}';
		Assert.equals(1, violations(castFixture(types, 'cast(o, T).flag == true')).length);
		Assert.equals(castFixture(types, 'cast(o, T).flag'), applyFix(castFixture(types, 'cast(o, T).flag == true')));
	}

	/**
	 * An anonymous-structure receiver gets NO proof: an `@:optional` field is nullable despite its
	 * `Bool` annotation, and the member table cannot tell the two apart.
	 */
	public function testAnonStructReceiverSkipped(): Void {
		Assert.equals(0, violations(anonFixture('?flag:Bool')).length);
		Assert.equals(0, violations(anonFixture('flag:Bool')).length);
	}

	/** A two-type fixture: a `T` declaring `member`, and a `C.f(o:T)` whose body is `body`. */
	private function typed(member: String, body: String): String {
		return 'class T {\n\t$member\n}\n\nclass C {\n\tfunction f(o:T):Void {\n\t\t$body\n\t}\n}';
	}

	/** An EXTERN fixture: a `T` with a `Bool` property, and a `C.f(o:T)` whose body is `body`. */
	private function externFixture(body: String): String {
		return 'extern class T {\n\tpublic var visible(get, set):Bool;\n}\n\nclass C {\n\tfunction f(o:T):Void {\n\t\t$body\n\t}\n}';
	}

	/** A cast fixture: `types` declares the cast target `T`, and `read` is the field-access expression. */
	private function castFixture(types: String, read: String): String {
		return '$types\n\nclass C {\n\tfunction f(o:Dynamic):Void {\n\t\tvar b = $read;\n\t}\n}';
	}

	/** An anonymous-structure fixture: a `T` carrying one `field`, read through `o.flag == true`. */
	private function anonFixture(field: String): String {
		return 'typedef T = {\n\t$field\n}\n\nclass C {\n\tfunction f(o:T):Void {\n\t\tvar b = o.flag == true;\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return violationsAcross([{ file: 'C.hx', source: src }]);
	}

	/** `violations` over SEVERAL files — the only way to build a cross-file homonym. */
	private function violationsAcross(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new ComparisonToBoolean().run(files, new HaxeQueryPlugin());
	}

	/** Wrap a single statement body in a minimal class+function so it parses. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function applyFix(src: String): String {
		final check: ComparisonToBoolean = new ComparisonToBoolean();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	/** The motivating TM shape: `while (true == true) {}` folds to `while (true) {}`. */
	public function testFixFoldsConstantEqTrueTrue(): Void {
		Assert.equals(wrap('while (true) {}'), applyFix(wrap('while (true == true) {}')));
	}

	public function testFixFoldsConstantNeqTrueTrue(): Void {
		Assert.equals(wrap('var b = false;'), applyFix(wrap('var b = true != true;')));
	}

	public function testFixFoldsConstantEqFalseTrue(): Void {
		Assert.equals(wrap('var b = false;'), applyFix(wrap('var b = false == true;')));
	}

	public function testFixFoldsConstantNeqFalseTrue(): Void {
		Assert.equals(wrap('var b = true;'), applyFix(wrap('var b = false != true;')));
	}

}

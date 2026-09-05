package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.ComparisonToBoolean;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `comparison-to-boolean` check: a comparison against a boolean literal
 * (`x == true`, `x != false`, `true == x`) is flagged `Warning` when the operand is
 * provably non-null Bool — the severity `fix` earns by being able to rewrite it — and
 * `Info` only where nothing can prove the operand either way. Three proofs. STRUCTURAL:
 * a boolean-operator result, or a bare identifier whose declared type proves non-null
 * Bool — a `Null<Bool>` / optional-param / unannotated identifier stays silent (its
 * `== true` may be load-bearing under strict null-safety), and the arm sits behind a
 * blanket veto on an operand reaching a `?.` access / a call / `Map.get` result.
 * RESOLVED-MEMBER: a field access whose receiver type resolves and whose member's
 * declared type is a non-nullable Bool. RESOLVED-RETURN: a method call whose receiver
 * type resolves and whose method's written return type is one — the
 * `map.exists(k) != false` shape. Both resolved arms take the receiver through
 * `cast(e, T)` too, and both refuse what the `SymbolIndex` cannot answer soundly — an
 * anonymous-structure receiver, a simple-name homonym, a `#if`-guarded member — and
 * every `?.` in the receiver chain, whose result is `Null<Bool>` regardless of the
 * annotation. Comparisons inside macro reification are skipped.
 */
class ComparisonToBooleanCheckTest extends Test {

	/** The Bool-returning method every call-arm fixture reads through `o.has(k)`. */
	private static final BOOL_METHOD: String = 'public function has(k:String):Bool return true;';

	public function testEqTrueFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x == true;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('comparison-to-boolean', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
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
	@:pin('control') @:killer('M-PATHWALK-NULL')
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

	/**
	 * A METHOD CALL whose resolved return type is a plain `Bool` is provably non-null, so the
	 * `nullableOperandKinds` blanket veto is bypassed by the resolved-return proof — the
	 * `moveHashMap.exists(hash) != false` shape. Fixable, so `Warning`.
	 */
	public function testCallReturningBoolFlagged(): Void {
		final vs: Array<Violation> = violations(typed(BOOL_METHOD, 'var b = o.has(k) != false;'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** The same shape's autofix strips the literal, leaving the call. */
	public function testFixStripsCallReturningBool(): Void {
		Assert.equals(typed(BOOL_METHOD, 'var b = o.has(k);'), applyFix(typed(BOOL_METHOD, 'var b = o.has(k) != false;')));
	}

	/** `== false` on a Bool-returning call negates it; a call is atomic, so no parentheses. */
	public function testFixNegatesCallReturningBool(): Void {
		Assert.equals(typed(BOOL_METHOD, 'var b = !o.has(k);'), applyFix(typed(BOOL_METHOD, 'var b = o.has(k) == false;')));
	}

	/** A literal on the LEFT of a Bool-returning call collapses the same way. */
	public function testFixStripsCallReturningBoolLiteralLeft(): Void {
		Assert.equals(typed(BOOL_METHOD, 'var b = o.has(k);'), applyFix(typed(BOOL_METHOD, 'var b = true == o.has(k);')));
	}

	/** A `Null<Bool>`-returning method's `!= false` is NOT equivalent to the bare call — silent, never fixed. */
	public function testNullableBoolReturnCallSkipped(): Void {
		final member: String = 'public function has(k:String):Null<Bool> return null;';
		Assert.equals(0, violations(typed(member, 'var b = o.has(k) != false;')).length);
		final src: String = typed(member, 'var b = o.has(k) != false;');
		Assert.equals(src, applyFix(src));
	}

	/** An UNRESOLVABLE receiver leaves the call's return type unknown — silent, never fixed. */
	public function testUnknownReceiverCallSkipped(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = o.has(k) != false;\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A method with NO return annotation is unresolvable — silent, never fixed. */
	public function testUnannotatedReturnCallSkipped(): Void {
		final member: String = 'public function has(k:String) return true;';
		final src: String = typed(member, 'var b = o.has(k) != false;');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A `?.` CALL result is `Null<Bool>` even when the method returns a plain `Bool`, so
	 * `!= false` is load-bearing — silent, never fixed.
	 */
	public function testSafeNavCallOnBoolMethodSkipped(): Void {
		final src: String = typed(BOOL_METHOD, 'var b = o?.has(k) != false;');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A safe-nav RECEIVER under a Bool-returning call is unresolvable — silent, never fixed. */
	public function testSafeNavReceiverCallSkipped(): Void {
		final src: String = typed(BOOL_METHOD, 'var b = o?.inner.has(k) != false;');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A BARE `has(k) != false` call has no receiver to key the lookup on — silent, never fixed. */
	public function testBareCallSkipped(): Void {
		final src: String = typed(BOOL_METHOD, 'var b = has(k) != false;');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A `#if`-GUARDED Bool-returning method declaration is refused, exactly as a guarded field is. */
	public function testGuardedBoolMethodSkipped(): Void {
		final member: String = '#if js\n\tpublic function has(k:String):Bool return true;\n\t#end';
		Assert.equals(0, violations(typed(member, 'var b = o.has(k) != false;')).length);
	}

	/** An ANON-STRUCT receiver's method gets no proof — the member table cannot rule out `@:optional`. */
	public function testAnonStructReceiverCallSkipped(): Void {
		final src: String = 'typedef T = {\n\tfunction has(k:String):Bool;\n}\n\n'
			+ 'class C {\n\tfunction f(o:T, k:String):Void {\n\t\tvar b = o.has(k) != false;\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A Bool-returning method reached through `cast(o, T)` resolves like a field does. */
	public function testTypedCastReceiverCallFlagged(): Void {
		final types: String = 'class T {\n\tpublic function has(k:String):Bool return true;\n}';
		Assert.equals(1, violations(castFixture(types, 'cast(o, T).has(k) == true')).length);
		Assert.equals(castFixture(types, 'cast(o, T).has(k)'), applyFix(castFixture(types, 'cast(o, T).has(k) == true')));
	}

	/** A Bool-returning method INHERITED from a supertype resolves through the index's walk. */
	public function testInheritedBoolMethodFlagged(): Void {
		final types: String = 'class B {\n\tpublic function has(k:String):Bool return true;\n}\n\nclass T extends B {}';
		final src: String = '$types\n\nclass C {\n\tfunction f(o:T, k:String):Void {\n\t\tvar b = o.has(k) != false;\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/** The constant fold is autofixable too, so it is a `Warning` rather than an advisory. */
	public function testConstantFoldIsWarning(): Void {
		final vs: Array<Violation> = violations(wrap('var b = true == true;'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** A proven bare-identifier operand is fixable, so it is a `Warning`. */
	public function testDeclaredBoolLocalIsWarning(): Void {
		final vs: Array<Violation> =
			violations('class C {\n\tfunction f():Void {\n\t\tfinal x:Bool = a > c;\n\t\tvar b = x == true;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** A proven FIELD-ACCESS operand is fixable, so it is a `Warning`. */
	public function testFieldAccessBoolMemberIsWarning(): Void {
		final vs: Array<Violation> = violations(typed('public var flag:Bool;', 'var b = o.flag == true;'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** A `Null<Bool>` LOCAL is never fixed — the report's silence and the fixer's agree. */
	public function testFixLeavesNullableBoolLocal(): Void {
		final src: String = wrap('final x:Null<Bool> = g();\n\t\tvar b = x == false;');
		Assert.equals(src, applyFix(src));
	}

	/** A `Null<Bool>` MEMBER is never fixed either. */
	public function testFixLeavesNullableBoolMember(): Void {
		final src: String = typed('public var flag:Null<Bool>;', 'var b = o.flag != false;');
		Assert.equals(src, applyFix(src));
	}

	/**
	 * `haxe.ds.Map.exists` writes NO return annotation (`public inline function exists(key:K) return
	 * this.exists(key);`), so no resolution scope can read one — `RefShape.instanceMethodReturns`
	 * supplies the `Bool` its forwarded-to `IMap.exists(k:K):Bool` declares. The TM shape that
	 * motivated the arm.
	 */
	public function testStdMapExistsFlagged(): Void {
		final vs: Array<Violation> = violations(mapFixture('m.exists(k) != false'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(mapFixture('m.exists(k)'), applyFix(mapFixture('m.exists(k) != false')));
		Assert.equals(mapFixture('!m.remove(k)'), applyFix(mapFixture('m.remove(k) == false')));
	}

	/** `Map.get` is absent from the table on purpose — its `Null<V>` is exactly what `== true` guards. */
	public function testStdMapGetSkipped(): Void {
		final src: String = mapFixture('m.get(k) == true');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A PROJECT type named `Map` shadows the stdlib name, so the table must not answer for it — even
	 * though ONE declaration passes the homonym pin. The shadow's own `exists` is UNANNOTATED, so
	 * `returnNominalOf` answers null exactly as it does for the std `Map`: only the table's own
	 * non-std shadowing guard stands between that null and a `Bool` the project type never promised.
	 */
	public function testShadowedMapNameSkipped(): Void {
		final own: String = 'package p;\n\nclass Map {\n\tpublic function exists(k:String) return null;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: mapFixture('m.exists(k) != false') },
			{ file: 'p/Map.hx', source: own }
		];
		Assert.equals(0, violationsAcross(files).length);
	}

	/** The same shadow ANNOTATED `Null<Bool>` is refused by the nullability gate behind it. */
	public function testShadowedNullableMapNameSkipped(): Void {
		final own: String = 'package p;\n\nclass Map {\n\tpublic function exists(k:String):Null<Bool> return null;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: mapFixture('m.exists(k) != false') },
			{ file: 'p/Map.hx', source: own }
		];
		Assert.equals(0, violationsAcross(files).length);
	}

	/** TWO project types named `Map` refuse the lookup at the homonym pin, before any table. */
	public function testTwoShadowsOfMapNameSkipped(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: mapFixture('m.exists(k) != false') },
			{ file: 'p/Map.hx', source: 'package p;\n\nclass Map {\n\tpublic function exists(k:String):Bool return true;\n}' },
			{ file: 'q/Map.hx', source: 'package q;\n\nclass Map {\n\tpublic function exists(k:String):Bool return true;\n}' }
		];
		Assert.equals(0, violationsAcross(files).length);
	}

	/** A WRITTEN `this.m()` resolves through the self-reference branch of the receiver walk. */
	public function testThisReceiverCallFlagged(): Void {
		final src: String = 'class C {\n\tpublic function has(k:String):Bool return true;\n\n'
			+ '\tfunction f(k:String):Void {\n\t\tvar b = this.has(k) != false;\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * A plain alias re-pointing at its OWN simple name — the `typedef Map<K, V> = haxe.ds.Map<K, V>`
	 * shape Haxe's std ships — is not a second answer, so it does not make the name ambiguous.
	 */
	public function testSelfNamedAliasHomonymStillProven(): Void {
		final alias: String = 'package p;\n\ntypedef T = q.T;';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: typed(BOOL_METHOD, 'var b = o.has(k) != false;') },
			{ file: 'p/T.hx', source: alias }
		];
		Assert.equals(1, violationsAcross(files).length);
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

	/** A stdlib-`Map` fixture: a `C.f(m:Map<String, String>, k:String)` whose body reads `expr`. */
	private function mapFixture(expr: String): String {
		return 'class C {\n\tfunction f(m:Map<String, String>, k:String):Void {\n\t\tvar b = $expr;\n\t}\n}';
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
		return CheckFixture.fixedSource(new ComparisonToBoolean(), src);
	}

}

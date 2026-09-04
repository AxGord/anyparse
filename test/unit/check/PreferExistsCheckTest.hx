package unit.check;

import anyparse.check.Check;
import anyparse.check.PreferExists;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-exists` check: a manual any-match `for` loop — bare
 * `for (x in xs) if (cond) return true; return false;` and the GUARDED
 * `if (g) for (x in xs) if (cond) return true; return false;` — is flagged `Info`,
 * suggesting `xs.exists(x -> cond)` / `g && xs.exists(x -> cond)`. A non-literal
 * fallback, a matching (rather than opposite) trailing literal, an `else` on either
 * `if`, a key-value / range / call iterable, a non-adjacent trailing return and the
 * opposite (`foreach`) direction are all safe misses.
 *
 * ## The FLAG form
 *
 * The second sink: `var f:Bool = false;` immediately followed by
 * `for (x in xs) if (cond) f = true;`, which folds to
 * `final f:Bool = xs.exists(x -> cond);`. Its own gates get a fixture each — the
 * declaration must open at the OPPOSITE literal, be a `var` rather than a `final`,
 * stand next to the loop, and be written nowhere else; the loop must assign THAT
 * name and nothing else.
 *
 * The load-bearing one is PURITY. The flag loop visits every element where the
 * `return` form stops at the first match, so folding to a short-circuiting
 * `Lambda.exists` is only an identity while the condition does no work —
 * `testFlagFormEffectfulConditionNotFlagged` is the fixture that says so, and
 * `testFlagFormFieldReadConditionFlagged` is its twin proving the gate is
 * `PurityScan` (which admits a field READ) rather than
 * `RefactorSupport.isSideEffectFree` (which refuses one).
 */
class PreferExistsCheckTest extends Test {

	public function testBareFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-exists', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testGuardedFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('if (n != null) for (x in n) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('n != null && n.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testBracedThenBranchFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) if (x > 2) { return true; }\n\t\treturn false;')).length);
	}

	public function testBracedLoopBodyFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) { if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testBracedGuardBodyFlagged(): Void {
		Assert.equals(1, violations(fn('if (a) { for (x in xs) if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testSameLiteralTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn true;')).length);
	}

	public function testNonLiteralFallbackNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn xs.length == 0;')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true; else return false;\n\t\treturn false;')).length);
	}

	public function testGuardWithElseNotFlagged(): Void {
		Assert.equals(0, violations(fn('if (a) for (x in xs) if (x > 2) return true; else return false;\n\t\treturn false;')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return true;\n\t\treturn false;')).length);
	}

	public function testCallIterableNotFlagged(): Void {
		// A call iterable may yield an Iterator, not an Iterable — `Lambda.exists` would not compile.
		// `Map.keys` lives in a std this index does not see, so the type stays UNRESOLVED and is refused.
		Assert.equals(0, violations(fn('for (k in m.keys()) if (m[k] > 2) return true;\n\t\treturn false;')).length);
	}

	public function testCallIterableResolvingToArrayFlagged(): Void {
		final vs: Array<Violation> = violations(typedFn('for (x in b.items()) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('b.items().exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testCallIterableResolvingToIteratorNotFlagged(): Void {
		// The TYPED refusal, not the unresolved one: `Iterator<T>` is not an `Iterable<T>`.
		Assert.equals(0, violations(typedFn('for (x in b.walker()) if (x > 2) return true;\n\t\treturn false;')).length);
	}

	public function testCallIterableFixRewritesToExists(): Void {
		final out: String = fixResult(
			'package p;\n\nusing Lambda;\n\n' + typedFn('for (x in b.items()) if (x > 2) return true;\n\t\treturn false;')
		);
		Assert.isTrue(out.indexOf('return b.items().exists(x -> x > 2);') != -1, out);
	}

	public function testReceiverDeclaringExistsTakesTheQualifiedForm(): Void {
		// A real MEMBER always beats a `using` static extension, so `m.exists(x -> …)` on a receiver
		// whose own type declares `exists(key)` binds to THAT member and puts the lambda in the key
		// slot — the shape a `Map` receiver has, and the one that cannot compile. The FOLD is still
		// available in the QUALIFIED spelling, which routes around the member entirely.
		final vs: Array<Violation> = violations(memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Lambda.exists(m, x -> x > 2)') != -1, vs[0].message);
	}

	public function testReceiverInheritingExistsTakesTheQualifiedForm(): Void {
		// The inherited half of the same question: the member is declared by a SUPERTYPE, and Haxe
		// picks it over the extension exactly the same way — so the same fallback applies.
		final vs: Array<Violation> = violations(inheritedMemberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Lambda.exists(m, x -> x > 2)') != -1, vs[0].message);
	}

	public function testNullableReceiverDeclaringExistsTakesTheQualifiedForm(): Void {
		// ★ The receiver is `Null<M>`, and Haxe's `Null` is member-TRANSPARENT: `m.exists(…)` looks
		// `exists` up on `M` all the same. Asking the VALUE nominal answers `Null`, which declares
		// nothing — which is why the gate asks `CheckScan.receiverNominalResolver`. This is the
		// second of the two measured TM sites (`baseData:Null<Map<Int, ObjectFrameData>>`), and the
		// guarded merge rides on the qualified call unchanged.
		final vs: Array<Violation> = violations(nullableMemberFn('if (m != null) for (x in m) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('m != null && Lambda.exists(m, x -> x > 2)') != -1, vs[0].message);
	}

	public function testQualifiedFixEmitsTheStaticCallAndInsertsNoUsing(): Void {
		// The `using Lambda;` the extension form needs buys the qualified call NOTHING — it is a
		// plain static call on a named module — so the fixer must not add one.
		final out: String = fixResult('package p;\n\n' + memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;'));
		Assert.isTrue(out.indexOf('return Lambda.exists(m, x -> x > 2);') != -1, out);
		Assert.equals(-1, out.indexOf('using Lambda;'));
	}

	public function testQualifiedFixKeepsAnExistingUsing(): Void {
		// The other direction of the same question: a `using Lambda;` the file already declares is
		// left alone — other code may depend on it, and this rule never removes one.
		final out: String = fixResult(
			'package p;\n\nusing Lambda;\n\n' + memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;')
		);
		Assert.isTrue(out.indexOf('return Lambda.exists(m, x -> x > 2);') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testShadowedLambdaModuleRefusesTheQualifiedForm(): Void {
		// `Lambda` may itself be shadowed — a project declaring its own `Lambda.hx` (this one did
		// until recently). Then `Lambda.exists(…)` reaches THAT type, and a member it declares as an
		// INSTANCE method is not reachable through a type-qualified call at all. Refuse, as the
		// extension form already does.
		Assert.equals(0, violations(shadowedLambdaFn('for (x in m) if (x > 2) return true;\n\t\treturn false;')).length);
	}

	public function testImportRebindingLambdaRefusesTheQualifiedForm(): Void {
		// The same question asked of the file's HEADER rather than the index: an `import` binding the
		// simple name `Lambda` to another module decides what `Lambda.exists` means here.
		final src: String = 'package p;\n\nimport q.Lambda;\n\n' + memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;');
		Assert.equals(0, violations(src).length);
	}

	public function testProjectLambdaInAnotherFileRefusesTheQualifiedForm(): Void {
		// The INDEX arm of the same question: the shadowing `Lambda` is a module of its own, exactly
		// the shape a project ships as `src/Lambda.hx` (this one did until recently). It declares no
		// STATIC `exists`, so `Lambda.exists(m, …)` would not resolve.
		final own: String = memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;');
		final lambda: String = 'class Lambda {\n\tpublic static function foreach(it:Int):Bool {\n\t\treturn false;\n\t}\n}';
		final vs: Array<Violation> = new PreferExists().run(
			[{ file: 'C.hx', source: own }, { file: 'Lambda.hx', source: lambda }], new HaxeQueryPlugin()
		);
		Assert.equals(0, vs.length);
	}

	public function testProjectLambdaSupplyingTheStaticKeepsTheQualifiedForm(): Void {
		// The gate is about the METHOD, not the NAME: a project `Lambda` that declares the static the
		// call wants answers it, so the fallback stands.
		final own: String = memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;');
		final lambda: String =
			'class Lambda {\n\tpublic static function exists<A>(it:Iterable<A>, f:A -> Bool):Bool {\n\t\treturn false;\n\t}\n}';
		final vs: Array<Violation> = new PreferExists().run(
			[{ file: 'C.hx', source: own }, { file: 'Lambda.hx', source: lambda }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Lambda.exists(m, x -> x > 2)') != -1, vs[0].message);
	}

	public function testWildcardImportRefusesTheQualifiedForm(): Void {
		// A wildcard binds main types it does not spell out, and nothing in the statement says
		// whether `q` holds a `Lambda`. Refuse rather than guess — the extension form was already
		// refused here, so the site simply stays a report-only finding.
		final src: String = 'package p;\n\nimport q.*;\n\n' + memberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;');
		Assert.equals(0, violations(src).length);
	}

	public function testShadowedReceiverStillRefusedForANonShadowReason(): Void {
		// The qualified spelling changes only WHICH call is written, never whether the fold is
		// SOUND: the call iterable here resolves to an `Iterator`, which is not an `Iterable`, so
		// neither spelling compiles and the site stays refused even though its receiver shadows.
		Assert.equals(0, violations(iteratorMemberFn('for (x in m.walker()) if (x > 2) return true;\n\t\treturn false;')).length);
	}

	public function testReceiverDeclaringAnotherMemberStillFlagged(): Void {
		// The gate is about the ONE name the rewrite wants: a receiver declaring `foreach` and not
		// `exists` is still rewritten by this direction.
		Assert.equals(1, violations(foreachMemberFn('for (x in m) if (x > 2) return true;\n\t\treturn false;')).length);
	}

	public function testRangeLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return true;\n\t\treturn false;')).length);
	}

	public function testNonAdjacentTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\tfinal q = xs.length;\n\t\treturn false;')).length);
	}

	public function testForeachDirectionNotClaimed(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testExtraLoopBodyStatementNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) { trace(x); if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testFallThroughFromElseBranchFlagged(): Void {
		final vs: Array<Violation> = violations(
			fn('if (a) {\n\t\t\ttrace(b);\n\t\t} else {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t}\n\t\treturn false;')
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testFallThroughAcrossTwoIfLevelsFlagged(): Void {
		Assert.equals(
			1,
			violations(fn('if (a) {\n\t\t\tif (b) {\n\t\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t\t}\n\t\t}\n\t\treturn false;'))
				.length
		);
	}

	public function testFallThroughStopsAtALoopBody(): Void {
		// Falling off the end of a `while` body starts the NEXT ITERATION, so the trailing
		// `return false;` is not what follows the loop — the successor must not cross it.
		Assert.equals(0, violations(fn('while (a) {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t}\n\t\treturn false;')).length);
	}

	public function testFallThroughStopsAtATryBody(): Void {
		Assert.equals(
			0, violations(fn('try {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t} catch (e:Dynamic) {}\n\t\treturn false;')).length
		);
	}

	public function testFallThroughStopsAtASwitchArm(): Void {
		// The arm body is BRACED on purpose: an unbraced arm's statements are not a statement list
		// at all, so the pairing never happens and the fixture would pass behind that gate instead
		// of this one. With a block there, only the successor rule can refuse it.
		Assert.equals(
			0,
			violations(
				fn('switch (a) {\n\t\t\tcase _: {\n\t\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t\t}\n\t\t}\n\t\treturn false;')
			).length
		);
	}

	public function testConditionalRegionIsNotAStatementList(): Void {
		// Pins a DIFFERENT gate from the three above, and says so: a `#if` region projects its
		// branches as FLATTENED siblings and is deliberately absent from `blockKinds`, so nothing
		// inside one is ever paired with a sibling outside it — with or without a successor.
		Assert.equals(0, violations(fn('#if js\n\t\tfor (x in xs) if (x > 2) return true;\n\t\t#end\n\t\treturn false;')).length);
	}

	public function testGuardedBracedFormReportedOnce(): Void {
		// `if (g) { for … }` + the fallback matches BOTH readings — the guarded merge and the bare
		// fall-through inside the braces. One site, one finding: the merge.
		final vs: Array<Violation> = violations(fn('if (a) { for (x in xs) if (x > 2) return true; }\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('a && xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testFallThroughFixKeepsTheTrailingReturn(): Void {
		final out: String = fixResult(
			file('if (a) {\n\t\t\ttrace(b);\n\t\t} else {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t}\n\t\treturn false;', true)
		);
		Assert.isTrue(out.indexOf('return xs.exists(x -> x > 2);') != -1, out);
		Assert.isTrue(out.indexOf('return false;') != -1, out);
	}

	public function testFixBareRewritesAndInsertsUsing(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return true;\n\t\treturn false;', false));
		Assert.isTrue(out.indexOf('return xs.exists(x -> x > 2);') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testFixGuardedKeepsGuard(): Void {
		final out: String = fixResult(file('if (n != null) for (x in n) if (x > 2) return true;\n\t\treturn false;', true));
		Assert.isTrue(out.indexOf('return n != null && n.exists(x -> x > 2);') != -1, out);
	}

	public function testFixParenthesizesLooseGuard(): Void {
		final out: String = fixResult(file('if (a || b) for (x in xs) if (x > 2) return true;\n\t\treturn false;', true));
		Assert.isTrue(out.indexOf('return (a || b) && xs.exists(x -> x > 2);') != -1, out);
	}

	public function testFixKeepsSingleUsing(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return true;\n\t\treturn false;', true));
		final first: Int = out.indexOf('using Lambda;');
		Assert.isTrue(first != -1, out);
		Assert.equals(-1, out.indexOf('using Lambda;', first + 1));
	}

	public function testCommentInDroppedRegionNotFixed(): Void {
		final src: String = file('for (x in xs) // why\n\t\t\tif (x > 2) return true;\n\t\treturn false;', true);
		Assert.equals(0, new PreferExists().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	public function testInsertedUsingIsAtomicWithItsRewrites(): Void {
		// Reverting the rewrite while KEEPING the inserted `using` leaves a file that still
		// compiles, so the verifier could not tell that subset was wrong — measured as an orphaned
		// `using Lambda;` on a Map-receiver fixture before the grouping landed.
		final src: String = file('for (x in xs) if (x > 2) return true;\n\t\treturn false;', false);
		final edits: Array<GroupedEdit> = grouped(src);
		Assert.equals(2, edits.length);
		Assert.notNull(edits[0].group);
		Assert.equals(edits[0].group, edits[1].group);
	}

	public function testEditsStayIndependentWhenTheUsingIsAlreadyThere(): Void {
		final src: String = file(
			'if (a) {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t} else {\n\t\t\tfor (x in xs) if (x < 0) return true;\n\t\t}\n'
			+ '\t\treturn false;',
			true
		);
		final edits: Array<GroupedEdit> = grouped(src);
		Assert.equals(2, edits.length);
		for (e in edits) Assert.isNull(e.group);
	}

	public function testFlagFormFlagged(): Void {
		// The rule id and severity ride on the shared violation builder, which `testBareFormFlagged`
		// already pins — what is this arm's own is the SINK the message names.
		final vs: Array<Violation> =
			violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('final found = xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testFlagFormFieldReadConditionFlagged(): Void {
		// The motivating TM site's shape (`child.nodeType == CData`): the condition READS a field,
		// which `RefactorSupport.isSideEffectFree` refuses outright and `PurityScan` admits. The twin
		// of the refusal below — together they say WHICH purity question the gate asks.
		final vs: Array<Violation> =
			violations(flagFn('var found:Bool = false;\n\t\tfor (p in ps) if (p.id > 2) found = true;\n\t\treturn found;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('final found = ps.exists(p -> p.id > 2)') != -1, vs[0].message);
	}

	public function testFlagFormEffectfulConditionNotFlagged(): Void {
		// ★ The gate the whole arm exists for. This loop calls `keep` on EVERY element;
		// `Lambda.exists` stops at the first `true`, so the fold would silently drop the remaining
		// calls. Five real sites in the measured application have exactly this shape.
		Assert.equals(
			0, violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (keep(x)) found = true;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormEffectfulMethodCallConditionNotFlagged(): Void {
		// The receiver-call spelling of the same hazard (`locks.remove(rm)` in the measured tree).
		Assert.equals(
			0, violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (xs.remove(x)) found = true;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormSameLiteralNotFlagged(): Void {
		// The loop's literal decides the DIRECTION, and `found = false` is the twin's.
		Assert.equals(
			0, violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) found = false;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormInitializerMatchingTheLoopLiteralNotFlagged(): Void {
		// The OTHER half of the same pairing: the loop's literal is this direction's, but the
		// declaration already opens at it, so the loop can never change the value and the fold is
		// not an identity. Pinned separately because the direction check above does not reach it.
		Assert.equals(
			0, violations(flagFn('var found:Bool = true;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormNonLiteralInitializerNotFlagged(): Void {
		Assert.equals(
			0, violations(flagFn('var found:Bool = xs.length == 0;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormFinalDeclarationNotFlagged(): Void {
		// A `final` cannot be the loop's assignment target at all, so the pair is not this shape.
		Assert.equals(
			0, violations(flagFn('final found:Bool = false;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormWrittenAgainAfterTheLoopNotFlagged(): Void {
		// The fold emits `final`, which a second write would not compile against.
		Assert.equals(
			0,
			violations(
				flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\tif (a) found = false;\n\t\treturn found;')
			).length
		);
	}

	public function testFlagFormNonAdjacentLoopNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				flagFn('var found:Bool = false;\n\t\tfinal q = xs.length;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;')
			).length
		);
	}

	public function testFlagFormAssigningAnotherNameNotFlagged(): Void {
		// The loop must write the name the declaration BINDS. Here it writes the parameter `a`, and
		// `found` gets its one write afterwards — so the single-write gate is satisfied and only the
		// target-name check stands between this pair and a fold that would be plain wrong.
		Assert.equals(
			0,
			violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) a = true;\n\t\tfound = a;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormExtraThenBranchStatementNotFlagged(): Void {
		// ★ The second load-bearing refusal. The purity gate covers the CONDITION only; work done in
		// the then-BRANCH is refused by the sink shape, which demands the branch BE the assignment.
		// Folding this would drop every `trace` past the first match.
		Assert.equals(
			0,
			violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) { trace(x); found = true; }\n\t\treturn found;'))
				.length
		);
	}

	public function testFlagFormExtraLoopBodyStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(flagFn('var found:Bool = false;\n\t\tfor (x in xs) { trace(x); if (x > 2) found = true; }\n\t\treturn found;'))
				.length
		);
	}

	public function testFlagFormGuardedLoopNotClaimed(): Void {
		// The guarded merge is claimed for the RETURN form only. Here the statement after the
		// declaration is the guard, not the loop, so the pair is not this shape — and no measured
		// site wants it: every guarded flag loop in the application tree fails the purity gate too.
		Assert.equals(
			0, violations(flagFn('var found:Bool = false;\n\t\tif (a) for (x in xs) if (x > 2) found = true;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormRangeIterableNotFlagged(): Void {
		Assert.equals(
			0,
			violations(flagFn('var found:Bool = false;\n\t\tfor (i in 0...xs.length) if (xs[i] > 2) found = true;\n\t\treturn found;'))
				.length
		);
	}

	public function testFlagFormForeachDirectionNotClaimed(): Void {
		Assert.equals(
			0, violations(flagFn('var found:Bool = true;\n\t\tfor (x in xs) if (x > 2) found = false;\n\t\treturn found;')).length
		);
	}

	public function testFlagFormReceiverDeclaringExistsTakesTheQualifiedForm(): Void {
		// The FLAG sink reaches the same head and therefore the same fallback: the shadow picks the
		// qualified spelling, and the fold's own purity gate is untouched by it.
		final vs: Array<Violation> = new PreferExists().run([
			{
				file: 'C.hx',
				source: 'class C {\n\tfunction f(m:M):Bool {\n\t\tvar found:Bool = false;\n\t\tfor (x in m) if (x > 2) found = true;\n'
				+ '\t\treturn found;\n\t}\n}\n\nclass M {\n\tpublic function exists(key:Int):Bool {\n\t\treturn false;\n\t}\n\n'
				+ '\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			}
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('final found = Lambda.exists(m, x -> x > 2)') != -1, vs[0].message);
	}

	public function testFlagFormFixFoldsDeclarationAndLoop(): Void {
		final out: String = fixResult(
			flagFile('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;', true)
		);
		Assert.isTrue(out.indexOf('final found:Bool = xs.exists(x -> x > 2);') != -1, out);
		Assert.equals(-1, out.indexOf('for (x in xs)'));
	}

	public function testFlagFormFixKeepsAnAbsentAnnotationAbsent(): Void {
		final out: String = fixResult(flagFile('var found = false;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;', true));
		Assert.isTrue(out.indexOf('final found = xs.exists(x -> x > 2);') != -1, out);
	}

	public function testFlagFormFixInsertsUsing(): Void {
		final out: String = fixResult(
			flagFile('var found:Bool = false;\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;', false)
		);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testFlagFormCommentInDroppedRegionNotFixed(): Void {
		final src: String = flagFile(
			'var found:Bool = false;\n\t\t// why\n\t\tfor (x in xs) if (x > 2) found = true;\n\t\treturn found;', true
		);
		Assert.equals(1, violations(src).length);
		Assert.equals(0, new PreferExists().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	/** The FLAG form's fixture: `ps` gives a field-read condition a receiver, `keep` an effectful one. */
	private function flagFn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, ps:Array<P>, m:Map<String, Int>, a:Bool):Bool {\n\t\t$body\n\t}\n\n'
			+ '\tfunction keep(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}\n\nclass P {\n\tpublic var id:Int;\n}';
	}

	private function flagFile(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + flagFn(body);
	}

	private function grouped(src: String): Array<GroupedEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferExists = new PreferExists();
		return check.fixGrouped(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>, n:Null<Array<Int>>, a:Bool, b:Bool):Bool {\n\t\t${body}\n\t}\n}';
	}

	/** A fixture whose CALL iterables are RESOLVABLE: `B` is indexed alongside `C`, so its members' written return types answer. */
	private function typedFn(body: String): String {
		return 'class C {\n\tfunction f(b:B, a:Bool):Bool {\n\t\t$body\n\t}\n}\n\nclass B {\n\tpublic function items():Array<Int> {\n'
			+ '\t\treturn [];\n\t}\n\n\tpublic function walker():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	/** A receiver whose OWN type declares `exists(key)` — the `Map` shape, spelled inside the index. */
	private function memberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function exists(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	/** The same shape with `exists` declared by a SUPERTYPE rather than the receiver's own body. */
	private function inheritedMemberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass Base {\n\tpublic function exists(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n}\n\nclass M extends Base {\n\tpublic function iterator():Iterator<Int> {\n'
			+ '\t\treturn [].iterator();\n\t}\n}';
	}

	/** The same shape behind a member-TRANSPARENT `Null<…>` wrapper — the shape the TM guarded site has. */
	private function nullableMemberFn(body: String): String {
		return 'class C {\n\tfunction f(m:Null<M>):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function exists(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	/** The `memberFn` shape plus a PROJECT `Lambda` whose `exists` is an INSTANCE member — unreachable through `Lambda.exists(…)`. */
	private function shadowedLambdaFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function exists(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}\n\n'
			+ 'class Lambda {\n\tpublic function exists(f:Int):Bool {\n\t\treturn false;\n\t}\n}';
	}

	/** A receiver that BOTH declares `exists` and hands out an `Iterator` — two refusals at one site. */
	private function iteratorMemberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function exists(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function walker():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	/** A receiver declaring the TWIN direction's name and not this one — the gate must not fire. */
	private function foreachMemberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function foreach(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	private function file(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + fn(body);
	}

	private function violations(source: String): Array<Violation> {
		return new PreferExists().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferExists = new PreferExists();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, vs, plugin, SymbolIndex.build([{ file: 'C.hx', source: src }], plugin)
		);
		switch CanonicalEdit.canonicalize(src, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}

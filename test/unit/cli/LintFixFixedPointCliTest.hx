package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.cli.command.LintFixLedger;
import utest.Assert;
import utest.Test;

/**
 * End-to-end proof that `apq lint --fix` iterates to a FIXED POINT in a
 * single invocation. Each fixture is a cascade where the first fix exposes a
 * finding only a later pass can see: a `redundant-else` `else if` chain (the
 * inner else surfaces once the outer is de-nested, `prefer-ternary-return` then
 * collapses the two guards into a nested ternary, and `prefer-if-expression-chain`
 * converts that into the canonical 3-value if-expression chain — four fixes, three
 * rules, one invocation) and a dead-code deletion that leaves a local unused.
 * Methods are `public` so `unused-private` does not subsume the whole method, and
 * each fixture is byte-canonical under default writer opts (trailing newline
 * included) so the first-pass canonical gate admits it.
 *
 * The `else`-chain fixture used to assert that NO `else` survived, which held only
 * while the cascade stopped at the nested ternary. `prefer-if-expression-chain`
 * adds the last step of the project's conditional canon (2 values -> ternary,
 * 3+ -> if-expression chain), so the pin is now the canonical chain itself — a
 * stronger assertion than "no `else`", since it names the exact fixed point rather
 * than one property of it.
 */
class LintFixFixedPointCliTest extends Test {

	public function testElseIfChainConverges(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f():Int {\n\t\tif (a) return 1;\n\t\telse if (b) return 2;\n'
			+ '\t\telse return 3;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfp', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('if (a) return 1;') == -1, 'the guard chain is de-nested and collapsed: $out');
		Assert.isTrue(out.indexOf('return if (a) 1 else if (b) 2 else 3;') != -1, 'the whole cascade lands on the canonical chain: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDeadCodeExposesUnusedLocal(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f():Void {\n\t\tvar x = 1;\n\t\treturn;\n\t\ttrace(x);\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfp', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('trace') == -1, 'dead trace deleted: $out');
		Assert.isTrue(out.indexOf('var x') == -1, 'now-unused local deleted in the same invocation: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCrossFileConfinementSafeAcrossPasses(): Void {
		#if (sys || nodejs)
		// A.hx holds a private method `m` with an unused parameter PLUS a
		// redundant-else fixed on pass 1 — which makes A active for pass 2. B.hx
		// overrides `m`, so A is NOT confined (it has a subtype). `unused-parameter`
		// is registered in the --fix loop's `fullScopeIds`, so even on the pass-2
		// subset {A} the cross-file index still includes B and `m`'s parameter stays
		// `Info`. Were the check active-scope, pass 2 would re-lint {A} alone,
		// wrongly conclude `m` confined, and silently break B's override.
		final a: String = 'package p;\n\nclass A {\n\tprivate function m(a:Int, unused:Int):Int {\n\t\treturn a;\n\t}\n\n'
			+ '\tpublic function u():Int {\n\t\tif (c) return 1;\n\t\telse return m(1, 2);\n\t}\n}\n';
		final b: String =
			'package p;\n\nclass B extends A {\n\toverride private function m(a:Int, unused:Int):Int {\n\t\treturn a;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixconfine', [{ name: 'A.hx', source: a }, { name: 'B.hx', source: b }]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('else') == -1, 'redundant else de-nested (pass 1 ran): $outA');
		Assert.isTrue(outA.indexOf('unused:Int') != -1, 'm parameter kept — A is unconfined via subtype B: $outA');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCrossFileNamingFieldRenameAcrossFiles(): Void {
		#if (sys || nodejs)
		// A non-confined private field `shape` (missing its `_`), read by a subclass, renames in
		// BOTH files in one `lint --fix` invocation via naming's cross-file fix. C is unconfined
		// (subtype D reads `shape`), so the single-file rename would refuse it; the cross-file
		// rename rewrites C's declaration AND D's inherited read atomically.
		final c: String =
			'package p;\n\nclass C {\n\tprivate var shape:Int = 0;\n\n\tpublic function f():Int {\n\t\treturn this.shape;\n\t}\n}\n';
		final d: String = 'package p;\n\nclass D extends C {\n\tpublic function g():Int {\n\t\treturn shape;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixcrossnaming', [{ name: 'C.hx', source: c }, { name: 'D.hx', source: d }]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outC: String = File.getContent('$dir/C.hx');
		final outD: String = File.getContent('$dir/D.hx');
		Assert.isTrue(outC.indexOf('_shape') != -1, 'C declaration renamed: $outC');
		Assert.isTrue(outD.indexOf('_shape') != -1, 'D inherited read renamed in the same invocation: $outD');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `Reg` is a custom `keys()`-bearing NON-map and `Svc` — which holds it — is declared in a
	 * THIRD file, so resolving the receiver path `s.reg` needs a file A.hx does not contain.
	 * A.hx is made active for pass 2 by a redundant-else fix. `map-keys-lookup` is registered in
	 * the `--fix` loop's `fullScopeIds`, so pass 2 over the subset {A} still sees Svc.hx, still
	 * resolves `Svc.reg` to `Reg`, and the type gate keeps skipping the loop. Were the check
	 * active-scope, pass 2 would re-lint {A} alone, read `Svc.reg` as unresolvable, and rewrite
	 * the loop to `for (k => value in s.reg)` — which does not compile, `Reg` having no
	 * `keyValueIterator`.
	 */
	public function testMapKeysLookupFullScopeAcrossPasses(): Void {
		#if (sys || nodejs)
		final reg: String = 'package p;\n\nclass Reg {\n\tpublic function keys():Iterator<String> {\n\t\treturn null;\n\t}\n\n'
			+ '\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}\n';
		final svc: String = 'package p;\n\nclass Svc {\n\tpublic var reg:Reg;\n}\n';
		final a: String = 'package p;\n\nclass A {\n\tpublic function u():Int {\n\t\tif (c) return 1;\n\t\telse return 2;\n\t}\n\n'
			+ '\tpublic function f(s:Svc):Void {\n\t\tfor (k in s.reg.keys()) trace(s.reg.get(k));\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixmkl', [
			{ name: 'Reg.hx', source: reg },
			{ name: 'Svc.hx', source: svc },
			{ name: 'A.hx', source: a }
		]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('else') == -1, 'redundant else de-nested (pass 1 ran): $outA');
		Assert.isTrue(outA.indexOf('s.reg.keys()') != -1, 'custom keys() type kept — Svc stayed resolvable on every pass: $outA');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testParamRemovalConflictWithTernaryStaysConsistent(): Void {
		#if (sys || nodejs)
		// `caller`'s `if (flag) return helper(...); return helper(...);` is a
		// prefer-ternary-return candidate whose helper calls sit inside the rewritten
		// region; `helper`'s first parameter is unused. In one pass prefer-ternary's
		// region-rewrite and unused-parameter's call-arg removal collided — the param
		// was dropped from the signature but the call kept all three args
		// (`Too many arguments`). The --fix loop must converge to an arity-consistent
		// (compiling) result.
		final src: String = 'package p;\n\nclass C {\n\tpublic static function caller(flag:Bool):Int {\n'
			+ '\t\tif (flag) return helper(1, 10, 20);\n\t\treturn helper(2, 30, 40);\n\t}\n\n'
			+ '\tstatic function helper(unused:Int, b:Int, c:Int):Int {\n\t\treturn b + c;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfp', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isFalse(
			out.indexOf('helper(b:Int, c:Int)') != -1 && out.indexOf('helper(1, 10, 20)') != -1,
			'unused-parameter dropped the param but prefer-ternary kept the call arg -> arity mismatch: $out'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `ext` is written ONLY from B.hx; A is made active for pass 2 by a redundant-else
	 * fix. `prefer-final-public-field` is in the `--fix` loop's `fullScopeIds`, so pass 2
	 * over the subset {A} still includes B's `a.ext = 9` write and `ext` stays `var`.
	 * Were the check active-scope, pass 2 would re-lint {A} alone, see no write, and
	 * wrongly rewrite it to `final` — breaking B's write. Guard-free: File is
	 * imported under the file's `#if (sys || nodejs)` and every test target satisfies it.
	 */
	public function testPreferFinalPublicFieldFullScopeAcrossPasses(): Void {
		final a: String = 'package p;\n\nclass A {\n\tpublic var ext:Int = 0;\n\n\tpublic function u():Int {\n\t\tif (c) return 1;\n'
			+ '\t\telse return 2;\n\t}\n}\n';
		final b: String = 'package p;\n\nclass B {\n\tpublic function poke(a:A):Void {\n\t\ta.ext = 9;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfpf', [{ name: 'A.hx', source: a }, { name: 'B.hx', source: b }]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('else') == -1, 'redundant else de-nested (pass 1 ran): $outA');
		Assert.isTrue(outA.indexOf('public var ext') != -1, 'ext kept var — written cross-file from B: $outA');
		CliFixture.removeDir(dir);
	}

	/**
	 * `Holder` (with two `Map` fields) is declared in a SEPARATE file, so resolving the nested
	 * receiver paths `h.byId` / `h.other` needs a file A.hx does not contain. Pass 1 (whole set
	 * active) converts the OUTER get and defers the contained inner one; that edit makes A active
	 * for pass 2. `prefer-index-access` is registered in the `--fix` loop's `fullScopeIds`, so
	 * pass 2 over the subset {A} still sees Holder.hx, resolves `h.other` to `Map`, and converts
	 * the inner get too. Were the check active-scope, pass 2 would re-lint {A} alone, read
	 * `h.other` as unresolvable, and leave the inner `.get(` behind — a converged fixed point that
	 * still has a Map get spelled as a call.
	 */
	public function testPreferIndexAccessFullScopeAcrossPasses(): Void {
		#if (sys || nodejs)
		final holder: String = 'package p;\n\nclass Holder {\n\tpublic var byId:Map<Int, Int>;\n\tpublic var other:Map<Int, Int>;\n}\n';
		final a: String = 'package p;\n\nclass A {\n\tpublic function f(h:Holder):Int {\n\t\treturn h.byId.get(h.other.get(0));\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixpia', [{ name: 'Holder.hx', source: holder }, { name: 'A.hx', source: a }]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('h.byId[h.other[0]]') != -1, 'both nested Map gets converted across passes: $outA');
		Assert.isTrue(outA.indexOf('.get(') == -1, 'inner get resolved on the pass-2 subset via full scope: $outA');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRenameSkipsOverriddenBaseParam(): Void {
		#if (sys || nodejs)
		// A is unconfined (subtype B), so neither param is removable — both are `Info`.
		// The `_<name>` silence-rename is opt-in, so the fixture declares `renameSilence`.
		// `hook` is OVERRIDDEN by B, which USES `ctx`, so the rename gate leaves the base
		// param alone (renaming it to `_ctx` would misdescribe it); `solo` is not
		// overridden and IS silenced to `_dead`.
		final a: String =
			'package p;\n\nclass A {\n\tpublic function hook(ctx:Int):Void {}\n\n\tpublic function solo(dead:Int):Void {}\n}\n';
		final b: String = 'package p;\n\nclass B extends A {\n\toverride public function hook(ctx:Int):Void {\n\t\ttrace(ctx);\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixrename', [
			{ name: 'A.hx', source: a },
			{ name: 'B.hx', source: b },
			{ name: 'apqlint.json', source: '{"rules": {"unused-parameter": {"renameSilence": true}}}' }
		]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('hook(ctx:Int)') != -1, 'overridden base param kept, not renamed: $outA');
		Assert.isTrue(outA.indexOf('solo(_dead:Int)') != -1, 'non-overridden param renamed to _dead: $outA');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testPreferInlineFullScopeAcrossPasses(): Void {
		#if (sys || nodejs)
		// A's getW is a single-expression method OVERRIDDEN by B. A is made active for pass 2
		// by prefer-inline's OWN pass-1 fix of useX. `prefer-inline` must be in the --fix loop's
		// `fullScopeIds`: on the pass-2 subset {A} an active-scope check would not see B, wrongly
		// conclude getW has no override, and inline it — a "Field getW is inlined and cannot be
		// overridden" compile error at B.
		final a: String =
			'package p;\n\nclass A {\n\tpublic function useX():Int\n\t\treturn 1;\n\n\tpublic function getW():Int\n\t\treturn 2;\n}\n';
		final b: String = 'package p;\n\nclass B extends A {\n\toverride public function getW():Int\n\t\treturn 3;\n}\n';
		final dir: String = CliFixture.writeDir('fixpinl', [{ name: 'A.hx', source: a }, { name: 'B.hx', source: b }]);
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-inline', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('inline function useX') != -1, 'non-overridden useX inlined (pass 1 ran): $outA');
		Assert.isTrue(outA.indexOf('inline function getW') == -1, 'overridden getW NOT inlined — B stayed visible on every pass: $outA');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The defect: `--fix` reported a rule that HAS an autofix and one that has none in exactly the
	 * same way, and its own tail spelled the ambiguity out rather than resolving it — "the check has
	 * no autofix, or when its fix declined here". Two queue items were written on the wrong branch of
	 * that `or`, for two rules that each had a working fix.
	 *
	 * So the four situations must get four DIFFERENT sentences, and the one a rule declared nothing
	 * about must get the OBSERVATION (the fix was called, no edit came back) rather than a verdict.
	 */
	@:access(anyparse.query.Cli)
	public function testUnfixedLedgerTellsNoAutofixApartFromDeclinedHere(): Void {
		final lines: Array<String> = LintFixLedger.unfixedFixLedger([
			'complexity' => outcome(3, 3, 0),
			'prefer-typed-throw' => outcome(9, 9, 0, [{ text: 'a String catch clause is in scope', count: 9 }]),
			'naming' => outcome(7, 2, 5),
			'magic-number' => outcome(1, 1, 0)
		], ['complexity' => 'which decomposition is right is a human call'], [], []);
		final all: String = lines.join('');
		Assert.isTrue(
			all.indexOf('complexity 3: no autofix by design — which decomposition is right is a human call') >= 0,
			'a rule that DECLARED it cannot fix says so, with its reason - got: $all'
		);
		Assert.isTrue(
			all.indexOf('prefer-typed-throw 9: fix DECLINED — a String catch clause is in scope') >= 0,
			'a declined finding carries the gate that withheld it - got: $all'
		);
		Assert.isTrue(
			all.indexOf('naming 2 of 7: fix declined here, yet the rule produced 5 edit(s) elsewhere') >= 0,
			'a rule that fixed elsewhere this run is PROVED to have an autofix, and the row shows the gap - got: $all'
		);
		Assert.isTrue(
			all.indexOf('magic-number 1: its fix was called') >= 0, 'an undeclared rule gets the observation, never a verdict - got: $all'
		);
		Assert.isTrue(
			all.indexOf('declares neither NoAutofix nor a decline reason') >= 0,
			'and the observation names the DECLARATION as what is missing - got: $all'
		);
		Assert.isTrue(all.indexOf('15 reported finding(s) in 4 rule(s)') >= 0, 'the header totals the declined counts - got: $all');
	}

	/**
	 * A run that fixed everything it reported, and a run that reported nothing, both print no ledger
	 * — the block is about findings that got no edit, and a clean run must gain no noise.
	 */
	@:access(anyparse.query.Cli)
	public function testUnfixedLedgerIsSilentWhenNothingWasDeclined(): Void {
		final fixedEverything: Array<String> = LintFixLedger.unfixedFixLedger(['unused-import' => outcome(4, 0, 4)], [], [], []);
		Assert.equals(0, fixedEverything.length, 'nothing was declined, so there is nothing to explain');
		Assert.equals(0, LintFixLedger.unfixedFixLedger([], [], [], []).length, 'a clean run gains no noise');
	}

	/**
	 * A `RiskyFix` rule this run could not verify is never handed to the safe loop either, so no
	 * `fix` of its own is ever called and its row would be a silent zero. On Pony `avoid-dynamic`
	 * alone reports 470 findings; a block about what did not get fixed that simply omits the largest
	 * rule on the tree invites its own misreading, so those rules are named once at the end.
	 *
	 * The caller decides which rules those are, and since `FixVerifier` began carrying per-rule
	 * tallies it passes an EMPTY list whenever the risky phase actually ran — see
	 * `LintFixDeclineWiringSliceTest`, which pins both states of this sentence against a ledger the
	 * risky fold has filled. What is asserted here is the list-is-not-empty state: the phase did not
	 * run, and the block says so rather than losing the rules.
	 *
	 * An `OracleAssisted` rule that is not ALSO risky runs in the safe loop, so it has a row here
	 * either way. The first version of the disclaimer listed it as absent, one line under its own row.
	 */
	@:access(anyparse.query.Cli)
	public function testUnfixedLedgerNamesTheRulesItDoesNotCover(): Void {
		final all: String = LintFixLedger.unfixedFixLedger([
			'magic-number' => outcome(1, 1, 0),
			'explicit-local-type' => outcome(5, 5, 0)
		], [], ['explicit-local-type'], ['avoid-dynamic', 'prefer-inline']).join('');
		Assert.isTrue(all.indexOf('2 rule(s) are absent from this ledger') >= 0, 'the RISKY rules are counted - got: $all');
		Assert.isTrue(all.indexOf('avoid-dynamic, prefer-inline') >= 0, 'and named - got: $all');
		// An OracleAssisted rule that is not ALSO risky runs in the safe loop, so it has a row here.
		// The first version of this line listed it as absent, one line under its own row.
		Assert.isTrue(all.indexOf('explicit-local-type 5:') >= 0, 'an oracle-assisted rule still gets a row - got: $all');
		Assert.isTrue(
			all.indexOf('oracle-assisted pass besides') >= 0,
			'and its second fix path is noted ON the row, not by claiming the rule is missing - got: $all'
		);
	}

	/**
	 * Seventy-odd rules report on a real tree (74 on Pony), so the block names the biggest few and
	 * totals the rest — otherwise the answer to "what did not get fixed" is a wall nobody reads.
	 */
	@:access(anyparse.query.Cli)
	public function testUnfixedLedgerCapsTheRuleListAndTotalsTheRest(): Void {
		final all: String = LintFixLedger.unfixedFixLedger([
			'r1' => outcome(8, 8, 0),
			'r2' => outcome(7, 7, 0),
			'r3' => outcome(6, 6, 0),
			'r4' => outcome(5, 5, 0),
			'r5' => outcome(4, 4, 0),
			'r6' => outcome(3, 3, 0),
			'r7' => outcome(2, 2, 0),
			'r8' => outcome(1, 1, 0)
		], [], [], []).join('');
		Assert.isTrue(all.indexOf('r1 8:') >= 0 && all.indexOf('r6 3:') >= 0, 'the six biggest are named - got: $all');
		Assert.isTrue(all.indexOf('r7 2:') < 0, 'the seventh is not - got: $all');
		Assert.isTrue(all.indexOf('... +2 more rule(s), 3 finding(s)') >= 0, 'and the rest are totalled - got: $all');
	}

	/**
	 * A rule that declines for SEVERAL different reasons gets one line per reason, with the count
	 * that makes the shares readable.
	 *
	 * The ledger recorded the FIRST `Violation.declineReason` it saw and printed it as the rule's
	 * whole verdict, which was right while every converted rule declined for a single cause. The
	 * first rule to write the field per-ARM declines for four different ones on a single real tree
	 * — `unused-import` on Pony: 110 out-of-scope, 54 `#if`-guarded, 25 unknown `using`, 15 unknown
	 * wildcard — and naming whichever the file walk reached first states a quarter of the answer
	 * with the confidence of the whole.
	 */
	@:access(anyparse.query.Cli)
	public function testUnfixedLedgerSpellsOutEveryReasonWithItsCount(): Void {
		final all: String = LintFixLedger.unfixedFixLedger([
			'unused-import' => outcome(205, 204, 2, [
				{ text: 'the import is `#if`-guarded', count: 54 },
				{ text: 'the module is outside the lint scope', count: 110 },
				{ text: 'the `using` module is unknown', count: 25 },
				{ text: 'the wildcard symbol set is unknown', count: 15 }
			])
		], [], [], []).join('');
		Assert.isTrue(
			all.indexOf('unused-import 204 of 205: fix DECLINED, 4 distinct reason(s) over 204 finding(s)') >= 0,
			'the row heads the list with how many different answers there are - got: $all'
		);
		final biggest: Int = all.indexOf('110× the module is outside the lint scope');
		final second: Int = all.indexOf('54× the import is `#if`-guarded');
		final third: Int = all.indexOf('25× the `using` module is unknown');
		Assert.isTrue(biggest >= 0 && second >= 0 && third >= 0, 'each reason is spelled out with its own count - got: $all');
		Assert.isTrue(biggest < second && second < third, 'strongest share first, so the dominant cause reads first - got: $all');
		Assert.isTrue(all.indexOf('... +1 more reason(s), 15 finding(s)') >= 0, 'and the tail is totalled, not dropped - got: $all');
		Assert.isTrue(all.indexOf('15× the wildcard symbol set is unknown') < 0, 'the fourth reason is past the cap - got: $all');
		Assert.isTrue(
			all.indexOf('produced 2 edit(s) elsewhere') < 0,
			'a rule that SAID why never falls back to the measured arm, which says only that it did not - got: $all'
		);
	}

	/**
	 * The one-reason row keeps the exact bytes it has always printed, and a rule that spoke for only
	 * SOME of its declines says so rather than letting the reasons it gave stand for all of them.
	 */
	@:access(anyparse.query.Cli)
	public function testUnfixedLedgerKeepsOneReasonInlineAndOwnsTheRemainder(): Void {
		final one: String = LintFixLedger.unfixedFixLedger([
			'prefer-typed-throw' => outcome(9, 9, 0, [{ text: 'a String catch clause is in scope', count: 9 }])
		], [], [], [])
			.join('');
		Assert.isTrue(
			one.indexOf('prefer-typed-throw 9: fix DECLINED — a String catch clause is in scope\n') >= 0,
			'one reason covering every decline stays on the row, byte for byte - got: $one'
		);
		Assert.isTrue(one.indexOf('×') < 0, 'and gains no sub-line it does not need - got: $one');
		final partial: String = LintFixLedger.unfixedFixLedger([
			'naming' => outcome(10, 10, 0, [{ text: 'the method is an `override`', count: 4 }])
		], [], [], [])
			.join('');
		Assert.isTrue(
			partial.indexOf('4× the method is an `override`') >= 0, 'the reason that WAS given is shown with its share - got: $partial'
		);
		Assert.isTrue(
			partial.indexOf('6× — the check declared no reason for these') >= 0,
			'and the six the check said nothing about are reported, never rounded into the four it did - got: $partial'
		);
	}

	/**
	 * The mechanism behind `naming`'s wholesale zero on a project that ships a `checkstyle.json`,
	 * as a ONE-VARIABLE matrix: the same source, the same finding, the same format regex — and the
	 * only difference is where the policy came from.
	 *
	 * The loader used to map each naming check's `format` onto a rule and attach no `normalize`, so
	 * `correctedName` had nothing to return and every finding declined: `fixed 0` against `fixed 2`,
	 * with 198 of an 851-file tree's 231 findings taking the first arm. `CheckstyleConfigLoader.ruleFor`
	 * now asks `HaxeNamingSupport.normalizerFor` for the corrections the built-in policy attaches to the
	 * rule's own category, so both arms write the same edits.
	 *
	 * The two arms are asserted EQUAL to each other rather than each against a literal, because the
	 * property the matrix isolates is precisely that: where a policy came from does not change what it
	 * fixes. The correction is still self-checking twice over — `normalizerFor` keeps only a candidate
	 * the config's own format accepts, and `correctedName` re-verifies the survivor against it.
	 */
	public function testCheckstyleDerivedPolicyFixesTheRenameItsOwnFormatDemands(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass A {\n\n\tpublic function run():Void {\n\t\t_foo();\n\t}\n\n'
			+ '\tprivate function _foo():Void {\n\t\ttrace(1);\n\t}\n\n}\n';
		final checkstyle: String = '{\n\t"checks": [\n\t\t{\n\t\t\t"type": "MethodName",\n\t\t\t"props": {\n'
			+ '\t\t\t\t"format": "^[a-z][a-zA-Z0-9_]*$"\n\t\t\t}\n\t\t}\n\t]\n}\n';
		final configured: String = CliFixture.writeDir(
			'csnaming', [{ name: 'A.hx', source: src }, { name: 'checkstyle.json', source: checkstyle }]
		);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'naming', '$configured/A.hx']), 'lint --fix exits ok');
		final fromConfig: String = File.getContent('$configured/A.hx');
		CliFixture.removeDir(configured);
		final bare: String = CliFixture.writeDir('csnaming', [{ name: 'A.hx', source: src }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'naming', '$bare/A.hx']), 'lint --fix exits ok');
		final fromDefault: String = File.getContent('$bare/A.hx');
		CliFixture.removeDir(bare);
		Assert.isTrue(
			fromDefault.indexOf('_foo') == -1 && fromDefault.indexOf('function foo():Void') >= 0,
			'the built-in policy renames declaration and call site: $fromDefault'
		);
		Assert.equals(
			fromDefault, fromConfig, 'and the SAME regex fixes the SAME bytes when a project config is what states it: $fromConfig'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * One ledger row for a fixture, with the empty lists defaulted.
	 *
	 * The shape lives HERE and not seventeen times over: spelled inline, adding a field to
	 * `RuleFixOutcome` failed every literal at once with an anonymous-structure mismatch that named
	 * neither the type nor which field was missing.
	 */
	private static function outcome(
		reported: Int, declined: Int, edits: Int, ?reasons: Array<{ text: String, count: Int }>,
		?refusals: Array<{ text: String, count: Int }>
	): RuleFixOutcome {
		return {
			reported: reported,
			declined: declined,
			edits: edits,
			reasons: reasons ?? [],
			refusals: refusals ?? []
		};
	}

}

package unit;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.RedundantToString;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `redundant-tostring` check: a `.toString()` call whose position already stringifies — a
 * `${ … }` interpolation block, an operand of a `+` with a String, a `Std.string(...)` argument, or
 * a String receiver (the identity call). A STRING-REQUIRED position is never flagged, and a site
 * missing any of the three fix proofs (non-null receiver / the coercion calling the declared
 * `toString` / `+` really being concatenation) is reported without an edit.
 */
class RedundantToStringCheckTest extends Test {

	/**
	 * A project-declared class prefix: the check proves a receiver's coercion reaches its own
	 * `toString` only for a NON-EXTERN type declared in the analysed scope, so every context-arm
	 * fixture has to declare the receiver's type.
	 */
	private static inline final DECL_K: String = "class K { public function toString():String return 'k'; } ";

	/** An abstract prefix: non-extern and declared, so only the `+` arm's operator proof can reject it. */
	private static inline final DECL_ABSTRACT: String = "abstract Tag(String) { public function toString():String return 'tag'; } ";

	public function testInterpolationIdentCollapsesToShorthand(): Void {
		final out: String = applyFix('$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${x.toString()}\'; } }');
		Assert.isTrue(out.indexOf("'$x'") != -1, 'expected the shorthand form, got: $out');
	}

	public function testInterpolationExpressionKeepsBraces(): Void {
		// A non-identifier receiver has no shorthand; only the call text goes away. `new K()` also
		// proves non-null on its own, so no null-safety annotation is needed here.
		final out: String = applyFix('${DECL_K}class C { function f() { final s:String = \'$${new K().toString()}\'; } }');
		Assert.isTrue(out.indexOf("'${new K()}'") != -1, 'expected the braced form, got: $out');
	}

	public function testInterpolationCollapseRefusedBeforeIdentChar(): Void {
		// Collapsing here would read the local `xabc`, so the braces must stay.
		final out: String = applyFix(
			'$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${x.toString()}abc\'; } }'
		);
		Assert.isTrue(out.indexOf("'${x}abc'") != -1, 'expected braces kept, got: $out');
	}

	public function testInterpolationCollapseRefusedInEscapedLiteral(): Void {
		// Haxe decodes escapes BEFORE scanning for interpolation, so `\x61` is an `a` that would
		// extend a `$x` read into `xa`. The literal carrying an escape refuses the shorthand.
		final out: String = applyFix(
			'$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${x.toString()}\\x61\'; } }'
		);
		Assert.isTrue(out.indexOf("'${x}\\x61'") != -1, 'expected braces kept, got: $out');
	}

	public function testInterpolationCollapseRefusedWithSpacing(): Void {
		// The block must hold the call and NOTHING else: spacing inside it would be lost by the
		// shorthand, so the plain drop is used. Span arithmetic decides it — the block spans exactly
		// `$`, `{`, the call, `}` when there is no slack.
		final out: String = applyFix(
			'$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${ x.toString() }\'; } }'
		);
		Assert.isTrue(out.indexOf("'${ x }'") != -1, 'expected the spacing kept, got: $out');
	}

	public function testFixIgnoresUnreportedSpans(): Void {
		// `fix` edits only what the violations name, so a caller filtering its findings gets a
		// filtered edit set rather than every candidate the collector re-finds.
		final src: String = '$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${x.toString()}\'; } }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(1, edits(src).length);
		Assert.equals(0, new RedundantToString().fix(src, [], plugin).length);
	}

	public function testNullableReceiverReportedNotFixed(): Void {
		// No null-safety in scope, so `x` is not provably non-null: reported, never rewritten.
		final src: String = '${DECL_K}class C { function f(x:K) { final s:String = \'$${x.toString()}\'; } }';
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('non-null') != -1, 'message should name the missing proof: ${found[0].message}');
		Assert.equals(0, edits(src).length);
	}

	/**
	 * The blocker that withheld the edit is written onto the finding as its `declineReason`, and a
	 * FIXABLE finding carries none.
	 *
	 * The blocker is already the second half of the message ("…, but $blocker"), so the run had the
	 * sentence and simply did not put it where `apq lint --fix`'s ledger reads it — the ledger then
	 * reported that this check "declares neither NoAutofix nor a decline reason".
	 *
	 * RED at base on the first `notNull`; the fixable arm below is green at base BY CONSTRUCTION and
	 * is the discriminator — writing a reason unconditionally turns only IT red.
	 */
	public function testBlockedSiteCarriesItsBlockerAsTheDeclineReason(): Void {
		final blocked: String = '${DECL_K}class C { function f(x:K) { final s:String = \'$${x.toString()}\'; } }';
		final found: Array<Violation> = violations(blocked);
		Assert.equals(1, found.length);
		final reason: Null<String> = found[0].declineReason;
		if (reason == null) {
			Assert.fail('a blocked site carries no decline reason though its message states one: ${found[0].message}');
			return;
		}
		Assert.isTrue(reason.indexOf('non-null') != -1, reason);
		Assert.isTrue(found[0].message.indexOf(reason) != -1, 'the reason is the message\'s own blocker clause, verbatim');
		Assert.equals(0, edits(blocked).length);

		final fixable: String = '$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${x.toString()}\'; } }';
		final clean: Array<Violation> = violations(fixable);
		Assert.equals(1, clean.length);
		Assert.isNull(clean[0].declineReason, 'a site that DOES get an edit declines nothing');
		Assert.equals(1, edits(fixable).length);
	}

	public function testNullLiteralReceiverReportedNotFixed(): Void {
		final src: String = "class C { function f() { final s:String = '${null.toString()}'; } }";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testExternReceiverTypeReportedNotFixed(): Void {
		// An extern type's `toString` is a declaration over a foreign runtime object; the coercion
		// may reach a different method entirely (js `Date` / `Array`), so the fix is withheld.
		final src: String = 'extern class Ext { function toString():String; } '
			+ "@:nullSafety(Strict) class C { function f(x:Ext) { final s:String = '${x.toString()}'; } }";
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('extern') != -1, 'message should name the missing proof: ${found[0].message}');
		Assert.equals(0, edits(src).length);
	}

	/**
	 * The same proof, end-to-end, for a receiver type whose `extern` modifier is GUARDED —
	 * `#if js extern class Ext {…} #end` — rather than written unconditionally. This pins that
	 * `SymbolIndexBuilder`'s guarded-`extern` lift (`pushGuardedDecl`) actually reaches this
	 * check's gate: before that fix, a guarded extern indexed as `isExtern == false`, so this
	 * site would have been fixed instead of withheld — the exact false-positive rewrite the
	 * unconditional sibling test above exists to prevent.
	 */
	public function testGuardedExternReceiverTypeReportedNotFixed(): Void {
		final src: String = '#if js\nextern class Ext { function toString():String; }\n#end\n'
			+ "@:nullSafety(Strict) class C { function f(x:Ext) { final s:String = '${x.toString()}'; } }";
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('extern') != -1, 'message should name the missing proof: ${found[0].message}');
		Assert.equals(0, edits(src).length);
	}

	public function testUnresolvedReceiverTypeReportedNotFixed(): Void {
		// `K` is not declared in the analysed scope at all — same conservative default as extern.
		final src: String = "@:nullSafety(Strict) class C { function f(x:K) { final s:String = '${x.toString()}'; } }";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testStdlibDateReceiverReportedNotFixed(): Void {
		// `Date.now` IS a curated non-null static return, so the null proof passes — and the fix is
		// still withheld, because `extern class Date`'s `toString` and its string coercion diverge
		// on js. Pins that the TYPE proof, not the null proof, is what stops this one.
		final src: String = "class C { function f() { final s:String = '${Date.now().toString()}'; } }";
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('extern') != -1, 'expected the type proof to block: ${found[0].message}');
		Assert.equals(0, edits(src).length);
	}

	public function testConcatWithStringOperandFlagged(): Void {
		final out: String = applyFix(
			'$DECL_K@:nullSafety(Strict) class C { function f(s:String, x:K) { final r:String = s + x.toString(); } }'
		);
		Assert.isTrue(out.indexOf('= s + x;') != -1, 'expected the call dropped, got: $out');
	}

	public function testConcatWithStringLiteralFlagged(): Void {
		final out: String = applyFix('$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final r:String = \'a\' + x.toString(); } }');
		Assert.isTrue(out.indexOf("'a' + x;") != -1, 'expected the call dropped, got: $out');
	}

	public function testConcatWithNonStringOperandNotFlagged(): Void {
		Assert.equals(
			0, violations('$DECL_K@:nullSafety(Strict) class C { function f(n:Int, x:K) { final r:String = n + x.toString(); } }').length
		);
	}

	public function testConcatAbstractReceiverReportedNotFixed(): Void {
		// An abstract may overload `@:op(A + B)`, and the overload beats the concatenation rule.
		final src: String =
			'$DECL_ABSTRACT@:nullSafety(Strict) class C { function f(s:String, t:Tag) { final r:String = s + t.toString(); } }';
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('not a class') != -1, 'expected the operator proof to block: ${found[0].message}');
		Assert.equals(0, edits(src).length);
	}

	public function testInterpolationAbstractReceiverFixed(): Void {
		// The SAME abstract receiver is fine in an interpolation: no `+` is resolved there, and Haxe
		// routes an abstract's stringification through its own `toString`.
		final out: String = applyFix(
			'$DECL_ABSTRACT@:nullSafety(Strict) class C { function f(t:Tag) { final s:String = \'$${t.toString()}\'; } }'
		);
		Assert.isTrue(out.indexOf("'$t'") != -1, 'expected the shorthand form, got: $out');
	}

	public function testChainedCallNotFlagged(): Void {
		// The call is the RECEIVER of `.substr`, not a direct operand of the `+`.
		Assert.equals(
			0,
			violations('$DECL_K@:nullSafety(Strict) class C { function f(s:String, x:K) { final r:String = s + x.toString().substr(0); } }')
				.length
		);
	}

	public function testStdStringArgumentFlagged(): Void {
		final out: String = applyFix(
			'$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final r:String = Std.string(x.toString()); } }'
		);
		Assert.isTrue(out.indexOf('Std.string(x)') != -1, 'expected the inner call dropped, got: $out');
	}

	public function testStdShadowedByLocalNotFlagged(): Void {
		// A local named `Std` is not the class, so this is not the stringifying call the arm assumes.
		Assert.equals(
			0,
			violations('$DECL_K@:nullSafety(Strict) class C { function f(x:K, Std:K) { final r:String = Std.string(x.toString()); } }')
				.length
		);
	}

	public function testStringReceiverIsIdentity(): Void {
		// The identity arm needs no type proof: `String` is nowhere declared here, and the call
		// performs no coercion at all.
		final out: String = applyFix('@:nullSafety(Strict) class C { function f(s:String) { final r:String = s.toString(); } }');
		Assert.isTrue(out.indexOf('= s;') != -1, 'expected the identity call dropped, got: $out');
	}

	public function testStringRequiredVarNotFlagged(): Void {
		// Anonymized from a real crash-reporter helper: a String-typed initializer is NOT a
		// stringifying context — Haxe has no implicit conversion there, so dropping the call
		// would not compile.
		Assert.equals(
			0,
			violations(
				"class Ticket { public static function makeId(prefix:String = ''):String { var now:String = Date.now().toString(); while "
				+ "(now.indexOf(' ') != -1) now = now.replace(' ', '_'); return prefix + now; } }"
			).length
		);
	}

	public function testStringRequiredParameterNotFlagged(): Void {
		Assert.equals(
			0,
			violations('$DECL_K@:nullSafety(Strict) class C { function f(x:K) { g(x.toString()); } function g(s:String):Void {} }').length
		);
	}

	public function testStringRequiredReturnNotFlagged(): Void {
		Assert.equals(0, violations('$DECL_K@:nullSafety(Strict) class C { function f(x:K):String { return x.toString(); } }').length);
	}

	public function testArgumentBearingCallNotFlagged(): Void {
		// A BOUND receiver with an argument: only the zero-argument gate can reject this one, so it
		// discriminates that gate rather than the static-receiver gate beside it.
		Assert.equals(
			0, violations('$DECL_K@:nullSafety(Strict) class C { function f(x:K) { final s:String = \'$${x.toString(2)}\'; } }').length
		);
	}

	public function testStaticToStringWithArgumentNotFlagged(): Void {
		// `Trace.toString(e.stack)` is a static helper, not a stringification of a receiver.
		Assert.equals(0, violations("class C { function f(e:Err) { final s:String = '$e${Trace.toString(e.stack)}'; } }").length);
	}

	public function testZeroArgStaticToStringNotFlagged(): Void {
		// Dropping this would leave a bare type reference.
		Assert.equals(0, violations("class C { function f() { final s:String = '${Env.toString()}'; } }").length);
	}

	public function testCommentInRemovedTextSuppressesFix(): Void {
		final src: String =
			'$DECL_K@:nullSafety(Strict) class C { function f(s:String, x:K) { final r:String = s + x /* keep */ .toString(); } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testInstanceCallReceiverProvenOnlyWithWholeScope(): Void {
		// The instance-call null proof reads the DECLARING file's return annotation through the
		// index, so the same source is fixable with the whole scope and report-only without it.
		final other: { file: String, source: String } = {
			file: 'Src.hx',
			source: '${DECL_K}class Src { public function make():K return new K(); }'
		};
		final src: String = "@:nullSafety(Strict) class C { function f(o:Src) { final s:String = '${o.make().toString()}'; } }";
		final wide: Array<Violation> = new RedundantToString().run([other, { file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, wide.length);
		Assert.isTrue(wide[0].message.indexOf('but ') == -1, 'whole-scope run should prove the site: ${wide[0].message}');
		Assert.equals(1, violations(src).length);
		Assert.isTrue(violations(src)[0].message.indexOf('non-null') != -1, 'single-file run should miss the proof');
	}

	public function testFlaggedAsInfo(): Void {
		final found: Array<Violation> =
			violations('@:nullSafety(Strict) class C { function f(s:String) { final r:String = s.toString(); } }');
		Assert.equals(1, found.length);
		Assert.equals('redundant-tostring', found[0].rule);
		Assert.equals(Severity.Info, found[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantToString().run([{ file: 'Bad.hx', source: 'class Bad { function f() { x.toString(' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('redundant-tostring');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'redundant-tostring is opt-in');
		Assert.equals(178, Linter.builtins().length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantToString().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The check's edits for `src`, driven with the whole-scope index `Cli` always supplies. */
	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: RedundantToString = new RedundantToString();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run(files, plugin);
		return check.fix(src, found, plugin, SymbolIndex.build(files, plugin));
	}

	private function applyFix(src: String): String {
		final applied: Array<{ span: Span, text: String }> = edits(src);
		applied.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (edit in applied) result = result.substring(0, edit.span.from) + edit.text + result.substring(edit.span.to);
		return result;
	}

}

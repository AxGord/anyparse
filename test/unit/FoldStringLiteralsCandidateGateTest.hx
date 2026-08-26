package unit;

import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;

using StringTools;

/**
 * The CANDIDATE gate of `fold-adjacent-string-literals`: the positions a
 * concatenation is never rewritten in, and the call-target resolution that decides
 * the one position where it may be.
 *
 * A `case` pattern, a default parameter value, an `enum abstract` value (plain,
 * deprecated `@:enum` or `#if`-guarded), an inline field value, a module-level
 * inline value and a metadata string argument are all compile-time-constant slots
 * and are never candidates. A MACRO argument is reported but not fixed — rewriting
 * one a macro pattern-matches breaks it silently — unless the target is listed in
 * the per-file `concatFoldingMacros` whitelist; a call whose declaration is out of
 * scope stays refused under every spelling, while a resolvable plain call is fixed.
 */
class FoldStringLiteralsCandidateGateTest extends FoldStringLiteralsCheckTestBase {

	/** The macro-whitelist option name, which the refusal message names so a reader knows what lifts it. */
	private static inline final WHITELIST_OPTION: String = 'concatFoldingMacros';

	/** The rule id, which every finding here is asserted to carry. */
	private static inline final RULE: String = 'fold-adjacent-string-literals';

	/** The words the INTRINSIC refusal names itself by — distinct from the macro one, which names the whitelist option. */
	private static inline final INTRINSIC_MARKER: String = 'compiler intrinsic';

	/** A string literal in an ANNOTATION argument is parsed as an expression — moving a `$` into it changes the annotation. */
	public function testMetadataStringArgumentNotTouched(): Void {
		Assert.equals(0, violations("@:native('a' + 'b') class C { function f() {} }").length);
	}

	/**
	 * Gate (2): a concatenation is not a legal `case` pattern (`Unrecognized pattern`
	 * on Haxe 4.3.7), so a literal in pattern position is skipped whatever its width.
	 */
	public function testCasePatternIsNotACandidate(): Void {
		Assert.equals(0, violations(casePatternSource(100, 60)).length);
	}

	/**
	 * Gate (3): a default argument value must be constant (`Default argument value
	 * should be constant` on Haxe 4.3.7), so a parameter's default is skipped.
	 */
	public function testDefaultParamValueIsNotACandidate(): Void {
		Assert.equals(0, violations(defaultParamSource(100, 60)).length);
	}

	/**
	 * Gate (3): an enum-abstract VALUE folded to a concatenation still compiles, but
	 * it stops being usable as a `case` pattern (`Unknown identifier` on Haxe 4.3.7) —
	 * the consumer sees the expression SHAPE, so the value is skipped.
	 */
	public function testEnumAbstractValueIsNotACandidate(): Void {
		Assert.equals(0, violations(enumAbstractSource(100, 60)).length);
	}

	/**
	 * The DEPRECATED `@:enum abstract` spelling is the same declaration and breaks the
	 * same way, but it projects as a plain `AbstractDecl` with the annotation as a
	 * SIBLING — so a gate that tested the declaration's KIND folded its values.
	 */
	public function testDeprecatedEnumAbstractValueIsNotACandidate(): Void {
		Assert.equals(0, violations(deprecatedEnumAbstractSource(100, 60)).length);
	}

	/**
	 * A `#if`-guarded value sits one level down, under the conditional region rather than
	 * under the declaration — a gate that asked only about the immediate parent was blind
	 * to it.
	 */
	public function testGuardedEnumAbstractValueIsNotACandidate(): Void {
		Assert.equals(0, violations(guardedEnumAbstractSource(100, 60)).length);
	}

	/**
	 * An `inline` field's value IS a compile-time constant at every use site, so a `case`
	 * pattern reads its expression shape exactly as it reads an enum-abstract value's
	 * (`case S:` becomes an "Unknown identifier" once `S` folds). The modifier is a
	 * preceding SIBLING, invisible from the field node itself.
	 */
	public function testInlineFieldValueIsNotACandidate(): Void {
		Assert.equals(0, violations(inlineFieldSource(100, 60)).length);
		Assert.equals(1, violations(inlineFieldSource(100, 60).replace('static inline final', 'static final')).length);
	}

	/**
	 * A MODULE-LEVEL `inline final` is the same compile-time constant and breaks the same
	 * `case S:` — but it is a top-level declaration, not a member, so a gate that asked
	 * for a member KIND folded it.
	 */
	public function testModuleLevelInlineValueIsNotACandidate(): Void {
		final literal: String = '\'${''.rpad('A', 100)}\\n${''.rpad('B', 60)}\'';
		Assert.equals(0, violations('inline final S:String = $literal;\n').length);
		Assert.equals(1, violations('final S:String = $literal;\n').length);
	}

	/**
	 * The modifier run ends at EVERY declaration, not only at a member. Ending it at a
	 * member left the `@:enum` of a deprecated enum abstract set for the rest of the
	 * MODULE — a type declaration being no member kind — so every later type's field
	 * values were silently exempt.
	 */
	public function testEnumAbstractRunEndsAtItsOwnDeclaration(): Void {
		final literal: String = '\'${''.rpad('A', 100)}\\n${''.rpad('B', 60)}\'';
		Assert.equals(1, violations('${deprecatedEnumAbstractSource(4, 4)}\nclass C {\n\tstatic final S:String = $literal;\n}').length);
	}

	/**
	 * Gate (1): a macro argument is reported but NOT fixed — a macro pattern-matching
	 * `EConst(CString)` breaks silently on a concatenation, and no structural check can
	 * see whether it folds.
	 */
	public function testMacroArgumentIsReportedButNotFixed(): Void {
		final files: Array<{ file: String, source: String }> = macroArgFiles(100, 60);
		final check: FoldStringLiterals = new FoldStringLiterals();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf(WHITELIST_OPTION) != -1);
		Assert.equals(0, check.fix(files[1].source, vs, new HaxeQueryPlugin()).length);
	}

	/** A macro PROVEN to fold `+` chains of constants is whitelisted by qualified path, and its arguments become fixable. */
	public function testWhitelistedMacroArgumentIsFixed(): Void {
		final files: Array<{ file: String, source: String }> = macroArgFiles(100, 60);
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"$RULE":{"$WHITELIST_OPTION":["m.Lang.t"]}}}'));
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(files[1].source, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		Assert.equals('\'${''.rpad('A', 100)}\\n\' + \'${''.rpad('B', 60)}\'', edits[0].text);
	}

	/** A call the file imports nothing for cannot be routed to an unseen macro, so its arguments fold as usual. */
	public function testPlainCallArgumentIsFixed(): Void {
		Assert.equals(
			'\'${''.rpad('A', 100)}\\n\' + \'${''.rpad('B', 60)}\'', foldOf(rawSource('\'${''.rpad('A', 100)}\\n${''.rpad('B', 60)}\''))
		);
	}

	/**
	 * The gate's second refusal. The index covers only what the INVOCATION reaches, so
	 * linting the caller ALONE cannot see `m.Lang.t`'s `macro` modifier — and reading
	 * that as "not a macro" would rewrite the argument, making `--fix` answer differently
	 * depending on how the linter was called. The file's own `import m.Lang.t` binds the
	 * name, which is what makes the unresolved answer refusable rather than merely
	 * unknown.
	 */
	public function testMacroArgumentStaysRefusedWhenTheDeclarationIsOutOfScope(): Void {
		final caller: { file: String, source: String } = macroArgFiles(100, 60)[1];
		final check: FoldStringLiterals = new FoldStringLiterals();
		final vs: Array<Violation> = check.run([caller], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf(WHITELIST_OPTION) != -1);
		Assert.equals(0, check.fix(caller.source, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * Every spelling that can route the call to an out-of-scope declaration refuses, and
	 * the two that CANNOT do not. The gate reads the import's KIND, not just its path: a
	 * wildcard and a `using` bind every name in the file, which is why an unresolved call
	 * under either is refused whatever it is called.
	 */
	public function testEveryOutOfScopeCallSpellingIsRefused(): Void {
		for (spelling in [
			{ imports: 'import m.Lang.t;', call: 't' },
			{ imports: 'import m.Lang;', call: 'Lang.t' },
			{ imports: 'import m.Lang as L;', call: 'L.t' },
			{ imports: 'import m.*;', call: 'Lang.t' },
			{ imports: 'import m.Lang.*;', call: 't' },
			{ imports: 'using m.Ext;', call: 'x.t' },
			{ imports: '', call: 'm.Lang.t' }
		])
			Assert.isTrue(
				refusedIn(outOfScopeCallSource(spelling.imports, spelling.call)),
				'expected a refusal for ${spelling.imports} ${spelling.call}'
			);
	}

	/**
	 * The refusal costs nothing where the source cannot route the call anywhere unseen: a
	 * bare call the file imports nothing for is local, inherited or global, and a
	 * receiver whose TYPE the index carries is resolved. Asked against the same gate as
	 * the refusals above, so the pair discriminates rather than merely agreeing.
	 */
	public function testResolvableCallsAreNotRefused(): Void {
		Assert.isFalse(refusedIn(outOfScopeCallSource('', 'g2')));
		Assert.isFalse(refusedIn(outOfScopeCallSource('class Lang { public static function t(v:String):String return v; }', 'Lang.t')));
	}

	/** A whitelisted target clears the refusal whichever spelling the call site used — the entry and the call meet by dotted suffix. */
	public function testWhitelistClearsAnOutOfScopeCall(): Void {
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"$RULE":{"$WHITELIST_OPTION":["m.Lang.t"]}}}'));
		for (spelling in [
			{ imports: 'import m.Lang.t;', call: 't' },
			{ imports: 'import m.Lang;', call: 'Lang.t' },
			{ imports: '', call: 'm.Lang.t' }
		]) {
			final src: String = outOfScopeCallSource(spelling.imports, spelling.call);
			final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
			Assert.equals(1, vs.length);
			Assert.equals(1, check.fix(src, vs, new HaxeQueryPlugin()).length, 'expected a fix for ${spelling.imports} ${spelling.call}');
		}
	}

	/**
	 * The whitelist is read from the file's OWN discovered config, not from the run's
	 * first file — one `lint` invocation can span projects that disagree about which
	 * macros fold, and applying one project's claim to another's code rewrites an
	 * argument nobody cleared.
	 */
	public function testWhitelistIsResolvedPerFile(): Void {
		final files: Array<{ file: String, source: String }> = macroArgFiles(100, 60);
		final other: { file: String, source: String } = { file: 'other/D.hx', source: files[1].source };
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(path -> LintConfig.parse(path == 'C.hx' ? '{"rules":{"$RULE":{"$WHITELIST_OPTION":["m.Lang.t"]}}}' : '{}'));
		final vs: Array<Violation> = check.run([files[0], files[1], other], new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		Assert.equals(1, check.fix(files[1].source, vs.filter(v -> v.file == 'C.hx'), new HaxeQueryPlugin()).length);
		Assert.equals(0, check.fix(other.source, vs.filter(v -> v.file == other.file), new HaxeQueryPlugin()).length);
	}

	/**
	 * The gate's THIRD refusal, and the one the other two are structurally blind to. Both of
	 * them are questions about RESOLUTION — "does a `macro` member declare this name", "could an
	 * import route it out of scope" — and a target INTRINSIC answers no to both because it has no
	 * declaration anywhere: the fall-through then reads the call as local, inherited or global and
	 * lets it through. Fail-OPEN, on exactly the family that never resolves.
	 *
	 * Measured on Haxe 4.3.7: `untyped __lua__("{x=" + "1}")` compiles with NO diagnostic and emits
	 * `__lua__(Std.string("{x=") .. Std.string("1}"))` — a call to a Lua function no runtime
	 * declares; `js.Syntax.code` rejects the same shape with "must be a string constant".
	 */
	public function testIntrinsicArgumentIsReportedButNotFixed(): Void {
		final src: String = intrinsicCallSource('__lua__', overLongLiteral());
		Assert.isTrue(refusedIn(src));
		Assert.isTrue(violations(src)[0].message.indexOf(INTRINSIC_MARKER) != -1);
	}

	/**
	 * `$WHITELIST_OPTION` does not lift it, unlike every macro refusal above. Listing a macro is a
	 * claim a project can make about code it owns; listing `__lua__` would be a claim about the
	 * COMPILER's own generator, and the claim is the one the measurement refutes.
	 */
	public function testIntrinsicRefusalIsNotWhitelistable(): Void {
		Assert.isTrue(refusedWhitelisting(intrinsicCallSource('__lua__', overLongLiteral()), '__lua__'));
		Assert.isFalse(refusedWhitelisting(outOfScopeCallSource('import m.Lang.t;', 't'), 'm.Lang.t'));
	}

	/**
	 * What the refusal reads, spelled as a one-variable matrix so it discriminates rather than
	 * merely agreeing. The affix is required at BOTH ends: `__hxcpp_cast_get_proc_address` carries
	 * the leading `__` and is an ordinary prim taking runtime strings, and the std passes it a `+`
	 * chain today. A RECEIVER also clears it — an intrinsic is never written with one, while
	 * `x.__next__(…)` is an ordinary member call to a target-magic method name.
	 */
	public function testOnlyABareDunderAffixedCalleeIsAnIntrinsic(): Void {
		Assert.isFalse(refusedIn(intrinsicCallSource('__hxcpp_cast_get_proc_address', overLongLiteral())));
		Assert.isFalse(refusedIn(intrinsicCallSource('x.__next__', overLongLiteral())));
		Assert.isTrue(refusedIn(intrinsicCallSource('__lua__', overLongLiteral())));
	}

	/**
	 * The exemption is a CONSTANT plan, not a one-group one — the distinction the macro gate's own
	 * `groups < 2` misses. Merging to a single PLAIN literal is what the target wants and is applied;
	 * merging to a single INTERPOLATED literal is not a constant at all, since Haxe desugars `'a$k'`
	 * back into a `+` chain before anything reads the argument as syntax, and both spellings emit the
	 * identical broken `__lua__(Std.string(…) .. Std.string(…))` (4.3.7).
	 */
	public function testIntrinsicKeepsTheConstantMergeAndRefusesTheInterpolatedOne(): Void {
		Assert.equals('"ab"', foldOf(intrinsicCallSource('__lua__', '"a" + "b"')));
		Assert.equals('', foldOf(intrinsicCallSource('__lua__', '"a" + k')));
		Assert.equals("'a$k'", foldOf(intrinsicCallSource('g', '"a" + k')));
	}

	/** A statement passing `<arg>` to `untyped <call>(…)` — the spelling every resolution gate reads as unresolvable. */
	private function intrinsicCallSource(call: String, arg: String): String {
		return 'class C {\n\tfunction f(k:String, x:Dynamic) {\n\t\tuntyped $call($arg);\n\t}\n}';
	}

	/** The over-long literal the split-direction fixtures share — one `\n` seam, both halves past the budget. */
	private function overLongLiteral(): String {
		return '\'${''.rpad('A', 100)}\\n${''.rpad('B', 60)}\'';
	}

	/** The same over-long literal in `case` PATTERN position, where a concatenation is not legal syntax. */
	private function casePatternSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return 'class C {\n\tfunction f(s:String) {\n\t\tswitch (s) {\n\t\t\tcase $literal: g(1);\n\t\t\tcase _: g(2);\n\t\t}\n\t}\n}';
	}

	/** The same over-long literal as a parameter DEFAULT, where the compiler requires a constant. */
	private function defaultParamSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return 'class C {\n\tfunction f(s:String = $literal) {\n\t\tg(s);\n\t}\n}';
	}

	/** The same over-long literal as an enum-abstract VALUE, which its `case` consumers read as a shape. */
	private function enumAbstractSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return 'enum abstract E(String) {\n\tvar A = $literal;\n\tvar B = \'b\';\n}';
	}

	/** The same declaration in Haxe's deprecated spelling: a PLAIN abstract carrying an `@:enum` annotation sibling. */
	private function deprecatedEnumAbstractSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return '@:enum abstract E(String) {\n\tvar A = $literal;\n\tvar B = \'b\';\n}';
	}

	/** The same value one level down, inside a `#if` region — the declaration is no longer its immediate parent. */
	private function guardedEnumAbstractSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return 'enum abstract E(String) {\n\t#if js\n\tvar A = $literal;\n\t#end\n\tvar B = \'b\';\n}';
	}

	/** The same over-long literal as an `inline` field's value — a compile-time constant at every use site. */
	private function inlineFieldSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return 'class C {\n\tstatic inline final S:String = $literal;\n}';
	}

	/**
	 * Two files: a `macro` function `m.Lang.t` and a caller passing it the over-long
	 * literal. Resolution is cross-file, so the macro modifier only reaches the check
	 * through the symbol index built over BOTH.
	 */
	private function macroArgFiles(aLen: Int, bLen: Int): Array<{ file: String, source: String }> {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return [
			{
				file: 'm/Lang.hx',
				source: 'package m;\nclass Lang {\n\tmacro public static function t(v:Expr):Expr {\n\t\treturn v;\n\t}\n}'
			},
			{ file: 'C.hx', source: 'import m.Lang.t;\nclass C {\n\tfunction f() {\n\t\tg(t($literal));\n\t}\n}' }
		];
	}

	/**
	 * A `<head>` line, then the over-long literal passed to `<call>(…)` — the shape whose
	 * target the index cannot resolve, since neither `m.Lang` nor `m.Ext` is in the run.
	 * `head` doubles as a place to DECLARE a resolvable type, for the negative control.
	 */
	private function outOfScopeCallSource(head: String, call: String): String {
		final literal: String = '\'${''.rpad('A', 100)}\\n${''.rpad('B', 60)}\'';
		return '$head\nclass C {\n\tfunction f() {\n\t\th($call($literal));\n\t}\n}';
	}

	/** `refusedIn` asked with `entry` listed in `$WHITELIST_OPTION` — the lever that lifts a macro refusal and no other. */
	private function refusedWhitelisting(src: String, entry: String): Bool {
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"$RULE":{"$WHITELIST_OPTION":["$entry"]}}}'));
		return refusedBy(check, src);
	}

	/** Whether `src`'s single finding is report-only — a gate refused it — as opposed to fixable. */
	private function refusedIn(src: String): Bool {
		return refusedBy(new FoldStringLiterals(), src);
	}

	/** The shared half of the two above: `src` must report EXACTLY one finding, and the answer is whether `fix` declined it. */
	private function refusedBy(check: FoldStringLiterals, src: String): Bool {
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return check.fix(src, vs, new HaxeQueryPlugin()).length == 0;
	}

}

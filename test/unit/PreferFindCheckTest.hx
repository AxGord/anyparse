package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.PreferFind;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;
import anyparse.check.Check;
import anyparse.check.PreferFinal;
import anyparse.check.PreferSafeNav;

/**
 * The `prefer-find` check: a manual first-match `for` loop — Form A
 * `for (x in xs) if (cond) return x; return null;`, Form B
 * `var r = null; for (x in xs) if (cond) { r = x; break; }` and Form B under a guard,
 * `var r = null; if (g) for (x in xs) if (cond) { r = x; break; }` — is flagged `Info`,
 * suggesting `xs.find(x -> cond)`. A non-null Form-A fallback appends `?? <fallback>`; a
 * transformed return, an `else` (on the inner `if` or on the guard), a Form-B `continue` (last
 * match, not first), an extra Form-B statement, a key-value loop, a non-adjacent trailing return
 * or declaration, a guard that writes the holder local, and a pair straddling two `#if` branches
 * are all safe misses. The guarded form's fix rewrites the loop in place and leaves the
 * declaration alone; `testCompositionGuardedFindSafeNavFinal` pins the three-check cascade it
 * exists to unlock.
 */
class PreferFindCheckTest extends Test {

	public function testBasicReturnFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testBracedReturnFormFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) if (x > 2) { return x; }\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testNonNullFallbackFlaggedWithCoalesce(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn 0;', 'Int'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2) ?? 0') != -1);
	}

	public function testBreakFormFlagged(): Void {
		final vs: Array<Violation> = violations(
			fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>')
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testBreakFormWithContinueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; continue; }\n\t\treturn r;', 'Null<Int>')).length
		);
	}

	public function testBreakFormExtraStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; trace(x); break; }\n\t\treturn r;', 'Null<Int>'))
				.length
		);
	}

	public function testTransformedReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return x + 1;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return x; else return 0;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return v;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testKeyValueLoopReturningItsKeyNotFlagged(): Void {
		// The fixture above is refused by a LATER gate — the returned `v` is not the loop node's
		// name — so it proves nothing about the key-value refusal itself. Here the returned name
		// IS the loop's own (the KEY), so every later gate passes and only `isKeyValueLoop` can
		// stop the rewrite. It must: `Lambda.find` iterates a map's VALUES, so `m.find(k -> …)`
		// would silently bind the value where the loop bound the key.
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return k;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testCallIterableNotFlagged(): Void {
		// A `.keys()` / any call iterable may yield an Iterator, not an Iterable — Lambda.find
		// would not compile, so a call-expression iterable is skipped.
		Assert.equals(0, violations(fn('for (k in m.keys()) if (m[k] > 2) return k;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testRangeIndexLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return i;\n\t\treturn -1;', 'Int')).length);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('for (x in xs) if (x > 2) return x;\n\t\tfinal n = xs.length;\n\t\treturn null;', 'Null<Int>')).length
		);
	}

	public function testMessageContainsConditionExcerpt(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('x > 2') != -1);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-find'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-find'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (x in xs) if (x > 2) return').length);
	}

	public function testFixReturnFormRewritesAndInsertsUsing(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2);') != -1);
		Assert.isTrue(out.indexOf('using Lambda;') != -1);
		Assert.isTrue(out.indexOf('for (') == -1);
	}

	public function testFixAccessorCallCondRewrites(): Void {
		final out: String = fixResult(file('for (x in xs) if (node.fmtHasFlag(x)) return x;\n\t\treturn null;', 'Null<Int>', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> node.fmtHasFlag(x));') != -1);
	}

	public function testFixNonNullFallbackCoalesces(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn 0;', 'Int', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2) ?? 0;') != -1);
	}

	public function testFixBreakFormRewritesAndDeletesLoop(): Void {
		final out: String = fixResult(
			file('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>', true)
		);
		Assert.isTrue(out.indexOf('var r:Null<Int> = xs.find(x -> x > 2);') != -1);
		Assert.isTrue(out.indexOf('for (') == -1);
		Assert.isTrue(out.indexOf('break') == -1);
	}

	public function testFixInsertsUsingAboveAnExistingUsing(): Void {
		// Haxe resolves static extensions in REVERSE declaration order, so the inserted `using`
		// must sit ABOVE the existing run or it would outrank — and silently re-target — the
		// extension calls the file already makes through `using Other;`.
		final out: String = fixResultWith(
			usingOtherSource(), 'class Other {\n\tpublic static function tag(xs:Array<Int>):Int return 0;\n}\n'
		);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') < out.indexOf('using Other;'), out);
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2);') != -1, out);
	}

	public function testFixRefusedWhenAnotherUsingSuppliesFind(): Void {
		// The inserted `using Lambda;` sits BELOW `using Other;`, so a `find` declared there would
		// win the new `xs.find(...)` call — the rewrite must not be emitted at all.
		final out: String = fixResultWith(
			usingOtherSource(), 'class Other {\n\tpublic static function find(xs:Array<Int>, f:Int -> Bool):Int return -999;\n}\n'
		);
		Assert.isTrue(out.indexOf('.find(') == -1, out);
		Assert.isTrue(out.indexOf('for (') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') == -1, out);
	}

	public function testFixAlreadyUsingNoDuplicate(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>', true));
		Assert.isTrue(out.indexOf('using Lambda;') != -1);
		Assert.equals(out.indexOf('using Lambda;'), out.lastIndexOf('using Lambda;'));
	}

	public function testFixEffectfulCondNotRewritten(): Void {
		final out: String = fixResult(file('for (x in xs) if (bump(x) > 2) return x;\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
		Assert.isTrue(out.indexOf('using Lambda;') == -1);
	}

	public function testFixNewInCondNotRewritten(): Void {
		final out: String = fixResult(file('for (x in xs) if (new Foo(x).ok) return x;\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
	}

	public function testFixNonNullableBreakDeclNotRewritten(): Void {
		final out: String = fixResult(
			file('var found:Int = null;\n\t\tfor (x in xs) if (x > 2) { found = x; break; }\n\t\treturn found;', 'Int', true)
		);
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
	}

	public function testFixExtraBodyStatementNotRewritten(): Void {
		final out: String = fixResult(
			file('for (x in xs) if (x > 2) { Assert.fail("bad"); return x; }\n\t\treturn null;', 'Null<Int>', false)
		);
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
	}

	public function testFixInsideBranchKeepsControlFlow(): Void {
		final out: String = fixResult(file(
			'if (node != null) {\n\t\t\tfor (x in xs) if (x > 2) return x;\n\t\t\treturn null;\n\t\t} else return -1;', 'Null<Int>', false
		));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2);') != -1);
		Assert.isTrue(out.indexOf('return -1;') != -1);
		Assert.isTrue(out.indexOf('else') != -1);
	}

	public function testFixTernaryFallbackParenthesized(): Void {
		// `??` binds tighter than `?:`, so a ternary fallback must be wrapped.
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn node != null ? 1 : 2;', 'Int', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2) ?? (node != null ? 1 : 2);') != -1);
	}

	public function testFixOrFallbackNotParenthesized(): Void {
		// `+` (and `||`/`&&`/`==`) bind tighter than `??`, so no wrapping parens.
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn a + b;', 'Int', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2) ?? a + b;') != -1);
	}

	public function testFixTernaryIterableParenthesized(): Void {
		final out: String = fixResult(
			file('for (x in (node != null ? xs : xs)) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>', true)
		);
		Assert.isTrue(out.indexOf('(node != null ? xs : xs).find(x -> x > 2)') != -1);
	}

	public function testFixCommentBeforeFallbackRefused(): Void {
		// A comment in the dropped region would be lost — refuse, keep the finding.
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\t// keep me\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
		Assert.isTrue(out.indexOf('// keep me') != -1);
	}

	public function testGuardedBreakFormFlagged(): Void {
		final vs: Array<Violation> = violations(
			fn('var r:Null<Int> = null;\n\t\tif (ok) for (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>')
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testGuardedBreakFormBracedGuardBodyFlagged(): Void {
		Assert.equals(
			1,
			violations(
				fn('var r:Null<Int> = null;\n\t\tif (ok) { for (x in xs) if (x > 2) { r = x; break; } }\n\t\treturn r;', 'Null<Int>')
			).length
		);
	}

	public function testGuardedBreakFormWithElseNotFlagged(): Void {
		// The braces bind the `else` to the GUARD (not to the inner `if (x > 2)`), so the guard
		// is a two-way choice and the loop is no longer its sole statement.
		Assert.equals(
			0,
			violations(fn(
				'var r:Null<Int> = null;\n\t\tif (ok) { for (x in xs) if (x > 2) { r = x; break; } } else trace(1);\n\t\treturn r;',
				'Null<Int>'
			)).length
		);
	}

	public function testGuardedBreakFormNonAdjacentDeclNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn(
				'var r:Null<Int> = null;\n\t\tfinal n = xs.length;\n\t\tif (ok) for (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;',
				'Null<Int>'
			)).length
		);
	}

	public function testGuardedBreakFormOtherTargetNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tif (ok) for (x in xs) if (x > 2) { q = x; break; }\n\t\treturn r;', 'Null<Int>'))
				.length
		);
	}

	public function testGuardedBreakFormNonNullInitNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = 0;\n\t\tif (ok) for (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>'))
				.length
		);
	}

	public function testFixGuardedBreakFormRewritesLoopInPlace(): Void {
		final out: String = fixResult(
			file('var r:Null<Int> = null;\n\t\tif (ok) for (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>', true)
		);
		Assert.isTrue(out.indexOf('if (ok) r = xs.find(x -> x > 2);') != -1, out);
		Assert.isTrue(out.indexOf('var r:Null<Int> = null;') != -1, out);
		Assert.isTrue(out.indexOf('for (') == -1, out);
	}

	public function testGuardedBreakFormGuardWritingHolderNotFlagged(): Void {
		// The guard runs BETWEEN the declaration and the loop — the one place the unguarded form
		// has nothing at all. A guard that writes the holder leaves its own value behind on the
		// no-match path, where the rewrite would leave `null`.
		Assert.equals(
			0,
			violations(fn(
				'var r:Null<Int> = null;\n\t\tif ((r = seed) != null) for (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;',
				'Null<Int>'
			)).length
		);
	}

	public function testGuardedBreakFormAcrossConditionalBranchesNotFlagged(): Void {
		// The two branches of a `#if` region project as FLATTENED siblings, so the declaration and
		// the loop LOOK adjacent while no execution ever sees both.
		Assert.equals(
			0,
			violations(fn(
				'#if js\n\t\tvar r:Null<Int> = null;\n\t\t#else\n\t\tif (ok) for (x in xs) if (x > 2) { r = x; break; }\n\t\t#end\n\t\treturn null;',
				'Null<Int>'
			)).length
		);
	}

	public function testFixGuardedBreakFormCommentInLoopNotRewritten(): Void {
		// The whole loop node is replaced, so a comment anywhere inside it would be lost.
		final out: String = fixResult(file(
			'var r:Null<Int> = null;\n\t\tif (ok) for (x in xs) if (x > 2) {\n\t\t\t// first hit wins\n\t\t\tr = x;\n\t\t\tbreak;\n'
			+ '\t\t}\n\t\treturn r;',
			'Null<Int>', true
		));
		Assert.isTrue(out.indexOf('.find(') == -1, out);
		Assert.isTrue(out.indexOf('// first hit wins') != -1, out);
	}

	public function testFixGuardedBreakFormNonNullableDeclNotRewritten(): Void {
		final out: String = fixResult(
			file('var found:Int = null;\n\t\tif (ok) for (x in xs) if (x > 2) { found = x; break; }\n\t\treturn found;', 'Int', true)
		);
		Assert.isTrue(out.indexOf('.find(') == -1, out);
		Assert.isTrue(out.indexOf('for (') != -1, out);
	}

	/**
	 * The three-rule cascade the guarded form exists to unlock: `prefer-find` collapses the
	 * guarded capture-and-break loop to `if (g) r = xs.find(...)`, `prefer-safe-nav` folds that
	 * guarded assignment into the null-initialized declaration as `r = g?.find(...)`, and
	 * `prefer-final` then seals the now single-assignment local.
	 */
	public function testCompositionGuardedFindSafeNavFinal(): Void {
		final out: String = fixCascade(compositionSource());
		Assert.isTrue(out.indexOf("final oXml:Null<Xml> = frame1Xml?.find(child -> child.nodeName == 'o');") != -1, out);
		Assert.isTrue(out.indexOf('for (') == -1, out);
		Assert.isTrue(out.indexOf('if (frame1Xml != null)') == -1, out);
	}

	/** A guarded capture-and-break loop over a nullable local — the cascade fixture. */
	private inline function compositionSource(): String {
		return 'package p;\n\nusing Lambda;\n\nclass C {\n\tfunction f(xml:Xml):Void {\n'
			+ '\t\tfinal frame1Xml:Null<Xml> = xml.find(c -> c.nodeName == \'f\');\n\t\tvar oXml:Null<Xml> = null;\n'
			+ '\t\tif (frame1Xml != null) for (child in frame1Xml) if (child.nodeName == \'o\') {\n\t\t\toXml = child;\n\t\t\tbreak;\n'
			+ '\t\t}\n\t\ttrace(oXml);\n\t}\n}';
	}

	/** `source` run through `prefer-find`, then `prefer-safe-nav`, then `prefer-final`, canonicalized after each. */
	private function fixCascade(source: String): String {
		var out: String = source;
		for (check in ([new PreferFind(), new PreferSafeNav(), new PreferFinal()]: Array<Check>)) {
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final text: String = out;
			final edits: Array<{ span: Span, text: String }> = check.fix(text, check.run([{ file: 'C.hx', source: text }], plugin), plugin);
			Assert.isTrue(edits.length > 0, 'stage ${check.id()} produced no edits');
			switch RefactorSupport.canonicalize(text, edits, true, plugin) {
				case Ok(next):
					out = next;
				case Err(message):
					Assert.fail('stage ${check.id()} canonicalize Err: $message');
					return out;
			}
		}
		return out;
	}

	/** A `p.C` with a `using Other;` and one Form-A first-match loop — the conflicting-`using` fixture. */
	private inline function usingOtherSource(): String {
		return 'package p;\n\nusing Other;\n\nclass C {\n\tfunction f(xs:Array<Int>):Null<Int> {\n\t\tfor (x in xs) if (x > 2) return x;\n'
			+ '\t\treturn null;\n\t}\n}';
	}

	/** `source` fixed with `other` (an `Other.hx` module) in the index the conflict gate consults. */
	private function fixResultWith(source: String, other: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferFind = new PreferFind();
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: source },
			{ file: 'Other.hx', source: other }
		];
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin)
		);
		switch RefactorSupport.canonicalize(source, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	private function fn(body: String, ret: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>):$ret {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferFind().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function file(body: String, ret: String, withUsing: Bool): String {
		final head: String = 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '');
		return '${head}class C {\n\tfunction f(xs:Array<Int>, node:Node, a:Int, b:Int):$ret {\n\t\t$body\n\t}\n}';
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferFind = new PreferFind();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin);
		switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}

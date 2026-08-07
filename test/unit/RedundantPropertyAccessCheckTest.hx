package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantPropertyAccess;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `redundant-property-access` check: a property declared `var x(default, default)` —
 * both accessors the plain stored ones, so the clause says exactly what a bare `var x`
 * already says. `Info`, DEFAULT OFF, `--fix` deletes the clause.
 *
 * The gates fail closed: ANY other accessor pair (`get` / `set` / `null` / `never` /
 * `dynamic` / a method name), an arity other than two, a comment anywhere from the
 * declaration's start through the clause's `)`, and a declaration outside the field
 * walk (a local, a `final`, an interface member) are all safe misses.
 */
class RedundantPropertyAccessCheckTest extends Test {

	public function testDefaultDefaultFlagged(): Void {
		final source: String = wrap('public var isFlag(default, default):Bool = false;');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-property-access', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'property \'isFlag\' declares (default, default) — the plain stored accessors; drop the clause and write \'var isFlag\'',
			vs[0].message
		);
	}

	/** The reported span is the clause itself, not the whole declaration. */
	public function testViolationSpanIsTheClause(): Void {
		final source: String = wrap('public var isFlag(default, default):Bool = false;');
		final span: Null<Span> = violations(source)[0].span;
		Assert.notNull(span);
		if (span != null) Assert.equals('(default, default)', source.substring(span.from, span.to));
	}

	public function testFixDeletesTheClause(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('public var isFlag(default, default):Bool = false;'));
		Assert.equals(1, es.length);
		Assert.equals('', es[0].text);
	}

	/** End-to-end through the canonical writer: visibility, type and initializer survive byte-identically. */
	public function testFixOutputKeepsEverythingElse(): Void {
		final out: String = applyFixOnce(wrap('public var isFlag(default, default):Bool = false;'));
		Assert.isTrue(out.indexOf('public var isFlag:Bool = false;') != -1);
		Assert.equals(-1, out.indexOf('default'));
	}

	/** A `static` property keeps its modifier run. */
	public function testFixKeepsStaticModifier(): Void {
		final out: String = applyFixOnce(wrap('public static var gap(default, default):Float = 4;'));
		Assert.isTrue(out.indexOf('public static var gap:Float = 4;') != -1);
	}

	/** `@:isVar` is metadata on the member, not part of the clause — the fix leaves it alone. */
	public function testFixKeepsIsVarMeta(): Void {
		final out: String = applyFixOnce(wrap('@:isVar public var x(default, default):Int = 1;'));
		Assert.isTrue(out.indexOf('@:isVar') != -1);
		Assert.isTrue(out.indexOf('public var x:Int = 1;') != -1);
	}

	/** A doc comment on the member is trivia the writer re-emits; the clause deletion does not disturb it. */
	public function testFixKeepsDocComment(): Void {
		final out: String = applyFixOnce(wrap('/** Doc. */\n\tpublic var x(default, default):Int = 1;'));
		Assert.isTrue(out.indexOf('/** Doc. */') != -1);
		Assert.isTrue(out.indexOf('public var x:Int = 1;') != -1);
	}

	/** A trailing line comment sits past the declaration and survives the deletion. */
	public function testFixKeepsTrailingComment(): Void {
		final out: String = applyFixOnce(wrap('public var forwardChanges(default, default):Bool = true; // forward changed values'));
		Assert.isTrue(out.indexOf('public var forwardChanges:Bool = true;') != -1);
		Assert.isTrue(out.indexOf('// forward changed values') != -1);
	}

	/** A property with no initializer and no type still loses just the clause. */
	public function testFixBareDeclaration(): Void {
		final out: String = applyFixOnce(wrap('public var x(default, default);'));
		Assert.isTrue(out.indexOf('public var x;') != -1);
	}

	/** Whitespace between the name and the clause is swallowed with it. */
	public function testFixSpacedClause(): Void {
		final out: String = applyFixOnce(wrap('public var x (default, default):Int = 1;'));
		Assert.isTrue(out.indexOf('public var x:Int = 1;') != -1);
	}

	/** The spelling real code uses most: no space after the comma. */
	public function testFixTightClause(): Void {
		final out: String = applyFixOnce(wrap('public var x(default,default):Int = 1;'));
		Assert.isTrue(out.indexOf('public var x:Int = 1;') != -1);
	}

	/** A clause broken across lines is still just whitespace between the tokens. */
	public function testFixMultiLineClause(): Void {
		final out: String = applyFixOnce(wrap('public var x(default,\n\t\tdefault):Int = 1;'));
		Assert.isTrue(out.indexOf('public var x:Int = 1;') != -1);
	}

	/** A member with no visibility modifier at all is walked like any other field. */
	public function testFixNoVisibilityModifier(): Void {
		final out: String = applyFixOnce(wrap('var x(default, default):Int = 1;'));
		Assert.isTrue(out.indexOf('var x:Int = 1;') != -1);
	}

	/** Each property of a class is its own finding. */
	public function testTwoPropertiesEachFlagged(): Void {
		Assert.equals(
			2,
			violations(wrap('public var isFlag(default, default):Bool = false;\n\tpublic var stepSize(default, default):Int = 1;')).length
		);
	}

	/** Two findings in one file produce two edits that both land — the batched `--fix` path. */
	public function testFixTwoPropertiesInOneClass(): Void {
		final out: String = applyFixOnce(
			wrap('public var isFlag(default, default):Bool = false;\n\tpublic var stepSize(default, default):Int = 1;')
		);
		Assert.isTrue(out.indexOf('public var isFlag:Bool = false;') != -1);
		Assert.isTrue(out.indexOf('public var stepSize:Int = 1;') != -1);
		Assert.equals(-1, out.indexOf('default'));
	}

	/** The rewritten form is a writer fixed point: a second canonicalize pass is byte-identical. */
	public function testFixedFormIsWriterIdempotent(): Void {
		final once: String = applyFixOnce(wrap('public var isFlag(default, default):Bool = false;'));
		Assert.equals(once, canonicalize(once, []));
		Assert.equals(once, canonicalize(canonicalize(once, []), []));
	}

	public function testGetSetNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(get, set):Int;')).length);
	}

	public function testDefaultNullNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(default, null):Int = 1;')).length);
	}

	public function testDefaultNeverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(default, never):Int = 1;')).length);
	}

	public function testGetDefaultNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(get, default):Int = 1;')).length);
	}

	public function testDefaultSetNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(default, set):Int = 1;')).length);
	}

	public function testDynamicPairNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(dynamic, dynamic):Int = 1;')).length);
	}

	/** Method-name accessors run code — nothing redundant about them. */
	public function testMethodNameAccessorsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(getX, setX):Int;')).length);
	}

	public function testPlainFieldNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x:Int = 1;')).length);
	}

	public function testFinalFieldNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public final x:Int = 1;')).length);
	}

	/** A three-identifier clause is not the exact shape — refuse rather than guess. */
	public function testThreeAccessorsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(default, default, default):Int = 1;')).length);
	}

	public function testSingleAccessorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(default):Int = 1;')).length);
	}

	/** A comment where an accessor is expected is not an identifier — the scan refuses it. */
	public function testCommentInClauseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(/* why */ default, default):Int = 1;')).length);
	}

	/** A comment between the name and the clause sits in the region the fix deletes. */
	public function testCommentBeforeClauseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x /* why */ (default, default):Int = 1;')).length);
	}

	/**
	 * The name token is found by text search, so a comment quoting the field name ahead of it
	 * would send the whole scan into the comment's own text. The guard spans the declaration
	 * head for exactly this: the field below is ALREADY plain and must not be reported.
	 */
	public function testCommentQuotingTheNameNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var /* x(default, default) */ x:Int = 1;')).length);
	}

	/**
	 * An interface member is outside the walk (`visibilityContainerKinds` has no
	 * `InterfaceDecl`) — a safe miss, pinned so widening the walk is a deliberate act.
	 */
	public function testInterfaceMemberNotFlagged(): Void {
		Assert.equals(0, violations('interface I {\n\tvar x(default, default):Int;\n}').length);
	}

	/** A conditional-compilation directive inside the clause breaks the identifier scan. */
	public function testDirectiveInClauseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('public var x(#if air default #else get #end, default):Int = 1;')).length);
	}

	/** A local declaration is not a field member — the walk never reaches it. */
	public function testLocalDeclarationNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tvar x(default, default):Int = 1;\n\t}\n}').length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new RedundantPropertyAccess() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-property-access'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-property-access'));
	}

	/**
	 * A property written inside a member-position `#if` is a member of the class like any other, and
	 * its `(default, default)` clause is just as redundant. The region is ONE node holding every
	 * branch's members flattened as siblings, so a scan of the container's direct children never saw it.
	 */
	public function testConditionalMemberFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t#if cpp\n\tpublic var a(default, default):Int;\n\t#end\n}').length);
	}

	/** A region with a redundant property in each branch reports each of them. */
	public function testConditionalBothBranchesFlagged(): Void {
		Assert.equals(
			2,
			violations(
				'class C {\n\t#if cpp\n\tpublic var a(default, default):Int;\n\t#else\n\tpublic var b(default, default):Int;\n\t#end\n}'
			).length
		);
	}

	/** Wrap a member body in a minimal parseable class. */
	private function wrap(member: String): String {
		return 'class C {\n\t$member\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantPropertyAccess().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: RedundantPropertyAccess = new RedundantPropertyAccess();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return canonicalize(src, edits(src));
	}

	private function canonicalize(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		}
	}

}

package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.JoinReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `join-return` check: a local declaration whose value is IMMEDIATELY returned is flagged
 * `Info`, and `fix` collapses the pair to a single `return`. An unannotated decl always
 * collapses to `return e;`; an annotated decl keeps its annotation as a type-check ascription
 * `return (e : T);` UNLESS the enclosing function's explicit return type already equals it
 * (then plain `return e;`). A non-adjacent return, a return of a different name or of an
 * expression, a bare `return;`, a local used elsewhere, a multi-declarator and a comment in a
 * dropped region are all safe misses.
 */
class JoinReturnCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('final x = g();\n\t\treturn x;'));
		Assert.equals(1, vs.length);
		Assert.equals('join-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this declaration and its next-line return can be joined into a single return', vs[0].message);
	}

	/** An unannotated declaration collapses to a plain `return e;`. */
	public function testFixUnannotated(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/** A `var` local collapses just like a `final`. */
	public function testFixVar(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var x = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/**
	 * An annotated decl in a function with NO explicit return type keeps its annotation as an
	 * ascription -- the annotation can be load-bearing (an implicit `@:from` conversion).
	 */
	public function testAnnotatedInferredReturnAscribes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x:Int = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return (g() : Int);', es[0].text);
	}

	/** When the function's explicit return type equals the annotation, the conversion happens at the boundary -- plain `return e;`. */
	public function testAnnotatedEqualReturnTypeCollapsesPlain(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('Int', 'final x:Int = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/** A differing explicit return type does not re-state the annotation, so it survives as an ascription. */
	public function testAnnotatedDifferingReturnTypeAscribes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('String', 'final x:Int = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return (g() : Int);', es[0].text);
	}

	/** The load-bearing case (mirrors `types.Color`): a qualified annotation driving an implicit `@:from` is preserved. */
	public function testQualifiedAnnotationAscribed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final color:types.Color = str;\n\t\treturn color;'));
		Assert.equals(1, es.length);
		Assert.equals('return (str : types.Color);', es[0].text);
	}

	/** A statement between the declaration and the return blocks the join (only the immediate next return qualifies). */
	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\tside();\n\t\treturn x;')).length);
	}

	public function testReturnDifferentNameNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn y;')).length);
	}

	/** The return must be exactly the bare identifier, not an expression using it. */
	public function testReturnExpressionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn x + 1;')).length);
	}

	/** A bare `return;` is a distinct node kind and never joins. */
	public function testBareReturnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn;')).length);
	}

	/** The local must be referenced ONLY by the return -- a use in (unreachable) trailing code disqualifies. */
	public function testLocalUsedElsewhereNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn x;\n\t\tafter(x);')).length);
	}

	/** A multi-declarator (`final a = 1, b = 2;`) is never joined. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final a = 1, b = 2;\n\t\treturn a;')).length);
	}

	/** A comma INSIDE a generic type is not a second declarator -- a typed single-var decl still joins (ascribed). */
	public function testTypeCommaStillFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final m:Map<Int, String> = null;\n\t\treturn m;'));
		Assert.equals(1, es.length);
		Assert.equals('return (null : Map<Int, String>);', es[0].text);
	}

	/** A comment between the declaration and the return would be dropped by the join. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\t// note\n\t\treturn x;')).length);
	}

	/** A comment INSIDE the initializer is kept verbatim, so the pair still joins. */
	public function testCommentInInitializerStillFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x = g(/* k */);\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g(/* k */);', es[0].text);
	}

	/** End-to-end through the canonical writer: the emitted file holds the single return and no declaration line. */
	public function testFixOutputJoins(): Void {
		final out: String = applyFixOnce(wrap('final x = g();\n\t\treturn x;'));
		Assert.isTrue(out.indexOf('return g();') != -1);
		Assert.equals(-1, out.indexOf('final x = g();'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('join-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('join-return'));
	}

	/** Wrap a statement body in a minimal parseable class + method with an inferred return type. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	/** Wrap a statement body in a method with an explicit return type. */
	private function wrapRet(retType: String, body: String): String {
		return 'class C {\n\tfunction f():$retType {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinReturn = new JoinReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}

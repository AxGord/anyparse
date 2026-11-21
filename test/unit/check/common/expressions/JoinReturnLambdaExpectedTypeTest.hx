package unit.check.common.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.check.common.expressions.JoinReturn;

using StringTools;

/**
 * `join-return` in an untyped lambda passed as an argument: the parameter's function type fixes the lambda's
 * return type the way a declared return type does, so an annotation it restates collapses to a plain
 * `return e;` and one it does not restate, or a lambda with no typed parameter, keeps its ascription.
 */
class JoinReturnLambdaExpectedTypeTest extends Test {

	/** The parameter's function type returns `Int`, which restates the local's annotation. */
	@:pin('control')
	@:killer('M-JOIN-RETURN-LAMBDA-EXPECTATION-OFF')
	public function testRestatingParameterTypeJoinsPlain(): Void {
		Assert.equals('return g();', soleEdit(callee('(t: String) -> Int'), 'Int'));
	}

	/** The callee in another module: its parameter's return type is read through the resolution index. */
	@:pin('control')
	@:killer('M-JOIN-RETURN-LAMBDA-EXPECTATION-OFF')
	public function testRestatingParameterTypeAcrossFilesJoinsPlain(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: caller('Int', 'R.each') },
			{ file: 'R.hx', source: 'class R {\n\tpublic static function each(body: (t: String) -> Int): Void {}\n}' }
		];
		final es: Array<FixEdit> = CheckFixture.fixRun(new JoinReturn(), files).edits;
		Assert.equals(1, es.length);
		if (es.length == 1) Assert.equals('return g();', es[0].text);
	}

	/** One name binding a different declaration in the callee's module is not the annotation's type. */
	@:pin('control')
	@:killer('M-WTI-BOUND-HEADS-ALWAYS-SAME')
	public function testSameNameOtherDeclarationKeepsAscription(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/C.hx', source: 'package a;\n\nimport b.R;\n\nclass Box {}\n\n' + caller('Box', 'R.each') },
			{
				file: 'b/R.hx',
				source: 'package b;\n\nclass Box {}\n\nclass R {\n\tpublic static function each(body: (t: String) -> Box): Void {}\n}'
			}
		];
		final es: Array<FixEdit> = CheckFixture.fixRun(new JoinReturn(), files).edits;
		Assert.equals(1, es.length);
		if (es.length == 1) Assert.equals('return (g() : Box);', es[0].text);
	}

	/**
	 * A typedef the parameter's return type names is not the structure it stands for: null safety checks a literal typed
	 * against the typedef without the narrowing it applies against the structure written out, so the ascription is kept.
	 */
	@:pin('control')
	@:killer('M-WTI-SHAPES-ALWAYS-SAME')
	public function testTypedefOfTheAnnotationKeepsAscription(): Void {
		final src: String = 'typedef E = { a: Int, b: String }\n' + callee('(t: String) -> Array<E>');
		Assert.equals('return (g() : Array<{ a: Int, b: String }>);', soleEdit(src, 'Array<{ a: Int, b: String }>'));
	}

	/** A structure written out in both places, its fields in another order, is one type. */
	@:pin('control')
	@:killer('M-WTI-FIELDS-NEVER-SAME')
	public function testSameStructureJoinsPlain(): Void {
		Assert.equals('return g();', soleEdit(callee('(t: String) -> Array<{ b: String, a: Int }>'), 'Array<{ a: Int, b: String }>'));
	}

	/** A parameter whose function type returns another type does not restate the annotation. */
	@:pin('control')
	@:killer('M-WTI-HEADS-ALWAYS-SAME')
	public function testDifferingParameterTypeKeepsAscription(): Void {
		Assert.equals('return (g() : Int);', soleEdit(callee('(t: String) -> Float'), 'Int'));
	}

	/** An untyped parameter fixes no return type, so the annotation stays as an ascription. */
	@:pin('control')
	@:killer('M-BINDER-LAMBDA-RESULT-ALWAYS-EXPECTED')
	public function testUntypedParameterKeepsAscription(): Void {
		Assert.equals('return (g() : Int);', soleEdit(callee('Dynamic'), 'Int'));
	}

	/** A callee the file does not declare fixes nothing either. */
	@:pin('control')
	@:killer('M-BINDER-LAMBDA-RESULT-ALWAYS-EXPECTED')
	public function testUnknownCalleeKeepsAscription(): Void {
		Assert.equals('return (g() : Int);', soleEdit('class C {\n\tfunction f() {\n\t\t${call('Int', 'unknown')}\n\t}\n}', 'Int'));
	}

	/** A callee's own type parameter the call does not bind is not the caller's parameter of the same name. */
	@:pin('control')
	@:killer('M-WTI-UNBOUND-PARAM-BY-SPELLING')
	public function testUnboundCalleeTypeParameterKeepsAscription(): Void {
		final src: String = 'class C {\n\tstatic function each<T>(body: (t: String) -> T): Void {}\n\tfunction f<T>() {\n\t\t'
			+ call('T', 'each')
			+ '\n\t}\n}';
		Assert.equals('return (g() : T);', soleEdit(src, 'T'));
	}

	/** A type parameter of the class both the callee and the caller sit in is one type in both. */
	@:pin('control')
	@:killer('M-DN-PARAM-OWNER-PER-POSITION')
	public function testSharedClassTypeParameterJoinsPlain(): Void {
		final src: String =
			'class C<T> {\n\tfunction each(body: (t: String) -> T): Void {}\n\tfunction f() {\n\t\t${call('T', 'each')}\n\t}\n}';
		Assert.equals('return g();', soleEdit(src, 'T'));
	}

	/** A class whose `each(body: <param>)` is called with a lambda returning an annotated local. */
	private function callee(param: String): String {
		return 'class C {\n\tstatic function each(body: $param): Void {}\n\tfunction f() {\n\t\t${call('ANN', 'each')}\n\t}\n}';
	}

	private function caller(ann: String, target: String): String {
		return 'class C {\n\tfunction f() {\n\t\t${call(ann, target)}\n\t}\n}';
	}

	private function call(ann: String, target: String): String {
		return '$target(t -> {\n\t\t\tfinal x: $ann = g();\n\t\t\treturn x;\n\t\t});';
	}

	/** The one edit of `src` with `ANN` standing for the annotation. */
	private function soleEdit(src: String, ann: String): String {
		final es: Array<FixEdit> = CheckFixture.edits(new JoinReturn(), src.replace('ANN', ann));
		Assert.equals(1, es.length);
		return es.length == 1 ? es[0].text : '';
	}

}

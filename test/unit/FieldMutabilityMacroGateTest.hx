package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinal;
import anyparse.check.PreferFinalField;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * Two rules that change a declaration's MUTABILITY, and the two ways the declaration they read
 * is not the declaration the compiler sees.
 *
 * A build macro rewrites members arbitrarily. `pony.magic.DeclaratorBuilder` — reached through
 * `implements Declarator`, so the class itself carries no metadata — strips the initializer off
 * every non-inline `var` field and moves the assignment into the constructor. `var` -> `final`
 * then gives `Static final variable must be initialized`, and a field promoted to `static` gives
 * `Cannot access static field from a class instance`, raised from inside the builder. Ten fields
 * in one file of the reporting tree, 25 types overall.
 *
 * An ABSTRACT whose member rebinds `this` needs a mutable local, and the gate for that already
 * existed — but it read the local's DECLARED type, which an unannotated local has none of. So
 * `var t = new ThreadTasks(); t.add(f);` was flagged and stopped compiling while the identical
 * code with `var t: ThreadTasks = …` was correctly kept: the annotation was doing the work.
 */
class FieldMutabilityMacroGateTest extends Test {

	/** The `@:autoBuild` grant is on the INTERFACE — the class implementing it carries no metadata of its own. */
	private static final DECLARATOR: String = 'package p;\n\n@:autoBuild(p.B.build())\ninterface Declarator {}\n';

	/** An abstract whose non-constructor member rebinds `this`, so a binding of its type must stay mutable. */
	private static final THREAD_TASKS: String = 'package p;\n\nabstract ThreadTasks(UInt) {\n\n'
		+ '\tpublic inline function new() this = 0;\n\n\tpublic inline function add(f: Int): Void this = this + f;\n\n}\n';

	public function testAFieldOfAMacroBuiltTypeIsNotFinalized(): Void {
		final owner: String = 'package p;\n\nclass W implements Declarator {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		Assert.equals(0, fieldViolations(owner).length);
	}

	public function testAFieldOfAnOrdinaryTypeIsStillFinalized(): Void {
		final owner: String = 'package p;\n\nclass W {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		Assert.equals(1, fieldViolations(owner).length);
	}

	/**
	 * `@:buildXml` is an hxcpp build-file tag, not a build macro — it generates no member. The gate
	 * used to test the metadata with a plain substring search, so `@:build` matched its PREFIX and
	 * every consumer of `carriesBuildMacro` bailed out on the type. 17 declarations in the Haxe std
	 * alone carry it.
	 */
	public function testABuildXmlTagDoesNotGateTheField(): Void {
		final owner: String = 'package p;\n\n@:buildXml(\'<files id="haxe"/>\')\nclass W {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		Assert.equals(1, fieldViolations(owner).length);
	}

	/**
	 * The token match must still see the two REAL spellings. `@:autoBuild` is pinned above through
	 * the `implements` grant, which is how it reaches a class in practice; this pins `@:build` on
	 * the type itself.
	 */
	public function testABuildMacroOnTheTypeItselfStillGatesTheField(): Void {
		final owner: String = 'package p;\n\n@:build(p.B.build())\nclass W {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		Assert.equals(0, fieldViolations(owner).length);
	}

	/**
	 * `@:genericBuild` builds the WHOLE type per instantiation, so the members read here are not
	 * the members the compiler sees — the same claim `@:build` and `@:autoBuild` make, and the
	 * predicate's own doc already stated it. It was missing from the token list, and its direction
	 * is the DANGEROUS one: the rule ACTED on a type it cannot read, where the `@:buildXml` defect
	 * only over-declined. Zero declarations in the Haxe 4.3.7 std (its three occurrences there are
	 * doc-comment prose), live in `lime.app.Event`, `json2object.JsonParser` and
	 * `tink.macro.DirectType`.
	 */
	public function testAGenericBuildTypeGatesTheField(): Void {
		final owner: String = 'package p;\n\n@:genericBuild(p.B.build())\nclass W {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		Assert.equals(0, fieldViolations(owner).length);
	}

	public function testAnUnannotatedLocalOfAThisRebindingAbstractIsNotFinalized(): Void {
		Assert.equals(0, localViolations('var t = new ThreadTasks();\n\t\tt.add(1);\n\t\treturn 0;').length);
	}

	public function testTheAnnotatedFormWasAlreadyRefusedAndStaysRefused(): Void {
		Assert.equals(0, localViolations('var t: ThreadTasks = new ThreadTasks();\n\t\tt.add(1);\n\t\treturn 0;').length);
	}

	public function testAnUnannotatedLocalOfAnOrdinaryTypeIsStillFinalized(): Void {
		Assert.equals(1, localViolations('var b = new StringBuf();\n\t\tb.add(\'x\');\n\t\treturn b.length;').length);
	}

	/** `prefer-final-field` findings for `owner`, linted alongside the `@:autoBuild` interface. */
	private function fieldViolations(owner: String): Array<Violation> {
		return new PreferFinalField().run([
			{ file: 'p/Declarator.hx', source: DECLARATOR },
			{ file: 'p/W.hx', source: owner }
		], new HaxeQueryPlugin()).filter(v -> v.file == 'p/W.hx');
	}

	/** `prefer-final` findings for a method body, linted alongside the `this`-rebinding abstract. */
	private function localViolations(body: String): Array<Violation> {
		final user: String = 'package p;\n\nclass U {\n\n\tpublic static function run(): Int {\n\t\t$body\n\t}\n\n}\n';
		return new PreferFinal().run([
			{ file: 'p/ThreadTasks.hx', source: THREAD_TASKS },
			{ file: 'p/U.hx', source: user }
		], new HaxeQueryPlugin()).filter(v -> v.file == 'p/U.hx');
	}

}

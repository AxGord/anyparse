package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.InlineConstant;
import anyparse.check.PreferFinal;
import anyparse.check.PreferFinalField;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * Rules that act on a declaration the compiler does NOT see, and the two ways it differs from the
 * one they read.
 *
 * A build macro rewrites members arbitrarily. `pony.magic.DeclaratorBuilder` — reached through
 * `implements Declarator`, so the class itself carries no metadata — strips the initializer off
 * every non-inline `var` field and moves the assignment into the constructor. `var` -> `final`
 * then gives `Static final variable must be initialized`, and a field promoted to `static` gives
 * `Cannot access static field from a class instance`, raised from inside the builder. Ten fields in one file of the reporting tree, 25 types overall.
 *
 * Which rules take the gate was itself a gap. `inline-constant` and `trivial-getter` consulted NO
 * build-macro predicate — not `@:build`, not `@:autoBuild`, not `@:genericBuild` — while the four
 * field rules, `member-order` and `prefer-inline` all did; the residue was visible in the
 * `@:genericBuild` fixture of `43ce9697` and left alone there. Both were measured on Haxe 4.3.7
 * before being gated: a builder that rewrites a `static final`'s initializer makes `inline-constant`'s
 * rewrite "Inline variable initialization must be a constant value", and a builder that reads the
 * backing field makes `trivial-getter`'s collapse `Unknown identifier`. Both compile before the fix
 * and fail after it, under `@:build` on the type and under `@:autoBuild` through `implements` alike.
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

	/**
	 * The same interface WITHOUT the grant. The `@:autoBuild` arms below differ from their control by
	 * this one tag and nothing else — an `implements` of its own would otherwise move two gates at once
	 * (`trivial-getter` asks every implemented interface whether it declares the property).
	 */
	private static final PLAIN_IFACE: String = 'package p;\n\ninterface Plain {}\n';

	/** A same-simple-name declaration in ANOTHER package, carrying a build macro of its own. */
	private static final BUILT_HOMONYM: String = 'package p;\n\n@:build(p.B.build())\nclass W {\n\n\tpublic function new() {}\n\n}\n';

	/** The same homonym without the tag — the one line the collision arms above differ from it by. */
	private static final PLAIN_HOMONYM: String = 'package p;\n\nclass W {\n\n\tpublic function new() {}\n\n}\n';

	/** An `@:autoBuild` marker interface in package `p` — the grant a supertype hop may reach. */
	private static final BUILT_MARKER: String = 'package p;\n\n@:autoBuild(p.B.build())\ninterface Marker {}\n';

	/** A marker of the SAME simple name in package `q`, granting nothing. */
	private static final PLAIN_MARKER: String = 'package q;\n\ninterface Marker {}\n';

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

	/**
	 * `inline-constant` adds `inline` to a `static final` scalar, and a builder that REWRITES that
	 * field's initializer makes the result "Inline variable initialization must be a constant value"
	 * — measured on Haxe 4.3.7 with `@:build` on the class and with `@:autoBuild` reached through
	 * `implements`, which is the shape the file itself carries no metadata for. The rule consulted no
	 * build-macro predicate at all until then; `@:coreApi`'s gate landed beside it and left this one.
	 */
	public function testAConstantOfAMacroBuiltTypeIsNotInlined(): Void {
		Assert.equals(1, constantViolations('class W implements Plain').length, 'the control still fires');
		Assert.equals(0, constantViolations('class W implements Declarator').length);
		Assert.equals(0, constantViolations('@:build(p.B.build())\nclass W').length);
		Assert.equals(0, constantViolations('@:genericBuild(p.B.build())\nclass W').length);
	}

	/**
	 * `trivial-getter` DELETES the getter and the backing field, so a member the builder generates
	 * around them loses its referent — measured, `Unknown identifier : _active` from inside the macro.
	 * Same three spellings, same control.
	 */
	public function testATrivialGetterOfAMacroBuiltTypeIsNotCollapsed(): Void {
		Assert.equals(1, propertyViolations('class W implements Plain').length, 'the control still fires');
		Assert.equals(0, propertyViolations('class W implements Declarator').length);
		Assert.equals(0, propertyViolations('@:build(p.B.build())\nclass W').length);
		Assert.equals(0, propertyViolations('@:genericBuild(p.B.build())\nclass W').length);
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

	/**
	 * The gate's OWN type is not a written type reference — it is the container the rule is looking
	 * at, and the rule already holds the file that declares it — so answering it by simple name
	 * across the whole index conflates every homonym. `@:build` on an unrelated `p.W` silenced
	 * `q.W`, and at library scale one tag reaches a hundred strangers.
	 */
	public function testAHomonymOfTheOwnerDoesNotGateTheField(): Void {
		Assert.equals(1, homonymFieldViolations(PLAIN_HOMONYM).length, 'the control still fires');
		Assert.equals(1, homonymFieldViolations(BUILT_HOMONYM).length);
	}

	/** The same collision on a rule that DELETES the members it acts on, where a false "no" is the costly direction. */
	public function testAHomonymOfTheOwnerDoesNotGateTheTrivialGetter(): Void {
		Assert.equals(1, homonymPropertyViolations(PLAIN_HOMONYM).length, 'the control still fires');
		Assert.equals(1, homonymPropertyViolations(BUILT_HOMONYM).length);
	}

	/**
	 * One hop up the chain the names ARE written references, so they resolve against the referring
	 * file's import scope: a `q.W implements Marker` in a package that declares its own `Marker`
	 * takes THAT one, not the `@:autoBuild` homonym in `p`.
	 */
	public function testASupertypeHomonymOutsideTheOwnersScopeDoesNotGateTheField(): Void {
		Assert.equals(1, markerFieldViolations('q').length);
	}

	/**
	 * …and the fallback when that resolution settles nothing: an owner in a package holding no
	 * `Marker` of its own and importing none names a type the index cannot place, so the hop widens
	 * back to the same-simple-name union and the `@:autoBuild` grant still gates. Failing to resolve
	 * may only ever keep the conservative answer — this arm passes on the old engine too, and pins
	 * that it must keep passing.
	 */
	public function testAnUnplaceableSupertypeStillGatesTheField(): Void {
		Assert.equals(0, markerFieldViolations('r').length);
	}

	/**
	 * `prefer-final-field` findings for `owner`, linted alongside the `@:autoBuild` interface.
	 */
	private function fieldViolations(owner: String): Array<Violation> {
		return new PreferFinalField().run([
			{ file: 'p/Declarator.hx', source: DECLARATOR },
			{ file: 'p/W.hx', source: owner }
		], new HaxeQueryPlugin()).filter(v -> v.file == 'p/W.hx');
	}

	/** `prefer-final-field` findings for a `q.W`, linted alongside a same-simple-name `p.W`. */
	private function homonymFieldViolations(homonym: String): Array<Violation> {
		final owner: String = 'package q;\n\nclass W {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		return new PreferFinalField().run([
			{ file: 'p/W.hx', source: homonym },
			{ file: 'q/W.hx', source: owner }
		], new HaxeQueryPlugin()).filter(v -> v.file == 'q/W.hx');
	}

	/** `trivial-getter` findings for the same `q.W` / `p.W` pair. */
	private function homonymPropertyViolations(homonym: String): Array<Violation> {
		final owner: String = 'package q;\n\nclass W {\n\n\tpublic var active(get, never): Bool;\n\n\tprivate var _active: Bool = '
			+ 'false;\n\n\tpublic function new() {}\n\n\tprivate function get_active(): Bool return _active;\n\n}\n';
		return new TrivialGetter().run([
			{ file: 'p/W.hx', source: homonym },
			{ file: 'q/W.hx', source: owner }
		], new HaxeQueryPlugin()).filter(v -> v.file == 'q/W.hx');
	}

	/**
	 * `prefer-final-field` findings for a `W` in `pkg` implementing the bare name `Marker`, with both
	 * markers in the index: `q` declares its own, `r` declares none and imports none.
	 */
	private function markerFieldViolations(pkg: String): Array<Violation> {
		final owner: String = 'package $pkg;\n\nclass W implements Marker {\n\n\tprivate static var counter: Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function bump(): Int return counter;\n\n}\n';
		return new PreferFinalField().run([
			{ file: 'p/Marker.hx', source: BUILT_MARKER },
			{ file: 'q/Marker.hx', source: PLAIN_MARKER },
			{ file: '$pkg/W.hx', source: owner }
		], new HaxeQueryPlugin()).filter(v -> v.file == '$pkg/W.hx');
	}

	/** `inline-constant` findings for a class `head` carrying one private static scalar constant. */
	private function constantViolations(head: String): Array<Violation> {
		return ownerViolations(
			new InlineConstant(),
			'package p;\n\n${head} {\n\n\tprivate static final LIMIT: Int = 5;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function read(): Int return LIMIT;\n\n}\n'
		);
	}

	/** `trivial-getter` findings for a class `head` carrying one `(get, never)` property over a backing field. */
	private function propertyViolations(head: String): Array<Violation> {
		return ownerViolations(
			new TrivialGetter(),
			'package p;\n\n$head {\n\n\tpublic var active(get, never): Bool;\n\n\tprivate var _active: Bool = false;\n\n'
			+ '\tpublic function new() {}\n\n\tprivate function get_active(): Bool return _active;\n\n}\n'
		);
	}

	/** Run `check` over `owner` with both interfaces in scope, keeping only the owner's own findings. */
	private function ownerViolations(check: Check, owner: String): Array<Violation> {
		return check.run([
			{ file: 'p/Declarator.hx', source: DECLARATOR },
			{ file: 'p/Plain.hx', source: PLAIN_IFACE },
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

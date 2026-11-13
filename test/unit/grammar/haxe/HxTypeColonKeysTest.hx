package unit.grammar.haxe;

import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.grammar.haxe.HaxeFormatConfigIssues;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * The colon of a named function-type parameter, `(call:QueryNode) -> Bool`, and the colon of a type-parameter
 * constraint, `<T:Dynamic>`, each follow a key of their own (`whitespace.arrowParamColonPolicy`,
 * `whitespace.typeParamConstraintColonPolicy`); an absent key follows `typeHintColonPolicy`, the policy of the
 * annotation colons around them.
 */
@:nullSafety(Strict)
final class HxTypeColonKeysTest extends Test {

	private static final ARROW_SRC: String = 'typedef F = (call:Int, x:String) -> Bool;';
	private static final ARROW_POSITIONS: String = 'class C {\n\tvar f:(call:Int) -> Bool;\n\tvar o:(?call:Int, Int) -> Bool;\n'
		+ '\tfunction g(h:(call:Int) -> Void):(a:Int) -> Void {}\n}';
	private static final CONSTRAINT_SRC: String = 'class C<T:Foo, S:Bar = Baz> {}';
	private static final CONSTRAINT_POSITIONS: String = 'typedef P<T:Foo> = {a:T};\ntypedef G<T:A & B> = T;\nabstract Ab<T:Foo>(T) {}\n'
		+ 'enum E<T:Foo> {}\ninterface I<T:Foo> {}\nclass C {\n\tfunction f<T:Foo>(x:T):Void {}\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARROW-COLON-LEAD-POLICY-OFF')
	public function testArrowColonFollowsItsKey(): Void {
		Assert.stringContains('(call:Int, x:String) -> Bool', write(ARROW_SRC, arrow('none')));
		Assert.stringContains('(call :Int, x :String) -> Bool', write(ARROW_SRC, arrow('before')));
		Assert.stringContains('(call: Int, x: String) -> Bool', write(ARROW_SRC, arrow('after')));
		Assert.stringContains('(call : Int, x : String) -> Bool', write(ARROW_SRC, arrow('around')));
	}

	@:pin('control')
	@:killer('M-CONSTRAINT-COLON-LEAD-POLICY-OFF')
	public function testConstraintColonFollowsItsKey(): Void {
		Assert.stringContains('class C<T:Foo, S:Bar = Baz>', write(CONSTRAINT_SRC, constraint('none')));
		Assert.stringContains('class C<T :Foo, S :Bar = Baz>', write(CONSTRAINT_SRC, constraint('before')));
		Assert.stringContains('class C<T: Foo, S: Bar = Baz>', write(CONSTRAINT_SRC, constraint('after')));
		Assert.stringContains('class C<T : Foo, S : Bar = Baz>', write(CONSTRAINT_SRC, constraint('around')));
	}

	@:pin('control')
	@:killer('M-ARROW-COLON-KEY-UNMAPPED')
	public function testArrowKeyLoadsIntoItsOption(): Void {
		Assert.equals(WhitespacePolicy.After, load(arrow('after')).arrowParamColon);
		Assert.equals(WhitespacePolicy.Both, load(arrow('around')).arrowParamColon);
		Assert.equals(WhitespacePolicy.Before, load(arrow('before')).arrowParamColon);
	}

	@:pin('control')
	@:killer('M-CONSTRAINT-COLON-KEY-UNMAPPED')
	public function testConstraintKeyLoadsIntoItsOption(): Void {
		Assert.equals(WhitespacePolicy.After, load(constraint('after')).typeParamConstraintColon);
		Assert.equals(WhitespacePolicy.Both, load(constraint('around')).typeParamConstraintColon);
		Assert.equals(WhitespacePolicy.Before, load(constraint('before')).typeParamConstraintColon);
	}

	@:pin('guard')
	public function testBothColonsAreTightWithoutAnyColonKey(): Void {
		final opts: HxModuleWriteOptions = load('{}');
		Assert.equals(WhitespacePolicy.None, opts.arrowParamColon);
		Assert.equals(WhitespacePolicy.None, opts.typeParamConstraintColon);
		Assert.stringContains('(call:Int, x:String) -> Bool', write(ARROW_SRC, '{}'));
		Assert.stringContains('class C<T:Foo, S:Bar = Baz>', write(CONSTRAINT_SRC, '{}'));
	}

	@:pin('control')
	@:killer('M-ARROW-COLON-ABSENT-TIGHT')
	public function testAbsentArrowKeyFollowsTheTypeHintPolicy(): Void {
		Assert.equals(WhitespacePolicy.Both, load(typeHint('around')).arrowParamColon);
		Assert.stringContains('(call : Int, x : String) -> Bool', write(ARROW_SRC, typeHint('around')));
		Assert.stringContains('(call: Int, x: String) -> Bool', write(ARROW_SRC, typeHint('after')));
	}

	@:pin('control')
	@:killer('M-CONSTRAINT-COLON-ABSENT-TIGHT')
	public function testAbsentConstraintKeyFollowsTheTypeHintPolicy(): Void {
		Assert.equals(WhitespacePolicy.Both, load(typeHint('around')).typeParamConstraintColon);
		Assert.stringContains('class C<T : Foo, S : Bar = Baz>', write(CONSTRAINT_SRC, typeHint('around')));
		Assert.stringContains('class C<T: Foo, S: Bar = Baz>', write(CONSTRAINT_SRC, typeHint('after')));
	}

	@:pin('guard')
	public function testASetKeyWinsOverTheTypeHintPolicy(): Void {
		final json: String = '{"whitespace": {"typeHintColonPolicy": "around", "arrowParamColonPolicy": "none", '
			+ '"typeParamConstraintColonPolicy": "before"}}';
		Assert.stringContains('(call:Int, x:String) -> Bool', write(ARROW_SRC, json));
		Assert.stringContains('class C<T :Foo, S :Bar = Baz>', write(CONSTRAINT_SRC, json));
	}

	@:pin('guard')
	public function testEachKeyLeavesTheOtherColonAndTheAnnotationsAlone(): Void {
		final arrowOut: String = write('class C<T:Foo> {\n\tvar x:Int;\n\tvar f:(call:Int) -> Bool;\n}', arrow('around'));
		Assert.stringContains('class C<T:Foo>', arrowOut);
		Assert.stringContains('var x:Int;', arrowOut);
		Assert.stringContains('var f:(call : Int) -> Bool;', arrowOut);
		final constraintOut: String = write('class C<T:Foo> {\n\tvar x:Int;\n\tvar f:(call:Int) -> Bool;\n}', constraint('around'));
		Assert.stringContains('class C<T : Foo>', constraintOut);
		Assert.stringContains('var x:Int;', constraintOut);
		Assert.stringContains('var f:(call:Int) -> Bool;', constraintOut);
	}

	@:pin('guard')
	public function testArrowColonKeyReachesEveryFunctionTypePosition(): Void {
		for (out in [
			write(ARROW_POSITIONS, arrow('after')),
			writePlain(ARROW_POSITIONS, arrow('after'))
		]) {
			Assert.stringContains('var f:(call: Int) -> Bool;', out);
			Assert.stringContains('var o:(?call: Int, Int) -> Bool;', out);
			Assert.stringContains('function g(h:(call: Int) -> Void):(a: Int) -> Void', out);
		}
	}

	@:pin('guard')
	public function testConstraintColonKeyReachesEveryTypeParameterSite(): Void {
		for (out in [
			write(CONSTRAINT_POSITIONS, constraint('after')),
			writePlain(CONSTRAINT_POSITIONS, constraint('after'))
		]) {
			Assert.stringContains('typedef P<T: Foo>', out);
			Assert.stringContains('typedef G<T: A & B> = T;', out);
			Assert.stringContains('abstract Ab<T: Foo>(T)', out);
			Assert.stringContains('enum E<T: Foo>', out);
			Assert.stringContains('interface I<T: Foo>', out);
			Assert.stringContains('function f<T: Foo>(x:T):Void', out);
		}
	}

	@:pin('guard')
	public function testTheTwoKeysAreIndependent(): Void {
		final json: String = '{"whitespace": {"arrowParamColonPolicy": "after", "typeParamConstraintColonPolicy": "before"}}';
		Assert.stringContains('(call: Int, x: String) -> Bool', write(ARROW_SRC, json));
		Assert.stringContains('class C<T :Foo, S :Bar = Baz>', write(CONSTRAINT_SRC, json));
	}

	@:pin('guard')
	public function testBothKeysAreKnownToTheConfigDiagnostics(): Void {
		final known: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"whitespace": {"arrowParamColonPolicy": "after", "typeParamConstraintColonPolicy": "after"}}'
		);
		Assert.equals(0, known.keys.length, 'reported: ${known.keys.join(', ')}');
		Assert.equals(1, HaxeFormatConfigDiagnostics.diagnose('{"whitespace": {"arrowParamColonPolicyy": "after"}}').keys.length);
	}

	private static function arrow(policy: String): String {
		return '{"whitespace": {"arrowParamColonPolicy": "$policy"}}';
	}

	private static function constraint(policy: String): String {
		return '{"whitespace": {"typeParamConstraintColonPolicy": "$policy"}}';
	}

	private static function typeHint(policy: String): String {
		return '{"whitespace": {"typeHintColonPolicy": "$policy"}}';
	}

	private static function load(json: String): HxModuleWriteOptions {
		return HxWriteOptionsKit.strictJson(json);
	}

	private static function write(src: String, json: String): String {
		return HxWriteFixture.triviaWrite(src, json);
	}

	private static function writePlain(src: String, json: String): String {
		return HxWriteFixture.plainWrite(src, json);
	}

}

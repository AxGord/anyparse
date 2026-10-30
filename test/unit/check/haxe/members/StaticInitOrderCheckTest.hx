package unit.check.haxe.members;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.haxe.members.StaticInitOrder;

/**
 * The `static-init-order` check: a static initializer reading a static declared below it is flagged `Warning`,
 * report-only. An earlier field, a read inside a function literal or a comment, an inline or uninitialized field, and an
 * instance field are left alone.
 */
class StaticInitOrderCheckTest extends Test {

	public function testLaterStaticReadFlagged(): Void {
		final vs: Array<Violation> = violations('static var a:Int = b + 1;\n\tstatic var b:Int = 5;');
		Assert.equals(1, vs.length);
		Assert.equals('static-init-order', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('`b`') >= 0);
		Assert.equals(1, violations('static final a:String = C.b;\n\tstatic final b:String = "x";').length);
	}

	/** The finding names the field the initializer reads, not a later field's name spelled as a member of it. */
	public function testNamesTheFieldActuallyRead(): Void {
		final vs: Array<Violation> = violations('static var a:Int = ob.b;\n\tstatic var b:Int = 3;\n\tstatic var ob:Dynamic = {};');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('`ob`') >= 0);
	}

	/** A string, an object-literal key and a comment spell the later field's name without reading it. */
	public function testWordsAreNoReads(): Void {
		Assert.equals(0, violations('static var a:String = "b text";\n\tstatic var b:Int = 2;').length);
		Assert.equals(0, violations('static var a:Dynamic = { b: 1 };\n\tstatic var b:Int = 2;').length);
		Assert.equals(0, violations('static var a:Int = /* b */ 1;\n\tstatic var b:Int = 5;').length);
	}

	/** Only the declaring type's own name qualifies a read of its static. */
	@:pin('control')
	@:killer('M-STATICINIT-ANY-QUALIFIER')
	public function testOtherTypesStaticNotFlagged(): Void {
		Assert.equals(0, violations('static var a:Int = Other.b;\n\tstatic var b:Int = 1;').length);
		Assert.equals(1, violations('static var a:Int = C.b;\n\tstatic var b:Int = 1;').length);
	}

	/** A read is the declaration it binds: a comprehension binder of the later field's name is not that field. */
	@:pin('control')
	@:killer('M-STATICINIT-BY-NAME')
	public function testShadowingBinderNotFlagged(): Void {
		Assert.equals(0, violations('static var a:Array<Int> = [for (b in [1, 2]) b];\n\tstatic var b:Int = 1;').length);
	}

	/** One finding per initializer, however many later fields it reads. */
	public function testOneFindingPerInitializer(): Void {
		Assert.equals(1, violations('static var a:Int = b + c;\n\tstatic var b:Int = 1;\n\tstatic var c:Int = 2;').length);
	}

	/** A field declared above the reader is initialized before it. */
	@:pin('control')
	@:killer('M-STATICINIT-ANY-ORDER')
	public function testEarlierStaticReadNotFlagged(): Void {
		Assert.equals(0, violations('static var b:Int = 5;\n\tstatic var a:Int = b + 1;').length);
	}

	/** A read inside a function literal runs when it is called, after every initializer. */
	@:pin('control')
	@:killer('M-STATICINIT-NO-DEFERRED')
	public function testDeferredReadsNotFlagged(): Void {
		Assert.equals(0, violations('static var f:() -> Int = () -> b;\n\tstatic var b:Int = 5;').length);
		Assert.equals(0, violations('static var f:() -> Int = function() return b;\n\tstatic var b:Int = 5;').length);
	}

	/** An inline field is folded, an uninitialized one has no order, an instance field runs in another phase. */
	public function testOtherTargetsNotFlagged(): Void {
		Assert.equals(0, violations('static var a:Int = b + 1;\n\tstatic inline final b:Int = 5;').length);
		Assert.equals(0, violations('static var a:Null<Int> = b;\n\tstatic var b:Null<Int>;').length);
		Assert.equals(0, violations('static var a:Int = b;\n\tvar b:Int = 5;').length);
	}

	public function testNoFixAndDefaultOn(): Void {
		Assert.equals(0, CheckFixture.edits(new StaticInitOrder(), wrap('static var a:Int = b;\n\tstatic var b:Int = 5;')).length);
		Assert.notNull(Linter.byId('static-init-order'));
		Assert.isFalse(Std.isOfType(new StaticInitOrder(), DefaultOff));
	}

	private function wrap(members: String): String {
		return 'class C {\n\t$members\n}';
	}

	private function violations(members: String): Array<Violation> {
		return CheckFixture.violations(new StaticInitOrder(), wrap(members));
	}

}

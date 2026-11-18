package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The `moduleOnlyTypedefs` wrap condition: a module-level fact, true when every top-level declaration of the module is a
 * typedef, handed to the typedef-body cascade by the grammar.
 *
 * `CONFIG` gives `typedefBody` one rule — `moduleOnlyTypedefs` and two items put the body one item per line — and a
 * `noWrap` default, so a body that fits stays on one line exactly where the rule does not fire.
 */
@:nullSafety(Strict)
final class HxModuleOnlyTypedefsWrapTest extends Test {

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"typedefBody":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"moduleOnlyTypedefs","value":1},'
		+ '{"cond":"itemCount >= n","value":2}],"type":"onePerLine"}]}}}';

	/** Three fields, a `> Base` extension with one field (two items) and a single field. */
	private static final BODIES: String = 'typedef Entity = {Folders:Array<Folder>, Files:Array<File>, Sharing:Array<Info>}\n\n'
		+ 'typedef Outside = {> BaseUser, newInvite:Bool}\n\ntypedef Time = {Time:String}';

	private static final BODIES_OUT: String = 'typedef Entity = {\n\tFolders:Array<Folder>,\n\tFiles:Array<File>,\n\tSharing:Array<Info>\n}\n\n'
		+ 'typedef Outside = {\n\t> BaseUser,\n\tnewInvite:Bool\n}\n\ntypedef Time = {Time:String}';
	private static final HEADER: String = 'package p;\n\nimport a.B;\n\nusing Lambda;\n\n// doc\n';

	/** The rule of `CONFIG` with the polarity flipped: it fires in a module that is NOT typedef-only. */
	private static final NOT_ONLY_CONFIG: String = '{"wrapping":{"maxLineLength":140,"typedefBody":{"defaultWrap":"noWrap","rules":['
		+ '{"conditions":[{"cond":"moduleOnlyTypedefs","value":0},{"cond":"itemCount >= n","value":2}],"type":"onePerLine"}]}}}';

	/** The same rule on `anonType`, which a nested anonymous type and a field type follow. */
	private static final ANON_CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"anonType":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"moduleOnlyTypedefs","value":1},'
		+ '{"cond":"itemCount >= n","value":2}],"type":"onePerLine"}]}}}';

	public function new(): Void {
		super();
	}

	/** Every body of two or more items breaks in a module of typedefs only; a single item stays on its line. */
	@:pin('control')
	@:killer('M-MODULE-ONLY-COND-OFF')
	public function testTypedefOnlyModuleBreaksItsBodies(): Void {
		Assert.equals(BODIES_OUT, write(BODIES));
		Assert.equals(BODIES_OUT, write(BODIES_OUT));
	}

	/** A class, enum, abstract, interface or function in the module keeps every typedef body on the fit rule. */
	@:pin('control')
	@:killer('M-MODULE-ONLY-OTHER-DECL-HOLDS')
	public function testDeclarationOtherThanTypedefKeepsTheFit(): Void {
		for (other in [
			'class C {}',
			'enum E {\n\tA;\n}',
			'abstract A(Int) {}',
			'interface I {}',
			'function f() {}'
		]) {
			final src: String = 'typedef T = {a:Int, b:Int}\n\n$other';
			Assert.equals(src, write(src));
		}
	}

	/** `package`, `import`, `using` and comments do not count against the module. */
	@:pin('control')
	@:killer('M-MODULE-ONLY-HEADER-COUNTS')
	public function testHeaderLinesDoNotCount(): Void {
		Assert.equals('${HEADER}typedef T = {\n\ta:Int,\n\tb:Int\n}', write('${HEADER}typedef T = {a:Int, b:Int}'));
	}

	/** An `#if` region counts by every one of its arms. */
	@:pin('control')
	@:killer('M-MODULE-ONLY-REGION-ARMS-SKIPPED')
	public function testConditionalRegionHoldsByItsArms(): Void {
		final typedefs: String = '#if js\ntypedef E = {a:Int, b:Int}\n#else\ntypedef E = {a:Int, c:Int}\n#end';
		Assert.equals('#if js\ntypedef E = {\n\ta:Int,\n\tb:Int\n}\n#else\ntypedef E = {\n\ta:Int,\n\tc:Int\n}\n#end', write(typedefs));
		final mixed: String = '#if js\ntypedef E = {a:Int, b:Int}\n#else\nclass E {}\n#end';
		Assert.equals(mixed, write(mixed));
	}

	/** Without the rule nothing moves: the same module keeps its one-line bodies. */
	@:pin('guard')
	public function testWithoutTheRuleBodiesFitOnOneLine(): Void {
		Assert.equals(
			BODIES, HxWriteFixture.triviaWrite(BODIES, '{"wrapping":{"maxLineLength":140,"typedefBody":{"defaultWrap":"noWrap"}}}')
		);
	}

	/** An `#elseif` arm counts like the others: a class in it keeps the fit rule, a typedef in it breaks all three bodies. */
	@:pin('control')
	@:killer('M-MODULE-ONLY-ELSEIF-ARMS-SKIPPED')
	public function testElseifArmCounts(): Void {
		final withClass: String = '#if js\ntypedef E = {a:Int, b:Int}\n#elseif cpp\nclass E {}\n#else\ntypedef E = {a:Int, d:Int}\n#end';
		Assert.equals(withClass, write(withClass));
		Assert.equals(
			'#if js\ntypedef E = {\n\ta:Int,\n\tb:Int\n}\n#elseif cpp\ntypedef E = {\n\ta:Int,\n\tc:Int\n}\n#else\ntypedef E = {\n'
			+ '\ta:Int,\n\td:Int\n}\n#end',
			write('#if js\ntypedef E = {a:Int, b:Int}\n#elseif cpp\ntypedef E = {a:Int, c:Int}\n#else\ntypedef E = {a:Int, d:Int}\n#end')
		);
	}

	/** `value: 0` asks for a module that is not typedef-only: it breaks a typedef beside a class, not in a typedef-only module. */
	@:pin('control')
	@:killer('M-MODULE-ONLY-POLARITY-IGNORED')
	public function testValueZeroAsksForTheOppositeModule(): Void {
		Assert.equals(
			'typedef Z = {\n\ta:Int,\n\tb:Int\n}\n\nclass C {}',
			HxWriteFixture.triviaWrite('typedef Z = {a:Int, b:Int}\n\nclass C {}', NOT_ONLY_CONFIG)
		);
		Assert.equals('typedef Z = {a:Int, b:Int}', HxWriteFixture.triviaWrite('typedef Z = {a:Int, b:Int}', NOT_ONLY_CONFIG));
	}

	/** An `anonType` rule reads the fact too: a nested anonymous type in a typedef-only module breaks, a field type in a class does not. */
	@:pin('guard')
	public function testAnonTypeRuleReadsTheFact(): Void {
		Assert.equals(
			'typedef N = {\n\ta:{\n\t\tx:Int,\n\t\ty:Int\n\t},\n\tb:Int\n}',
			HxWriteFixture.triviaWrite('typedef N = {a:{x:Int, y:Int}, b:Int}', ANON_CONFIG)
		);
		final field: String = 'class C {\n\tvar f:{a:Int, b:Int};\n}';
		Assert.equals(field, HxWriteFixture.triviaWrite(field, ANON_CONFIG));
	}

	private inline function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}

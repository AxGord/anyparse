package unit.query;

import anyparse.check.facts.TypedFactsProbe;
import anyparse.query.CompilerFacts;
import anyparse.query.FactKinds;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * `FactKinds` against a real compile: every kind and id string `TypedFactsProbe` writes into a fact is one the readers
 * of `CompilerFacts` compare against, so the vocabulary has one owner and the producer cannot drift from its consumers.
 */
@:nullSafety(Strict)
class FactKindsTest extends Test {

	/** A js target has no overloads, so the fixture compiles for the jvm. */
	private static inline final BUILD: String = '-cp .\n-main Main\n--jvm out.jar\n';

	private static inline final MACRO_BUILD: String = '-cp .\n-main Main\n--js out.js\n';
	private static final SOURCE: String = 'interface Shape { function area():Int; }\nenum Color { Red; Rgb(r:Int); }\n'
		+ 'typedef Point = {x:Int};\nabstract Meters(Int) { public function new(i:Int) this = i; }\nclass '
		+ 'Circle implements Shape {\n\tpublic var radius:Int = 1;\n\tpublic function new() {}\n\tstatic '
		+ 'function __init__():Void { Sys.println("init"); }\n\tpublic function area():Int return radius;\n'
		+ '\tpublic inline function grow():Void radius++;\n\tpublic dynamic function shrink():Void {}\n'
		+ '\tpublic function run():Int {\n\t\tfunction named(x:Int) return x + 1;\n\t\treturn '
		+ '[1].map(function(x:Int) return x * 2).length + named(2);\n\t}\n}\nclass Main {\n\tstatic inline '
		+ 'function mk():Int->Int return function(x:Int) return x;\n\toverload static function '
		+ 'ov(i:Int):Void {}\n\toverload static function ov(s:String):Void {}\n\tstatic function main() {\n'
		+ '\t\tvar c = new Circle(); c.run(); c.grow(); c.shrink(); ov(1); ov("x");\n\t\tvar g = mk(); var '
		+ 'h = mk(); g(1); h(2);\n\t\tvar m:Meters = new Meters(1); var col = Rgb(1); var p:Point = {'
		+ 'x: 1};\n\t\tReflect.field(c, "radius"); Type.createInstance(Circle, []);\n\t}\n}\n';

	/** The macro function: a js target types it without the overload fixture. */
	private static final MACRO_SOURCE: String =
		'class Main { public static macro function make() return macro null; static function main() {} }\n';

	private var _dir: Null<String>;
	private var _facts: Null<CompilerFacts>;
	private var _macroDir: Null<String>;
	private var _macroFacts: Null<CompilerFacts>;

	public function setupClass(): Void {
		final dir: String = CliFixture.writeTree(
			'fact_kinds', [{ name: 'Main.hx', source: SOURCE }, { name: 'build.hxml', source: BUILD }]
		);
		_dir = dir;
		_facts = TypedFactsProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }]);
		// the overload fixture does not compile beside a macro function, so the macro field has a compile of its own
		final macroDir: String = CliFixture.writeTree('fact_kinds_macro', [
			{ name: 'Main.hx', source: MACRO_SOURCE },
			{ name: 'build.hxml', source: MACRO_BUILD }
		]);
		_macroDir = macroDir;
		_macroFacts = TypedFactsProbe.probeAll([{ hxml: 'build.hxml', dir: macroDir, defines: [] }]);
	}

	public function teardownClass(): Void {
		final dir: Null<String> = _dir;
		if (dir != null) CliFixture.removeDir(dir);
		final macroDir: Null<String> = _macroDir;
		if (macroDir != null) CliFixture.removeDir(macroDir);
	}

	@:pin('control') @:killer('M-FACTKINDS-TYPE-INTERFACE') @:killer('M-FACTKINDS-TYPE-IMPL')
	public function testTheTypeKindsAreTheOnesTheReadersCompare(): Void {
		// the producer's kind for each declaration form is a constant, and the readers' groups hold exactly those
		Assert.equals(FactKinds.CLASS, kindOf('Circle'));
		Assert.equals(FactKinds.INTERFACE, kindOf('Shape'));
		Assert.equals(FactKinds.ENUM, kindOf('Color'));
		Assert.equals(FactKinds.TYPEDEF, kindOf('Point'));
		Assert.equals(FactKinds.ABSTRACT, kindOf('Meters'));
		final impl: String = _facts?.type('Meters')?.implementation ?? '';
		Assert.equals(FactKinds.IMPL, kindOf(impl));
		Assert.isTrue(FactKinds.OBJECT_KINDS.contains(kindOf('Circle')) && FactKinds.OBJECT_KINDS.contains(kindOf('Shape')));
		Assert.isFalse(FactKinds.OBJECT_KINDS.contains(kindOf('Color')));
		Assert.isTrue(FactKinds.NOMINAL_KINDS.contains(kindOf('Color')));
		Assert.isFalse(FactKinds.NOMINAL_KINDS.contains(kindOf('Point')) || FactKinds.NOMINAL_KINDS.contains(kindOf('Meters')));
		Assert.isTrue(FactKinds.CODE_KINDS.contains(kindOf('Circle')) && FactKinds.CODE_KINDS.contains(kindOf(impl)));
		Assert.isFalse(FactKinds.CODE_KINDS.contains(kindOf('Shape')));
	}

	@:pin('control') @:killer('M-FACTKINDS-NODE-METHOD') @:killer('M-FACTKINDS-NODE-NESTED')
	public function testTheNodeKindsAreTheOnesTheReadersCompare(): Void {
		Assert.equals(FactKinds.CTOR, nodeKind('Circle.new'));
		Assert.equals(FactKinds.METHOD, nodeKind('Circle.area'));
		Assert.equals(FactKinds.VAR, nodeKind('Circle.radius'));
		Assert.equals(FactKinds.INIT, nodeKind('Circle.__init__'));
		final nested: Array<String> = _facts?.node('Circle.run')?.fns ?? [];
		final nestedKinds: Array<String> = nested.map(nodeKind);
		Assert.equals(2, nestedKinds.length);
		Assert.isTrue(nestedKinds.contains(FactKinds.FN) && nestedKinds.contains(FactKinds.LOCAL), 'nested: $nestedKinds');
		Assert.isTrue(
			FactKinds.OWN_BODY_KINDS.contains(nodeKind('Circle.new')) && FactKinds.OWN_BODY_KINDS.contains(nodeKind('Circle.area'))
		);
		Assert.isFalse(nestedKinds.exists(k -> FactKinds.OWN_BODY_KINDS.contains(k)));
		Assert.isTrue(nestedKinds.foreach(k -> FactKinds.NESTED_FUNCTION_KINDS.contains(k)));
		for (id in ['Circle.new', 'Circle.area'].concat(nested)) Assert.isTrue(FactKinds.FUNCTION_KINDS.contains(nodeKind(id)), id);
		Assert.isFalse(FactKinds.FUNCTION_KINDS.contains(nodeKind('Circle.radius')));
		Assert.isFalse(FactKinds.FUNCTION_KINDS.contains(nodeKind('Circle.__init__')));
	}

	@:pin('control') @:killer('M-FACTKINDS-FIELD-DYNAMIC')
	public function testTheFieldKindsAreTheOnesTheReadersCompare(): Void {
		final fields: Array<FieldDeclFact> = _facts?.type('Circle')?.fields ?? [];
		Assert.equals(FactKinds.METHOD, fieldKind(fields, 'area'));
		Assert.equals(FactKinds.INLINE, fieldKind(fields, 'grow'));
		Assert.equals(FactKinds.DYNAMIC, fieldKind(fields, 'shrink'));
		Assert.equals(FactKinds.MACRO, fieldKind(_macroFacts?.type('Main')?.fields ?? [], 'make'));
		for (name in ['area', 'grow', 'shrink']) Assert.isTrue(FactKinds.METHOD_KINDS.contains(fieldKind(fields, name)), name);
		Assert.isFalse(FactKinds.METHOD_KINDS.contains(fieldKind(fields, 'radius')));
		Assert.isFalse(FactKinds.METHOD_KINDS.contains(FactKinds.MACRO));
		Assert.isTrue(FactKinds.FIXED_METHOD_KINDS.contains(fieldKind(fields, 'grow')));
		Assert.isFalse(FactKinds.FIXED_METHOD_KINDS.contains(fieldKind(fields, 'shrink')));
	}

	@:pin('control') @:killer('M-FACTKINDS-ID-NESTED') @:killer('M-FACTKINDS-ID-OVERLOAD') @:killer('M-FACTKINDS-ID-UNIQUE')
	public function testTheIdSeparatorsAreTheOnesTheReadersSplitOn(): Void {
		final nested: Array<String> = _facts?.node('Circle.run')?.fns ?? [];
		Assert.isTrue(nested.length > 0 && nested.foreach(id -> id.startsWith('Circle.run${FactKinds.NESTED_ID}')), 'nested: $nested');
		Assert.equals(1, _facts?.node('Main.ov${FactKinds.OVERLOAD_ID}1')?.overloadIndex);
		// two inlined copies of one lambda land on one nested id, and the later is numbered
		final copies: Array<String> = _facts?.node('Main.main')?.fns ?? [];
		Assert.isTrue(
			copies.exists(id -> id.contains('${FactKinds.NESTED_ID}') && id.endsWith('${FactKinds.UNIQUE_ID}1')), 'copies: $copies'
		);
	}

	@:pin('control') @:killer('M-FACTKINDS-REFLECTION-TYPE')
	public function testTheReflectionClassesAreTheOnesTheProbeMarks(): Void {
		final targets: Array<String> = [for (r in _facts?.node('Main.main')?.reflection ?? []) r.target];
		for (cls in FactKinds.REFLECTION_CLASSES)
			Assert.isTrue(targets.exists(t -> t.startsWith('$cls.')), 'no reflection fact of `$cls`: $targets');
	}

	private function kindOf(id: String): String {
		return _facts?.type(id)?.kind ?? '';
	}

	private function nodeKind(id: String): String {
		return _facts?.node(id)?.kind ?? '';
	}

	private static function fieldKind(fields: Array<FieldDeclFact>, name: String): String {
		for (f in fields) if (f.name == name) return f.kind;
		return '';
	}

}

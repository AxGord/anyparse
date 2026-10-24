package unit.check;

import anyparse.check.LintConfig;
import anyparse.check.ShortenTypeRef;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

/**
 * `shorten-type-ref` decides by RESOLUTION, not by what the file already spells short: a path whose short name reaches
 * the same type here — through an enclosing package or a transparent root alias — is reported and shortened with no
 * import, even when nothing else in the file writes the short name.
 */
class ShortenTypeRefResolutionTest extends Test {

	/** The enclosing-package type every consumer below sits under. */
	private static inline final ENTITY_SOURCE: String =
		'package pkg;\n\nclass Entity<T> {\n\tpublic function new(path:String) {}\n\n\tpublic static function make():String {\n\t\treturn \'pkg\';\n\t}\n}\n';

	/** A build macro's carriers: the macro module itself, an `@:autoBuild` interface and an `@:autoBuild` class. */
	private static final MACRO_LIBRARY: Array<{ file: String, source: String }> = [
		{
			file: 'pkg/Builder.hx',
			source: 'package pkg;\n\nclass Builder {\n\tpublic static function build():Array<Dynamic> {\n\t\treturn null;\n\t}\n}\n'
		},
		{ file: 'pkg/Auto.hx', source: 'package pkg;\n\n@:autoBuild(pkg.Builder.build())\ninterface Auto {}\n' },
		{ file: 'pkg/SBase.hx', source: 'package pkg;\n\n@:autoBuild(pkg.Builder.build())\nclass SBase {\n\tpublic function new() {}\n}\n' }
	];

	/** Library types whose simple names an enclosing package (`Entity`), a builtin (`Date`) or nothing (`Gadget`) already holds. */
	private static final LIB_DEEP: Array<{ file: String, source: String }> = [
		for (name in ['Entity', 'Date', 'Gadget']) { file: 'lib/deep/$name.hx', source: 'package lib.deep;\n\nclass $name {}\n' }
	];

	@:pin('control')
	@:killer('M-PRINTER-PACKAGE-CHAIN-BLIND')
	public function testEnclosingPackageTypeShortensWithNoImport(): Void {
		final src: String = holder('\tpublic final a:pkg.Entity<String> = null;\n');
		final out: String = applyFix(src, []);
		Assert.isTrue(out.indexOf('public final a:Entity<String> = null;') != -1, 'shortened, got: $out');
		Assert.equals(-1, out.indexOf('import '), 'no import needed, got: $out');
		Assert.equals('an over-qualified type reference - the short name resolves to the same type here', violations(src, [])[0].message);
	}

	@:pin('control')
	@:killer('M-PRINTER-TRANSPARENT-ALIAS')
	public function testStdMapShortensThroughTheRootAlias(): Void {
		final src: String = holder('\tstatic final m:haxe.ds.Map<String, String> = [\'a\' => \'b\'];\n');
		final out: String = applyFix(src, []);
		Assert.isTrue(out.indexOf('static final m:Map<String, String> =') != -1, 'shortened, got: $out');
		Assert.equals(-1, out.indexOf('import '), 'no import needed, got: $out');
	}

	public function testNearerPackageTypeLeavesTheEnclosingPathAlone(): Void {
		final nearer: Array<{ file: String, source: String }> = [
			{ file: 'pkg/sub/Entity.hx', source: 'package pkg.sub;\n\nclass Entity<T> {}\n' }
		];
		Assert.equals(0, violations(holder('\tpublic final a:pkg.Entity<String> = null;\n'), nearer).length);
	}

	public function testEnclosingPackageMapShadowsTheBuiltin(): Void {
		final shadow: Array<{ file: String, source: String }> = [{ file: 'pkg/Map.hx', source: 'package pkg;\n\nclass Map<K, V> {}\n' }];
		Assert.equals(0, violations(holder('\tstatic final m:haxe.ds.Map<String, String> = null;\n'), shadow).length);
	}

	// --- a VALUE position: a value of the short name outranks the type ---

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-SITE-BLIND')
	public function testALocalOfTheShortNameKeepsTheValueSiteQualified(): Void {
		final src: String = holder(
			'\tpublic static function f(y:Dynamic):Bool {\n\t\tfinal Entity:String = \'local\';\n\t\ttrace(Entity);\n'
			+ '\t\treturn Std.isOfType(y, pkg.Entity);\n\t}\n'
		);
		Assert.equals(0, violations(src, []).length);
	}

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-SITE-BLIND')
	public function testAModuleEnumConstructorKeepsTheValueSiteQualified(): Void {
		final src: String = 'package pkg.sub;\n\nenum K {\n\tEntity;\n}\n\nclass Holder {\n'
			+ '\tpublic static function f(y:Dynamic):Bool {\n\t\treturn Std.isOfType(y, pkg.Entity);\n\t}\n}\n';
		Assert.equals(0, violations(src, []).length);
	}

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-SITE-BLIND')
	public function testALocalStructureKeepsTheStaticCallQualified(): Void {
		final src: String = holder(
			'\tpublic static function f():String {\n\t\tfinal Entity = {make: () -> \'local\'};\n'
			+ '\t\treturn pkg.Entity.make() + Entity.make();\n\t}\n'
		);
		Assert.equals(0, violations(src, []).length);
	}

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-DOORS-SKIPPED')
	public function testAnInheritedFieldKeepsTheValueSiteQualified(): Void {
		final base: Array<{ file: String, source: String }> = [
			{
				file: 'pkg/Base.hx',
				source: 'package pkg;\n\nclass Base {\n\tpublic var Entity:String = \'\';\n\n\tpublic function new() {}\n}\n'
			}
		];
		final src: String = 'package pkg.sub;\n\nclass Holder extends Base {\n'
			+ '\tpublic function f(y:Dynamic):Bool {\n\t\treturn Std.isOfType(y, pkg.Entity);\n\t}\n}\n';
		Assert.equals(0, violations(src, base).length);
	}

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-SITE-BLIND')
	public function testAnImportedTypeDoesNotOutrankALocalAtAValueSite(): Void {
		final src: String = 'package pkg.sub;\n\nimport pkg.Entity;\n\nclass Holder {\n\tpublic static function f(y:Dynamic):Bool {\n'
			+ '\t\tfinal Entity:String = \'local\';\n\t\ttrace(Entity);\n\t\treturn Std.isOfType(y, pkg.Entity);\n\t}\n}\n';
		Assert.equals(0, violations(src, []).length);
	}

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-SITE-NEVER')
	public function testAFreeValueSiteShortens(): Void {
		final src: String = holder(
			'\tpublic static function f(y:Dynamic):Bool {\n\t\treturn Std.isOfType(y, pkg.Entity) && pkg.Entity.make() != \'\';\n\t}\n'
		);
		final out: String = applyFix(src, []);
		Assert.isTrue(out.indexOf('return Std.isOfType(y, Entity) && Entity.make() != \'\';') != -1, 'shortened, got: $out');
	}

	// --- a build macro may add the field a value site would read ---

	@:pin('control')
	@:killer('M-VALUE-DOORS-BUILD-BLIND')
	public function testABuildMacroOnTheClassKeepsTheValueSiteQualified(): Void {
		Assert.equals(0, violations(builtHolder('', '@:build(pkg.Builder.build())\n', ''), MACRO_LIBRARY).length);
	}

	@:pin('control')
	@:killer('M-VALUE-DOORS-BUILD-BLIND')
	public function testAnAutoBuildInterfaceKeepsTheValueSiteQualified(): Void {
		Assert.equals(0, violations(builtHolder('', '', ' implements Auto'), MACRO_LIBRARY).length);
	}

	@:pin('control')
	@:killer('M-VALUE-DOORS-BUILD-BLIND')
	public function testAnAutoBuildSuperclassKeepsTheValueSiteQualified(): Void {
		Assert.equals(0, violations(builtHolder('', '', ' extends SBase'), MACRO_LIBRARY).length);
	}

	@:pin('control')
	@:killer('M-VALUE-DOORS-BUILD-BLIND')
	public function testABuildMacroKeepsTheImportRouteQualifiedToo(): Void {
		Assert.equals(0, violations(builtHolder('import pkg.Entity;\n\n', '@:build(pkg.Builder.build())\n', ''), MACRO_LIBRARY).length);
	}

	@:pin('control')
	@:killer('M-SHORTEN-VALUE-SITE-NEVER')
	public function testTheUnbuiltTwinShortens(): Void {
		final out: String = applyFix(builtHolder('', '', ''), MACRO_LIBRARY);
		Assert.isTrue(out.indexOf('trace(Entity.make());') != -1, 'shortened, got: $out');
	}

	// --- the add-import arm takes a name only where nothing else reaches it without an import ---

	/** `Gadget` is the positive control: the same fixture still buys its import, so the refusal is the name, not the arm. */
	@:pin('control')
	@:killer('M-SHORTEN-IMPORT-CHAIN-CONFLICT-BLIND')
	public function testAnEnclosingPackageTypeOfTheNameRefusesTheImport(): Void {
		final out: String = applyFix(holder(twice('lib.deep.Entity') + twice('lib.deep.Gadget')), LIB_DEEP);
		Assert.equals(-1, out.indexOf('import lib.deep.Entity;'), 'pkg.Entity holds the name, got: $out');
		Assert.isTrue(out.indexOf('public final e0:lib.deep.Entity') != -1, 'kept qualified, got: $out');
		Assert.isTrue(out.indexOf('import lib.deep.Gadget;') != -1 && out.indexOf('public final g0:Gadget') != -1, 'control, got: $out');
	}

	@:pin('control')
	@:killer('M-SHORTEN-IMPORT-BUILTIN-BLIND')
	public function testABuiltinOfTheNameRefusesTheImport(): Void {
		final out: String = applyFix(holder(twice('lib.deep.Date') + twice('lib.deep.Gadget')), LIB_DEEP);
		Assert.equals(-1, out.indexOf('import lib.deep.Date;'), 'the std Date holds the name, got: $out');
		Assert.isTrue(out.indexOf('import lib.deep.Gadget;') != -1, 'control, got: $out');
	}

	/** `X.X` written inside a class `X` of another module: the bare name means the enclosing class, never the root module's type. */
	@:pin('guard')
	public function testAModuleQualifiedSelfNameStaysQualified(): Void {
		final root: Array<{ file: String, source: String }> = [{ file: 'X.hx', source: 'class X {\n\tpublic function new() {}\n}\n' }];
		final src: String = 'package pkg;\n\nclass X {\n\tpublic final a:X.X = null;\n\tpublic final b:X.X = null;\n}\n';
		Assert.equals(0, violationsAt('pkg/X.hx', src, root).length);
	}

	/** Two fields typed `path`, named after its last segment. */
	private function twice(path: String): String {
		final name: String = path.charAt(path.lastIndexOf('.') + 1).toLowerCase();
		return '\tpublic final ${name}0:$path = null;\n\tpublic final ${name}1:$path = null;\n';
	}

	/** A `pkg.sub.Holder` carrying `imports`, the metadata `meta` and the heritage `heritage`, calling `pkg.Entity.make()` twice. */
	private function builtHolder(imports: String, meta: String, heritage: String): String {
		return 'package pkg.sub;\n\n${imports}${meta}class Holder$heritage {\n\tpublic function new() {}\n\n'
			+ '\tpublic function f():Void {\n\t\ttrace(pkg.Entity.make());\n\t\ttrace(pkg.Entity.make());\n\t}\n}\n';
	}

	/** A `pkg.sub.Holder` module whose class body is `members`, with no import. */
	private function holder(members: String): String {
		return 'package pkg.sub;\n\nclass Holder {\n$members}\n';
	}

	/** The resolution scope: the consumer, the enclosing-package type, the std's `Map` pair, and `extra`. */
	private function plugin(
		report: Array<{ file: String, source: String }>, extra: Array<{ file: String, source: String }>
	): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final library: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Entity.hx', source: ENTITY_SOURCE },
			{ file: 'Map.hx', source: 'typedef Map<K, V> = haxe.ds.Map<K, V>;\n' },
			{ file: 'haxe/ds/Map.hx', source: 'package haxe.ds;\n\nabstract Map<K, V>(Dynamic) {}\n' }
		].concat(extra);
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: [],
				library: new LibrarySources(library)
			}
		});
		return scoped;
	}

	private function violations(src: String, extra: Array<{ file: String, source: String }>): Array<Violation> {
		return violationsAt('pkg/sub/Holder.hx', src, extra);
	}

	/** The findings for `src` written as the module `file`. */
	private function violationsAt(file: String, src: String, extra: Array<{ file: String, source: String }>): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: file, source: src }];
		return CheckFixture.violationsIn(valueRule(), report, plugin(report, extra));
	}

	private function applyFix(src: String, extra: Array<{ file: String, source: String }>): String {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/sub/Holder.hx', source: src }];
		return CanonicalEdit.applyEdits(src, CheckFixture.fixRun(valueRule(), report, plugin(report, extra)).edits);
	}

	/** The rule with VALUE positions opted in, so the value-site pins exercise their gates. */
	private static function valueRule(): ShortenTypeRef {
		final rule: ShortenTypeRef = new ShortenTypeRef();
		rule.setConfigResolver(_ -> LintConfig.parse('{"rules":{"shorten-type-ref":{"valuePositions":true}}}'));
		return rule;
	}

}

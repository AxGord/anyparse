package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.ValueNameBinding.FieldAlias;
import anyparse.query.ValueNameBinding.ImportedStatic;
import anyparse.query.ValueNameBinding.ImportedStatics;
import anyparse.query.ValueNameBinding.ModuleValues;
import haxe.Exception;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The ONE reading of a bare value name at module level (`ValueNameBinding`, the index's `values` layer): a module-level
 * field first, then the statics the imports bind, owners read off the index by declaration. Every precedence a fixture
 * asserts was compiled first on Haxe 4.3.7 — the probe programs are recorded with the `docs/decisions.md` entry.
 */
@:nullSafety(Strict)
class ValueNameBindingTest extends Test {

	@:pin('control')
	@:killer('M-TS-MODULE-NAME') @:killer('M-TS-MODULE-NAME-NESTED') @:killer('M-TS-MODULE-NAME-ALIAS')
	public function testAModuleFieldComesBeforeAnyImport(): Void {
		final index: SymbolIndex = indexOf([
			'a/A.hx' => 'package a;\n\nclass A {\n\tpublic static var x:Int = 0;\n\tpublic static function f():Void {}\n'
			+ '\tpublic static function g():Void {}\n}\n',
			'Main.hx' => 'import a.A.*;\nimport a.A.g as held;\n\nvar x:Int = 1;\nfinal y = 2;\n#if foo\nfunction f() {}\n#end\n\nclass Main {}\n'
		]);
		Assert.equals('x,y,f', [for (f in fileOf(index, 'Main.hx').moduleFields) f.name].join(
			','
		), 'module-level values only: no type, import or alias');
		Assert.equals('', statics(index, 'Main.hx', 'x'), 'a module-level var hides the imported static');
		Assert.equals('A.f[a/A.hx]', statics(index, 'Main.hx', 'f'), 'one inside a conditional region hides it in its builds only');
		Assert.equals('A.g[a/A.hx]', statics(index, 'Main.hx', 'g'), 'a name only the import binds is the imported static');
		Assert.equals('A.g[a/A.hx]', statics(index, 'Main.hx', 'held'), 'an alias names no module-level value');
	}

	/**
	 * A module-level value inside `#if` is what a bare name means in the builds compiling it only (`moduleValuesAt`, Haxe 4.3.7
	 * `hx/p1`): a use every such build compiles binds it alone; a use of a branch it is an alternative of never does; any
	 * other use may bind it or, in the builds without it, what the imports bind.
	 */
	@:pin('control')
	@:killer('M-VALUES-MODULE-WITHIN') @:killer('M-VALUES-MODULE-ALTERNATIVE') @:killer('M-VALUES-IMPORTS-WITHIN')
	@:killer('M-VALUES-IMPORTS-POSITION')
	public function testAModuleValueUnderIfBindsInTheBuildsCompilingIt(): Void {
		final source: String = 'import a.A.*;\n\n#if foo\nfinal x:Int = 1;\n#else\nvar x:String = "";\n#end\nfinal y:Int = 2;\n\n'
			+ '#if foo\nclass InFoo {}\n#else\nclass InElse {}\n#end\n#if bar\nclass InBar {}\n#end\nclass Out {}\n'
			+ '#if foo\nfinal z:Int = 1;\nclass ZFoo {}\n#else\nclass ZElse {}\n#end\n';
		final index: SymbolIndex = indexOf([
			'a/A.hx' => 'package a;\n\nclass A {\n\tpublic static var x:Int = 0;\n\tpublic static var y:Int = 0;\n\tpublic static var z:Int = 0;\n}\n',
			'Main.hx' => source
		]);
		final at: (String, String) -> String = valuesAt.bind(index, source);
		Assert.equals('x@4|-', at('InFoo', 'x'), 'the branch the use sits in');
		Assert.equals('x@6|-', at('InElse', 'x'), 'a sibling region\'s #else is the same builds');
		Assert.equals('x@4,x@6|A.x[a/A.hx]', at('InBar', 'x'), 'another region decides nothing: each branch, and the import');
		Assert.equals('x@4,x@6|A.x[a/A.hx]', at('Out', 'x'), 'outside every region');
		Assert.equals('y@8|-', at('InBar', 'y'), 'a declaration no #if guards binds everywhere');
		Assert.equals('none', at('Out', 'w'), 'a name the module declares no value of');
		Assert.equals('', statics(index, 'Main.hx', 'y'), 'and hides the import with no position too');
		Assert.equals('A.x[a/A.hx]', statics(index, 'Main.hx', 'x'), 'a guarded one does not');
		Assert.equals('|A.z[a/A.hx]', at('ZElse', 'z'), 'a use in a branch the value is an alternative of never binds it');
		Assert.equals(
			'', statics(index, 'Main.hx', 'x', source.indexOf('class InFoo')),
			'at a use every build of which declares it, it hides the import'
		);
	}

	/**
	 * A use is an alternative of a module-level declaration in ANOTHER region when the two chains spell the same condition where
	 * the earlier branch is taken (`CondBranchPath.comparable`, Haxe 4.3.7 `hx/p2`): `#if foo` declares, and the use sits in the
	 * `#else` — or an `#elseif` — of a region opening with `#if foo`; no build compiles both, so the imports alone supply the name.
	 * A chain whose conditions differ there, or one a condition spelling `|` cannot be split back into, still may bind it.
	 */
	@:pin('control')
	@:killer('M-COND-ALTERNATIVE-REGIONS') @:killer('M-COND-ALTERNATIVE-SPLIT')
	public function testAnotherRegionOfTheSameConditionIsAnAlternative(): Void {
		final source: String = 'import a.A.*;\n\n#if foo\nfinal w:Int = 1;\n#end\n#if foo\nclass WFoo {}\n#else\nclass WElse {}\n#end\n'
			+ '#if foo\nclass Wf {}\n#elseif bar\nclass WBar {}\n#end\n#if bar\nclass VBar {}\n#elseif foo\nclass VFoo {}\n#end\n'
			+ '#if (p || q)\nfinal u:Int = 1;\n#end\n#if (p || r)\nclass UIn {}\n#else\nclass UOut {}\n#end\n';
		final index: SymbolIndex = indexOf([
			'a/A.hx' => 'package a;\n\nclass A {\n\tpublic static var w:Int = 0;\n\tpublic static var u:Int = 0;\n}\n',
			'Main.hx' => source
		]);
		final at: (String, String) -> String = valuesAt.bind(index, source);
		Assert.equals('w@4|-', at('WFoo', 'w'), 'a sibling region of the same condition is the same builds');
		Assert.equals('|A.w[a/A.hx]', at('WElse', 'w'), 'its #else compiles none of them');
		Assert.equals('|A.w[a/A.hx]', at('WBar', 'w'), 'nor does an #elseif after the same #if');
		Assert.equals('w@4|A.w[a/A.hx]', at('VFoo', 'w'), 'an #elseif after another condition may be compiled with it');
		Assert.equals('u@22|A.u[a/A.hx]', at('UOut', 'u'), 'a condition spelling | is not split back into its chain');
	}

	@:pin('control')
	@:killer('M-VALUES-SUBTYPE-IMPORT') @:killer('M-VALUES-ENUM-CTOR') @:killer('M-GRAPH-IMPORT-UNLISTED')
	public function testAnExplicitImportBindsTheStaticItsPathNames(): Void {
		final index: SymbolIndex = indexOf([
			'p/T.hx' => 'package p;\n\nclass T {\n\tpublic static function f():Void {}\n}\n\nclass Sub {\n\tpublic static function h():Void {}\n}\n',
			'p/Mod.hx' => 'package p;\n\nfunction helper():Void {}\n\nclass Mod {}\n',
			'p/E.hx' => 'package p;\n\nenum E {\n\tOne;\n\tTwo(x:Int);\n}\n',
			'Main.hx' => 'import p.T.f;\nimport p.T.Sub.h;\nimport p.T.f as g;\nimport p.Mod.helper;\nimport p.T.Sub;\nimport p.T as U;\n'
			+ 'import q.Lib.make;\nimport p.E.One;\n\nclass Main {}\n'
		]);
		Assert.equals('T.f[p/T.hx]', statics(index, 'Main.hx', 'f'), 'the static of the module main type');
		Assert.equals('Sub.h[p/T.hx]', statics(index, 'Main.hx', 'h'), 'the static of a sub-type of the module');
		Assert.equals('T.f[p/T.hx]', statics(index, 'Main.hx', 'g'), 'an alias binds the static its path names');
		Assert.equals('Mod.helper[p/Mod.hx]', statics(index, 'Main.hx', 'helper'), 'a module-level field of the module, by its name');
		Assert.equals('', statics(index, 'Main.hx', 'Sub'), 'a path naming a sub-type of the module imports a type');
		Assert.equals('', statics(index, 'Main.hx', 'U'), 'an alias of a type binds no static');
		Assert.equals('Lib.make[]', statics(index, 'Main.hx', 'make'), 'a module outside the index: the static it names, no declaration');
		Assert.equals('', statics(index, 'Main.hx', 'One'), 'a constructor of an indexed enum builds a value');
		Assert.equals('g=T.f', aliases(index, 'Main.hx'), 'only the alias of a static is a field alias');
	}

	@:pin('control')
	@:killer('M-GRAPH-UNLISTED-WILDCARD') @:killer('M-VALUES-OWNER-BY-NAME') @:killer('M-VALUES-EXTERN') @:killer('M-VALUES-BUILT-ABOVE')
	public function testAWildcardBringsTheTypesStaticsOnly(): Void {
		final index: SymbolIndex = indexOf([
			'a/T.hx' => 'package a;\n\nclass T {\n\tpublic static function f():Void {}\n\tpublic function inst():Void {}\n}\n',
			'b/T.hx' => 'package b;\n\nclass T {\n\tpublic static function only():Void {}\n}\n',
			'a/M.hx' => 'package a;\n\nfunction modfn():Void {}\n\nclass M {}\n',
			'a/E.hx' => 'package a;\n\nextern class E {}\n',
			'a/Base.hx' => 'package a;\n\n@:autoBuild(X.b())\nclass Base {}\n',
			'a/Kid.hx' => 'package a;\n\nclass Kid extends Base {}\n',
			'W1.hx' => 'import a.T.*;\n\nclass W1 {}\n',
			'W2.hx' => 'import a.M.*;\n\nclass W2 {}\n',
			'W3.hx' => 'import a.E.*;\n\nclass W3 {}\n',
			'W4.hx' => 'import lib.Unseen.*;\n\nclass W4 {}\n',
			'W5.hx' => 'import a.Kid.*;\n\nclass W5 {}\n',
			'W6.hx' => 'import a.*;\n\nclass W6 {}\n'
		]);
		Assert.equals('T.f[a/T.hx]', statics(index, 'W1.hx', 'f'), 'a static of the type');
		Assert.equals('', statics(index, 'W1.hx', 'inst'), 'an instance member is no static');
		Assert.equals('', statics(index, 'W1.hx', 'only'), 'a namesake in another package lends nothing');
		Assert.equals('', statics(index, 'W2.hx', 'modfn'), 'a module wildcard brings no module-level field (Haxe 4.3.7)');
		Assert.equals('?', statics(index, 'W3.hx', 'x'), 'an extern type: its statics are not all listed');
		Assert.equals('?', statics(index, 'W4.hx', 'x'), 'a type outside the index');
		Assert.equals('?', statics(index, 'W5.hx', 'x'), 'a build macro on a supertype may add statics');
		Assert.equals('', statics(index, 'W6.hx', 'f'), 'a package wildcard brings types, no static');
	}

	@:pin('control')
	@:killer('M-VALUES-ALIAS-UNDECODED')
	public function testAnAliasWhosePathDoesNotDecodeMayBeAnyStatic(): Void {
		final index: SymbolIndex = indexOf(['Main.hx' => 'import a.b as x;\n\nclass Main {}\n']);
		Assert.equals('?', statics(index, 'Main.hx', 'x'), 'a package path names no static the index can tell');
		Assert.equals('x=?', aliases(index, 'Main.hx'), 'listed as an alias of no known static');
	}

	/** A `using` of a module brings the extensions of every type it declares, its sub-types' too (Haxe 4.3.7, `hx/us`). */
	@:pin('control') @:killer('M-USING-MODULE-TYPES')
	public function testAUsingBringsEveryTypeOfItsModule(): Void {
		final index: SymbolIndex = indexOf([
			'p/Mod.hx' => 'package p;\n\nclass Mod {}\n\nclass Sub {}\n\nprivate class Hidden {}\n',
			'Main.hx' => 'using p.Mod;\nusing lib.Ext;\n\nclass Main {}\n',
			'One.hx' => 'using p.Mod.Sub;\n\nclass One {}\n'
		]);
		Assert.equals(
			'Sub,Mod,Ext', index.typing.extensions.usingTypes(fileOf(index, 'Main.hx')).join(','),
			'a module\'s every type, the last declared first, and a module outside'
		);
		Assert.equals('Sub', index.typing.extensions.usingTypes(fileOf(index, 'One.hx')).join(','), 'the one type a path names');
	}

	/**
	 * What an import may bring into unqualified scope as a VALUE (`mayImportValue`, what a bare `case` pattern compares
	 * against), each probed on Haxe 4.3.7 `--interp`: a whole-module import brings its module-level fields and its sub-type
	 * enum's constructors, a sub-type import and a wildcard over it the constructors; an alias of the main type neither, a
	 * static-field import only the field it names, a package wildcard no value.
	 */
	@:pin('control')
	@:killer('M-VALUES-IMPORTED-CTOR') @:killer('M-VALUES-WILDCARD-CTOR') @:killer('M-VALUES-ALIAS-WHOLE-MODULE')
	@:killer('M-VALUES-FIELD-IMPORT-TYPES') @:killer('M-SCOPE-MODULE-IMPORT-BLIND')
	public function testAnImportBringsTheValuesOfTheTypesItPutsInScope(): Void {
		final index: SymbolIndex = indexOf([
			'pk/Mod.hx' => 'package pk;\n\nfinal modval = 1;\n\nenum Sub {\n\tlowctor;\n}\n\nclass Mod {}\n',
			'A1.hx' => 'import pk.Mod;\n\nclass A1 {}\n',
			'A2.hx' => 'import pk.Mod.Sub;\n\nclass A2 {}\n',
			'A3.hx' => 'import pk.Mod.Sub.*;\n\nclass A3 {}\n',
			'A4.hx' => 'import pk.Mod as M;\n\nclass A4 {}\n',
			'A5.hx' => 'import nowhere.Gone.thing;\n\nclass A5 {}\n',
			'A6.hx' => 'import pk.*;\n\nclass A6 {}\n'
		]);
		function may(file: String, name: String): Bool {
			return index.values.mayImportValue(fileOf(index, file), name);
		}
		Assert.isTrue(may('A1.hx', 'lowctor'), 'a whole-module import: its sub-type enum\'s constructor');
		Assert.isTrue(may('A1.hx', 'modval'), 'a whole-module import: its module-level field');
		Assert.isTrue(may('A2.hx', 'lowctor'), 'a sub-type import');
		Assert.isFalse(may('A2.hx', 'modval'), 'a sub-type import brings no module-level field');
		Assert.isTrue(may('A3.hx', 'lowctor'), 'a wildcard over the enum');
		Assert.isFalse(may('A4.hx', 'lowctor'), 'an alias of the main type brings no sub-type\'s constructor');
		Assert.isFalse(may('A4.hx', 'modval'), 'nor a module-level field');
		Assert.isTrue(may('A5.hx', 'thing'), 'a static-field import: the field it names');
		Assert.isFalse(may('A5.hx', 'lowctor'), 'and nothing else, even outside the index');
		Assert.isFalse(may('A6.hx', 'lowctor'), 'a package wildcard brings types');
	}

	@:pin('control')
	@:killer('M-DOOR-USING-TYPES-BLIND')
	public function testBesideATypeAUsingBringsTheValuesOfItsModulesTypes(): Void {
		final index: SymbolIndex = indexOf([
			'pk/Tools.hx' => 'package pk;\n\nenum UMode {\n\tUsg;\n}\n\nclass Tools {}\n',
			'B1.hx' => 'using pk.Tools;\n\nclass B1 {}\n',
			'B2.hx' => 'import pk.Tools;\n\nclass B2 {}\n'
		]);
		Assert.isTrue(index.values.mayImportValueBesideType(fileOf(index, 'B1.hx'), 'Usg'), 'a constructor of a type the using brings');
		Assert.isFalse(index.values.mayImportValue(fileOf(index, 'B1.hx'), 'Usg'), 'which a bare pattern does not compare against');
		Assert.isFalse(index.values.mayImportValueBesideType(fileOf(index, 'B2.hx'), 'Tools'), 'an import of the type is the type');
	}

	/**
	 * The import a bare call may be routed through out of the index's sight (`unlistedImportOf`, the macro gate's question): a
	 * static-field import of a module the index does not hold, a `using` of one; a wildcard over an indexed type it lists is
	 * none. On a value receiver only a `using` is asked.
	 */
	@:pin('control')
	@:killer('M-MACRO-VALUE-UNLISTED') @:killer('M-MACRO-EXTENSIONS-ONLY')
	public function testAnUnlistedImportIsTheOneACallMayBeRoutedThrough(): Void {
		final index: SymbolIndex = indexOf([
			'pk/Mod.hx' => 'package pk;\n\nclass Mod {\n\tpublic static function t():Void {}\n}\n',
			'B1.hx' => 'import m.Lang.t;\n\nclass B1 {}\n',
			'B2.hx' => 'import pk.Mod.*;\n\nclass B2 {}\n',
			'B3.hx' => 'using m.Ext;\nimport m.Lang.t;\n\nclass B3 {}\n'
		]);
		function at(file: String, extensionsOnly: Bool): String {
			return index.values.unlistedImportOf(fileOf(index, file), 't', extensionsOnly) ?? '-';
		}
		Assert.equals('m.Lang.t', at('B1.hx', false), 'a static-field import of a module the index does not hold');
		Assert.equals('-', at('B1.hx', true), 'which routes no call on a value');
		Assert.equals('-', at('B2.hx', false), 'a wildcard over a type the index lists');
		Assert.equals('m.Ext', at('B3.hx', true), 'a `using` of a module the index does not hold');
	}

	private static function indexOf(files: Map<String, String>): SymbolIndex {
		final entries: Array<{ file: String, source: String }> = [for (file => source in files) { file: file, source: source }];
		entries.sort((a, b) -> Reflect.compare(a.file, b.file));
		return CheckFixture.index(entries, new HaxeQueryPlugin());
	}

	private static function fileOf(index: SymbolIndex, file: String): FileInfo {
		final fi: Null<FileInfo> = index.fileInfo(file);
		if (fi == null) throw new Exception('the fixture must index $file');
		return fi;
	}

	/** The statics `name` binds in `file`, as `Owner.member[declaring files]`, then `?` when one may be unlisted. */
	private static function statics(index: SymbolIndex, file: String, name: String, ?at: Int): String {
		final found: ImportedStatics = index.values.importedStatics(fileOf(index, file), name, at);
		final out: Array<String> = [for (s in found.statics) render(s)];
		if (found.unknown) out.push('?');
		return out.join(' ');
	}

	/** The field aliases of `file`, as `alias=Owner.member` (`?` for an undecoded path). */
	private static function aliases(index: SymbolIndex, file: String): String {
		final found: Array<FieldAlias> = index.values.fieldAliases(fileOf(index, file));
		return [
			for (a in found) {
				final target: Null<ImportedStatic> = a.target;
				'${a.alias}=${target == null ? '?' : '${target.owner}.${target.member}'}';
			}
		].join(' ');
	}

	private static function render(s: ImportedStatic): String {
		return '${s.owner}.${s.member}[${[for (d in s.decls) d.file.file].join(',')}]';
	}

	/**
	 * What `moduleValuesAt` answers for the bare `name` read at `class <type>` of `Main.hx` (`source`): each declaration it binds
	 * as `name@line`, then the imported statics of the builds compiling none (`-` when every such build compiles one).
	 */
	private static function valuesAt(index: SymbolIndex, source: String, type: String, name: String): String {
		final values: Null<ModuleValues> = index.values.moduleValuesAt(fileOf(index, 'Main.hx'), name, source.indexOf('class $type'));
		if (values == null) return 'none';
		final imported: Null<ImportedStatics> = values.imported;
		final decls: String = [
			for (d in values.decls) d.name + '@' + source.substr(0, d.span.from).split('\n').length
		].join(',');
		return '$decls|${imported == null ? '-' : [for (s in imported.statics) render(s)].join(' ')}';
	}

}

package unit.check.common.members;

import anyparse.check.Severity;
import anyparse.check.common.members.UnstoredProperty;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.scan.ReflectionScan.ScopeFile;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import sys.io.File;
import unit.cli.CliFixture;

using StringTools;

/**
 * The `unstored-property` check: a property whose plain reads return its field while its own set accessor never
 * stores it. Read anywhere, the finding is a `Warning` with no fix; read nowhere, it is `Info` and the fix makes
 * the read access `never`. Refusals come in two kinds: no finding (something stores the field), and a finding whose
 * fix is declined (the proof the fix needs fails).
 */
class UnstoredPropertyCheckTest extends Test {

	/** A setter that never stores a property something reads: every read sees the initial value. */
	@:pin('control') @:killer('M-PROPSTORE-READS-BLIND')
	public function testANeverStoredPropertyThatIsReadWarns(): Void {
		final src: String = widget('', 'trace(w.label);');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('unstored-property', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(
			'property `label` is never stored: `set_label` does not assign it and nothing else in scope writes its field, so every '
			+ 'read of it sees its initial value',
			vs[0].message
		);
		Assert.equals(src, fixed(src));
	}

	/** Read nowhere — only written, through the setter — the property's read access becomes `never`. */
	@:pin('control') @:killer('M-PROPSTORE-WRITE-TARGETS-OFF')
	public function testAnUnreadPropertyLosesItsReadAccess(): Void {
		final src: String = widget('', '');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isNull(vs[0].declineReason);
		final out: String = fixed(src);
		Assert.isTrue(out.indexOf('public var label(never, set):String;') >= 0, out);
	}

	/** A compound assignment reads the property before it writes it. */
	@:pin('control') @:killer('M-PROPSTORE-COMPOUND-AS-WRITE')
	public function testACompoundAssignmentIsARead(): Void {
		final vs: Array<Violation> = violations(widget('', 'w.label += \'b\';'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0]?.severity);
	}

	/**
	 * A setter that names its property stores it (or at least may): nothing to report. Held twice — the setter's own
	 * mention and the scope-wide accessor-body scan each refuse it — so no single arm kills it.
	 */
	@:pin('guard')
	public function testASetterThatStoresItsPropertyIsSilent(): Void {
		Assert.equals(0, violations(widget('', 'trace(w.label);', 'return label = value;')).length);
	}

	/** A declaration initializer stores the field. */
	@:pin('control') @:killer('M-UNSTORED-INIT-BLIND')
	public function testAnInitializerStoresTheField(): Void {
		Assert.equals(0, violations(widget('', 'trace(w.label);', 'return value;', ' = \'x\'')).length);
	}

	/** A reflective string naming the property may write its field by name. */
	@:pin('control') @:killer('M-UNSTORED-REFLECTION-BLIND')
	public function testAReflectiveNameMayStoreTheField(): Void {
		Assert.equals(0, violations(widget('', 'Reflect.setField(w, \'label\', \'b\');')).length);
	}

	/** An override of the setter in a subtype may store the field: accessor bodies are read wherever they are. */
	@:pin('control') @:killer('M-ISVAR-ACCESSOR-BODY-BLIND')
	public function testAnOverridingSetterMayStoreTheField(): Void {
		final sub: String =
			'\n\nclass S extends W {\n\toverride function set_label(value:String):String {\n\t\treturn label = value;\n\t}\n}';
		Assert.equals(0, violations(widget('', 'trace(w.label);') + sub).length);
	}

	/** Metadata on the property may reach its field: the finding stays, the fix is declined. */
	@:pin('control') @:killer('M-UNSTORED-META-ADMITTED')
	public function testMetadataDeclinesTheFix(): Void {
		assertDeclinedAs(widget('@:keep ', ''), 'the property carries metadata');
	}

	/** A kept owner may be reached by name: the fix is declined. */
	@:pin('control') @:killer('M-UNSTORED-KEEP-ADMITTED')
	public function testAKeptOwnerDeclinesTheFix(): Void {
		assertDeclinedAs('@:keep ' + widget('', ''), 'the owner is kept');
	}

	/** Runtime type information describes the property's access: the fix is declined. */
	@:pin('control') @:killer('M-UNSTORED-RTTI-ADMITTED')
	public function testAnRttiOwnerDeclinesTheFix(): Void {
		assertDeclinedAs('@:rtti ' + widget('', ''), 'runtime type information');
	}

	/** A supertype outside the scope may declare the property, whose access the subtype's must match. */
	@:pin('control') @:killer('M-UNSTORED-CHAIN-ADMITTED')
	public function testAnUnresolvedSupertypeDeclinesTheFix(): Void {
		assertDeclinedAs(widget('', '').replace('class W {', 'class W extends Missing {'), 'a supertype outside the scope');
	}

	/** The fixed program compiles and prints what the original printed. */
	public function testTheFixedProgramRunsTheSame(): Void {
		final main: String = 'class Main {\n\tpublic var label(default, set):String;\n\n\tpublic function new() {}\n\n'
			+ '\tfunction set_label(value:String):String {\n\t\tSys.println(\'set \' + value);\n\t\treturn value;\n\t}\n\n'
			+ '\tstatic function main():Void {\n\t\tfinal m:Main = new Main();\n\t\tm.label = \'a\';\n\t}\n}\n';
		final out: String = fixed(main);
		Assert.isTrue(out.indexOf('label(never, set)') >= 0, out);
		assertRunsTheSame(main, out, 'set a');
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unstored-property'));
	}

	/** An extern's field is stored on the native side, which no text here shows: no finding. */
	@:pin('control') @:killer('M-UNSTORED-EXTERN-ADMITTED')
	public function testAnExternOwnerIsSilent(): Void {
		final ext: String = 'extern class E {\n\tpublic var label(default, set):String;\n\n'
			+ '\tinline function set_label(value:String):String {\n\t\treturn value;\n\t}\n}';
		Assert.equals(0, violations(ext).length);
		Assert.equals(0, violations('$ext\n\nclass U {\n\tstatic function run(e:E):Void {\n\t\ttrace(e.label);\n\t}\n}').length);
	}

	/** A setter declared without a body shows nothing of what it stores: no finding. */
	@:pin('control') @:killer('M-PROPSTORE-BODILESS-ADMITTED')
	public function testABodilessSetterIsSilent(): Void {
		Assert.equals(
			0,
			violations(
				'abstract class A {\n\tpublic var label(default, set):String;\n\n\tabstract function set_label(value:String):String;\n}'
			).length
		);
	}

	/**
	 * A write through `Dynamic` lands in the field past the setter, so the field IS stored: no finding — and the program
	 * keeps running as it did, where a `never` read access made that write fail at run time.
	 */
	@:pin('control') @:killer('M-UNSTORED-DYNAMIC-WRITE-BLIND')
	public function testADynamicWriteMayStoreTheField(): Void {
		final main: String = 'class Main {\n\tpublic var label(default, set):String;\n\n\tpublic function new() {}\n\n'
			+ '\tfunction set_label(value:String):String {\n\t\tSys.println(\'set \' + value);\n\t\treturn value;\n\t}\n\n'
			+ '\tstatic function main():Void {\n\t\tfinal m:Main = new Main();\n\t\tm.label = \'a\';\n\t\tfinal d:Dynamic = m;\n'
			+ '\t\td.label = \'b\';\n\t\tSys.println(\'done\');\n\t}\n}\n';
		Assert.equals(0, violations(main).length);
		assertRunsTheSame(main, fixed(main), 'set a\ndone');
	}

	/** Code rendering an object sees whether it has the field: the fix is declined. */
	@:pin('control') @:killer('M-UNSTORED-ENUMERATION-ADMITTED')
	public function testAnEnumeratingScopeDeclinesTheFix(): Void {
		assertDeclinedAs(widget('', 'trace(haxe.Json.stringify(w));'), 'list or render an object');
	}

	/** A printing call counts wherever it sits in the scope. */
	@:pin('control') @:killer('M-REFLECT-ENUM-BLIND')
	public function testAPrintingCallDeclinesTheFix(): Void {
		assertDeclinedAs(widget('', 'trace(Std.string(w));'), 'list or render an object');
	}

	/** A member read by a name the call computes may be any member, this field included: the fix is declined. */
	@:pin('control') @:killer('M-REFLECT-ENUM-COMPUTED-BLIND')
	public function testAComputedMemberNameDeclinesTheFix(): Void {
		assertDeclinedAs(widget('', 'final k:String = \'other\';\n\t\ttrace(Reflect.field(w, k));'), 'list or render an object');
	}

	/** A member read by a literal naming another member enumerates nothing: the fix stands. */
	@:pin('control') @:killer('M-REFLECT-ENUM-LITERAL-ENUMERATES')
	public function testALiteralMemberNameKeepsTheFix(): Void {
		final out: String = fixed(widget('', 'trace(Reflect.field(w, \'other\'));'));
		Assert.isTrue(out.indexOf('label(never, set)') >= 0, out);
	}

	/**
	 * The std spells every enumerating call itself and enumerates only when the project calls one: an std file of the
	 * scope declines nothing, while the same file DECLARED by the project — a root or a library it chose — does.
	 */
	@:pin('control') @:killer('M-REFLECT-ENUM-STD-INCLUDED')
	public function testTheStdDoesNotDeclineTheFix(): Void {
		final src: String = widget('', '');
		final std: ScopeFile = {
			file: 'std/haxe/Dump.hx',
			source: 'package haxe;\n\nclass Dump {\n\tpublic static function all(o:Dynamic):Array<String> {\n'
				+ '\t\treturn Reflect.fields(o);\n\t}\n}'
		};
		final out: String = fixedWith(scoped(src, [std], []), src);
		Assert.isTrue(out.indexOf('label(never, set)') >= 0, out);
		final vs: Array<Violation> = CheckFixture.violations(new UnstoredProperty(), src, scoped(src, [std], [std]));
		Assert.equals(1, vs.length);
		final reason: String = vs[0]?.declineReason ?? '';
		Assert.isTrue(reason.indexOf('list or render an object') >= 0, reason);
	}

	/** The printer `Json.stringify` delegates to renders an object's fields when called directly too. */
	@:pin('control') @:killer('M-HXSHAPE-JSONPRINTER-UNLISTED')
	public function testTheJsonPrinterDeclinesTheFix(): Void {
		assertDeclinedAs(widget('', 'trace(haxe.format.JsonPrinter.print(w));'), 'list or render an object');
	}

	/** A shallow copy carries over exactly the fields an object has. */
	@:pin('control') @:killer('M-HXSHAPE-COPY-UNLISTED')
	public function testAReflectiveCopyDeclinesTheFix(): Void {
		assertDeclinedAs(widget('', 'trace(Reflect.copy(w));'), 'list or render an object');
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new UnstoredProperty(), src);
	}

	/** `src` after the check's fix of its own findings. */
	private function fixed(src: String): String {
		return fixedWith(new HaxeQueryPlugin(), src);
	}

	/** `src` holds one `Info` finding whose fix is declined for a reason containing `why`. */
	private function assertDeclinedAs(src: String, why: String): Void {
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		final reason: String = vs[0].declineReason ?? '';
		Assert.isTrue(reason.indexOf(why) >= 0, reason);
		Assert.equals(src, fixed(src));
	}

	/**
	 * `main` and `out` (`main` after the fix) both run under `--interp` and print the same — `expected`, trimmed — when
	 * a Haxe toolchain is on the path; skipped otherwise.
	 */
	private function assertRunsTheSame(main: String, out: String, expected: String): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('unstoredproperty', [{ name: 'Main.hx', source: main }]);
		final before: HaxeRun = HaxeSpawn.run(['-cp', '.', '-main', 'Main', '--interp'], dir, 1 << 20);
		if (before.status != 0) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped: ${before.err}${before.failure}');
			return;
		}
		File.saveContent('$dir/Main.hx', out);
		final after: HaxeRun = HaxeSpawn.run(['-cp', '.', '-main', 'Main', '--interp'], dir, 1 << 20);
		CliFixture.removeDir(dir);
		Assert.equals(expected, before.out.trim(), before.err);
		Assert.equals(0, after.status, after.err);
		Assert.equals(before.out, after.out, after.err);
		#else
		Assert.pass('no process spawning on this target');
		#end
	}

	/** `src` after the check's fix of its own findings, through `plugin`. */
	private function fixedWith(plugin: GrammarPlugin, src: String): String {
		final check: UnstoredProperty = new UnstoredProperty();
		final vs: Array<Violation> = CheckFixture.violations(check, src, plugin);
		final edits: Array<{ span: Span, text: String }> = CheckFixture.fixOf(check, src, vs, plugin);
		return CanonicalEdit.applyEdits(src, edits);
	}

	/**
	 * A class `W` with a `(default, set)` property `label` (after the metadata `meta`, with the initializer `init`)
	 * whose setter's body ends in `ret`, and a class `U` writing it and then running `use`.
	 */
	private static function widget(meta: String, use: String, ret: String = 'return value;', init: String = ''): String {
		return 'class W {\n\t${meta}public var label(default, set):String$init;\n\n\tpublic function new() {}\n\n'
			+ '\tfunction set_label(value:String):String {\n\t\ttrace(value);\n\t\t$ret\n\t}\n}\n\n'
			+ 'class U {\n\tstatic function run(w:W):Void {\n\t\tw.label = \'a\';\n\t\t$use\n\t}\n}';
	}

	/** A host for the report `src` (as `C.hx`) whose resolution scope holds `library`, of which the project declared `declared`. */
	private static function scoped(src: String, library: Array<ScopeFile>, declared: Array<ScopeFile>): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: declared.length > 0,
			sources: () -> {
				report: [{ file: 'C.hx', source: src }],
				projectRoots: [],
				library: new LibrarySources(library),
				declaredLibrary: new LibrarySources(declared)
			}
		});
		return plugin;
	}

}

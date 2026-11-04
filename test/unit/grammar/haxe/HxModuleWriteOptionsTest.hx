package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * The Haxe options record as the writer and the loader use it: a clone holds every knob of its source, and neither
 * a write nor a config load touches the record it started from.
 */
@:access(anyparse.grammar.haxe.HaxeModuleTriviaWriter)
class HxModuleWriteOptionsTest extends Test {

	/** A distinct value per field: a field the clone skipped, or took from the defaults, reads differently. */
	@:pin('control')
	@:killer('M-OPTIONS-CLONE-TAKES-DEFAULTS')
	public function testACloneCarriesEveryFieldOfItsSource(): Void {
		final source: HxModuleWriteOptions = new HxModuleWriteOptions();
		final names: Array<String> = Reflect.fields(source);
		for (name in names) Reflect.setField(source, name, 'value of $name');
		final clone: HxModuleWriteOptions = new HxModuleWriteOptions(source);
		Assert.equals(names.length, Reflect.fields(clone).length);
		for (name in names) Assert.equals('value of $name', Reflect.field(clone, name));
	}

	/** Every record assigns its fields in one order, so a default and a clone are one object shape at a read site. */
	public function testADefaultAndACloneListTheirFieldsInOneOrder(): Void {
		final defaults: HxModuleWriteOptions = new HxModuleWriteOptions();
		Assert.same(Reflect.fields(defaults), Reflect.fields(new HxModuleWriteOptions(defaults)));
	}

	/** The loader re-baselines knobs on its result; run on the shared default it would reformat every later config-less write. */
	@:pin('control')
	@:killer('M-LOADER-WRITES-THE-DEFAULT')
	public function testALoadedConfigLeavesTheDefaultRecordAlone(): Void {
		final loaded: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, loaded.caseBody);
		Assert.equals(BodyPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.caseBody);
	}

	/** A generated shim sets its flag on a clone: written on the caller's record, the flag would leak to the next sibling and file. */
	@:pin('control')
	@:killer('M-COPYOPT-RETURNS-ITS-SOURCE')
	public function testAWriteLeavesTheCallersRecordAlone(): Void {
		final options: HxModuleWriteOptions = new HxModuleWriteOptions();
		final before: HxModuleWriteOptions = new HxModuleWriteOptions(options);
		final source: String = 'class C {\n\tfunction f() {\n\t\tvar g = () -> (a ? { x: 1 } : [for (i in 0...3) i]);\n\t}\n}\n';
		HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), options);
		for (name in Reflect.fields(options)) Assert.equals(Reflect.field(before, name), Reflect.field(options, name), name);
	}

	/**
	 * The generated clone is the class, not a struct of its fields: a struct
	 * copy reads the same and changes the object shape at every read site.
	 */
	@:pin('control')
	@:killer('M-COPYOPT-CLASS-AS-STRUCT')
	public function testTheGeneratedCloneIsAnInstanceOfTheClass(): Void {
		Assert.isTrue(Std.isOfType(HaxeModuleTriviaWriter._copyOpt(new HxModuleWriteOptions()), HxModuleWriteOptions));
	}

}

package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HxModule;

/**
 * ω-paired-converters (Phase A1) smoke test.
 *
 * Forces type-checking of the synth-generated
 * `anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_<T>`
 * helpers by referencing one at runtime. Without an explicit
 * consumer the Haxe compiler's DCE strips the Converters class
 * before its bodies are typed, so build errors in generated code
 * would slip through.
 *
 * The synth module path is referenced FULLY QUALIFIED inline
 * (not via `import`) per the macro-defined-module gotcha — sub-
 * module imports fail because module registration runs after the
 * importing file's parse/import phase.
 */
class PairedConvertersSmokeTest extends utest.Test {

	public function testHxModulePairedToRawHasNoDecls():Void {
		final paired:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('');
		final raw:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired);
		Assert.equals(0, raw.decls.length);
	}

	public function testHxModulePairedToRawSingleClass():Void {
		final paired:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Foo {}');
		final raw:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired);
		Assert.equals(1, raw.decls.length);
	}

	public function testHxModulePairedToRawTwoClasses():Void {
		final paired:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class A {} class B {}');
		final raw:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired);
		Assert.equals(2, raw.decls.length);
	}

	public function testHxModulePairedToRawPreservesClassName():Void {
		final paired:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Foo {}');
		final raw:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired);
		final classDecl:anyparse.grammar.haxe.HxClassDecl = switch raw.decls[0].decl {
			case ClassDecl(d): d;
			case _: Assert.fail('expected ClassDecl'); throw 'unreachable';
		};
		Assert.equals('Foo', (classDecl.name : String));
	}

	public function testHxModulePairedToRawPreservesMembers():Void {
		final paired:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Foo { var x:Int; function bar():Void {} }');
		final raw:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired);
		final classDecl:anyparse.grammar.haxe.HxClassDecl = switch raw.decls[0].decl {
			case ClassDecl(d): d;
			case _: Assert.fail('expected ClassDecl'); throw 'unreachable';
		};
		Assert.equals(2, classDecl.members.length);
	}

	public function testRawToPairedRoundTripDeclCount():Void {
		final paired1:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class A {} class B {}');
		final raw1:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired1);
		final paired2:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = anyparse.grammar.haxe.trivia.Pairs.Converters.rawToPaired_HxModule(raw1);
		final raw2:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired2);
		Assert.equals(raw1.decls.length, raw2.decls.length);
	}

	public function testRawToPairedRoundTripClassName():Void {
		final paired1:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Foo {}');
		final raw1:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired1);
		final paired2:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = anyparse.grammar.haxe.trivia.Pairs.Converters.rawToPaired_HxModule(raw1);
		final raw2:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired2);
		final cd:anyparse.grammar.haxe.HxClassDecl = switch raw2.decls[0].decl {
			case ClassDecl(d): d;
			case _: Assert.fail('expected ClassDecl'); throw 'unreachable';
		};
		Assert.equals('Foo', (cd.name : String));
	}

	public function testRawToPairedRoundTripMembers():Void {
		final paired1:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Foo { var x:Int; function bar():Void {} }');
		final raw1:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired1);
		final paired2:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = anyparse.grammar.haxe.trivia.Pairs.Converters.rawToPaired_HxModule(raw1);
		final raw2:HxModule = anyparse.grammar.haxe.trivia.Pairs.Converters.pairedToRaw_HxModule(paired2);
		final cd:anyparse.grammar.haxe.HxClassDecl = switch raw2.decls[0].decl {
			case ClassDecl(d): d;
			case _: Assert.fail('expected ClassDecl'); throw 'unreachable';
		};
		Assert.equals(2, cd.members.length);
	}
}

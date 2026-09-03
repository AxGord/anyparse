package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import utest.Assert;

/**
 * Metadata dangling off an ALTERNATIVE branch of a module-level `#if` region.
 *
 * `#if macro <imports> #else @:autoBuild(...) #end interface X {}` is valid Haxe — checked with
 * the compiler, not assumed — and this grammar rejected it outright. The `#if` branch's imports
 * committed the region to `HxConditionalDecl`, whose `trailingMeta` slot existed only on the
 * FIRST branch; the alternative branch had nowhere to put the metadata, so the whole file
 * skip-parsed.
 *
 * It is also exactly the shape `cond-region-merge` proposes when it sees `#if macro … #end`
 * followed by `#if !macro … #end`, so that check carried a finding it could never apply: the
 * `--fix` result did not re-parse and was rolled back on every run.
 */
class HxCondDeclElseTrailingMetaTest extends HxTestHelpers {

	public inline function testElseBranchTakesDanglingMetadata(): Void {
		assertParses('#if macro\nimport a.B;\n#else\n@:keep\n#end\ninterface I {}');
	}

	public inline function testElseBranchTakesDeclarationsThenMetadata(): Void {
		assertParses('#if macro\nimport a.B;\n#else\nimport c.D;\n@:keep\n#end\ninterface I {}');
	}

	public inline function testElseifBranchTakesDanglingMetadata(): Void {
		assertParses('#if macro\nimport a.B;\n#elseif js\n@:keep\n#else\n@:autoBuild(p.B.build())\n#end\ninterface I {}');
	}

	public function testTheHomogeneousShapesStillParse(): Void {
		assertParses('#if macro\nimport a.B;\n#else\nimport c.D;\n#end\ninterface I {}');
		assertParses('#if macro\nimport a.B;\n@:keep\n#end\ninterface I {}');
	}

	/** `source` parses to one module, and the writer's output is a fixed point — the canonical-gate contract. */
	private function assertParses(source: String): Void {
		final module: HxModule = HaxeModuleParser.parse(source);
		Assert.isTrue(module.decls.length > 0, source);
		roundTrip(source, source);
	}

}

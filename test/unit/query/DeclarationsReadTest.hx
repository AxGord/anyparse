package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondDirectives;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndexBuilder;
import anyparse.runtime.BodySkip;
import anyparse.runtime.StringInput;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The DECLARATIONS-ONLY read (`BodySkip`, `ParsedRootProvider.parseDeclarationsRoot`, `IndexScope.declarationsOf`): a
 * function body is jumped from its `{` to the matching `}` over the grammar's own non-code regions and directives, a
 * run that cannot be proven balanced is read element by element, and the declarations read off such a tree are the
 * ones a full parse gives.
 */
@:nullSafety(Strict)
class DeclarationsReadTest extends Test {

	/** The directory whose every source the agreement fixture reads both ways. */
	private static inline final AGREEMENT_DIR: String = 'src/anyparse/query';

	@:pin('control')
	@:killer('M-SKIM-GAPS-COUNTED')
	public function testABodyIsJumpedToItsMatchingCloseOverEveryNonCodeRegion(): Void {
		final source: String = "{ a { b } c = '}'; d = \"{\"; /* } */ // }\n e = ~/\\}/; f = '${ { x: 1 } }'; }!";
		Assert.equals(source.lastIndexOf('}'), closeOf(source), 'braces in strings, comments, a regex and an interpolation do not count');
	}

	@:pin('control')
	@:killer('M-SKIM-NEVER')
	public function testABalancedDirectiveRegionIsJumpedOver(): Void {
		final source: String = '{ #if a { x } #elseif b y #else { z } #end }!';
		Assert.equals(source.lastIndexOf('}'), closeOf(source), 'every branch returns to the depth its region opened at');
	}

	@:pin('control')
	@:killer('M-SKIM-BRANCH-DEPTH')
	public function testABranchThatDoesNotReturnToItsDepthIsNotSkipped(): Void {
		final source: String = '{ #if a if (x) { #else if (y) { #end } } }!';
		Assert.equals(openOf(source), closeOf(source), 'the branches open a brace each and close one together');
	}

	@:pin('control')
	@:killer('M-SKIM-REGION-LEFT-OPEN')
	public function testARegionStillOpenAtTheCloseIsNotSkipped(): Void {
		final source: String = '{ #if a } function g() { #end }!';
		Assert.equals(openOf(source), closeOf(source), 'the body would end inside a region it opened');
	}

	@:pin('control')
	@:killer('M-SKIM-OUTER-REGION')
	public function testADirectiveOfARegionOpenedOutsideIsNotSkipped(): Void {
		final source: String = '#if a\n{ x #else y #end }!';
		Assert.equals(openOf(source), closeOf(source), 'the `#else` and `#end` belong to a region the body did not open');
	}

	@:pin('guard')
	public function testAnUnclosedBodyIsNotSkipped(): Void {
		final source: String = '{ a { b }';
		Assert.equals(openOf(source), closeOf(source), 'the input ends before the close');
	}

	@:pin('control')
	@:killer('M-SKIM-NEVER')
	public function testABodyTheGrammarCannotReadDoesNotHideTheDeclarations(): Void {
		final source: String = 'package p;\n\nclass A {\n\tfunction f() {\n\t\treturn 1 +;\n\t}\n}\n\nclass B {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isNull(plugin.parseRoot(source), 'the full parse reads the body and fails');
		final info: Null<FileInfo> = IndexScope.declarationsOf('p/A.hx', source, plugin);
		Assert.equals('A,B', info == null ? 'null' : [for (t in info.types) t.name].join(','), 'the declarations read never reads it');
	}

	@:pin('guard')
	public function testTheDeclarationsReadAgreesWithTheFullReadOnEverySource(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final sources: Array<{ file: String, source: String }> = [
			{
				file: 'p/Cond.hx',
				source: 'package p;\n\n#if a\nimport x.Y;\n#end\n\nclass Cond {\n\tvar v = function() { return { a: 1 }; };\n\n'
					+ '\tfunction f(): Int {\n\t\t#if a\n\t\tif (b) { g(); }\n\t\t#else\n\t\th();\n\t\t#end\n\t\treturn \'}\'.length;\n\t}\n'
					+ '\n\t#if b\n\tfunction k() {}\n\t#end\n}\n\nprivate typedef T = { x: Int };\n'
			}
		];
		for (name in FileSystem.readDirectory(AGREEMENT_DIR)) if (name.endsWith('.hx'))
			sources.push({ file: '$AGREEMENT_DIR/$name', source: File.getContent('$AGREEMENT_DIR/$name') });
		var compared: Int = 0;
		for (entry in sources) {
			final full: Null<FileInfo> = IndexScope.over([entry], plugin).fileInfo(entry.file);
			if (full == null) continue;
			final read: Null<FileInfo> = SymbolIndexBuilder.declarationsFromRoot(
				entry.file, entry.source, plugin.parseDeclarationsRoot(entry.source), plugin, plugin
			);
			Assert.equals(Json.stringify(full), read == null ? 'null' : Json.stringify(read), entry.file);
			compared++;
		}
		Assert.isTrue(compared > 100, 'the directory was read ($compared sources)');
	}

	/** Where `BodySkip` closes the run opened by the first `{` of `source`. */
	private static function closeOf(source: String): Int {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final skip: BodySkip = new BodySkip(
			SourceComments.collectNonCodeRegions(regions), CondDirectives.skipMarks(source, plugin.refShape(), regions)
		);
		return skip.closeAt(new StringInput(source), openOf(source), '{'.code, '}'.code);
	}

	/** The position just inside the first `{` of `source`. */
	private static inline function openOf(source: String): Int {
		return source.indexOf('{') + 1;
	}

}

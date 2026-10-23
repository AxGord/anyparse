package unit.grammar;

import anyparse.grammar.mermaid.MermaidParser;
import anyparse.grammar.mermaid.MermaidSpanParser;
import anyparse.grammar.mermaid.MermaidWriter;
import anyparse.grammar.mermaid.MmdFlowchart;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The Mermaid flowchart corpus (`test/corpus/mermaid`, see its README): every file parses with both
 * parsers, writes back to text that parses to the same AST, and writes idempotently; the `demo`
 * files are canonical, so writing one gives back its own bytes.
 */
@:nullSafety(Strict)
class MermaidRoundTripTest extends Test {

	/** The corpus root, relative to the repository root the suite runs from. */
	private static inline final CORPUS: String = 'test/corpus/mermaid';

	/** The corpus sets, each a directory of `.mmd` files. */
	private static final SETS: Array<String> = ['docs', 'spec', 'demo', 'review'];

	/** Parse, write, re-parse and re-write every corpus file. */
	public function testEveryCorpusFileRoundTrips(): Void {
		#if (sys || nodejs)
		for (set in SETS) {
			final files: Array<String> = corpusFiles(set);
			Assert.isTrue(files.length > 0, '$set holds files');
			for (path in files) try {
				roundTrip(path);
			} catch (exception: Exception) {
				Assert.fail('$path: ${exception.message}');
			}
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A demo diagram is already canonical. */
	public function testTheDemoDiagramsAreCanonical(): Void {
		#if (sys || nodejs)
		for (path in corpusFiles('demo')) {
			final source: String = File.getContent(path);
			Assert.equals(source, MermaidWriter.write(MermaidParser.parse(source)), path);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** One corpus file through both parsers, a write and a second write. */
	private static function roundTrip(path: String): Void {
		final source: String = File.getContent(path);
		final ast: MmdFlowchart = MermaidParser.parse(source);
		MermaidSpanParser.parse(source);
		final written: String = MermaidWriter.write(ast);
		final reparsed: MmdFlowchart = MermaidParser.parse(written);
		Assert.equals(MermaidAst.dump(ast), MermaidAst.dump(reparsed), '$path: same AST after a write');
		Assert.equals(written, MermaidWriter.write(reparsed), '$path: the write is idempotent');
	}
	/** The `.mmd` files of one corpus set, in name order. */
	private static function corpusFiles(set: String): Array<String> {
		final dir: String = '$CORPUS/$set';
		final names: Array<String> = FileSystem.readDirectory(dir).filter(name -> name.endsWith('.mmd'));
		names.sort(Reflect.compare);
		return [for (name in names) '$dir/$name'];
	}
	#end

}

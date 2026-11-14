package unit.core;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocIdentityMap;
import anyparse.core.DocMeasure;
import anyparse.core.LeafTag;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

using StringTools;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * A leaf whose first visible byte is a letter, `_` or `$` says so through its tag, set where the writer builds it, so a
 * reader asking "does this operand start with a name" never re-reads the leaf's bytes. The sweep holds the tag equal to
 * the bytes' answer over every non-comment leaf of the written Docs of a source tree; `APQ_WORDSTART_ROOTS` (comma
 * separated directories) widens it for a one-off probe over other trees.
 */
@:nullSafety(Strict)
class WordStartLeafTest extends Test {

	/** Divergent leaves quoted in a failure message before it elides the rest. */
	private static inline final REPORTED: Int = 8;

	/** The trees swept by default, relative to the runner's cwd. */
	private static final DEFAULT_ROOTS: Array<String> = ['src/anyparse/core', 'src/anyparse/format', 'src/anyparse/grammar'];

	/** A constant keyword, a name and a keyword with an open delimiter are word-start leaves; a bare closer is not. */
	@:pin('control')
	@:killer('M-WORDSTART-TAGOF')
	public function testTagOfNamesAWordStart(): Void {
		Assert.same(LeafTag.Delimiter(WordStart, Plain), DelimiterLeaf.tagOf('else'));
		Assert.same(LeafTag.Delimiter(WordStart, Opens), DelimiterLeaf.tagOf('foo('));
		Assert.same(LeafTag.Delimiter(WordStart, Plain), DelimiterLeaf.tagOf(' is '));
		Assert.isNull(DelimiterLeaf.tagOf('1'));
		Assert.same(LeafTag.Delimiter(NoOpen, Closes), DelimiterLeaf.tagOf(')'));
	}

	/** A runtime string is classified by its bytes where the leaf is built. */
	@:pin('control')
	@:killer('M-WORDSTART-WORDLEAF')
	public function testWordLeafReadsTheFirstVisibleByte(): Void {
		for (s in ['name', '_x', '$$y', ' and ']) Assert.isTrue(startsWord(DelimiterLeaf.wordLeaf(s)), s);
		for (s in ['1', '"s"', '(', ' + ', '']) Assert.isFalse(startsWord(DelimiterLeaf.wordLeaf(s)), s);
	}

	/** A verbatim region terminal that begins with a name is a word start, whether or not it closes its region. */
	@:pin('control')
	@:killer('M-WORDSTART-REGIONLEAF')
	public function testRegionLeafStartsAWord(): Void {
		Assert.same(Text('cs\n#end', null, Delimiter(WordStart, ClosesRegion)), DelimiterLeaf.regionLeaf('cs\n#end'));
		Assert.same(Text('cs x', null, Delimiter(WordStart, Plain)), DelimiterLeaf.regionLeaf('cs x'));
		Assert.same(Text('1 #end', null, Delimiter(NoOpen, ClosesRegion)), DelimiterLeaf.regionLeaf('1 #end'));
		Assert.same(Text('1', null, null), DelimiterLeaf.regionLeaf('1'));
	}

	/** The word-start tag never reads as a run opener: a name before `(` is no open delimiter by itself. */
	@:pin('control')
	@:killer('M-WORDSTART-NOT-AN-OPENER')
	public function testWordStartOpensNoRun(): Void {
		final name: Doc = Text('foo', null, Delimiter(WordStart, Plain));
		Assert.isNull(DocMeasure.flatPrefixToOpenDelim(name));
		Assert.equals(4, DocMeasure.flatPrefixToOpenDelim(Concat([name, Text('(', null, Delimiter(Paren, Plain))])));
	}

	/** Over written Docs, every non-comment leaf's tag agrees with its bytes. */
	@:pin('control')
	@:killer('M-WORDSTART-RUNTIME-DT')
	public function testWrittenLeavesAgreeWithTheirBytes(): Void {
		#if (sys || nodejs)
		final env: Null<String> = Sys.getEnv('APQ_WORDSTART_ROOTS');
		final roots: Array<String> = env == null || env == '' ? DEFAULT_ROOTS : env.split(',');
		final bad: Map<String, Bool> = [];
		var files: Int = 0;
		for (root in roots) for (path in haxeFiles(root)) {
			final doc: Null<Doc> = try docOf(File.getContent(path)) catch (_: haxe.Exception) null;
			if (doc == null) continue;
			files++;
			collect(doc, new DocIdentityMap(), bad);
		}
		Assert.isTrue(files > 100, 'the sweep must cover a tree, saw $files files');
		final shown: Array<String> = [for (k in bad.keys()) k];
		shown.sort(anyparse.util.Compare.compareString);
		Assert.equals(
			0, shown.length, 'leaves whose tag disagrees with their bytes (${shown.length}):\n  ${shown.slice(0, REPORTED).join('\n  ')}'
		);
		#else
		Assert.fail('this sweep needs a filesystem — it must not compile to a silent pass');
		#end
	}

	private static function startsWord(d: Doc): Bool {
		return switch d {
			case Text(_, _, tag): DelimiterLeaf.startsWordTag(tag);
			case _: false;
		};
	}

	private static function docOf(source: String): Doc {
		return HaxeModuleTriviaWriter.writeDoc(HaxeModuleTriviaParser.parse(source), HaxeFormat.instance.defaultWriteOptions);
	}

	/** Visits each shared node of the DAG once and records every non-comment leaf whose tag and bytes disagree. */
	private static function collect(d: Doc, seen: DocIdentityMap<Bool>, bad: Map<String, Bool>): Void {
		if (seen.exists(d)) return;
		seen.set(d, true);
		switch d {
			case Text(s, _, tag) if (!DelimiterLeaf.isComment(tag) && DelimiterLeaf.startsWordTag(tag) != DelimiterLeaf.startsWord(s)):
				bad['${DelimiterLeaf.startsWordTag(tag) ? 'tagged' : 'untagged'}: ${s.replace('\n', '\\n')}'] = true;
			case _:
		}
		D.mapChildren(d, c -> {
			collect(c, seen, bad);
			return c;
		});
	}

	#if (sys || nodejs)
	private static function haxeFiles(root: String): Array<String> {
		final out: Array<String> = [];
		if (!FileSystem.exists(root)) return out;
		for (name in FileSystem.readDirectory(root)) {
			final path: String = '$root/$name';
			if (FileSystem.isDirectory(path))
				for (p in haxeFiles(path)) out.push(p);
			else if (name.endsWith('.hx'))
				out.push(path);
		}
		return out;
	}
	#end

}

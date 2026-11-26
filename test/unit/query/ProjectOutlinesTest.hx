package unit.query;

import anyparse.core.ContentHash;
import anyparse.core.ParseProjectionEngine;
import anyparse.query.FileSymbols;
import anyparse.query.OwnerIndex;
import anyparse.query.ProjectOutlines;
import anyparse.query.ProjectParseStore;
import anyparse.query.SymbolIndex;
import unit.cli.CliFixture;

using StringTools;

/**
 * The per-file records `apq owner` and `apq symbols` answer from (`ProjectOutlines`): a warm run reads every file's record
 * from the store and answers what a build over the parse answers, a file whose bytes changed is derived again, and the
 * key of a record covers the query code that derives it.
 */
class ProjectOutlinesTest extends Test {

	private static final KEEPER: String = 'package outline.store;\n\n/** The one answer to "where is a kept thing": it keeps one. */\n'
		+ 'class Keeper {\n\n\t/** Keeps a thing. */\n\tpublic function keep(): Void {}\n\n}\n\ntypedef Kept = { var name: String; }\n';
	private static final USER: String = 'package outline.store;\n\nclass User {\n\n\tfinal keeper: Keeper = new Keeper();\n\n}\n';

	/** A warm run folds, from the stored records alone, the owner index and the declarations a build over the parse gives. */
	@:pin('control')
	@:killer('M-OUTLINE-STORE-NEVER-HITS')
	public function testStoredRecordsAnswerTheNextRunAsTheParseDid(): Void {
		#if (sys || nodejs)
		final files: Array<{ file: String, source: String }> = written([KEEPER, USER]);
		final fromParse: String = ownerDump(OwnerIndex.build(SymbolIndex.build(files, new HaxeQueryPlugin()), new HaxeQueryPlugin()));
		final cold: ProjectParseStore = new ProjectParseStore('haxe', Math.POSITIVE_INFINITY);
		Assert.equals(fromParse, ownerDump(OwnerIndex.fromOutlines(ProjectOutlines.owners(files, new HaxeQueryPlugin(), cold))));
		final symbols: String = symbolDump(ProjectOutlines.symbols(files, new HaxeQueryPlugin(), cold));
		Assert.equals(4, cold.written(), 'the cold run stored both kinds of record of both files');
		Assert.equals(
			'1', fromParse.split('\n').filter(line -> line.startsWith('Keeper|'))[0].split('|')[2], 'Keeper is mentioned by the other file'
		);

		final warm: ProjectParseStore = new ProjectParseStore('haxe', Math.POSITIVE_INFINITY);
		Assert.equals(fromParse, ownerDump(OwnerIndex.fromOutlines(ProjectOutlines.owners(files, new HaxeQueryPlugin(), warm))));
		Assert.equals(symbols, symbolDump(ProjectOutlines.symbols(files, new HaxeQueryPlugin(), warm)));
		Assert.equals(0, warm.written(), 'every record of the warm run came from the store');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A file whose bytes changed since its record was stored is derived again; the unchanged file is still served. */
	@:pin('control')
	@:killer('M-DISK-RECORD-IGNORES-SOURCE')
	public function testChangedFileIsDerivedAgain(): Void {
		#if (sys || nodejs)
		final files: Array<{ file: String, source: String }> = written([KEEPER, USER]);
		final stored: ProjectParseStore = new ProjectParseStore('haxe', Math.POSITIVE_INFINITY);
		Assert.equals(2, ProjectOutlines.symbols(files, new HaxeQueryPlugin(), stored).length, 'both files parse');
		final edited: Array<{ file: String, source: String }> = [files[0], { file: files[1].file, source: USER.replace('User', 'Owner') }];
		final store: ProjectParseStore = new ProjectParseStore('haxe', Math.POSITIVE_INFINITY);
		Assert.equals(
			'Keeper,Kept,Owner', names(ProjectOutlines.symbols(edited, new HaxeQueryPlugin(), store)),
			'the edited file answers with what it holds now'
		);
		Assert.equals(1, store.written(), 'only the edited file was derived and stored again');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A file that does not parse contributes nothing, cold or warm, and its stored record spares the warm run its parse. */
	public function testUnparsedFileIsAbsentAndStoredAsSuch(): Void {
		#if (sys || nodejs)
		final files: Array<{ file: String, source: String }> = written([USER, 'package outline.store;\n\nclass Broken {\n']);
		final cold: ProjectParseStore = new ProjectParseStore('haxe', Math.POSITIVE_INFINITY);
		Assert.equals('User', names(ProjectOutlines.symbols(files, new HaxeQueryPlugin(), cold)), 'the broken file holds no declaration');
		final warm: ProjectParseStore = new ProjectParseStore('haxe', Math.POSITIVE_INFINITY);
		Assert.equals('User', names(ProjectOutlines.symbols(files, new HaxeQueryPlugin(), warm)), 'nor does it warm');
		Assert.equals(0, warm.written(), 'the unparsed file was served from its record');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The record key is the digest of the query code that reads a record off a parse, the command layer aside. */
	@:pin('control')
	@:killer('M-RECORD-KEY-SKIPS-QUERY')
	public function testRecordKeyCoversTheDerivingCode(): Void {
		final sources: Array<String> = ParseProjectionEngine.outlineSources();
		for (module in [
			'query/OwnerIndex.hx',
			'query/SymbolIndexBuilder.hx',
			'query/ProjectOutlines.hx',
			'grammar/haxe/query/HaxeQueryPlugin.hx',
			'ds/Set.hx',
			'util/Compare.hx'
		]) Assert.isTrue(sources.contains(module), '$module is in the record key');
		Assert.equals(0, sources.filter(path -> path.startsWith('query/cli/')).length, 'the command layer is not');
		#if (sys || nodejs)
		final root: String = '${CliFixture.repoRoot()}/src/anyparse';
		final hashed: String = sources.map(path -> '$path\n${sys.io.File.getContent('$root/$path')}').join('\n');
		Assert.equals(ContentHash.md5(hashed), ParseProjectionEngine.outlineDigest(), 'the key is the digest of every listed source');
		#end
	}

	private static function written(sources: Array<String>): Array<{ file: String, source: String }> {
		return sources.map(source -> { file: CliFixture.write('projectoutlines', source), source: source });
	}

	private static function ownerDump(index: OwnerIndex): String {
		return index.entries.map(entry ->
			'${OwnerIndex.nameOf(entry)}|${entry.file}:${entry.line}|${entry.mentions}|${entry.summary}|'
			+ '${entry.question}|${entry.nameTerms.join(',')}|${entry.docTerms.join(',')}'
		)
			.join('\n');
	}

	private static function names(records: Array<FileSymbols>): String {
		return [ for (record in records) for (symbol in record.symbols) symbol.name ].join(',');
	}

	private static function symbolDump(records: Array<FileSymbols>): String {
		return [
			for (record in records)
				for (symbol in record.symbols) '${record.file} ${symbol.qualified} ${symbol.kind} ${symbol.line}:${symbol.col}'
		].join('\n');
	}

}

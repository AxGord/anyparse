package anyparse.query;

import anyparse.grammar.json.JsonFormat;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span.Position;
import haxe.Exception;

/**
 * The one answer to "what does each project file contribute to `apq symbols` and `apq owner` without being parsed again":
 * per file its declarations (`FileSymbols`), or its owner entries and code words (`FileOwners`), read from the disk store
 * when the file's bytes and the code that derives the record are those it was stored under, else derived from an index
 * over the files the store missed and written back under the store's budget. A record is file-local, so a miss costs the
 * parse of that file alone; what is cross-file is folded from the records (`OwnerIndex.fromOutlines`).
 */
@:nullSafety(Strict)
final class ProjectOutlines {

	private static final SYMBOLS_KIND: String = 'symbols';
	private static final OWNERS_KIND: String = 'owners';

	/** The declarations of each file of `files` that parses, in `files` order. */
	public static function symbols(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?store: ProjectParseStore
	): Array<FileSymbols> {
		return derive(
			files, plugin, store ?? new ProjectParseStore(plugin.langName()), SYMBOLS_KIND, FileSymbolsParser.parse,
			record -> FileSymbolsWriter.write(record, JsonFormat.instance.compactWriteOptions), symbolsOf,
			file -> { file: file, parsed: false, symbols: [] }
		);
	}

	/** The owner entries and code words of each file of `files` that parses, in `files` order. */
	public static function owners(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?store: ProjectParseStore
	): Array<FileOwners> {
		return derive(
			files, plugin, store ?? new ProjectParseStore(plugin.langName()), OWNERS_KIND, FileOwnersParser.parse,
			record -> FileOwnersWriter.write(record, JsonFormat.instance.compactWriteOptions),
			(info, source) -> ownersOf(info, source, plugin),
			file -> {
				file: file,
				parsed: false,
				entries: [],
				words: []
			}
		);
	}

	/** The declarations `info` holds, at their line and column in `source`. */
	public static function symbolsOf(info: FileInfo, source: String): FileSymbols {
		return { file: info.file, parsed: true, symbols: info.types.map(symbolOf.bind(info, _, source)) };
	}

	/** The owner entries of `info`'s types and members and the distinct words of `source`'s code. */
	public static function ownersOf(info: FileInfo, source: String, plugin: GrammarPlugin): FileOwners {
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		return {
			file: info.file,
			parsed: true,
			entries: OwnerIndex.entriesOf(info, source, regions),
			words: OwnerIndex.codeWords(source, regions)
		};
	}

	private static function symbolOf(info: FileInfo, type: TypeDeclInfo, source: String): OutlineSymbol {
		final position: Position = type.span.lineCol(source);
		return {
			qualified: ModuleScan.pathOfDecl(info, type),
			name: type.name,
			kind: type.kind,
			line: position.line,
			col: position.col
		};
	}

	/**
	 * Each file's record of `kind`: the stored one, else the one `of` derives from an index over the files the store missed
	 * (`unparsed` for a file that index skipped), kept for the next run. Only the records of files that parse come back.
	 */
	private static function derive<T: { var file: String; var parsed: Bool; }>(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, store: ProjectParseStore, kind: String, decode: String -> T,
		encode: T -> String, of: (FileInfo, String) -> T, unparsed: String -> T
	): Array<T> {
		final records: Array<Null<T>> = files.map(entry -> stored(store, entry.file, entry.source, kind, decode));
		final missed: Array<{ file: String, source: String }> = [ for (i => entry in files) if (records[i] == null) entry ];
		if (missed.length > 0) {
			final index: SymbolIndex = IndexScope.over(missed, plugin);
			final derived: Map<String, T> = [ for (info in index.allFiles()) info.file => of(info, index.sourceOf(info.file) ?? '') ];
			for (i => entry in files) if (records[i] == null) {
				final record: T = derived[entry.file] ?? unparsed(entry.file);
				store.keepRecord(entry.file, entry.source, kind, () -> encode(record));
				records[i] = record;
			}
		}
		return [ for (record in records) if (record != null && record.parsed) record ];
	}

	/** The record of `kind` stored for `file`, when it decodes and names that file; null on any doubt. */
	private static function stored<T: { var file: String; var parsed: Bool; }>(
		store: ProjectParseStore, file: String, source: String, kind: String, decode: String -> T
	): Null<T> {
		final text: Null<String> = store.record(file, source, kind);
		if (text == null) return null;
		try {
			final record: T = decode(text);
			return record.file == file ? record : null;
		} catch (_: Exception) {
			return null;
		}
	}

}

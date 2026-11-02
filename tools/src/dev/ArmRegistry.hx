package dev;

import anyparse.query.PackageDocuments;
import anyparse.query.RegistryFiles;
import haxe.Exception;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;

/**
 * The reader of the arm registry (`test/testkit/arms`, one document per package) as records keyed by `name`, each with its
 * source text — what the arms row of the slice gate selects from. The documents merge through `apq merge-file`, by records
 * like every JSON document (`.gitattributes` `merge=anyparse`).
 */
@:nullSafety(Strict)
final class ArmRegistry {

	/** The registry, from the tree's root: one document per package, named after it. */
	public static inline final DIRECTORY: String = 'test/testkit/arms';

	/** The single document the registry was kept in before it was split; a base older than the split still has it. */
	public static inline final LEGACY_FILE: String = 'test/testkit/mutation-arms.json';

	/** The key of the array that holds the records. */
	private static inline final ARRAY_NAME: String = 'arms';

	/** The opening of that array as the documents spell it. */
	private static inline final ARRAY_KEY: String = '"arms": [';

	/** The records of the registry document `text`, in its order; a name declared twice in it is refused. */
	public static function parse(text: String): Array<ArmRecord> {
		final cut: Null<RecordCut> =
			try PackageDocuments.cut(text, ARRAY_NAME) catch (exception: Exception) throw new ArmRegistryError(exception.message);
		if (cut == null) throw new ArmRegistryError('no $ARRAY_KEY array');
		final records: Array<ArmRecord> = [for (body in cut.records) { key: keyOf(body), text: body }];
		final keys: Array<String> = [];
		for (record in records) {
			if (keys.contains(record.key)) throw new ArmRegistryError('arm ${record.key} is declared twice');
			keys.push(record.key);
		}
		return records;
	}

	/** The records of several documents, in their order; a name declared in two of them is refused. */
	public static function parseAll(texts: Array<String>): Array<ArmRecord> {
		final records: Array<ArmRecord> = [];
		for (text in texts) for (record in parse(text)) {
			if (records.exists(r -> r.key == record.key)) throw new ArmRegistryError('arm ${record.key} is declared in two documents');
			records.push(record);
		}
		return records;
	}

	/**
	 * The records of the registry at `path` — a directory of documents, or one document. A directory is refused when a document
	 * holds an arm that `PackageDocuments.misplacement` places elsewhere; a single document is read whatever it is called.
	 */
	public static function read(path: String): Array<ArmRecord> {
		final files: Array<String> = RegistryFiles.of(path);
		if (files.length == 0) throw new ArmRegistryError('no arm registry at $path');
		final texts: Array<String> = [for (file in files) File.getContent(file)];
		if (FileSystem.isDirectory(path)) for (i => text in texts) {
			final document: String = Path.withoutDirectory(files[i]);
			for (record in parse(text)) {
				final type: Null<String> = typeOf(record.text);
				final complaint: Null<String> = type == null ? null : PackageDocuments.misplacement(document, type);
				if (complaint != null) throw new ArmRegistryError('$document: arm ${record.key} $complaint');
			}
		}
		return parseAll(texts);
	}

	/** The registry at `path` as ONE document — what `MutationArm.cuts` and `armNames` read. */
	public static function merged(path: String): String {
		return '{"arms": [' + [for (record in read(path)) record.text].join(',') + ']}';
	}

	/** The `type` of the record `body`, null when it carries none. */
	private static function typeOf(body: String): Null<String> {
		final type: Null<Any> = Reflect.field(Json.parse(body), 'type');
		return type is String ? Std.string(type) : null;
	}

	/** The `name` of the record `body`. */
	private static function keyOf(body: String): String {
		final parsed: Any = try Json.parse(body) catch (exception: Exception) throw new ArmRegistryError(
			'a record does not parse: ${exception.message}'
		);
		final name: Null<Any> = Reflect.field(parsed, 'name');
		if (!(name is String)) throw new ArmRegistryError('a record carries no string `name`');
		return Std.string(name);
	}

}

/** One arm record: its `name` and its source text. */
typedef ArmRecord = {
	var key: String;
	var text: String;
}

/**
 * A version that does not read as the registry: no `arms` array, a record without a string `name`, a name declared twice, or
 * (in a directory) an arm kept in a document `PackageDocuments.misplacement` rejects.
 */
class ArmRegistryError extends Exception {}

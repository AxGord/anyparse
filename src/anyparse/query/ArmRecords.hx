package anyparse.query;

import anyparse.ds.Set;
import anyparse.query.PackageDocumentCarry.RegistryDocument;
import anyparse.query.format.json.ArmRecordText;
import anyparse.query.format.json.MutationArmRegistryJsonParser;
import haxe.Exception;
import haxe.ds.Either;
import haxe.io.Path;

using Lambda;

/**
 * The one answer to "how does a new mutation-arm record get into the registry of arms": a record is checked for the
 * shape a reader needs to find it (`name`, `type`, `method`, `note` and one cut) and appended to the document of its
 * type's package (`PackageDocuments`), which is made when it does not exist. The layout is the JSON layout writer's
 * (`ArmRecordText.append`), in the document's own indent unit. A name already in the registry is refused. What the build
 * checks of a record (a cut that applies, a member that exists) stays the build's: this class reads no source.
 *
 * Not reachable from macro code: the append goes through the JSON query plugin, a generated parser a macro cannot use.
 */
@:nullSafety(Strict)
final class ArmRecords {

	/** The registry key (`<array>.<field>`) the arm registry is declared under in the `move` section. */
	public static final REGISTRY_KEY: String = 'arms.type';

	/**
	 * The documents `records` (each the JSON text of one arm) change in a registry directory `directory` that holds
	 * `existing`: every document returned is to be written, an existing one with its records kept byte for byte and the
	 * new ones last. Left carries the first refusal, naming the record.
	 */
	public static function add(
		directory: String, existing: Array<RegistryDocument>, records: Array<String>
	): Either<String, Array<RegistryDocument>> {
		final taken: Set<String> = new Set<String>();
		for (doc in existing) {
			final names: Array<String> = try
				MutationArmRegistryJsonParser.parse(doc.source).arms.map(arm -> arm.name)
			catch (exception: Exception)
				return Left('${doc.file} does not read as an arm registry: ${exception.message}');
			for (name in names) taken.add(name);
		}
		final sources: Map<String, String> = [for (doc in existing) Path.withoutDirectory(doc.file) => doc.source];
		final touched: Array<String> = [];
		for (json in records) {
			final record: ArmRecord = switch ArmRecordText.read(json) {
				case Left(message): return Left(message);
				case Right(found): found;
			}
			if (taken.has(record.name)) return Left('arm ${record.name} is already in the registry');
			taken.add(record.name);
			final document: String = PackageDocuments.documentFor(record.type);
			final current: Null<String> = sources[document];
			final updated: Either<String, String> = ArmRecordText.append(current ?? empty(document), record.text);
			switch updated {
				case Left(message):
					return Left('$document $message');
				case Right(source):
					sources[document] = source;
			}
			if (!touched.contains(document)) touched.push(document);
		}
		return Right(touched.map(document -> { file: Path.join([directory, document]), source: sources[document] ?? '' }));
	}

	/** A document of the registry that holds only `record`, with the comment every document opens with. */
	private static function empty(document: String): String {
		return '{\n\t"$$comment": [\n\t\t"Mutation arms cutting the types of package ${PackageDocumentCarry.packageName(document)}'
			+ '. Format and rules: docs/testing.md, Declared arms."\n\t],\n\t"${ArmRecordText.ARRAY_KEY}": [\n\t]\n}\n';
	}

}

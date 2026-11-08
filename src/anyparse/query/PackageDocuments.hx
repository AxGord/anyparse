package anyparse.query;

/**
 * The one answer to "which document of a registry kept one document per package holds a record of this type": the one
 * named after the type's package (`_root.json` for a type with none). The directory reader refuses a record in any
 * other document; `PackageDocumentCarry` carries a record to the document of its new package when a module moves.
 *
 * A record is an object of the array at the first segment of a registry key (`arms.type`: the elements of `arms`), its
 * type path the string at the second. Macro code reads this class, so it holds no parser: only names and paths.
 */
@:nullSafety(Strict)
final class PackageDocuments {

	/** The document of the types that have no package. */
	public static inline final ROOT_DOCUMENT: String = '_root.json';

	/** The package of the type path `type`: its leading lower-initial segments, `''` for none. */
	public static function packageOf(type: String): String {
		final segments: Array<String> = [];
		for (segment in type.split('.')) {
			if (segment == '' || segment.charAt(0) != segment.charAt(0).toLowerCase()) break;
			segments.push(segment);
		}
		return segments.join('.');
	}

	/** The name of the document that holds records of the type `type`. */
	public static function documentFor(type: String): String {
		final pkg: String = packageOf(type);
		return pkg == '' ? ROOT_DOCUMENT : pkg + RegistryFiles.EXTENSION;
	}

	/** The complaint about a record of `type` kept in the document named `document`, or null when it belongs there. */
	public static function misplacement(document: String, type: String): Null<String> {
		final expected: String = documentFor(type);
		return document == expected ? null : 'holds a record for $type, which belongs in $expected';
	}

}

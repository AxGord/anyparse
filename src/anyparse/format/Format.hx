package anyparse.format;

/**
 * Base interface for every format plugin. Every format describes its
 * human-facing `name`, a `version` string, and the `encoding` its
 * inputs use. Family-specific interfaces (`TextFormat`, `BinaryFormat`,
 * future `TagTreeFormat`, etc.) extend this with the structural model
 * specific to that family.
 *
 * There is no common denominator beyond these three fields — attempts
 * to unify mapping-based text formats and binary tagged formats under
 * one interface either collapse to something useless or expand to an
 * unmanageable union. See `docs/formats.md` for the reasoning.
 */
interface Format {
	var name(default, null):String;
	var version(default, null):String;
	var encoding(default, null):Encoding;
}

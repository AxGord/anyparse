package anyparse.format.text;

/**
 * How a parser matches input entries to schema fields.
 *
 * - `ByName`     — entries are looked up by their key string (JSON, YAML).
 * - `ByPosition` — entries are matched positionally (CSV records).
 * - `ByTag`      — entries carry a tag the parser uses to dispatch
 *                  (binary tagged unions, protobuf).
 */
enum abstract FieldLookup(Int) {
	final ByName = 0;
	final ByPosition = 1;
	final ByTag = 2;
}

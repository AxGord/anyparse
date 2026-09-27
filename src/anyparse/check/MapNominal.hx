package anyparse.check;

import anyparse.query.SourceText;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

/**
 * The one question two checks ask about a receiver's written type: does it name the
 * grammar's Map ABSTRACT.
 *
 * `prefer-index-access` asks because index access `x[k]` lives on that abstract only — the
 * concrete `haxe.ds.StringMap` / `IntMap` / `ObjectMap` carry `.get` / `.set` but no
 * `@:arrayAccess`, so rewriting one to `m[k]` would not compile. `redundant-map-exists` asks
 * because its `??` rewrite relies on a MISSING key reading as `null`, which is again the
 * abstract's contract and not a general one. Same question, two consequences; the answer
 * lives here rather than in either caller.
 */
@:nullSafety(Strict)
final class MapNominal {

	/**
	 * Whether `nominal` (with the optional verbatim type `source` it was read from) names a
	 * `mapTypes` entry — directly (`Map`), or through a nullable wrapper whose inner nominal
	 * is one (`Null<Map<…>>`).
	 */
	public static function isMap(
		nominal: String, source: Null<String>, mapTypes: Array<String>, nullableWrappers: Array<String>, typeSyntax: TypeSyntaxReader
	): Bool {
		return mapTypes.contains(nominal)
			|| (source != null && nullableWrappers.contains(nominal) && wrapsMap(source, nominal, mapTypes, typeSyntax));
	}

	/** Whether the verbatim type `source` is `wrapper<Nominal…>` whose inner nominal is a `mapTypes` name. */
	private static function wrapsMap(source: String, wrapper: String, mapTypes: Array<String>, typeSyntax: TypeSyntaxReader): Bool {
		return switch typeSyntax(source)?.wrapped([wrapper])?.shape {
			case Nominal(path, _): mapTypes.contains(SourceText.lastSegment(path));
			case _: false;
		};
	}

}

package anyparse.query;

import anyparse.runtime.ParseError;
import haxe.Exception;

/** A source that parsed, with its tree, or the diagnostic naming why it did not. */
enum ParseOutcome {

	Parsed(tree: QueryNode);
	Unparsed(message: String);

}

/**
 * The ONE parse gate. `parse` / `refusal` answer the diagnostic every refactoring op words the same
 * way — `<label> does not parse: <reason>`, where a grammar `ParseError` reads as itself (its position
 * included) and any other exception by its message; `parseOrNull` drops the reason for a caller that
 * only skips an unparsable source.
 *
 * Both ends of an op go through it. The INPUT gate (`$file` as the label) refuses a source the op
 * cannot read; the OUTPUT gate (`rewritten $file`) is the atomicity check every span-splice op runs
 * on its result before handing it back, so a rewrite that breaks the parse is an error, never a
 * written file.
 */
@:nullSafety(Strict)
final class ParseGate {

	/** Parse `source` through `plugin`, or name why it does not parse under `label`. */
	public static function parse(plugin: GrammarPlugin, source: String, label: String): ParseOutcome {
		return try Parsed(plugin.parseFile(source)) catch (exception: ParseError) Unparsed('$label does not parse: $exception')
		catch (exception: Exception) Unparsed('$label does not parse: ${exception.message}');
	}

	/** The diagnostic `parse` would give `source` under `label`, or null when it parses. */
	public static function refusal(plugin: GrammarPlugin, source: String, label: String): Null<String> {
		return switch parse(plugin, source, label) {
			case Parsed(_): null;
			case Unparsed(message): message;
		};
	}

	/**
	 * The tree of `source`, or null on any parse failure — the tolerant parse of a caller that skips an
	 * unparsable source unworded: every check's `run` / `fix` (`Check` forbids throwing on unparseable
	 * input), the call graph, the CLI.
	 */
	public static function parseOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFile(source) catch (exception: Exception) null;
	}

}

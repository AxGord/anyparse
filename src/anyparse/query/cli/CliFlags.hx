package anyparse.query.cli;

/**
 * Which tokens of a command's argv are flags, which are a flag's value and which are positionals: the one answer
 * the dispatcher's unknown-flag refusal and `LanguageChoice`'s "is this token a file" both read. Each command
 * declares its own (`CliCommand.flags`); one whose argv another parser also reads declares the union (`with`).
 * Every command also takes `--lang` / `--lang-default` and `-h` / `--help`.
 */
@:nullSafety(Strict)
final class CliFlags {

	/**
	 * Splits a walker's queries from its scope (`refs A B -- src`): neither a flag nor a value, and flags may follow
	 * it — unless the command's spec says it ends the options (`search -- '--$x'`).
	 */
	public static inline final SEPARATOR: String = '--';

	/** The long-flag prefix: a token spelled with it that no spec declares is an unknown option. */
	private static inline final LONG_PREFIX: String = '--';

	private static final GLOBAL_VALUED: Array<String> = ['--lang', '--lang-default'];
	private static final GLOBAL_SWITCHES: Array<String> = ['-h', '--help'];

	/** Flags that take no value. A flag whose value is optional and never a file or a flag (a position, `-`) is one. */
	private final _switches: Array<String>;

	/** Flags whose next token is their value, whatever it spells. */
	private final _valued: Array<String>;

	/** Does `--` end the options, so every token after it is a positional? */
	private final _separatorEndsOptions: Bool;

	public function new(switches: Array<String>, valued: Array<String>, separatorEndsOptions: Bool = false) {
		_switches = switches;
		_valued = valued;
		_separatorEndsOptions = separatorEndsOptions;
	}

	/** This spec and `other`'s together: the flags of a command whose argv another parser also reads. */
	public function with(other: CliFlags): CliFlags {
		return new CliFlags(
			union(_switches, other._switches), union(_valued, other._valued), _separatorEndsOptions || other._separatorEndsOptions
		);
	}

	/** Does `token` take the next argv token as its value? */
	public function takesValue(token: String): Bool {
		return _valued.contains(token) || GLOBAL_VALUED.contains(token);
	}

	/** Is `token` a flag this spec declares, valued or not? */
	public function declares(token: String): Bool {
		return takesValue(token) || _switches.contains(token) || GLOBAL_SWITCHES.contains(token);
	}

	/** The indices of `args` that are positionals: not a flag, not a flag's value, not the separator. */
	public function positionals(args: Array<String>): Array<Int> {
		final out: Array<Int> = [];
		var i: Int = 0;
		while (i < args.length) {
			final token: String = args[i];
			if (takesValue(token))
				i++;
			else if (token == SEPARATOR && _separatorEndsOptions)
				return out.concat([for (rest in i + 1...args.length) rest]);
			else if (token != SEPARATOR && !declares(token) && !isLongFlag(token))
				out.push(i);
			i++;
		}
		return out;
	}

	/** The first `--word` in `args` this spec does not declare, or null; a flag's value is never one. */
	public function unknownFlag(args: Array<String>): Null<String> {
		var i: Int = 0;
		while (i < args.length) {
			final token: String = args[i];
			if (takesValue(token))
				i++;
			else if (token == SEPARATOR && _separatorEndsOptions)
				return null;
			else if (isLongFlag(token) && !declares(token))
				return token;
			i++;
		}
		return null;
	}

	/** Every flag this spec declares beyond the global ones, switches first. */
	public function names(): Array<String> {
		return _switches.concat(_valued);
	}

	private static function isLongFlag(token: String): Bool {
		return token.length > LONG_PREFIX.length && token.startsWith(LONG_PREFIX);
	}

	/** `a`, then each name of `b` it lacks: two parsers reading one flag declare it once. */
	private static function union(a: Array<String>, b: Array<String>): Array<String> {
		return a.concat(b.filter(name -> !a.contains(name)));
	}

}

package anyparse.query.cli;

using Lambda;

/**
 * Which tokens of a command's argv are flags, which are a flag's value and which are positionals: the one answer
 * the dispatcher's unknown-flag refusal, `LanguageChoice`'s "is this token a file" and every command's own parser
 * (`walk`) read. Each command declares its own (`CliCommand.flags`); one whose argv another parser also reads
 * declares the union (`with`). Every command also takes `--lang` / `--lang-default` and `-h` / `--help`.
 */
@:nullSafety(Strict)
final class CliFlags {

	/**
	 * Splits a walker's queries from its scope (`refs A B -- src`): neither a flag nor a value, and flags may follow
	 * it — unless the command's spec says it ends the options (`search -- '--$x'`). A spec that reads neither
	 * refuses it as an unknown option.
	 */
	public static inline final SEPARATOR: String = '--';

	/** The long-flag prefix: a token spelled with it that no spec declares is an unknown option. */
	private static inline final LONG_PREFIX: String = '--';

	private static final GLOBAL_VALUED: Array<String> = ['--lang', '--lang-default'];
	private static final GLOBAL_SWITCHES: Array<String> = ['-h', '--help'];

	/** Flags that take no value. */
	private final _switches: Array<String>;

	/** Flags whose next token is their value, whatever it spells. */
	private final _valued: Array<String>;

	/** Flags whose next token is their value only when their own test accepts it (`--after [<l>:<c>]`). */
	private final _optional: Array<OptionalValueFlag>;

	/** Valued flags that take more than the one token after them (`graph --diff <old> <new>`). */
	private final _multi: Array<MultiValueFlag>;

	/** What a bare `--` is to this command: refused, a split its parser reads, or the end of the options. */
	private final _separator: CliSeparator;

	public function new(
		switches: Array<String>, valued: Array<String>, separator: CliSeparator = Refused, ?optional: Array<OptionalValueFlag>,
		?multi: Array<MultiValueFlag>
	) {
		_switches = switches;
		_valued = valued;
		_separator = separator;
		_optional = optional ?? [];
		_multi = multi ?? [];
	}

	/** This spec and `other`'s together: the flags of a command whose argv another parser also reads. */
	public function with(other: CliFlags): CliFlags {
		return new CliFlags(
			union(_switches, other._switches), union(_valued, other._valued), wider(_separator, other._separator),
			_optional.concat(other._optional.filter(flag -> !optionalNames().contains(flag.name))),
			_multi.concat(other._multi.filter(flag -> !multiNames().contains(flag.name)))
		);
	}

	/** This spec plus `name`, whose next token is its value only when `accepts` says so. */
	public function withOptional(name: String, accepts: String -> Bool): CliFlags {
		return with(new CliFlags([], [], Refused, [{ name: name, accepts: accepts }]));
	}

	/** This spec plus `name`, which takes the `count` tokens after it as its values. */
	public function withValues(name: String, count: Int): CliFlags {
		return with(new CliFlags([], [], Refused, [], [{ name: name, count: count }]));
	}

	/** Does `token` always take the next argv token as its value? */
	public function takesValue(token: String): Bool {
		return _valued.contains(token) || GLOBAL_VALUED.contains(token) || multiNames().contains(token);
	}

	/** Does `token` take the next argv token as its value only when one that it accepts follows? */
	public function takesOptionalValue(token: String): Bool {
		return optionalNames().contains(token);
	}

	/** Is `token` a flag this spec declares, valued or not? */
	public function declares(token: String): Bool {
		return takesValue(token) || takesOptionalValue(token) || _switches.contains(token) || GLOBAL_SWITCHES.contains(token);
	}

	/**
	 * `args` as this spec reads them, in order: each flag with the value it took, the separator, each positional with
	 * its index. An undeclared `--word`, or a valued flag with nothing after it, is a usage failure.
	 */
	public function walk(args: Array<String>): Array<CliArg> {
		final read: CliScan = scan(args);
		final unknown: Null<String> = read.unknown;
		if (unknown != null) throw new UsageFailure('unknown option "$unknown"');
		final valueless: Null<String> = read.valueless;
		if (valueless != null) throw new UsageFailure('$valueless requires a value');
		return read.args;
	}

	/** The indices of `args` that are positionals: not a flag, not a flag's value, not the separator. */
	public function positionals(args: Array<String>): Array<Int> {
		return [for (arg in scan(args).args) if (arg.flag == null) arg.index];
	}

	/** The first `--word` in `args` this spec does not declare, or null; a flag's value is never one. */
	public function unknownFlag(args: Array<String>): Null<String> {
		return scan(args).unknown;
	}

	/** Does `args` give `flag` as a flag: not as another flag's value, not as a positional after an ending separator? */
	public function given(args: Array<String>, flag: String): Bool {
		return scan(args).args.exists(arg -> arg.flag == flag);
	}

	/** Every flag this spec declares beyond the global ones, switches first. */
	public function names(): Array<String> {
		return _switches.concat(_valued).concat(optionalNames()).concat(multiNames());
	}

	/** Reads `args` to the end, noting the first undeclared `--word` and a trailing valued flag instead of refusing them. */
	private function scan(args: Array<String>): CliScan {
		final out: Array<CliArg> = [];
		var unknown: Null<String> = null;
		var valueless: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final token: String = args[i];
			if (takesValue(token)) {
				final count: Int = valueCount(token);
				if (i + count < args.length) {
					out.push(new CliArg(token, token, i, args.slice(i + 1, i + 1 + count)));
					i += count;
				} else {
					valueless = token;
				}
			} else if (token == SEPARATOR && _separator == Refused) {
				if (unknown == null) unknown = token;
			} else if (token == SEPARATOR) {
				out.push(new CliArg(token, token, i, []));
				if (_separator == EndsOptions) {
					for (rest in i + 1...args.length) out.push(new CliArg(null, args[rest], rest, []));
					break;
				}
			} else if (i + 1 < args.length && acceptsOptionalValue(token, args[i + 1])) {
				out.push(new CliArg(token, token, i, [args[++i]]));
			} else if (declares(token)) {
				out.push(new CliArg(token, token, i, []));
			} else if (isLongFlag(token)) {
				if (unknown == null) unknown = token;
			} else {
				out.push(new CliArg(null, token, i, []));
			}
			i++;
		}
		return { args: out, unknown: unknown, valueless: valueless };
	}

	private function acceptsOptionalValue(token: String, next: String): Bool {
		for (flag in _optional) if (flag.name == token) return flag.accepts(next);
		return false;
	}

	private function optionalNames(): Array<String> {
		return [for (flag in _optional) flag.name];
	}

	private function multiNames(): Array<String> {
		return [for (flag in _multi) flag.name];
	}

	/** How many tokens after `token` are its values: one, unless the spec gives it more. */
	private function valueCount(token: String): Int {
		for (flag in _multi) if (flag.name == token) return flag.count;
		return 1;
	}

	/** The reading of `--` that admits what either spec admits: two parsers on one argv. */
	private static inline function wider(a: CliSeparator, b: CliSeparator): CliSeparator {
		return if (a == EndsOptions || b == EndsOptions)
			EndsOptions
		else if (a == Splits || b == Splits)
			Splits
		else
			Refused;
	}

	private static function isLongFlag(token: String): Bool {
		return token.length > LONG_PREFIX.length && token.startsWith(LONG_PREFIX);
	}

	/** `a`, then each name of `b` it lacks: two parsers reading one flag declare it once. */
	private static function union(a: Array<String>, b: Array<String>): Array<String> {
		return a.concat(b.filter(name -> !a.contains(name)));
	}

}

/** A flag whose next token is its value only when `accepts` says so; otherwise it stands alone. */
typedef OptionalValueFlag = {
	var name: String;
	var accepts: String -> Bool;
};

/** A valued flag that takes the `count` tokens after it, not just the next one. */
typedef MultiValueFlag = {
	var name: String;
	var count: Int;
};

/** What a bare `--` in argv is to a command. */
enum CliSeparator {

	/** No parser reads it: an unknown option. */
	Refused;

	/** It splits queries from scope (`refs A B -- src`); flags may follow it. */
	Splits;

	/** Every token after it is a positional, a flag-shaped one too (`search -- '--$x'`). */
	EndsOptions;
}

/** What `CliFlags.scan` read: every token it placed, the first undeclared `--word`, a valued flag argv ended on. */
private typedef CliScan = {
	var args: Array<CliArg>;
	var unknown: Null<String>;
	var valueless: Null<String>;
};

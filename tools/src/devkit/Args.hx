package devkit;

import haxe.Exception;

using StringTools;

/**
 * The command line of one subcommand, taken apart in the order a tool asks for it: flags and options first (each in
 * either `--name value` or `--name=value` form, anywhere on the line), the positionals last — which is also where an
 * option nobody asked for is refused. Everything after a bare `--` is positional.
 */
@:nullSafety(Strict)
final class Args {

	private final _rest: Array<String>;
	private final _tail: Array<String>;

	public function new(argv: Array<String>) {
		final cut: Int = argv.indexOf('--');
		_rest = cut < 0 ? argv.copy() : argv.slice(0, cut);
		_tail = cut < 0 ? [] : argv.slice(cut + 1);
	}

	/** Whether the flag `name` is given; takes every occurrence. */
	public function flag(name: String): Bool {
		final given: Bool = _rest.contains(name);
		while (_rest.remove(name)) {}
		return given;
	}

	/** The value of the option `name` (its last occurrence), or null when it is not given. */
	public function option(name: String): Null<String> {
		final values: Null<Array<String>> = take(name, 1);
		return values == null ? null : values[0];
	}

	/** The `count` values of the option `name` (its last occurrence), or null when it is not given. */
	public function values(name: String, count: Int): Null<Array<String>> {
		return take(name, count);
	}

	/**
	 * The positionals, once every flag and option is taken: exactly `names.length` of them, named by `names` in a
	 * refusal. An unknown option or a missing or extra positional throws `UsageError`.
	 */
	public function positionals(names: Array<String>): Array<String> {
		final all: Array<String> = left();
		if (all.length < names.length) throw new UsageError('missing ${names.slice(all.length).join(' ')}');
		if (all.length > names.length) throw new UsageError('unexpected ${all.slice(names.length).join(' ')}');
		return all;
	}

	/** Refuse anything left once every flag and option is taken: the end of a command line that takes no positionals. */
	public function done(): Void {
		final all: Array<String> = left();
		if (all.length > 0) throw new UsageError('unexpected ${all.join(' ')}');
	}

	/** What is left of the command line, refusing an option nobody took. */
	private function left(): Array<String> {
		for (arg in _rest) if (arg.startsWith('-') && arg != '-') throw new UsageError('unknown option $arg');
		return _rest.concat(_tail);
	}

	/** Take every occurrence of the option `name` with its `count` values; answers the last one's. */
	private function take(name: String, count: Int): Null<Array<String>> {
		var found: Null<Array<String>> = null;
		var i: Int = 0;
		while (i < _rest.length) {
			final arg: String = _rest[i];
			if (arg.startsWith('$name=') && count == 1) {
				found = [arg.substr(name.length + 1)];
				_rest.splice(i, 1);
			} else if (arg == name) {
				if (_rest.length - i - 1 < count) throw new UsageError('$name needs $count value(s)');
				found = _rest.slice(i + 1, i + 1 + count);
				_rest.splice(i, count + 1);
			} else {
				i++;
			}
		}
		return found;
	}

}

/** A command line a subcommand cannot read: the CLI prints the message with the usage and exits 2. */
class UsageError extends Exception {}

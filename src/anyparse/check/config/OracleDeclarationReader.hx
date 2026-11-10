package anyparse.check.config;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.query.FileIdentity;
import haxe.io.Path;

using StringTools;
using Lambda;

/**
 * The one answer to "which builds does a `compilerOracle` value declare": its string or list form read into configurations,
 * every wrong entry dropped with a line. Grammar-neutral: the compile directory of an hxml is decided by the `probe` the
 * caller hands in (the Haxe compiler reads class paths for it) or left unset for a run whose grammar has no compiler.
 */
@:nullSafety(Strict)
final class OracleDeclarationReader {

	/**
	 * The `compilerOracle` value → its configurations. A JSON STRING is the one-element case (no extra defines);
	 * an ARRAY holds one `{hxml, defines?, dir?, generate?, generateInputs?}` object per configuration.
	 *
	 * A value that is neither is not a configuration at all, so it is dropped with a line rather
	 * than guessed at — a project whose oracle silently went missing would read every risky fix
	 * as report-only and never learn why.
	 */
	public static function read(
		raw: JValue, baseDir: Null<String>, drops: Array<String>, probe: Null<(hxml:String, baseDir:String) -> String>
	): Array<OracleConfig> {
		return switch raw {
			case JString(hxml): [
				at(hxml, {
					hxml: hxml,
					dir: null,
					defines: [],
					generate: null,
					generateInputs: null
				}, baseDir, drops, 0, probe)
			];
			case JArray(items): readList(items, baseDir, drops, probe);
			case _:
				drops.push('compilerOracle is neither an hxml path nor a list of configurations — ignored');
				[];
		};
	}

	/** Whether `path` exists on disk — false wholesale on a non-sys target, keeping the probe a tie there. */
	public static function pathExists(path: String): Bool {
		return #if (sys || nodejs) sys.FileSystem.exists(path) #else false #end;
	}

	/**
	 * The ARRAY form's entries → their configurations, per-ENTRY lenient exactly as `rules` and
	 * `frameworks` are: an element that is not an object, names no `hxml`, spells a key with the
	 * wrong type, or names a key this reader does not know is dropped and the configurations
	 * beside it still apply.
	 *
	 * Every drop appends a diagnostic line, because a dropped element that said nothing is
	 * indistinguishable from one that works — and here that silence costs a whole build's worth
	 * of verification.
	 *
	 * An hxml two different `generate` commands claim is dropped from every entry that claims it
	 * (`withoutRivalCommands`).
	 */
	private static function readList(
		items: Array<JValue>, baseDir: Null<String>, drops: Array<String>, probe: Null<(hxml:String, baseDir:String) -> String>
	): Array<OracleConfig> {
		final out: Array<IndexedOracle> = [];
		for (i => item in items) switch item {
			case JObject(fields):
				final declared: OracleFields = readFields(i, fields, drops);
				final hxml: Null<String> = declared.hxml;
				if (hxml == null) {
					drops.push('compilerOracle[$i] declares no "hxml" — dropped');
					continue;
				}
				out.push({ index: i, config: at(hxml, declared, baseDir, drops, i, probe) });
			case _:
				drops.push('compilerOracle[$i] is not an object — dropped');
		}
		return withoutRivalCommands(out, drops);
	}

	/** One array element's keys as DECLARED, every wrong-typed or unknown one dropped with a line. */
	private static function readFields(index: Int, fields: Array<JEntry>, drops: Array<String>): OracleFields {
		var hxml: Null<String> = null;
		var dir: Null<String> = null;
		var generate: Null<String> = null;
		var inputs: Null<Array<String>> = null;
		final defines: Array<String> = [];
		for (field in fields) switch [field.key, field.value] {
			case ['hxml', JString(v)]:
				hxml = v;
			case ['dir', JString(v)]:
				dir = v;
			case ['generate', JString(v)]:
				generate = v;
			case ['generateInputs', JArray(values)]:
				final declared: Array<String> = [];
				LintDocuments.collectStrings(values, declared);
				final skipped: Int = values.length - declared.length;
				if (skipped > 0) drops.push('compilerOracle[$index] "generateInputs" ignored $skipped value(s) that are not strings');
				inputs = declared;
			case ['defines', JArray(values)]:
				final before: Int = defines.length;
				LintDocuments.collectStrings(values, defines);
				final skipped: Int = values.length - (defines.length - before);
				if (skipped > 0) drops.push('compilerOracle[$index] "defines" ignored $skipped value(s) that are not strings');
			case ['hxml', _], ['dir', _], ['generate', _]:
				drops.push('compilerOracle[$index] "${field.key}" is not a string — ignored');
			case ['defines', _], ['generateInputs', _]:
				drops.push('compilerOracle[$index] "${field.key}" is not an array of strings — ignored');
			case _:
				drops.push('compilerOracle[$index] declares unknown key "${field.key}" — ignored');
		}
		return {
			hxml: hxml,
			dir: dir,
			defines: defines,
			generate: generate,
			generateInputs: inputs
		};
	}

	/**
	 * One configuration's declared paths resolved: the hxml against the config dir, and the
	 * compile directory either as the element declared it or PROBED.
	 *
	 * With neither a declared dir nor a base there is nothing to resolve against and nothing to
	 * claim, so the compile directory stays null and the caller runs in its own cwd.
	 *
	 * A `generate` command runs from the config dir (the process cwd without one) and its
	 * `generateInputs` resolve there too: the compile directory may be one the command itself
	 * creates. A probed compile directory is probed again once the command wrote the hxml
	 * (`probeDir`), since before that there may be nothing to probe.
	 */
	private static function at(
		hxml: String, declared: OracleFields, baseDir: Null<String>, drops: Array<String>, index: Int,
		probe: Null<(hxml:String, baseDir:String) -> String>
	): OracleConfig {
		final resolved: String = LintDocuments.resolveAgainstConfigDir(baseDir, hxml);
		final dir: Null<String> = declared.dir;
		final probed: Null<String> = if (dir != null)
			LintDocuments.resolveAgainstConfigDir(baseDir, dir)
		else if (baseDir == null || probe == null)
			null
		else
			probe(resolved, baseDir);
		final command: Null<String> = declared.generate;
		final inputs: Null<Array<String>> = declared.generateInputs;
		if (command == null && inputs != null) drops.push('compilerOracle[$index] declares "generateInputs" without "generate" — ignored');
		final config: OracleConfig = { hxml: resolved, dir: probed, defines: declared.defines };
		if (command != null) config.generate = {
			command: command,
			root: baseDir ?? '.',
			inputs: generateInputs(inputs, baseDir, drops, index),
			probeDir: dir == null && baseDir != null
		};
		return config;
	}

	/**
	 * A `generateInputs` list resolved: a leading `~/` against the home directory (a tool's own config file lives
	 * there), anything else relative against the config dir. An EMPTY list is read as no list — it could only ever mean
	 * "never regenerate", which no project wants silently — so both regenerate every run. A path that does not exist is
	 * KEPT, since its appearance is a change the next run must see, but named with a line: a typo there would otherwise
	 * make that input a constant.
	 */
	private static function generateInputs(
		inputs: Null<Array<String>>, baseDir: Null<String>, drops: Array<String>, index: Int
	): Null<Array<String>> {
		if (inputs == null || inputs.length == 0) return null;
		final home: String = Sys.getEnv('HOME') ?? '';
		final out: Array<String> = [];
		for (input in inputs) {
			final path: String = input.startsWith('~/') && home != ''
				? Path.join([home, input.substr(2)])
				: LintDocuments.resolveAgainstConfigDir(baseDir, input);
			if (!pathExists(path))
				drops.push('compilerOracle[$index] "generateInputs" names $input, which does not exist — kept, it counts once created');
			out.push(path);
		}
		return out;
	}

	/**
	 * `entries` without those whose hxml a DIFFERENT `generate` command of this document
	 * also writes, compared as real paths so two spellings of one file meet. One generation's
	 * state and lock are keyed by its tree, so two commands over one hxml would run concurrently into it and each find
	 * the other's record: neither configuration could ever be current. Which one the project meant is not ours to guess,
	 * so each such entry is dropped with a line naming the rival command.
	 */
	private static function withoutRivalCommands(entries: Array<IndexedOracle>, drops: Array<String>): Array<OracleConfig> {
		final claims: Map<String, Array<String>> = [];
		final trees: Array<String> = entries.map(entry -> FileIdentity.realPath(entry.config.hxml));
		for (i => entry in entries) {
			final command: Null<String> = entry.config.generate?.command;
			if (command == null) continue;
			final held: Array<String> = claims[trees[i]] ?? [];
			if (!held.contains(command)) held.push(command);
			claims[trees[i]] = held;
		}
		final out: Array<OracleConfig> = [];
		for (i => entry in entries) {
			final command: Null<String> = entry.config.generate?.command;
			final rivals: Array<String> = command == null ? [] : (claims[trees[i]] ?? []).filter(c -> c != command);
			if (rivals.length == 0)
				out.push(entry.config)
			else
				drops.push(
					'compilerOracle[${entry.index}] generates ${entry.config.hxml}, which another entry generates with a different command '
					+ '(`${rivals.join('`, `')}`) — which one writes it is ambiguous, so the entry is dropped'
				);
		}
		return out;
	}

}

/**
 * One `compilerOracle` array element's keys exactly as DECLARED — before any path is
 * resolved and before a missing `hxml` decides the element's fate.
 *
 * Module-private: it is the reading step's own shape, not a config surface.
 */
private typedef OracleFields = {
	var hxml: Null<String>;
	var dir: Null<String>;
	var defines: Array<String>;
	var generate: Null<String>;
	var generateInputs: Null<Array<String>>;
}

/** A configuration read from the array form, with the position its element had there, for the drop lines. */
private typedef IndexedOracle = { var index: Int; var config: OracleConfig; }

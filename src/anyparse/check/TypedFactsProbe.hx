package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.core.TempScratch;
import anyparse.macro.EmbeddedSource;
import anyparse.query.CompilerFacts;
import haxe.io.Path;

/**
 * What the compiler typed, for every configured compiler oracle: one compile of the configuration's own hxml with the
 * `TypedFactsMacro` hook, which writes the typed tree's facts to a file once typing ended, read into one
 * `CompilerFacts` table. Asked per run and never kept across runs (`docs/decisions.md` records why a cache is unsound);
 * the compiles overlap (`HaxeSpawn.parallelism`). A configuration that cannot be asked, fails to compile, or leaves no
 * complete file contributes no facts — the table then holds less, which its absence semantics already answer.
 *
 * ## The facts file
 *
 * JSON Lines. Offsets are the compiler's `Position.min`/`max` (codepoints, `max` exclusive). A position is
 * `[min, max]` in the file of the record carrying it (`f`), or `[i, min, max]` in the file a `file` record announced
 * as index `i` — only code inlined or generated from elsewhere has one. Ids are the compiler's type paths: a type is
 * `pack.Name` (a private type's package ends in `_Module`), a field node `pack.Name.field` (the constructor is `new`),
 * a nested function `<enclosing node id>@<min>`, suffixed `#n` in the rare case two share an offset.
 *
 * - `{"k":"facts","v":1,"inline":B}` first; `{"k":"end","nodes":N,"types":N}` last — a file without it is incomplete.
 *   `inline` is whether the compile inlined: a call of an `inline` function is then no call site, and its
 *   body's facts are the caller's, positioned in the callee: the probe compiles with `keep-inline-positions`, so none
 *   lands on the call site's range.
 * - `{"k":"file","i":N,"path":S}`.
 * - `{"k":"type","id","f","p","kind","pack", params?, meta?, ext?, …}` — `kind` is `class`, `interface`, `impl` (an
 *   abstract's implementation class, `abs` naming the abstract), `abstract` (`under`, `from`, `to`, `impl`), `enum`
 *   (`ctors`: `{n, t}`) or `typedef` (`target`). A class or interface has `sup`, `ifaces` and `fields`:
 *   `{n, k, t, p, s?, fin?, ext?, over?, meta?}`, `k` being `method`, `inline`, `dynamic`, `macro` or
 *   `var(<read>,<write>)` with the accessors `default`, `null`, `never`, `call`, `inline`, `resolve`, `require`, `ctor`.
 * - `{"k":"node","id","f","p","kind","owner","t", s?, name?, …facts}` — `kind` is `method`, `ctor`, `var` (an
 *   initializer), `fn` (a function expression) or `local` (a function bound to a local). The facts, each list deduplicated:
 *   - `params`: `{n, t}` — the function's parameters, in order; the compiler gives a parameter no position of its own.
 *   - `calls`: `{t?, a, r?, rp?, rt, p}` — `a` is the field access `FInstance`/`FStatic`/`FAnon`/`FDynamic`/`FClosure`/
 *     `FEnum` with `t` = `<declaring type>.<field>` (a bare name for `FAnon`/`FDynamic`) and `r`/`rp` the receiver's
 *     type and position; `super` (`t` = `<super>.new`); `local` (`t` = the local function's node id); `ident` (a native
 *     identifier); `value` (a call of any other value, `r` its type). `rt` is the result type. A property read or write
 *     through an accessor IS a call of `get_x`/`set_x`; an abstract operator, `@:from` or `@:to` is a call of the
 *     implementation class's static.
 *   - `news`: `{t, ty, p}` — the class and the instance type.
 *   - `fields`: `{f, a, o?, r, t, p, w?}` — a field read (a write when `w`) that is not a callee; `o` is the declaring
 *     type, absent for a structure or a dynamic access.
 *   - `flows`: `{s, d, c, p}` — a value of type `s` reaching a place of type `d`, `c` being `var`, `assign`, `arg`,
 *     `ret`, `arr`, `obj` or `cast` (an unchecked cast only); kept only when the two differ beyond an outer `Null<>`.
 *   - `strs`: `{o, p}` — a non-String operand of a String `+` or `+=`.
 *   - `iters`: `{v, i, p}` — a `for` the compiler kept (it lowers an Array loop to a `while` and unrolls a constant one).
 *   - `refl`: `{t, n?, c?, p}` — a `Reflect.*`/`Type.*` call, its first literal string and its first type argument.
 *   - `native`: `{w, n, p}` — `syntax` for a `*.Syntax` call, `ident` for a `__js__`-style identifier.
 *   - `vars`: `{n, t, p}` — a parameter, local or loop binder (compiler temporaries are left out).
 *   - `reads`: `[min, max, type]` (foreign: `[i, min, max, type]`) — a read of a local, at the identifier.
 *   - `fns`: the node ids of the functions nested directly in this one.
 *
 * ## Type strings
 *
 * ```
 * type  := '?'                                   unknown: an unbound monomorph, or nested deeper than the bound
 *        | 'Dynamic' ['<' type '>']
 *        | '$' path                              a type parameter (`$pack.Class.T`)
 *        | path ['<' type (',' type)* '>']       class, enum, typedef (not expanded), abstract — `Null<T>` included
 *        | 'Class<' path '>' | 'Enum<' path '>' | 'Abstract<' path '>'   a type expression's statics
 *        | '(' [arg (',' arg)*] ')->' type       arg := ['?'] type
 *        | '{' [field (',' field)*] '}'          field := ['?'] name ':' type, sorted by name
 * path  := the type id above
 * ```
 */
@:nullSafety(Strict)
final class TypedFactsProbe {

	/** The bound of the random suffix that keeps two runs' probe directories apart. */
	private static inline final DIRECTORY_SUFFIX_BOUND: Int = 0x7fffffff;

	/** Spawn buffer, in bytes: the facts go to a file, the compile prints only its warnings. */
	private static inline final BUFFER: Int = 64 * 1024 * 1024;

	/** The hook's modules, by class-path-relative path, written into each compile's probe directory. */
	private static final MACRO_FILES: Array<{ path: String, text: String }> = [
		{ path: 'anyparse/check/TypedFactsMacro.hx', text: EmbeddedSource.text('anyparse/check/TypedFactsMacro.hx') },
		{ path: 'anyparse/check/TypedFactsWalk.hx', text: EmbeddedSource.text('anyparse/check/TypedFactsWalk.hx') }
	];

	/**
	 * The table over every configuration of `oracles` that answered, each compiled once (the compiles overlap); null when
	 * none answered.
	 */
	public static function probeAll(oracles: Array<OracleConfig>): Null<CompilerFacts> {
		#if (sys || nodejs)
		final asked: Array<{
			oracle: OracleConfig,
			dir: String,
			out: String,
			args: Array<String>
		}> = [];
		for (i in 0...oracles.length) {
			final prepared: Null<{
				oracle: OracleConfig,
				dir: String,
				out: String,
				args: Array<String>
			}> = prepare(oracles[i], i);
			if (prepared != null) asked.push(prepared);
		}
		final runs: Array<HaxeRun> = asked.length == 0
			? []
			: HaxeSpawn.runAll([for (a in asked) { args: a.args, cwd: a.oracle.dir }], BUFFER, HaxeSpawn.parallelism());
		final dumps: Array<FactsDump> = [];
		for (i in 0...asked.length) {
			final dump: Null<FactsDump> = answer(asked[i].oracle, runs[i], asked[i].out);
			if (dump != null) dumps.push(dump);
		}
		for (a in asked) discard(a.dir);
		if (dumps.length == 0) return null;
		return CompilerFacts.build(
			dumps, file -> try sys.io.File.getContent(file) catch (exception: haxe.Exception) null, memoised(Sys.getCwd())
		);
		#else
		return null;
		#end
	}

	/** The arguments of the facts compile of `hxml` under `defines`, writing to `out` with the hook found under `dir`. */
	public static function compileArgs(hxml: String, defines: Array<String>, dir: String, out: String): Array<String> {
		// the hook's class path goes AFTER the hxml: a later class path wins, so a project holding its own copy — anyparse —
		// still runs the one written here. `keep-inline-positions` leaves an inlined body at the callee's positions: without
		// it every fact of the body lands on the call site's range and reads as the type of the call itself
		return CompilerOracle.defineFlags(defines.concat(['keep-inline-positions'])).concat([
			hxml,
			'--no-output',
			'-cp',
			dir,
			'--macro',
			'anyparse.check.TypedFactsMacro.run(${haxe.Json.stringify(out)})'
		]);
	}

	#if (sys || nodejs)
	private static function prepare(oracle: OracleConfig, index: Int): Null<{
		oracle: OracleConfig,
		dir: String,
		out: String,
		args: Array<String>
	}> {
		if (oracle.unavailable != null) return null;
		final dir: String = Path.join([
			TempScratch.root(),
			'anyparse-typed-facts-${Std.random(DIRECTORY_SUFFIX_BOUND)}-$index'
		]);
		final out: String = Path.join([dir, 'facts.jsonl']);
		try {
			for (file in MACRO_FILES) {
				sys.FileSystem.createDirectory(Path.join([dir, Path.directory(file.path)]));
				sys.io.File.saveContent(Path.join([dir, file.path]), file.text);
			}
		} catch (exception: haxe.Exception) {
			return null;
		}
		return {
			oracle: oracle,
			dir: dir,
			out: out,
			args: compileArgs(oracle.hxml, oracle.defines, dir, out)
		};
	}

	/** The facts the compile `run` of `oracle` wrote to `out`, or null when it failed or left no file. */
	private static function answer(oracle: OracleConfig, run: HaxeRun, out: String): Null<FactsDump> {
		if (run.failure != '' || run.status != 0) return null;
		final text: Null<String> = try sys.io.File.getContent(out) catch (exception: haxe.Exception) null;
		if (text == null) return null;
		return { name: LintConfig.describeOracle(oracle), text: text, file: memoised(oracle.dir ?? Sys.getCwd()) };
	}

	/** `OracleCoverage.canonical` against `root`, each path resolved once: a facts file names one path on many lines. */
	private static function memoised(root: String): (String) -> String {
		final known: Map<String, String> = [];
		return path -> {
			final hit: Null<String> = known[path];
			if (hit != null) return hit;
			final resolved: String = OracleCoverage.canonical(root, path);
			known[path] = resolved;
			return resolved;
		};
	}

	/** Delete the probe directory `dir`. */
	private static function discard(dir: String): Void {
		function wipe(path: String): Void {
			if (sys.FileSystem.isDirectory(path)) {
				for (entry in sys.FileSystem.readDirectory(path)) wipe(Path.join([path, entry]));
				sys.FileSystem.deleteDirectory(path);
			} else
				sys.FileSystem.deleteFile(path);
		}
		try wipe(dir) catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a leftover probe directory costs nothing but disk: the answer does not depend on it
		}
	}
	#end

}

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
 * complete file contributes no facts and is named in the table's `dropped`.
 *
 * ## The facts file
 *
 * JSON Lines. Offsets are the compiler's `Position.min`/`max` (codepoints, `max` exclusive). A position is
 * `[min, max]` in the file of the record carrying it (`f`), or `[i, min, max]` in the file a `file` record announced
 * as index `i`. A fact outside the node's body range — another file or elsewhere in its own — was spliced in by
 * inlining or a macro, and sits at the callee's positions: the compiler keeps no range for the call site it replaced.
 * Ids are the compiler's type paths: a type is
 * `pack.Name` (a private type's package ends in `_Module`), a field node `pack.Name.field` (the constructor is `new`,
 * the static initializer `__init__`, a further overload `field~n`), a nested function `<enclosing node id>@<min>`,
 * suffixed `#n` in the rare case two share an offset.
 *
 * - `{"k":"facts","v":1,"inline":B}` first; `{"k":"end","nodes":N,"types":N}` last — a file without it is incomplete.
 *   The compile keeps `keep-inline-positions`, so an inlined body stays at its callee's positions.
 * - `{"k":"file","i":N,"path":S}`; `{"k":"src","path":S,"len":N,"md5":S}` — the UTF-8 length and MD5 of every
 *   file a record is homed in, as the compile read it: a table reading another text has no facts for the file.
 * - `{"k":"type","id","f","p","kind","pack", params?, meta?, ext?, …}` — `kind` is `class`, `interface`, `impl` (an
 *   abstract's implementation class, `abs` naming the abstract), `abstract` (`under`, `from`, `to`, `impl`), `enum`
 *   (`ctors`: `{n, t}`) or `typedef` (`target`). A class or interface has `sup`, `ifaces` and `fields`:
 *   `{n, k, t, p, s?, fin?, ext?, over?, meta?}`, `k` being `method`, `inline`, `dynamic`, `macro` or
 *   `var(<read>,<write>)` with the accessors `default`, `null`, `never`, `call`, `inline`, `resolve`, `require`, `ctor`.
 *   A `@:generic` instance is a class of its own with `of`, the generic class at its arguments. `builds`: the printed
 *   macro calls of `@:build`/`@:autoBuild`/`@:genericBuild`. A `macro` field is always reachable from outside the program.
 * - `{"k":"node","id","f","p","kind","owner","t", s?, name?, gen?, gi?, inl?, ov?, inc?, …facts}` — `kind` is `method`,
 *   `ctor`, `var` (an initializer), `init` (`__init__`), `fn` (a function expression) or `local` (a function bound to a
 *   local never assigned again). `p` is the body's range. `gen`: a macro placed the body outside its type's file. `gi`: a
 *   `@:generic` instance's copy of its generic class's body. `inl`: the node an inlined body spliced this function into.
 *   A `gen`, `gi` or `inl` node is found by id, never by a range of its file. `ov`: the overload index. `inc`: markers.
 *   The facts, each list deduplicated:
 *   - `params`: `{n, t}` — the function's parameters, in order; the compiler gives a parameter no position of its own.
 *   - `calls`: `{t?, a, sig?, r?, rp?, rt, p}` — `a` is the field access `FInstance`/`FStatic`/`FAnon`/`FDynamic`/
 *     `FClosure`/`FEnum` with `t` = `<declaring type>.<field>` (a bare name for `FAnon`/`FDynamic`) and `r`/`rp` the
 *     receiver's type and position; `fieldValue` for a field that holds a replaceable value (a variable of a function
 *     type, a `dynamic` method); `super` (`t` = `<super>.new`); `local` (`t` = the local function's node id); `ident`
 *     (a native identifier); `value` (a call of any other value, `r` its type); `inlined` (`t` = the `inline` function
 *     whose body was spliced in, positioned at that body). `sig` is the signature chosen among a
 *     field's overloads. `rt` is the result type. A property access IS a call of `get_x`/`set_x`; an abstract operator,
 *     `@:from` or `@:to` is a call of the implementation class's static.
 *   - `news`: `{t, ty, p}` — the class and the instance type.
 *   - `fields`: `{f, a, o?, r, t, p, w?}` — a field read (a write when `w`) that is not a callee; `o` is the declaring
 *     type, absent for a structure or a dynamic access.
 *   - `flows`: `{s, d, c, p}` — a value of type `s` reaching a place of type `d`, `c` being `var`, `assign`, `arg`,
 *     `ret`, `arr`, `obj`, `throw` or `cast` (an unchecked cast, always kept). A branching value flows once per branch
 *     at the branch's own type; a place of no type is `Dynamic`, and so is every argument of a callee of no function
 *     type; each rest argument flows into the rest element type. Otherwise kept only when the types differ beyond `Null<>`.
 *   - `strs`: `{o, p}` — a non-String operand of a String `+` or `+=`.
 *   - `iters`: `{v, i, p}` — a `for` the compiler kept (it lowers an Array loop to a `while` and unrolls a constant one).
 *   - `refl`: `{t, n?, c?, v?, p}` — a `Reflect.*`/`Type.*` call, its first literal string and its first type argument;
 *     `v` when the member, or the class itself, is read as a value — whatever calls it later is reflection.
 *   - `native`: `{w, n, p}` — `syntax` for a `*.Syntax` call, `ident` for every native identifier, read or called.
 *   - `vars`: `{n, t, p}` — a local or loop binder (compiler temporaries are left out).
 *   - `reads`: `[min, max, type]` (foreign: `[i, min, max, type]`) — a read of a local, at the identifier.
 *   - `fns`: the node ids of the functions nested directly in this one.
 *
 * ## Markers (`inc`) — what a consumer answers Unknown for
 *
 * - `inline-site-unknown`: a body was spliced in; its facts are the node's but no range says where they run, so a range
 *   query not covering the whole node is Unknown.
 * - `macro-expansion`: a spliced body no `inline` function could be matched to — an expression macro's expansion, or
 *   an inlined piece that carries only its declaring type's range (an abstract's `this`); as above, and no callee is named.
 * - `reflection-inlined`: a `Reflect`/`Type` body was inlined; its call, name and arguments are gone.
 * - `stale-foreign` (added by the table): a fact positioned in a file whose text the table no longer has was dropped.
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
		{ path: 'anyparse/check/TypedFactsWalk.hx', text: EmbeddedSource.text('anyparse/check/TypedFactsWalk.hx') },
		{ path: 'anyparse/check/TypedFactsShapes.hx', text: EmbeddedSource.text('anyparse/check/TypedFactsShapes.hx') }
	];

	/**
	 * The table over every configuration of `oracles` that answered, each compiled once (the compiles overlap), with the
	 * rest in its `dropped` and why; null only on a target that cannot spawn a compile. A compile that reported an error
	 * is dropped even when it wrote a complete file: typing goes on past an error, and what it recovers with — an unbound
	 * monomorph, a branch left out — reads exactly like a fact, so the table could not tell the two apart. The files are
	 * read and added one at a time, so no two dumps are held at once.
	 */
	public static function probeAll(oracles: Array<OracleConfig>): Null<CompilerFacts> {
		#if (sys || nodejs)
		final facts: CompilerFacts = CompilerFacts.create(
			file -> try sys.io.File.getContent(file) catch (exception: haxe.Exception) null, memoised(Sys.getCwd())
		);
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
			if (prepared != null)
				asked.push(prepared)
			else
				facts.dropped.push({
					name: LintConfig.describeOracle(oracles[i]),
					reason: oracles[i].unavailable ?? 'its probe directory could not be written'
				});
		}
		final runs: Array<HaxeRun> = asked.length == 0
			? []
			: HaxeSpawn.runAll([for (a in asked) { args: a.args, cwd: a.oracle.dir }], BUFFER, HaxeSpawn.parallelism());
		for (i in 0...asked.length) {
			final dump: Null<FactsDump> = answer(asked[i].oracle, runs[i], asked[i].out);
			if (dump != null)
				facts.addDump(dump)
			else
				facts.dropped.push({ name: LintConfig.describeOracle(asked[i].oracle), reason: failureOf(runs[i]) });
			discard(asked[i].dir);
		}
		return facts;
		#else
		return null;
		#end
	}

	/** Why the compile `run` left no facts, in one line. */
	private static function failureOf(run: HaxeRun): String {
		if (run.failure != '') return run.failure;
		if (run.status != 0) {
			final first: String = StringTools.trim(
				Lambda.find(run.err.split('\n'), l -> StringTools.trim(l) != '' && l.indexOf('Warning') < 0) ?? ''
			);
			return 'the compile failed (status ${run.status})' + (first == '' ? '' : ': $first');
		}
		return 'it wrote no facts file';
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

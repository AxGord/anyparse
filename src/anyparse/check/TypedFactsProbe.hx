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
 *   An import alias (`import pack.T as U`), which no module lists, is a `typedef` of its own, a record per declaration.
 * - `{"k":"node","id","f","p","kind","owner","t", s?, name?, gen?, gi?, inl?, ov?, inc?, …facts}` — `kind` is `method`,
 *   `ctor`, `var` (an initializer), `init` (`__init__`), `fn` (a function expression) or `local` (a function bound to a
 *   local never assigned again). `p` is the body's range. `gen`: a macro placed the body outside its type's file. `gi`: a
 *   `@:generic` instance's copy of its generic class's body. `inl`: the node an inlined body spliced this function into.
 *   A `gen`, `gi` or `inl` node is found by id, never by a range of its file. `ov`: the overload index. `inc`: markers.
 *   The facts, each list deduplicated:
 *   - `params`: `{n, t}` — the function's parameters, in order; the compiler gives a parameter no position of its own.
 *   - `calls`: `{t?, a, sig?, r?, rp?, rt, p, s?, d?, o?, x?}` — `a` is the field access `FInstance`/`FStatic`/`FAnon`/`FDynamic`/
 *     `FClosure`/`FEnum` with `t` = `<declaring type>.<field>` (a bare name for `FAnon`/`FDynamic`) and `r`/`rp` the
 *     receiver's type and position; `fieldValue` for a field that holds a replaceable value (a variable of a function
 *     type, a `dynamic` method); `super` (`t` = `<super>.new`); `local` (`t` = the local function's node id); `ident`
 *     (a native identifier); `value` (a call of any other value, `r` its type); `inlined` (`t` = the method — `inline`, or
 *     inlined by its call site — whose body was spliced in, positioned at that body; `s` is where it ran: the range of the
 *     innermost expression of the node's own range around the call site it replaced, the whole body when none is, and `d`
 *     the method's declared range, which holds the code the call spliced in; a body a spliced body spliced in turn is a
 *     call of its own at the same `s`). `sig` is the signature chosen among a field's overloads. `rt` is the result
 *     type. A property access IS a call of `get_x`/`set_x`; an abstract operator, `@:from` or `@:to` is a call of the
 *     implementation class's static. `o`: of a call handing its first argument to a `Dynamic` parameter, that argument's
 *     type, with `x` when it is an object of exactly the class its type names, as a converted operand (`strs`) is: no
 *     flow names a value of the parameter's own type, and a spliced call's argument lies in the text of another method.
 *   - `news`: `{t, ty, p}` — the class and the instance type.
 *   - `fields`: `{f, a, o?, r, t, p, w?, u?, m?, fresh?}` — a field read (a write when `w`) that is not a callee; `o` is
 *     the declaring type, absent for a structure or a dynamic access. A read has `u`, how its value is used: `call` (the
 *     receiver of a call, `m` the called field), `index` (an array indexed to read), `elemWrite` (an array indexed to
 *     write, see `elems`), `member` (the receiver of a field read that is no method closure), `memberWrite` (the
 *     receiver of a field write), `compare` (an operand of a comparison, a `switch` subject), `iter` (the iterated value
 *     of a kept `for`), `update` (the read half of a compound assignment or increment of the field) or `value` — anything
 *     else: an argument, a stored, returned or thrown value, a method closure's receiver, a discarded value. A read the
 *     compiler holds in a local — a lowered loop's array, a compound element write's receiver — or that a local is
 *     initialized with, is used as the local is read: one fact per distinct use, all at the read's position, `value` for
 *     a local never read or read from a nested function. A write has `fresh` when every value its right side produces is
 *     an array literal, a `new Array` or `null` and the assignment's own value is discarded: the field alone holds it.
 *   - `elems`: `{r, rp, p}` — an element write `a[i] = v`, `a[i] += v` or `a[i]++`, on any receiver; `r`/`rp` are the
 *     array's type and position, which is its own read's, as a call's `rp` is: a `fields` read (`u` = `elemWrite`), a
 *     `reads` entry, a call.
 *   - `flows`: `{s, d, c, p, x?}` — a value of type `s` reaching a place of type `d`, `c` being `var`, `assign`, `arg`,
 *     `ret`, `arr`, `obj`, `throw` or `cast` (an unchecked cast, always kept). A branching value flows once per branch
 *     at the branch's own type; a place of no type is `Dynamic`, and so is every argument of a callee of no function
 *     type; each rest argument flows into the rest element type. Otherwise kept only when the types differ beyond `Null<>`.
 *     `x`: the value is an object of exactly the class its type names, as a converted operand's (`strs`) is.
 *   - `hands`: `{t, s, d, p}` — a value of type `s` handed to `t`, a field of an extern class (target code, which no fact
 *     describes), at a parameter it declares of type `d`, its own type parameters unapplied: one per value-producing leaf
 *     of each argument of a call, a construction or a super constructor call, a rest argument at the rest element type.
 *   - `gens`: `{d, s, p}` — a field declaring type parameters of its own (a generic method), read or called: its declared
 *     type `d` and the type `s` the compiler instantiated it at there, which say what each of its parameters stands for.
 *   - `strs`: `{o, p, x?}` — a non-String operand of a String `+` or `+=`, and a non-String thrown value, which the
 *     exception wrapping the compiler adds after typing hands to `Std.string` (`haxe.ValueException`) — unless it is an
 *     object of exactly a class extending `haxe.Exception`, which it throws as it is. `x`: the operand is an object of
 *     exactly the class its type names — a construction, or a local initialized with one of its own type and never
 *     written again.
 *   - `iters`: `{v, i, p}` — a `for` the compiler kept (it lowers an Array loop to a `while` and unrolls a constant one).
 *   - `refl`: `{t, n?, c?, v?, r?, x?, h?, p}` — a `Reflect.*`/`Type.*` call, its first literal string and its first type
 *     argument; `v` when the member, or the class itself, is read as a value — whatever calls it later is reflection. `r` is
 *     the type of its first argument — the object an access by name acts on — with `x` when that is an object of exactly
 *     the class its type names, `h` when it is `this`.
 *   - `native`: `{w, n, p}` — `syntax` for a `*.Syntax` call, `ident` for every native identifier, read or called.
 *   - `vars`: `{n, t, p}` — a local or loop binder (compiler temporaries are left out).
 *   - `reads`: `[min, max, type]` (foreign: `[i, min, max, type]`) — a read of a local, at the identifier.
 *   - `exps`: `{p, a, t?, d?}` — code spliced in where no inlined method is declared, rooted at `p`: in the body's own
 *     code, and in the code of a method an inlined call spliced in when a macro is declared around it. `t` is the macro
 *     method declared around the root and `d` its declared range, which holds the code it built; `a` is the innermost
 *     expression around the root of the code it was written in — the body's, or the spliced method's — where the
 *     compiler replaced the call of the macro. Without `t`, no macro is declared there either.
 *   - `fns`: the node ids of the functions nested directly in this one.
 *
 * ## Markers (`inc`) — what a consumer answers Unknown for
 *
 * - `inline-site-unknown`: a body was spliced in; its facts are the node's but no range says where they run, so a range
 *   query not covering the whole node is Unknown — unless it reads them by the `s` and `d` of their `inlined` calls.
 * - `macro-expansion`: a spliced body no method could be matched to — an expression macro's expansion, or
 *   an inlined piece that carries only its declaring type's range (an abstract's `this`); as above, and no callee is named.
 *   Each such body is an `exps` record.
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
		{ path: 'anyparse/check/TypedFactsShapes.hx', text: EmbeddedSource.text('anyparse/check/TypedFactsShapes.hx') },
		{ path: 'anyparse/check/FactsTypeText.hx', text: EmbeddedSource.text('anyparse/check/FactsTypeText.hx') }
	];

	/**
	 * The table over every configuration of `oracles` that answered, each compiled once (the compiles overlap):
	 * `start` and `finish` in one step.
	 */
	public static function probeAll(oracles: Array<OracleConfig>): Null<CompilerFacts> {
		return finish(start(oracles));
	}

	/**
	 * `probeAll` started in the BACKGROUND: the compiles — and in a run that remembers, the baseline of the same tree
	 * beside each (`wanted`) — run while the caller goes on; `finish` answers the table, `abandon` ends them unread. A lint
	 * run that expects to be asked starts them before its first pass, so they overlap the checks instead of following the
	 * first check that asks.
	 */
	public static function start(oracles: Array<OracleConfig>): FactsProbe {
		final dropped: Array<{ name: String, reason: String }> = [];
		final asked: Array<FactsCompile> = [];
		#if (sys || nodejs)
		for (i in 0...oracles.length) {
			final prepared: Null<FactsCompile> = prepare(oracles[i], i);
			if (prepared != null)
				asked.push(prepared)
			else
				dropped.push({
					name: OracleDeclaration.describeOracle(oracles[i]),
					reason: oracles[i].unavailable ?? 'its probe directory could not be written'
				});
		}
		final memo: Null<OracleRunMemo> = OracleRunMemo.of(oracles);
		final baselines: Array<OracleConfig> = memo == null ? [] : [for (a in asked) a.oracle];
		final before: Array<Null<String>> = memo == null ? [] : memo.fingerprints(baselines);
		final ahead: Array<Int> = memo == null ? [] : [for (k in 0...baselines.length) if (wanted(memo, baselines[k], before[k])) k];
		final runs: PendingRuns = HaxeSpawn.startAll([for (a in asked) { args: a.args, cwd: a.oracle.dir }].concat([
			for (k in ahead) { args: OracleCoverage.probeArgs(baselines[k].hxml, baselines[k].defines), cwd: baselines[k].dir }
		]), BUFFER, HaxeSpawn.parallelism());
		return {
			dropped: dropped,
			asked: asked,
			memo: memo,
			baselines: [for (k in ahead) baselines[k]],
			before: [for (k in ahead) before[k]],
			runs: runs
		};
		#else
		return {
			dropped: dropped,
			asked: asked,
			memo: null,
			baselines: [],
			before: [],
			runs: null
		};
		#end
	}

	/**
	 * The table `probe` compiled, blocking until its compiles ended: every configuration that answered, with the rest in
	 * its `dropped` and why; null only on a target that cannot spawn a compile. A compile that reported an error is dropped
	 * even when it wrote a complete file: typing goes on past an error, and what it recovers with — an unbound monomorph, a
	 * branch left out — reads exactly like a fact, so the table could not tell the two apart. The files are read and added
	 * one at a time, so no two dumps are held at once. The baselines compiled beside are filed in the run's memo.
	 */
	public static function finish(probe: FactsProbe): Null<CompilerFacts> {
		#if (sys || nodejs)
		final pending: Null<PendingRuns> = probe.runs;
		if (pending == null) return null;
		final runs: Array<HaxeRun> = pending.await();
		final asked: Array<FactsCompile> = probe.asked;
		final memo: Null<OracleRunMemo> = probe.memo;
		if (memo != null && probe.baselines.length > 0) {
			final after: Array<Null<String>> = memo.fingerprints(probe.baselines);
			for (j in 0...probe.baselines.length) memo.file(probe.baselines[j], true, probe.before[j], after[j], runs[asked.length + j]);
		}
		final facts: CompilerFacts = CompilerFacts.create(
			file -> try sys.io.File.getContent(file) catch (exception: haxe.Exception) null, memoised(Sys.getCwd())
		);
		for (d in probe.dropped) facts.dropped.push(d);
		for (i in 0...asked.length) {
			final dump: Null<FactsDump> = answer(asked[i].oracle, runs[i], asked[i].out);
			if (dump != null)
				facts.add(dump)
			else
				facts.dropped.push({ name: OracleDeclaration.describeOracle(asked[i].oracle), reason: failureOf(runs[i]) });
			discard(asked[i].dir);
		}
		return facts;
		#else
		return null;
		#end
	}

	/** End `probe`'s compiles unread and delete what they were given — a run that was never asked for the facts. */
	public static function abandon(probe: FactsProbe): Void {
		probe.runs?.cancel();
		#if (sys || nodejs)
		for (a in probe.asked) discard(a.dir);
		#end
	}

	/**
	 * Whether the facts compile of `oracle` should bring its baseline typecheck along: the run will ask for one of the tree
	 * as it is now, the memo holds none, and it is not a run that answers baselines from the persisted cache, which
	 * already holds one for this input. The baseline is the `-v` compile, so the coverage probe of the same tree reuses it.
	 */
	private static function wanted(memo: OracleRunMemo, oracle: OracleConfig, fingerprint: Null<String>): Bool {
		if (fingerprint == null || memo.holds(oracle, fingerprint)) return false;
		if (!memo.persisted) return true;
		// the persisted cache files a verdict under its own fingerprint, not the run's
		final persisted: Null<String> = OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines);
		return persisted == null || OracleCache.lookup(oracle.hxml, oracle.dir, persisted, oracle.defines) == null;
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
	private static function prepare(oracle: OracleConfig, index: Int): Null<FactsCompile> {
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
		return { name: OracleDeclaration.describeOracle(oracle), text: text, file: memoised(oracle.dir ?? Sys.getCwd()) };
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

/** One configuration's facts compile: its probe directory, the file the hook writes, and the compile's arguments. */
typedef FactsCompile = {
	var oracle: OracleConfig;
	var dir: String;
	var out: String;
	var args: Array<String>;
}

/**
 * The facts compiles `TypedFactsProbe.start` left running, and what `finish` needs to read them: the configurations
 * dropped before any compile, the compiles in job order, and — in a run that remembers — the baselines compiled after
 * them in the same batch with the fingerprint each input had when it started. `runs` is null on a target that cannot
 * spawn a compile.
 */
typedef FactsProbe = {
	var dropped: Array<{ name: String, reason: String }>;
	var asked: Array<FactsCompile>;
	var memo: Null<OracleRunMemo>;
	var baselines: Array<OracleConfig>;
	var before: Array<Null<String>>;
	var runs: Null<PendingRuns>;
}

package anyparse.check;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.query.HaxelibResolver;
import haxe.io.Path;

using Lambda;
using StringTools;

/** The tokens of one hxml text a library build is read from (`LibraryBuild.tokens`). */
typedef HxmlTokens = {
	final classPaths: Array<String>;
	final libs: Array<String>;

	/** Each `-D` as written: `name` or `name=value`. */
	final defines: Array<String>;

	final includes: Array<String>;

	/** The target the hxml compiles to (`cpp`, `js`, …), null when it names none. */
	final target: Null<String>;
}

/**
 * The ONE shipped build whose libraries `thread-safety` walks the bodies of (`LibraryBodies`), read off its hxml with no
 * compile: the library classpaths — each `-cp` holding no file of the run, and each `-lib` (`HaxelibResolver`) — and the
 * defines that decide those libraries' conditional compilation: the hxml's `-D`s (a dash read as the underscore a
 * condition spells), the `defines` of the `compilerOracle` entry naming the hxml, the ones the compiler sets for the
 * target, and the compiler version's (`haxe -version`). A define an initialization macro sets that none of those name is
 * not seen, so the read is the shipped build's as far as its hxml says, no further.
 */
@:nullSafety(Strict)
final class LibraryBuild {

	/** The defines the Haxe compiler (4.3) sets for each target, a value after `=`. */
	public static final TARGET_DEFINES: Map<String, Array<String>> = [
		'cpp' => [
			'cpp',
			'sys',
			'target.sys',
			'target.static',
			'target.threaded',
			'target.unicode',
			'target.name=cpp'
		],
		'hl' => [
			'hl',
			'sys',
			'target.sys',
			'target.static',
			'target.threaded',
			'target.unicode',
			'target.utf16',
			'target.name=hl'
		],
		'js' => ['js', 'target.unicode', 'target.utf16', 'target.name=js'],
		'neko' => ['neko', 'sys', 'target.sys', 'target.threaded', 'target.name=neko'],
		'interp' => [
			'interp',
			'eval',
			'sys',
			'target.sys',
			'target.threaded',
			'target.unicode',
			'target.name=eval'
		]
	];

	/** The hxml flags that pick a target. */
	private static final TARGET_FLAGS: Map<String, String> = [
		'-cpp' => 'cpp',
		'--cpp' => 'cpp',
		'-hl' => 'hl',
		'--hl' => 'hl',
		'-js' => 'js',
		'--js' => 'js',
		'-neko' => 'neko',
		'--neko' => 'neko',
		'--interp' => 'interp'
	];

	/** The package names, and file-name suffixes, the compiler reserves for one target each. */
	public static final TARGET_PACKAGES: Array<String> = [
		'cpp', 'cs', 'eval', 'flash', 'hl', 'java', 'js', 'jvm', 'lua', 'neko', 'php', 'python'
	];

	/** The digits `haxe_ver` gives the patch number (`4.3.7` is `4.307`). */
	private static inline final PATCH_DIGITS: Int = 2;

	/** The first major version the compiler defines `haxe<major>` for (`haxe3`, `haxe4`). */
	private static inline final FIRST_MAJOR_DEFINE: Int = 3;

	/** How deep an hxml include chain is followed. */
	private static inline final MAX_INCLUDES: Int = 16;

	/** The buffer `haxe -version` answers into. */
	private static inline final VERSION_BUFFER: Int = 64 * 1024;

	/** The absolute library source directories, each once. */
	public final classPaths: Array<String>;

	/** Every define the build sets, by the name a condition spells. */
	public final defined: Array<String>;

	/** The value of each define of `defined` that has one. */
	public final values: Map<String, String>;

	/** The target the build compiles to, null when its hxml names none. */
	public final target: Null<String>;

	public function new(classPaths: Array<String>, defined: Array<String>, values: Map<String, String>, target: Null<String>) {
		this.classPaths = classPaths;
		this.defined = defined;
		this.values = values;
		this.target = target;
	}

	/** The `-cp` / `-lib` / `-D` / include / target tokens of one hxml's text; a `#` line is a comment. Pure. */
	public static function tokens(text: String): HxmlTokens {
		final classPaths: Array<String> = [];
		final libs: Array<String> = [];
		final defines: Array<String> = [];
		final includes: Array<String> = [];
		var target: Null<String> = null;
		for (rawLine in text.split('\n')) {
			final line: String = rawLine.trim();
			if (line == '' || line.startsWith('#')) continue;
			final words: Array<String> = [for (w in line.replace('\t', ' ').split(' ')) if (w != '') w];
			var i: Int = 0;
			while (i < words.length) {
				final word: String = words[i];
				final value: Null<String> = i + 1 < words.length ? words[i + 1] : null;
				final picked: Null<String> = TARGET_FLAGS[word];
				if (picked != null) target = picked;
				switch word {
					case '-cp', '-p', '--class-path':
						if (value != null) classPaths.push(value);
						i += 2;
					case '-lib', '-L', '--library':
						if (value != null) libs.push(value.split(':')[0]);
						i += 2;
					case '-D', '--define':
						if (value != null) defines.push(value);
						i += 2;
					case _:
						if (!word.startsWith('-') && word.endsWith('.hxml')) includes.push(word);
						i++;
				}
			}
		}
		return {
			classPaths: classPaths,
			libs: libs,
			defines: defines,
			includes: includes,
			target: target
		};
	}

	/** Records the define `spec` (`name` or `name=value`) in `defined` and `values`, its name as a condition spells it. */
	public static function addDefine(spec: String, defined: Array<String>, values: Map<String, String>): Void {
		final eq: Int = spec.indexOf('=');
		final name: String = (eq < 0 ? spec : spec.substring(0, eq)).replace('-', '_');
		if (name == '') return;
		if (!defined.contains(name)) defined.push(name);
		if (eq >= 0) values[name] = spec.substring(eq + 1);
	}

	/**
	 * Whether a build for `target` may compile the file at `relative` — its path under its classpath, `/`-separated: never
	 * one in another target's package (`php/db/Mysqli.hx`) or named for another target (`Mysql.php.hx`), nor one a copy
	 * named for `target` stands in for (`Mysql.hx` beside `Mysql.cpp.hx`, which `hasFile` answers). Pure.
	 */
	public static function compiles(relative: String, target: Null<String>, hasFile: (String) -> Bool): Bool {
		final own: Null<String> = target == 'interp' ? 'eval' : target;
		final slash: Int = relative.indexOf('/');
		if (slash > 0 && TARGET_PACKAGES.contains(relative.substring(0, slash)) && relative.substring(0, slash) != own) return false;
		final parts: Array<String> = Path.withoutDirectory(relative).split('.');
		if (parts.length == 3 && TARGET_PACKAGES.contains(parts[1])) return parts[1] == own;
		final dir: String = Path.directory(relative);
		return own == null || !hasFile((dir == '' ? '' : '$dir/') + '${parts[0]}.$own.hx');
	}

	/** The defines the compiler of version `version` (`4.3.7`) sets: `haxe`, `haxe_ver` (`4.307`) and `haxe<major>`. */
	public static function versionDefines(version: String): Array<String> {
		final parts: Array<Null<Int>> = [for (p in version.split('.')) Std.parseInt(p)];
		final major: Null<Int> = parts[0];
		final minor: Null<Int> = parts.length > 1 ? parts[1] : null;
		final patch: Null<Int> = parts.length > 2 ? parts[2] : null;
		if (parts.length != 3 || major == null || minor == null || patch == null) return [];
		final out: Array<String> = [
			'haxe=$version',
			'haxe_ver=$major.$minor${'$patch'.lpad('0', PATCH_DIGITS)}'
		];
		for (m in FIRST_MAJOR_DEFINE ... major + 1) out.push('haxe$m');
		return out;
	}

	#if (sys || nodejs)
	/**
	 * The build `oracle` describes, its libraries those of its classpaths that hold none of `runFiles`; null, with the
	 * reason in `problems`, when its hxml cannot be read.
	 */
	public static function read(oracle: OracleConfig, runFiles: Array<String>, problems: Array<String>): Null<LibraryBuild> {
		final root: String = oracle.dir ?? Path.directory(oracle.hxml);
		final chain: Null<HxmlTokens> = readChain(root, absolute(root, oracle.hxml), problems);
		if (chain == null) return null;
		final target: Null<String> = chain.target;
		final implicit: Array<String> = target == null ? [] : TARGET_DEFINES[target] ?? [target];
		final defined: Array<String> = [];
		final values: Map<String, String> = [];
		for (d in chain.defines.concat(oracle.defines).concat(implicit).concat(versionDefines(compilerVersion())))
			addDefine(d, defined, values);
		final classPaths: Array<String> = [for (cp in chain.classPaths) absolute(root, cp)];
		// a library or a classpath the build names and the run cannot find is one whose bodies go unread: said, by name
		for (lib in chain.libs) {
			final dir: Null<String> = HaxelibResolver.libSourceDir(lib);
			if (dir != null)
				classPaths.push(dir)
			else
				problems.push(
					'libraryBodies: the library "-lib $lib" of "${oracle.hxml}" does not resolve (haxelib) — its bodies are not walked'
				);
		}
		final run: Array<String> = [for (f in runFiles) absolute(Sys.getCwd(), f)];
		final libraries: Array<String> = [];
		for (cp in classPaths) if (!libraries.contains(cp)) {
			if (!sys.FileSystem.exists(cp))
				problems.push('libraryBodies: the classpath "$cp" of "${oracle.hxml}" does not exist — nothing under it is walked')
			else if (!run.exists(f -> f.startsWith('$cp/')))
				libraries.push(cp);
		}
		return new LibraryBuild(libraries, defined, values, target);
	}

	/** `path` absolute against `root`, normalised, with no trailing slash. */
	private static function absolute(root: String, path: String): String {
		final full: String = Path.normalize(Path.isAbsolute(path) ? path : Path.join([sys.FileSystem.absolutePath(root), path]));
		return full.length > 1 && full.endsWith('/') ? full.substr(0, full.length - 1) : full;
	}

	/** What `haxe -version` answers (`4.3.7`), or '' when it cannot be run. */
	private static function compilerVersion(): String {
		final run: HaxeSpawn.HaxeRun = HaxeSpawn.run(['-version'], null, VERSION_BUFFER);
		final text: String = (run.out.trim() == '' ? run.err : run.out).trim();
		final cut: Int = text.indexOf('+');
		return cut < 0 ? text : text.substring(0, cut);
	}

	/**
	 * The tokens of the hxml `hxml` and of every hxml it includes (each resolved against `root`), merged; null, with the
	 * reason in `problems`, when one cannot be read.
	 */
	private static function readChain(root: String, hxml: String, problems: Array<String>): Null<HxmlTokens> {
		final queue: Array<String> = [hxml];
		final classPaths: Array<String> = [];
		final libs: Array<String> = [];
		final defines: Array<String> = [];
		var target: Null<String> = null;
		var i: Int = 0;
		while (i < queue.length && i < MAX_INCLUDES) {
			final path: String = queue[i++];
			final text: Null<String> = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
			if (text == null) {
				problems.push('libraryBodies: cannot read the hxml "$path" — no library body is walked');
				return null;
			}
			final read: HxmlTokens = tokens(text);
			target = read.target ?? target;
			for (cp in read.classPaths) classPaths.push(cp);
			for (lib in read.libs) libs.push(lib);
			for (d in read.defines) defines.push(d);
			for (inc in read.includes) queue.push(absolute(root, inc));
		}
		return {
			classPaths: classPaths,
			libs: libs,
			defines: defines,
			includes: queue.slice(1),
			target: target
		};
	}
	#end

}

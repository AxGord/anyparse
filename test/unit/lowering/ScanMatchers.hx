package unit.lowering;

import haxe.io.Path;
import haxe.macro.Expr;
import sys.FileSystem;

/**
 * Compiles every `@:re` terminal under a package with the generated parsers' own `TerminalScanLowering`, so a test
 * on js runs the code the static targets run. What needs the macro context sits in the macro body, the one place
 * only that context types.
 */
class ScanMatchers {

	/**
	 * One `ScanMatcher` per `@:re` terminal declared under `pack` on the class path, in path order. Its `scan` answers
	 * the end of the match the compiled scan finds from `start`, -1 for none, and is null when `RegexScanPlan` refuses
	 * the pattern.
	 */
	public static macro function under(pack: String): Expr {
		final entries: Array<Expr> = [];
		for (path in modulesUnder(haxe.macro.Context.getClassPath(), pack)) for (type in haxe.macro.Context.getModule(path)) {
			final found: Null<{ name: String, pattern: String }> = terminalOf(type);
			if (found == null) continue;
			final plan: Null<anyparse.macro.ScanNode> = anyparse.macro.RegexScanPlan.of(found.pattern);
			final scan: Expr = plan == null ? macro null : {
				final body: Expr = anyparse.macro.TerminalScanLowering.scan(plan, macro _input, macro _start, macro return _hit ? _p : -1);
				macro (_input: anyparse.runtime.Input, _start: Int) -> $body;
			};
			entries.push(macro ({ name: $v{found.name}, pattern: $v{found.pattern}, scan: $scan }: unit.lowering.ScanMatcher));
		}
		return macro $a{entries};
	}

	/** The modules under `pack` in `classPath` whose source declares a `@:re` terminal, sorted. */
	private static function modulesUnder(classPath: Array<String>, pack: String): Array<String> {
		final out: Array<String> = [];
		for (root in classPath) {
			final dir: String = Path.join([root == '' ? '.' : root, pack.split('.').join('/')]);
			if (FileSystem.exists(dir) && FileSystem.isDirectory(dir)) collect(dir, pack, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	private static function collect(dir: String, pack: String, out: Array<String>): Void {
		for (name in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (FileSystem.isDirectory(path))
				collect(path, '$pack.$name', out)
			else if (Path.extension(name) == 'hx' && sys.io.File.getContent(path).indexOf('@:re(') >= 0)
				out.push('$pack.${Path.withoutExtension(name)}');
		}
	}

	/** The name and `@:re` pattern of `type` when it is an abstract carrying one. */
	private static function terminalOf(type: haxe.macro.Type): Null<{ name: String, pattern: String }> {
		final a: Null<haxe.macro.Type.AbstractType> = switch type {
			case TAbstract(ref, _): ref.get();
			case _: null;
		};
		if (a == null) return null;
		final re: Array<MetadataEntry> = a.meta.extract(':re');
		final params: Null<Array<Expr>> = re.length == 0 ? null : re[0].params;
		if (params == null || params.length == 0) return null;
		return switch params[0].expr {
			case EConst(CString(pattern, _)): { name: a.name, pattern: pattern };
			case _: null;
		};
	}

}

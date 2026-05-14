package anyparse.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import haxe.Exception;

#if sys
import sys.io.File;
#end

/**
 * `apq` CLI entry point. Parses argv, picks a grammar plugin via
 * `--lang`, dispatches on the subcommand.
 *
 * Phase 1 surface: `apq ast <file> [--lang L] [--json] [--depth N]
 * [--select PATH] [--at LINE:COL]`. Other subcommands (`search`,
 * `refs`, `meta`) are reserved — calling them prints a "deferred"
 * notice with the phase that owns each.
 */
@:nullSafety(Strict)
final class Cli {

	private static final EXIT_OK:Int = 0;
	private static final EXIT_USAGE:Int = 2;
	private static final EXIT_RUNTIME:Int = 1;

	public static function main():Void {
		#if sys
		Sys.exit(run(Sys.args()));
		#else
		throw 'apq: only sys targets supported';
		#end
	}

	/** Pure-argv entry. Returns process exit code. */
	public static function run(args:Array<String>):Int {
		if (args.length == 0 || args[0] == '-h' || args[0] == '--help') {
			printUsage();
			return EXIT_OK;
		}
		final cmd:String = args[0];
		final rest:Array<String> = args.slice(1);
		switch cmd {
			case 'ast': return runAst(rest);
			case 'search', 'refs', 'meta':
				stderr('apq: subcommand "$cmd" deferred to a later phase\n');
				return EXIT_USAGE;
			case _:
				stderr('apq: unknown subcommand "$cmd"\n');
				printUsage();
				return EXIT_USAGE;
		}
	}

	private static function runAst(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var depth:Int = -1;
		var selectExpr:Null<String> = null;
		var atExpr:Null<String> = null;
		var file:Null<String> = null;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--depth':
					final v:String = expectValue(args, ++i, '--depth');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null) {
						stderr('apq ast: --depth expects an integer, got "$v"\n');
						return EXIT_USAGE;
					}
					depth = parsed;
				case '--select':
					selectExpr = expectValue(args, ++i, '--select');
				case '--at':
					atExpr = expectValue(args, ++i, '--at');
				case '-h', '--help':
					printAstUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq ast: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
						stderr('apq ast: only one file argument supported (got "$file" and "$a")\n');
						return EXIT_USAGE;
					}
					file = a;
			}
			i++;
		}

		if (file == null) {
			stderr('apq ast: missing <file> argument\n');
			printAstUsage();
			return EXIT_USAGE;
		}
		if (atExpr != null) {
			stderr('apq ast: --at deferred to a later slice (needs AST span instrumentation)\n');
			return EXIT_USAGE;
		}

		final plugin:GrammarPlugin = pickPlugin(lang);
		final source:String = readFile(file);
		final tree:QueryNode = try plugin.parseFile(source) catch (e:ParseError) {
			stderr('apq ast: $file: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq ast: $file: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		if (selectExpr != null) {
			final selector:Selector = Selector.parse(selectExpr);
			final raw:Array<QueryNode> = Engine.select(tree, selector);
			final matches:Array<QueryNode> = depth < 0 ? raw : [for (m in raw) Engine.truncate(m, depth)];
			Sys.print(json ? Json.renderMatches(file, matches) : Text.renderMatches(matches));
			return EXIT_OK;
		}

		final shaped:QueryNode = Engine.truncate(tree, depth);
		Sys.print(json ? Json.renderTree(file, shaped) : Text.render(shaped));
		return EXIT_OK;
	}

	private static function pickPlugin(lang:String):GrammarPlugin {
		return switch lang {
			case 'haxe': new HaxeQueryPlugin();
			case _: throw 'apq: no grammar plugin for --lang "$lang"';
		};
	}

	private static function readFile(path:String):String {
		#if sys
		return File.getContent(path);
		#else
		throw 'apq: file IO requires a sys target';
		#end
	}

	private static function expectValue(args:Array<String>, idx:Int, flag:String):String {
		if (idx >= args.length) throw 'apq: $flag requires a value';
		return args[idx];
	}

	private static function printUsage():Void {
		Sys.print('apq — anyparse query CLI\n');
		Sys.print('\n');
		Sys.print('Usage: apq <command> [options] <file>\n');
		Sys.print('\n');
		Sys.print('Commands:\n');
		Sys.print('  ast      Dump parsed AST (S-expr or JSON)\n');
		Sys.print('  search   Structural pattern search (deferred to Phase 2)\n');
		Sys.print('  refs     Symbol references with scope (deferred to Phase 3)\n');
		Sys.print('  meta     Annotation-on-decl shortcut (deferred to Phase 4)\n');
		Sys.print('\n');
		Sys.print('Global options:\n');
		Sys.print('  --lang <name>   Pick grammar plugin (default: haxe)\n');
		Sys.print('  -h, --help      Show help\n');
	}

	private static function printAstUsage():Void {
		Sys.print('Usage: apq ast [options] <file>\n');
		Sys.print('\n');
		Sys.print('Options:\n');
		Sys.print('  --json              Emit JSON instead of S-expr\n');
		Sys.print('  --depth <n>         Truncate beyond depth n\n');
		Sys.print('  --select <path>     Subtree(s) matching a selector (e.g. "ClassDecl > FnDecl:foo")\n');
		Sys.print('  --at <line>:<col>   Smallest enclosing node (deferred)\n');
		Sys.print('  --lang <name>       Grammar plugin (default: haxe)\n');
	}

	private static function stderr(s:String):Void {
		#if sys
		Sys.stderr().writeString(s);
		#end
	}
}

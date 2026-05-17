package anyparse.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta.MetaHit;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

#if (sys || nodejs)
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
		#if (sys || nodejs)
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
			case 'search': return runSearch(rest);
			case 'refs': return runRefs(rest);
			case 'meta': return runMeta(rest);
			case _:
				stderr('apq: unknown subcommand "$cmd"\n');
				printUsage();
				return EXIT_USAGE;
		}
	}

	private static function runRefs(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var wantDecls:Bool = false;
		var wantReads:Bool = false;
		var wantWrites:Bool = false;
		var name:Null<String> = null;
		var inputSpec:Null<String> = null;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--decls':
					wantDecls = true;
				case '--reads':
					wantReads = true;
				case '--writes':
					wantWrites = true;
				case '-h', '--help':
					printRefsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq refs: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null) {
						name = a;
					} else if (inputSpec == null) {
						inputSpec = a;
					} else {
						stderr('apq refs: extra positional argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (name == null) {
			stderr('apq refs: missing <name> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		if (inputSpec == null) {
			stderr('apq refs: missing <file-or-glob> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		final nameStr:String = name;
		final inputStr:String = inputSpec;
		// No flag = no filter (emit every hit). Any flag flips on the
		// allow-set; sister CLIs (`git log --author --grep`) follow the
		// same any-flag-narrows convention.
		final anyFilter:Bool = wantDecls || wantReads || wantWrites;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:RefShape = plugin.refShape();

		final paths:Array<String> = Glob.expand(inputStr, '.hx');
		if (paths.length == 0) {
			stderr('apq refs: no input files matched "$inputStr"\n');
			return EXIT_RUNTIME;
		}

		final allEntries:Array<{file:String, source:String, hits:Array<RefHit>}> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = try plugin.parseFile(source)
				catch (e:ParseError) {
					stderr('apq refs: $path: ${e.toString()}\n');
					null;
				}
				catch (e:Exception) {
					stderr('apq refs: $path: ${e.message}\n');
					null;
				};
			if (tree == null) continue;
			final raw:Array<RefHit> = Refs.find(nameStr, tree, shape);
			final filtered:Array<RefHit> = anyFilter
				? raw.filter(h -> kindAllowed(h.kind, wantDecls, wantReads, wantWrites))
				: raw;
			if (filtered.length == 0) continue;
			allEntries.push({file: path, source: source, hits: filtered});
		}

		if (json) {
			sysPrint(Json.renderRefs(allEntries));
		} else {
			for (entry in allEntries) sysPrint(Text.renderRefs(entry.file, entry.source, entry.hits));
		}
		return EXIT_OK;
	}

	private static function runMeta(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var argContains:Null<String> = null;
		var onKind:Null<String> = null;
		final positionals:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--arg-contains':
					argContains = expectValue(args, ++i, '--arg-contains');
				case '--on':
					onKind = expectValue(args, ++i, '--on');
				case '-h', '--help':
					printMetaUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq meta: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					positionals.push(a);
			}
			i++;
		}

		// Positional grammar: [<annotation>] <file-or-glob>. With `--on`
		// the annotation may be omitted (list every annotation on a kind).
		if (positionals.length == 0) {
			stderr('apq meta: missing <file-or-glob> argument\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		if (positionals.length > 2) {
			stderr('apq meta: extra positional argument "${positionals[2]}"\n');
			return EXIT_USAGE;
		}
		final inputStr:String = positionals[positionals.length - 1];
		final annotation:Null<String> = positionals.length == 2 ? positionals[0] : null;
		if (annotation == null && onKind == null) {
			// One bare positional with no `--on`: ambiguous — it is taken
			// as the <file-or-glob>, leaving no annotation/kind to scope
			// the query. Spell out both halves the grammar needs.
			stderr('apq meta: need an <annotation> or --on <decl-kind>, plus a <file-or-glob>\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:MetaShape = plugin.metaShape();

		final paths:Array<String> = Glob.expand(inputStr, '.hx');
		if (paths.length == 0) {
			stderr('apq meta: no input files matched "$inputStr"\n');
			return EXIT_RUNTIME;
		}

		final allEntries:Array<{file:String, source:String, hits:Array<MetaHit>}> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = try plugin.parseFile(source)
				catch (e:ParseError) {
					stderr('apq meta: $path: ${e.toString()}\n');
					null;
				}
				catch (e:Exception) {
					stderr('apq meta: $path: ${e.message}\n');
					null;
				};
			if (tree == null) continue;
			final raw:Array<MetaHit> = Meta.find(tree, shape, source);
			final filtered:Array<MetaHit> = raw.filter(h ->
				(annotation == null || h.annotation == annotation)
				&& argMatches(h.args, argContains)
				&& (onKind == null || h.declKind == onKind));
			if (filtered.length == 0) continue;
			allEntries.push({file: path, source: source, hits: filtered});
		}

		if (json) {
			sysPrint(Json.renderMeta(allEntries));
		} else {
			for (entry in allEntries) sysPrint(Text.renderMeta(entry.file, entry.source, entry.hits));
		}
		return EXIT_OK;
	}

	private static function argMatches(args:Array<String>, sub:Null<String>):Bool {
		if (sub == null) return true;
		final needle:String = sub;
		for (a in args) if (a.indexOf(needle) >= 0) return true;
		return false;
	}

	private static inline function kindAllowed(k:RefKind, decls:Bool, reads:Bool, writes:Bool):Bool {
		return switch k {
			case Decl: decls;
			case Read: reads;
			case Write: writes;
		}
	}

	private static function runSearch(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var pattern:Null<String> = null;
		var inputSpec:Null<String> = null;

		// `--` is the standard end-of-options sentinel: every token after
		// it is positional, never an option. A search pattern can legally
		// start with `--` (`--$x` = prefix-decrement), which would
		// otherwise be rejected as an unknown option — the sentinel is the
		// only way to reach those patterns.
		var optsEnded:Bool = false;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			var isOption:Bool = false;
			if (!optsEnded) {
				isOption = true;
				switch a {
					case '--lang':
						lang = expectValue(args, ++i, '--lang');
					case '--json':
						json = true;
					case '-h', '--help':
						printSearchUsage();
						return EXIT_OK;
					case '--':
						optsEnded = true;
					case _:
						if (StringTools.startsWith(a, '--')) {
							stderr('apq search: unknown option "$a"\n');
							return EXIT_USAGE;
						}
						isOption = false;
				}
			}
			if (!isOption) {
				if (pattern == null) {
					pattern = a;
				} else if (inputSpec == null) {
					inputSpec = a;
				} else {
					stderr('apq search: extra positional argument "$a"\n');
					return EXIT_USAGE;
				}
			}
			i++;
		}
		if (pattern == null) {
			stderr('apq search: missing <pattern> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		if (inputSpec == null) {
			stderr('apq search: missing <file-or-glob> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		final patternStr:String = pattern;
		final inputStr:String = inputSpec;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final parsed:Pattern = try plugin.parsePattern(patternStr)
			catch (e:Exception) {
				stderr('apq search: pattern: ${e.message}\n');
				return EXIT_RUNTIME;
			};

		final paths:Array<String> = Glob.expand(inputStr, '.hx');
		if (paths.length == 0) {
			stderr('apq search: no input files matched "$inputStr"\n');
			return EXIT_RUNTIME;
		}

		final allMatches:Array<Match> = [];
		final allEntries:Array<{file:String, source:String, matches:Array<Match>}> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = try plugin.parseFile(source)
				catch (e:ParseError) {
					stderr('apq search: $path: ${e.toString()}\n');
					null;
				}
				catch (e:Exception) {
					stderr('apq search: $path: ${e.message}\n');
					null;
				};
			if (tree == null) continue;
			final matches:Array<Match> = Matcher.search(parsed, tree);
			if (matches.length == 0) continue;
			allEntries.push({file: path, source: source, matches: matches});
			for (m in matches) allMatches.push(m);
		}

		if (json) {
			final combined:StringBuf = new StringBuf();
			combined.add('{"matches":[');
			var first:Bool = true;
			for (entry in allEntries) {
				for (m in entry.matches) {
					if (!first) combined.add(',');
					first = false;
					combined.add(perMatchJson(entry.file, entry.source, m));
				}
			}
			combined.add(']}\n');
			sysPrint(combined.toString());
		} else {
			for (entry in allEntries) sysPrint(Text.renderSearchMatches(entry.file, entry.source, entry.matches));
		}
		return EXIT_OK;
	}

	private static function perMatchJson(file:String, source:String, m:Match):String {
		// Render a single match through the macro-generated writer by
		// wrapping it in a singleton envelope, then slicing the inner
		// JSON object out. Keeps every entry typed through the same path
		// as the multi-match render — no separate stringify code.
		final rendered:String = Json.renderSearchMatches(file, source, [m]);
		// Strip the `{"matches":[` prefix and `]}\n` suffix to get the
		// bare match object for inclusion in the multi-file array.
		final inner:String = StringTools.trim(rendered);
		final openIdx:Int = inner.indexOf('[');
		final closeIdx:Int = inner.lastIndexOf(']');
		if (openIdx < 0 || closeIdx <= openIdx) return rendered;
		return inner.substring(openIdx + 1, closeIdx);
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
		final plugin:GrammarPlugin = pickPlugin(lang);
		final source:String = readFile(file);
		final tree:QueryNode = try plugin.parseFile(source) catch (e:ParseError) {
			stderr('apq ast: $file: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq ast: $file: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		if (atExpr != null) {
			final colonIdx:Int = atExpr.indexOf(':');
			if (colonIdx < 0) {
				stderr('apq ast: --at expects LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			final atLine:Null<Int> = Std.parseInt(atExpr.substring(0, colonIdx));
			final atCol:Null<Int> = Std.parseInt(atExpr.substring(colonIdx + 1));
			if (atLine == null || atCol == null) {
				stderr('apq ast: --at expects integer LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			// Capture into non-null locals immediately after the null
			// check — Strict narrows locals, not the Null<Int> bindings,
			// and `Span.offsetOf` takes plain Int.
			final atLineN:Int = atLine;
			final atColN:Int = atCol;
			if (atLineN < 1 || atColN < 1) {
				stderr('apq ast: --at expects 1-indexed LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			final offset:Int = Span.offsetOf(source, atLineN, atColN);
			final node:Null<QueryNode> = Engine.at(tree, offset);
			final matches:Array<QueryNode> = node == null ? [] : [depth < 0 ? node : Engine.truncate(node, depth)];
			sysPrint(json ? Json.renderMatches(file, source, matches) : Text.renderMatches(matches));
			return EXIT_OK;
		}

		if (selectExpr != null) {
			final selector:Selector = Selector.parse(selectExpr);
			final raw:Array<QueryNode> = Engine.select(tree, selector);
			final matches:Array<QueryNode> = depth < 0 ? raw : [for (m in raw) Engine.truncate(m, depth)];
			sysPrint(json ? Json.renderMatches(file, source, matches) : Text.renderMatches(matches));
			return EXIT_OK;
		}

		final shaped:QueryNode = Engine.truncate(tree, depth);
		sysPrint(json ? Json.renderTree(file, source, shaped) : Text.render(shaped));
		return EXIT_OK;
	}

	private static function pickPlugin(lang:String):GrammarPlugin {
		return switch lang {
			case 'haxe': new HaxeQueryPlugin();
			case _: throw 'apq: no grammar plugin for --lang "$lang"';
		};
	}

	private static function readFile(path:String):String {
		#if (sys || nodejs)
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
		sysPrint('apq — anyparse query CLI\n');
		sysPrint('\n');
		sysPrint('Usage: apq <command> [options] <file>\n');
		sysPrint('\n');
		sysPrint('Commands:\n');
		sysPrint('  ast      Dump parsed AST (S-expr or JSON)\n');
		sysPrint('  search   Structural pattern search\n');
		sysPrint('  refs     Symbol references (name-only; scope-aware in Phase 3.2)\n');
		sysPrint('  meta     Annotation-on-decl shortcut\n');
		sysPrint('\n');
		sysPrint('Global options:\n');
		sysPrint('  --lang <name>   Pick grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show help\n');
	}

	private static function printSearchUsage():Void {
		sysPrint('Usage: apq search [options] <pattern> <file-or-dir>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of text\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint("Pattern syntax: language source with `$X` / `$_` metavars.\n");
		sysPrint("  $X      — bind a subtree; reuses must match structurally.\n");
		sysPrint("  $_      — wildcard, no binding.\n");
		sysPrint("\n");
		sysPrint("Use `--` before a pattern that starts with `--` (e.g. the\n");
		sysPrint("prefix-decrement pattern `--$x`): apq search -- '--\\$x' <file>\n");
	}

	private static function printRefsUsage():Void {
		sysPrint('Usage: apq refs [options] <name> <file-or-dir>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of text\n');
		sysPrint('  --decls             Filter to declarations\n');
		sysPrint('  --reads             Filter to read references\n');
		sysPrint('  --writes            Filter to write references (Phase 3.3)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Phase 3.1: name-only matching, no lexical scope. Filters combine\n');
		sysPrint('inclusively — passing `--decls --reads` keeps both kinds.\n');
	}

	private static function printMetaUsage():Void {
		sysPrint('Usage: apq meta [<annotation>] [options] <file-or-dir>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --arg-contains <s>  Keep hits whose argument list contains <s>\n');
		sysPrint('  --on <decl-kind>    Keep hits attached to the given decl kind\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('<annotation> is the target language source syntax (e.g. `@:foo`).\n');
		sysPrint('Omit it with `--on` to list every annotation on a decl kind.\n');
	}

	private static function printAstUsage():Void {
		sysPrint('Usage: apq ast [options] <file>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of S-expr\n');
		sysPrint('  --depth <n>         Truncate beyond depth n\n');
		sysPrint('  --select <path>     Subtree(s) matching a selector (e.g. "ClassDecl > FnDecl:foo")\n');
		sysPrint('  --at <line>:<col>   Innermost node enclosing the 1-indexed position\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
	}

	private static function stderr(s:String):Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

	private static inline function sysPrint(s:String):Void {
		#if (sys || nodejs)
		Sys.print(s);
		#end
	}
}

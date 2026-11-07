package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Type;
#end

using StringTools;

import haxe.io.Path;
import haxe.macro.Expr;
import sys.FileSystem;

/**
 * The one answer to "which grammar plugins can the CLI dispatch": every module on the compiler's classpath whose file
 * is named `<Name>QueryPlugin.hx`, read at compile time, so a new grammar package is found with no CLI edit and a build
 * whose classpath does not hold a plugin never registers it.
 *
 * The module's class of that name must implement `GrammarPlugin`, take no constructor argument and declare the statics
 * `LANG` (its `--lang`), `EXTENSIONS` (lower case, with the dot) and `MERGE` (how `apq merge-file` takes its files apart),
 * and may declare `recognises(text): Bool` (stdin with no `--lang`). A module that carries the name and breaks the
 * contract is a build error naming it, never a silent skip. It lives outside `anyparse.query.cli` because that
 * package's ambient imports would drag the CLI into the macro context; the walk and the row builder need no compiler
 * and stay outside `#if macro`, so the suite types them.
 */
@:nullSafety(Strict)
final class GrammarDiscovery {

	/** The file-name suffix that makes a module a grammar plugin the CLI registers. */
	private static inline final MODULE_SUFFIX: String = 'QueryPlugin';

	/** The compiler's module file extension. */
	private static inline final MODULE_EXTENSION: String = '.hx';

	/** The interface every registered plugin implements, by its module path. */
	private static inline final PLUGIN_INTERFACE: String = 'anyparse.query.GrammarPlugin';

	/** The optional static content test. */
	private static inline final RECOGNISES: String = 'recognises';

	/** The statics every registered plugin declares. */
	private static final REQUIRED_STATICS: Array<String> = ['LANG', 'EXTENSIONS', 'MERGE'];

	/**
	 * The `CliArgs.GrammarEntry` rows of every plugin the classpath holds, sorted by module path, as an array
	 * literal: the caller builds it afresh on every call, so the registry is never process-scoped state (invariant 1).
	 */
	public static macro function rows(): Expr {
		final rows: Array<Expr> = pluginModules(Context.getClassPath()).map(row);
		return macro $a{rows};
	}

	/** Every `*QueryPlugin` module path under the directories `roots`, deduped and sorted; an empty root is skipped. */
	public static function pluginModules(roots: Array<String>): Array<String> {
		final seen: Map<String, Bool> = [];
		for (root in roots) if (root != '' && FileSystem.isDirectory(root)) collect(root, [], seen);
		final found: Array<String> = [for (module in seen.keys()) module];
		found.sort(Reflect.compare);
		return found;
	}

	/**
	 * The registry row of the plugin class at `path`, whose statics are named `statics`: its declared `LANG`,
	 * `EXTENSIONS` and `MERGE`, its constructor, and its `recognises` when it declares one, else null.
	 */
	public static function entry(path: Expr, statics: Array<String>): Expr {
		final make: Expr = { expr: EField(path, 'new'), pos: path.pos };
		final recognises: Expr = statics.contains(RECOGNISES) ? macro $path.recognises : macro null;
		return macro {
			lang: $path.LANG,
			extensions: $path.EXTENSIONS,
			recognises: $recognises,
			make: $make,
			merge: $path.MERGE
		};
	}

	/** Record in `seen` the `*QueryPlugin` module of every file under `dir`, whose package is `pack`. */
	private static function collect(dir: String, pack: Array<String>, seen: Map<String, Bool>): Void {
		for (entry in FileSystem.readDirectory(dir)) if (!entry.startsWith('.')) {
			final full: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(full))
				collect(full, pack.concat([entry]), seen)
			else if (entry.endsWith(MODULE_SUFFIX + MODULE_EXTENSION))
				seen[pack.concat([entry.substr(0, entry.length - MODULE_EXTENSION.length)]).join('.')] = true;
		}
	}

	#if macro
	/** The registry row of the plugin `module`; a module breaking the contract is a build error. */
	private static function row(module: String): Expr {
		final plugin: ClassType = switch Context.getType(module) {
			case TInst(ref, _): ref.get();
			case _:
				Context.error(
					'$module is named *$MODULE_SUFFIX, so the CLI registers it as a grammar plugin, but it is not a class',
					Context.currentPos()
				);
		}
		if (!implementsPlugin(plugin))
			Context.error(
				'$module is named *$MODULE_SUFFIX, so the CLI registers it as a grammar plugin, but it does not implement'
				+ ' $PLUGIN_INTERFACE — implement it, or rename the module',
				plugin.pos
			);
		final statics: Array<String> = [for (field in plugin.statics.get()) field.name];
		for (name in REQUIRED_STATICS) if (!statics.contains(name))
			Context.error('grammar plugin $module declares no static $name, which its CLI registry row reads', plugin.pos);
		return entry(macro $p{module.split('.')}, statics);
	}

	/** Whether `c`, its superclasses or the interfaces they extend include `GrammarPlugin`. */
	private static function implementsPlugin(c: ClassType): Bool {
		if (c.pack.concat([c.name]).join('.') == PLUGIN_INTERFACE) return true;
		for (iface in c.interfaces) if (implementsPlugin(iface.t.get())) return true;
		final superClass: Null<{ t: Ref<ClassType>, params: Array<Type> }> = c.superClass;
		return superClass != null && implementsPlugin(superClass.t.get());
	}
	#end

}

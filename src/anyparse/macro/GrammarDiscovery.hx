package anyparse.macro;

#if macro
import haxe.macro.Context;
#end

using Lambda;
using StringTools;

import anyparse.util.Compare;
import haxe.io.Path;
import haxe.macro.Expr;
import haxe.macro.Type;
import sys.FileSystem;

/**
 * The one answer to "which grammar plugins can the CLI dispatch": every module on the compiler's classpath whose file
 * is named `<Name>QueryPlugin.hx`, read at compile time, so a new grammar package is found with no CLI edit and a build
 * whose classpath does not hold a plugin never registers it.
 *
 * The module's class of that name must implement `GrammarPlugin`, take no constructor argument and declare the statics
 * `LANG` (its `--lang`), `EXTENSIONS` (lower case, with the dot) and `MERGE` (how `apq merge-file` takes its files apart),
 * and may declare `recognises(text): Bool` (stdin with no `--lang`). `LANG` and `EXTENSIONS` are initialised with
 * literals, and two plugins claiming one `--lang` or one extension are a build error naming both. A module that carries
 * the name and breaks the contract is a build error naming it, never a silent skip. A compilation server does not
 * re-run the walk when a plugin file appears (docs/cli-query-tool.md says why). It lives outside `anyparse.query.cli`
 * because that package's ambient imports would drag the CLI into the macro context; the walk, the row builder, the
 * clash check and the literal reader need no compiler and stay outside `#if macro`, so the suite types them.
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
		final rows: Array<Expr> = [];
		final claims: Array<PluginClaim> = [];
		for (module in pluginModules(Context.getClassPath())) {
			final plugin: ClassType = pluginClass(module);
			rows.push(entry(macro $p{module.split('.')}, [for (field in plugin.statics.get()) field.name]));
			claims.push({ module: module, lang: literal(module, plugin, 'LANG')[0], extensions: literal(module, plugin, 'EXTENSIONS') });
		}
		final problem: Null<String> = clash(claims);
		if (problem != null) Context.error(problem, Context.currentPos());
		return macro $a{rows};
	}

	/** Every `*QueryPlugin` module path under the directories `roots`, deduped and sorted; an empty root is skipped. */
	public static function pluginModules(roots: Array<String>): Array<String> {
		final seen: Map<String, Bool> = [];
		for (root in roots) if (root != '' && FileSystem.isDirectory(root)) collect(root, [], seen);
		final found: Array<String> = [for (module in seen.keys()) module];
		found.sort(Compare.compareString);
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

	/**
	 * The first two plugins of `claims` that claim one `--lang` or one file extension, as the build error naming both
	 * modules, else null: the CLI dispatches a claim to one plugin, so a shared one would silently go to whichever
	 * module sorts first.
	 */
	public static function clash(claims: Array<PluginClaim>): Null<String> {
		final langs: Map<String, String> = [];
		final extensions: Map<String, String> = [];
		for (claim in claims) {
			final langOwner: Null<String> = langs[claim.lang];
			if (langOwner != null)
				return 'grammar plugins $langOwner and ${claim.module} both declare LANG "${claim.lang}",'
					+ ' so the CLI cannot tell which one it dispatches';
			langs[claim.lang] = claim.module;
			for (extension in claim.extensions) {
				final extensionOwner: Null<String> = extensions[extension];
				if (extensionOwner != null && extensionOwner != claim.module)
					return 'grammar plugins $extensionOwner and ${claim.module} both declare the extension "$extension",'
						+ ' so the CLI cannot tell which one a file of it goes to';
				extensions[extension] = claim.module;
			}
		}
		return null;
	}

	/**
	 * The strings `e` spells as a string literal or an array literal of them, through parentheses, metadata and
	 * unchecked casts, else null — never a partial list, so a non-literal claim is refused rather than shortened.
	 */
	public static function strings(e: TypedExpr): Null<Array<String>> {
		return switch e.expr {
			case TConst(TString(s)): [s];
			case TParenthesis(inner), TCast(inner, null), TMeta(_, inner): strings(inner);
			case TArrayDecl(items):
				final found: Array<String> = [];
				for (item in items) switch item.expr {
					case TConst(TString(s)):
						found.push(s);
					case _:
						return null;
				}
				found;
			case _: null;
		}
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
	/** The plugin class of `module`; a module breaking the contract is a build error. */
	private static function pluginClass(module: String): ClassType {
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
		return plugin;
	}

	/**
	 * The strings the static `name` of the plugin `module` is initialised with — a string literal or an array literal
	 * of them; any other initialiser is a build error, since the claim could not be checked against the other plugins.
	 */
	private static function literal(module: String, plugin: ClassType, name: String): Array<String> {
		final field: Null<ClassField> = plugin.statics.get().find(field -> field.name == name);
		final value: Null<TypedExpr> = field?.expr();
		final found: Null<Array<String>> = value == null ? null : strings(value);
		return found ?? Context.error(
			'grammar plugin $module initialises its static $name with no string literal or array literal of them, so its claim'
			+ ' cannot be checked against the other plugins',
			plugin.pos
		);
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

/** One grammar plugin's claim on the CLI's dispatch: its module path, its `--lang` and its file extensions. */
typedef PluginClaim = {
	final module: String;
	final lang: String;
	final extensions: Array<String>;
}

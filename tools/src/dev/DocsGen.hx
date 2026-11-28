package dev;

import anyparse.check.Linter;
import anyparse.check.RuleCategory;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.CliRegistry;
import anyparse.util.Compare;
import dev.ConfigKeys.ConfigKey;
import devkit.Args;
import haxe.Exception;
import sys.io.File;

using StringTools;

/** One generated region of a guide page: `name` marks it in `path`, `body` is what lies between its markers. */
typedef GeneratedSection = { var path: String; var name: String; var body: String; }

/**
 * `dev docs-gen [--check] [--root <dir>]` — the one answer to "which reference tables of `docs/guide` does the code own,
 * and does the committed page hold them": the command table (`CliRegistry`), the options each rule accepts
 * (`Linter.acceptedOptions`) and the `apq.json` keys (the `ApqLintConfig` typedef, read at compile time) are rendered
 * between `<!-- docs-gen:begin NAME -->` and `<!-- docs-gen:end NAME -->` markers of their page. The default rewrites the
 * regions; `--check` writes nothing and exits 1 when a committed region differs from the generated one.
 */
@:nullSafety(Strict)
final class DocsGen {

	public static inline final USAGE: String = 'usage: dev docs-gen [--check] [--root <dir>]';

	private static final COMMANDS_PAGE: String = 'docs/guide/commands.md';
	private static final RULE_OPTIONS_PAGE: String = 'docs/guide/rule-options.md';
	private static final CONFIG_PAGE: String = 'docs/guide/lint-config.md';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final check: Bool = args.flag('--check');
		final root: String = args.option('--root') ?? '.';
		args.done();
		final stale: Array<String> = apply(root, sections(), !check);
		if (stale.length == 0) {
			Sys.println('docs-gen: every generated section is current');
			return 0;
		}
		for (path in stale)
			Sys.println(check ? 'docs-gen: $path differs from the generated one; run node bin/dev.js docs-gen' : 'docs-gen: wrote $path');
		return check ? 1 : 0;
	}

	/** Every generated region, in page order. */
	public static function sections(): Array<GeneratedSection> {
		return [
			{ path: COMMANDS_PAGE, name: 'commands', body: commandTable(CliRegistry.commands()) },
			{ path: RULE_OPTIONS_PAGE, name: 'rule-options', body: ruleOptionTable(Linter.acceptedOptions()) },
			{ path: CONFIG_PAGE, name: 'config-keys', body: configKeyTable(ConfigKeys.declared()) }
		];
	}

	/** One row per command, in registry order: its name, its `--help` summary and the flags it declares beyond the global ones. */
	public static function commandTable(commands: Array<CliCommand>): String {
		final out: StringBuf = new StringBuf();
		out.add('| command | summary | flags |\n|---|---|---|\n');
		for (command in commands) {
			final flags: String = command.flags().names().map(flag -> '`$flag`').join(' ');
			out.add('| `${command.name()}` | ${cell(command.summary())} | $flags |\n');
		}
		return out.toString();
	}

	/** One row per rule that reads an option, by category then id: the keys of its `rules` entry besides `enabled` and `severity`. */
	public static function ruleOptionTable(accepted: Map<String, Array<String>>): String {
		final out: StringBuf = new StringBuf();
		out.add('| rule | category | options |\n|---|---|---|\n');
		final categoryOf: Map<String, String> = [ for (check in Linter.builtins()) check.id() => check.category() ];
		final ids: Array<String> = [ for (id => keys in accepted) if (keys.length > 0 && categoryOf.exists(id)) id ];
		final rank: (String) -> Int = id -> RuleCategory.ALL.indexOf(cast categoryOf[id]);
		ids.sort((a, b) -> rank(a) != rank(b) ? rank(a) - rank(b) : Compare.compareString(a, b));
		for (id in ids) out.add('| `$id` | `${categoryOf[id]}` | ${[ for (key in accepted[id] ?? []) '`$key`' ].join(' ')} |\n');
		return out.toString();
	}

	/** One row per key, by name. Every key is optional: an empty document is a valid config. */
	public static function configKeyTable(keys: Array<ConfigKey>): String {
		final out: StringBuf = new StringBuf();
		out.add('| key | type |\n|---|---|\n');
		for (key in keys) out.add('| `${key.name}` | `${key.type}` |\n');
		return out.toString();
	}

	/**
	 * `page` with the region `name` holding `body`; throws when the page lacks either marker, so a section cannot be
	 * generated into a page that never asked for it.
	 */
	public static function splice(page: String, name: String, body: String): String {
		final begin: String = '<!-- docs-gen:begin $name -->';
		final end: String = '<!-- docs-gen:end $name -->';
		final from: Int = page.indexOf(begin);
		final to: Int = page.indexOf(end);
		if (from < 0 || to < from) throw new Exception('the page has no `$begin` ... `$end` pair');
		return '${page.substring(0, from + begin.length)}\n$body${page.substring(to)}';
	}

	/**
	 * Splice every section into its page under `root`; answers the paths whose text changed, in the order of `all`, and
	 * writes them when `write` is set.
	 */
	public static function apply(root: String, all: Array<GeneratedSection>, write: Bool): Array<String> {
		final texts: Map<String, String> = [];
		final changed: Array<String> = [];
		for (section in all) {
			final file: String = '$root/${section.path}';
			final before: String = texts[section.path] ?? File.getContent(file);
			final after: String = splice(before, section.name, section.body);
			texts[section.path] = after;
			if (after != File.getContent(file) && !changed.contains(section.path)) changed.push(section.path);
		}
		if (write) for (path in changed) File.saveContent('$root/$path', texts[path] ?? '');
		return changed;
	}

	/** `text` safe inside a markdown table cell: a pipe would end the cell. */
	private static inline function cell(text: String): String {
		return text.replace('|', '\\|');
	}

}

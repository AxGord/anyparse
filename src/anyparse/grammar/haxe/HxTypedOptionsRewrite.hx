package anyparse.grammar.haxe;

import anyparse.format.OptionsSource;
import anyparse.macro.OptionKnobs;
import anyparse.query.AddImport;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin;
import anyparse.query.Matcher.Match;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.Rewrite;
import anyparse.query.SourceSlice;
import haxe.Exception;

using anyparse.util.Strings;

/**
 * The one answer to "how does a test's `hxformat.json` call become typed `HxModuleWriteOptions`, by an op rather than by hand": every
 * `HaxeFormatConfigLoader.loadHxFormatJson(<literal>)` / `loadHxFormatJson(<literal>)`, `<kit>.strictJson(<literal>)` and
 * `HxWriteConfig.ofJson(<literal>)` of a Haxe source becomes `<kit>.forkWith(edited -> edited.<knob> = <value>)`
 * over the same baseline, `loadHxFormatJson('{}')`: a block of
 * assignments for several knobs, an empty one for none.
 *
 * An assignment is written for each knob whose value the document changed from that baseline, so a key that fans out over several
 * knobs, or cascades, is rewritten as the knobs it ended up setting and the options stay equal by construction. The rewrite refuses,
 * writing nothing, a document the loader does not act on (`HaxeFormatConfigDiagnostics`, the keys it names), a document that does
 * not load, a knob changed to a value with no source spelling, and an argument that is not one plain string literal.
 */
@:nullSafety(Strict)
final class HxTypedOptionsRewrite {

	/** How much of a refused call a message quotes. */
	private static inline final CALL_EXCERPT: Int = 80;

	/**
	 * `source` with each hxformat.json call turned into the typed edit of `kit` (a qualified type with `forkWith`), the imports that edit
	 * needs added; `Ok(source, 0)` when it holds none.
	 */
	public static function rewrite(source: String, kit: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String): EditResult {
		final knobs: Array<OptionKnob> = OptionKnobs.of(HxModuleWriteOptions);
		final imports: Array<String> = [];
		final kitName: String = kit.allAfterLast('.');
		var text: String = source;
		var sites: Int = 0;
		for (site in callShapes(kitName)) {
			final current: String = text;
			switch Rewrite.rewriteBy(current, site.pattern, reformat, plugin, optsJson, false, m -> {
				final answer: Replacement = replacement(m, current, site, kitName, knobs, imports);
				if (answer.match(Spliced(_, _))) sites++;
				return answer;
			}) {
				case Err(message):
					return Err(message);
				case Ok(rewritten, _):
					text = rewritten;
			}
		}
		if (sites == 0) return Ok(source, 0);
		imports.push(kit);
		return withImports(text, imports, reformat, plugin, optsJson, sites);
	}

	/** The call shapes the rewrite reads; `strictJson` is the kit's own refusing loader, so it is spelled with the kit's simple name. */
	private static function callShapes(kitName: String): Array<Site> {
		return [
			{ pattern: 'HaxeFormatConfigLoader.loadHxFormatJson($$json)', asConfig: false },
			{ pattern: 'loadHxFormatJson($$json)', asConfig: false },
			{ pattern: '$kitName.strictJson($$json)', asConfig: false },
			{ pattern: 'HxWriteConfig.ofJson($$json)', asConfig: true }
		];
	}

	private static function replacement(
		m: Match, source: String, site: Site, kitName: String, knobs: Array<OptionKnob>, imports: Array<String>
	): Replacement {
		final call: String = SourceSlice.slice(source, m.span).firstLine();
		final at: String = call.length > CALL_EXCERPT ? '${call.substring(0, CALL_EXCERPT)}…' : call;
		final json: Null<String> = literalOf(m.bindings['json']);
		if (json == null) return Refused('$at: the argument is not one plain string literal, so there is no document to read');
		try {
			final ignored: Array<String> = HaxeFormatConfigDiagnostics.ignored(HaxeFormatConfigDiagnostics.diagnose(json));
			if (ignored.length > 0) return Refused('$at: hxformat.json settings the loader does not act on: ${ignored.join('; ')}');
			final base: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
			final edits: Array<String> = OptionsSource.changes(knobs, base, HaxeFormatConfigLoader.loadHxFormatJson(json), imports)
				.map(c -> 'edited.${c.name} = ${c.source}');
			final body: String = switch edits.length {
				case 0: '{}';
				case 1: edits[0];
				case _: '{ ${edits.map(e -> '$e;').join(' ')} }';
			};
			final fork: String = '$kitName.forkWith(edited -> $body)';
			return Spliced(site.asConfig ? 'HxWriteConfig.ofOptions($fork)' : fork, []);
		} catch (exception: Exception) {
			return Refused('$at: ${exception.message}');
		}
	}

	/** The text of a call argument that is one string literal with no interpolation, decoded; null for anything else. */
	private static function literalOf(node: Null<QueryNode>): Null<String> {
		if (node == null) return null;
		final raw: Null<String> = rawOf(node);
		return raw == null || HxStringEscape.carriesEscapedDollar(raw)
			? null
			: HxStringEscape.decode(raw).map(c -> String.fromCharCode(c.code)).join('');
	}

	private static function withImports(
		text: String, wanted: Array<String>, reformat: Bool, plugin: GrammarPlugin, optsJson: Null<String>, total: Int
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, text, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};
		final held: Array<String> = [];
		var pack: String = '';
		for (c in tree.children) switch c.kind {
			case 'ImportDecl':
				held.push(c.name ?? '');
			case 'PackageDecl':
				pack = c.name ?? '';
			case _:
		}
		var result: String = text;
		for (path in wanted) if (!held.contains(path) && path.substring(0, path.lastIndexOf('.')) != pack) {
			held.push(path);
			switch AddImport.addImport(result, path, false, reformat, plugin, optsJson) {
				case Err(message):
					return Err(message);
				case Ok(added, _):
					result = added;
			}
		}
		return Ok(result, total);
	}

	/** The source text between the quotes of a string literal node with no interpolation in it; null for any other node. */
	private static function rawOf(node: QueryNode): Null<String> {
		final name: Null<String> = node.name;
		if (node.kind == 'DoubleStringExpr') return name == null ? null : name.substring(1, name.length - 1);
		if (node.kind != 'SingleStringExpr') return null;
		if (node.children.length == 0) return '';
		return node.children.length == 1 && node.children[0].kind == 'Literal' ? node.children[0].name : null;
	}

}

private typedef Site = { pattern: String, asConfig: Bool };

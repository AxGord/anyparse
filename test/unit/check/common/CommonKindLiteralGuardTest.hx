package unit.check.common;

import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;

using StringTools;

/**
 * The generic rules of `check/common` spell no node kind of the Haxe grammar: a kind they test is asked of the grammar
 * plugin (`RefShape`, `ShapeVocab`, `MetaShape`), so a second grammar's spellings reach them and a check is not welded to
 * one language without anything failing. What still spells one is recorded in `ACCOUNTED` with the reason it stays, and
 * the record only shrinks. The guard reads only this layer: a Haxe kind table of `anyparse.query` (`MemberKinds`) is
 * not the grammar, and a rule that reads one is welded to Haxe where this guard cannot see it.
 */
@:nullSafety(Strict)
class CommonKindLiteralGuardTest extends Test {

	/** The layer the guard reads, relative to the repository root. */
	private static inline final LAYER: String = 'src/anyparse/check/common';

	/**
	 * The kind literals left, by file. The import declarations are one family no seam answers yet; `Dynamic` there is the
	 * std TYPE name (a list of type names is data), which happens to share its spelling with the `dynamic` modifier kind.
	 */
	private static final ACCOUNTED: Map<String, Array<String>> = [
		'$LAYER/imports/ImportOutsideGuard.hx' => ['ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl'],
		'$LAYER/types/DynamicBag.hx' => [
			'UsingDecl',
			'Dynamic',
			'ImportDecl',
			'ImportWildDecl',
			'ImportAliasDecl',
			'ImportAliasInDecl',
			'PackageDecl'
		],
		'$LAYER/loops/PreferForIn.hx' => ['Dynamic'],
		'$LAYER/types/ExplicitLocalType.hx' => ['Dynamic'],
		'$LAYER/types/ExplicitType.hx' => ['Dynamic'],
		'$LAYER/types/LiteralInfer.hx' => ['Dynamic'],
		'$LAYER/unused/UnusedReturnValue.hx' => ['Dynamic']
	];

	/**
	 * Every whole string literal in the layer that equals a projected Haxe kind is accounted for, and every accounted one
	 * is still there. A literal is read off its raw span, so an interpolated fragment that merely starts with a kind's
	 * spelling is prose, not a kind.
	 */
	@:pin('control') @:killer('M-COMMON-RULE-SPELLS-IF-KIND')
	public function testNoUnaccountedHaxeKindLiteralInTheCommonRules(): Void {
		final root: String = CliFixture.repoRoot();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final kinds: Array<String> = plugin.projectedKinds();
		final literalKinds: Array<String> = plugin.refShape().stringLiteralKinds ?? [];
		final seen: Array<String> = [];
		for (path in layerFiles(root)) {
			final raw: String = File.getContent('$root/$path');
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, raw);
			if (tree == null) continue;
			for (text in wholeLiterals(tree, raw, literalKinds)) if (kinds.contains(text)) {
				final key: String = '$path $text';
				if (!seen.contains(key)) seen.push(key);
				Assert.isTrue(
					(ACCOUNTED[path] ?? []).contains(text),
					'$path spells the Haxe node kind \'$text\' - ask RefShape / ShapeVocab for it, or account for it here'
				);
			}
		}
		for (path => texts in ACCOUNTED) for (text in texts)
			Assert.isTrue(seen.contains('$path $text'), '$path no longer spells \'$text\' - drop it from ACCOUNTED');
	}

	/** The text of every string literal in `tree` whose raw span is one quoted run, quotes stripped. */
	private static function wholeLiterals(tree: QueryNode, raw: String, literalKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		function visit(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (literalKinds.contains(node.kind) && span != null && span.to - span.from >= 2) {
				final quote: String = raw.charAt(span.from);
				if ((quote == '\'' || quote == '"') && raw.charAt(span.to - 1) == quote)
					out.push(raw.substring(span.from + 1, span.to - 1));
			}
			for (child in node.children) visit(child);
		}
		visit(tree);
		return out;
	}

	/** Every `.hx` under the layer, as paths relative to `root`. */
	private static function layerFiles(root: String): Array<String> {
		final out: Array<String> = [];
		final pending: Array<String> = [LAYER];
		while (pending.length > 0) {
			final dir: String = pending.shift() ?? '';
			for (entry in FileSystem.readDirectory('$root/$dir')) {
				final rel: String = '$dir/$entry';
				if (FileSystem.isDirectory('$root/$rel'))
					pending.push(rel);
				else if (entry.endsWith('.hx'))
					out.push(rel);
			}
		}
		return out;
	}

}

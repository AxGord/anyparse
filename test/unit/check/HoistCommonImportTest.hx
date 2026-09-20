package unit.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.Violation;
import anyparse.check.HoistCommonImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * One file of a fixture tree: its tree-relative `name` and its `source`. Named because the fixtures,
 * the helpers that write them and the ones that read a fix back all pass the same pair.
 */
private typedef TreeFile = {
	var name: String;
	var source: String;
}

/**
 * `hoist-common-import` — which statement earns a place in a directory's ambient source, which one
 * is refused, and what the cross-file fix writes.
 *
 * Every fixture is a real tree on disk: the governed set and the chain are read from there, so an
 * in-memory file set cannot exercise either. Type names are NONCES — a one-letter or common name is
 * unreportable by construction, since the resolution scope joins the language's own std and any
 * string literal is a possible reflection key.
 */
@:nullSafety(Strict)
class HoistCommonImportTest extends Test {

	/** What `hoistedSites` puts between two slices — never a `;`, which every statement it renders ends with. */
	private static inline final SITE_SEPARATOR: String = ' :: ';

	/** Four modules of one package spelling one import, and a fifth that does not. */
	private static final COMMON_TREE: Array<TreeFile> = [
		{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
		{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/TwoQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass TwoQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/ThreeQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass ThreeQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
	];

	/**
	 * Three modules of one package importing the MODULE `aqq.Modqqw`, whose sibling `Othqqw` a
	 * same-package `bqq.Othqqw` is a namesake of — and a fourth module that reads bare `Othqqw`
	 * without importing anything.
	 */
	private static final SIBLING_TREE: Array<TreeFile> = [
		{
			name: 'src/aqq/Modqqw.hx',
			source: 'package aqq;\n\nclass Modqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'aqq\';\n\t}\n\n}\n\n'
				+ 'class Othqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'aqq.Othqqw\';\n\t}\n\n}\n\n'
				+ 'class Subqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'aqq.Subqqw\';\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/Othqqw.hx',
			source: 'package bqq;\n\nclass Othqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'bqq\';\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/MqqOne.hx',
			source: 'package bqq;\n\nimport aqq.Modqqw;\n\nclass MqqOne {\n\n\tpublic static function run(): String {\n\t\t'
				+ 'return Modqqw.who();\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/MqqTwo.hx',
			source: 'package bqq;\n\nimport aqq.Modqqw;\n\nclass MqqTwo {\n\n\tpublic static function run(): String {\n\t\t'
				+ 'return Modqqw.who();\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/MqqThree.hx',
			source: 'package bqq;\n\nimport aqq.Modqqw;\n\nclass MqqThree {\n\n\tpublic static function run(): String {\n\t\t'
				+ 'return Modqqw.who();\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/Userqqw.hx',
			source: 'package bqq;\n\nclass Userqqw {\n\n\tpublic static function run(): String {\n\t\treturn Othqqw.who();\n\t}\n\n}\n'
		}
	];

	/** A modules-and-nesting tree: one statement every module spells, one only the nested package does. */
	private static final NESTED_TREE: Array<TreeFile> = [
		{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
		{ name: 'src/qqz/Yqqwwee.hx', source: 'package qqz;\n\nclass Yqqwwee {}\n' },
		{
			name: 'src/aqq/OneQq.hx',
			source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/TwoQq.hx',
			source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass TwoQq {\n\n\tvar a: Zqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/bqq/ThreeQq.hx',
			source: 'package aqq.bqq;\n\nimport qqz.Yqqwwee;\nimport qqz.Zqqwwee;\n\nclass ThreeQq {\n\n\tvar a: Zqqwwee;\n'
				+ '\tvar b: Yqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/bqq/FourQq.hx',
			source: 'package aqq.bqq;\n\nimport qqz.Yqqwwee;\nimport qqz.Zqqwwee;\n\nclass FourQq {\n\n\tvar a: Zqqwwee;\n'
				+ '\tvar b: Yqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/bqq/FiveQq.hx',
			source: 'package aqq.bqq;\n\nimport qqz.Yqqwwee;\nimport qqz.Zqqwwee;\n\nclass FiveQq {\n\n\tvar a: Zqqwwee;\n'
				+ '\tvar b: Yqqwwee;\n\n}\n'
		}
	];

	/**
	 * A statement most modules of a directory spell moves to the widest position whose share it
	 * reaches, and every module that spells it is reported.
	 */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testHoistsAnImportMostModulesSpell(): Void {
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/import.hx',
			planned(COMMON_TREE)
		);
	}

	/** An ALIAS binds a name the rule cannot follow into an ambient source. */
	@:pin('guard')
	public function testRefusesAnAlias(): Void {
		Assert.equals('', planned(withStatement('import qqz.Zqqwwee as Uqqwwee;', 'Uqqwwee')));
	}

	/** A PACKAGE wildcard binds every module of a package, which no enumeration here could name. */
	@:pin('guard')
	public function testRefusesAPackageWildcard(): Void {
		Assert.equals('', planned(withStatement('import qqz.*;', 'Zqqwwee')));
	}

	/** A STATIC wildcard binds members, not a type name — a different question, refused here. */
	@:pin('guard')
	public function testRefusesAStaticWildcard(): Void {
		Assert.equals('', planned(withStatement('import qqz.Zqqwwee.*;', 'Zqqwwee')));
	}

	/**
	 * A `#if`-guarded statement decides a BUILD, so it cannot decide what a name means under a whole
	 * directory. Over-determined on purpose: the candidate filter refuses it, and so would the
	 * second-binder gate — which is why the arm for chain guardedness hangs on its own fixture below.
	 */
	@:pin('guard')
	public function testRefusesAGuardedStatement(): Void {
		Assert.equals('', planned(withStatement('#if js\nimport qqz.Zqqwwee;\n#end', 'Zqqwwee')));
	}

	/**
	 * A chain carrying ANY guarded statement withholds every verdict under it: one such statement makes
	 * name resolution in every governed module answer the union of two readings, and a position this
	 * rule adds to must not be one of them.
	 */
	@:pin('control')
	@:killer('M-HOIST-GUARDED-BLIND')
	public function testWithholdsWhereTheChainCarriesAGuardedStatement(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([
			{ name: 'src/import.hx', source: '#if js\nimport aqq.Aqqwwee;\n#end\n' },
			{ name: 'src/aqq/Aqqwwee.hx', source: 'package aqq;\n\nclass Aqqwwee {}\n' }
		])));
	}

	/** A `using` off the allow-list stays where its author put it. */
	@:pin('guard')
	public function testRefusesAUsingOffTheAllowList(): Void {
		Assert.equals('', planned(usingTree('qqz.Rqqwwee', '')));
	}

	/** An allow-listed `using` moves, and opens its own block in the created source. */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testHoistsAnAllowListedUsing(): Void {
		Assert.equals('using qqz.Sqqwwee;|', hoisted(usingTree('qqz.Sqqwwee', '')));
	}

	/** A module keeping a `using` this rule cannot vouch for keeps its OWN statement: hoisting it would demote it. */
	@:pin('control')
	@:killer('M-HOIST-USING-DEMOTION')
	public function testKeepsAnAllowListedUsingWhereARivalRemains(): Void {
		Assert.equals('', planned(usingTree('qqz.Sqqwwee', 'using qqz.Rqqwwee;\n')));
	}

	/** An ambient explicit import OUTRANKS a same-package type, so a namesake there is a retarget. */
	@:pin('control')
	@:killer('M-HOIST-RETARGET-BAND')
	public function testRefusesASamePackageNamesake(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/aqq/Zqqwwee.hx', source: 'package aqq;\n\nclass Zqqwwee {}\n' }])));
	}

	/** And a ROOT-package type, which is what a language's own top-level std types are. */
	@:pin('control')
	@:killer('M-HOIST-RETARGET-BAND')
	public function testRefusesARootPackageNamesake(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/Zqqwwee.hx', source: 'class Zqqwwee {}\n' }])));
	}

	/** And a type a governed module reaches through its own PACKAGE wildcard. */
	@:pin('control')
	@:killer('M-HOIST-RETARGET-BAND')
	public function testRefusesANamesakeReachedByAWildcard(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([
			{ name: 'src/wqq/Zqqwwee.hx', source: 'package wqq;\n\nclass Zqqwwee {}\n' },
			{ name: 'src/aqq/FiveQq.hx', source: 'package aqq;\n\nimport wqq.*;\n\nclass FiveQq {\n\n\tvar a: Zqqwwee;\n\n}\n' }
		])));
	}

	/**
	 * A namesake is a retarget only for the modules one of their bands carries it to, so a widest
	 * position governing the namesake's own package is refused while the nested one below it is not —
	 * the gate is per band and per module, never per name.
	 */
	@:pin('guard')
	public function testANamesakePushesTheStatementToADeeperSite(): Void {
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/aqq/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/aqq/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/aqq/import.hx',
			planned(COMMON_TREE.concat([{ name: 'src/fqq/Zqqwwee.hx', source: 'package fqq;\n\nclass Zqqwwee {}\n' }]))
		);
	}

	/**
	 * A statement naming a MODULE binds every type that module declares, so a SIBLING of the imported
	 * type with a namesake a governed module can see is the same retarget as one on the leaf — and it
	 * is the one nobody would look at, since no module in the directory ever named it.
	 */
	@:pin('control')
	@:killer('M-IMPORT-LEAF-ONLY-NAMES')
	public function testRefusesAModuleImportWhoseSiblingHasANamesake(): Void {
		Assert.equals('', planned(SIBLING_TREE));
	}

	/** A path naming ONE type inside a module brings only that type, so a sibling's namesake is irrelevant to it. */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testASubTypeImportIgnoresItsSiblings(): Void {
		Assert.equals(
			'src/bqq/MqqOne.hx:aqq.Modqqw.Subqqw@src/import.hx,src/bqq/MqqThree.hx:aqq.Modqqw.Subqqw@src/import.hx,'
			+ 'src/bqq/MqqTwo.hx:aqq.Modqqw.Subqqw@src/import.hx',
			planned(SIBLING_TREE.map(entry -> entry.name.startsWith('src/bqq/Mqq') ? {
				name: entry.name,
				source: entry.source.split('import aqq.Modqqw;')
					.join('import aqq.Modqqw.Subqqw;')
					.split('Modqqw.who()')
					.join('Subqqw.who()')
			} : entry))
		);
	}

	/** A second run over the tree the fix produced has nothing left to do. */
	@:pin('guard')
	public function testASecondRunHasNothingToDo(): Void {
		Assert.equals('', planned(applied(COMMON_TREE)));
	}

	/** A module whose directory contradicts its package has a chain nobody can bound, so no verdict is made under it. */
	@:pin('control')
	@:killer('M-HOIST-SHORT-CHAIN')
	public function testWithholdsOnAnUnboundedChain(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/aqq/StrayQq.hx', source: 'package wrongqq;\n\nclass StrayQq {}\n' }])));
	}

	/** A directory with fewer modules than the minimum has no share worth reading. */
	@:pin('control')
	@:killer('M-HOIST-MIN-MODULES')
	public function testWithholdsBelowTheMinimumModuleCount(): Void {
		Assert.equals('', planned([
			{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
			{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n' }
		]));
	}

	/** A statement the chain above the directory already provides binds nothing new there. */
	@:pin('guard')
	public function testDoesNotProposeWhatTheChainAlreadyProvides(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/import.hx', source: 'import qqz.Zqqwwee;\n' }])));
	}

	/** A NESTED position takes only what its parents did not, so no statement lands in two sources of one chain. */
	@:pin('control')
	@:killer('M-HOIST-SITE-ORDER')
	@:killer('M-HOIST-CHAIN-INHERITED')
	public function testANestedSiteTakesOnlyWhatItsParentDidNot(): Void {
		Assert.equals('src/import.hx=import qqz.Zqqwwee;| :: src/aqq/import.hx=import qqz.Yqqwwee;|', hoistedSites(NESTED_TREE));
	}

	/** An existing ambient source keeps its own statements and takes the new one in its ordered place. */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testExtendsAnExistingAmbientSource(): Void {
		Assert.equals('import aqq.Aqqwwee;|import qqz.Zqqwwee;|', hoisted(COMMON_TREE.concat([
			{ name: 'src/import.hx', source: 'import aqq.Aqqwwee;\n' },
			{ name: 'src/aqq/Aqqwwee.hx', source: 'package aqq;\n\nclass Aqqwwee {}\n' }
		])));
	}

	/** The statement is CREATED as a whole file when no source is there — the half no edit list can express. */
	@:pin('guard')
	public function testCreatesTheAmbientSourceAsAWholeFile(): Void {
		Assert.equals('create', slicesOf(COMMON_TREE).head);
	}

	/** Extending an existing source is an EDIT, not a create — the opposite refusal of the same seat. */
	@:pin('guard')
	public function testExtendingAnExistingSourceIsAnEdit(): Void {
		Assert.equals(
			'edit', slicesOf(COMMON_TREE.concat([
				{ name: 'src/import.hx', source: 'import aqq.Aqqwwee;\n' },
				{ name: 'src/aqq/Aqqwwee.hx', source: 'package aqq;\n\nclass Aqqwwee {}\n' }
			])).head
		);
	}

	/** One slice per SITE, so a created source and every removal it makes commit together or not at all. */
	@:pin('guard')
	public function testOneSlicePerSite(): Void {
		Assert.equals(2, slicesOf(NESTED_TREE).groups);
	}

	/** `tree` with this rule's own fix applied — the ambient sources it writes, and the modules without what it lifted. */
	private function applied(tree: Array<TreeFile>): Array<TreeFile> {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_applied', tree);
		var out: Array<TreeFile> = tree;
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final byName: Map<String, String> = [];
			for (entry in tree) byName[entry.name] = entry.source;
			for (slice in fixOf(tree, root)) for (part in slice) {
				final name: String = relative(part.file, root);
				final created: Null<String> = part.create;
				if (created != null) {
					byName[name] = created;
					continue;
				}
				var source: String = byName[name] ?? '';
				for (edit in part.edits) source = source.substring(0, edit.span.from) + edit.text + source.substr(edit.span.to);
				byName[name] = source;
			}
			out = [for (name => source in byName) { name: name, source: source }];
		});
		return out;
		#else
		return tree;
		#end
	}

	/**
	 * Every finding over `tree` as `<module>:<path>@<site>`, tree-relative and SORTED — the governed
	 * order is a directory listing's, which is the filesystem's to decide.
	 */
	private function planned(tree: Array<TreeFile>): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_plan', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final rendered: Array<String> = [
				for (v in reportOf(tree, root)) '${relative(v.file, root)}:${quoted(v.message, 0)}@${relative(quoted(v.message, 1), root)}'
			];
			rendered.sort((a, b) -> if (a < b)
				-1
			else if (a > b)
				1
			else
				0);
			out = rendered.join(',');
		});
		return out;
		#else
		return '';
		#end
	}

	/** The ambient source text the FIRST slice writes, with each newline as `|`. */
	private function hoisted(tree: Array<TreeFile>): String {
		final sites: String = hoistedSites(tree);
		final first: Int = sites.indexOf(SITE_SEPARATOR);
		final one: String = first < 0 ? sites : sites.substring(0, first);
		final at: Int = one.indexOf('=');
		return at < 0 ? one : one.substr(at + 1);
	}

	/** Every slice as `<site>=<ambient source text with | for each newline>`, joined in plan order. */
	private function hoistedSites(tree: Array<TreeFile>): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_fix', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			out = [
				for (slice in fixOf(tree, root)) '${relative(slice[0].file, root)}=${textOf(slice[0], tree, root).replace('\n', '|')}'
			].join(SITE_SEPARATOR);
		});
		return out;
		#else
		return '';
		#end
	}

	/** Whether the first slice CREATES or EDITS its ambient source, and how many slices there are. */
	private function slicesOf(tree: Array<TreeFile>): { head: String, groups: Int } {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_slices', tree);
		var out: { head: String, groups: Int } = {
			head: '',
			groups: 0
		};
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final slices: Array<Array<CrossFileEdits>> = fixOf(tree, root);
			out = {
				head: slices.length == 0 ? '' : slices[0][0].create != null ? 'create' : 'edit',
				groups: slices.length
			};
		});
		return out;
		#else
		return {
			head: '',
			groups: 0
		};
		#end
	}

	/** The rule's report over the whole tree written under `root`. */
	private function reportOf(tree: Array<TreeFile>, root: String): Array<Violation> {
		return new HoistCommonImport().run(analysed(tree, root), new HaxeQueryPlugin());
	}

	/** The rule's cross-file fix over the whole tree written under `root`, justified by its own report. */
	private function fixOf(tree: Array<TreeFile>, root: String): Array<Array<CrossFileEdits>> {
		final files: Array<{ file: String, source: String }> = analysed(tree, root);
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final rule: HoistCommonImport = new HoistCommonImport();
		return rule.crossFileFix(files, rule.run(files, plugin), plugin);
	}

	/** `path` without the fixture root prefix. */
	private static inline function relative(path: String, root: String): String {
		return path.startsWith('$root/') ? path.substr(root.length + 1) : path;
	}

	/** The head slice's resulting ambient source text — its `create`, or its edit applied to the existing source. */
	private static function textOf(slice: CrossFileEdits, tree: Array<TreeFile>, root: String): String {
		final created: Null<String> = slice.create;
		if (created != null) return created;
		final name: String = relative(slice.file, root);
		final existing: String = tree.find(entry -> entry.name == name)?.source ?? '';
		final edit: { span: Span, text: String } = slice.edits[0];
		return existing.substring(0, edit.span.from) + edit.text + existing.substr(edit.span.to);
	}

	/** Every `.hx` of `tree` as the run's file set — an ambient source included, the way a whole-tree lint sees one. */
	private static function analysed(tree: Array<TreeFile>, root: String): Array<{ file: String, source: String }> {
		return [
			for (entry in tree) if (entry.name.endsWith('.hx')) { file: '$root/${entry.name}', source: entry.source }
		];
	}

	/** The `n`-th single-quoted SPAN of `message` — quotes come in pairs, so its opening one is at twice the index. */
	private static function quoted(message: String, n: Int): String {
		var at: Int = -1;
		for (_ in 0...2 * n + 1) {
			at = message.indexOf('\'', at + 1);
			if (at < 0) return message;
		}
		final close: Int = message.indexOf('\'', at + 1);
		return close < 0 ? message : message.substring(at + 1, close);
	}

	/** Three of four modules of one package carrying `statement`, which binds `name`. */
	private static function withStatement(statement: String, name: String): Array<TreeFile> {
		return [
			{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
			carrying('OneQq', statement, name),
			carrying('TwoQq', statement, name),
			carrying('ThreeQq', statement, name),
			{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
		];
	}

	/** One module of `aqq` carrying `statement` and reading `name`. */
	private static function carrying(module: String, statement: String, name: String): TreeFile {
		return {
			name: 'src/aqq/$module.hx',
			source: 'package aqq;\n\n$statement\n\nclass $module {\n\n\tvar a: $name;\n\n}\n'
		};
	}

	/**
	 * Three of six modules carrying `using <path>;` plus `extra`, with `path` on the allow-list this
	 * fixture's own `apqlint.json` declares — a `using` of a local module, since a direct run resolves
	 * no library.
	 */
	private static function usingTree(path: String, extra: String): Array<TreeFile> {
		final head: String = 'package aqq;\n\nusing $path;\n$extra';
		return [
			{ name: 'apqlint.json', source: '{ "rules": { "hoist-common-import": { "usingAllowList": ["qqz.Sqqwwee"] } } }\n' },
			{
				name: 'src/qqz/Sqqwwee.hx',
				source: 'package qqz;\n\nclass Sqqwwee {\n\n\tpublic static function tqq(s: String): String {\n\t\treturn s;\n\t}\n\n}\n'
			},
			{
				name: 'src/qqz/Rqqwwee.hx',
				source: 'package qqz;\n\nclass Rqqwwee {\n\n\tpublic static function uqq(s: String): String {\n\t\treturn s;\n\t}\n\n}\n'
			},
			{ name: 'src/aqq/OneQq.hx', source: '$head\nclass OneQq {}\n' },
			{ name: 'src/aqq/TwoQq.hx', source: '$head\nclass TwoQq {}\n' },
			{ name: 'src/aqq/ThreeQq.hx', source: '$head\nclass ThreeQq {}\n' },
			{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
		];
	}

}

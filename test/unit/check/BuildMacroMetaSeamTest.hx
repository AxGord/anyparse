package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.StaticConstant;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The drift guards for the DECLARATION-METADATA seams — the entries of `RefShape` that answer
 * "what does this annotation mean" so a check in `src/anyparse/check` or an index builder in
 * `src/anyparse/query` never has to spell a target-language tag. Invariant 4 (grammar as plugin) is
 * what a spelled tag breaks, and it breaks silently: the check keeps working, on exactly one
 * grammar.
 *
 * Two failure modes, two kinds of guard here.
 *
 * A seam that DRIFTS from its answer. `MemberWriteScan.carriesBuildMacro` matches `@:build` /
 * `@:autoBuild` / `@:genericBuild` as whole metadata tokens; `unused-private`'s leading-run walk
 * asked for `'@:build'` and nothing else, so a `@:genericBuild` class — built WHOLE per
 * instantiation, its declared members discarded — had its privates deleted by the same `--fix` that
 * spares a `@:build` one. Nothing failed: the two lists simply disagreed, and no test compared them.
 * So the guards compare each seam against the OTHER answer, or against the consumer end-to-end, over
 * a probe alphabet the seam itself has to be covered by. `typeBuildMacroMetaNames` is compared to the
 * text scan; `descendantBuildMacroMetaNames` splits that union by DIRECTION (a tag that builds its
 * carrier vs one that builds its subtypes) and is checked against the two index flags it derives;
 * `retainedDeclMetaName`, `reflectedDeclMetaName`, `takesPrivateAccessMetaName`,
 * `forwardingDeclMetaName` and `implicitConstructorDeclMetaName` are each pinned end-to-end plus the
 * near-miss tag that must NOT be matched, since a prefix match is the defect this project already
 * paid for (`@:buildXml` read as `@:build`).
 *
 * A seam that a NEW consumer never asks. No behaviour test can see that one — the check works, it is
 * just welded to Haxe — so the last guard reads the two layers themselves and fails on any string
 * literal starting with a metadata tag that is not accounted for, with the remaining inventory and
 * the reason each entry is still there recorded in `ACCOUNTED_TAGS`.
 */
class BuildMacroMetaSeamTest extends Test {

	/**
	 * The tags the two answers are compared over — the three real ones plus the near-misses that
	 * have been confused with them (`@:buildXml` is an hxcpp build-file tag with 17 declarations in
	 * the Haxe std, and reading it as `@:build` by prefix is a defect this project already paid for).
	 */
	private static final PROBE_TAGS: Array<String> = [
		'@:build',
		'@:autoBuild',
		'@:genericBuild',
		'@:buildXml',
		'@:coreApi',
		'@:keep',
		'@:keepSub',
		'@:rtti',
		'@:enum',
		'@:op',
		'@:generic',
		'@:final',
		'@:publicFields',
		'@:structInit'
	];

	#if (sys || nodejs)
	/**
	 * anyparse's OWN grammar-description vocabulary, spelled in the `@:` shape because that is what
	 * Haxe metadata looks like on the typedefs a `@:build` macro reads. These are not target-language
	 * tags at all — the layers below name them because the layers below IMPLEMENT them — so no seam
	 * could ever hold them and no file needs an entry for one.
	 */
	private static final OWN_GRAMMAR_TAGS: Array<String> = [
		'@:peg',
		'@:fmt',
		'@:optional',
		'@:kw',
		'@:lead',
		'@:trail',
		'@:absentOn',
		'@:sep'
	];

	/**
	 * Every remaining target-language tag a grammar-agnostic file still spells, and why each is
	 * there. Three reasons, and only the third is a queue item:
	 *
	 *  - EMISSION. The file writes the tag INTO target source (`MoveMember` adds an access grant,
	 *    `EncapsulateField` adds a backing-storage annotation, `NewFile` writes a module header). A
	 *    name seam answers "which tag means X", not "what do I type to get one" — the distinction
	 *    `RefShape.enumAbstractSyntax` and `parenDelimiters` already draw. Seaming these needs a
	 *    SPELLING seam, a different design.
	 *  - THE SECOND ANSWER. `MemberWriteScan` is the text scan the seam guards above compare
	 *    `typeBuildMacroMetaNames` AGAINST. Folding it into the seam would make
	 *    `testSeamAndTextScanAgreeOnEveryProbeTag` compare the seam with itself, so the drift guard
	 *    that caught `@:genericBuild` would pass on any disagreement. Its `@:coreApi` is the same
	 *    shape and has no second reader.
	 *  - NOT SEAMED YET. `@:allow` (the privacy waiver that BREAKS a confinement proof — now ONE
	 *    spelling, `RefactorSupport.carriesAllowGrant`, whose consumers are called once per member
	 *    and would need a `RefShape` threaded to them; it was two, in `Naming` as well, until they
	 *    drifted apart in what a hit meant);
	 *    `@:isVar` / `@:bypassAccessor` (accessor physics — which annotation gives a property real
	 *    storage, which one writes past its setter); and `prefer-inline`'s inline-neutral SET, which
	 *    is not a tag but a MEANING — "these annotations describe visibility, documentation or
	 *    typing rather than code generation" — and needs a seam that carries that meaning, plus its
	 *    bare `'@:'` prefix test, which encodes the Haxe convention that a compiler tag starts with
	 *    a colon.
	 */
	private static final ACCOUNTED_TAGS: Map<String, Array<String>> = [
		'src/anyparse/query/MoveMember.hx' => ['@:access'],
		'src/anyparse/query/EncapsulateField.hx' => ['@:isVar'],
		'src/anyparse/query/NewFile.hx' => ['@:nullSafety'],
		'src/anyparse/query/MemberWriteScan.hx' => ['@:build', '@:autoBuild', '@:genericBuild', '@:coreApi'],
		'src/anyparse/query/RefactorSupport.hx' => ['@:allow'],
		'src/anyparse/check/TrivialGetter.hx' => ['@:isVar'],
		'src/anyparse/check/BackingFieldRefs.hx' => ['@:bypassAccessor'],
		'src/anyparse/check/RedundantBypassAccessor.hx' => ['@:bypassAccessor'],
		'src/anyparse/check/PreferInline.hx' => [
			'@:',
			'@:access',
			'@:allow',
			'@:beta',
			'@:deprecated',
			'@:dox',
			'@:final',
			'@:from',
			'@:isVar',
			'@:noCompletion',
			'@:noDoc',
			'@:noUsing',
			'@:nullSafety',
			'@:op',
			'@:pure',
			'@:to',
			'@:unreflective',
			'@:value'
		]
	];
	#end

	/** One question, one answer: the grammar's declared list and the text scan agree tag for tag. */
	public function testSeamAndTextScanAgreeOnEveryProbeTag(): Void {
		final names: Array<String> = declaredBuildMacroNames();
		for (tag in PROBE_TAGS)
			Assert.equals(
				MemberWriteScan.carriesBuildMacro('$tag\nclass C {}\n'), names.contains(tag),
				'$tag: the grammar seam and the text scan answer one question differently'
			);
	}

	/** ...and the alphabet the comparison runs over covers everything the grammar declares. */
	public function testEveryDeclaredNameIsInTheProbeAlphabet(): Void {
		for (name in declaredBuildMacroNames())
			Assert.isTrue(PROBE_TAGS.contains(name), '$name is declared by the grammar but absent from the probe alphabet');
	}

	/** Every declared tag reaches the consumer: `unused-private --fix` keeps the dead private under each. */
	public function testEveryDeclaredNameProtectsAPrivateMember(): Void {
		for (name in declaredBuildMacroNames()) Assert.equals(0, deletions(name), '$name does not protect the private member');
	}

	/** And a tag outside the list protects nothing — the walk matches a whole tag name, never a prefix. */
	public function testANearMissTagProtectsNothing(): Void {
		Assert.equals(1, deletions('@:buildXml'), '@:buildXml is an hxcpp build-file tag, not a build macro');
	}

	/** The retained-declaration seam, both directions. */
	public function testTheRetainedTagIsHonouredAndIsNotAPrefixMatch(): Void {
		final keep: Null<String> = new HaxeQueryPlugin().refShape().retainedDeclMetaName;
		Assert.notNull(keep);
		if (keep == null) return;
		Assert.equals(0, deletions(keep), '$keep does not pin the declaration');
		Assert.equals(1, deletions('${keep}Sub'), '${keep}Sub is a different tag and pins nothing');
	}

	// ---- the DIRECTION split: which of the union's tags build their carrier, which build subtypes ----

	/**
	 * The descendant-ward list is a subset of the union, and the own-ward remainder is non-empty. A
	 * grammar that named a descendant-ward tag the union does not hold would leave that tag unable
	 * to set either index flag; one that named every tag descendant-ward would leave `hasBuild`
	 * dead.
	 */
	public function testTheDescendantWardTagsAreASubsetOfTheUnion(): Void {
		final union: Array<String> = declaredBuildMacroNames();
		final descendant: Array<String> = declaredDescendantBuildMacroNames();
		for (name in descendant) Assert.isTrue(union.contains(name), '$name is descendant-ward but absent from typeBuildMacroMetaNames');
		Assert.isTrue(union.length > descendant.length, 'every build-macro tag is descendant-ward - hasBuild could never be set');
	}

	/**
	 * ...and the index files each declared tag on the side its direction says. This is the guard
	 * that fails on an engine built before the split: `SymbolIndexBuilder` matched `'@:build'` and
	 * `'@:autoBuild'` as literals, so `@:genericBuild` — which builds the WHOLE type per
	 * instantiation — set NEITHER flag, and every consumer of `hasBuild` (`unused-private`,
	 * `unused-public-member`, `orphan-accessor`, `operator-selection`, `SymbolIndex`'s accessor
	 * climb) acted on a member set the builder discards.
	 */
	public function testEachBuildTagIsIndexedOnItsOwnSide(): Void {
		final descendant: Array<String> = declaredDescendantBuildMacroNames();
		for (name in declaredBuildMacroNames()) {
			final type: TypeDeclInfo = indexedType('$name(M.b()) class C {}');
			Assert.equals(!descendant.contains(name), type.hasBuild, '$name: wrong hasBuild for its direction');
			Assert.equals(descendant.contains(name), type.hasAutoBuild, '$name: wrong hasAutoBuild for its direction');
		}
	}

	/** And a near-miss tag sets neither — the index matches a whole tag name, never a prefix. */
	public function testANearMissBuildTagIsIndexedOnNeitherSide(): Void {
		final type: TypeDeclInfo = indexedType('@:buildXml("x.xml") class C {}');
		Assert.isFalse(type.hasBuild);
		Assert.isFalse(type.hasAutoBuild);
	}

	// ---- the other four declaration-metadata seams, each pinned end-to-end plus its near miss ----

	/** `reflectedDeclMetaName`: the type's member names are runtime data, so the naming autofix leaves them alone. */
	public function testTheReflectedTagIsIndexedAndIsNotAPrefixMatch(): Void {
		final tag: String = declaredName(new HaxeQueryPlugin().refShape().reflectedDeclMetaName, 'reflectedDeclMetaName');
		Assert.isTrue(indexedType('$tag class C {}').hasRtti, '$tag does not mark the type reflected');
		Assert.isFalse(indexedType('${tag}Sub class C {}').hasRtti, '${tag}Sub is a different tag and marks nothing');
	}

	/** `retainedDeclMetaName` reaches the INDEX too, not only the leading-run walk pinned above. */
	public function testTheRetainedTagIsIndexedAndIsNotAPrefixMatch(): Void {
		final tag: String = declaredName(new HaxeQueryPlugin().refShape().retainedDeclMetaName, 'retainedDeclMetaName');
		Assert.isTrue(indexedType('$tag class C {}').hasKeep, '$tag does not pin the type');
		Assert.isFalse(indexedType('${tag}Sub class C {}').hasKeep, '${tag}Sub is a different tag and pins nothing');
	}

	/** `takesPrivateAccessMetaName`: the type NAMED in the annotation is the one whose privates are reachable. */
	public function testTheTakenAccessTagCollectsTheNamedType(): Void {
		final tag: String = declaredName(new HaxeQueryPlugin().refShape().takesPrivateAccessMetaName, 'takesPrivateAccessMetaName');
		Assert.isTrue(indexOf('$tag(pkg.Target) class C {}').text.hasAccessGrant('Target'), '$tag does not grant access to the named type');
		Assert.isFalse(indexOf('${tag}or(pkg.Target) class C {}').text.hasAccessGrant('Target'), '${tag}or grants nothing');
	}

	/** `forwardingDeclMetaName`: the abstract republishes its underlying type's members, so the index records it. */
	public function testTheForwardingTagRecordsTheUnderlyingType(): Void {
		final tag: String = declaredName(new HaxeQueryPlugin().refShape().forwardingDeclMetaName, 'forwardingDeclMetaName');
		Assert.equals('Int', indexedType('$tag abstract A(Int) {}').abstractForwardUnderlying, '$tag records no underlying type');
		Assert.isNull(indexedType('${tag}Statics abstract A(Int) {}').abstractForwardUnderlying, '${tag}Statics forwards nothing');
	}

	/**
	 * `implicitConstructorDeclMetaName`: the fields ARE the constructor's parameters, so
	 * `static-constant` may not move one off the instance — that deletes an argument every
	 * construction site is written against.
	 */
	public function testTheImplicitConstructorTagBlocksTheStaticPromotion(): Void {
		final tag: String = declaredName(
			new HaxeQueryPlugin().refShape().implicitConstructorDeclMetaName, 'implicitConstructorDeclMetaName'
		);
		final body: String = 'class C {\n\tfinal n: Int = 1;\n}';
		Assert.equals(1, promotions(body), 'the control fixture is not a promotion candidate - the gate below proves nothing');
		Assert.equals(0, promotions('$tag $body'), '$tag does not block the promotion');
		Assert.equals(1, promotions('${tag}ial $body'), '${tag}ial is a different tag and blocks nothing');
	}

	/** The grammar's declared build-macro tags; asserted non-empty so no guard here can pass vacuously. */
	private function declaredBuildMacroNames(): Array<String> {
		final names: Array<String> = new HaxeQueryPlugin().refShape().typeBuildMacroMetaNames ?? [];
		Assert.isTrue(names.length > 0, 'the grammar declares no build-macro tag - every guard here would pass vacuously');
		return names;
	}

	/** How many members `unused-private --fix` deletes from a one-dead-private class carrying `tag`. */
	private function deletions(tag: String): Int {
		final src: String = '$tag(M.build()) class C {\n\tprivate function dead() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return check.fix(src, vs, new HaxeQueryPlugin()).length;
	}

	/** The grammar's declared descendant-ward build-macro tags; non-empty, so no guard here passes vacuously. */
	private function declaredDescendantBuildMacroNames(): Array<String> {
		final names: Array<String> = new HaxeQueryPlugin().refShape().descendantBuildMacroMetaNames ?? [];
		Assert.isTrue(names.length > 0, 'the grammar declares no descendant-ward build-macro tag');
		return names;
	}

	/** A seam the grammar must fill for the guard reading it to mean anything, asserted non-null. */
	private function declaredName(name: Null<String>, seam: String): String {
		Assert.notNull(name, 'the grammar leaves $seam unset - the guard below would pass vacuously');
		return name ?? '@:__unset__';
	}

	/** A one-file `SymbolIndex` over `src`. */
	private function indexOf(src: String): SymbolIndex {
		return SymbolIndex.build([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The single indexed type declaration of `src`. */
	private function indexedType(src: String): TypeDeclInfo {
		final info: Null<FileInfo> = indexOf(src).fileInfo('C.hx');
		Assert.notNull(info);
		final types: Array<TypeDeclInfo> = info == null ? [] : info.types;
		Assert.equals(1, types.length, 'the fixture does not index exactly one type');
		return types[0] ?? {
			name: '',
			kind: '',
			span: null,
			isMain: false,
			isPrivate: false,
			isExtern: false,
			typeParamArity: 0,
			typeParamNames: [],
			supertypes: [],
			supertypesRaw: [],
			interfaces: [],
			isAnonStruct: false,
			aliasTargetNominal: null,
			aliasTargetRaw: null,
			hasRtti: false,
			hasBuild: false,
			hasAutoBuild: false,
			hasKeep: false,
			members: [],
			abstractSelfRebind: false,
			abstractForwardUnderlying: null
		};
	}

	/** How many `static-constant` findings `src` yields. */
	private function promotions(src: String): Int {
		return new StaticConstant().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length;
	}

	#if (sys || nodejs)
	// ---- invariant 4, made checkable: no NEW target-language tag in the grammar-agnostic layers ----
	/**
	 * Every string literal under `src/anyparse/check` and `src/anyparse/query` whose content STARTS
	 * with a metadata tag has to be one this project already accounts for. The per-seam guards above
	 * catch a seam that drifts from its answer; this catches the other failure mode, the one that
	 * put six leaks in the inventory this test was written for — a NEW check spelling the Haxe tag
	 * instead of asking the grammar for it, which no behaviour test can see because the check works.
	 *
	 * Prefiltered on `'@:` / `"@:` so only the handful of files that hold such a literal are parsed.
	 * The blind spot that buys is a tag written MID-literal, which is always user-facing prose in a
	 * message (`'… external write(s) with @:bypassAccessor'`) rather than a value the check compares
	 * against — that is not the leak, and flagging it would only push prose into a seam.
	 *
	 * The literals are read from each string node's RAW span rather than through a plain-literal
	 * folder: the two EMISSION sites splice the surrounding source into the tag they write
	 * (`'@:isVar ${groupText…}'`), so a folder that answers only for a non-interpolated literal
	 * reports the file as clean and the guard's own record of it goes stale.
	 */
	public function testNoUnaccountedTargetLanguageTagInTheGrammarAgnosticLayers(): Void {
		final root: String = CliFixture.repoRoot();
		final seen: Array<String> = [];
		for (path in layerFiles(root)) {
			final raw: String = File.getContent('$root/$path');
			if (raw.indexOf("'@:") < 0 && raw.indexOf('"@:') < 0) continue;
			for (tag in metaTagLiterals(raw)) if (!OWN_GRAMMAR_TAGS.contains(tag)) {
				final key: String = '$path $tag';
				if (!seen.contains(key)) seen.push(key);
				Assert.isTrue(
					(ACCOUNTED_TAGS[path] ?? []).contains(tag),
					'$path spells the target-language tag $tag - ask the grammar for it (see RefShape), '
					+ 'or add it to ACCOUNTED_TAGS with the reason it must stay'
				);
			}
		}
		// ...and the list is a record of what is LEFT, not a permanent amnesty: a tag that has since
		// been seamed must leave it, or the next reader reads a closed leak as an open one.
		for (path => tags in ACCOUNTED_TAGS) for (tag in tags)
			Assert.isTrue(seen.contains('$path $tag'), '$path no longer spells $tag - drop it from ACCOUNTED_TAGS');
	}

	/**
	 * The leading metadata tag of every string literal in `raw` that starts with one — walked over
	 * the grammar's own `stringLiteralKinds`, reading each node's raw span minus its opening quote.
	 */
	private function metaTagLiterals(raw: String): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, raw);
		if (tree == null) return [];
		final kinds: Array<String> = plugin.refShape().stringLiteralKinds ?? [];
		final out: Array<String> = [];
		function visit(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (kinds.contains(node.kind) && span != null) {
				final tag: Null<String> = leadingMetaTag(raw.substring(span.from + 1, span.to));
				if (tag != null && !out.contains(tag)) out.push(tag);
			}
			for (child in node.children) visit(child);
		}
		visit(tree);
		return out;
	}

	/** Every `.hx` under the two grammar-agnostic layers, as paths relative to `root`. */
	private function layerFiles(root: String): Array<String> {
		final out: Array<String> = [];
		final pending: Array<String> = ['src/anyparse/check', 'src/anyparse/query'];
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

	/** `content`'s leading `@:`-tag (`@:isVar ` -> `@:isVar`, `@:access(` -> `@:access`), or null when it starts with none. */
	private function leadingMetaTag(content: String): Null<String> {
		if (!content.startsWith('@:')) return null;
		var i: Int = 2;
		while (i < content.length) {
			final c: Int = content.charCodeAt(i) ?? 0;
			final part: Bool = c == '_'.code || c == '.'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code
				|| c >= '0'.code && c <= '9'.code;
			if (!part) break;
			i++;
		}
		return content.substring(0, i);
	}
	#end

}

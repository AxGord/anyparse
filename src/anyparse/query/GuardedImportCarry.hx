package anyparse.query;

import anyparse.query.CondDirectives.CondBlock;
import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The `#if`-guarded half of the `move` family's dependency-import carry.
 *
 * A guarded import is a rung of SOME build's ladder and of no other, so it cannot be carried as an
 * unconditional statement — which is why the carry skipped it. Skipping it SILENTLY is the defect:
 * one campaign sweep moved 767 modules and 72 destinations lost
 * `#if (sys || nodejs) import sys.FileSystem; import sys.io.File; #end` with nothing naming a file;
 * the loss showed at build time, one error at a time, and the op's own advisory admitted the class
 * without ever naming an instance.
 *
 * What this module carries is the STATEMENT, re-emitted at the destination under the condition
 * that guards it at the source — `#if <that condition>` around the statements, `#end` after them,
 * one block per distinct condition. Copying the whole REGION was the first shape and it was wrong
 * on real code: a file whose entire body sits inside one `#if (sys || nodejs)` has its type
 * declaration in that region and an `#if` inside a method body, so a whole-region reading refused
 * a move the op had always performed (measured on `unit.CliFixture`, 84 files).
 *
 * Where ONE condition cannot carry it this module REFUSES and names the file, the condition and
 * the name: two different regions binding one name, a statement nested in more than one region, a
 * statement in an `#else` / `#elseif` branch (whose condition is the negation of the ones above
 * it, which this op will not synthesise), and one sharing its line with a directive. Fail-closed,
 * the same rule the delete-gating checks follow — never write a destination that does not compile
 * and say nothing.
 *
 * The branch question is why the walk is over DIRECTIVES rather than the tree: the grammar
 * flattens every branch of a region into one child list, so the node model cannot say which branch
 * a statement is in, and that distinction is the difference between a condition that carries and
 * its negation.
 */
@:nullSafety(Strict)
final class GuardedImportCarry {

	/** The statement kinds a carry may reproduce at the destination — the same set the unguarded carry accepts. */
	private static final CARRIABLE_KINDS: Array<ImportKind> = [ImportKind.Import, ImportKind.Using, ImportKind.Alias];

	/**
	 * Every conditional-compilation directive of `source`, in source order — what `carryFor` reads
	 * one guarded statement's guard out of.
	 *
	 * Hoisted by the caller rather than taken per name: a move asks about every dependency of one
	 * declaration, and the scan is over the whole file.
	 */
	public static function directivesOf(source: String, plugin: GrammarPlugin): Array<CondDirective> {
		return CondDirectives.scan(source, plugin.refShape(), plugin.lexicalRegions.bind(source));
	}

	/**
	 * Every top-level conditional region of `source`, ready for `mergeSeat`.
	 *
	 * Hoisted by the caller rather than taken per name: a move asks about every dependency of one
	 * declaration, and the directive scan is over the whole file.
	 */
	public static function blocksOf(source: String, plugin: GrammarPlugin): Array<CondBlock> {
		final shape: RefShape = plugin.refShape();
		final directives: Array<CondDirective> = CondDirectives.scan(source, shape, plugin.lexicalRegions.bind(source));
		return directives.length == 0 ? [] : CondDirectives.topLevelBlocks(source, directives, shape);
	}

	/**
	 * The `#if <condition>` … `#end` block that carries `lines` — the statements are reproduced
	 * verbatim under the condition their source file guarded them with, rather than the region
	 * being copied whole.
	 *
	 * Copying the region was the first shape and it was wrong on real code: a file whose ENTIRE
	 * body sits inside one `#if (sys || nodejs)` has its type declaration in that region too, and
	 * every `#if` written inside a method body makes it non-flat — so the whole-region reading
	 * refused a move the op had always performed. The statements alone carry with no such gates.
	 */
	public static function blockText(condition: String, lines: Array<String>, shape: RefShape): String {
		final ifKeyword: String = shape.conditionalIfKeyword ?? '#if';
		final endKeyword: String = shape.conditionalEndKeyword ?? '#end';
		return '$ifKeyword $condition\n${lines.join('\n')}\n$endKeyword';
	}

	/**
	 * What to do about `dep` when the unguarded carry found no statement to bring: the guarded
	 * statements to re-emit and the ONE condition that guards them all, a refusal naming why no single
	 * condition carries it, or `GuardedNone` when nothing guarded binds the name at all (which is every
	 * dependency reached through the stdlib, a wildcard or the ambient top level, so it must stay the
	 * silent answer).
	 */
	public static function carryFor(
		dep: String, cursorFile: String, source: String, cursorInfo: FileInfo, directives: Array<CondDirective>, shape: RefShape
	): GuardedCarry {
		final providers: Array<ImportInfo> = [
			for (imp in cursorInfo.imports)
				if (
					imp.guarded && CARRIABLE_KINDS.contains(imp.kind) && SymbolIndex.pathImportedBy(imp) != null
					&& RefactorSupport.lastSegment(imp.raw) == dep
				)
					imp
		];
		if (providers.length == 0) return GuardedNone;
		var condition: Null<String> = null;
		for (imp in providers) {
			final guard: GuardSite = guardOf(source, directives, shape, imp.span.from);
			final why: Null<String> = switch guard {
				// The tree says the statement is guarded and the lexical directive walk does not
				// agree: an unbalanced `#if` run, or one this reader stopped at. Refuse rather than
				// fall back on the statement alone, which is the silent drop this module exists for.
				case GuardNone:
					'the directive walk cannot place it under any `#if`';
				// A conjunction of conditions, which this op will not synthesise a spelling for.
				case GuardNested(depth):
					'it sits $depth `#if` regions deep, so more than one condition guards it';
				// `#else` means "not the conditions above", and reproducing that at the destination
				// takes the whole chain, not one branch of it.
				case GuardBranch(keyword):
					'it sits in that region\'s `$keyword` branch, whose condition is the negation of the ones above it';
				case GuardNoCondition: 'the region\'s condition could not be delimited';
				case GuardTop(text): text == '' ? 'the region\'s condition is empty' : null;
			};
			if (why != null) return refused(dep, cursorFile, conditionTextOf(guard), why);
			if (!CondDirectives.ownsItsLine(source, imp.span))
				return refused(dep, cursorFile, conditionTextOf(guard), 'the statement shares its line with code the move is not taking');
			final text: String = conditionTextOf(guard) ?? '';
			if (condition != null && condition != text)
				return refused(
					dep, cursorFile, null, 'two different `#if` regions bind it (`$condition`, `$text`), so no single condition carries it'
				);
			condition = text;
		}
		return condition == null ? GuardedNone : GuardedProviders(condition, providers);
	}

	/** Whether `line` is a carried guarded REGION rather than a single statement. */
	public static function isBlock(line: String, shape: RefShape): Bool {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		return ifKeyword != null && ifKeyword != '' && line.startsWith(ifKeyword);
	}

	/**
	 * The edit that merges `block` into a region `destSource` already has under the SAME condition,
	 * or null when it has none to merge into (the block is then written whole at the import anchor).
	 *
	 * Two same-condition regions in one header compile exactly as one does, so this is tidiness
	 * rather than correctness — but a `move` that leaves a file the `cond-region-merge` check
	 * immediately reports has made work for its own user. Only a SINGLE-BRANCH region on each side
	 * qualifies: inserting above an `#end` that closes an `#else` arm would put the statement in
	 * that arm, under the negation of the condition it was carried for.
	 */
	public static function mergeSeat(
		destSource: String, destBlocks: Array<CondBlock>, block: String, shape: RefShape
	): Null<{ span: Span, text: String }> {
		final lines: Array<String> = bodyLinesOf(block);
		if (lines.length == 0) return null;
		final condition: String = CondDirectives.normalizeCondition(headerConditionOf(block, shape));
		for (dest in destBlocks) {
			if (!dest.singleBranch || !dest.flat || !dest.linewise) continue;
			if (CondDirectives.normalizeCondition(conditionOf(destSource, dest)) != condition) continue;
			final present: String = destSource.substring(dest.headerEnd, dest.closeFrom);
			final held: Array<String> = [for (line in present.split('\n')) line.trim()];
			final missing: Array<String> = lines.filter(line -> !held.contains(line.trim()));
			if (missing.length == 0) return { span: new Span(dest.closeFrom, dest.closeFrom), text: '' };
			final seat: Int = lineStartOf(destSource, dest.closeFrom);
			return { span: new Span(seat, seat), text: '${missing.join('\n')}\n' };
		}
		return null;
	}

	/**
	 * Where `at` sits in `source`'s conditional nesting — the whole answer the carry needs about one
	 * guarded statement, in the shape the refusal reads it back in.
	 *
	 * The walk is over the directive list rather than the tree: the grammar flattens every branch of a
	 * region into one child list, so the node model cannot say which BRANCH a statement is in, and that
	 * distinction is the difference between a condition that can be carried and its negation.
	 */
	private static function guardOf(source: String, directives: Array<CondDirective>, shape: RefShape, at: Int): GuardSite {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		if (ifKeyword == null || endKeyword == null) return GuardNone;
		final open: Array<CondDirective> = [];
		var branch: Null<String> = null;
		for (directive in directives) {
			if (directive.span.from > at) break;
			if (directive.keyword == ifKeyword) {
				open.push(directive);
				branch = null;
				continue;
			}
			if (directive.keyword == endKeyword) {
				if (open.length == 0) return GuardNone;
				open.pop();
				branch = null;
				continue;
			}
			if (open.length > 0) branch = directive.keyword;
		}
		if (open.length == 0) return GuardNone;
		if (open.length > 1) return GuardNested(open.length);
		if (branch != null) return GuardBranch(branch);
		final span: Null<Span> = open[0].condition;
		return span == null ? GuardNoCondition : GuardTop(source.substring(span.from, span.to).trim());
	}

	/** The condition text a `GuardSite` carries, for the refusal's `(#if …)` clause. */
	private static function conditionTextOf(guard: GuardSite): Null<String> {
		return switch guard {
			case GuardTop(text): text;
			case _: null;
		};
	}

	/** The region's condition text as written, or the empty string when it carries none the reader could delimit. */
	private static function conditionOf(source: String, block: CondBlock): String {
		final span: Null<Span> = block.condition;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	/** The condition of a carried region, read off its own first line. */
	private static function headerConditionOf(block: String, shape: RefShape): String {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final nl: Int = block.indexOf('\n');
		final header: String = nl < 0 ? block : block.substring(0, nl);
		return ifKeyword == null ? header.trim() : header.substring(ifKeyword.length).trim();
	}

	/** A carried region's body — every line between its two directive lines, which own their lines by construction. */
	private static function bodyLinesOf(block: String): Array<String> {
		final lines: Array<String> = block.split('\n');
		return lines.length < 3 ? [] : lines.slice(1, lines.length - 1);
	}

	/** Index of the first character of the line containing `i`. */
	private static function lineStartOf(source: String, i: Int): Int {
		final nl: Int = source.lastIndexOf('\n', i);
		return nl < 0 ? 0 : nl + 1;
	}

	/** One refusal, in the shape the collision gate's already use: what was reached, where, why, and the two ways out. */
	private static function refused(dep: String, cursorFile: String, condition: Null<String>, why: String): GuardedCarry {
		final where: String = condition == null ? '' : ' (`#if $condition`)';
		return GuardedRefusal(
			'the moved code reaches "$dep" through a `#if`-guarded import in $cursorFile$where, and $why — leaving it behind '
			+ 'would make "$dep" unbound in some build with nothing to say so; move the dependency too, or import "$dep" '
			+ 'unconditionally at the source first'
		);
	}

}

/**
 * The three answers `GuardedImportCarry.carryFor` has: nothing guarded binds the name, a region to
 * carry verbatim under its condition, or a reason the region is not a unit this op may relocate.
 */
enum GuardedCarry {

	GuardedNone;
	GuardedProviders(condition: String, imports: Array<ImportInfo>);
	GuardedRefusal(message: String);

}

/**
 * Where one guarded statement sits in its file's conditional nesting: unguarded as far as the
 * directive walk can tell, one region deep in that region's `#if` arm (the only carriable shape),
 * one region deep in a LATER branch, several regions deep, or under a condition the reader could
 * not delimit.
 */
private enum GuardSite {

	GuardNone;
	GuardTop(condition: String);
	GuardBranch(keyword: String);
	GuardNested(depth: Int);
	GuardNoCondition;

}

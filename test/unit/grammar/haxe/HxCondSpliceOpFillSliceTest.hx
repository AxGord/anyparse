package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * `@:fmt(fillParts)` on `HxCondSpliceOpExpr` — the operand-position
 * conditional splice gets a layout policy of its own.
 *
 * THE DEFECT THIS CLOSES. The modelled region used to be written by replaying
 * the source: the terms Star's inter-element separator read
 * `Trivial<T>.newlineBefore`, the `operand`/`op` gap inside a term read
 * `opBeforeNewline`, and the gaps before `#end` and before the tail read their
 * own `BeforeNewline` slots. Every one of those is a hardline when the source
 * had a newline there and a space when it did not, so the SAME tree laid out
 * as many different ways as the source could spell it. Measured on the TM site
 * (`src/crashdumper/SystemData.hx:135-140`) with 42 legal whitespace spellings
 * of one expression: the pre-slice writer produced **39 distinct outputs**,
 * including one 238-column line from a source written flat — the width limit
 * was not enforced inside the region at all, because there was no decision to
 * enforce it with. The two TM sites that carry this shape
 * (`crashdumper/SystemData.hx`, `crashdumper/CrashDumper.hx`) disagreed with
 * each other for exactly this reason.
 *
 * THE POLICY. The rule assembles its fields as one run — condition, operand
 * terms, `#end`, tail — that stays space-joined while it fits the line and
 * packs (Wadler fill) when it does not. `@:fmt(fillSeam)` hands the gap before
 * `#end` and before the tail to that run; `@:fmt(fillItems)` does the same for
 * the terms Star; `@:fmt(inlineSep)` on `HxCondSpliceOpTerm.op` keeps an
 * operator glued to the operand it closes. No source-newline slot is read
 * anywhere in the region.
 *
 * WHY THIS IS SAFE, given that the operator is bound to a compilation branch
 * (`+` before `#if` lives outside the region, `+` before `#end` lives inside
 * it, so moving one across a directive seam silently breaks one of the two
 * builds): the policy only ever changes WHITESPACE. The token order is the
 * rule's field order and no edit here can reorder it. That was checked rather
 * than argued — a projection net tokenizes a file, expands every conditional
 * both ways, and compares the two token streams before and after formatting;
 * over 1665 real modules it reports zero movement, and it catches both
 * illegal seam moves when they are injected deliberately.
 */
@:nullSafety(Strict)
final class HxCondSpliceOpFillSliceTest extends Test {

	/** TM's own `hxformat.json` shape for the two sites this slice moves. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"opAddSubChain":{"defaultWrap":"noWrap",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]}}}';

	/** TM `src/crashdumper/SystemData.hx:135-140`, canonical. */
	private static final SYSTEM_DATA: String = 'class C {\n\tpublic function toString():String {\n\t\treturn \'SystemData\\n{$${endl()}  '
		+ 'os: $$os\\n  osRaw: $$osRaw\\n  osName: $$osName\\n  osVersion: $$osVersion\\n\'\n\t\t\t+ #if flash \'  playerType: \' + '
		+ 'playerType + \'\\n\' + \'  playerVersion: \' + playerVersion + \'\\n\' + #end\n\t\t\t\'  totalMemory: '
		+ '$${toGBStr(totalMemory)}\\n  cpuName: $$cpuName\\n  gpuName: $$gpuName\\n  gpuDriverVersion: $$gpuDriverVersion\\n}\';\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * Every legal whitespace spelling of one region reaches one output. The
	 * variants are the ones a human actually writes: the operator before
	 * `#if` on either line, a break after the condition, a break mid-term
	 * (between an operand and the operator that closes it — the shape TM's
	 * own source carries), a break before `#end`, and everything flat.
	 */
	public function testEveryLegalSpellingReachesOneOutput(): Void {
		final spellings: Array<String> = [
			SYSTEM_DATA,
			// TM's source form: the run split mid-term at `+ '\n' + #end`.
			'class C {\n\tpublic function toString():String {\n\t\treturn \'SystemData\\n{$${endl()}  os: $$os\\n  osRaw: $$osRaw\\n  '
				+ 'osName: $$osName\\n  osVersion: $$osVersion\\n\'\n\t\t\t+ #if flash \'  playerType: \' + playerType + \'\\n\' + \'  '
				+ 'playerVersion: \' + playerVersion\n\t\t\t+ \'\\n\' + #end\n\t\t\t\'  totalMemory: $${toGBStr(totalMemory)}\\n  cpuName: '
				+ '$$cpuName\\n  gpuName: $$gpuName\\n  gpuDriverVersion: $$gpuDriverVersion\\n}\';\n\t}\n}',
			// The operator on its own line, the condition alone on the next,
			// and the run's trailing operator left dangling before `#end`.
			'class C {\n\tpublic function toString():String {\n'
				+ '\t\treturn \'SystemData\\n{$${endl()}  os: $$os\\n  osRaw: $$osRaw\\n  osName: $$osName\\n  osVersion: '
				+ '$$osVersion\\n\'\n\t\t\t+\n\t\t\t#if flash\n\t\t\t\'  playerType: \' + playerType + \'\\n\' + \'  playerVersion: \' + '
				+ 'playerVersion + \'\\n\' +\n\t\t\t#end\n\t\t\t\'  totalMemory: $${toGBStr(totalMemory)}\\n  cpuName: $$cpuName\\n  '
				+ 'gpuName: $$gpuName\\n  gpuDriverVersion: $$gpuDriverVersion\\n}\';\n\t}\n}',
			// The whole statement on ONE source line. Pre-slice this produced
			// a 238-column output line: no break point existed inside the
			// region, so the width limit had nothing to act on.
			'class C {\n\tpublic function toString():String {\n\t\treturn \'SystemData\\n{$${endl()}  os: $$os\\n  osRaw: '
				+ '$$osRaw\\n  osName: $$osName\\n  osVersion: $$osVersion\\n\' + #if flash \'  playerType: \' + playerType + \'\\n\' + '
				+ '\'  playerVersion: \' + playerVersion + \'\\n\' + #end \'  totalMemory: $${toGBStr(totalMemory)}\\n  cpuName: '
				+ '$$cpuName\\n  gpuName: $$gpuName\\n  gpuDriverVersion: $$gpuDriverVersion\\n}\';\n\t}\n}'
		];
		for (i in 0...spellings.length) Assert.equals(SYSTEM_DATA, triviaWrite(spellings[i]), 'spelling $i');
	}

	/**
	 * No line of the canonical output passes the configured limit. The
	 * flat-source spelling above used to give one of 238 columns against a
	 * 140-column budget, so this is the property the fill exists to restore.
	 */
	public function testCanonicalOutputRespectsTheLineWidth(): Void {
		for (line in triviaWrite(SYSTEM_DATA).split('\n')) {
			var width: Int = 0;
			for (i in 0...line.length) width += line.charAt(i) == '\t' ? 4 : 1;
			Assert.isTrue(width <= 140, 'line of $width columns: $line');
		}
	}

	/**
	 * A region that already fits keeps its bytes. Eight of the ten regions in
	 * a 1665-module census are this shape — a single-line `#if c <operand> <op>
	 * #end <tail>` inside a condition — and the fill must be invisible to
	 * them, INCLUDING to the probes that decide whether `if (` opens onto its
	 * own line. It is not invisible on its own: a bare `Fill` reads as a
	 * committed break to `Renderer.naturalFirstLineGluable`, which opened the
	 * parens of all four such regions in the census. `D.fillOnOverflow` gates
	 * the fill behind an `IfLineExceeds` so every measurement still descends
	 * the plain space-joined shape.
	 */
	public function testFittingRegionKeepsItsBytesAndItsParens(): Void {
		final src: String = 'class C {\n\tfunction f():Bool {\n\t\tif (#if neko __fieldOfView == null || #end projectionCenter == null)\n'
			+ '\t\t\treturn null;\n\t\tif (#if openfl_power_of_two !image.powerOfTwo || #end (!image.premultiplied && image.transparent))\n'
			+ '\t\t\treturn null;\n\t\treturn true;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * A comment captured inside the operand run routes the whole Star back to
	 * the source-faithful emit — a fill re-decides every break, and a line
	 * comment pins the one after itself. The refusal is what keeps such a
	 * region round-tripping instead of being re-laid out around a comment the
	 * fill cannot place.
	 */
	public function testCommentInsideTheRunKeepsTheSourceFaithfulEmit(): Void {
		final src: String =
			'class C {\n\tfunction f():String {\n\t\treturn \'a\' + #if flash \'b\' + // why\n\t\t\tc + #end \'d\';\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
